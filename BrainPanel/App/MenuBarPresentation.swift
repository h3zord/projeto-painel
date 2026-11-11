import Foundation

/// Regras puras de apresentação do rótulo da barra de menus, descrição de acessibilidade e rodapé.
nonisolated enum MenuBarPresentation {
  static func label(
    lowestRemainingPercentage: Int?,
    waitingOnOwnerCount: Int,
    hasCriticalFailure: Bool
  ) -> String {
    let quotaText = lowestRemainingPercentage.map { "\($0)%" } ?? "—"
    if hasCriticalFailure {
      return "\(quotaText) · !"
    }
    if waitingOnOwnerCount > 0 {
      return "\(quotaText) · \(waitingOnOwnerCount)"
    }
    return quotaText
  }

  static func accessibilityLabel(
    lowestRemainingPercentage: Int?,
    waitingOnOwnerCount: Int,
    hasCriticalFailure: Bool
  ) -> String {
    var parts: [String] = []
    if let lowestRemainingPercentage {
      parts.append("Brain Panel: menor cota disponível \(lowestRemainingPercentage)%")
    } else {
      parts.append("Brain Panel: cota indisponível")
    }
    if hasCriticalFailure {
      parts.append("falha crítica no Brain")
    }
    if waitingOnOwnerCount == 1 {
      parts.append("1 item esperando você")
    } else if waitingOnOwnerCount > 1 {
      parts.append("\(waitingOnOwnerCount) itens esperando você")
    }
    return parts.joined(separator: ", ")
  }

  static func footerStatusSummary(
    lastRefreshAt: Date?,
    isRefreshing: Bool,
    now: Date
  ) -> String {
    if let lastRefreshAt {
      return "Atualizado \(RelativeTimeFormatter.elapsedPhrase(since: lastRefreshAt, now: now))"
    }
    if isRefreshing {
      return "Sincronizando…"
    }
    return "Aguardando leitura"
  }
}
