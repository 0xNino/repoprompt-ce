import Darwin
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
        XCTAssertTrue(guidance.contains("listener belongs to the active Codex app-server"))
        XCTAssertTrue(guidance.contains("still running and healthy"))
        XCTAssertFalse(guidance.contains("Another app may be occupying"))
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

    func testStalePreLoginAccountCannotAuthenticateWithoutValidatingRefresh() async {
        let staleAccount: [String: Any] = [
            "account": ["type": "chatgpt", "email": "stale@example.com"],
            "requiresOpenaiAuth": true
        ]
        let client = MockCodexManagedAuthClient(
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: [Self.signedOutAccount],
            unrefreshedAccountReadResponse: staleAccount
        )
        let clock = TestClock()
        let service = makeService(client: client, clock: clock, validationTimeout: 1)

        let result = await service.startManagedChatgptLogin { _ in }

        guard case let .failed(message) = result else {
            return XCTFail("Expected unchanged stale account to time out, got \(result)")
        }
        XCTAssertTrue(message.contains("still signed out"))
        XCTAssertEqual(client.accountReadRefreshFlags(), [true, true])
        XCTAssertEqual(client.requestCount(method: "account/login/cancel"), 0)
        XCTAssertEqual(client.stopCallCount(), 1)
    }

    func testCorrelatedSuccessValidatesRefreshBeforeAcceptingUnchangedAccount() async {
        let unchangedAccount: [String: Any] = [
            "account": ["type": "chatgpt", "email": "same@example.com"],
            "requiresOpenaiAuth": true
        ]
        let client = MockCodexManagedAuthClient(
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: [unchangedAccount],
            notificationOnLoginStart: CodexAppServerClient.Notification(
                method: "account/login/completed",
                params: [
                    "loginId": .string("browser-login"),
                    "success": .bool(true),
                    "error": .null
                ]
            )
        )
        let service = CodexManagedAuthRecoveryService(
            clientFactory: { client },
            refreshRequestTimeout: 1,
            browserLoginValidationTimeout: 300,
            deviceCodeLoginValidationTimeout: 900,
            loginPollInterval: 1,
            sleep: { _ in try await Task.sleep(nanoseconds: .max) }
        )

        let result = await service.startManagedChatgptLogin { _ in }

        XCTAssertEqual(result, .authenticated)
        let refreshFlags = client.accountReadRefreshFlags()
        XCTAssertFalse(refreshFlags.isEmpty)
        XCTAssertTrue(refreshFlags.allSatisfy(\.self))
        XCTAssertEqual(client.stopCallCount(), 1)
    }

    func testAbsentAndNullCompletionLoginIDsAreIgnoredAndSafeFallbackRemainsAvailable() async {
        let notificationParams: [[String: CodexJSONValue]] = [
            [
                "success": .bool(false),
                "error": .string("Uncorrelated failure without an ID.")
            ],
            [
                "loginId": .null,
                "success": .bool(false),
                "error": .string("Uncorrelated failure with a null ID.")
            ]
        ]

        for params in notificationParams {
            let client = MockCodexManagedAuthClient(
                loginStartResponse: Self.deviceStartResponse,
                accountReadResponses: [Self.signedOutAccount, Self.signedInAccount],
                notificationOnLoginStart: CodexAppServerClient.Notification(
                    method: "account/login/completed",
                    params: params
                )
            )
            let clock = TestClock()
            let service = makeService(client: client, clock: clock, validationTimeout: 1)

            let result = await service.startManagedChatgptDeviceCodeLogin { _, _ in }

            XCTAssertEqual(result, .authenticated)
            XCTAssertEqual(client.accountReadRefreshFlags(), [true, true])
            XCTAssertEqual(client.stopCallCount(), 1)
        }
    }

    func testDocumentedOverloadRetryBudgetIsBounded() async {
        let overload = CodexAppServerClient.ClientError.requestFailed(.init(
            method: "account/read",
            code: -32001,
            message: "Server overloaded; retry later.",
            data: nil
        ))
        let client = MockCodexManagedAuthClient(
            loginStartResponse: Self.browserStartResponse,
            accountReadOutcomes: [.failure(overload)]
        )
        let clock = TestClock()
        let service = makeService(client: client, clock: clock, validationTimeout: 300)

        let result = await service.startManagedChatgptLogin { _ in }

        guard case let .failed(message) = result else {
            return XCTFail("Expected bounded overload failure, got \(result)")
        }
        XCTAssertTrue(message.contains("Server overloaded; retry later."))
        XCTAssertEqual(client.requestCount(method: "account/read"), 3)
        XCTAssertEqual(clock.now.timeIntervalSince1970, 3, accuracy: 0.001)
        XCTAssertEqual(client.requestCount(method: "account/login/cancel"), 1)
        XCTAssertEqual(client.stopCallCount(), 1)
    }

    func testProcessExitDuringValidationFailsPromptlyCancelsAndAwaitsStop() async throws {
        let events = EventRecorder()
        let processExit = CodexAppServerClient.ClientError.processExited(.init(
            executablePath: "/tmp/codex",
            launchDirectory: "/tmp",
            pid: 4242,
            status: .exited(code: 23),
            stderrTail: Data("fixture process exit".utf8),
            stderrWasTruncated: false,
            stderrWasSettled: true
        ))
        let client = MockCodexManagedAuthClient(
            label: "browser",
            loginStartResponse: Self.browserStartResponse,
            accountReadOutcomes: [
                .response(Self.signedOutAccount),
                .failure(processExit)
            ],
            eventRecorder: { events.record($0) }
        )
        let clock = TestClock()
        let service = makeService(client: client, clock: clock, validationTimeout: 300)

        let result = await service.startManagedChatgptLogin { _ in }

        guard case let .failed(message) = result else {
            return XCTFail("Expected prompt process-exit failure, got \(result)")
        }
        XCTAssertTrue(message.contains("exited with status 23"))
        XCTAssertTrue(message.contains("fixture process exit"))
        XCTAssertTrue(message.contains("listener belongs to the active Codex app-server"))
        XCTAssertTrue(message.contains(CodexManagedAuthRecoveryClassifier.deviceCodeActionTitle))
        XCTAssertEqual(clock.now.timeIntervalSince1970, 1, accuracy: 0.001)
        XCTAssertEqual(client.requestCount(method: "account/login/cancel"), 1)
        XCTAssertEqual(client.stopCallCount(), 1)

        let recordedEvents = events.snapshot()
        let validationRead = try XCTUnwrap(recordedEvents.lastIndex(of: "browser.account/read"))
        let cancel = try XCTUnwrap(recordedEvents.firstIndex(of: "browser.account/login/cancel"))
        let stop = try XCTUnwrap(recordedEvents.firstIndex(of: "browser.stop"))
        XCTAssertLessThan(validationRead, cancel)
        XCTAssertLessThan(cancel, stop)
    }

    func testTransportFailureDuringValidationFailsPromptlyCancelsAndAwaitsStop() async throws {
        let events = EventRecorder()
        let transportFailure = CodexAppServerClient.ClientError.transportReadSetupFailed(
            message: "Codex app-server process pipe reader failed to start: Bad file descriptor",
            errno: EBADF
        )
        let client = MockCodexManagedAuthClient(
            label: "device",
            loginStartResponse: Self.deviceStartResponse,
            accountReadOutcomes: [
                .response(Self.signedOutAccount),
                .failure(transportFailure)
            ],
            eventRecorder: { events.record($0) }
        )
        let clock = TestClock()
        let service = makeService(client: client, clock: clock, validationTimeout: 900)

        let result = await service.startManagedChatgptDeviceCodeLogin { _, _ in }

        guard case let .failed(message) = result else {
            return XCTFail("Expected prompt transport failure, got \(result)")
        }
        XCTAssertTrue(message.contains("process pipe reader failed to start"))
        XCTAssertTrue(message.contains("Request a new device code and try again"))
        XCTAssertTrue(message.contains(CodexManagedAuthRecoveryClassifier.separateSignInExplanation))
        XCTAssertEqual(clock.now.timeIntervalSince1970, 1, accuracy: 0.001)
        XCTAssertEqual(client.requestCount(method: "account/login/cancel"), 1)
        XCTAssertEqual(client.stopCallCount(), 1)

        let recordedEvents = events.snapshot()
        let validationRead = try XCTUnwrap(recordedEvents.lastIndex(of: "device.account/read"))
        let cancel = try XCTUnwrap(recordedEvents.firstIndex(of: "device.account/login/cancel"))
        let stop = try XCTUnwrap(recordedEvents.firstIndex(of: "device.stop"))
        XCTAssertLessThan(validationRead, cancel)
        XCTAssertLessThan(cancel, stop)
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
        let service = CodexManagedAuthRecoveryService(
            clientFactory: { client },
            refreshRequestTimeout: 1,
            browserLoginValidationTimeout: 10,
            deviceCodeLoginValidationTimeout: 10,
            loginPollInterval: 1,
            sleep: { _ in try await Task.sleep(nanoseconds: .max) }
        )

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
            accountReadResponses: [Self.signedOutAccount, Self.signedInAccount],
            notificationOnLoginStart: Self.deviceSuccessNotification
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
            browserClient.requestCount(method: "account/login/start") == 1
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
            accountReadResponses: [Self.signedOutAccount, Self.signedInAccount],
            notificationOnLoginStart: Self.deviceSuccessNotification
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
            notificationOnLoginStart: Self.deviceSuccessNotification,
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
            browserClient.requestCount(method: "account/login/start") == 1
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

    private static let deviceSuccessNotification = CodexAppServerClient.Notification(
        method: "account/login/completed",
        params: [
            "loginId": .string("device-login"),
            "success": .bool(true),
            "error": .null
        ]
    )

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

private enum MockAccountReadOutcome {
    case response([String: Any])
    case failure(Error)
}

private final class MockCodexManagedAuthClient: CodexManagedAuthRPCClient, @unchecked Sendable {
    private struct RequestRecord {
        let method: String
        let loginType: String?
        let loginID: String?
        let refreshToken: Bool?
    }

    private let lock = NSLock()
    private let label: String
    private let loginStartResponse: [String: Any]
    private let unrefreshedAccountReadOutcome: MockAccountReadOutcome?
    private var accountReadOutcomes: [MockAccountReadOutcome]
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
        unrefreshedAccountReadResponse: [String: Any]? = nil,
        notificationOnLoginStart: CodexAppServerClient.Notification? = nil,
        eventRecorder: (@Sendable (String) -> Void)? = nil
    ) {
        self.label = label
        self.loginStartResponse = loginStartResponse
        unrefreshedAccountReadOutcome = unrefreshedAccountReadResponse.map(MockAccountReadOutcome.response)
        accountReadOutcomes = accountReadResponses.map(MockAccountReadOutcome.response)
        self.notificationOnLoginStart = notificationOnLoginStart
        self.eventRecorder = eventRecorder
        var continuation: AsyncStream<CodexAppServerClient.Notification>.Continuation!
        notificationStream = AsyncStream { continuation = $0 }
        notificationContinuation = continuation
    }

    init(
        label: String = "client",
        loginStartResponse: [String: Any],
        accountReadOutcomes: [MockAccountReadOutcome],
        notificationOnLoginStart: CodexAppServerClient.Notification? = nil,
        eventRecorder: (@Sendable (String) -> Void)? = nil
    ) {
        self.label = label
        self.loginStartResponse = loginStartResponse
        unrefreshedAccountReadOutcome = nil
        self.accountReadOutcomes = accountReadOutcomes
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
        let refreshToken = params?["refreshToken"] as? Bool
        lock.withLock {
            requests.append(RequestRecord(
                method: method,
                loginType: loginType,
                loginID: loginID,
                refreshToken: refreshToken
            ))
        }
        eventRecorder?("\(label).\(method)")

        switch method {
        case "account/login/start":
            if let notificationOnLoginStart {
                notificationContinuation.yield(notificationOnLoginStart)
            }
            return loginStartResponse
        case "account/read":
            let outcome = lock.withLock {
                if refreshToken == false, let unrefreshedAccountReadOutcome {
                    return unrefreshedAccountReadOutcome
                }
                guard accountReadOutcomes.count > 1 else {
                    return accountReadOutcomes.first ?? .response([
                        "account": NSNull(),
                        "requiresOpenaiAuth": true
                    ])
                }
                return accountReadOutcomes.removeFirst()
            }
            switch outcome {
            case let .response(response):
                return response
            case let .failure(error):
                throw error
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

    func accountReadRefreshFlags() -> [Bool] {
        lock.withLock {
            requests.compactMap { record in
                record.method == "account/read" ? record.refreshToken : nil
            }
        }
    }
}
