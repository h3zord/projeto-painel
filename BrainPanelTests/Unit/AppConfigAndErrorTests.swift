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
    XCTAssertEqual(config.brainStateDirectory.path, "/Users/teste/.local/state")
    XCTAssertEqual(
      config.brainPendingStateDirectory.path,
      "/Users/teste/.local/state/brain-pending"
    )
    XCTAssertEqual(config.brainMailStateDirectory.path, "/Users/teste/.local/state/brain-mail")
    XCTAssertEqual(config.brainCIStateDirectory.path, "/Users/teste/.local/state/brain-ci")
    XCTAssertEqual(config.brainWeeklyStateDirectory.path, "/Users/teste/.local/state/brain-weekly")
    XCTAssertEqual(config.logsDirectory.path, "/Users/teste/Library/Logs")
    XCTAssertEqual(config.launchAgentsDirectory.path, "/Users/teste/Library/LaunchAgents")
    XCTAssertEqual(
      config.backupProgressFileURL.path,
      "/Users/teste/Brain/local/pages/backup-drive.json"
    )
    XCTAssertEqual(config.brainPagesURL.absoluteString, "http://127.0.0.1:4780/")
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
    XCTAssertFalse(config.brainStateDirectory.path.contains("/Users/teste/.local/state"))
    XCTAssertFalse(config.logsDirectory.path.contains("/Users/teste/Library/Logs"))
    XCTAssertFalse(config.launchAgentsDirectory.path.contains("/Users/teste/Library/LaunchAgents"))
    XCTAssertFalse(config.backupProgressFileURL.path.contains("/Users/teste/Brain"))
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
      environment: ["BRAIN_PANEL_BRAIN_STATE_DIR": "relativo/local-state"],
      expectedSetting: "BRAIN_PANEL_BRAIN_STATE_DIR"
    )
    assertConfigFails(
      environment: ["BRAIN_PANEL_LOGS_DIR": "/tmp/../Logs"],
      expectedSetting: "BRAIN_PANEL_LOGS_DIR"
    )
    assertConfigFails(
      environment: ["BRAIN_PANEL_LAUNCH_AGENTS_DIR": "LaunchAgents"],
      expectedSetting: "BRAIN_PANEL_LAUNCH_AGENTS_DIR"
    )
    assertConfigFails(
      environment: ["BRAIN_PANEL_BACKUP_PROGRESS_FILE": "/tmp/../backup-drive.json"],
      expectedSetting: "BRAIN_PANEL_BACKUP_PROGRESS_FILE"
    )
    assertConfigFails(
      environment: ["BRAIN_PANEL_CLI_SEARCH_PATHS": "/usr/bin:relativo"],
      expectedSetting: "BRAIN_PANEL_CLI_SEARCH_PATHS"
    )
    assertConfigFails(
      environment: ["BRAIN_PANEL_BRAIN_PAGES_URL": "https://example.com"],
      expectedSetting: "BRAIN_PANEL_BRAIN_PAGES_URL"
    )
    assertConfigFails(
      environment: ["BRAIN_PANEL_BRAIN_PAGES_URL": "http://192.168.1.50:4780/"],
      expectedSetting: "BRAIN_PANEL_BRAIN_PAGES_URL"
    )
    assertConfigFails(
      environment: ["BRAIN_PANEL_BRAIN_PAGES_URL": "http://127.0.0.1@evil.example.com:4780/"],
      expectedSetting: "BRAIN_PANEL_BRAIN_PAGES_URL"
    )
    assertConfigFails(
      environment: ["BRAIN_PANEL_BRAIN_PAGES_URL": "file:///etc/passwd"],
      expectedSetting: "BRAIN_PANEL_BRAIN_PAGES_URL"
    )
    assertConfigFails(
      environment: ["BRAIN_PANEL_BRAIN_PAGES_URL": "http://127.0.0.1:70000/"],
      expectedSetting: "BRAIN_PANEL_BRAIN_PAGES_URL"
    )
    assertConfigFails(
      environment: ["BRAIN_PANEL_BRAIN_PAGES_URL": "http://127.0.0.1:4780/../secreto"],
      expectedSetting: "BRAIN_PANEL_BRAIN_PAGES_URL"
    )
    assertConfigFails(
      environment: ["BRAIN_PANEL_BRAIN_PAGES_URL": "http://127.0.0.1:4780/%2e%2e/secreto"],
      expectedSetting: "BRAIN_PANEL_BRAIN_PAGES_URL"
    )
    assertConfigFails(
      environment: ["BRAIN_PANEL_BRAIN_PAGES_URL": "http://127.0.0.1:4780/?redirect=https://x.io"],
      expectedSetting: "BRAIN_PANEL_BRAIN_PAGES_URL"
    )
    assertConfigFails(
      environment: ["BRAIN_PANEL_BRAIN_PAGES_URL": "http://127.0.0.1:4780/#../invalido"],
      expectedSetting: "BRAIN_PANEL_BRAIN_PAGES_URL"
    )
    assertConfigFails(
      environment: ["BRAIN_PANEL_BRAIN_PAGES_URL": ""],
      expectedSetting: "BRAIN_PANEL_BRAIN_PAGES_URL"
    )
  }

  func testAcceptsLoopbackBrainPagesURLVariants() throws {
    for validURL in [
      "http://127.0.0.1:4780/",
      "http://localhost:4780/",
      "http://localhost:9000/painel",
      "http://127.0.0.1:4780/fila",
      "http://127.0.0.1:4780/brain/backup-drive",
      "http://127.0.0.1:4780/#esperando",
      "http://localhost:4780/projeto-painel/_arquivo/doc-1#secao_2-a",
      "http://127.0.0.1",
    ] {
      let parsed = try AppConfig.parse(
        environment: [
          "BRAIN_PANEL_MODE": "testing",
          "BRAIN_PANEL_BRAIN_PAGES_URL": validURL,
        ],
        defaultHomeDirectory: homeURL,
        defaultAppSupportRoot: appSupportURL,
        defaultTemporaryRoot: tempURL,
        bundleIdentifier: "com.h3zord.BrainPanel"
      )
      XCTAssertEqual(parsed.brainPagesURL.absoluteString, validURL)
    }
  }

  func testBrainTabViewOpenerOnlyDispatchesValidatedLoopbackURLs() throws {
    var openedURLs: [URL] = []
    let safeRootURL = try XCTUnwrap(URL(string: "http://127.0.0.1:4780/"))
    let safeFragmentURL = try XCTUnwrap(URL(string: "http://127.0.0.1:4780/#esperando"))
    let safeSubpathURL = try XCTUnwrap(
      URL(string: "http://localhost:4780/projeto-painel/_arquivo/doc-1#secao-1")
    )
    let externalURL = try XCTUnwrap(URL(string: "https://example.com/painel"))
    let dotDotURL = try XCTUnwrap(URL(string: "http://127.0.0.1:4780/projeto-painel/../secreto"))
    let encodedDotDotURL = try XCTUnwrap(URL(string: "http://127.0.0.1:4780/%2e%2e/secreto"))
    let queryURL = try XCTUnwrap(URL(string: "http://127.0.0.1:4780/fila?cmd=rm"))
    let badFragmentURL = try XCTUnwrap(URL(string: "http://127.0.0.1:4780/#a/b"))
    let fileURL = URL(filePath: "/etc/passwd")

    XCTAssertTrue(BrainTabView.openIfLoopbackSafe(safeRootURL) { openedURLs.append($0) })
    XCTAssertTrue(BrainTabView.openIfLoopbackSafe(safeFragmentURL) { openedURLs.append($0) })
    XCTAssertTrue(BrainTabView.openIfLoopbackSafe(safeSubpathURL) { openedURLs.append($0) })
    XCTAssertFalse(BrainTabView.openIfLoopbackSafe(externalURL) { openedURLs.append($0) })
    XCTAssertFalse(BrainTabView.openIfLoopbackSafe(dotDotURL) { openedURLs.append($0) })
    XCTAssertFalse(BrainTabView.openIfLoopbackSafe(encodedDotDotURL) { openedURLs.append($0) })
    XCTAssertFalse(BrainTabView.openIfLoopbackSafe(queryURL) { openedURLs.append($0) })
    XCTAssertFalse(BrainTabView.openIfLoopbackSafe(badFragmentURL) { openedURLs.append($0) })
    XCTAssertFalse(BrainTabView.openIfLoopbackSafe(fileURL) { openedURLs.append($0) })
    XCTAssertFalse(
      BrainTabView.dispatchIfBaseAndTargetSafe(
        targetURL: safeFragmentURL,
        baseURL: externalURL
      ) { openedURLs.append($0) }
    )
    XCTAssertTrue(
      BrainTabView.dispatchIfBaseAndTargetSafe(
        targetURL: safeSubpathURL,
        baseURL: safeRootURL
      ) { openedURLs.append($0) }
    )
    XCTAssertEqual(openedURLs, [safeRootURL, safeFragmentURL, safeSubpathURL, safeSubpathURL])
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
      AppError.brainStateReadFailed(section: .waiting),
      AppError.brainStateReadFailed(section: .ciQueue),
      AppError.brainStateReadFailed(section: .healthAndBackup),
      AppError.brainStateReadFailed(section: .scheduledJobs),
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
