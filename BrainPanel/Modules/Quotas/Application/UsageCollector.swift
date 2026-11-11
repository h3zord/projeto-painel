import Foundation

/// Porta de leitura de cotas de um provedor autenticado localmente.
nonisolated protocol UsageCollector: Sendable {
  var providerID: String { get }
  func fetchUsage() async throws -> ProviderUsage
}

/// Regra de aplicação do módulo de Cotas: preserva a última leitura ativa quando uma
/// coleta posterior falha e converte falhas iniciais em mensagens seguras de `AppError`.
nonisolated enum QuotaCollectionOutcome: Equatable, Sendable {
  case updated(ProviderUsage)
  case preservedActive(AppError)
  case markedUnavailable(ProviderUsage, AppError)
  case ignoredUnknownProvider
}

nonisolated enum QuotaStateReducer {
  static func apply(
    result: Result<ProviderUsage, any Error>,
    for providerID: String,
    into providers: inout [ProviderUsage]
  ) -> QuotaCollectionOutcome {
    guard let index = providers.firstIndex(where: { $0.id == providerID }) else {
      return .ignoredUnknownProvider
    }

    switch result {
    case .success(let usage):
      providers[index] = usage
      return .updated(usage)
    case .failure(let rawError):
      let appError = ErrorHandler.normalize(rawError)
      if providers[index].sessionState == .active {
        return .preservedActive(appError)
      }
      let updated = providers[index].unavailable(appError.userMessage)
      providers[index] = updated
      return .markedUnavailable(updated, appError)
    }
  }
}
