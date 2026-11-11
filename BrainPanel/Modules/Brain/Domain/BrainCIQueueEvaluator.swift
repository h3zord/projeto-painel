import Foundation

nonisolated enum BrainCIQueueEvaluator {
  static let freshVMWindowSeconds: TimeInterval = 120
  static let recentAlertsWindowSeconds: TimeInterval = 86_400
  static let maxRecentRuns = 5

  struct RawInputs: Sendable {
    let versionData: Data?
    let pausedData: Data?
    let modeData: Data?
    let vmNowData: Data?
    let ticketPayloads: [(id: String, data: Data)]
    let runLines: [Substring]
    let alertLines: [Substring]
  }

  nonisolated private struct VersionRecord: Decodable {
    let version: Int?
    let since: Double?
  }

  nonisolated private struct PauseRecord: Decodable {
    let reason: String?
    let pid: Int32?
    let at: Double?

    enum CodingKeys: String, CodingKey {
      case reason
      case pid
      case at
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.reason = try container.decodeIfPresent(String.self, forKey: .reason)
      self.at = try container.decodeIfPresent(Double.self, forKey: .at)
      if let numericPID = try? container.decodeIfPresent(Int32.self, forKey: .pid) {
        self.pid = numericPID
      } else if let stringPID = try? container.decodeIfPresent(String.self, forKey: .pid),
        let parsed = Int32(stringPID)
      {
        self.pid = parsed
      } else {
        self.pid = nil
      }
    }
  }

  nonisolated private struct ModeRecord: Decodable {
    let mode: String?
    let reason: String?
    let until: Double?
  }

  nonisolated private struct VMNowRecord: Decodable {
    let at: Double?
    let available: Double?
  }

  nonisolated private struct TicketRecord: Decodable {
    let pid: Int32
    let project: String?
    let role: String?
    let session: String?
    let cmd: String?
    let commit: String?
    let queued: Double?
    let started: Double?
    let claimed: Double?
    let folder: String?
    let type: String?
    let durEst: Double?
    let memEst: Double?
    let solo: Bool?
    let waits: [String: Double]?

    enum CodingKeys: String, CodingKey {
      case pid
      case project
      case role
      case session
      case cmd
      case commit
      case queued
      case started
      case claimed
      case folder
      case type
      case durEst = "dur_est"
      case memEst = "mem_est"
      case solo
      case waits
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      if let numericPID = try? container.decode(Int32.self, forKey: .pid) {
        self.pid = numericPID
      } else {
        let stringPID = try container.decode(String.self, forKey: .pid)
        guard let parsed = Int32(stringPID) else {
          throw DecodingError.dataCorruptedError(
            forKey: .pid,
            in: container,
            debugDescription: "PID inválido"
          )
        }
        self.pid = parsed
      }
      self.project = try container.decodeIfPresent(String.self, forKey: .project)
      self.role = try container.decodeIfPresent(String.self, forKey: .role)
      self.session = try container.decodeIfPresent(String.self, forKey: .session)
      self.cmd = try container.decodeIfPresent(String.self, forKey: .cmd)
      self.commit = try container.decodeIfPresent(String.self, forKey: .commit)
      self.queued = try container.decodeIfPresent(Double.self, forKey: .queued)
      self.started = try container.decodeIfPresent(Double.self, forKey: .started)
      self.claimed = try container.decodeIfPresent(Double.self, forKey: .claimed)
      self.folder = try container.decodeIfPresent(String.self, forKey: .folder)
      self.type = try container.decodeIfPresent(String.self, forKey: .type)
      self.durEst = try container.decodeIfPresent(Double.self, forKey: .durEst)
      self.memEst = try container.decodeIfPresent(Double.self, forKey: .memEst)
      self.solo = try container.decodeIfPresent(Bool.self, forKey: .solo)
      self.waits = try container.decodeIfPresent([String: Double].self, forKey: .waits)
    }
  }

  nonisolated private struct RunRecord: Decodable {
    let kind: String?
    let queueVersion: Int?
    let project: String?
    let dir: String?
    let folder: String?
    let role: String?
    let type: String?
    let commit: String?
    let queued: Double?
    let start: Double?
    let end: Double?
    let exit: Int?
    let interrupted: Bool?

    enum CodingKeys: String, CodingKey {
      case kind
      case queueVersion = "queue_version"
      case project
      case dir
      case folder
      case role
      case type
      case commit
      case queued
      case start
      case end
      case exit
      case interrupted
    }
  }

  nonisolated private struct AlertRecord: Decodable {
    let at: Double?
    let project: String?
    let cmd: String?
    let alarm: String?
  }

  static func evaluate(
    inputs: RawInputs,
    now: Date,
    calendar: Calendar = .current,
    isProcessAlive: (Int32) -> Bool
  ) -> CIQueueState {
    let decoder = JSONDecoder()
    let nowEpoch = now.timeIntervalSince1970

    let versionRecord = inputs.versionData.flatMap {
      try? decoder.decode(VersionRecord.self, from: $0)
    }
    let activeQueueVersion = versionRecord?.version
    let versionSince = versionRecord?.since.map { Date(timeIntervalSince1970: $0) }

    let pauseState: CIQueuePauseState? = {
      guard
        let pausedData = inputs.pausedData,
        let record = try? decoder.decode(PauseRecord.self, from: pausedData)
      else {
        return nil
      }
      if let pid = record.pid, !isProcessAlive(pid) {
        return nil
      }
      let reason = BrainPrivacyGuard.sanitizeSingleLine(record.reason, maxLength: 200) ?? "pausada"
      return CIQueuePauseState(
        reason: reason,
        pid: record.pid,
        pausedAt: record.at.map { Date(timeIntervalSince1970: $0) }
      )
    }()

    let (isSerial, serialReason, serialUntil): (Bool, String?, Date?) = {
      guard
        let modeData = inputs.modeData,
        let record = try? decoder.decode(ModeRecord.self, from: modeData),
        record.mode == "serial"
      else {
        return (false, nil, nil)
      }
      if let untilEpoch = record.until, nowEpoch > untilEpoch {
        return (false, nil, nil)
      }
      return (
        true,
        BrainPrivacyGuard.sanitizeSingleLine(record.reason, maxLength: 200),
        record.until.map { Date(timeIntervalSince1970: $0) }
      )
    }()

    let (vmAvailableMB, vmMeasuredAt): (Double?, Date?) = {
      guard
        let vmData = inputs.vmNowData,
        let record = try? decoder.decode(VMNowRecord.self, from: vmData),
        let available = record.available,
        let measuredEpoch = record.at,
        nowEpoch - measuredEpoch < freshVMWindowSeconds
      else {
        return (nil, nil)
      }
      return (max(available, 0), Date(timeIntervalSince1970: measuredEpoch))
    }()

    var runningTickets: [CIQueueTicket] = []
    var waitingTickets: [CIQueueTicket] = []

    for (ticketID, payload) in inputs.ticketPayloads {
      guard
        let record = try? decoder.decode(TicketRecord.self, from: payload),
        isProcessAlive(record.pid)
      else {
        continue
      }

      let isCorporate = BrainPrivacyGuard.isCorporateScope(
        record.project,
        record.folder,
        record.session
      )
      let project =
        isCorporate
        ? BrainPrivacyGuard.corporateMarker
        : (BrainPrivacyGuard.sanitizeSingleLine(record.project, maxLength: 80) ?? "?")
      let command =
        isCorporate ? nil : BrainPrivacyGuard.sanitizeSingleLine(record.cmd, maxLength: 160)
      let commit =
        isCorporate ? nil : BrainPrivacyGuard.sanitizeSingleLine(record.commit, maxLength: 40)

      let primaryWait =
        record.waits?
        .max { lhs, rhs in
          if lhs.value != rhs.value {
            return lhs.value < rhs.value
          }
          return lhs.key > rhs.key
        }
        .flatMap { BrainPrivacyGuard.sanitizeSingleLine($0.key, maxLength: 80) }

      let activeStartEpoch = record.started ?? record.claimed
      let ticket = CIQueueTicket(
        id: ticketID,
        pid: record.pid,
        project: project,
        role: BrainPrivacyGuard.sanitizeSingleLine(record.role, maxLength: 32),
        jobType: BrainPrivacyGuard.sanitizeSingleLine(record.type, maxLength: 32),
        command: command,
        commit: commit,
        queuedAt: record.queued.map { Date(timeIntervalSince1970: $0) },
        startedAt: activeStartEpoch.map { Date(timeIntervalSince1970: $0) },
        estimatedDurationSeconds: record.durEst,
        estimatedMemoryMB: record.memEst,
        isSolo: record.solo ?? false,
        primaryWaitReason: primaryWait
      )

      if activeStartEpoch != nil {
        runningTickets.append(ticket)
      } else {
        waitingTickets.append(ticket)
      }
    }

    let startOfTodayEpoch = calendar.startOfDay(for: now).timeIntervalSince1970
    var todayTotal = 0
    var todayGreen = 0
    var parsedRuns: [CIRecentRun] = []

    for (lineOffset, line) in inputs.runLines.enumerated() {
      guard
        let record = try? decoder.decode(RunRecord.self, from: Data(line.utf8)),
        record.kind == "run",
        let endEpoch = record.end
      else {
        continue
      }
      if let activeQueueVersion, record.queueVersion != activeQueueVersion {
        continue
      }

      let isInterrupted = record.interrupted ?? false
      let isGreen = (record.exit == 0) && !isInterrupted

      if endEpoch >= startOfTodayEpoch {
        todayTotal += 1
        if isGreen {
          todayGreen += 1
        }
      }

      let isCorporate = BrainPrivacyGuard.isCorporateScope(
        record.project,
        record.dir,
        record.folder
      )
      let project =
        isCorporate
        ? BrainPrivacyGuard.corporateMarker
        : (BrainPrivacyGuard.sanitizeSingleLine(record.project, maxLength: 80) ?? "?")
      let shortCommit: String? =
        if isCorporate {
          nil
        } else if let clean = BrainPrivacyGuard.sanitizeSingleLine(record.commit, maxLength: 40) {
          String(clean.prefix(8))
        } else {
          nil
        }

      let startEpoch = record.start ?? endEpoch
      let queuedEpoch = record.queued ?? startEpoch

      parsedRuns.append(
        CIRecentRun(
          id: "run-\(lineOffset)-\(Int(endEpoch))",
          project: project,
          role: BrainPrivacyGuard.sanitizeSingleLine(record.role, maxLength: 32),
          jobType: BrainPrivacyGuard.sanitizeSingleLine(record.type, maxLength: 32),
          commit: shortCommit,
          exitCode: record.exit,
          isInterrupted: isInterrupted,
          endedAt: Date(timeIntervalSince1970: endEpoch),
          durationSeconds: max(endEpoch - startEpoch, 0),
          waitedSeconds: max(startEpoch - queuedEpoch, 0)
        )
      )
    }

    let recentRuns = Array(parsedRuns.suffix(maxRecentRuns).reversed())

    var recentAlerts: [CIQueueAlert] = []
    for (lineOffset, line) in inputs.alertLines.enumerated() {
      guard
        let record = try? decoder.decode(AlertRecord.self, from: Data(line.utf8)),
        let alertEpoch = record.at,
        nowEpoch - alertEpoch < recentAlertsWindowSeconds
      else {
        continue
      }

      let isCorporate = BrainPrivacyGuard.isCorporateScope(record.project, record.cmd)
      let project =
        isCorporate
        ? BrainPrivacyGuard.corporateMarker
        : (BrainPrivacyGuard.sanitizeSingleLine(record.project, maxLength: 80) ?? "?")
      let alarm =
        isCorporate
        ? "alerta da fila"
        : (BrainPrivacyGuard.sanitizeSingleLine(record.alarm, maxLength: 400) ?? "alerta da fila")

      recentAlerts.append(
        CIQueueAlert(
          id: "alert-\(lineOffset)-\(Int(alertEpoch))",
          project: project,
          alarm: alarm,
          alertedAt: Date(timeIntervalSince1970: alertEpoch)
        )
      )
    }
    recentAlerts.reverse()

    return CIQueueState(
      queueVersion: activeQueueVersion,
      versionSince: versionSince,
      pauseState: pauseState,
      isSerial: isSerial,
      serialReason: serialReason,
      serialUntil: serialUntil,
      vmAvailableMB: vmAvailableMB,
      vmMeasuredAt: vmMeasuredAt,
      runningTickets: runningTickets,
      waitingTickets: waitingTickets,
      todaySummary: CITodaySummary(totalCount: todayTotal, greenCount: todayGreen),
      recentRuns: recentRuns,
      recentAlerts: recentAlerts
    )
  }
}
