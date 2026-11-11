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
