import Foundation

/// Lê as cotas do Google AI Pro / Ultra abrindo `/quota` na CLI Antigravity (`agy`)
/// em pseudo-terminal somente-leitura, sem enviar prompts.
nonisolated struct GeminiCollector: UsageCollector {
  let providerID = KnownProviderID.gemini.rawValue
  private let cliEnvironment: CLIEnvironment
  private let clock: any Clock

  init(cliEnvironment: CLIEnvironment, clock: any Clock = SystemClock()) {
    self.cliEnvironment = cliEnvironment
    self.clock = clock
  }

  @concurrent
  func fetchUsage() async throws -> ProviderUsage {
    let executable = try cliEnvironment.executableURL(for: .agy)
    let directory = try cliEnvironment.workingDirectory(for: .gemini)
    let environment = cliEnvironment.config.childCLIEnvironment
    let collectorClock = clock

    let screen = try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(
          with: Result {
            try Self.captureQuotaScreen(
              executable: executable,
              directory: directory,
              environment: environment,
              clock: collectorClock
            )
          }
        )
      }
    }

    return try GeminiQuotaParser.makeUsage(from: screen, now: clock.now())
  }

  private static func captureQuotaScreen(
    executable: URL,
    directory: URL,
    environment: [String: String],
    clock: any Clock
  ) throws(AppError) -> String {
    let session = try PseudoTerminalSession(
      executable: executable,
      directory: directory,
      environment: environment,
      clock: clock,
      rows: 200
    )
    defer { session.terminate() }

    let isReady: (String) -> Bool = { $0.contains("for shortcuts") }
    session.read(timeout: 15) { isReady($0) || $0.contains("trust the contents") }

    if !isReady(session.text), session.text.contains("trust the contents") {
      guard session.text.contains("> Yes, I trust this folder") else {
        throw AppError.untrustedPromptFormat(provider: .gemini)
      }
      try session.send("\r")
      session.read(timeout: 15, until: isReady)
    }

    guard isReady(session.text) else {
      throw AppError.unauthenticatedSession(provider: .gemini, executable: .agy)
    }
    session.readUntilQuiet(0.3, timeout: 3)

    try session.send("/quota")
    Thread.sleep(forTimeInterval: 0.25)
    try session.send("\r")

    guard session.read(timeout: 10, until: { $0.contains("Models & Quota") }) else {
      throw AppError.collectorTimedOut(provider: .gemini)
    }

    session.read(timeout: 8) { text in
      guard let start = text.range(of: "Models & Quota", options: .backwards) else {
        return false
      }
      return text[start.upperBound...].contains("Within each group")
    }

    let screen = session.screen
    try? session.send("\u{1b}")
    return screen
  }
}
