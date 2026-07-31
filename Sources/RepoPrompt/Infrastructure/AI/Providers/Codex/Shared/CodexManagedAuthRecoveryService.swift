import Foundation

protocol CodexManagedAuthRPCClient: Sendable {
    func updateDefaultRequestTimeout(_ timeout: TimeInterval?) async
    func startIfNeeded() async throws
    func stop() async
    func request(
        method: String,
        params: [String: Any]?,
        timeout: TimeInterval?
    ) async throws -> [String: Any]
    func subscribeNotifications() async -> AsyncStream<CodexAppServerClient.Notification>
}

protocol CodexManagedAuthRecovering: Sendable {
    func refreshManagedAccount() async -> CodexManagedAuthRefreshResult
    func startManagedChatgptLogin(
        openURL: @MainActor @escaping @Sendable (URL) -> Void
    ) async -> CodexManagedChatgptLoginResult
    func startManagedChatgptDeviceCodeLogin(
        presentDeviceCode: @MainActor @escaping @Sendable (CodexManagedChatgptDeviceCode, Bool) -> Void
    ) async -> CodexManagedChatgptLoginResult
}

enum CodexManagedLoginFlow: Equatable {
    case browser
    case deviceCode
}

enum CodexManagedAuthRefreshResult: Equatable {
    case recovered
    case requiresUserLogin(message: String)
    case executableUnavailable(message: String)
}

enum CodexManagedChatgptLoginResult: Equatable {
    case authenticated
    case failed(message: String)
    case executableUnavailable(message: String)
}

struct CodexManagedChatgptDeviceCode: Equatable {
    let loginID: String
    let userCode: String
    let verificationURL: URL
}

enum CodexManagedAuthRecoveryClassifier {
    static let loginActionTitle = "Login with ChatGPT"
    static let deviceCodeActionTitle = "Use device code instead"
    static let separateSignInExplanation =
        "RepoPrompt CE uses a separate Codex sign-in from any ~/.codex CLI credentials; sign in once here."
    static let manualLoginGuidanceMessage =
        "Codex authentication could not be refreshed automatically. Use 'Login with ChatGPT' or 'Use device code instead', then retry. \(separateSignInExplanation)"

    static func isRecoverable(issue: CodexNativeSessionController.ServerRequestIssue) -> Bool {
        guard issue.method == "account/chatgptAuthTokens/refresh" else { return false }
        switch issue.kind {
        case .authTokensRefreshInvalidParams, .authTokensRefreshUnavailable, .authTokensRefreshFailed:
            return true
        case .requestUserInputInvalidParams,
             .mcpElicitationInvalidParams,
             .mcpElicitationUnsupported,
             .permissionsRequestUnsupported,
             .dynamicToolCallUnsupported,
             .unsupportedMethod:
            return false
        }
    }

    static func isRecoverable(error: Error) -> Bool {
        isRecoverable(message: error.localizedDescription)
    }

    static func isRecoverable(message: String) -> Bool {
        let lowered = message.lowercased()
        let isRawUnauthorizedResponsesError =
            (lowered.contains("unexpected status 401") || lowered.contains("401 unauthorized"))
                && (
                    lowered.contains("missing bearer or basic authentication in header")
                        || lowered.contains("api.openai.com/v1/responses")
                )
        return lowered.contains("account/chatgptauthtokens/refresh")
            || lowered.contains("external auth is active")
            || isRawUnauthorizedResponsesError
    }

    static func preservesAsUserFacingGuidance(_ message: String) -> Bool {
        message == manualLoginGuidanceMessage
            || message.localizedCaseInsensitiveContains(loginActionTitle)
            || message.localizedCaseInsensitiveContains(deviceCodeActionTitle)
    }
}

actor CodexManagedAuthRecoveryService: CodexManagedAuthRecovering {
    static let shared = CodexManagedAuthRecoveryService {
        CodexProviderHelpers.makeOwnedNonAgentAppServerClient()
    }

    private struct InFlightLogin {
        let id: UUID
        let flow: CodexManagedLoginFlow
        let task: Task<CodexManagedChatgptLoginResult, Never>
    }

    private let clientFactory: @Sendable () -> any CodexManagedAuthRPCClient
    private let refreshRequestTimeout: TimeInterval
    private let browserLoginValidationTimeout: TimeInterval
    private let deviceCodeLoginValidationTimeout: TimeInterval
    private let loginPollInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var inFlightRefreshTask: Task<CodexManagedAuthRefreshResult, Never>?
    private var inFlightLogin: InFlightLogin?
    private var deviceCodePresenters: [UUID: @MainActor @Sendable (CodexManagedChatgptDeviceCode, Bool) -> Void] = [:]
    private var currentDeviceCode: CodexManagedChatgptDeviceCode?

    init(
        clientFactory: @escaping @Sendable () -> any CodexManagedAuthRPCClient,
        refreshRequestTimeout: TimeInterval = 30,
        browserLoginValidationTimeout: TimeInterval = 300,
        deviceCodeLoginValidationTimeout: TimeInterval = 15 * 60,
        loginPollInterval: TimeInterval = 0.5,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { interval in
            try await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
        }
    ) {
        self.clientFactory = clientFactory
        self.refreshRequestTimeout = refreshRequestTimeout
        self.browserLoginValidationTimeout = browserLoginValidationTimeout
        self.deviceCodeLoginValidationTimeout = deviceCodeLoginValidationTimeout
        self.loginPollInterval = loginPollInterval
        self.now = now
        self.sleep = sleep
    }

    func refreshManagedAccount() async -> CodexManagedAuthRefreshResult {
        if let inFlightLogin {
            switch await inFlightLogin.task.value {
            case .authenticated:
                return .recovered
            case let .executableUnavailable(message):
                return .executableUnavailable(message: message)
            case .failed:
                return .requiresUserLogin(message: CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage)
            }
        }
        if let inFlightRefreshTask {
            return await inFlightRefreshTask.value
        }

        let task = Task<CodexManagedAuthRefreshResult, Never> { [clientFactory, refreshRequestTimeout] in
            let client = clientFactory()
            defer {
                Task { await client.stop() }
            }
            do {
                await client.updateDefaultRequestTimeout(refreshRequestTimeout)
                try await client.startIfNeeded()
                let result = try await client.request(
                    method: "account/read",
                    params: ["refreshToken": true],
                    timeout: refreshRequestTimeout
                )
                if Self.isValidAccountReadResult(result) {
                    return .recovered
                }
            } catch {
                if let message = Self.executableUnavailableMessage(from: error) {
                    return .executableUnavailable(message: message)
                }
                return .requiresUserLogin(message: CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage)
            }
            return .requiresUserLogin(message: CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage)
        }
        inFlightRefreshTask = task
        let result = await task.value
        inFlightRefreshTask = nil
        return result
    }

    func startManagedChatgptLogin(
        openURL: @MainActor @escaping @Sendable (URL) -> Void
    ) async -> CodexManagedChatgptLoginResult {
        await startManagedLogin(flow: .browser) { [
            clientFactory,
            refreshRequestTimeout,
            browserLoginValidationTimeout,
            loginPollInterval,
            now,
            sleep
        ] in
            let client = clientFactory()
            return await Self.runLogin(
                client: client,
                flow: .browser,
                requestTimeout: refreshRequestTimeout,
                validationTimeout: browserLoginValidationTimeout,
                pollInterval: loginPollInterval,
                now: now,
                sleep: sleep,
                browserOpened: openURL,
                deviceCodeStarted: nil
            )
        }
    }

    func startManagedChatgptDeviceCodeLogin(
        presentDeviceCode: @MainActor @escaping @Sendable (CodexManagedChatgptDeviceCode, Bool) -> Void
    ) async -> CodexManagedChatgptLoginResult {
        let presenterID = UUID()
        deviceCodePresenters[presenterID] = presentDeviceCode
        defer { deviceCodePresenters[presenterID] = nil }

        if let currentDeviceCode, inFlightLogin?.flow == .deviceCode {
            await presentDeviceCode(currentDeviceCode, false)
        }

        return await startManagedLogin(flow: .deviceCode) { [
            clientFactory,
            refreshRequestTimeout,
            deviceCodeLoginValidationTimeout,
            loginPollInterval,
            now,
            sleep,
            weak self
        ] in
            let client = clientFactory()
            return await Self.runLogin(
                client: client,
                flow: .deviceCode,
                requestTimeout: refreshRequestTimeout,
                validationTimeout: deviceCodeLoginValidationTimeout,
                pollInterval: loginPollInterval,
                now: now,
                sleep: sleep,
                browserOpened: nil,
                deviceCodeStarted: { [self] code in
                    await self?.publishDeviceCode(code, initiatingPresenterID: presenterID)
                }
            )
        }
    }

    private func startManagedLogin(
        flow: CodexManagedLoginFlow,
        operation: @escaping @Sendable () async -> CodexManagedChatgptLoginResult
    ) async -> CodexManagedChatgptLoginResult {
        var waitedForRefresh = false
        while true {
            if let slot = inFlightLogin {
                if slot.flow == flow {
                    return await slot.task.value
                }
                slot.task.cancel()
                _ = await slot.task.value
                if inFlightLogin?.id == slot.id {
                    inFlightLogin = nil
                    currentDeviceCode = nil
                }
                continue
            }

            if !waitedForRefresh, let refreshTask = inFlightRefreshTask {
                waitedForRefresh = true
                switch await refreshTask.value {
                case .recovered:
                    return .authenticated
                case let .executableUnavailable(message):
                    return .executableUnavailable(message: message)
                case .requiresUserLogin:
                    continue
                }
            }

            let id = UUID()
            let task = Task<CodexManagedChatgptLoginResult, Never> {
                await operation()
            }
            inFlightLogin = InFlightLogin(id: id, flow: flow, task: task)
            let result = await task.value
            if inFlightLogin?.id == id {
                inFlightLogin = nil
                currentDeviceCode = nil
            }
            return result
        }
    }

    private func publishDeviceCode(
        _ code: CodexManagedChatgptDeviceCode,
        initiatingPresenterID: UUID
    ) async {
        currentDeviceCode = code
        for (presenterID, presenter) in deviceCodePresenters {
            await presenter(code, presenterID == initiatingPresenterID)
        }
    }

    private static func runLogin(
        client: any CodexManagedAuthRPCClient,
        flow: CodexManagedLoginFlow,
        requestTimeout: TimeInterval,
        validationTimeout: TimeInterval,
        pollInterval: TimeInterval,
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void,
        browserOpened: (@MainActor @Sendable (URL) -> Void)?,
        deviceCodeStarted: (@Sendable (CodexManagedChatgptDeviceCode) async -> Void)?
    ) async -> CodexManagedChatgptLoginResult {
        let cancellation = LoginCancellationState()
        var failureAuthURL: URL?
        let result = await withTaskCancellationHandler {
            do {
                await client.updateDefaultRequestTimeout(requestTimeout)
                try await client.startIfNeeded()
                let notifications = await client.subscribeNotifications()
                let state = LoginNotificationState()
                let loginID: String
                let browserAuthURL: URL?

                switch flow {
                case .browser:
                    let startResponse = try await startChatgptLogin(
                        client: client,
                        flow: flow,
                        timeout: requestTimeout
                    )
                    guard case let .browser(browser) = startResponse else {
                        throw AIProviderError.invalidResponse(detail: "Codex returned an invalid ChatGPT login response.")
                    }
                    loginID = browser.loginID
                    browserAuthURL = browser.authURL
                    failureAuthURL = browser.authURL
                    await cancellation.register(loginID: loginID, client: client, timeout: requestTimeout)
                    try Task.checkCancellation()
                    await browserOpened?(browser.authURL)
                case .deviceCode:
                    let startResponse = try await startChatgptLogin(
                        client: client,
                        flow: flow,
                        timeout: requestTimeout
                    )
                    guard case let .deviceCode(deviceCode) = startResponse else {
                        throw AIProviderError.invalidResponse(detail: "Codex returned an invalid ChatGPT device-code response.")
                    }
                    loginID = deviceCode.loginID
                    browserAuthURL = nil
                    await cancellation.register(loginID: loginID, client: client, timeout: requestTimeout)
                    try Task.checkCancellation()
                    await deviceCodeStarted?(deviceCode)
                }

                let notificationTask = Task {
                    var iterator = notifications.makeAsyncIterator()
                    while !Task.isCancelled, let notification = await iterator.next() {
                        await state.consume(notification: notification, expectedLoginID: loginID)
                    }
                }
                defer { notificationTask.cancel() }

                let deadline = now().addingTimeInterval(validationTimeout)
                return try await withThrowingTaskGroup(of: CodexManagedChatgptLoginResult?.self) { group in
                    // A matching managed-login completion is the primary success signal.
                    // Even then, account/read(refreshToken: true) remains authoritative.
                    group.addTask {
                        guard let completion = await state.waitForCompletion() else {
                            return nil
                        }
                        switch completion {
                        case .success:
                            let isAuthenticated = try await readAuthenticatedAccount(
                                client: client,
                                timeout: requestTimeout,
                                retryDelay: pollInterval,
                                sleep: sleep
                            )
                            return isAuthenticated ? .authenticated : nil
                        case let .failure(message):
                            return .failed(message: failureGuidance(
                                flow: flow,
                                message: message,
                                authURL: browserAuthURL
                            ))
                        }
                    }
                    group.addTask {
                        // Notifications can be lost with a dying transport. Keep a bounded
                        // fallback, but force token refresh so an unvalidated stale account
                        // snapshot cannot report success. A successful refresh remains
                        // authoritative even when the user signs back into the same account.
                        while now() < deadline {
                            try Task.checkCancellation()
                            if try await readAuthenticatedAccount(
                                client: client,
                                timeout: requestTimeout,
                                retryDelay: pollInterval,
                                sleep: sleep
                            ) {
                                return .authenticated
                            }
                            let remaining = deadline.timeIntervalSince(now())
                            if remaining > 0 {
                                try await sleep(min(pollInterval, remaining))
                            }
                        }
                        try Task.checkCancellation()
                        if try await readAuthenticatedAccount(
                            client: client,
                            timeout: requestTimeout,
                            retryDelay: pollInterval,
                            sleep: sleep
                        ) {
                            return .authenticated
                        }
                        return .failed(message: timeoutGuidance(flow: flow, authURL: browserAuthURL))
                    }
                    while let candidate = try await group.next() {
                        if let candidate {
                            group.cancelAll()
                            return candidate
                        }
                    }
                    return .failed(message: timeoutGuidance(flow: flow, authURL: browserAuthURL))
                }
            } catch is CancellationError {
                await cancellation.cancel(client: client, timeout: requestTimeout)
                return .failed(message: "Codex ChatGPT login was canceled before completion. Start the login again when ready.")
            } catch {
                await cancellation.cancel(client: client, timeout: requestTimeout)
                if let message = executableUnavailableMessage(from: error) {
                    return .executableUnavailable(message: message)
                }
                return .failed(message: failureGuidance(
                    flow: flow,
                    message: error.localizedDescription,
                    authURL: failureAuthURL
                ))
            }
        } onCancel: {
            Task {
                await cancellation.cancel(client: client, timeout: requestTimeout)
            }
        }
        await client.stop()
        return result
    }

    private static func readAuthenticatedAccount(
        client: any CodexManagedAuthRPCClient,
        timeout: TimeInterval,
        retryDelay: TimeInterval,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void
    ) async throws -> Bool {
        var transientFailureCount = 0
        while true {
            do {
                let result = try await client.request(
                    method: "account/read",
                    params: ["refreshToken": true],
                    timeout: timeout
                )
                return isAuthenticatedAccountReadResult(result)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard isClearlyTransientAccountReadFailure(error), transientFailureCount < 2 else {
                    throw error
                }
                transientFailureCount += 1
                let backoff = min(max(retryDelay, 0.1) * pow(2, Double(transientFailureCount - 1)), 2)
                try await sleep(backoff)
            }
        }
    }

    private static func isClearlyTransientAccountReadFailure(_ error: Error) -> Bool {
        guard let clientError = error as? CodexAppServerClient.ClientError,
              case let .requestFailed(failure) = clientError
        else {
            return false
        }
        // Codex documents -32001 as its overloaded/retry-later response.
        return failure.code == -32001
    }

    private static func executableUnavailableMessage(from error: Error) -> String? {
        if let clientError = error as? CodexAppServerClient.ClientError,
           case let .executableUnavailable(message) = clientError
        {
            return message
        }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CodexProviderHelpers.isCodexExecutableUnavailableMessage(message) else {
            return nil
        }
        return message
    }

    private static func startChatgptLogin(
        client: any CodexManagedAuthRPCClient,
        flow: CodexManagedLoginFlow,
        timeout: TimeInterval
    ) async throws -> ManagedChatgptLoginStartResponse {
        let type = flow == .browser ? "chatgpt" : "chatgptDeviceCode"
        do {
            return try await requestLoginStart(client: client, type: type, timeout: timeout)
        } catch {
            if error.localizedDescription.localizedCaseInsensitiveContains("external auth is active") {
                _ = try? await client.request(method: "account/logout", params: nil, timeout: timeout)
                return try await requestLoginStart(client: client, type: type, timeout: timeout)
            }
            throw error
        }
    }

    private static func requestLoginStart(
        client: any CodexManagedAuthRPCClient,
        type: String,
        timeout: TimeInterval
    ) async throws -> ManagedChatgptLoginStartResponse {
        let response = try await client.request(
            method: "account/login/start",
            params: ["type": type],
            timeout: timeout
        )
        if type == "chatgpt", let parsed = parseManagedChatgptLoginStartResponse(response) {
            return .browser(parsed)
        }
        if type == "chatgptDeviceCode", let parsed = parseManagedChatgptDeviceCodeStartResponse(response) {
            return .deviceCode(parsed)
        }
        let detail = type == "chatgpt"
            ? "Codex returned an invalid ChatGPT login response."
            : "Codex returned an invalid ChatGPT device-code response."
        throw AIProviderError.invalidResponse(detail: detail)
    }

    static func parseManagedChatgptLoginStartResponse(
        _ response: [String: Any]
    ) -> ManagedChatgptBrowserLoginStartResponse? {
        guard let loginID = stringValue(in: response, keys: ["loginId", "login_id"]),
              let authURLString = stringValue(in: response, keys: ["authUrl", "auth_url"]),
              let authURL = URL(string: authURLString),
              stringValue(in: response, keys: ["type"])?.lowercased() == "chatgpt"
        else {
            return nil
        }
        return ManagedChatgptBrowserLoginStartResponse(loginID: loginID, authURL: authURL)
    }

    static func parseManagedChatgptDeviceCodeStartResponse(
        _ response: [String: Any]
    ) -> CodexManagedChatgptDeviceCode? {
        guard let loginID = stringValue(in: response, keys: ["loginId", "login_id"]),
              let userCode = stringValue(in: response, keys: ["userCode", "user_code"]),
              let verificationURLString = stringValue(
                  in: response,
                  keys: ["verificationUrl", "verification_url"]
              ),
              let verificationURL = URL(string: verificationURLString),
              stringValue(in: response, keys: ["type"])?.lowercased() == "chatgptdevicecode"
        else {
            return nil
        }
        return CodexManagedChatgptDeviceCode(
            loginID: loginID,
            userCode: userCode,
            verificationURL: verificationURL
        )
    }

    static func browserCallbackPort(from authURL: URL) -> Int? {
        if authURL.host?.localizedCaseInsensitiveCompare("localhost") == .orderedSame {
            return authURL.port
        }
        guard let components = URLComponents(url: authURL, resolvingAgainstBaseURL: false),
              let redirectURI = components.queryItems?.first(where: {
                  $0.name.localizedCaseInsensitiveCompare("redirect_uri") == .orderedSame
              })?.value,
              let redirectURL = URL(string: redirectURI),
              redirectURL.host?.localizedCaseInsensitiveCompare("localhost") == .orderedSame
        else {
            return nil
        }
        return redirectURL.port
    }

    static func browserFailureGuidance(message: String, authURL: URL?) -> String {
        var parts = [trimmedMessage(message, fallback: "Codex ChatGPT login failed.")]
        if let authURL, let port = browserCallbackPort(from: authURL) {
            parts.append(
                "Codex was waiting for the browser callback on localhost:\(port). Use `lsof -iTCP:\(port) -sTCP:LISTEN` to verify that the listener belongs to the active Codex app-server, then confirm that process is still running and healthy."
            )
        } else {
            parts.append("Verify that the Codex app-server process is still running and able to receive the browser callback.")
        }
        parts.append("Try 'Use device code instead' to sign in without a localhost callback.")
        parts.append(CodexManagedAuthRecoveryClassifier.separateSignInExplanation)
        return parts.joined(separator: " ")
    }

    private static func failureGuidance(flow: CodexManagedLoginFlow, message: String, authURL: URL?) -> String {
        switch flow {
        case .browser:
            browserFailureGuidance(message: message, authURL: authURL)
        case .deviceCode:
            "\(trimmedMessage(message, fallback: "Codex ChatGPT device-code login failed.")) Request a new device code and try again. \(CodexManagedAuthRecoveryClassifier.separateSignInExplanation)"
        }
    }

    private static func timeoutGuidance(flow: CodexManagedLoginFlow, authURL: URL?) -> String {
        switch flow {
        case .browser:
            browserFailureGuidance(
                message: "Codex ChatGPT login did not complete in time. The managed account was checked once more and is still signed out.",
                authURL: authURL
            )
        case .deviceCode:
            "Codex ChatGPT device-code login did not complete before the code expired. The managed account was checked once more and is still signed out. Request a new device code and try again. \(CodexManagedAuthRecoveryClassifier.separateSignInExplanation)"
        }
    }

    private static func trimmedMessage(_ message: String, fallback: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func isValidAccountReadResult(_ result: [String: Any]) -> Bool {
        let requiresOpenAIAuth = boolValue(in: result, keys: ["requiresOpenaiAuth", "requires_openai_auth"]) ?? true
        if requiresOpenAIAuth == false {
            return true
        }
        return isAuthenticatedAccountReadResult(result)
    }

    private static func isAuthenticatedAccountReadResult(_ result: [String: Any]) -> Bool {
        guard let account = result["account"], !(account is NSNull) else {
            return false
        }
        return true
    }

    private static func stringValue(in payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func boolValue(in payload: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = payload[key] as? Bool {
                return value
            }
        }
        return nil
    }

    struct ManagedChatgptBrowserLoginStartResponse: Equatable {
        let loginID: String
        let authURL: URL
    }

    private enum ManagedChatgptLoginStartResponse {
        case browser(ManagedChatgptBrowserLoginStartResponse)
        case deviceCode(CodexManagedChatgptDeviceCode)
    }

    private actor LoginCancellationState {
        private var loginID: String?
        private var cancellationRequested = false
        private var cancellationTask: Task<Void, Never>?

        func register(
            loginID: String,
            client: any CodexManagedAuthRPCClient,
            timeout: TimeInterval
        ) async {
            self.loginID = loginID
            if cancellationRequested {
                await sendCancellationIfNeeded(client: client, timeout: timeout)
            }
        }

        func cancel(client: any CodexManagedAuthRPCClient, timeout: TimeInterval) async {
            cancellationRequested = true
            await sendCancellationIfNeeded(client: client, timeout: timeout)
        }

        private func sendCancellationIfNeeded(
            client: any CodexManagedAuthRPCClient,
            timeout: TimeInterval
        ) async {
            if let cancellationTask {
                await cancellationTask.value
                return
            }
            guard let loginID else { return }
            let task = Task {
                _ = try? await client.request(
                    method: "account/login/cancel",
                    params: ["loginId": loginID],
                    timeout: timeout
                )
            }
            cancellationTask = task
            await task.value
        }
    }

    private actor LoginNotificationState {
        enum Completion {
            case success
            case failure(String)
        }

        private var completion: Completion?
        private var pendingCompletionWaiters: [CheckedContinuation<Completion?, Never>] = []

        func consume(notification: CodexAppServerClient.Notification, expectedLoginID: String) {
            guard notification.method == "account/login/completed", completion == nil else { return }
            let params = Self.decodeParams(notification.params)
            // The broad Codex notification union permits a null loginId for non-managed
            // variants. Browser and device-code starts return an ID, so only an exact
            // match can complete this attempt. Absent, null, and foreign IDs are ignored;
            // account/read provides the bounded notification-loss fallback.
            guard Self.stringValue(in: params, keys: ["loginId", "login_id"]) == expectedLoginID else {
                return
            }
            let observedCompletion: Completion = if Self.boolValue(in: params, keys: ["success"]) == true {
                .success
            } else {
                .failure(
                    Self.stringValue(in: params, keys: ["error"]) ?? "Codex ChatGPT login failed."
                )
            }
            completion = observedCompletion
            resolvePendingWaiters(with: observedCompletion)
        }

        /// Suspends until the correlated terminal notification arrives. Returns `nil`
        /// when the waiter is cancelled so task-group cancellation cannot strand it.
        func waitForCompletion() async -> Completion? {
            if let completion {
                return completion
            }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    registerWaiterIfStillPending(continuation)
                }
            } onCancel: {
                Task { await self.cancelPendingWaiters() }
            }
        }

        private func registerWaiterIfStillPending(_ continuation: CheckedContinuation<Completion?, Never>) {
            if let completion {
                continuation.resume(returning: completion)
                return
            }
            pendingCompletionWaiters.append(continuation)
        }

        private func resolvePendingWaiters(with completion: Completion) {
            let waiters = pendingCompletionWaiters
            pendingCompletionWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(returning: completion)
            }
        }

        private func cancelPendingWaiters() {
            let waiters = pendingCompletionWaiters
            pendingCompletionWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(returning: nil)
            }
        }

        private static func stringValue(in payload: [String: Any], keys: [String]) -> String? {
            for key in keys {
                if let value = payload[key] as? String, !value.isEmpty {
                    return value
                }
            }
            return nil
        }

        private static func boolValue(in payload: [String: Any], keys: [String]) -> Bool? {
            for key in keys {
                if let value = payload[key] as? Bool {
                    return value
                }
            }
            return nil
        }

        private static func decodeParams(_ params: [String: CodexJSONValue]) -> [String: Any] {
            var output: [String: Any] = [:]
            for (key, value) in params {
                output[key] = value.toAny()
            }
            return output
        }
    }
}

extension CodexAppServerClient: CodexManagedAuthRPCClient {}
