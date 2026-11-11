import Foundation
import Observation

nonisolated final class RefreshTaskHandle: @unchecked Sendable {
  private let lock = NSLock()
  private var task: Task<Void, Never>?

  func replace(with newTask: Task<Void, Never>) {
    lock.lock()
    let previous = task
    task = newTask
    lock.unlock()
    previous?.cancel()
  }

  func cancel() {
    lock.lock()
    let current = task
    task = nil
    lock.unlock()
    current?.cancel()
  }
}

@MainActor
@Observable
final class UsageStore {
  private(set) var providers: [ProviderUsage]
  private(set) var activeConversations: [ActiveConversation]
  private(set) var brainSnapshot: BrainSnapshot
  private(set) var lastUpdated: Date?
  private(set) var lastConversationsUpdated: Date?
  private(set) var lastBrainUpdated: Date?
  private(set) var isRefreshing = false

  private let collectors: [any UsageCollector]
  private let conversationCollector: (any ConversationCollecting)?
  private let brainCollector: (any BrainStateCollecting)?
  private let clock: any Clock
  private let logger: StructuredLogger
  private let refreshInterval: Duration
  private let cacheTTL: TimeInterval
  private let refreshTaskHandle = RefreshTaskHandle()
  private var refreshSequence = 0

  init(
    providers: [ProviderUsage] = ProviderUsage.placeholders,
    activeConversations: [ActiveConversation] = [],
    brainSnapshot: BrainSnapshot = .empty,
    collectors: [any UsageCollector],
    conversationCollector: (any ConversationCollecting)?,
    brainCollector: (any BrainStateCollecting)? = nil,
    clock: any Clock = SystemClock(),
    logger: StructuredLogger? = nil,
    refreshInterval: Duration = .seconds(300),
    cacheTTL: TimeInterval = 60,
    startPeriodicRefresh: Bool = true
  ) {
    self.providers = providers
    self.activeConversations = activeConversations
    self.brainSnapshot = brainSnapshot
    self.collectors = collectors
    self.conversationCollector = conversationCollector
    self.brainCollector = brainCollector
    self.clock = clock
    self.logger = logger ?? StructuredLogger(clock: clock)
    self.refreshInterval = refreshInterval
    self.cacheTTL = cacheTTL

    guard
      startPeriodicRefresh,
      !collectors.isEmpty || conversationCollector != nil || brainCollector != nil
    else {
      return
    }

    let loopClock = clock
    let interval = refreshInterval
    let task = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        if let store = self {
          await store.refresh()
        } else {
          return
        }
        guard !Task.isCancelled, self != nil else { return }
        do {
          try await loopClock.sleep(for: interval)
        } catch {
          return
        }
      }
    }
    refreshTaskHandle.replace(with: task)
  }

  nonisolated deinit {
    refreshTaskHandle.cancel()
  }

  var currentDate: Date {
    clock.now()
  }

  var menuBarLabel: String {
    let lowestRemaining =
      providers
      .filter { $0.sessionState.hasUsableQuota }
      .flatMap(\.limits)
      .map(\.remainingPercentage)
      .min()

    return lowestRemaining.map { "\($0)%" } ?? "—"
  }

  func stopPeriodicRefresh() {
    refreshTaskHandle.cancel()
  }

  /// Atualiza dados somente quando o cache de `cacheTTL` (60 s por padrão) expirou.
  func refreshIfStale() async {
    let now = clock.now()

    let quotasAreFresh: Bool =
      if collectors.isEmpty {
        true
      } else if let lastUpdated {
        now.timeIntervalSince(lastUpdated) < cacheTTL
      } else {
        false
      }

    guard quotasAreFresh else {
      await refresh()
      return
    }

    let conversationsAreFresh: Bool =
      if conversationCollector == nil {
        true
      } else if let lastConversationsUpdated {
        now.timeIntervalSince(lastConversationsUpdated) < cacheTTL
      } else {
        false
      }

    let brainIsFresh: Bool =
      if brainCollector == nil {
        true
      } else if let lastBrainUpdated {
        now.timeIntervalSince(lastBrainUpdated) < cacheTTL
      } else {
        false
      }

    if !conversationsAreFresh || !brainIsFresh {
      await refreshLocalState()
    }
  }

  func refreshLocalState(refreshID: String? = nil) async {
    guard conversationCollector != nil || brainCollector != nil else { return }
    let correlationID = refreshID ?? nextRefreshID(prefix: "local")

    if let conversationCollector {
      do {
        let conversations = try await conversationCollector.fetchActiveConversations()
        activeConversations = conversations
        lastConversationsUpdated = clock.now()
        logger.info(
          event: "sessions_refreshed",
          refreshID: correlationID,
          fields: [
            .collector: "active_sessions",
            .status: "ok",
            .conversationsCount: "\(conversations.count)",
          ]
        )
      } catch {
        let appError = ErrorHandler.normalize(error)
        logger.warn(
          event: "sessions_refresh_failed",
          refreshID: correlationID,
          errorCode: appError.code,
          fields: [
            .collector: "active_sessions",
            .status: "failed",
          ]
        )
      }
    }

    if let brainCollector {
      do {
        let snapshot = try await brainCollector.fetchBrainState()
        brainSnapshot = snapshot
        let degraded = snapshot.degradedSections
        if degraded.isEmpty {
          lastBrainUpdated = clock.now()
          logger.info(
            event: "brain_state_refreshed",
            refreshID: correlationID,
            fields: [
              .collector: "brain_state",
              .status: "ok",
              .waitingCount: "\(snapshot.waitingOnOwnerCount)",
            ]
          )
        } else {
          let firstError =
            snapshot.waiting.error
            ?? snapshot.ciQueue.error
            ?? snapshot.healthAndBackup.error
            ?? snapshot.scheduledJobs.error
          logger.warn(
            event: "brain_state_partially_degraded",
            refreshID: correlationID,
            errorCode: firstError?.code,
            fields: [
              .collector: "brain_state",
              .status: "degraded",
              .degradedSectionsCount: "\(degraded.count)",
              .section: degraded.map(\.rawValue).joined(separator: ","),
            ]
          )
        }
      } catch {
        let appError = ErrorHandler.normalize(error)
        logger.warn(
          event: "brain_state_refresh_failed",
          refreshID: correlationID,
          errorCode: appError.code,
          fields: [
            .collector: "brain_state",
            .status: "failed",
          ]
        )
      }
    }
  }

  func refresh() async {
    guard !isRefreshing else { return }
    guard !collectors.isEmpty || conversationCollector != nil || brainCollector != nil else {
      return
    }

    isRefreshing = true
    defer { isRefreshing = false }

    let correlationID = nextRefreshID(prefix: "refresh")
    let startedAt = clock.now()

    logger.info(
      event: "refresh_started",
      refreshID: correlationID,
      fields: [.status: "started"]
    )

    await refreshLocalState(refreshID: correlationID)

    guard !collectors.isEmpty else {
      let localSucceeded = lastConversationsUpdated != nil || lastBrainUpdated != nil
      logRefreshCompleted(
        correlationID: correlationID,
        startedAt: startedAt,
        anySucceeded: localSucceeded
      )
      return
    }

    var receivedLiveData = false
    let registeredCollectors = collectors

    await withTaskGroup(of: (String, Result<ProviderUsage, any Error>).self) { group in
      for collector in registeredCollectors {
        group.addTask {
          do {
            return (collector.providerID, .success(try await collector.fetchUsage()))
          } catch {
            return (collector.providerID, .failure(error))
          }
        }
      }

      for await (providerID, result) in group {
        let outcome = QuotaStateReducer.apply(
          result: result,
          for: providerID,
          now: clock.now(),
          into: &providers
        )
        switch outcome {
        case .updated(let usage):
          receivedLiveData = true
          logger.info(
            event: "collector_succeeded",
            refreshID: correlationID,
            fields: [
              .provider: providerID,
              .status: "ok",
              .limitsCount: "\(usage.limits.count)",
            ]
          )
        case .markedStale(_, let appError):
          logger.warn(
            event: "collector_failed_preserved_cache",
            refreshID: correlationID,
            errorCode: appError.code,
            fields: [
              .provider: providerID,
              .status: "stale",
            ]
          )
        case .markedUnavailable(_, let appError):
          logger.warn(
            event: "collector_failed",
            refreshID: correlationID,
            errorCode: appError.code,
            fields: [
              .provider: providerID,
              .status: "unavailable",
            ]
          )
        case .ignoredUnknownProvider:
          break
        }
      }
    }

    if receivedLiveData {
      lastUpdated = clock.now()
    }
    logRefreshCompleted(
      correlationID: correlationID,
      startedAt: startedAt,
      anySucceeded: receivedLiveData
    )
  }

  private func nextRefreshID(prefix: String) -> String {
    refreshSequence += 1
    return "\(prefix)-\(refreshSequence)"
  }

  private func logRefreshCompleted(
    correlationID: String,
    startedAt: Date,
    anySucceeded: Bool
  ) {
    let elapsedMs = max(Int((clock.now().timeIntervalSince(startedAt) * 1_000).rounded()), 0)
    logger.info(
      event: "refresh_completed",
      refreshID: correlationID,
      fields: [
        .status: anySucceeded ? "ok" : "degraded",
        .durationMs: "\(elapsedMs)",
      ]
    )
  }
}

extension UsageStore {
  static func makeForRuntime(
    config: AppConfig,
    clock: any Clock = SystemClock(),
    logger: StructuredLogger? = nil
  ) -> UsageStore {
    let resolvedLogger = logger ?? StructuredLogger(clock: clock)

    switch config.mode {
    case .live:
      let cliEnvironment = CLIEnvironment(config: config)
      return UsageStore(
        collectors: [
          ClaudeCollector(cliEnvironment: cliEnvironment, clock: clock),
          GeminiCollector(cliEnvironment: cliEnvironment, clock: clock),
        ],
        conversationCollector: ActiveConversationCollector(config: config, clock: clock),
        brainCollector: BrainStateCollector(config: config, clock: clock),
        clock: clock,
        logger: resolvedLogger,
        refreshInterval: config.refreshInterval,
        cacheTTL: config.cacheTTL,
        startPeriodicRefresh: true
      )
    case .isolated:
      let cliEnvironment = CLIEnvironment(config: config)
      return UsageStore(
        collectors: [
          ClaudeCollector(cliEnvironment: cliEnvironment, clock: clock),
          GeminiCollector(cliEnvironment: cliEnvironment, clock: clock),
        ],
        conversationCollector: ActiveConversationCollector(config: config, clock: clock),
        brainCollector: BrainStateCollector(
          config: config,
          clock: clock,
          launchctlRunner: EmptyLaunchctlRunner()
        ),
        clock: clock,
        logger: resolvedLogger,
        refreshInterval: config.refreshInterval,
        cacheTTL: config.cacheTTL,
        startPeriodicRefresh: true
      )
    case .selfCheck, .testing:
      return UsageStore(
        collectors: [],
        conversationCollector: nil,
        brainCollector: nil,
        clock: clock,
        logger: resolvedLogger,
        refreshInterval: config.refreshInterval,
        cacheTTL: config.cacheTTL,
        startPeriodicRefresh: false
      )
    }
  }
}
