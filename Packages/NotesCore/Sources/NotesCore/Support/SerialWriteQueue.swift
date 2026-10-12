import Foundation
import Synchronization

/// 按顺序执行的写入队列，每个写入有超时（用 `withTimeout`）。
///
/// 超时按失败处理：`completion` 收到 `TimeoutError`，队列继续往下走。**已知取舍**：超时之后，
/// 那次卡住的写入可能还在后台跑，后面的写入不再等它。
public final class SerialWriteQueue: Sendable {
    private let tail = Mutex<Task<Void, Never>?>(nil)
    private let timeout: Duration

    public init(timeout: Duration = .seconds(10)) {
        self.timeout = timeout
    }

    /// 排到队尾。`work` 完成（成功、失败或超时）后调用 `completion`：成功传 nil，否则传错误。
    /// 前一个写入不管卡多久，最多等 `timeout`。
    public func enqueue(
        _ work: @escaping @Sendable () async throws -> Void,
        completion: @escaping @Sendable (Error?) async -> Void
    ) {
        let timeout = timeout
        tail.withLock { current in
            let previous = current
            current = Task {
                await previous?.value
                var failure: Error?
                do {
                    try await withTimeout(timeout, work)
                } catch {
                    failure = error
                }
                await completion(failure)
            }
        }
    }
}
