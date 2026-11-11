import Darwin
import Foundation
import XCTest

@testable import BrainPanel

final class GeminiCollectorIntegrationTests: XCTestCase {
  func testCollectsQuotaFromFakeAgy155WithTrustPromptDismissibleBannerAndModeCycleFooter()
    async throws
  {
    let tempRoot = try makeIsolatedTmpDirectory()
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let script = """
      #!/usr/bin/python3
      import os, sys, termios, time, tty

      fd = sys.stdin.fileno()
      old_attrs = termios.tcgetattr(fd)
      tty.setraw(fd)
      try:
          os.write(1, b"Welcome to the Antigravity CLI. You are currently not signed in.\\r\\n")
          os.write(1, b"Signing in...\\r\\n")
          time.sleep(0.05)

          os.write(1, b"Do you trust the contents of this project?\\r\\n")
          os.write(1, b"> Yes, I trust this folder\\r\\n  No, exit\\r\\n")

          trust_reply = b""
          while b"\\r" not in trust_reply and b"\\n" not in trust_reply:
              chunk = os.read(fd, 1)
              if not chunk:
                  sys.exit(1)
              trust_reply += chunk

          os.write(1, b"\\x1bM\\x1b[2K\\x1bM\\x1b[2KIntroducing Gemini 4 Carbon\\r\\nesc to dismiss\\r\\n")

          dismiss_buf = bytearray()
          while True:
              chunk = os.read(fd, 1)
              if not chunk:
                  sys.exit(1)
              dismiss_buf.extend(chunk)
              if b"/quota" in dismiss_buf:
                  os.write(1, b"ERROR_QUOTA_SENT_BEFORE_ESC\\r\\n")
                  sys.exit(2)
              if chunk == b"\\x1b":
                  break

          os.write(
              1,
              b"\\x1b[2J\\x1b[H"
              b"Antigravity CLI 1.5.5 (Google AI Ultra)\\r\\n"
              b"----------------------------------------\\r\\n"
              b"> \\r\\n"
              b"----------------------------------------\\r\\n"
              b"Auto mode: edits & safe commands auto-approved (shift+tab to cycle)\\r\\n",
          )

          cmd_buf = bytearray()
          while not cmd_buf.endswith(b"\\r") and not cmd_buf.endswith(b"\\n"):
              chunk = os.read(fd, 1)
              if not chunk:
                  sys.exit(1)
              cmd_buf.extend(chunk)

          if b"/quota" in cmd_buf:
              os.write(
                  1,
                  b"\\r\\n"
                  b"\\xe2\\x94\\x94 Models & Quota\\r\\n"
                  b"\\xe2\\x94\\x82 GEMINI 4 CARBON\\r\\n"
                  b"\\xe2\\x94\\x82 Weekly Limit Remaining\\r\\n"
                  b"\\xe2\\x94\\x82 82% Refreshes in 3d 4h\\r\\n"
                  b"\\xe2\\x94\\x82 Five Hour Limit Remaining\\r\\n"
                  b"\\xe2\\x94\\x82 100% Quota available\\r\\n"
                  b"\\xe2\\x94\\x82 CLAUDE AND GPT MODELS\\r\\n"
                  b"\\xe2\\x94\\x82 Five Hour Limit Remaining\\r\\n"
                  b"\\xe2\\x94\\x82 60% Refreshes in 1h 30m\\r\\n"
                  b"\\xe2\\x94\\x82 Weekly Limit Remaining\\r\\n"
                  b"\\xe2\\x94\\x82 50% Refreshes in 5d\\r\\n"
                  b"\\xe2\\x94\\x82Within each group, models share a weekly limit and a 5-hour limit.\\r\\n",
              )
              time.sleep(0.15)
      finally:
          termios.tcsetattr(fd, termios.TCSADRAIN, old_attrs)
      """

    let collector = try makeGeminiCollector(in: tempRoot, agyScript: script)
    let usage = try await collector.fetchUsage()

    XCTAssertEqual(usage.id, "gemini")
    XCTAssertEqual(usage.plan, "Google AI Ultra")
    XCTAssertEqual(
      usage.limits.map(\.id),
      [
        "gemini-4-carbon-session",
        "gemini-4-carbon-weekly",
        "gemini-claude-and-gpt-models-session",
        "gemini-claude-and-gpt-models-weekly",
      ]
    )
    XCTAssertEqual(usage.limits.map(\.usedPercentage), [0, 18, 40, 50])
    XCTAssertNil(usage.limits.first?.resetsAt)
    XCTAssertEqual(usage.weeklyLimit?.id, "gemini-claude-and-gpt-models-weekly")
    XCTAssertEqual(usage.weeklyLimit?.usedPercentage, 50)
  }

  func testRetriesOnceCleanlyWhenFirstPTYStartupExitsPrematurely() async throws {
    let tempRoot = try makeIsolatedTmpDirectory()
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let attemptsFileURL = tempRoot.appending(path: "attempts.log")
    let script = """
      #!/usr/bin/python3
      import os, sys, termios, time, tty

      attempts_path = \(pythonStringLiteral(attemptsFileURL.path))
      count = 0
      if os.path.exists(attempts_path):
          with open(attempts_path, "r", encoding="utf-8") as fh:
              count = len([line for line in fh.read().splitlines() if line.strip()])
      with open(attempts_path, "a", encoding="utf-8") as fh:
          fh.write(f"{os.getpid()}\\n")

      if count == 0:
          os.write(1, b"Welcome to the Antigravity CLI. You are currently not signed in.\\r\\nSigning in...\\r\\n")
          sys.exit(1)

      fd = sys.stdin.fileno()
      old_attrs = termios.tcgetattr(fd)
      tty.setraw(fd)
      try:
          os.write(
              1,
              b"Antigravity CLI 1.5.5 (Google AI Pro)\\r\\n"
              b"> \\r\\n"
              b"Auto mode: edits & safe commands auto-approved (shift+tab to cycle)\\r\\n",
          )
          cmd_buf = bytearray()
          while not cmd_buf.endswith(b"\\r") and not cmd_buf.endswith(b"\\n"):
              chunk = os.read(fd, 1)
              if not chunk:
                  sys.exit(1)
              cmd_buf.extend(chunk)
          if b"/quota" in cmd_buf:
              os.write(
                  1,
                  b"\\xe2\\x94\\x94 Models & Quota\\r\\n"
                  b"\\xe2\\x94\\x82 GEMINI 4 CARBON\\r\\n"
                  b"\\xe2\\x94\\x82 Weekly Limit Remaining\\r\\n"
                  b"\\xe2\\x94\\x82 75% Refreshes in 2d\\r\\n"
                  b"\\xe2\\x94\\x82Within each group, models share a weekly limit and a 5-hour limit.\\r\\n",
              )
              time.sleep(0.15)
      finally:
          termios.tcsetattr(fd, termios.TCSADRAIN, old_attrs)
      """

    let collector = try makeGeminiCollector(in: tempRoot, agyScript: script)
    let usage = try await collector.fetchUsage()

    XCTAssertEqual(usage.plan, "Google AI Pro")
    XCTAssertEqual(usage.weeklyLimit?.usedPercentage, 25)

    let recordedPIDs = try String(contentsOf: attemptsFileURL, encoding: .utf8)
      .split(whereSeparator: \.isNewline)
    XCTAssertEqual(
      recordedPIDs.count,
      2,
      "Falha transitória na 1ª abertura deve acionar exatamente 1 nova tentativa limpa"
    )
  }

  func testPreservesUnauthenticatedErrorAndCapsRetriesWhenAgyNeverReachesReadyState() async throws {
    let tempRoot = try makeIsolatedTmpDirectory()
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let attemptsFileURL = tempRoot.appending(path: "unauth-attempts.log")
    let script = """
      #!/usr/bin/python3
      import os, time

      attempts_path = \(pythonStringLiteral(attemptsFileURL.path))
      with open(attempts_path, "a", encoding="utf-8") as fh:
          fh.write(f"{os.getpid()}\\n")

      os.write(1, b"Welcome to the Antigravity CLI. You are currently not signed in.\\r\\n")
      os.write(1, b"> Sign in with Google\\r\\n")
      while True:
          time.sleep(1)
      """

    var fastTimings = GeminiCollector.Timings()
    fastTimings.startupTimeout = 0.35
    fastTimings.retryBackoff = 0.05

    let collector = try makeGeminiCollector(
      in: tempRoot,
      agyScript: script,
      timings: fastTimings
    )

    var capturedError: AppError?
    do {
      _ = try await collector.fetchUsage()
      XCTFail("Deveria lançar CLI_UNAUTHENTICATED quando a CLI não atinge estado pronto")
    } catch let error as AppError {
      capturedError = error
    }

    XCTAssertEqual(
      capturedError,
      AppError.unauthenticatedSession(provider: .gemini, executable: .agy)
    )

    let pids = try String(contentsOf: attemptsFileURL, encoding: .utf8)
      .split(whereSeparator: \.isNewline)
      .compactMap { Int32($0) }
    XCTAssertEqual(
      pids.count,
      2,
      "Deve tentar no máximo 1 vez extra antes de devolver CLI_UNAUTHENTICATED"
    )

    for pid in pids {
      let exited = waitForProcessExit(pid: pid, maxMilliseconds: 1_000)
      if !exited {
        _ = Darwin.kill(pid, SIGKILL)
      }
      XCTAssertTrue(exited, "Nenhum processo sonda pode sobrar vivo após falha de autenticação")
    }
  }

  func testCancellingFetchUsageTaskAbortsInFlightPTYWithoutStartingRetryOrLeavingOrphan()
    async throws
  {
    let tempRoot = try makeIsolatedTmpDirectory()
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let attemptsFileURL = tempRoot.appending(path: "cancel-attempts.log")
    let script = """
      #!/usr/bin/python3
      import os, time

      attempts_path = \(pythonStringLiteral(attemptsFileURL.path))
      with open(attempts_path, "a", encoding="utf-8") as fh:
          fh.write(f"{os.getpid()}\\n")

      os.write(1, b"Welcome to the Antigravity CLI. You are currently not signed in.\\r\\nSigning in...\\r\\n")
      while True:
          time.sleep(1)
      """

    var slowTimings = GeminiCollector.Timings()
    slowTimings.startupTimeout = 20
    let collector = try makeGeminiCollector(
      in: tempRoot,
      agyScript: script,
      timings: slowTimings
    )

    let task = Task {
      try await collector.fetchUsage()
    }

    let started = waitForFileNonEmpty(url: attemptsFileURL, maxMilliseconds: 3_000)
    XCTAssertTrue(started, "A sonda fake deveria ter iniciado antes do cancelamento")

    let cancelledAt = SystemClock().now()
    task.cancel()
    _ = await task.result
    let cancelLatency = SystemClock().now().timeIntervalSince(cancelledAt)
    XCTAssertLessThan(
      cancelLatency,
      3.0,
      "Cancelamento da Task deve abortar a leitura PTY em voo imediatamente sem esperar startupTimeout"
    )

    let pids = try String(contentsOf: attemptsFileURL, encoding: .utf8)
      .split(whereSeparator: \.isNewline)
      .compactMap { Int32($0) }
    XCTAssertEqual(pids.count, 1, "Cancelamento da Task não pode disparar retry de startup")

    for pid in pids {
      let exited = waitForProcessExit(pid: pid, maxMilliseconds: 1_500)
      if !exited {
        _ = Darwin.kill(pid, SIGKILL)
      }
      XCTAssertTrue(exited, "Cancelamento da Task deve encerrar a sonda PTY em voo sem órfãos")
    }
  }

  private func makeGeminiCollector(
    in tempRoot: URL,
    agyScript: String,
    timings: GeminiCollector.Timings? = nil
  ) throws -> GeminiCollector {
    let binDir = tempRoot.appending(path: "fake-bin", directoryHint: .isDirectory)
    let supportDir = tempRoot.appending(path: "support", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)

    let agyURL = binDir.appending(path: "agy")
    try Data(agyScript.utf8).write(to: agyURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agyURL.path)

    let config = try AppConfig.parse(
      environment: [
        "BRAIN_PANEL_MODE": "testing",
        "BRAIN_PANEL_APP_SUPPORT_DIR": supportDir.path,
        "BRAIN_PANEL_CLI_SEARCH_PATHS": binDir.path,
      ],
      defaultHomeDirectory: tempRoot,
      defaultAppSupportRoot: supportDir,
      defaultTemporaryRoot: tempRoot,
      bundleIdentifier: "com.h3zord.BrainPanel.Tests"
    )

    var defaultTestTimings = GeminiCollector.Timings()
    defaultTestTimings.startupTimeout = 4
    defaultTestTimings.quietPeriod = 0.08
    defaultTestTimings.quietTimeout = 0.8
    defaultTestTimings.commandSubmitDelay = 0.05
    defaultTestTimings.quotaHeaderTimeout = 4
    defaultTestTimings.quotaFooterTimeout = 4
    defaultTestTimings.postQuotaQuietPeriod = 0.05
    defaultTestTimings.postQuotaQuietTimeout = 0.4
    defaultTestTimings.retryBackoff = 0.05

    return GeminiCollector(
      cliEnvironment: CLIEnvironment(config: config),
      clock: SystemClock(),
      timings: timings ?? defaultTestTimings
    )
  }

  private func pythonStringLiteral(_ value: String) -> String {
    let escaped =
      value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }

  private func waitForFileNonEmpty(url: URL, maxMilliseconds: Int) -> Bool {
    let steps = max(maxMilliseconds / 20, 1)
    for _ in 0..<steps {
      if let data = try? Data(contentsOf: url), !data.isEmpty {
        return true
      }
      usleep(20_000)
    }
    return false
  }

  private func waitForProcessExit(pid: Int32, maxMilliseconds: Int) -> Bool {
    let steps = max(maxMilliseconds / 10, 1)
    for _ in 0..<steps {
      var status: Int32 = 0
      if waitpid(pid, &status, WNOHANG) == pid {
        return true
      }
      if Darwin.kill(pid, 0) != 0 && errno == ESRCH {
        return true
      }
      usleep(10_000)
    }
    return Darwin.kill(pid, 0) != 0 && errno == ESRCH
  }

  private func makeIsolatedTmpDirectory() throws -> URL {
    let repoRoot = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let dir =
      repoRoot
      .appending(
        path: "local/tmp/integration-gemini-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
}
