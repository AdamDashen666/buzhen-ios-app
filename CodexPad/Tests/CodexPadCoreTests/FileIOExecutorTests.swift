import XCTest
@testable import CodexPadCore

final class FileIOExecutorTests: XCTestCase, @unchecked Sendable {
    func testDeadlineReturnsWithoutWaitingForUncooperativeProvider() async {
        let release = DispatchSemaphore(value: 0)
        let ended = expectation(description: "Worker ends after the caller times out")
        let start = Date()
        do {
            let _: Int = try await FileIOExecutor.run(timeout: 0.05) { _ in
                XCTAssertFalse(Thread.isMainThread)
                defer { ended.fulfill() }
                _ = release.wait(timeout: .now() + 3)
                return 42
            }
            XCTFail("Expected a real deadline")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("超时"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        release.signal()
        await fulfillment(of: [ended], timeout: 4)
    }

    func testCancellationReturnsBeforeBlockedWorkerExits() async {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let ended = expectation(description: "Cancelled worker drains safely")
        let task = Task {
            try await FileIOExecutor.run { _ in
                defer { ended.fulfill() }
                started.signal()
                _ = release.wait(timeout: .now() + 3)
                return 42
            }
        }
        while started.wait(timeout: .now()) == .timedOut {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let start = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        release.signal()
        await fulfillment(of: [ended], timeout: 4)
    }

    func testTimedOutQueuedOperationNeverStarts() async {
        let queue = DispatchQueue(label: "test.blocked-provider")
        let release = DispatchSemaphore(value: 0)
        queue.async { _ = release.wait(timeout: .now() + 3) }
        do {
            let _: Int = try await FileIOExecutor.run(timeout: 0.05, queue: queue) { _ in
                XCTFail("A cancelled queued operation must not touch files")
                return 42
            }
            XCTFail("Expected timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("超时"))
        }
        release.signal()
        let drained = expectation(description: "Queue drained")
        queue.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 4)
    }
}
