import Foundation

nonisolated enum RuntimeMode: String, CaseIterable, Equatable, Sendable {
  case live = "live"
  case isolated = "isolated"
  case selfCheck = "self_check"
  case testing = "testing"
}

/// Ponto único de leitura e validação estrita de variáveis de ambiente no boot.
/// Qualquer chave `BRAIN_PANEL_*` desconhecida ou fora da faixa válida impede o boot (falhar fechado).
nonisolated struct AppConfig: Equatable, Sendable {
  static let defaultBundleIdentifier = "com.h3zord.BrainPanel"
  static let refreshIntervalRange = 10...3_600
  static let cacheTTLRange = 1...600
  static let maxPathLength = 1_024
  static let maxSearchPathEntries = 32

  private static let allowedEnvironmentKeys: Set<String> = [
    "BRAIN_PANEL_MODE",
    "BRAIN_PANEL_REFRESH_INTERVAL_SECONDS",
    "BRAIN_PANEL_CACHE_TTL_SECONDS",
    "BRAIN_PANEL_CLAUDE_SESSIONS_DIR",
    "BRAIN_PANEL_CLAUDE_PROJECTS_DIR",
    "BRAIN_PANEL_CLAUDE_CONTEXT_CACHE_DIR",
    "BRAIN_PANEL_ANTIGRAVITY_DIR",
    "BRAIN_PANEL_BRAIN_SESSIONS_STATE_DIR",
    "BRAIN_PANEL_BRAIN_STATE_DIR",
    "BRAIN_PANEL_LOGS_DIR",
    "BRAIN_PANEL_LAUNCH_AGENTS_DIR",
    "BRAIN_PANEL_BACKUP_PROGRESS_FILE",
    "BRAIN_PANEL_APP_SUPPORT_DIR",
    "BRAIN_PANEL_CLI_SEARCH_PATHS",
  ]

  private static let passthroughChildKeys = ["HOME", "USER", "LOGNAME", "TMPDIR", "SHELL"]

  let mode: RuntimeMode
  let bundleIdentifier: String
  let refreshIntervalSeconds: Int
  let cacheTTLSeconds: Int
  let claudeSessionsDirectory: URL
  let claudeProjectsDirectory: URL
  let claudeContextCacheDirectory: URL
  let antigravityDirectory: URL
  let brainSessionsStateDirectory: URL
  let brainStateDirectory: URL
  let logsDirectory: URL
  let launchAgentsDirectory: URL
  let backupProgressFileURL: URL
  let appSupportDirectory: URL
  let cliSearchPaths: [String]
  let childCLIEnvironment: [String: String]

  var refreshInterval: Duration {
    .seconds(refreshIntervalSeconds)
  }

  var cacheTTL: TimeInterval {
    TimeInterval(cacheTTLSeconds)
  }

  var brainPendingStateDirectory: URL {
    brainStateDirectory.appending(path: "brain-pending", directoryHint: .isDirectory)
  }

  var brainMailStateDirectory: URL {
    brainStateDirectory.appending(path: "brain-mail", directoryHint: .isDirectory)
  }

  var brainCIStateDirectory: URL {
    brainStateDirectory.appending(path: "brain-ci", directoryHint: .isDirectory)
  }

  var brainWeeklyStateDirectory: URL {
    brainStateDirectory.appending(path: "brain-weekly", directoryHint: .isDirectory)
  }

  static func loadFromProcessEnvironment(
    bundleIdentifier: String? = Bundle.main.bundleIdentifier
  ) throws(AppError) -> AppConfig {
    let rawEnvironment = ProcessInfo.processInfo.environment
    return try parse(
      environment: rawEnvironment,
      defaultHomeDirectory: FileManager.default.homeDirectoryForCurrentUser,
      defaultAppSupportRoot: URL.applicationSupportDirectory,
      defaultTemporaryRoot: FileManager.default.temporaryDirectory,
      bundleIdentifier: bundleIdentifier
    )
  }

  static func parse(
    environment: [String: String],
    defaultHomeDirectory: URL,
    defaultAppSupportRoot: URL,
    defaultTemporaryRoot: URL,
    bundleIdentifier: String?
  ) throws(AppError) -> AppConfig {
    for key in environment.keys.sorted() where key.hasPrefix("BRAIN_PANEL_") {
      guard allowedEnvironmentKeys.contains(key) else {
        throw AppError.invalidConfiguration(setting: key)
      }
    }

    let resolvedBundleID = try validateBundleIdentifier(
      bundleIdentifier ?? Self.defaultBundleIdentifier)
    let mode = try parseMode(from: environment)
    let refreshSeconds = try parseBoundedInt(
      key: "BRAIN_PANEL_REFRESH_INTERVAL_SECONDS",
      in: environment,
      defaultValue: 300,
      allowedRange: Self.refreshIntervalRange
    )
    let cacheTTLSeconds = try parseBoundedInt(
      key: "BRAIN_PANEL_CACHE_TTL_SECONDS",
      in: environment,
      defaultValue: 60,
      allowedRange: Self.cacheTTLRange
    )

    let isolatedRoot =
      defaultTemporaryRoot
      .appending(path: "brain-panel-isolated", directoryHint: .isDirectory)

    let defaultSessionsDir: URL
    let defaultProjectsDir: URL
    let defaultContextCacheDir: URL
    let defaultAntigravityDir: URL
    let defaultBrainStateDir: URL
    let defaultLogsDir: URL
    let defaultLaunchAgentsDir: URL
    let defaultBackupProgressFile: URL
    let defaultSupportDir: URL
    let defaultSearchPaths: [String]

    switch mode {
    case .live:
      let homePath = try validateAbsolutePath(
        defaultHomeDirectory.path,
        setting: "HOME"
      )
      let homeURL = URL(filePath: homePath, directoryHint: .isDirectory)
      defaultSessionsDir = homeURL.appending(path: ".claude/sessions", directoryHint: .isDirectory)
      defaultProjectsDir = homeURL.appending(path: ".claude/projects", directoryHint: .isDirectory)
      defaultContextCacheDir = homeURL.appending(
        path: ".cache/claude-context",
        directoryHint: .isDirectory
      )
      defaultAntigravityDir = homeURL.appending(
        path: ".gemini/antigravity-cli",
        directoryHint: .isDirectory
      )
      defaultBrainStateDir = homeURL.appending(
        path: ".local/state",
        directoryHint: .isDirectory
      )
      defaultLogsDir = homeURL.appending(
        path: "Library/Logs",
        directoryHint: .isDirectory
      )
      defaultLaunchAgentsDir = homeURL.appending(
        path: "Library/LaunchAgents",
        directoryHint: .isDirectory
      )
      defaultBackupProgressFile = homeURL.appending(
        path: "Brain/local/pages/backup-drive.json",
        directoryHint: .notDirectory
      )
      defaultSupportDir = defaultAppSupportRoot.appending(
        path: resolvedBundleID,
        directoryHint: .isDirectory
      )
      defaultSearchPaths = [
        "\(homePath)/.local/bin",
        "\(homePath)/.npm-global/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
      ]
    case .isolated, .selfCheck, .testing:
      defaultSessionsDir = isolatedRoot.appending(
        path: "claude-sessions", directoryHint: .isDirectory)
      defaultProjectsDir = isolatedRoot.appending(
        path: "claude-projects", directoryHint: .isDirectory)
      defaultContextCacheDir = isolatedRoot.appending(
        path: "claude-context",
        directoryHint: .isDirectory
      )
      defaultAntigravityDir = isolatedRoot.appending(
        path: "antigravity-cli",
        directoryHint: .isDirectory
      )
      defaultBrainStateDir = isolatedRoot.appending(
        path: "local-state",
        directoryHint: .isDirectory
      )
      defaultLogsDir = isolatedRoot.appending(
        path: "logs",
        directoryHint: .isDirectory
      )
      defaultLaunchAgentsDir = isolatedRoot.appending(
        path: "launch-agents",
        directoryHint: .isDirectory
      )
      defaultBackupProgressFile = isolatedRoot.appending(
        path: "pages/backup-drive.json",
        directoryHint: .notDirectory
      )
      defaultSupportDir = isolatedRoot.appending(path: "app-support", directoryHint: .isDirectory)
      defaultSearchPaths = [
        isolatedRoot.appending(path: "empty-bin", directoryHint: .isDirectory).path
      ]
    }

    let claudeSessionsDirectory = try parseOptionalDirectory(
      key: "BRAIN_PANEL_CLAUDE_SESSIONS_DIR",
      in: environment,
      defaultURL: defaultSessionsDir
    )
    let claudeProjectsDirectory = try parseOptionalDirectory(
      key: "BRAIN_PANEL_CLAUDE_PROJECTS_DIR",
      in: environment,
      defaultURL: defaultProjectsDir
    )
    let claudeContextCacheDirectory = try parseOptionalDirectory(
      key: "BRAIN_PANEL_CLAUDE_CONTEXT_CACHE_DIR",
      in: environment,
      defaultURL: defaultContextCacheDir
    )
    let antigravityDirectory = try parseOptionalDirectory(
      key: "BRAIN_PANEL_ANTIGRAVITY_DIR",
      in: environment,
      defaultURL: defaultAntigravityDir
    )
    let brainStateDirectory = try parseOptionalDirectory(
      key: "BRAIN_PANEL_BRAIN_STATE_DIR",
      in: environment,
      defaultURL: defaultBrainStateDir
    )
    let defaultBrainSessionsStateDir = brainStateDirectory.appending(
      path: "brain-sessions",
      directoryHint: .isDirectory
    )
    let brainSessionsStateDirectory = try parseOptionalDirectory(
      key: "BRAIN_PANEL_BRAIN_SESSIONS_STATE_DIR",
      in: environment,
      defaultURL: defaultBrainSessionsStateDir
    )
    let logsDirectory = try parseOptionalDirectory(
      key: "BRAIN_PANEL_LOGS_DIR",
      in: environment,
      defaultURL: defaultLogsDir
    )
    let launchAgentsDirectory = try parseOptionalDirectory(
      key: "BRAIN_PANEL_LAUNCH_AGENTS_DIR",
      in: environment,
      defaultURL: defaultLaunchAgentsDir
    )
    let backupProgressFileURL = try parseOptionalFile(
      key: "BRAIN_PANEL_BACKUP_PROGRESS_FILE",
      in: environment,
      defaultURL: defaultBackupProgressFile
    )
    let appSupportDirectory = try parseOptionalDirectory(
      key: "BRAIN_PANEL_APP_SUPPORT_DIR",
      in: environment,
      defaultURL: defaultSupportDir
    )
    let cliSearchPaths = try parseSearchPaths(
      in: environment,
      defaultPaths: defaultSearchPaths
    )

    var childEnv: [String: String] = [:]
    for key in passthroughChildKeys {
      if let value = environment[key], !value.isEmpty, !value.contains("\0") {
        childEnv[key] = value
      }
    }
    childEnv["PATH"] = cliSearchPaths.joined(separator: ":")
    childEnv["LANG"] = "en_US.UTF-8"
    childEnv["TERM"] = "xterm-256color"

    return AppConfig(
      mode: mode,
      bundleIdentifier: resolvedBundleID,
      refreshIntervalSeconds: refreshSeconds,
      cacheTTLSeconds: cacheTTLSeconds,
      claudeSessionsDirectory: claudeSessionsDirectory,
      claudeProjectsDirectory: claudeProjectsDirectory,
      claudeContextCacheDirectory: claudeContextCacheDirectory,
      antigravityDirectory: antigravityDirectory,
      brainSessionsStateDirectory: brainSessionsStateDirectory,
      brainStateDirectory: brainStateDirectory,
      logsDirectory: logsDirectory,
      launchAgentsDirectory: launchAgentsDirectory,
      backupProgressFileURL: backupProgressFileURL,
      appSupportDirectory: appSupportDirectory,
      cliSearchPaths: cliSearchPaths,
      childCLIEnvironment: childEnv
    )
  }

  private static func parseMode(from environment: [String: String]) throws(AppError) -> RuntimeMode {
    if let rawMode = environment["BRAIN_PANEL_MODE"] {
      guard let parsed = RuntimeMode(rawValue: rawMode) else {
        throw AppError.invalidConfiguration(setting: "BRAIN_PANEL_MODE")
      }
      return parsed
    }

    if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
      return .testing
    }
    return .live
  }

  private static func parseBoundedInt(
    key: String,
    in environment: [String: String],
    defaultValue: Int,
    allowedRange: ClosedRange<Int>
  ) throws(AppError) -> Int {
    guard let raw = environment[key] else {
      return defaultValue
    }
    guard let parsed = Int(raw), allowedRange.contains(parsed) else {
      throw AppError.invalidConfiguration(setting: key)
    }
    return parsed
  }

  private static func parseOptionalDirectory(
    key: String,
    in environment: [String: String],
    defaultURL: URL
  ) throws(AppError) -> URL {
    guard let raw = environment[key] else {
      return defaultURL
    }
    let validated = try validateAbsolutePath(raw, setting: key)
    return URL(filePath: validated, directoryHint: .isDirectory)
  }

  private static func parseOptionalFile(
    key: String,
    in environment: [String: String],
    defaultURL: URL
  ) throws(AppError) -> URL {
    guard let raw = environment[key] else {
      return defaultURL
    }
    let validated = try validateAbsolutePath(raw, setting: key)
    return URL(filePath: validated, directoryHint: .notDirectory)
  }

  private static func parseSearchPaths(
    in environment: [String: String],
    defaultPaths: [String]
  ) throws(AppError) -> [String] {
    guard let raw = environment["BRAIN_PANEL_CLI_SEARCH_PATHS"] else {
      return defaultPaths
    }
    let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard !parts.isEmpty, parts.count <= maxSearchPathEntries else {
      throw AppError.invalidConfiguration(setting: "BRAIN_PANEL_CLI_SEARCH_PATHS")
    }
    var validatedPaths: [String] = []
    validatedPaths.reserveCapacity(parts.count)
    for part in parts {
      let clean = try validateAbsolutePath(part, setting: "BRAIN_PANEL_CLI_SEARCH_PATHS")
      validatedPaths.append(clean)
    }
    return validatedPaths
  }

  private static func validateAbsolutePath(
    _ path: String,
    setting: String
  ) throws(AppError) -> String {
    guard
      !path.isEmpty,
      path.count <= maxPathLength,
      !path.contains("\0"),
      path.hasPrefix("/")
    else {
      throw AppError.invalidConfiguration(setting: setting)
    }

    let segments = path.split(separator: "/")
    guard !segments.contains("..") else {
      throw AppError.invalidConfiguration(setting: setting)
    }
    return path
  }

  private static func validateBundleIdentifier(_ identifier: String) throws(AppError) -> String {
    let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 128, !trimmed.contains("\0") else {
      throw AppError.invalidConfiguration(setting: "CFBundleIdentifier")
    }
    return trimmed
  }
}
