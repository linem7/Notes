import Foundation
import Synchronization

/// `withTimeout` 超时了。
public struct TimeoutError: Error, Equatable, Sendable {
    public init() {}
}

/// 超过 `duration` 还没完成就抛 `TimeoutError`；调用方被取消就抛 `CancellationError`。
///
/// 两种情况都**立刻返回，不等 `operation` 结束**，并且取消 `operation`：`operation` 里有不响应取消的等待
/// （比如 WKWebView 的 `callAsyncJavaScript`，页面脚本死循环时永远不返回）时，超时和取消照样生效。
/// 不用 task group：它会等所有子任务结束，等于把不响应取消的子任务的时间也算进来，超时就形同虚设。
public func withTimeout<T: Sendable>(
    _ duration: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = TimeoutRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            race.setContinuation(continuation)
            race.add(Task {
                do {
                    race.finish(.success(try await operation()))
                } catch {
                    race.finish(.failure(error))
                }
            })
            race.add(Task {
                do {
                    try await Task.sleep(for: duration)
                } catch {
                    return
                }
                race.finish(.failure(TimeoutError()))
            })
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// 一次比赛：第一个 `finish` 决定结果，只恢复一次 continuation，并取消另一个任务。
private final class TimeoutRace<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        var result: Result<T, any Error>?
        var tasks: [Task<Void, Never>] = []
    }

    private let state = Mutex(State())

    func setContinuation(_ continuation: CheckedContinuation<T, any Error>) {
        let early = state.withLock { state -> Result<T, any Error>? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        // 取消赶在 continuation 建好之前：现在补上
        if let early { continuation.resume(with: early) }
    }

    func add(_ task: Task<Void, Never>) {
        let alreadyFinished = state.withLock { state -> Bool in
            if state.result != nil { return true }
            state.tasks.append(task)
            return false
        }
        if alreadyFinished { task.cancel() }
    }

    func finish(_ result: Result<T, any Error>) {
        let (continuation, tasks) = state.withLock { state -> (CheckedContinuation<T, any Error>?, [Task<Void, Never>]) in
            if state.result != nil { return (nil, []) }
            state.result = result
            let taken = (state.continuation, state.tasks)
            state.continuation = nil
            state.tasks = []
            return taken
        }
        continuation?.resume(with: result)
        for task in tasks { task.cancel() }
    }
}

