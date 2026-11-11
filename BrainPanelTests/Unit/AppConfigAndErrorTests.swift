import Foundation
import XCTest

@testable import BrainPanel

final class AppConfigAndErrorTests: XCTestCase {
  private let homeURL = URL(filePath: "/Users/teste", directoryHint: .isDirectory)
  private let appSupportURL = URL(
    filePath: "/Users/teste/Library/Application Support", directoryHint: .isDirectory)
  private let tempURL = URL(filePath: "/tmp/brain-panel-tests", directoryHint: .isDirectory)

  func testDefaultLiveConfigurationUsesStandardUserPaths() throws {
    let config = try AppConfig.parse(
      environment: ["HOME": "/Users/teste", "USER": "teste"],
      defaultHomeDirectory: homeURL,
      defaultAppSupportRoot: appSupportURL,
      defaultTemporaryRoot: tempURL,
      bundleIdentifier: "com.h3zord.BrainPanel"
    )

    XCTAssertEqual(config.mode, .live)
    XCTAssertEqual(config.bundleIdentifier, "com.h3zord.BrainPanel")
    XCTAssertEqual(config.refreshIntervalSeconds, 300)
    XCTAssertEqual(config.cacheTTLSeconds, 60)
    XCTAssertEqual(config.claudeSessionsDirectory.path, "/Users/teste/.claude/sessions")
    XCTAssertEqual(config.claudeProjectsDirectory.path, "/Users/teste/.claude/projects")
    XCTAssertEqual(config.childCLIEnvironment["LANG"], "en_US.UTF-8")
    XCTAssertEqual(config.childCLIEnvironment["TERM"], "xterm-256color")
  }

  func testTestingModeIsolatesDefaultPathsAwayFromHome() throws {
    let config = try AppConfig.parse(
      environment: ["XCTestConfigurationFilePath": "/tmp/run.xctestconfiguration"],
      defaultHomeDirectory: homeURL,
      defaultAppSupportRoot: appSupportURL,
      defaultTemporaryRoot: tempURL,
      bundleIdentifier: nil
    )

    XCTAssertEqual(config.mode, .testing)
    XCTAssertFalse(config.claudeSessionsDirectory.path.contains("/Users/teste/.claude"))
    XCTAssertFalse(config.claudeProjectsDirectory.path.contains("/Users/teste/.claude"))
    XCTAssertEqual(config.cliSearchPaths, ["/tmp/brain-panel-tests/brain-panel-isolated/empty-bin"])
  }

  func testRejectsUnknownBrainPanelEnvironmentVariable() {
    assertConfigFails(
      environment: ["BRAIN_PANEL_DESCONHECIDA": "1"],
      expectedSetting: "BRAIN_PANEL_DESCONHECIDA"
    )
  }

  func testRejectsInvalidModeOutOfBoundsNumbersAndRelativePaths() {
    assertConfigFails(
      environment: ["BRAIN_PANEL_MODE": "invalido"],
      expectedSetting: "BRAIN_PANEL_MODE"
    )
    assertConfigFails(
      environment: ["BRAIN_PANEL_REFRESH_INTERVAL_SECONDS": "5"],
      expectedSetting: "BRAIN_PANEL_REFRESH_INTERVAL_SECONDS"
    )
    assertConfigFails(
      environment: ["BRAIN_PANEL_REFRESH_INTERVAL_SECONDS": "abc"],
      expectedSetting: "BRAIN_PANEL_REFRESH_INTERVAL_SECONDS"
    )
    assertConfigFails(
      environment: ["BRAIN_PANEL_CACHE_TTL_SECONDS": "0"],
      expectedSetting: "BRAIN_PANEL_CACHE_TTL_SECONDS"
    )
    assertConfigFails(
      environment: ["BRAIN_PANEL_CLAUDE_SESSIONS_DIR": "caminho/relativo"],
      expectedSetting: "BRAIN_PANEL_CLAUDE_SESSIONS_DIR"
    )
    assertConfigFails(
      environment: ["BRAIN_PANEL_CLAUDE_PROJECTS_DIR": "/tmp/../etc"],
      expectedSetting: "BRAIN_PANEL_CLAUDE_PROJECTS_DIR"
    )
    assertConfigFails(
      environment: ["BRAIN_PANEL_CLI_SEARCH_PATHS": "/usr/bin:relativo"],
      expectedSetting: "BRAIN_PANEL_CLI_SEARCH_PATHS"
    )
  }

  func testEveryPublishedAppErrorCodeIsProvokedAndSafeForDisplay() {
    struct UnknownTestFailure: Error, LocalizedError {
      var errorDescription: String? {
        "SQL cru interno /Users/privado/segredo"
      }
    }

    let provokedErrors: [AppError] = [
      AppError.invalidConfiguration(setting: "BRAIN_PANEL_MODE"),
      AppError.executableNotFound(.claude),
      AppError.workingDirectoryUnavailable(provider: .claude),
      AppError.terminalUnavailable(),
      AppError.terminalWriteFailed(),
      AppError.collectorTimedOut(provider: .gemini),
      AppError.unauthenticatedSession(provider: .gemini, executable: .agy),
      AppError.untrustedPromptFormat(provider: .gemini),
      AppError.unexpectedOutputFormat(provider: .claude),
      AppError.transcriptReadFailed(),
      ErrorHandler.normalize(UnknownTestFailure()),
    ]

    let coveredCodes = Set(provokedErrors.map(\.code))
    XCTAssertEqual(coveredCodes, Set(AppErrorCode.allCases))

    for appError in provokedErrors {
      XCTAssertFalse(appError.userMessage.isEmpty)
      XCTAssertFalse(appError.userMessage.contains("SQL cru interno"))
      XCTAssertFalse(appError.userMessage.contains("/Users/privado"))
      XCTAssertEqual(ErrorHandler.normalize(appError), appError)
    }
  }

  private func assertConfigFails(environment: [String: String], expectedSetting: String) {
    XCTAssertThrowsError(
      try AppConfig.parse(
        environment: environment,
        defaultHomeDirectory: homeURL,
        defaultAppSupportRoot: appSupportURL,
        defaultTemporaryRoot: tempURL,
        bundleIdentifier: "com.h3zord.BrainPanel"
      )
    ) { error in
      let appError = error as? AppError
      XCTAssertEqual(appError?.code, .invalidConfiguration)
      XCTAssertEqual(appError?.safeSettingName, expectedSetting)
    }
  }
}
