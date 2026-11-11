import Foundation

nonisolated enum GeminiStartupAction: Equatable, Sendable {
  case waitForMoreOutput
  case confirmTrustedFolder
  case rejectUntrustedPromptFormat
  case dismissBanner
  case ready
}

/// Avalia de forma pura o estado visual de inicialização da CLI Antigravity (`agy`),
/// reconhecendo tanto o seletor de modo do `agy 1.5.5+` (`shift+tab to cycle`) quanto
/// o rodapé legado (`for shortcuts`), sem tratar o aviso inicial transitório
/// `"You are currently not signed in."` como falha antes da conclusão de `"Signing in..."`.
nonisolated enum GeminiStartupEvaluator {
  static let legacyReadyMarker = "for shortcuts"
  static let modeCycleReadyMarker = "shift+tab to cycle"
  static let folderTrustPromptMarker = "trust the contents"
  static let expectedFolderTrustChoice = "> Yes, I trust this folder"
  static let dismissibleBannerMarker = "esc to dismiss"

  static func isPromptReady(in screen: String) -> Bool {
    screen.localizedCaseInsensitiveContains(modeCycleReadyMarker)
      || screen.localizedCaseInsensitiveContains(legacyReadyMarker)
  }

  static func hasDismissibleBanner(in screen: String) -> Bool {
    screen.localizedCaseInsensitiveContains(dismissibleBannerMarker)
  }

  static func hasFolderTrustPrompt(in screen: String) -> Bool {
    screen.localizedCaseInsensitiveContains(folderTrustPromptMarker)
  }

  static func evaluate(
    screen: String,
    hasConfirmedFolderTrust: Bool = false,
    hasDismissedBanner: Bool = false,
    isFolderTrustPromptSettled: Bool = true
  ) -> GeminiStartupAction {
    if !hasDismissedBanner && hasDismissibleBanner(in: screen) {
      return .dismissBanner
    }

    if isPromptReady(in: screen) {
      return .ready
    }

    if !hasConfirmedFolderTrust && hasFolderTrustPrompt(in: screen) {
      if screen.contains(expectedFolderTrustChoice) {
        return .confirmTrustedFolder
      }
      return isFolderTrustPromptSettled ? .rejectUntrustedPromptFormat : .waitForMoreOutput
    }

    return .waitForMoreOutput
  }
}
