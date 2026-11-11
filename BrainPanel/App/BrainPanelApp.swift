import Darwin
import Foundation
import SwiftUI

@MainActor
enum BrainPanelRuntime {
  static var config: AppConfig?
}

@main
enum BrainPanelBootstrap {
  static func main() {
    let clock = SystemClock()
    let logger = StructuredLogger(clock: clock)
    let config = requireValidatedConfig(logger: logger)

    if config.mode == .selfCheck {
      runSelfCheck(config: config, clock: clock, logger: logger)
      return
    }
    BrainPanelRuntime.config = config
    BrainPanelApp.main()
  }

  nonisolated static func resolveConfigOrReportFailure(
    preloaded: AppConfig? = nil,
    environmentLoader: () throws -> AppConfig = {
      try AppConfig.loadFromProcessEnvironment()
    },
    logger: StructuredLogger,
    exitHandler: (Int32) -> Void = { Darwin.exit($0) }
  ) -> AppConfig? {
    if let preloaded {
      return preloaded
    }

    do {
      return try environmentLoader()
    } catch {
      let appError = ErrorHandler.normalize(error)
      var fields: [LogFieldKey: String] = [.status: "boot_failed"]
      if let setting = appError.safeSettingName {
        fields[.setting] = setting
      }
      logger.error(
        event: "boot_failed",
        refreshID: "boot",
        errorCode: appError.code,
        fields: fields
      )
      exitHandler(EXIT_FAILURE)
      return nil
    }
  }

  static func requireValidatedConfig(
    preloaded: AppConfig? = nil,
    logger: StructuredLogger
  ) -> AppConfig {
    if let config = resolveConfigOrReportFailure(preloaded: preloaded, logger: logger) {
      return config
    }
    Darwin.exit(EXIT_FAILURE)
  }

  private static func runSelfCheck(
    config: AppConfig,
    clock: any Clock,
    logger: StructuredLogger
  ) {
    let store = UsageStore.makeForRuntime(config: config, clock: clock, logger: logger)
    guard store.providers.count == 2, store.menuBarLabel == "—" else {
      logger.error(
        event: "self_check_failed",
        refreshID: "self-check",
        errorCode: .internalFailure,
        fields: [.mode: config.mode.rawValue]
      )
      Darwin.exit(EXIT_FAILURE)
    }

    logger.info(
      event: "self_check_passed",
      refreshID: "self-check",
      fields: [
        .mode: config.mode.rawValue,
        .bundleID: config.bundleIdentifier,
        .status: "ok",
      ]
    )
  }
}

struct BrainPanelApp: App {
  @State private var usageStore: UsageStore

  init() {
    let clock = SystemClock()
    let logger = StructuredLogger(clock: clock)
    let config = BrainPanelBootstrap.requireValidatedConfig(
      preloaded: BrainPanelRuntime.config,
      logger: logger
    )
    _usageStore = State(
      initialValue: UsageStore.makeForRuntime(config: config, clock: clock, logger: logger)
    )
  }

  var body: some Scene {
    MenuBarExtra {
      ContentView(store: usageStore)
    } label: {
      Label(usageStore.menuBarLabel, image: "MenuBarIcon")
    }
    .menuBarExtraStyle(.window)
  }
}
