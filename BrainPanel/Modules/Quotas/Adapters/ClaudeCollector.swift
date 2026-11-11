import Foundation

/// Lê as cotas do Claude Code abrindo `/usage` em pseudo-terminal somente-leitura,
/// sem enviar prompts nem consumir tokens.
nonisolated struct ClaudeCollector: UsageCollector {
  let providerID = KnownProviderID.claude.rawValue
  private let cliEnvironment: CLIEnvironment
  private let clock: any Clock

  init(cliEnvironment: CLIEnvironment, clock: any Clock = SystemClock()) {
    self.cliEnvironment = cliEnvironment
    self.clock = clock
  }

  @concurrent
  func fetchUsage() async throws -> ProviderUsage {
    let executable = try cliEnvironment.executableURL(for: .claude)
    let directory = try cliEnvironment.workingDirectory(for: .claude)
    let environment = cliEnvironment.config.childCLIEnvironment
    let collectorClock = clock
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
              try Self.captureUsageScreen(
                executable: executable,
                directory: directory,
                environment: environment,
                clock: collectorClock,
                cancellationBox: cancellationBox
              )
            }
          )
        }
      }
    } onCancel: {
      cancellationBox.cancel()
    }

    return try ClaudeUsageParser.makeUsage(from: screen, now: clock.now())
  }

  private static func captureUsageScreen(
    executable: URL,
    directory: URL,
    environment: [String: String],
    clock: any Clock,
    cancellationBox: PTYCaptureCancellationBox
  ) throws -> String {
    let session = try PseudoTerminalSession(
      executable: executable,
      directory: directory,
      environment: environment,
      clock: clock
    )
    cancellationBox.attach(session)
    defer {
      cancellationBox.attach(nil)
      session.terminate()
    }

    session.readUntilQuiet(1.5, timeout: 20)
    if cancellationBox.isCancelled {
      throw CancellationError()
    }

    if session.text.contains("trust this folder") {
      try session.send("\u{1b}[B")
      Thread.sleep(forTimeInterval: 0.3)
      try session.send("\r")
      session.readUntilQuiet(1.5, timeout: 20)
    }
    if cancellationBox.isCancelled {
      throw CancellationError()
    }

    try session.send("/usage")
    Thread.sleep(forTimeInterval: 0.5)
    try session.send("\r")

    let loaded = session.read(timeout: 20) { text in
      ClaudeUsageParser.limits(in: text, now: clock.now()).contains { $0.id == "claude-weekly" }
    }
    if cancellationBox.isCancelled {
      throw CancellationError()
    }
    guard loaded else {
      throw AppError.collectorTimedOut(provider: .claude)
    }

    session.readUntilQuiet(0.5, timeout: 3)
    try? session.send("\u{1b}")
    return session.text
  }
}
