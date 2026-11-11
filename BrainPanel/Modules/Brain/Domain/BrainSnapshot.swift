import Foundation

nonisolated enum BrainSectionState<Value: Equatable & Sendable>: Equatable, Sendable {
  case loaded(Value)
  case failed(AppError)

  var value: Value? {
    guard case .loaded(let val) = self else { return nil }
    return val
  }

  var error: AppError? {
    guard case .failed(let err) = self else { return nil }
    return err
  }

  var isFailed: Bool {
    error != nil
  }
}

/// Guarda central de privacidade corporativa (`flexograv`): nenhum comando, commit, texto livre ou caminho
/// de projeto corporativo pode atravessar para o modelo de domínio exibido no painel.
nonisolated enum BrainPrivacyGuard {
  static let corporateMarker = "flexograv"

  static func isCorporateScope(_ candidates: String?...) -> Bool {
    candidates.contains { candidate in
      guard let candidate, !candidate.isEmpty else { return false }
      return candidate.localizedStandardContains(corporateMarker)
    }
  }

  static func sanitizeSingleLine(_ raw: String?, maxLength: Int = 400) -> String? {
    guard let raw else { return nil }
    let cleaned =
      raw
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .filter { char in
        char.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
      }
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return nil }
    if cleaned.count > maxLength {
      return String(cleaned.prefix(maxLength))
    }
    return cleaned
  }
}

// MARK: - 1. Esperando Você

nonisolated struct PendingPrompt: Identifiable, Equatable, Sendable {
  var id: String { sessionKey }
  let sessionKey: String
  let askedAt: Date
  let text: String?
  let isExplicit: Bool
  let hasButton: Bool

  func elapsedSummary(now: Date) -> String {
    RelativeTimeFormatter.elapsedPhrase(since: askedAt, now: now)
  }
}

nonisolated struct StuckMailbox: Identifiable, Equatable, Sendable {
  var id: String { recipient }
  let recipient: String
  let unreadCount: Int
  let oldestMessageAt: Date
  let senders: [String]

  func elapsedSummary(now: Date) -> String {
    RelativeTimeFormatter.elapsedPhrase(since: oldestMessageAt, now: now)
  }
}

nonisolated struct ClosedMailbox: Identifiable, Equatable, Sendable {
  var id: String { recipient }
  let recipient: String
  let unreadCount: Int
}

nonisolated struct WaitingState: Equatable, Sendable {
  static let empty = WaitingState(pendingPrompts: [], stuckMail: [], closedMail: [])

  let pendingPrompts: [PendingPrompt]
  let stuckMail: [StuckMailbox]
  let closedMail: [ClosedMailbox]

  var waitingOnOwnerCount: Int {
    pendingPrompts.count + stuckMail.count
  }
}

// MARK: - 2. Fila da Máquina

nonisolated struct CIQueuePauseState: Equatable, Sendable {
  let reason: String
  let pid: Int32?
  let pausedAt: Date?
}

nonisolated struct CIQueueTicket: Identifiable, Equatable, Sendable {
  let id: String
  let pid: Int32
  let project: String
  let role: String?
  let jobType: String?
  let command: String?
  let commit: String?
  let queuedAt: Date?
  let startedAt: Date?
  let estimatedDurationSeconds: Double?
  let estimatedMemoryMB: Double?
  let isSolo: Bool
  let primaryWaitReason: String?
}

nonisolated struct CITodaySummary: Equatable, Sendable {
  static let empty = CITodaySummary(totalCount: 0, greenCount: 0)

  let totalCount: Int
  let greenCount: Int

  var nonGreenCount: Int {
    max(totalCount - greenCount, 0)
  }
}

nonisolated struct CIRecentRun: Identifiable, Equatable, Sendable {
  let id: String
  let project: String
  let role: String?
  let jobType: String?
  let commit: String?
  let exitCode: Int?
  let isInterrupted: Bool
  let endedAt: Date
  let durationSeconds: Double
  let waitedSeconds: Double

  var isGreen: Bool {
    exitCode == 0 && !isInterrupted
  }
}

nonisolated struct CIQueueAlert: Identifiable, Equatable, Sendable {
  let id: String
  let project: String
  let alarm: String
  let alertedAt: Date
}

nonisolated struct CIQueueState: Equatable, Sendable {
  static let empty = CIQueueState(
    queueVersion: nil,
    versionSince: nil,
    pauseState: nil,
    isSerial: false,
    serialReason: nil,
    serialUntil: nil,
    vmAvailableMB: nil,
    vmMeasuredAt: nil,
    runningTickets: [],
    waitingTickets: [],
    todaySummary: .empty,
    recentRuns: [],
    recentAlerts: []
  )

  let queueVersion: Int?
  let versionSince: Date?
  let pauseState: CIQueuePauseState?
  let isSerial: Bool
  let serialReason: String?
  let serialUntil: Date?
  let vmAvailableMB: Double?
  let vmMeasuredAt: Date?
  let runningTickets: [CIQueueTicket]
  let waitingTickets: [CIQueueTicket]
  let todaySummary: CITodaySummary
  let recentRuns: [CIRecentRun]
  let recentAlerts: [CIQueueAlert]
}

// MARK: - 3. Saúde & Backup

nonisolated enum DoctorFindingSeverity: Equatable, Sendable {
  case fail
  case warn
}

nonisolated struct DoctorFinding: Identifiable, Equatable, Sendable {
  var id: String { key }
  let key: String
  let severity: DoctorFindingSeverity
  let message: String
}

nonisolated struct TestSuiteStatus: Equatable, Sendable {
  let isPassing: Bool
  let ranCount: Int
  let failedTests: [String]
  let ranAt: Date?
}

nonisolated struct SyncStatus: Equatable, Sendable {
  let isPassing: Bool
  let reason: String?
  let syncedAt: Date?
  let commitSHA: String?
}

nonisolated struct BackupStatus: Equatable, Sendable {
  let isPassing: Bool
  let isOverdue: Bool
  let reason: String?
  let completedAt: Date?
  let snapshotID: String?
  let addedBytes: Int64?
  let filesCount: Int?

  var needsAttention: Bool {
    !isPassing || isOverdue
  }
}

nonisolated struct LiveBackupProgress: Equatable, Sendable {
  let phase: String
  let startedAt: Date?
  let heartbeatAt: Date?
  let fractionCompleted: Double
  let processedBytes: Int64
  let totalBytes: Int64
  let estimatedRemainingSeconds: Int?
  let errorCount: Int
  let currentFolder: String?
  let isStalled: Bool
}

nonisolated struct HealthAndBackupState: Equatable, Sendable {
  static let empty = HealthAndBackupState(
    doctorFailures: [],
    doctorWarnings: [],
    doctorCheckedAt: nil,
    testSuite: nil,
    syncStatus: nil,
    backupStatus: nil,
    liveBackupProgress: nil
  )

  let doctorFailures: [DoctorFinding]
  let doctorWarnings: [DoctorFinding]
  let doctorCheckedAt: Date?
  let testSuite: TestSuiteStatus?
  let syncStatus: SyncStatus?
  let backupStatus: BackupStatus?
  let liveBackupProgress: LiveBackupProgress?

  var isActivelyBackingUp: Bool {
    guard let liveBackupProgress else { return false }
    return !liveBackupProgress.isStalled
  }
}

// MARK: - 4. Jobs Agendados

nonisolated enum ScheduledJobStatus: Equatable, Sendable {
  case running
  case succeeded
  case failed
  case exitedWithError(Int)
  case loadedIdle
  case unloaded
}

nonisolated struct ScheduledJob: Identifiable, Equatable, Sendable {
  var id: String { label }
  let label: String
  let title: String
  let scheduleSummary: String
  let status: ScheduledJobStatus
  let lastRunAt: Date?
  let nextRunAt: Date?
}

nonisolated struct RestoreRehearsalStatus: Equatable, Sendable {
  let isPassing: Bool
  let ranAt: Date
  let restoredCount: Int?
  let expectedCount: Int?
}

nonisolated struct ScheduledJobsState: Equatable, Sendable {
  static let empty = ScheduledJobsState(jobs: [], weeklyCleanupAt: nil, restoreRehearsal: nil)

  let jobs: [ScheduledJob]
  let weeklyCleanupAt: Date?
  let restoreRehearsal: RestoreRehearsalStatus?
}

// MARK: - Snapshot Agregado

nonisolated struct BrainSnapshot: Equatable, Sendable {
  static let empty = BrainSnapshot(
    waiting: .loaded(.empty),
    ciQueue: .loaded(.empty),
    healthAndBackup: .loaded(.empty),
    scheduledJobs: .loaded(.empty),
    capturedAt: nil
  )

  let waiting: BrainSectionState<WaitingState>
  let ciQueue: BrainSectionState<CIQueueState>
  let healthAndBackup: BrainSectionState<HealthAndBackupState>
  let scheduledJobs: BrainSectionState<ScheduledJobsState>
  let capturedAt: Date?

  var waitingOnOwnerCount: Int {
    waiting.value?.waitingOnOwnerCount ?? 0
  }

  var hasCriticalFailure: Bool {
    if let health = healthAndBackup.value {
      if !health.doctorFailures.isEmpty { return true }
      if health.testSuite?.isPassing == false { return true }
      if health.syncStatus?.isPassing == false { return true }
      if health.backupStatus?.needsAttention == true { return true }
      if health.liveBackupProgress?.isStalled == true { return true }
    }
    if let scheduled = scheduledJobs.value {
      if scheduled.restoreRehearsal?.isPassing == false { return true }
      for job in scheduled.jobs {
        switch job.status {
        case .failed, .exitedWithError:
          return true
        case .running, .succeeded, .loadedIdle, .unloaded:
          break
        }
      }
    }
    return false
  }

  var degradedSections: [KnownBrainSection] {
    var result: [KnownBrainSection] = []
    if waiting.isFailed { result.append(.waiting) }
    if ciQueue.isFailed { result.append(.ciQueue) }
    if healthAndBackup.isFailed { result.append(.healthAndBackup) }
    if scheduledJobs.isFailed { result.append(.scheduledJobs) }
    return result
  }

  var needsAttentionBanner: Bool {
    hasCriticalFailure || waitingOnOwnerCount > 0
  }

  static func makePreviewData(now: Date) -> BrainSnapshot {
    BrainSnapshot(
      waiting: .loaded(
        WaitingState(
          pendingPrompts: [
            PendingPrompt(
              sessionKey: "painel-lead",
              askedAt: now.addingTimeInterval(-14 * 60),
              text: "Aprovar layout da aba Brain antes do merge?",
              isExplicit: true,
              hasButton: true
            )
          ],
          stuckMail: [
            StuckMailbox(
              recipient: "caixa-lead",
              unreadCount: 2,
              oldestMessageAt: now.addingTimeInterval(-42 * 60),
              senders: ["caixa-dev"]
            )
          ],
          closedMail: [
            ClosedMailbox(recipient: "sitio-dev", unreadCount: 1)
          ]
        )
      ),
      ciQueue: .loaded(
        CIQueueState(
          queueVersion: 4,
          versionSince: now.addingTimeInterval(-7 * 86_400),
          pauseState: nil,
          isSerial: false,
          serialReason: nil,
          serialUntil: nil,
          vmAvailableMB: 10_240,
          vmMeasuredAt: now.addingTimeInterval(-20),
          runningTickets: [
            CIQueueTicket(
              id: "01-running",
              pid: 41_010,
              project: "projeto-painel",
              role: "dev",
              jobType: "ci",
              command: "make ci",
              commit: "87b31d0",
              queuedAt: now.addingTimeInterval(-25),
              startedAt: now.addingTimeInterval(-22),
              estimatedDurationSeconds: 40,
              estimatedMemoryMB: 2_048,
              isSolo: false,
              primaryWaitReason: nil
            )
          ],
          waitingTickets: [],
          todaySummary: CITodaySummary(totalCount: 6, greenCount: 6),
          recentRuns: [
            CIRecentRun(
              id: "run-1",
              project: "projeto-painel",
              role: "dev",
              jobType: "mutation",
              commit: "01aed716",
              exitCode: 0,
              isInterrupted: false,
              endedAt: now.addingTimeInterval(-15 * 60),
              durationSeconds: 240,
              waitedSeconds: 1
            )
          ],
          recentAlerts: []
        )
      ),
      healthAndBackup: .loaded(
        HealthAndBackupState(
          doctorFailures: [],
          doctorWarnings: [
            DoctorFinding(
              key: "WARN 23",
              severity: .warn,
              message: "orçamento: índice próximo de 160 linhas"
            )
          ],
          doctorCheckedAt: now.addingTimeInterval(-8 * 60),
          testSuite: TestSuiteStatus(
            isPassing: true,
            ranCount: 414,
            failedTests: [],
            ranAt: now.addingTimeInterval(-25 * 60)
          ),
          syncStatus: SyncStatus(
            isPassing: true,
            reason: nil,
            syncedAt: now.addingTimeInterval(-12 * 60),
            commitSHA: "8267b37"
          ),
          backupStatus: BackupStatus(
            isPassing: true,
            isOverdue: false,
            reason: nil,
            completedAt: now.addingTimeInterval(-6 * 3_600),
            snapshotID: "a1b2c3d4",
            addedBytes: 42_500_000,
            filesCount: 1_240
          ),
          liveBackupProgress: nil
        )
      ),
      scheduledJobs: .loaded(
        ScheduledJobsState(
          jobs: [
            ScheduledJob(
              label: "com.lucas.awake",
              title: "Awake: Mac acordado com trabalho",
              scheduleSummary: "sempre ligado",
              status: .running,
              lastRunAt: nil,
              nextRunAt: nil
            ),
            ScheduledJob(
              label: "com.lucas.brain-sync",
              title: "Sync do Brain para o GitHub",
              scheduleSummary: "a cada 1 h",
              status: .succeeded,
              lastRunAt: now.addingTimeInterval(-12 * 60),
              nextRunAt: nil
            ),
            ScheduledJob(
              label: "com.lucas.brain-backup",
              title: "Backup criptografado no Drive",
              scheduleSummary: "todo dia 03:30",
              status: .succeeded,
              lastRunAt: now.addingTimeInterval(-6 * 3_600),
              nextRunAt: now.addingTimeInterval(18 * 3_600)
            ),
          ],
          weeklyCleanupAt: now.addingTimeInterval(-2 * 86_400),
          restoreRehearsal: RestoreRehearsalStatus(
            isPassing: true,
            ranAt: now.addingTimeInterval(-3 * 86_400),
            restoredCount: 40,
            expectedCount: 40
          )
        )
      ),
      capturedAt: now
    )
  }
}
