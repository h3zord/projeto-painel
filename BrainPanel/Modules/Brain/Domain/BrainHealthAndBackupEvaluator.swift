import Foundation

nonisolated enum BrainHealthAndBackupEvaluator {
  static let backupOverdueThresholdSeconds: TimeInterval = 2 * 86_400
  static let stalledBackupThresholdSeconds: TimeInterval = 60

  struct RawInputs: Sendable {
    let doctorStateData: Data?
    let doctorModifiedAt: Date?
    let testStateData: Data?
    let syncStateData: Data?
    let backupStateData: Data?
    let liveBackupProgressData: Data?
  }

  nonisolated private struct DoctorStateRecord: Decodable {
    let keys: [String: String]?
  }

  nonisolated private struct TestStateRecord: Decodable {
    let result: String?
    let failed: [String]?
    let ran: Int?
    let at: Double?
  }

  nonisolated private struct SyncStateRecord: Decodable {
    let result: String?
    let reason: String?
    let at: Double?
    let sha: String?
  }

  nonisolated private struct BackupStateRecord: Decodable {
    let result: String?
    let reason: String?
    let at: Double?
    let snapshot: String?
    let added: Int64?
    let files: Int?
  }

  nonisolated private struct LiveBackupRecord: Decodable {
    let fase: String?
    let inicio: Double?
    let at: Double?
    let pct: Double?
    let feito: Int64?
    let total: Int64?
    let restante: Int?
    let erros: Int?
    let pasta: String?
  }

  static func evaluate(inputs: RawInputs, now: Date) -> HealthAndBackupState {
    let decoder = JSONDecoder()
    let nowEpoch = now.timeIntervalSince1970

    var doctorFailures: [DoctorFinding] = []
    var doctorWarnings: [DoctorFinding] = []

    if let doctorData = inputs.doctorStateData,
      let record = try? decoder.decode(DoctorStateRecord.self, from: doctorData),
      let entries = record.keys
    {
      for key in entries.keys.sorted() {
        let rawLine = entries[key] ?? key
        let isFailure = rawLine.hasPrefix("FAIL") || key.hasPrefix("FAIL")
        let stripped = stripDoctorPrefix(rawLine)
        let cleanMessage =
          BrainPrivacyGuard.sanitizeSingleLine(stripped, maxLength: 300) ?? key
        let finding = DoctorFinding(
          key: key,
          severity: isFailure ? .fail : .warn,
          message: cleanMessage
        )
        if isFailure {
          doctorFailures.append(finding)
        } else {
          doctorWarnings.append(finding)
        }
      }
    }

    let testSuite: TestSuiteStatus? = {
      guard
        let data = inputs.testStateData,
        let record = try? decoder.decode(TestStateRecord.self, from: data)
      else {
        return nil
      }
      let failed = (record.failed ?? []).compactMap {
        BrainPrivacyGuard.sanitizeSingleLine($0, maxLength: 120)
      }
      return TestSuiteStatus(
        isPassing: record.result == "ok",
        ranCount: max(record.ran ?? 0, 0),
        failedTests: Array(failed.prefix(10)),
        ranAt: record.at.map { Date(timeIntervalSince1970: $0) }
      )
    }()

    let syncStatus: SyncStatus? = {
      guard
        let data = inputs.syncStateData,
        let record = try? decoder.decode(SyncStateRecord.self, from: data)
      else {
        return nil
      }
      return SyncStatus(
        isPassing: record.result == "ok",
        reason: BrainPrivacyGuard.sanitizeSingleLine(record.reason, maxLength: 240),
        syncedAt: record.at.map { Date(timeIntervalSince1970: $0) },
        commitSHA: BrainPrivacyGuard.sanitizeSingleLine(record.sha, maxLength: 40)
      )
    }()

    let backupStatus: BackupStatus? = {
      guard
        let data = inputs.backupStateData,
        let record = try? decoder.decode(BackupStateRecord.self, from: data)
      else {
        return nil
      }
      let isPassing = record.result == "ok"
      let isOverdue: Bool =
        if let completedEpoch = record.at {
          (nowEpoch - completedEpoch) > backupOverdueThresholdSeconds
        } else {
          false
        }
      return BackupStatus(
        isPassing: isPassing,
        isOverdue: isOverdue,
        reason: BrainPrivacyGuard.sanitizeSingleLine(record.reason, maxLength: 240),
        completedAt: record.at.map { Date(timeIntervalSince1970: $0) },
        snapshotID: BrainPrivacyGuard.sanitizeSingleLine(record.snapshot, maxLength: 40),
        addedBytes: record.added,
        filesCount: record.files
      )
    }()

    let liveBackupProgress: LiveBackupProgress? = {
      guard
        let data = inputs.liveBackupProgressData,
        let record = try? decoder.decode(LiveBackupRecord.self, from: data),
        let phase = BrainPrivacyGuard.sanitizeSingleLine(record.fase, maxLength: 40),
        phase != "fim"
      else {
        return nil
      }
      let heartbeatEpoch = record.at ?? 0
      let isStalled = (nowEpoch - heartbeatEpoch) > stalledBackupThresholdSeconds
      let processed = max(record.feito ?? 0, 0)
      let total = max(record.total ?? 0, processed)
      let clampedFraction = min(max(record.pct ?? 0, 0), 1)
      let safeFolder: String? =
        if BrainPrivacyGuard.isCorporateScope(record.pasta) {
          BrainPrivacyGuard.corporateMarker
        } else {
          BrainPrivacyGuard.sanitizeSingleLine(record.pasta, maxLength: 160)
        }

      return LiveBackupProgress(
        phase: phase,
        startedAt: record.inicio.map { Date(timeIntervalSince1970: $0) },
        heartbeatAt: record.at.map { Date(timeIntervalSince1970: $0) },
        fractionCompleted: clampedFraction,
        processedBytes: processed,
        totalBytes: total,
        estimatedRemainingSeconds: record.restante,
        errorCount: max(record.erros ?? 0, 0),
        currentFolder: safeFolder,
        isStalled: isStalled
      )
    }()

    return HealthAndBackupState(
      doctorFailures: doctorFailures,
      doctorWarnings: doctorWarnings,
      doctorCheckedAt: inputs.doctorModifiedAt,
      testSuite: testSuite,
      syncStatus: syncStatus,
      backupStatus: backupStatus,
      liveBackupProgress: liveBackupProgress
    )
  }

  private static func stripDoctorPrefix(_ raw: String) -> String {
    let prefixRegex = #/^(?:FAIL|WARN)\s+\d+\s+/#
    return raw.replacing(prefixRegex, with: "")
  }
}
