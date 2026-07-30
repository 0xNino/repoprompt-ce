import Foundation
@testable import RepoPromptApp
import XCTest

final class CodexManagedAuthRecoveryServiceTests: XCTestCase {
    func testParsesBrowserAndDeviceCodeStartResponses() throws {
        let browser = try XCTUnwrap(CodexManagedAuthRecoveryService.parseManagedChatgptLoginStartResponse([
            "type": "chatgpt",
            "loginId": "browser-login",
            "authUrl": "https://auth.openai.com/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1457%2Fauth%2Fcallback"
        ]))
        XCTAssertEqual(browser.loginID, "browser-login")
        XCTAssertEqual(CodexManagedAuthRecoveryService.browserCallbackPort(from: browser.authURL), 1457)

        let device = try XCTUnwrap(CodexManagedAuthRecoveryService.parseManagedChatgptDeviceCodeStartResponse([
            "type": "chatgptDeviceCode",
            "loginId": "device-login",
            "userCode": "ABCD-EFGH",
            "verificationUrl": "https://auth.openai.com/codex/device"
        ]))
        XCTAssertEqual(device.loginID, "device-login")
        XCTAssertEqual(device.userCode, "ABCD-EFGH")
        XCTAssertEqual(device.verificationURL.absoluteString, "https://auth.openai.com/codex/device")

        XCTAssertNil(CodexManagedAuthRecoveryService.parseManagedChatgptLoginStartResponse([
            "type": "chatgpt",
            "authUrl": "https://auth.openai.com/authorize"
        ]))
        XCTAssertNil(CodexManagedAuthRecoveryService.parseManagedChatgptDeviceCodeStartResponse([
            "type": "chatgptDeviceCode",
            "loginId": "device-login",
            "verificationUrl": "https://auth.openai.com/codex/device"
        ]))
    }

    func testBrowserGuidanceIncludesCallbackPortDeviceEscapeHatchAndSeparateSignIn() {
        let authURL = URL(
            string: "https://auth.openai.com/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback"
        )
        let guidance = CodexManagedAuthRecoveryService.browserFailureGuidance(
            message: "Login failed.",
            authURL: authURL
        )

        XCTAssertTrue(guidance.contains("localhost:1455"))
        XCTAssertTrue(guidance.contains("lsof -iTCP:1455"))
        XCTAssertTrue(guidance.contains(CodexManagedAuthRecoveryClassifier.deviceCodeActionTitle))
        XCTAssertTrue(guidance.contains(CodexManagedAuthRecoveryClassifier.separateSignInExplanation))
        XCTAssertTrue(CodexManagedAuthRecoveryClassifier.preservesAsUserFacingGuidance(guidance))
    }

    func testDeviceCodeLoginSucceedsFromAccountReadWithoutSuccessNotification() async {
        let client = MockCodexManagedAuthClient(
            loginStartResponse: Self.deviceStartResponse,
            accountReadResponses: [Self.signedOutAccount, Self.signedInAccount]
        )
        let clock = TestClock()
        let service = makeService(client: client, clock: clock, validationTimeout: 2)
        let presented = LockedBox<(code: CodexManagedChatgptDeviceCode, shouldOpen: Bool)>()

        let result = await service.startManagedChatgptDeviceCodeLogin { code, shouldOpen in
            presented.set((code: code, shouldOpen: shouldOpen))
        }

        XCTAssertEqual(result, .authenticated)
        XCTAssertEqual(presented.value?.code.userCode, "ABCD-EFGH")
        XCTAssertEqual(presented.value?.shouldOpen, true)
        XCTAssertEqual(client.requestCount(method: "account/login/start"), 1)
        XCTAssertEqual(client.requestCount(method: "account/read"), 2)
        XCTAssertEqual(client.requestCount(method: "account/login/cancel"), 0)
        XCTAssertEqual(client.stopCallCount(), 1)
    }

    func testCompletionFailureNotificationStopsLoginWithoutRetry() async {
        let client = MockCodexManagedAuthClient(
            loginStartResponse: Self.deviceStartResponse,
            accountReadResponses: [Self.signedOutAccount],
            notificationOnLoginStart: CodexAppServerClient.Notification(
                method: "account/login/completed",
                params: [
                    "loginId": .string("device-login"),
                    "success": .bool(false),
                    "error": .string("Device authorization was denied.")
                ]
            )
        )
        let clock = TestClock()
        let service = makeService(client: client, clock: clock, validationTimeout: 10)

        let result = await service.startManagedChatgptDeviceCodeLogin { _, _ in }

        guard case let .failed(message) = result else {
            return XCTFail("Expected notification failure, got \(result)")
        }
        XCTAssertTrue(message.contains("Device authorization was denied."))
        XCTAssertTrue(message.contains(CodexManagedAuthRecoveryClassifier.separateSignInExplanation))
        XCTAssertEqual(client.requestCount(method: "account/login/start"), 1)
        XCTAssertEqual(client.requestCount(method: "account/logout"), 0)
    }

    func testLateSuccessIsAcceptedByFinalAccountReadAtDeadline() async {
        let client = MockCodexManagedAuthClient(
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: [Self.signedOutAccount, Self.signedInAccount]
        )
        let clock = TestClock()
        let service = makeService(client: client, clock: clock, validationTimeout: 1)

        let result = await service.startManagedChatgptLogin { _ in }

        XCTAssertEqual(result, .authenticated)
        XCTAssertEqual(client.requestCount(method: "account/read"), 2)
        XCTAssertEqual(client.requestCount(method: "account/login/start"), 1)
    }

    func testTimeoutPerformsFinalReadAndDoesNotRetryOrLogout() async {
        let client = MockCodexManagedAuthClient(
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: [Self.signedOutAccount]
        )
        let clock = TestClock()
        let service = makeService(client: client, clock: clock, validationTimeout: 1)

        let result = await service.startManagedChatgptLogin { _ in }

        guard case let .failed(message) = result else {
            return XCTFail("Expected timeout failure, got \(result)")
        }
        XCTAssertTrue(message.contains("checked once more"))
        XCTAssertTrue(message.contains("localhost:1457"))
        XCTAssertTrue(message.contains(CodexManagedAuthRecoveryClassifier.separateSignInExplanation))
        XCTAssertEqual(client.requestCount(method: "account/read"), 2)
        XCTAssertEqual(client.requestCount(method: "account/login/start"), 1)
        XCTAssertEqual(client.requestCount(method: "account/logout"), 0)
    }

    func testSwitchingFromBrowserToDeviceCodeCancelsFirstLoginBeforeStartingSecond() async throws {
        let browserClient = MockCodexManagedAuthClient(
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: [Self.signedOutAccount]
        )
        let deviceClient = MockCodexManagedAuthClient(
            loginStartResponse: Self.deviceStartResponse,
            accountReadResponses: [Self.signedInAccount]
        )
        let clients = ClientFactoryBox([browserClient, deviceClient])
        let service = CodexManagedAuthRecoveryService(
            clientFactory: { clients.next() },
            refreshRequestTimeout: 1,
            browserLoginValidationTimeout: 300,
            deviceCodeLoginValidationTimeout: 900,
            loginPollInterval: 1,
            sleep: { _ in
                try await Task.sleep(nanoseconds: .max)
            }
        )

        let browserTask = Task {
            await service.startManagedChatgptLogin { _ in }
        }
        try await waitUntil {
            browserClient.requestCount(method: "account/read") == 1
        }

        let deviceResult = await service.startManagedChatgptDeviceCodeLogin { _, _ in }
        let browserResult = await browserTask.value

        XCTAssertEqual(deviceResult, .authenticated)
        guard case .failed = browserResult else {
            return XCTFail("Expected the browser flow to be canceled, got \(browserResult)")
        }
        XCTAssertEqual(browserClient.requestCount(method: "account/login/cancel"), 1)
        XCTAssertEqual(browserClient.lastLoginID(for: "account/login/cancel"), "browser-login")
        XCTAssertEqual(browserClient.stopCallCount(), 1)
        XCTAssertEqual(deviceClient.requestCount(method: "account/login/start"), 1)
        XCTAssertEqual(deviceClient.lastLoginType(), "chatgptDeviceCode")
    }

    func testConcurrentSameFlowDeviceCodeLoginsCoalesceAndOnlyInitiatingPresenterOpensURL() async {
        let client = MockCodexManagedAuthClient(
            loginStartResponse: Self.deviceStartResponse,
            accountReadResponses: [Self.signedInAccount]
        )
        let clients = ClientFactoryBox([client])
        let service = CodexManagedAuthRecoveryService(
            clientFactory: { clients.next() },
            refreshRequestTimeout: 1,
            browserLoginValidationTimeout: 300,
            deviceCodeLoginValidationTimeout: 900,
            loginPollInterval: 1,
            sleep: { _ in
                try await Task.sleep(nanoseconds: .max)
            }
        )
        let presentedA = LockedBox<Bool>()
        let presentedB = LockedBox<Bool>()

        async let resultA = service.startManagedChatgptDeviceCodeLogin { _, shouldOpen in
            presentedA.set(shouldOpen)
        }
        async let resultB = service.startManagedChatgptDeviceCodeLogin { _, shouldOpen in
            presentedB.set(shouldOpen)
        }
        let (a, b) = await (resultA, resultB)

        XCTAssertEqual(a, .authenticated)
        XCTAssertEqual(b, .authenticated)
        XCTAssertEqual(client.requestCount(method: "account/login/start"), 1)
        XCTAssertEqual(clients.remaining, 0)

        let openFlags = [presentedA.value, presentedB.value].compactMap(\.self)
        XCTAssertEqual(openFlags.count, 2, "both concurrent callers should have been presented the same device code")
        XCTAssertEqual(openFlags.count(where: { $0 }), 1, "exactly one presenter should be told to open the verification URL")
        XCTAssertEqual(openFlags.count(where: { !$0 }), 1)
    }

    func testConcurrentReplacementCallersShareSingleReplacementAfterCancelAndAwaitedStop() async throws {
        let events = EventRecorder()
        let browserClient = MockCodexManagedAuthClient(
            label: "browser",
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: [Self.signedOutAccount],
            eventRecorder: { events.record($0) }
        )
        let deviceClient = MockCodexManagedAuthClient(
            label: "device",
            loginStartResponse: Self.deviceStartResponse,
            accountReadResponses: [Self.signedInAccount],
            eventRecorder: { events.record($0) }
        )
        let clients = ClientFactoryBox([browserClient, deviceClient])
        let service = CodexManagedAuthRecoveryService(
            clientFactory: { clients.next() },
            refreshRequestTimeout: 1,
            browserLoginValidationTimeout: 300,
            deviceCodeLoginValidationTimeout: 900,
            loginPollInterval: 1,
            sleep: { _ in
                try await Task.sleep(nanoseconds: .max)
            }
        )

        let browserTask = Task {
            await service.startManagedChatgptLogin { _ in }
        }
        try await waitUntil {
            browserClient.requestCount(method: "account/read") == 1
        }

        async let deviceResult1 = service.startManagedChatgptDeviceCodeLogin { _, _ in }
        async let deviceResult2 = service.startManagedChatgptDeviceCodeLogin { _, _ in }
        let (result1, result2) = await (deviceResult1, deviceResult2)
        let browserResult = await browserTask.value

        XCTAssertEqual(result1, .authenticated)
        XCTAssertEqual(result2, .authenticated)
        guard case .failed = browserResult else {
            return XCTFail("Expected the browser flow to be canceled, got \(browserResult)")
        }

        XCTAssertEqual(browserClient.requestCount(method: "account/login/cancel"), 1)
        XCTAssertEqual(browserClient.stopCallCount(), 1)
        XCTAssertEqual(deviceClient.requestCount(method: "account/login/start"), 1)
        XCTAssertEqual(clients.remaining, 0)

        let recordedEvents = events.snapshot()
        let cancelIndex = recordedEvents.firstIndex(of: "browser.account/login/cancel")
        let stopIndex = recordedEvents.firstIndex(of: "browser.stop")
        let deviceStartIndex = recordedEvents.firstIndex(of: "device.account/login/start")
        let cancelIdx = try XCTUnwrap(cancelIndex, "expected a recorded browser cancel RPC")
        let stopIdx = try XCTUnwrap(stopIndex, "expected a recorded browser stop")
        let startIdx = try XCTUnwrap(deviceStartIndex, "expected a recorded device login/start")
        XCTAssertLessThan(cancelIdx, stopIdx, "the canceled login must be requested before its client stops")
        XCTAssertLessThan(stopIdx, startIdx, "the canceled login's client must stop before the replacement login starts")
    }

    func testBrowserLoginUsesDefaultThreeHundredSecondLifetime() async {
        let client = MockCodexManagedAuthClient(
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: [Self.signedOutAccount]
        )
        let clock = TestClock()
        let service = CodexManagedAuthRecoveryService(
            clientFactory: { client },
            refreshRequestTimeout: 1,
            loginPollInterval: 50,
            now: { clock.now },
            sleep: { interval in clock.advance(by: interval) }
        )

        let result = await service.startManagedChatgptLogin { _ in }

        guard case .failed = result else {
            return XCTFail("Expected timeout failure, got \(result)")
        }
        XCTAssertEqual(clock.now.timeIntervalSince1970, 300, accuracy: 0.001)
    }

    func testDeviceCodeLoginUsesDefaultNineHundredSecondLifetime() async {
        let client = MockCodexManagedAuthClient(
            loginStartResponse: Self.deviceStartResponse,
            accountReadResponses: [Self.signedOutAccount]
        )
        let clock = TestClock()
        let service = CodexManagedAuthRecoveryService(
            clientFactory: { client },
            refreshRequestTimeout: 1,
            loginPollInterval: 50,
            now: { clock.now },
            sleep: { interval in clock.advance(by: interval) }
        )

        let result = await service.startManagedChatgptDeviceCodeLogin { _, _ in }

        guard case .failed = result else {
            return XCTFail("Expected timeout failure, got \(result)")
        }
        XCTAssertEqual(clock.now.timeIntervalSince1970, 900, accuracy: 0.001)
    }

    func testManagedGuidanceAdvertisesBothUISurfacesAndSeparateCredentialNamespace() {
        let guidance = CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage

        XCTAssertTrue(guidance.contains(CodexManagedAuthRecoveryClassifier.loginActionTitle))
        XCTAssertTrue(guidance.contains(CodexManagedAuthRecoveryClassifier.deviceCodeActionTitle))
        XCTAssertTrue(guidance.contains("separate Codex sign-in"))
        XCTAssertTrue(guidance.contains("~/.codex"))
        XCTAssertFalse(guidance.localizedCaseInsensitiveContains("codex login"))
    }

    private func makeService(
        client: MockCodexManagedAuthClient,
        clock: TestClock,
        validationTimeout: TimeInterval
    ) -> CodexManagedAuthRecoveryService {
        CodexManagedAuthRecoveryService(
            clientFactory: { client },
            refreshRequestTimeout: 1,
            browserLoginValidationTimeout: validationTimeout,
            deviceCodeLoginValidationTimeout: validationTimeout,
            loginPollInterval: 1,
            now: { clock.now },
            sleep: { interval in clock.advance(by: interval) }
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), "Condition was not satisfied before timeout")
    }

    private static let browserStartResponse: [String: Any] = [
        "type": "chatgpt",
        "loginId": "browser-login",
        "authUrl": "https://auth.openai.com/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1457%2Fauth%2Fcallback"
    ]

    private static let deviceStartResponse: [String: Any] = [
        "type": "chatgptDeviceCode",
        "loginId": "device-login",
        "userCode": "ABCD-EFGH",
        "verificationUrl": "https://auth.openai.com/codex/device"
    ]

    private static let signedOutAccount: [String: Any] = [
        "account": NSNull(),
        "requiresOpenaiAuth": true
    ]

    private static let signedInAccount: [String: Any] = [
        "account": ["type": "chatgpt"],
        "requiresOpenaiAuth": true
    ]
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 0)

    var now: Date {
        lock.withLock { date }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock {
            date = date.addingTimeInterval(interval)
        }
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value?

    var value: Value? {
        lock.withLock { storedValue }
    }

    func set(_ value: Value) {
        lock.withLock {
            storedValue = value
        }
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func record(_ event: String) {
        lock.withLock {
            events.append(event)
        }
    }

    func snapshot() -> [String] {
        lock.withLock { events }
    }
}

private final class ClientFactoryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [MockCodexManagedAuthClient]

    init(_ clients: [MockCodexManagedAuthClient]) {
        self.clients = clients
    }

    var remaining: Int {
        lock.withLock { clients.count }
    }

    func next() -> MockCodexManagedAuthClient {
        lock.withLock {
            precondition(!clients.isEmpty, "Unexpected extra client creation")
            return clients.removeFirst()
        }
    }
}

private final class MockCodexManagedAuthClient: CodexManagedAuthRPCClient, @unchecked Sendable {
    private struct RequestRecord {
        let method: String
        let loginType: String?
        let loginID: String?
    }

    private let lock = NSLock()
    private let label: String
    private let loginStartResponse: [String: Any]
    private var accountReadResponses: [[String: Any]]
    private let notificationOnLoginStart: CodexAppServerClient.Notification?
    private let notificationStream: AsyncStream<CodexAppServerClient.Notification>
    private let notificationContinuation: AsyncStream<CodexAppServerClient.Notification>.Continuation
    private let eventRecorder: (@Sendable (String) -> Void)?
    private var requests: [RequestRecord] = []
    private var stopCount = 0

    init(
        label: String = "client",
        loginStartResponse: [String: Any],
        accountReadResponses: [[String: Any]],
        notificationOnLoginStart: CodexAppServerClient.Notification? = nil,
        eventRecorder: (@Sendable (String) -> Void)? = nil
    ) {
        self.label = label
        self.loginStartResponse = loginStartResponse
        self.accountReadResponses = accountReadResponses
        self.notificationOnLoginStart = notificationOnLoginStart
        self.eventRecorder = eventRecorder
        var continuation: AsyncStream<CodexAppServerClient.Notification>.Continuation!
        notificationStream = AsyncStream { continuation = $0 }
        notificationContinuation = continuation
    }

    func updateDefaultRequestTimeout(_: TimeInterval?) async {}

    func startIfNeeded() async throws {}

    func stop() async {
        lock.withLock {
            stopCount += 1
        }
        notificationContinuation.finish()
        eventRecorder?("\(label).stop")
    }

    func request(
        method: String,
        params: [String: Any]?,
        timeout _: TimeInterval?
    ) async throws -> [String: Any] {
        let loginType = params?["type"] as? String
        let loginID = params?["loginId"] as? String
        lock.withLock {
            requests.append(RequestRecord(method: method, loginType: loginType, loginID: loginID))
        }
        eventRecorder?("\(label).\(method)")

        switch method {
        case "account/login/start":
            if let notificationOnLoginStart {
                notificationContinuation.yield(notificationOnLoginStart)
            }
            return loginStartResponse
        case "account/read":
            return lock.withLock {
                guard accountReadResponses.count > 1 else {
                    return accountReadResponses.first ?? ["account": NSNull(), "requiresOpenaiAuth": true]
                }
                return accountReadResponses.removeFirst()
            }
        case "account/login/cancel":
            return ["status": "canceled"]
        case "account/logout":
            return [:]
        default:
            XCTFail("Unexpected mock request: \(method)")
            return [:]
        }
    }

    func subscribeNotifications() async -> AsyncStream<CodexAppServerClient.Notification> {
        notificationStream
    }

    func requestCount(method: String) -> Int {
        lock.withLock {
            requests.count(where: { $0.method == method })
        }
    }

    func stopCallCount() -> Int {
        lock.withLock { stopCount }
    }

    func lastLoginType() -> String? {
        lock.withLock {
            requests.last(where: { $0.method == "account/login/start" })?.loginType
        }
    }

    func lastLoginID(for method: String) -> String? {
        lock.withLock {
            requests.last(where: { $0.method == method })?.loginID
        }
    }
}
