import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

final class MCPDomainReadToolProviderTests: XCTestCase {
    func testDefinitionsCoverM3FamiliesExactlyOnce() throws {
        let definitions = MCPDomainReadToolDefinitions.definitions
        XCTAssertEqual(definitions.map(\.name), MCPDomainReadToolDefinitions.migratedToolNames)
        XCTAssertEqual(Set(definitions.map(\.name)).count, definitions.count)
        XCTAssertTrue(definitions.allSatisfy { $0.inputSchema.objectValue?["type"]?.stringValue == "object" })
        XCTAssertEqual(definitions.first { $0.name == "prompt" }?.annotations.readOnlyHint, false)
        XCTAssertTrue(definitions.filter { $0.name != "prompt" }.allSatisfy { $0.annotations.readOnlyHint == true })
    }

    func testProviderUsesDomainHandleAndSharedBackendForEveryFamily() async throws {
        let identity = makeIdentity()
        let coordinator = DomainReadSideEffectCoordinator(identity: identity)
        let recorder = InvocationRecorder()
        let handle = makeHandle(identity: identity)
        let provider = MCPDomainReadToolProvider(
            resolveContext: { _ in handle },
            backend: MCPDomainReadToolBackend { name, received, arguments, _ in
                await recorder.record(name: name, handle: received, arguments: arguments)
                return .object(["tool": .string(name)])
            },
            sideEffects: coordinator
        )

        for binding in provider.bindings {
            let arguments: [String: Value] = switch binding.definition.name {
            case "read_file": ["path": .string("file.swift")]
            case "file_search": ["pattern": .string("needle")]
            case "history": ["op": .string("list_sessions")]
            case "git": ["op": .string("status")]
            default: [:]
            }
            let value = try await binding(arguments)
            XCTAssertEqual(value.objectValue?["tool"]?.stringValue, binding.definition.name)
        }

        let invocations = await recorder.snapshot()
        XCTAssertEqual(invocations.map(\.name), MCPDomainReadToolDefinitions.migratedToolNames)
        XCTAssertTrue(invocations.allSatisfy { $0.handle == handle })
    }

    func testIndependentReadBackendsDoNotContendOnSideEffectCoordinator() async throws {
        let identity = makeIdentity()
        let handle = makeHandle(identity: identity)
        let barrier = ConcurrentEntryBarrier(target: 2)
        let provider = MCPDomainReadToolProvider(
            resolveContext: { _ in handle },
            backend: MCPDomainReadToolBackend { name, _, _, _ in
                await barrier.arriveAndWait()
                return .string(name)
            },
            sideEffects: DomainReadSideEffectCoordinator(identity: identity)
        )
        let tree = try XCTUnwrap(provider.binding(named: "get_file_tree"))
        let search = try XCTUnwrap(provider.binding(named: "file_search"))

        async let treeValue = tree([:])
        async let searchValue = search(["pattern": .string("needle")])
        let values = try await [treeValue, searchValue]

        XCTAssertEqual(Set(values.compactMap(\.stringValue)), ["get_file_tree", "file_search"])
        let maximumConcurrency = await barrier.maximumConcurrency()
        XCTAssertEqual(maximumConcurrency, 2)
    }

    func testCancellationPropagatesWithoutSuccessNormalization() async throws {
        let identity = makeIdentity()
        let handle = makeHandle(identity: identity)
        let provider = MCPDomainReadToolProvider(
            resolveContext: { _ in handle },
            backend: MCPDomainReadToolBackend { _, _, _, _ in
                try await Task.sleep(for: .seconds(30))
                return .object([:])
            },
            sideEffects: DomainReadSideEffectCoordinator(identity: identity)
        )
        let read = try XCTUnwrap(provider.binding(named: "read_file"))
        let task = Task { try await read(["path": .string("file.swift")]) }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }

    func testProviderNormalizesTopLevelInvalidParametersBeforeBackend() async throws {
        let identity = makeIdentity()
        let recorder = InvocationRecorder()
        let handle = makeHandle(identity: identity)
        let provider = MCPDomainReadToolProvider(
            resolveContext: { _ in handle },
            backend: MCPDomainReadToolBackend { name, handle, arguments, _ in
                await recorder.record(name: name, handle: handle, arguments: arguments)
                return .object([:])
            },
            sideEffects: DomainReadSideEffectCoordinator(identity: identity)
        )

        let readFile = try XCTUnwrap(provider.binding(named: "read_file"))
        do {
            _ = try await readFile([:])
            XCTFail("Expected invalid parameters")
        } catch let error as MCPError {
            XCTAssertTrue(String(describing: error).contains("missing path"))
        }

        let search = try XCTUnwrap(provider.binding(named: "file_search"))
        do {
            _ = try await search(["pattern": .string("  ")])
            XCTFail("Expected invalid parameters")
        } catch let error as MCPError {
            XCTAssertTrue(String(describing: error).contains("pattern cannot be empty"))
        }
        let invocations = await recorder.snapshot()
        XCTAssertTrue(invocations.isEmpty)
    }

    private func makeIdentity() -> DomainRuntimeIdentity {
        DomainRuntimeIdentity(
            runtimeID: UUID(),
            lifecycleGeneration: 3,
            processID: 42,
            mode: .app,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeHandle(identity: DomainRuntimeIdentity) -> DomainReadContextHandle {
        DomainReadContextHandle(
            runtimeID: identity.runtimeID,
            runtimeGeneration: identity.lifecycleGeneration,
            connectionID: UUID(),
            connectionGeneration: 2,
            context: DomainContextIdentity(workspaceID: UUID(), contextID: UUID()),
            workspaceRevision: 5,
            contextRevision: 7,
            routingRevision: 11,
            bindingKind: .explicit
        )
    }
}

private actor ConcurrentEntryBarrier {
    private let target: Int
    private var arrivals = 0
    private var maximum = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(target: Int) {
        self.target = target
    }

    func arriveAndWait() async {
        arrivals += 1
        maximum = max(maximum, arrivals)
        if arrivals == target {
            let pending = continuations
            continuations.removeAll()
            for continuation in pending {
                continuation.resume()
            }
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func maximumConcurrency() -> Int { maximum }
}

private actor InvocationRecorder {
    struct Invocation: Sendable {
        let name: String
        let handle: DomainReadContextHandle
        let arguments: [String: Value]
    }

    private var invocations: [Invocation] = []

    func record(name: String, handle: DomainReadContextHandle, arguments: [String: Value]) {
        invocations.append(Invocation(name: name, handle: handle, arguments: arguments))
    }

    func snapshot() -> [Invocation] { invocations }
}
