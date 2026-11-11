import Darwin
import Foundation

/// Coleta em modo estritamente somente-leitura os 4 blocos operacionais do ecossistema Brain,
/// isolando falhas de permissão/I/O por seção para manter os demais blocos disponíveis.
nonisolated struct BrainStateCollector: BrainStateCollecting {
  static let maxSmallFileBytes = 65_536
  static let runsTailBytes = 512 * 1_024
  static let alertsTailBytes = 128 * 1_024

  nonisolated private struct PendingTranscriptPointer: Decodable {
    let transcript: String?
  }

  let brainPendingDirectory: URL
  let brainMailDirectory: URL
  let brainSessionsDirectory: URL
  let claudeSessionsDirectory: URL
  let brainCIDirectory: URL
  let brainWeeklyDirectory: URL
  let logsDirectory: URL
  let launchAgentsDirectory: URL
  let backupProgressFileURL: URL
  private let clock: any Clock
  private let calendar: Calendar
  private let launchctlRunner: any LaunchctlRunning
  private let processAliveChecker: @Sendable (Int32) -> Bool

  init(
    config: AppConfig,
    clock: any Clock = SystemClock(),
    calendar: Calendar = .current,
    launchctlRunner: any LaunchctlRunning = ProcessLaunchctlRunner(),
    isProcessAlive: @escaping @Sendable (Int32) -> Bool = Self.isProcessAlive
  ) {
    self.brainPendingDirectory = config.brainPendingStateDirectory
    self.brainMailDirectory = config.brainMailStateDirectory
    self.brainSessionsDirectory = config.brainSessionsStateDirectory
    self.claudeSessionsDirectory = config.claudeSessionsDirectory
    self.brainCIDirectory = config.brainCIStateDirectory
    self.brainWeeklyDirectory = config.brainWeeklyStateDirectory
    self.logsDirectory = config.logsDirectory
    self.launchAgentsDirectory = config.launchAgentsDirectory
    self.backupProgressFileURL = config.backupProgressFileURL
    self.clock = clock
    self.calendar = calendar
    self.launchctlRunner = launchctlRunner
    self.processAliveChecker = isProcessAlive
  }

  static func isProcessAlive(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    if Darwin.kill(pid, 0) == 0 {
      return true
    }
    return errno == EPERM
  }

  @concurrent
  func fetchBrainState() async throws -> BrainSnapshot {
    let now = clock.now()
    let waiting = Self.collectSection(.waiting) {
      try collectWaiting(now: now)
    }
    let ciQueue = Self.collectSection(.ciQueue) {
      try collectCIQueue(now: now)
    }
    let healthAndBackup = Self.collectSection(.healthAndBackup) {
      try collectHealthAndBackup(now: now)
    }
    let isActivelyBackingUp = healthAndBackup.value?.isActivelyBackingUp ?? false
    let scheduledJobs = Self.collectSection(.scheduledJobs) {
      try collectScheduledJobs(now: now, isActivelyBackingUp: isActivelyBackingUp)
    }

    return BrainSnapshot(
      waiting: waiting,
      ciQueue: ciQueue,
      healthAndBackup: healthAndBackup,
      scheduledJobs: scheduledJobs,
      capturedAt: now
    )
  }

  // MARK: - 1. Esperando Você

  private func collectWaiting(now: Date) throws(AppError) -> WaitingState {
    let decoder = JSONDecoder()
    let pendingFiles = try Self.listDirectory(brainPendingDirectory, section: .waiting)
      .filter { $0.pathExtension == "json" }

    var pendingCandidates: [BrainWaitingEvaluator.PendingCandidate] = []
    pendingCandidates.reserveCapacity(pendingFiles.count)

    for fileURL in pendingFiles {
      guard let data = Self.readOptionalSmallFileData(at: fileURL) else {
        continue
      }
      let pointer = try? decoder.decode(PendingTranscriptPointer.self, from: data)
      let transcriptMtime = Self.safeTranscriptModifiedAt(path: pointer?.transcript)
      pendingCandidates.append(
        BrainWaitingEvaluator.PendingCandidate(
          jsonData: data,
          transcriptModifiedAt: transcriptMtime
        )
      )
    }

    let recipientDirs = try Self.listDirectory(
      brainMailDirectory,
      section: .waiting,
      keys: [.isDirectoryKey]
    )
    var mailboxes: [BrainWaitingEvaluator.MailboxCandidate] = []

    for recipientDir in recipientDirs {
      guard (try? recipientDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      else {
        continue
      }
      let newDir = recipientDir.appending(path: "new", directoryHint: .isDirectory)
      let messageFiles = try Self.listDirectory(newDir, section: .waiting)
        .filter { $0.pathExtension == "json" }
      let payloads = messageFiles.compactMap { Self.readOptionalSmallFileData(at: $0) }
      guard !payloads.isEmpty else { continue }
      mailboxes.append(
        BrainWaitingEvaluator.MailboxCandidate(
          recipient: recipientDir.lastPathComponent,
          messagePayloads: payloads
        )
      )
    }

    let brainSessionFiles = try Self.listDirectory(brainSessionsDirectory, section: .waiting)
      .filter { $0.pathExtension == "json" }
    let claudeSessionFiles = Self.optionalJSONFiles(in: claudeSessionsDirectory)

    var openSessionNames: Set<String> = []
    for sessionFile in brainSessionFiles + claudeSessionFiles {
      guard
        let data = Self.readOptionalSmallFileData(at: sessionFile),
        let openName = BrainWaitingEvaluator.parseOpenSessionName(
          from: data,
          filename: sessionFile.lastPathComponent,
          isProcessAlive: processAliveChecker
        )
      else {
        continue
      }
      openSessionNames.insert(openName)
    }

    return BrainWaitingEvaluator.evaluate(
      pendingCandidates: pendingCandidates,
      mailboxes: mailboxes,
      openSessionNames: openSessionNames,
      now: now
    )
  }

  // MARK: - 2. Fila da Máquina

  private func collectCIQueue(now: Date) throws(AppError) -> CIQueueState {
    _ = try Self.listDirectory(brainCIDirectory, section: .ciQueue)

    let versionData = try Self.readSmallFile(
      at: brainCIDirectory.appending(path: "version.json"),
      section: .ciQueue
    )?.data
    let pausedData = try Self.readSmallFile(
      at: brainCIDirectory.appending(path: "paused"),
      section: .ciQueue
    )?.data
    let modeData = try Self.readSmallFile(
      at: brainCIDirectory.appending(path: "mode"),
      section: .ciQueue
    )?.data
    let vmNowData = try Self.readSmallFile(
      at: brainCIDirectory.appending(path: "vm-now.json"),
      section: .ciQueue
    )?.data

    let queueDir = brainCIDirectory.appending(path: "queue", directoryHint: .isDirectory)
    let ticketFiles = try Self.listDirectory(queueDir, section: .ciQueue)
      .filter { $0.pathExtension == "json" }
    let ticketPayloads: [(id: String, data: Data)] = ticketFiles.compactMap { fileURL in
      guard let data = Self.readOptionalSmallFileData(at: fileURL) else {
        return nil
      }
      return (fileURL.deletingPathExtension().lastPathComponent, data)
    }

    let runLines = try Self.tailLines(
      at: brainCIDirectory.appending(path: "runs.jsonl"),
      maxBytes: Self.runsTailBytes,
      section: .ciQueue
    )
    let alertLines = try Self.tailLines(
      at: brainCIDirectory.appending(path: "alerts.jsonl"),
      maxBytes: Self.alertsTailBytes,
      section: .ciQueue
    )

    return BrainCIQueueEvaluator.evaluate(
      inputs: BrainCIQueueEvaluator.RawInputs(
        versionData: versionData,
        pausedData: pausedData,
        modeData: modeData,
        vmNowData: vmNowData,
        ticketPayloads: ticketPayloads,
        runLines: runLines,
        alertLines: alertLines
      ),
      now: now,
      calendar: calendar,
      isProcessAlive: processAliveChecker
    )
  }

  // MARK: - 3. Saúde & Backup

  private func collectHealthAndBackup(now: Date) throws(AppError) -> HealthAndBackupState {
    _ = try Self.listDirectory(logsDirectory, section: .healthAndBackup)

    let doctor = try Self.readSmallFile(
      at: logsDirectory.appending(path: "brain-doctor.state"),
      section: .healthAndBackup
    )
    let testState = try Self.readSmallFile(
      at: logsDirectory.appending(path: "brain-test.state"),
      section: .healthAndBackup
    )
    let syncState = try Self.readSmallFile(
      at: logsDirectory.appending(path: "brain-sync.state"),
      section: .healthAndBackup
    )
    let backupState = try Self.readSmallFile(
      at: logsDirectory.appending(path: "brain-backup.state"),
      section: .healthAndBackup
    )
    let liveBackup = try Self.readSmallFile(
      at: backupProgressFileURL,
      section: .healthAndBackup
    )

    return BrainHealthAndBackupEvaluator.evaluate(
      inputs: BrainHealthAndBackupEvaluator.RawInputs(
        doctorStateData: doctor?.data,
        doctorModifiedAt: doctor?.modifiedAt,
        testStateData: testState?.data,
        syncStateData: syncState?.data,
        backupStateData: backupState?.data,
        liveBackupProgressData: liveBackup?.data
      ),
      now: now
    )
  }

  // MARK: - 4. Jobs Agendados

  private func collectScheduledJobs(
    now: Date,
    isActivelyBackingUp: Bool
  ) throws(AppError) -> ScheduledJobsState {
    let plistFiles = try Self.listDirectory(launchAgentsDirectory, section: .scheduledJobs)
      .filter {
        $0.lastPathComponent.hasPrefix("com.lucas.") && $0.pathExtension == "plist"
      }

    let plists: [BrainScheduledJobsEvaluator.PlistCandidate] = plistFiles.compactMap { fileURL in
      guard let data = Self.readOptionalSmallFileData(at: fileURL) else {
        return nil
      }
      return BrainScheduledJobsEvaluator.PlistCandidate(
        fallbackLabel: fileURL.deletingPathExtension().lastPathComponent,
        plistData: data
      )
    }

    let launchctlListOutput = try launchctlRunner.listJobs()

    _ = try Self.listDirectory(brainWeeklyDirectory, section: .scheduledJobs)
    let weeklyStateData = try Self.readSmallFile(
      at: brainWeeklyDirectory.appending(path: "state.json"),
      section: .scheduledJobs
    )?.data
    let faxinaData = try Self.readSmallFile(
      at: brainWeeklyDirectory.appending(path: "faxina.json"),
      section: .scheduledJobs
    )?.data

    // Enriquecimentos de `logs/` são opcionais aqui para que falha em `logs/` degrade apenas `.healthAndBackup`.
    let syncStateData = Self.readOptionalSmallFileData(
      at: logsDirectory.appending(path: "brain-sync.state")
    )
    let backupStateData = Self.readOptionalSmallFileData(
      at: logsDirectory.appending(path: "brain-backup.state")
    )
    let rehearseStateData = Self.readOptionalSmallFileData(
      at: logsDirectory.appending(path: "brain-rehearse.state")
    )

    return BrainScheduledJobsEvaluator.evaluate(
      inputs: BrainScheduledJobsEvaluator.RawInputs(
        plists: plists,
        launchctlListOutput: launchctlListOutput,
        syncStateData: syncStateData,
        backupStateData: backupStateData,
        weeklyStateData: weeklyStateData,
        faxinaData: faxinaData,
        rehearseStateData: rehearseStateData,
        isActivelyBackingUp: isActivelyBackingUp
      ),
      now: now,
      calendar: calendar
    )
  }

  // MARK: - Helpers somente-leitura com falha isolada

  private static func collectSection<Value: Equatable & Sendable>(
    _ section: KnownBrainSection,
    _ body: () throws -> Value
  ) -> BrainSectionState<Value> {
    do {
      return .loaded(try body())
    } catch let appError as AppError {
      return .failed(
        appError.code == .brainStateReadFailed
          ? appError
          : AppError.brainStateReadFailed(section: section)
      )
    } catch {
      return .failed(AppError.brainStateReadFailed(section: section))
    }
  }

  private static func isMissingPathError(_ error: NSError, at url: URL) -> Bool {
    let isBrokenSymlink =
      (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    if isBrokenSymlink {
      return false
    }
    if error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileReadNoSuchFile.rawValue {
      return true
    }
    if error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
      return true
    }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
      underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOENT)
    {
      return true
    }
    return false
  }

  private static func listDirectory(
    _ directory: URL,
    section: KnownBrainSection,
    keys: [URLResourceKey] = []
  ) throws(AppError) -> [URL] {
    do {
      let entries = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles]
      )
      return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
    } catch {
      let nsError = error as NSError
      if isMissingPathError(nsError, at: directory) {
        return []
      }
      throw AppError.brainStateReadFailed(section: section)
    }
  }

  private static func optionalJSONFiles(in directory: URL) -> [URL] {
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }
    return
      entries
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private static func readSmallFile(
    at url: URL,
    section: KnownBrainSection
  ) throws(AppError) -> (data: Data, modifiedAt: Date?)? {
    let values: URLResourceValues
    do {
      values = try url.resourceValues(
        forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
      )
    } catch {
      let nsError = error as NSError
      if isMissingPathError(nsError, at: url) {
        return nil
      }
      throw AppError.brainStateReadFailed(section: section)
    }

    guard values.isRegularFile == true else {
      throw AppError.brainStateReadFailed(section: section)
    }
    if let size = values.fileSize, size > maxSmallFileBytes {
      return nil
    }

    do {
      let data = try Data(contentsOf: url)
      return (data, values.contentModificationDate)
    } catch {
      let nsError = error as NSError
      if isMissingPathError(nsError, at: url) {
        return nil
      }
      throw AppError.brainStateReadFailed(section: section)
    }
  }

  private static func readOptionalSmallFileData(at url: URL) -> Data? {
    guard
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
      values.isRegularFile == true,
      let size = values.fileSize,
      size <= maxSmallFileBytes,
      let data = try? Data(contentsOf: url)
    else {
      return nil
    }
    return data
  }

  private static func safeTranscriptModifiedAt(path: String?) -> Date? {
    guard
      let path,
      path.hasPrefix("/"),
      !path.contains("\0"),
      !path.split(separator: "/").contains("..")
    else {
      return nil
    }
    let url = URL(filePath: path)
    guard
      let values = try? url.resourceValues(
        forKeys: [.isRegularFileKey, .contentModificationDateKey]
      ),
      values.isRegularFile == true
    else {
      return nil
    }
    return values.contentModificationDate
  }

  private static func tailLines(
    at url: URL,
    maxBytes: Int,
    section: KnownBrainSection
  ) throws(AppError) -> [Substring] {
    do {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey])
      guard values.isRegularFile == true else {
        throw AppError.brainStateReadFailed(section: section)
      }
    } catch let appError as AppError {
      throw appError
    } catch {
      let nsError = error as NSError
      if isMissingPathError(nsError, at: url) {
        return []
      }
      throw AppError.brainStateReadFailed(section: section)
    }

    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }

      let totalSize = try handle.seekToEnd()
      let clampedMax = max(maxBytes, 1)
      let startOffset = totalSize > UInt64(clampedMax) ? totalSize - UInt64(clampedMax) : 0
      try handle.seek(toOffset: startOffset)

      guard let data = try handle.readToEnd(), !data.isEmpty else {
        return []
      }
      let text = String(decoding: data, as: UTF8.self)
      var rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
      if startOffset > 0, !rawLines.isEmpty {
        rawLines.removeFirst()
      }
      return rawLines.filter { !$0.isEmpty }
    } catch {
      throw AppError.brainStateReadFailed(section: section)
    }
  }
}
