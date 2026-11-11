import Foundation

nonisolated enum NotificationSnapshotBridge {
  static func makeEvaluationInput(
    providers: [ProviderUsage],
    brainSnapshot: BrainSnapshot,
    hasBrainCollector: Bool,
    isBrainSnapshotStale: Bool
  ) -> NotificationEvaluationInput {
    let providerInputs = providers.map(makeProviderInput)

    let waitingFreshness: NotificationSourceFreshness
    let waitingCandidates: [NotificationWaitingCandidate]
    if isBrainSnapshotStale {
      waitingFreshness = .degraded
      waitingCandidates = []
    } else if !hasBrainCollector && brainSnapshot.capturedAt == nil {
      waitingFreshness = .uncollected
      waitingCandidates = []
    } else {
      switch brainSnapshot.waiting {
      case .loaded(let waitingState):
        waitingFreshness = .fresh
        waitingCandidates = makeWaitingCandidates(from: waitingState)
      case .failed:
        waitingFreshness = .degraded
        waitingCandidates = []
      }
    }

    let healthInput: NotificationHealthEvaluationInput
    if isBrainSnapshotStale {
      healthInput = NotificationHealthEvaluationInput(
        freshness: .degraded,
        doctorFailureCount: 0,
        isBackupFailing: false,
        isLiveBackupStalled: false
      )
    } else if !hasBrainCollector && brainSnapshot.capturedAt == nil {
      healthInput = NotificationHealthEvaluationInput(
        freshness: .uncollected,
        doctorFailureCount: 0,
        isBackupFailing: false,
        isLiveBackupStalled: false
      )
    } else {
      switch brainSnapshot.healthAndBackup {
      case .loaded(let health):
        healthInput = NotificationHealthEvaluationInput(
          freshness: .fresh,
          doctorFailureCount: health.doctorFailures.count,
          isBackupFailing: health.backupStatus?.needsAttention == true,
          isLiveBackupStalled: health.liveBackupProgress?.isStalled == true
        )
      case .failed:
        healthInput = NotificationHealthEvaluationInput(
          freshness: .degraded,
          doctorFailureCount: 0,
          isBackupFailing: false,
          isLiveBackupStalled: false
        )
      }
    }

    return NotificationEvaluationInput(
      providers: providerInputs,
      waitingFreshness: waitingFreshness,
      waitingCandidates: waitingCandidates,
      health: healthInput
    )
  }

  private static func makeProviderInput(
    from provider: ProviderUsage
  ) -> NotificationProviderEvaluationInput {
    let displayName = KnownProviderID(rawValue: provider.id)?.displayName ?? provider.name
    switch provider.sessionState {
    case .loading:
      return NotificationProviderEvaluationInput(
        providerID: provider.id,
        providerName: displayName,
        freshness: .uncollected,
        usableWindows: []
      )
    case .active:
      let windows = provider.limits.map { limit in
        NotificationQuotaWindowCandidate(
          limitID: limit.id,
          limitName: limit.name,
          limitDetail: limit.detail,
          remainingPercentage: limit.remainingPercentage
        )
      }
      return NotificationProviderEvaluationInput(
        providerID: provider.id,
        providerName: displayName,
        freshness: .fresh,
        usableWindows: windows
      )
    case .stale, .unavailable:
      return NotificationProviderEvaluationInput(
        providerID: provider.id,
        providerName: displayName,
        freshness: .degraded,
        usableWindows: []
      )
    }
  }

  private static func makeWaitingCandidates(
    from waiting: WaitingState
  ) -> [NotificationWaitingCandidate] {
    let promptCandidates = waiting.pendingPrompts.map { prompt in
      NotificationWaitingCandidate(
        targetName: prompt.sessionKey,
        kind: .pendingPrompt(hasButton: prompt.hasButton),
        additionalContextForPrivacyCheck: [prompt.project, prompt.text].compactMap { $0 }
      )
    }
    let mailCandidates = waiting.stuckMail.map { mailbox in
      NotificationWaitingCandidate(
        targetName: mailbox.recipient,
        kind: .stuckMailbox(unreadCount: mailbox.unreadCount),
        additionalContextForPrivacyCheck: mailbox.senders
      )
    }
    return promptCandidates + mailCandidates
  }
}
