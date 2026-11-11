import Foundation

/// Lê as cotas do Google AI Pro / Ultra abrindo `/quota` na CLI Antigravity (`agy`)
/// em pseudo-terminal somente-leitura, sem enviar prompts.
nonisolated struct GeminiCollector: UsageCollector {
  struct Timings: Sendable {
    var startupTimeout: TimeInterval = 15
    var folderTrustDetailTimeout: TimeInterval = 1.5
    var quietPeriod: TimeInterval = 0.3
    var quietTimeout: TimeInterval = 3
    var commandSubmitDelay: TimeInterval = 0.25
    var quotaHeaderTimeout: TimeInterval = 10
    var quotaFooterTimeout: TimeInterval = 8
    var postQuotaQuietPeriod: TimeInterval = 0.1
    var postQuotaQuietTimeout: TimeInterval = 1
    var retryBackoff: TimeInterval = 0.15
  }

  private static let maxStartupAttempts = 2

  let providerID = KnownProviderID.gemini.rawValue
  private let cliEnvironment: CLIEnvironment
  private let clock: any Clock
  private let timings: Timings

  init(
    cliEnvironment: CLIEnvironment,
    clock: any Clock = SystemClock(),
    timings: Timings = Timings()
  ) {
    self.cliEnvironment = cliEnvironment
    self.clock = clock
    self.timings = timings
  }

  @concurrent
  func fetchUsage() async throws -> ProviderUsage {
    let executable = try cliEnvironment.executableURL(for: .agy)
    let directory = try cliEnvironment.workingDirectory(for: .gemini)
    let environment = cliEnvironment.config.childCLIEnvironment
    let collectorClock = clock
    let collectorTimings = timings
    let cancellationBox = PTYCaptureCancellationBox()

    if Task.isCancelled {
      cancellationBox.cancel()
      throw CancellationError()
    }

    let screen = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
          continuation.resume(
            with: Result {
              try Self.captureQuotaScreenWithRetry(
                executable: executable,
                directory: directory,
                environment: environment,
                clock: collectorClock,
                timings: collectorTimings,
                cancellationBox: cancellationBox
              )
            }
          )
        }
      }
    } onCancel: {
      cancellationBox.cancel()
    }

    return try GeminiQuotaParser.makeUsage(from: screen, now: clock.now())
  }

  private static func captureQuotaScreenWithRetry(
    executable: URL,
    directory: URL,
    environment: [String: String],
    clock: any Clock,
    timings: Timings,
    cancellationBox: PTYCaptureCancellationBox
  ) throws -> String {
    var lastError: AppError = .unauthenticatedSession(provider: .gemini, executable: .agy)

    for attempt in 1...maxStartupAttempts {
      if cancellationBox.isCancelled {
        throw CancellationError()
      }

      do {
        return try captureSingleQuotaScreen(
          executable: executable,
          directory: directory,
          environment: environment,
          clock: clock,
          timings: timings,
          cancellationBox: cancellationBox
        )
      } catch let appError {
        if cancellationBox.isCancelled {
          throw CancellationError()
        }
        lastError = appError
        let canRetry = attempt < maxStartupAttempts && shouldRetryStartupFailure(appError)
        if canRetry {
          sleepInterruptibly(timings.retryBackoff, cancellationBox: cancellationBox)
          continue
        }
        throw appError
      }
    }

    throw lastError
  }

  private static func shouldRetryStartupFailure(_ error: AppError) -> Bool {
    switch error.code {
    case .terminalUnavailable, .terminalWriteFailed, .unauthenticatedSession, .collectorTimedOut:
      true
    default:
      false
    }
  }

  private static func captureSingleQuotaScreen(
    executable: URL,
    directory: URL,
    environment: [String: String],
    clock: any Clock,
    timings: Timings,
    cancellationBox: PTYCaptureCancellationBox
  ) throws(AppError) -> String {
    let session = try PseudoTerminalSession(
      executable: executable,
      directory: directory,
      environment: environment,
      clock: clock,
      rows: 200
    )
    cancellationBox.attach(session)
    defer {
      cancellationBox.attach(nil)
      session.terminate()
    }

    var hasConfirmedTrust = false
    var hasDismissedBanner = false
    let startupDeadline = clock.now().addingTimeInterval(timings.startupTimeout)

    while clock.now() < startupDeadline && !cancellationBox.isCancelled {
      let remaining = startupDeadline.timeIntervalSince(clock.now())
      guard remaining > 0 else { break }

      let matched = session.readSession(timeout: remaining) { current in
        let action = GeminiStartupEvaluator.evaluate(
          screen: current.screen,
          hasConfirmedFolderTrust: hasConfirmedTrust,
          hasDismissedBanner: hasDismissedBanner,
          isFolderTrustPromptSettled: false
        )
        if action != .waitForMoreOutput {
          return true
        }
        return !hasConfirmedTrust && GeminiStartupEvaluator.hasFolderTrustPrompt(in: current.screen)
      }

      let action = GeminiStartupEvaluator.evaluate(
        screen: session.screen,
        hasConfirmedFolderTrust: hasConfirmedTrust,
        hasDismissedBanner: hasDismissedBanner,
        isFolderTrustPromptSettled: false
      )

      switch action {
      case .ready:
        break
      case .confirmTrustedFolder:
        hasConfirmedTrust = true
        try session.send("\r")
        continue
      case .dismissBanner:
        session.readUntilQuiet(0.05, timeout: 0.4)
        try session.send("\u{1b}")
        hasDismissedBanner = true
        continue
      case .rejectUntrustedPromptFormat, .waitForMoreOutput:
        if !hasConfirmedTrust && GeminiStartupEvaluator.hasFolderTrustPrompt(in: session.screen) {
          let settled = session.readSession(
            timeout: min(timings.folderTrustDetailTimeout, remaining)
          ) {
            $0.screen.contains(GeminiStartupEvaluator.expectedFolderTrustChoice)
          }
          if settled {
            hasConfirmedTrust = true
            try session.send("\r")
            continue
          }
          throw AppError.untrustedPromptFormat(provider: .gemini)
        }
      }

      if action == .ready || !matched {
        break
      }
    }

    let finalAction = GeminiStartupEvaluator.evaluate(
      screen: session.screen,
      hasConfirmedFolderTrust: hasConfirmedTrust,
      hasDismissedBanner: hasDismissedBanner,
      isFolderTrustPromptSettled: true
    )
    if finalAction == .rejectUntrustedPromptFormat {
      throw AppError.untrustedPromptFormat(provider: .gemini)
    }
    guard GeminiStartupEvaluator.isPromptReady(in: session.screen) else {
      throw AppError.unauthenticatedSession(provider: .gemini, executable: .agy)
    }

    session.readUntilQuiet(timings.quietPeriod, timeout: timings.quietTimeout)

    if !hasDismissedBanner && GeminiStartupEvaluator.hasDismissibleBanner(in: session.screen) {
      try session.send("\u{1b}")
      hasDismissedBanner = true
      session.readUntilQuiet(timings.quietPeriod, timeout: timings.quietTimeout)
    }

    try session.send("/quota")
    sleepInterruptibly(timings.commandSubmitDelay, cancellationBox: cancellationBox)
    try session.send("\r")

    guard session.read(timeout: timings.quotaHeaderTimeout, until: { $0.contains("Models & Quota") })
    else {
      throw AppError.collectorTimedOut(provider: .gemini)
    }

    session.read(timeout: timings.quotaFooterTimeout) { text in
      guard let start = text.range(of: "Models & Quota", options: .backwards) else {
        return false
      }
      return text[start.upperBound...].localizedCaseInsensitiveContains("within each group")
    }
    session.readUntilQuiet(timings.postQuotaQuietPeriod, timeout: timings.postQuotaQuietTimeout)

    let renderedScreen = session.screen
    let fullText = session.text
    try? session.send("\u{1b}")
    return preserveDetectedPlanIfNeeded(screen: renderedScreen, fullText: fullText)
  }

  private static func preserveDetectedPlanIfNeeded(screen: String, fullText: String) -> String {
    if screen.contains("Google AI Ultra") || screen.contains("Google AI Pro") {
      return screen
    }
    if fullText.contains("Google AI Ultra") {
      return "Google AI Ultra\n\(screen)"
    }
    if fullText.contains("Google AI Pro") {
      return "Google AI Pro\n\(screen)"
    }
    return screen
  }

  private static func sleepInterruptibly(
    _ seconds: TimeInterval,
    cancellationBox: PTYCaptureCancellationBox
  ) {
    guard seconds > 0 else { return }
    let sliceSeconds = 0.02
    let steps = max(Int((seconds / sliceSeconds).rounded(.up)), 1)
    let perStepMicroseconds = useconds_t(min(seconds / Double(steps), sliceSeconds) * 1_000_000)
    for _ in 0..<steps {
      if cancellationBox.isCancelled {
        return
      }
      usleep(perStepMicroseconds)
    }
  }
}
