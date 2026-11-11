import Darwin
import Foundation
import XCTest

@testable import BrainPanel

private struct FixedBrainIntegrationClock: Clock {
  let current: Date

  func now() -> Date {
    current
  }

  func sleep(for _: Duration) async throws {}
}

final class BrainStateCollectorIntegrationTests: XCTestCase {
  private var sandboxRoot: URL?

  override func setUpWithError() throws {
    try super.setUpWithError()
    let repoRoot = Self.repositoryRoot()
    let tmpBase = repoRoot.appending(path: "local/tmp", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tmpBase, withIntermediateDirectories: true)
    let unique = tmpBase.appending(
      path: "brain-collector-int-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: unique, withIntermediateDirectories: true)
    sandboxRoot = unique
  }

  override func tearDownWithError() throws {
    if let sandboxRoot, FileManager.default.fileExists(atPath: sandboxRoot.path) {
      // Restaura permissões caso um teste de falha tenha aplicado chmod 000
      if let enumerator = FileManager.default.enumerator(atPath: sandboxRoot.path) {
        for case let rel as String in enumerator {
          let full = sandboxRoot.appending(path: rel).path
          _ = Darwin.chmod(full, mode_t(0o700))
        }
      }
      _ = Darwin.chmod(sandboxRoot.path, mode_t(0o700))
      try? FileManager.default.removeItem(at: sandboxRoot)
    }
    sandboxRoot = nil
    try super.tearDownWithError()
  }

  func testCollectsAllFourBlocksIgnoringMalformedIndividualFilesAndUsingSimulatedLaunchctl()
    async throws
  {
    let sandbox = try XCTUnwrap(sandboxRoot)
    let config = try populateSandboxFromFixtures(in: sandbox)

    // Planta arquivos individuais corrompidos dentro das pastas: devem ser ignorados sem derrubar o bloco
    try Data("{json-quebrado".utf8).write(
      to: config.brainPendingStateDirectory.appending(path: "corrompido.json")
    )
    try Data("{ticket-invalido".utf8).write(
      to: config.brainCIStateDirectory.appending(path: "queue/corrompido.json")
    )
    try Data("plist-invalido".utf8).write(
      to: config.launchAgentsDirectory.appending(path: "com.lucas.quebrado.plist")
    )

    // Script local simulando `launchctl list`
    let fakeLaunchctl = sandbox.appending(path: "fake-launchctl.sh")
    let script = """
      #!/bin/sh
      printf 'PID\\tStatus\\tLabel\\n'
      printf '501\\t0\\tcom.lucas.awake\\n'
      printf -- '-\\t0\\tcom.lucas.brain-sync\\n'
      printf -- '-\\t0\\tcom.lucas.brain-backup\\n'
      printf -- '-\\t0\\tcom.lucas.brain-weekly\\n'
      """
    try Data(script.utf8).write(to: fakeLaunchctl)
    XCTAssertEqual(Darwin.chmod(fakeLaunchctl.path, mode_t(0o755)), 0)

    var utcCalendar = Calendar(identifier: .gregorian)
    utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    let clock = FixedBrainIntegrationClock(
      current: Date(timeIntervalSince1970: 1_762_819_800)
    )
    let livePIDs: Set<Int32> = [41001, 41002, 41003, 41004, 41005, 41006]

    let collector = BrainStateCollector(
      config: config,
      clock: clock,
      calendar: utcCalendar,
      launchctlRunner: ProcessLaunchctlRunner(
        executableURL: fakeLaunchctl,
        timeoutSeconds: 2.0
      ),
      isProcessAlive: { livePIDs.contains($0) }
    )

    let snapshot = try await collector.fetchBrainState()

    XCTAssertTrue(snapshot.degradedSections.isEmpty)
    XCTAssertEqual(snapshot.waitingOnOwnerCount, 3)
    XCTAssertTrue(snapshot.hasCriticalFailure)

    let waiting = try XCTUnwrap(snapshot.waiting.value)
    XCTAssertEqual(waiting.pendingPrompts.map(\.sessionKey), ["painel-lead", "flexograv-lead"])
    XCTAssertNil(waiting.pendingPrompts[1].text)
    XCTAssertEqual(waiting.stuckMail.map(\.recipient), ["painel-lead"])
    XCTAssertEqual(waiting.closedMail.map(\.recipient), ["caixa-dev"])

    let ciQueue = try XCTUnwrap(snapshot.ciQueue.value)
    XCTAssertEqual(ciQueue.queueVersion, 4)
    XCTAssertEqual(ciQueue.runningTickets.count, 2)
    XCTAssertEqual(ciQueue.waitingTickets.count, 1)
    XCTAssertEqual(ciQueue.todaySummary, CITodaySummary(totalCount: 3, greenCount: 2))

    let health = try XCTUnwrap(snapshot.healthAndBackup.value)
    XCTAssertEqual(health.doctorFailures.count, 1)
    XCTAssertEqual(health.testSuite?.ranCount, 414)
    XCTAssertTrue(health.isActivelyBackingUp)

    let scheduled = try XCTUnwrap(snapshot.scheduledJobs.value)
    XCTAssertEqual(scheduled.jobs.count, 4)
    XCTAssertNotNil(scheduled.weeklyCleanupAt)
    XCTAssertEqual(scheduled.restoreRehearsal?.isPassing, true)
  }

  func testPermissionFailureInSingleBlockIsolatesErrorKeepingRemainingThreeBlocksHealthy()
    async throws
  {
    let sandbox = try XCTUnwrap(sandboxRoot)
    let config = try populateSandboxFromFixtures(in: sandbox)

    // Remove permissão de leitura apenas de `logs/` -> somente `.healthAndBackup` deve falhar
    XCTAssertEqual(Darwin.chmod(config.logsDirectory.path, mode_t(0o000)), 0)
    defer { _ = Darwin.chmod(config.logsDirectory.path, mode_t(0o700)) }

    // Caso o processo rode como root em algum ambiente atípico (onde chmod 000 não bloqueia leitura),
    // substitui `logs/` por symlink quebrado para garantir falha determinística de leitura.
    if (try? FileManager.default.contentsOfDirectory(atPath: config.logsDirectory.path)) != nil {
      _ = Darwin.chmod(config.logsDirectory.path, mode_t(0o700))
      try FileManager.default.removeItem(at: config.logsDirectory)
      try FileManager.default.createSymbolicLink(
        at: config.logsDirectory,
        withDestinationURL: sandbox.appending(path: "alvo-inexistente")
      )
    }

    let clock = FixedBrainIntegrationClock(
      current: Date(timeIntervalSince1970: 1_762_819_800)
    )
    let collector = BrainStateCollector(
      config: config,
      clock: clock,
      launchctlRunner: EmptyLaunchctlRunner(),
      isProcessAlive: { [41001, 41002, 41004, 41005].contains($0) }
    )

    let snapshot = try await collector.fetchBrainState()

    XCTAssertEqual(snapshot.degradedSections, [.healthAndBackup])
    XCTAssertEqual(snapshot.healthAndBackup.error?.code, .brainStateReadFailed)
    XCTAssertNotNil(snapshot.waiting.value)
    XCTAssertNotNil(snapshot.ciQueue.value)
    XCTAssertNotNil(snapshot.scheduledJobs.value)
    XCTAssertEqual(snapshot.scheduledJobs.value?.jobs.count, 4)
  }

  func testSlowLaunchctlScriptIsTerminatedOnTimeoutWithoutLeakingChildProcessesAndIsolatesFailure()
    async throws
  {
    let sandbox = try XCTUnwrap(sandboxRoot)
    let config = try populateSandboxFromFixtures(in: sandbox)

    let childPIDFile = sandbox.appending(path: "spawned-child.pid")
    let slowLaunchctl = sandbox.appending(path: "slow-launchctl.sh")
    let slowScript = """
      #!/bin/sh
      sleep 30 &
      child=$!
      printf '%s' "$child" > "\(childPIDFile.path)"
      wait "$child"
      """
    try Data(slowScript.utf8).write(to: slowLaunchctl)
    XCTAssertEqual(Darwin.chmod(slowLaunchctl.path, mode_t(0o755)), 0)

    let clock = FixedBrainIntegrationClock(
      current: Date(timeIntervalSince1970: 1_762_819_800)
    )
    let collector = BrainStateCollector(
      config: config,
      clock: clock,
      launchctlRunner: ProcessLaunchctlRunner(
        executableURL: slowLaunchctl,
        timeoutSeconds: 0.25
      ),
      isProcessAlive: { [41001, 41004].contains($0) }
    )

    let snapshot = try await collector.fetchBrainState()

    // Apenas `.scheduledJobs` falha; os outros 3 blocos permanecem carregados
    XCTAssertEqual(snapshot.degradedSections, [.scheduledJobs])
    XCTAssertEqual(snapshot.scheduledJobs.error?.code, .brainStateReadFailed)
    XCTAssertNotNil(snapshot.waiting.value)
    XCTAssertNotNil(snapshot.ciQueue.value)
    XCTAssertNotNil(snapshot.healthAndBackup.value)

    // Confere que nem o script nem o subprocesso `sleep 30` vazaram vivos após o timeout
    if let rawPID = try? String(contentsOf: childPIDFile, encoding: .utf8),
      let childPID = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      var aliveAfterKill = Darwin.kill(childPID, 0) == 0
      if aliveAfterKill {
        // Aguarda no máximo 100ms de escalonamento do kernel para concluir o reap do grupo
        for _ in 0..<10 where aliveAfterKill {
          usleep(10_000)
          aliveAfterKill = Darwin.kill(childPID, 0) == 0
        }
      }
      if aliveAfterKill {
        _ = Darwin.kill(childPID, SIGKILL)
      }
      XCTAssertFalse(aliveAfterKill, "Subprocesso filho \(childPID) vazou vivo após o timeout")
    }
  }

  private func populateSandboxFromFixtures(in sandbox: URL) throws -> AppConfig {
    let fixtures = Self.repositoryRoot().appending(
      path: "BrainPanelTests/Fixtures/BrainState",
      directoryHint: .isDirectory
    )

    let stateDir = sandbox.appending(path: "local-state", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

    for sub in ["brain-pending", "brain-mail", "brain-sessions", "brain-ci", "brain-weekly"] {
      try FileManager.default.copyItem(
        at: fixtures.appending(path: sub),
        to: stateDir.appending(path: sub)
      )
    }

    let claudeSessionsDir = sandbox.appending(path: "claude-sessions", directoryHint: .isDirectory)
    try FileManager.default.copyItem(
      at: fixtures.appending(path: "claude-sessions"),
      to: claudeSessionsDir
    )

    let logsDir = sandbox.appending(path: "logs", directoryHint: .isDirectory)
    try FileManager.default.copyItem(
      at: fixtures.appending(path: "logs"),
      to: logsDir
    )

    let launchAgentsDir = sandbox.appending(path: "launch-agents", directoryHint: .isDirectory)
    try FileManager.default.copyItem(
      at: fixtures.appending(path: "launch-agents"),
      to: launchAgentsDir
    )

    let pagesDir = sandbox.appending(path: "pages", directoryHint: .isDirectory)
    try FileManager.default.copyItem(
      at: fixtures.appending(path: "pages"),
      to: pagesDir
    )

    let emptyDir = sandbox.appending(path: "empty", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

    return try AppConfig.parse(
      environment: [
        "BRAIN_PANEL_MODE": "testing",
        "BRAIN_PANEL_CLAUDE_SESSIONS_DIR": claudeSessionsDir.path,
        "BRAIN_PANEL_CLAUDE_PROJECTS_DIR": emptyDir.path,
        "BRAIN_PANEL_CLAUDE_CONTEXT_CACHE_DIR": emptyDir.path,
        "BRAIN_PANEL_ANTIGRAVITY_DIR": emptyDir.path,
        "BRAIN_PANEL_BRAIN_STATE_DIR": stateDir.path,
        "BRAIN_PANEL_LOGS_DIR": logsDir.path,
        "BRAIN_PANEL_LAUNCH_AGENTS_DIR": launchAgentsDir.path,
        "BRAIN_PANEL_BACKUP_PROGRESS_FILE": pagesDir.appending(path: "backup-drive.json").path,
        "BRAIN_PANEL_APP_SUPPORT_DIR": emptyDir.path,
        "BRAIN_PANEL_CLI_SEARCH_PATHS": emptyDir.path,
      ],
      defaultHomeDirectory: sandbox,
      defaultAppSupportRoot: sandbox,
      defaultTemporaryRoot: sandbox,
      bundleIdentifier: "com.h3zord.BrainPanel"
    )
  }

  private static func repositoryRoot() -> URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
