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

    do {
      let config = try AppConfig.loadFromProcessEnvironment()
      if config.mode == .selfCheck {
        runSelfCheck(config: config, clock: clock, logger: logger)
        return
      }
      BrainPanelRuntime.config = config
      BrainPanelApp.main()
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
      Darwin.exit(EXIT_FAILURE)
    }
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
    if let preloaded = BrainPanelRuntime.config {
      _usageStore = State(
        initialValue: UsageStore.makeForRuntime(config: preloaded, clock: clock, logger: logger)
      )
    } else if let loaded = try? AppConfig.loadFromProcessEnvironment() {
      _usageStore = State(
        initialValue: UsageStore.makeForRuntime(config: loaded, clock: clock, logger: logger)
      )
    } else {
      _usageStore = State(
        initialValue: UsageStore(
          collectors: [],
          conversationCollector: nil,
          clock: clock,
          logger: logger,
          startPeriodicRefresh: false
        )
      )
    }
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
