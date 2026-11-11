import Darwin
import Foundation
import XCTest

@testable import BrainPanel

final class InstallLocalScriptIntegrationTests: XCTestCase {
  func testFreshInstallUpgradeLegacyCleanupNeighborPreservationAndControlledTermination() throws {
    let tempRoot = try makeIsolatedTmpDirectory()
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let appsDir = tempRoot.appending(path: "Applications", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)

    let neighborMarkerURL =
      appsDir
      .appending(path: "OutroApp.app/Contents/Resources/marker.txt")
    try FileManager.default.createDirectory(
      at: neighborMarkerURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("vizinho-intacto".utf8).write(to: neighborMarkerURL)

    // 1. Instalação limpa inicial (v1.0.0)
    let sourceV1 = try makeFakeBrainPanelBundle(
      in: tempRoot.appending(path: "stage-v1", directoryHint: .isDirectory),
      version: "1.0.0"
    )
    let firstRun = try runInstallScript(arguments: [
      "--source-app", sourceV1.path,
      "--dest-dir", appsDir.path,
    ])
    XCTAssertEqual(firstRun.exitCode, 0, "stderr: \(firstRun.stderr)")

    let installedApp = appsDir.appending(path: "Brain Panel.app", directoryHint: .isDirectory)
    XCTAssertEqual(try readBundleVersion(of: installedApp), "1.0.0")
    XCTAssertTrue(
      FileManager.default.isExecutableFile(
        atPath: installedApp.appending(path: "Contents/MacOS/Brain Panel").path
      )
    )
    XCTAssertEqual(try String(contentsOf: neighborMarkerURL, encoding: .utf8), "vizinho-intacto")

    // 2. Cria AI Usage Menu.app provisório e inicia processos simulados dentro de appsDir
    let legacyExec = try makeSleepingExecutable(
      at: appsDir.appending(path: "AI Usage Menu.app/Contents/MacOS/AI Usage Menu"),
      readyFile: tempRoot.appending(path: "legacy.ready")
    )
    let installedExec = try makeSleepingExecutable(
      at: installedApp.appending(path: "Contents/MacOS/Brain Panel"),
      readyFile: tempRoot.appending(path: "installed.ready")
    )

    let legacyProcess = try spawnIsolatedProcess(
      executable: legacyExec,
      readyFile: tempRoot.appending(path: "legacy.ready")
    )
    defer {
      forceStopIfRunning(legacyProcess)
    }
    let previousAppProcess = try spawnIsolatedProcess(
      executable: installedExec,
      readyFile: tempRoot.appending(path: "installed.ready")
    )
    defer {
      forceStopIfRunning(previousAppProcess)
    }

    let legacyPID = legacyProcess.processIdentifier
    let previousPID = previousAppProcess.processIdentifier
    XCTAssertEqual(Darwin.kill(legacyPID, 0), 0)
    XCTAssertEqual(Darwin.kill(previousPID, 0), 0)

    // 3. Atualização para v1.1.0 com --terminate-running e remoção de AI Usage Menu.app
    let sourceV2 = try makeFakeBrainPanelBundle(
      in: tempRoot.appending(path: "stage-v2", directoryHint: .isDirectory),
      version: "1.1.0"
    )
    let upgradeRun = try runInstallScript(arguments: [
      "--source-app", sourceV2.path,
      "--dest-dir", appsDir.path,
      "--terminate-running",
    ])
    XCTAssertEqual(upgradeRun.exitCode, 0, "stderr: \(upgradeRun.stderr)")

    XCTAssertTrue(
      waitForProcessExit(legacyProcess, timeout: .seconds(3)),
      "Processo legado AI Usage Menu deveria ter encerrado"
    )
    XCTAssertTrue(
      waitForProcessExit(previousAppProcess, timeout: .seconds(3)),
      "Instância anterior de Brain Panel deveria ter encerrado"
    )
    XCTAssertNotEqual(Darwin.kill(legacyPID, 0), 0)
    XCTAssertNotEqual(Darwin.kill(previousPID, 0), 0)

    XCTAssertEqual(try readBundleVersion(of: installedApp), "1.1.0")
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: appsDir.appending(path: "AI Usage Menu.app").path
      ),
      "AI Usage Menu.app provisório deve ser removido"
    )
    XCTAssertEqual(try String(contentsOf: neighborMarkerURL, encoding: .utf8), "vizinho-intacto")

    let remainingItems = try FileManager.default.contentsOfDirectory(atPath: appsDir.path).sorted()
    XCTAssertEqual(remainingItems, ["Brain Panel.app", "OutroApp.app"])
  }

  func testRejectsInvalidSourceBundleMissingExecutableAndDotDotPathsWithoutTouchingExistingApps()
    throws
  {
    let tempRoot = try makeIsolatedTmpDirectory()
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let appsDir = tempRoot.appending(path: "Applications", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)

    let existingBrainPanel = try makeFakeBrainPanelBundle(in: appsDir, version: "0.9.0-existente")
    let legacyAppDir = appsDir.appending(path: "AI Usage Menu.app", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: legacyAppDir, withIntermediateDirectories: true)
    let neighborAppDir = appsDir.appending(path: "OutroApp.app", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: neighborAppDir, withIntermediateDirectories: true)

    let validStage = try makeFakeBrainPanelBundle(
      in: tempRoot.appending(path: "valid-stage", directoryHint: .isDirectory),
      version: "2.0.0"
    )

    // Bundle sem binário executável
    let nonExecStage = try makeFakeBrainPanelBundle(
      in: tempRoot.appending(path: "non-exec-stage", directoryHint: .isDirectory),
      version: "2.0.0"
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: nonExecStage.appending(path: "Contents/MacOS/Brain Panel").path
    )

    // Bundle com CFBundleIdentifier incorreto
    let wrongIDStage = try makeFakeBrainPanelBundle(
      in: tempRoot.appending(path: "wrong-id-stage", directoryHint: .isDirectory),
      version: "2.0.0",
      bundleIdentifier: "com.outro.Invalido"
    )

    let invalidInvocations: [[String]] = [
      [
        "--source-app", tempRoot.appending(path: "inexistente/Brain Panel.app").path,
        "--dest-dir", appsDir.path,
      ],
      [
        "--source-app", nonExecStage.path,
        "--dest-dir", appsDir.path,
      ],
      [
        "--source-app", wrongIDStage.path,
        "--dest-dir", appsDir.path,
      ],
      [
        "--source-app", "\(tempRoot.path)/valid-stage/../valid-stage/Brain Panel.app",
        "--dest-dir", appsDir.path,
      ],
      [
        "--source-app", validStage.path,
        "--dest-dir", "\(tempRoot.path)/Applications/../Applications",
      ],
    ]

    for args in invalidInvocations {
      let result = try runInstallScript(arguments: args)
      XCTAssertNotEqual(result.exitCode, 0, "Deveria falhar fechado para args: \(args)")
    }

    // Nenhuma invocação inválida pode ter substituído Brain Panel.app nem apagado AI Usage Menu.app / OutroApp.app
    XCTAssertEqual(try readBundleVersion(of: existingBrainPanel), "0.9.0-existente")
    XCTAssertTrue(FileManager.default.fileExists(atPath: legacyAppDir.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: neighborAppDir.path))

    // Controle positivo no mesmo ambiente: o bundle válido deve suceder logo em seguida
    let validControl = try runInstallScript(arguments: [
      "--source-app", validStage.path,
      "--dest-dir", appsDir.path,
    ])
    XCTAssertEqual(validControl.exitCode, 0, "stderr: \(validControl.stderr)")
    XCTAssertEqual(try readBundleVersion(of: existingBrainPanel), "2.0.0")
  }

  // MARK: - Helpers

  private struct ScriptOutcome {
    let exitCode: Int32
    let stdout: String
    let stderr: String
  }

  private func runInstallScript(arguments: [String]) throws -> ScriptOutcome {
    let scriptURL = repositoryRoot().appending(path: "scripts/install-local")
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/python3")
    process.arguments = [scriptURL.path] + arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    process.waitUntilExit()

    let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    return ScriptOutcome(
      exitCode: process.terminationStatus,
      stdout: String(decoding: outData, as: UTF8.self),
      stderr: String(decoding: errData, as: UTF8.self)
    )
  }

  private func makeFakeBrainPanelBundle(
    in parentDir: URL,
    version: String,
    bundleIdentifier: String = "com.h3zord.BrainPanel"
  ) throws -> URL {
    let bundleURL = parentDir.appending(path: "Brain Panel.app", directoryHint: .isDirectory)
    let macosDir = bundleURL.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: macosDir, withIntermediateDirectories: true)

    let plist: [String: Any] = [
      "CFBundleIdentifier": bundleIdentifier,
      "CFBundleName": "Brain Panel",
      "CFBundleExecutable": "Brain Panel",
      "CFBundleShortVersionString": version,
      "LSUIElement": true,
    ]
    let plistData = try PropertyListSerialization.data(
      fromPropertyList: plist,
      format: .xml,
      options: 0
    )
    try plistData.write(to: bundleURL.appending(path: "Contents/Info.plist"))

    let execURL = macosDir.appending(path: "Brain Panel")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: execURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: execURL.path)
    return bundleURL
  }

  private func readBundleVersion(of bundleURL: URL) throws -> String? {
    let data = try Data(contentsOf: bundleURL.appending(path: "Contents/Info.plist"))
    let plist =
      try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
      as? [String: Any]
    return plist?["CFBundleShortVersionString"] as? String
  }

  private func makeSleepingExecutable(at executableURL: URL, readyFile: URL) throws -> URL {
    try FileManager.default.createDirectory(
      at: executableURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let script = """
      #!/usr/bin/env python3
      import pathlib, signal, sys, time
      signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
      pathlib.Path(\(String(reflecting: readyFile.path))).write_text("ready", encoding="utf-8")
      time.sleep(30)
      """
    try Data(script.utf8).write(to: executableURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executableURL.path
    )
    return executableURL
  }

  private func spawnIsolatedProcess(executable: URL, readyFile: URL) throws -> Process {
    let process = Process()
    process.executableURL = executable
    try process.run()

    let deadline = ContinuousClock.now + .seconds(5)
    while !FileManager.default.fileExists(atPath: readyFile.path) {
      if ContinuousClock.now >= deadline {
        process.terminate()
        XCTFail("Processo simulado não sinalizou prontidão em \(readyFile.path)")
        break
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    return process
  }

  private func waitForProcessExit(_ process: Process, timeout: Duration) -> Bool {
    let deadline = ContinuousClock.now + timeout
    while process.isRunning {
      if ContinuousClock.now >= deadline {
        return false
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    return true
  }

  private func forceStopIfRunning(_ process: Process) {
    guard process.isRunning else { return }
    let pid = process.processIdentifier
    if pid > 0 {
      _ = Darwin.kill(pid, SIGKILL)
    }
    process.waitUntilExit()
  }

  private func repositoryRoot() -> URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func makeIsolatedTmpDirectory() throws -> URL {
    let dir =
      repositoryRoot()
      .appending(
        path: "local/tmp/integration-install-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
}
