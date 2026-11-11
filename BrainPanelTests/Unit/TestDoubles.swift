import Foundation

@testable import BrainPanel

nonisolated final class TestClock: Clock, @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date
  private var sleepCallCountValue = 0
  private var sleepCancelledCountValue = 0
  private var sleepWaiters: [CheckedContinuation<Void, any Error>] = []
  var onSleepStarted: (@Sendable () -> Void)?
  var onSleepCancelled: (@Sendable () -> Void)?

  init(now: Date = Date(timeIntervalSince1970: 1_762_819_200)) {
    self.current = now
  }

  var sleepCallCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return sleepCallCountValue
  }

  var sleepCancelledCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return sleepCancelledCountValue
  }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  func advance(by seconds: TimeInterval) {
    lock.lock()
    current = current.addingTimeInterval(seconds)
    lock.unlock()
  }

  func resumeNextSleep() {
    lock.lock()
    let waiter = sleepWaiters.isEmpty ? nil : sleepWaiters.removeFirst()
    lock.unlock()
    waiter?.resume()
  }

  func sleep(for _: Duration) async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        lock.lock()
        sleepCallCountValue += 1
        let startedCallback = onSleepStarted
        if Task.isCancelled {
          sleepCancelledCountValue += 1
          let cancelledCallback = onSleepCancelled
          lock.unlock()
          startedCallback?()
          cancelledCallback?()
          continuation.resume(throwing: CancellationError())
          return
        }
        sleepWaiters.append(continuation)
        lock.unlock()
        startedCallback?()
      }
    } onCancel: {
      lock.lock()
      sleepCancelledCountValue += 1
      let cancelledCallback = onSleepCancelled
      let waiters = sleepWaiters
      sleepWaiters.removeAll()
      lock.unlock()
      for waiter in waiters {
        waiter.resume(throwing: CancellationError())
      }
      cancelledCallback?()
    }
  }
}

nonisolated final class InMemoryLogSink: LogSink, @unchecked Sendable {
  private let lock = NSLock()
  private var storedLines: [String] = []

  var lines: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storedLines
  }

  func write(_ line: String) {
    lock.lock()
    storedLines.append(line)
    lock.unlock()
  }
}

nonisolated final class StubUsageCollector: UsageCollector, @unchecked Sendable {
  let providerID: String
  private let lock = NSLock()
  private var queuedResults: [Result<ProviderUsage, any Error>]
  private(set) var callCount = 0

  init(providerID: String, results: [Result<ProviderUsage, any Error>]) {
    self.providerID = providerID
    self.queuedResults = results
  }

  func fetchUsage() async throws -> ProviderUsage {
    let next: Result<ProviderUsage, any Error> = {
      lock.lock()
      defer { lock.unlock() }
      callCount += 1
      if queuedResults.count > 1 {
        return queuedResults.removeFirst()
      }
      return queuedResults.first ?? .failure(AppError.internalFailure())
    }()
    return try next.get()
  }
}

nonisolated final class StubConversationCollector: ConversationCollecting, @unchecked Sendable {
  private let lock = NSLock()
  private var queuedResults: [Result<[ActiveConversation], any Error>]
  private(set) var callCount = 0

  init(results: [Result<[ActiveConversation], any Error>]) {
    self.queuedResults = results
  }

  func fetchActiveConversations() async throws -> [ActiveConversation] {
    let next: Result<[ActiveConversation], any Error> = {
      lock.lock()
      defer { lock.unlock() }
      callCount += 1
      if queuedResults.count > 1 {
        return queuedResults.removeFirst()
      }
      return queuedResults.first ?? .success([])
    }()
    return try next.get()
  }
}

nonisolated final class StubBrainStateCollector: BrainStateCollecting, @unchecked Sendable {
  private let lock = NSLock()
  private var queuedResults: [Result<BrainSnapshot, any Error>]
  private(set) var callCount = 0

  init(results: [Result<BrainSnapshot, any Error>]) {
    self.queuedResults = results
  }

  func fetchBrainState() async throws -> BrainSnapshot {
    let next: Result<BrainSnapshot, any Error> = {
      lock.lock()
      defer { lock.unlock() }
      callCount += 1
      if queuedResults.count > 1 {
        return queuedResults.removeFirst()
      }
      return queuedResults.first ?? .success(.empty)
    }()
    return try next.get()
  }
}

nonisolated final class SpyNotificationDeliverer: NotificationDelivering, @unchecked Sendable {
  struct DeliveryBatch: Equatable, Sendable {
    let refreshID: String
    let alerts: [DiscreteNotificationAlert]
  }

  private let lock = NSLock()
  private var recordedBatches: [DeliveryBatch] = []

  var batches: [DeliveryBatch] {
    lock.lock()
    defer { lock.unlock() }
    return recordedBatches
  }

  var deliveredAlerts: [DiscreteNotificationAlert] {
    batches.flatMap(\.alerts)
  }

  var callCount: Int {
    batches.count
  }

  func deliver(_ alerts: [DiscreteNotificationAlert], refreshID: String) async {
    lock.withLock {
      recordedBatches.append(DeliveryBatch(refreshID: refreshID, alerts: alerts))
    }
  }
}
