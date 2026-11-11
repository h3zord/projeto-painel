import Foundation

/// Porta de leitura das conversas ativas locais.
nonisolated protocol ConversationCollecting: Sendable {
  func fetchActiveConversations() async throws -> [ActiveConversation]
}
