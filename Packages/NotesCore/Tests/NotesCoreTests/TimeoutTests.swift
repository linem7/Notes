import Foundation
import Testing
@testable import NotesCore

struct TimeoutTests {
    /// 永远不返回、也不响应取消的等待，模拟页面脚本死循环时的 `callAsyncJavaScript`。
    private static func neverReturns() async -> Int {
        await withCheckedContinuation { (_: CheckedContinuation<Int, Never>) in }
    }

    @Test func fastOperationsPassThrough() async throws {
        #expect(try await withTimeout(.seconds(5)) { 42 } == 42)
    }

    @Test func operationErrorsPassThrough() async throws {
        struct Boom: Error {}
        await #expect(throws: Boom.self) { try await withTimeout(.seconds(5)) { throw Boom() } }
    }

    @Test func aSlowOperationThatHonoursCancellationTimesOutAndIsCancelled() async throws {
        let started = ContinuousClock.now
        await #expect(throws: TimeoutError.self) {
            try await withTimeout(.milliseconds(50)) {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test(.timeLimit(.minutes(1)))
    func timeoutFiresEvenWhenTheOperationIgnoresCancellation() async throws {
        let started = ContinuousClock.now
        await #expect(throws: TimeoutError.self) {
            try await withTimeout(.milliseconds(100)) { await Self.neverReturns() }
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingTheCallerReturnsAtOnceEvenWhenTheOperationIgnoresCancellation() async throws {
        let task = Task { try await withTimeout(.seconds(60)) { await Self.neverReturns() } }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func theOperationIsCancelledWhenTheTimeoutFires() async throws {
        let flag = CancelFlag()
        await #expect(throws: TimeoutError.self) {
            try await withTimeout(.milliseconds(50)) {
                do { try await Task.sleep(for: .seconds(30)) } catch { await flag.mark(); throw error }
                return 1
            }
        }
        for _ in 0..<500 where !(await flag.isMarked) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await flag.isMarked)
    }

    private actor CancelFlag {
        private(set) var isMarked = false
        func mark() { isMarked = true }
    }
}
