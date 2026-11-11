import Foundation

/// Porta única de acesso ao tempo no aplicativo.
/// Nenhum arquivo fora de `Shared/Clock` pode ler `Date()` ou `Date.now`.
nonisolated protocol Clock: Sendable {
  func now() -> Date
  func sleep(for duration: Duration) async throws
}

nonisolated struct SystemClock: Clock {
  func now() -> Date {
    Date.now
  }

  func sleep(for duration: Duration) async throws {
    try await Task.sleep(for: duration)
  }
}
