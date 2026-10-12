import Foundation
import Testing

@testable import NotesCore

private actor Log {
    private(set) var items: [String] = []
    func add(_ item: String) { items.append(item) }
}

struct SerialWriteQueueTests {
    private struct Boom: Error {}

    /// 等 `count` 次 completion 都到了；自己也有超时，队列坏了不会让测试挂住。
    private func waitForCompletions(_ count: Int, _ stream: AsyncStream<Void>) async throws {
        try await withTimeout(.seconds(10)) {
            var seen = 0
            for await _ in stream {
                seen += 1
                if seen == count { return }
            }
        }
    }

    @Test func runsInOrderAndReportsSuccess() async throws {
        let queue = SerialWriteQueue(timeout: .seconds(5))
        let log = Log()
        let (stream, done) = AsyncStream.makeStream(of: Void.self)
        for i in 1...3 {
            queue.enqueue({
                // 前面的写入慢一点，也不能被后面的超车
                try await Task.sleep(for: .milliseconds(30 / i))
                await log.add("run \(i)")
            }, completion: { error in
                await log.add("done \(i) \(error == nil)")
                done.yield()
            })
        }
        try await waitForCompletions(3, stream)
        #expect(await log.items == ["run 1", "done 1 true", "run 2", "done 2 true", "run 3", "done 3 true"])
    }

    @Test func failureIsReportedAndLaterWritesStillRun() async throws {
        let queue = SerialWriteQueue(timeout: .seconds(5))
        let log = Log()
        let (stream, done) = AsyncStream.makeStream(of: Void.self)
        queue.enqueue({ throw Boom() }, completion: { error in
            await log.add("first \(error is Boom)")
            done.yield()
        })
        queue.enqueue({ await log.add("second ran") }, completion: { error in
            await log.add("second \(error == nil)")
            done.yield()
        })
        try await waitForCompletions(2, stream)
        #expect(await log.items == ["first true", "second ran", "second true"])
    }

    /// 一个永不返回、也不理会取消的写入（比如数据库被锁住）：超时后按失败处理，后面的写入照常执行。
    @Test func hungWriteTimesOutAndLaterWritesStillRun() async throws {
        let queue = SerialWriteQueue(timeout: .milliseconds(100))
        let log = Log()
        let (stream, done) = AsyncStream.makeStream(of: Void.self)
        queue.enqueue({
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        }, completion: { error in
            await log.add("hung timedOut=\(error is TimeoutError)")
            done.yield()
        })
        queue.enqueue({ await log.add("next ran") }, completion: { error in
            await log.add("next \(error == nil)")
            done.yield()
        })
        try await waitForCompletions(2, stream)
        #expect(await log.items == ["hung timedOut=true", "next ran", "next true"])
    }
}
