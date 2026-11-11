import Foundation

/// Porta de leitura do estado local somente-leitura do ecossistema Brain.
nonisolated protocol BrainStateCollecting: Sendable {
  func fetchBrainState() async throws -> BrainSnapshot
}
