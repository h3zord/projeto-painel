import Foundation

nonisolated enum BrainScheduledJobsEvaluator {
  static let friendlyTitles: [String: String] = [
    "com.lucas.brain-sync": "Sync do Brain para o GitHub",
    "com.lucas.brain-backup": "Backup criptografado no Drive",
    "com.lucas.brain-weekly": "Semanal: mutação dos projetos",
    "com.lucas.brain-watch": "Vigia dos projetos",
    "com.lucas.brain-pages": "Painel web (brain-pages)",
    "com.lucas.awake": "Awake: Mac acordado com trabalho",
    "com.lucas.globalhotkeys": "Atalhos globais do teclado",
    "com.lucas.brain-panel": "Brain Panel (barra de menus)",
  ]

  struct PlistCandidate: Sendable {
    let fallbackLabel: String
    let plistData: Data
  }

  struct RawInputs: Sendable {
    let plists: [PlistCandidate]
    let launchctlListOutput: String
    let syncStateData: Data?
    let backupStateData: Data?
    let weeklyStateData: Data?
    let faxinaData: Data?
    let rehearseStateData: Data?
    let isActivelyBackingUp: Bool
  }

  nonisolated private struct CalendarSlot {
    let weekday: Int?
    let hour: Int
    let minute: Int
  }

  nonisolated private struct LaunchctlEntry {
    let pid: Int32?
    let lastExitStatus: Int?
  }

  nonisolated private struct SimpleStateRecord: Decodable {
    let result: String?
    let at: Double?
  }

  nonisolated private struct WeeklyJobRecord: Decodable {
    let exit: Int?
  }

  nonisolated private struct WeeklyStateRecord: Decodable {
    let at: Double?
    let jobs: [WeeklyJobRecord]?
  }

  nonisolated private struct FaxinaRecord: Decodable {
    let at: Double?
  }

  nonisolated private struct RehearseStateRecord: Decodable {
    let result: String?
    let at: Double?
    let restored: Int?
    let expected: Int?
  }

  static func evaluate(
    inputs: RawInputs,
    now: Date,
    calendar: Calendar = .current
  ) -> ScheduledJobsState {
    let decoder = JSONDecoder()
    let launchctlEntries = parseLaunchctlList(inputs.launchctlListOutput)

    let syncRecord = inputs.syncStateData.flatMap {
      try? decoder.decode(SimpleStateRecord.self, from: $0)
    }
    let backupRecord = inputs.backupStateData.flatMap {
      try? decoder.decode(SimpleStateRecord.self, from: $0)
    }
    let weeklyRecord = inputs.weeklyStateData.flatMap {
      try? decoder.decode(WeeklyStateRecord.self, from: $0)
    }

    var jobs: [ScheduledJob] = []

    for candidate in inputs.plists {
      guard
        let rawPlist = try? PropertyListSerialization.propertyList(
          from: candidate.plistData,
          options: [],
          format: nil
        ),
        let dict = rawPlist as? [String: Any]
      else {
        continue
      }

      let rawLabel = (dict["Label"] as? String) ?? candidate.fallbackLabel
      guard let label = BrainPrivacyGuard.sanitizeSingleLine(rawLabel, maxLength: 120) else {
        continue
      }

      let title = friendlyTitles[label] ?? label
      let (rawSchedule, nextRunAt) = describeSchedule(
        plist: dict,
        now: now,
        calendar: calendar
      )
      let scheduleSummary =
        (label == "com.lucas.brain-weekly") ? "domingo de madrugada" : rawSchedule

      let stateOutcome = stateOutcome(
        for: label,
        syncRecord: syncRecord,
        backupRecord: backupRecord,
        weeklyRecord: weeklyRecord
      )

      let entry = launchctlEntries[label]
      let isRunning =
        (entry?.pid != nil)
        || (label == "com.lucas.brain-backup" && inputs.isActivelyBackingUp)

      let status: ScheduledJobStatus
      if isRunning {
        status = .running
      } else if entry == nil {
        status = .unloaded
      } else if let exitCode = entry?.lastExitStatus, exitCode != 0, stateOutcome == nil {
        status = .exitedWithError(exitCode)
      } else if let stateOutcome {
        status = stateOutcome.isPassing ? .succeeded : .failed
      } else {
        status = .loadedIdle
      }

      jobs.append(
        ScheduledJob(
          label: label,
          title: title,
          scheduleSummary: scheduleSummary,
          status: status,
          lastRunAt: stateOutcome?.ranAt,
          nextRunAt: nextRunAt
        )
      )
    }

    let weeklyCleanupAt: Date? = {
      guard
        let data = inputs.faxinaData,
        let record = try? decoder.decode(FaxinaRecord.self, from: data),
        let at = record.at
      else {
        return nil
      }
      return Date(timeIntervalSince1970: at)
    }()

    let restoreRehearsal: RestoreRehearsalStatus? = {
      guard
        let data = inputs.rehearseStateData,
        let record = try? decoder.decode(RehearseStateRecord.self, from: data),
        let at = record.at
      else {
        return nil
      }
      return RestoreRehearsalStatus(
        isPassing: record.result == "ok",
        ranAt: Date(timeIntervalSince1970: at),
        restoredCount: record.restored,
        expectedCount: record.expected
      )
    }()

    return ScheduledJobsState(
      jobs: jobs,
      weeklyCleanupAt: weeklyCleanupAt,
      restoreRehearsal: restoreRehearsal
    )
  }

  private static func parseLaunchctlList(_ output: String) -> [String: LaunchctlEntry] {
    var result: [String: LaunchctlEntry] = [:]
    for line in output.split(whereSeparator: \.isNewline) {
      let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard columns.count == 3 else { continue }
      let label = String(columns[2]).trimmingCharacters(in: .whitespaces)
      guard label.hasPrefix("com.lucas.") else { continue }

      let rawPID = String(columns[0]).trimmingCharacters(in: .whitespaces)
      let pid: Int32? = (rawPID == "-" || rawPID.isEmpty) ? nil : Int32(rawPID)
      let lastExitStatus = Int(String(columns[1]).trimmingCharacters(in: .whitespaces))
      result[label] = LaunchctlEntry(pid: pid, lastExitStatus: lastExitStatus)
    }
    return result
  }

  private static func describeSchedule(
    plist: [String: Any],
    now: Date,
    calendar: Calendar
  ) -> (String, Date?) {
    if isKeepAliveEnabled(plist["KeepAlive"]) {
      return ("sempre ligado", nil)
    }
    if let rawCalendar = plist["StartCalendarInterval"] {
      let slots = parseCalendarSlots(rawCalendar)
      if let first = slots.first {
        let summary = String(format: "todo dia %02d:%02d", first.hour, first.minute)
        let next = nextOccurrence(for: slots, after: now, calendar: calendar)
        return (summary, next)
      }
    }
    if let interval = plist["StartInterval"] as? Int, interval > 0 {
      if interval >= 3_600 {
        return ("a cada \(interval / 3_600) h", nil)
      }
      return ("a cada \(max(1, interval / 60)) min", nil)
    }
    return ("ao entrar", nil)
  }

  private static func isKeepAliveEnabled(_ value: Any?) -> Bool {
    if let flag = value as? Bool {
      return flag
    }
    if let dict = value as? [String: Any] {
      return !dict.isEmpty
    }
    return false
  }

  private static func parseCalendarSlots(_ raw: Any) -> [CalendarSlot] {
    let dictionaries: [[String: Any]]
    if let single = raw as? [String: Any] {
      dictionaries = [single]
    } else if let multiple = raw as? [[String: Any]] {
      dictionaries = multiple
    } else {
      return []
    }

    return dictionaries.map { item in
      CalendarSlot(
        weekday: item["Weekday"] as? Int,
        hour: min(max((item["Hour"] as? Int) ?? 0, 0), 23),
        minute: min(max((item["Minute"] as? Int) ?? 0, 0), 59)
      )
    }
  }

  private static func nextOccurrence(
    for slots: [CalendarSlot],
    after now: Date,
    calendar: Calendar
  ) -> Date? {
    let startOfToday = calendar.startOfDay(for: now)
    var earliest: Date?

    for slot in slots {
      for dayOffset in 0..<8 {
        guard let dayDate = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday) else {
          continue
        }
        if let targetWeekday = slot.weekday {
          // launchd: 0 ou 7 = domingo, 1 = segunda ... 6 = sábado
          // Calendar gregoriano: 1 = domingo, 2 = segunda ... 7 = sábado
          let calendarZeroBasedWeekday = (calendar.component(.weekday, from: dayDate) - 1) % 7
          let normalizedTarget = ((targetWeekday % 7) + 7) % 7
          if calendarZeroBasedWeekday != normalizedTarget {
            continue
          }
        }
        guard
          let candidate = calendar.date(
            bySettingHour: slot.hour,
            minute: slot.minute,
            second: 0,
            of: dayDate
          ),
          candidate > now
        else {
          continue
        }
        if let currentBest = earliest {
          earliest = min(currentBest, candidate)
        } else {
          earliest = candidate
        }
        break
      }
    }

    return earliest
  }

  private static func stateOutcome(
    for label: String,
    syncRecord: SimpleStateRecord?,
    backupRecord: SimpleStateRecord?,
    weeklyRecord: WeeklyStateRecord?
  ) -> (isPassing: Bool, ranAt: Date)? {
    switch label {
    case "com.lucas.brain-sync":
      guard let at = syncRecord?.at else { return nil }
      return (syncRecord?.result == "ok", Date(timeIntervalSince1970: at))
    case "com.lucas.brain-backup":
      guard let at = backupRecord?.at else { return nil }
      return (backupRecord?.result == "ok", Date(timeIntervalSince1970: at))
    case "com.lucas.brain-weekly":
      guard let at = weeklyRecord?.at else { return nil }
      let jobs = weeklyRecord?.jobs ?? []
      let allSucceeded = jobs.allSatisfy { ($0.exit ?? -1) == 0 }
      return (allSucceeded, Date(timeIntervalSince1970: at))
    default:
      return nil
    }
  }
}
