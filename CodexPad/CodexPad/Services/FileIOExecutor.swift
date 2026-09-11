import Foundation

enum FileIOExecutor {
    static func run<T: Sendable>(
        timeout: TimeInterval = 30,
        queue: DispatchQueue = .global(qos: .userInitiated),
        operation: @escaping @Sendable (FileOperationControl) throws -> T
    ) async throws -> T {
        let completion = FileIOCompletion<T>()
        let control = FileOperationControl()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                let deadline = Task.detached {
                    do { try await Task.sleep(for: .seconds(timeout)) }
                    catch { return }
                    completion.finish(.failure(WorkspaceFileError.timedOut))
                    control.cancel(timeout: true)
                }
                queue.async {
                    defer { deadline.cancel() }
                    let result = Result {
                        try control.check()
                        let value = try operation(control)
                        try control.check()
                        return value
                    }
                    completion.finish(result)
                }
            }
        } onCancel: {
            completion.finish(.failure(CancellationError()))
            control.cancel()
        }
    }
}

// A provider may ignore cancellation. Resume the caller exactly once without
// waiting for that provider; the worker retains its scope until it really exits.
private final class FileIOCompletion<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<T, Error>) {
        let completed: Result<T, Error>? = lock.withLock {
            if let result {
                self.result = nil
                return result
            }
            self.continuation = continuation
            return nil as Result<T, Error>?
        }
        if let completed { continuation.resume(with: completed) }
    }

    func finish(_ result: Result<T, Error>) {
        let waiting = lock.withLock {
            guard !finished else { return nil as CheckedContinuation<T, Error>? }
            finished = true
            let waiting = continuation
            if waiting == nil { self.result = result }
            continuation = nil
            return waiting
        }
        waiting?.resume(with: result)
    }
}
