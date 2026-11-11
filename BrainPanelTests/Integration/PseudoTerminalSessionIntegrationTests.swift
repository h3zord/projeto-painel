import Foundation
import XCTest

@testable import BrainPanel

final class PseudoTerminalSessionIntegrationTests: XCTestCase {
  func testExecutesControlledLocalScriptOverPTYWithCursorQueryAndInput() throws {
    let tempRoot = try makeIsolatedTmpDirectory()
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let scriptURL = tempRoot.appending(path: "fake-cli.py")
    let script = """
      #!/usr/bin/env python3
      import os, sys, termios, tty

      fd = sys.stdin.fileno()
      old_attrs = termios.tcgetattr(fd)
      tty.setraw(fd)
      try:
          os.write(1, b"\\x1b[6n")
          reply = bytearray()
          while not reply.endswith(b"R"):
              chunk = os.read(fd, 1)
              if not chunk:
                  break
              reply.extend(chunk)
          if b"[1;1R" in reply:
              os.write(1, b"READY for shortcuts\\r\\n")
          command = bytearray()
          while not command.endswith(b"\\r") and not command.endswith(b"\\n"):
              chunk = os.read(fd, 1)
              if not chunk:
                  break
              command.extend(chunk)
          if b"/quota" in command:
              os.write(
                  1,
                  b"Models & Quota\\r\\nGEMINI 4 ARGON\\r\\nWeekly Limit\\r\\n80% Refreshes in 24h\\r\\nWithin each group\\r\\n",
              )
      finally:
          termios.tcsetattr(fd, termios.TCSADRAIN, old_attrs)
      """
    try Data(script.utf8).write(to: scriptURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

    let session = try PseudoTerminalSession(
      executable: scriptURL,
      directory: tempRoot,
      environment: [
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "LANG": "en_US.UTF-8",
        "TERM": "xterm-256color",
      ],
      columns: 80,
      rows: 40
    )
    defer { session.terminate() }

    let becameReady = session.read(timeout: 5.0) { $0.contains("READY for shortcuts") }
    XCTAssertTrue(becameReady, "O script local deveria responder após receber o cursor report")

    try session.send("/quota\r")
    let renderedQuota = session.read(timeout: 5.0) { $0.contains("Within each group") }
    XCTAssertTrue(renderedQuota)

    let parsed = try GeminiQuotaParser.makeUsage(
      from: session.screen,
      now: Date(timeIntervalSince1970: 1_762_800_000)
    )
    XCTAssertEqual(parsed.weeklyLimit?.usedPercentage, 20)
  }

  func testTerminateEscalatesToSIGKILLWhenChildIgnoresSIGTERMAndSIGHUP() throws {
    let tempRoot = try makeIsolatedTmpDirectory()
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let pidFileURL = tempRoot.appending(path: "child.pid")
    let scriptURL = tempRoot.appending(path: "stubborn-cli.py")
    let script = """
      #!/usr/bin/env python3
      import os, signal, sys, time

      signal.signal(signal.SIGTERM, signal.SIG_IGN)
      signal.signal(signal.SIGHUP, signal.SIG_IGN)
      with open(sys.argv[1], "w", encoding="utf-8") as fh:
          fh.write(str(os.getpid()))
      os.write(1, b"STUBBORN_READY\\r\\n")
      while True:
          time.sleep(1)
      """
    try Data(script.utf8).write(to: scriptURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

    let session = try PseudoTerminalSession(
      executable: scriptURL,
      arguments: [pidFileURL.path],
      directory: tempRoot,
      environment: [
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "LANG": "en_US.UTF-8",
        "TERM": "xterm-256color",
      ],
      columns: 80,
      rows: 24
    )

    let becameReady = session.read(timeout: 5.0) { $0.contains("STUBBORN_READY") }
    XCTAssertTrue(becameReady)

    let pidText = try String(contentsOf: pidFileURL, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let childPID = try XCTUnwrap(Int32(pidText))
    XCTAssertEqual(Darwin.kill(childPID, 0), 0, "Processo filho deveria estar vivo antes de terminate()")

    session.terminate()

    let stillAlive = Darwin.kill(childPID, 0) == 0
    if stillAlive {
      _ = Darwin.kill(childPID, SIGKILL)
    }
    XCTAssertFalse(
      stillAlive,
      "PseudoTerminalSession.terminate() deveria ter encerrado o processo mesmo ignorando SIGTERM/SIGHUP"
    )

    // Valida também o encerramento automático quando a sessão sai de escopo (deinit)
    let deinitPIDFileURL = tempRoot.appending(path: "child-deinit.pid")
    var scopedSession: PseudoTerminalSession? = try PseudoTerminalSession(
      executable: scriptURL,
      arguments: [deinitPIDFileURL.path],
      directory: tempRoot,
      environment: [
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "LANG": "en_US.UTF-8",
        "TERM": "xterm-256color",
      ],
      columns: 80,
      rows: 24
    )
    let deinitReady = scopedSession?.read(timeout: 5.0) { $0.contains("STUBBORN_READY") } ?? false
    XCTAssertTrue(deinitReady)

    let deinitPIDText = try String(contentsOf: deinitPIDFileURL, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let deinitChildPID = try XCTUnwrap(Int32(deinitPIDText))
    XCTAssertEqual(Darwin.kill(deinitChildPID, 0), 0)

    scopedSession = nil

    let deinitStillAlive = Darwin.kill(deinitChildPID, 0) == 0
    if deinitStillAlive {
      _ = Darwin.kill(deinitChildPID, SIGKILL)
    }
    XCTAssertFalse(deinitStillAlive, "deinit deveria encerrar o processo filho no PTY sem órfãos")
  }

  func testFailedInitAndTerminateCloseMasterDescriptorExactlyOnceWithoutEBADF() throws {
    let tempRoot = try makeIsolatedTmpDirectory()
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let nonExecutableURL = tempRoot.appending(path: "nao-executavel.txt")
    try Data("texto comum".utf8).write(to: nonExecutableURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: nonExecutableURL.path)

    var failedInitCloseErrnos: [Int32] = []
    XCTAssertThrowsError(
      try PseudoTerminalSession(
        executable: nonExecutableURL,
        directory: tempRoot,
        environment: ["LANG": "en_US.UTF-8", "TERM": "xterm-256color"],
        masterCloser: { fd in
          let rc = Darwin.close(fd)
          failedInitCloseErrnos.append(rc == 0 ? 0 : errno)
          return rc
        }
      )
    ) { error in
      let appError = error as? AppError
      XCTAssertEqual(appError?.code, .terminalUnavailable)
    }
    XCTAssertEqual(
      failedInitCloseErrnos,
      [0],
      "Falha em process.run() no init deve fechar o descritor master exatamente 1 vez sem EBADF"
    )

    // Valida também que terminate() fecha o master exatamente 1 vez, rejeitando send/read posteriores e sem double-close no deinit
    let scriptURL = tempRoot.appending(path: "short-cli.sh")
    try Data("#!/bin/sh\nprintf 'OK\\r\\n'\nsleep 2\n".utf8).write(to: scriptURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

    var normalCloseErrnos: [Int32] = []
    do {
      let session = try PseudoTerminalSession(
        executable: scriptURL,
        directory: tempRoot,
        environment: ["PATH": "/bin:/usr/bin", "LANG": "en_US.UTF-8", "TERM": "xterm-256color"],
        masterCloser: { fd in
          let rc = Darwin.close(fd)
          normalCloseErrnos.append(rc == 0 ? 0 : errno)
          return rc
        }
      )
      XCTAssertTrue(session.read(timeout: 5.0) { $0.contains("OK") })
      session.terminate()
      XCTAssertEqual(normalCloseErrnos, [0], "terminate() deve fechar o master imediatamente")
      XCTAssertThrowsError(try session.send("depois\r")) { error in
        XCTAssertEqual((error as? AppError)?.code, .terminalWriteFailed)
      }
      XCTAssertFalse(session.read(timeout: 0.2) { _ in false })
    }
    XCTAssertEqual(normalCloseErrnos, [0], "deinit após terminate() não pode fechar o master de novo")
  }

  func testClosingMasterDescriptorAloneDeliversKernelSIGHUPAndPreventsOrphans() throws {
    let tempRoot = try makeIsolatedTmpDirectory()
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let pidFileURL = tempRoot.appending(path: "session-pids.txt")
    let scriptURL = tempRoot.appending(path: "ctty-probe.py")
    let script = """
      #!/usr/bin/python3
      import os, subprocess, sys, time

      sub = subprocess.Popen(
          ["/usr/bin/python3", "-c", "import time\\nwhile True:\\n    time.sleep(1)\\n"],
          stdin=subprocess.DEVNULL,
          stdout=subprocess.DEVNULL,
          stderr=subprocess.DEVNULL,
      )
      ctty_status = "CTTY_MISSING"
      try:
          tty_fd = os.open("/dev/tty", os.O_RDWR)
          os.close(tty_fd)
          ctty_status = "CTTY_OK"
      except OSError:
          ctty_status = "CTTY_MISSING"

      with open(sys.argv[1], "w", encoding="utf-8") as fh:
          fh.write(f"{os.getpid()}\\n{sub.pid}\\n")

      os.write(1, f"{ctty_status} WAITING_FOR_HUP\\r\\n".encode("utf-8"))
      while True:
          time.sleep(1)
      """
    try Data(script.utf8).write(to: scriptURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

    let session = try PseudoTerminalSession(
      executable: scriptURL,
      arguments: [pidFileURL.path],
      directory: tempRoot,
      environment: [
        "PATH": "/usr/bin:/bin",
        "LANG": "en_US.UTF-8",
        "TERM": "xterm-256color",
      ],
      columns: 80,
      rows: 24
    )

    var trackedPIDs: [Int32] = []
    defer {
      session.terminate()
      for pid in trackedPIDs where pid > 0 {
        _ = Darwin.kill(pid, SIGKILL)
      }
    }

    let ready = session.read(timeout: 5.0) { $0.contains("WAITING_FOR_HUP") }
    XCTAssertTrue(ready, "O script local deveria iniciar e reportar estado de controlling TTY")

    let pidLines = try String(contentsOf: pidFileURL, encoding: .utf8)
      .split(whereSeparator: \.isNewline)
      .compactMap { Int32($0) }
    XCTAssertEqual(pidLines.count, 2)
    guard pidLines.count == 2, let leaderPID = pidLines.first, let subPID = pidLines.last else {
      return
    }
    trackedPIDs = [leaderPID, subPID]

    XCTAssertTrue(
      session.text.contains("CTTY_OK"),
      "O processo filho no PTY precisa adquirir controlling terminal (setsid + TIOCSCTTY)"
    )

    // Simula encerramento abrupto do processo pai durante session.read: fecha apenas o master sem terminate()
    session.closeMasterDescriptorWithoutTerminating()

    let leaderExited = waitForProcessExit(pid: leaderPID, maxMilliseconds: 1_500)
    let subExited = waitForProcessExit(pid: subPID, maxMilliseconds: 1_500)

    XCTAssertTrue(
      leaderExited,
      "Fechar apenas o descritor master deveria fazer o kernel entregar SIGHUP imediato ao filho"
    )
    XCTAssertTrue(
      subExited,
      "Subprocesso no mesmo grupo do controlling TTY também deve encerrar por SIGHUP sem ficar órfão"
    )
  }

  func testTerminateKillsEntireProcessGroupWhenChildAndSubprocessIgnoreSIGHUPAndSIGTERM() throws {
    let tempRoot = try makeIsolatedTmpDirectory()
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let pidFileURL = tempRoot.appending(path: "group-pids.txt")
    let scriptURL = tempRoot.appending(path: "group-stubborn.py")
    let script = """
      #!/usr/bin/python3
      import os, signal, subprocess, sys, time

      signal.signal(signal.SIGHUP, signal.SIG_IGN)
      signal.signal(signal.SIGTERM, signal.SIG_IGN)

      child_code = (
          "import signal, time\\n"
          "signal.signal(signal.SIGHUP, signal.SIG_IGN)\\n"
          "signal.signal(signal.SIGTERM, signal.SIG_IGN)\\n"
          "while True:\\n    time.sleep(1)\\n"
      )
      sub = subprocess.Popen(
          ["/usr/bin/python3", "-c", child_code],
          stdin=subprocess.DEVNULL,
          stdout=subprocess.DEVNULL,
          stderr=subprocess.DEVNULL,
      )
      with open(sys.argv[1], "w", encoding="utf-8") as fh:
          fh.write(f"{os.getpid()}\\n{sub.pid}\\n")

      os.write(1, b"GROUP_READY\\r\\n")
      while True:
          time.sleep(1)
      """
    try Data(script.utf8).write(to: scriptURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

    let session = try PseudoTerminalSession(
      executable: scriptURL,
      arguments: [pidFileURL.path],
      directory: tempRoot,
      environment: [
        "PATH": "/usr/bin:/bin",
        "LANG": "en_US.UTF-8",
        "TERM": "xterm-256color",
      ],
      columns: 80,
      rows: 24
    )

    var trackedPIDs: [Int32] = []
    defer {
      for pid in trackedPIDs where pid > 0 {
        _ = Darwin.kill(pid, SIGKILL)
      }
    }

    XCTAssertTrue(session.read(timeout: 5.0) { $0.contains("GROUP_READY") })
    let pidLines = try String(contentsOf: pidFileURL, encoding: .utf8)
      .split(whereSeparator: \.isNewline)
      .compactMap { Int32($0) }
    XCTAssertEqual(pidLines.count, 2)
    guard pidLines.count == 2, let leaderPID = pidLines.first, let subPID = pidLines.last else {
      return
    }
    trackedPIDs = [leaderPID, subPID]

    session.terminate()

    let leaderDead = waitForProcessExit(pid: leaderPID, maxMilliseconds: 500)
    let subDead = waitForProcessExit(pid: subPID, maxMilliseconds: 500)
    XCTAssertTrue(leaderDead, "Líder do grupo deveria ter sido encerrado por terminate()")
    XCTAssertTrue(
      subDead,
      "Subprocesso no mesmo grupo ignorando SIGHUP/SIGTERM deveria ter sido encerrado por kill(-pid, SIGKILL)"
    )
  }

  private func waitForProcessExit(pid: Int32, maxMilliseconds: Int) -> Bool {
    let steps = max(maxMilliseconds / 10, 1)
    for _ in 0..<steps {
      var status: Int32 = 0
      let reaped = waitpid(pid, &status, WNOHANG)
      if reaped == pid {
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
      .appending(path: "local/tmp/integration-pty-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
}
