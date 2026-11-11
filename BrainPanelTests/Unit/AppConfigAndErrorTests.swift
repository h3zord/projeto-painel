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
    XCTAssertEqual(config.claudeContextCacheDirectory.path, "/Users/teste/.cache/claude-context")
    XCTAssertEqual(config.antigravityDirectory.path, "/Users/teste/.gemini/antigravity-cli")
    XCTAssertEqual(
      config.brainSessionsStateDirectory.path,
      "/Users/teste/.local/state/brain-sessions"
    )
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
    XCTAssertFalse(config.claudeContextCacheDirectory.path.contains("/Users/teste/.cache"))
    XCTAssertFalse(config.antigravityDirectory.path.contains("/Users/teste/.gemini"))
    XCTAssertFalse(config.brainSessionsStateDirectory.path.contains("/Users/teste/.local/state"))
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
      environment: ["BRAIN_PANEL_CLAUDE_CONTEXT_CACHE_DIR": "relativo/cache"],
      expectedSetting: "BRAIN_PANEL_CLAUDE_CONTEXT_CACHE_DIR"
    )
    assertConfigFails(
      environment: ["BRAIN_PANEL_ANTIGRAVITY_DIR": "/tmp/../gemini"],
      expectedSetting: "BRAIN_PANEL_ANTIGRAVITY_DIR"
    )
    assertConfigFails(
      environment: ["BRAIN_PANEL_BRAIN_SESSIONS_STATE_DIR": "relativo/state"],
      expectedSetting: "BRAIN_PANEL_BRAIN_SESSIONS_STATE_DIR"
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

  func testBootstrapFailsClosedAndLogsBootFailedWithoutPreloadedConfig() throws {
    let clock = TestClock()
    let logSink = InMemoryLogSink()
    let logger = StructuredLogger(clock: clock, sink: logSink)

    var exitCode: Int32?
    let failedResult = BrainPanelBootstrap.resolveConfigOrReportFailure(
      preloaded: nil,
      environmentLoader: {
        try AppConfig.parse(
          environment: ["BRAIN_PANEL_MODE": "invalido"],
          defaultHomeDirectory: homeURL,
          defaultAppSupportRoot: appSupportURL,
          defaultTemporaryRoot: tempURL,
          bundleIdentifier: "com.h3zord.BrainPanel"
        )
      },
      logger: logger,
      exitHandler: { code in exitCode = code }
    )

    XCTAssertNil(failedResult)
    XCTAssertEqual(exitCode, EXIT_FAILURE)
    XCTAssertTrue(
      logSink.lines.contains {
        $0.contains("\"event\":\"boot_failed\"")
          && $0.contains("\"error_code\":\"CONFIG_INVALID\"")
          && $0.contains("\"setting\":\"BRAIN_PANEL_MODE\"")
      }
    )

    let validPreloaded = try AppConfig.parse(
      environment: ["BRAIN_PANEL_MODE": "testing"],
      defaultHomeDirectory: homeURL,
      defaultAppSupportRoot: appSupportURL,
      defaultTemporaryRoot: tempURL,
      bundleIdentifier: "com.h3zord.BrainPanel"
    )
    var secondExitCode: Int32?
    let preloadedResult = BrainPanelBootstrap.resolveConfigOrReportFailure(
      preloaded: validPreloaded,
      environmentLoader: { throw AppError.invalidConfiguration(setting: "IGNORADA") },
      logger: logger,
      exitHandler: { code in secondExitCode = code }
    )
    XCTAssertEqual(preloadedResult, validPreloaded)
    XCTAssertNil(secondExitCode)
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
