import Foundation

/// Códigos de erro estáveis e enumerados do Brain Panel.
/// Toda decisão programática usa `AppErrorCode`, nunca o texto de `userMessage`.
nonisolated enum AppErrorCode: String, CaseIterable, Equatable, Sendable, Codable {
  case invalidConfiguration = "CONFIG_INVALID"
  case executableNotFound = "CLI_NOT_FOUND"
  case workingDirectoryUnavailable = "WORKDIR_UNAVAILABLE"
  case terminalUnavailable = "PTY_UNAVAILABLE"
  case terminalWriteFailed = "PTY_WRITE_FAILED"
  case collectorTimedOut = "COLLECTOR_TIMEOUT"
  case unauthenticatedSession = "CLI_UNAUTHENTICATED"
  case untrustedPromptFormat = "CLI_TRUST_PROMPT_UNKNOWN"
  case unexpectedOutputFormat = "OUTPUT_PARSE_FAILED"
  case transcriptReadFailed = "TRANSCRIPT_READ_FAILED"
  case internalFailure = "INTERNAL_FAILURE"
}

nonisolated enum KnownCLIExecutable: String, CaseIterable, Equatable, Sendable {
  case claude = "claude"
  case agy = "agy"
}

nonisolated enum KnownProviderID: String, CaseIterable, Equatable, Sendable {
  case claude = "claude"
  case gemini = "gemini"

  var displayName: String {
    switch self {
    case .claude:
      "Claude"
    case .gemini:
      "Gemini"
    }
  }
}

/// Erro estruturado da aplicação. `userMessage` contém apenas texto seguro para exibição na UI,
/// sem interpolar saídas cruas de processos externos, caminhos privados ou exceções do sistema.
nonisolated struct AppError: Error, Equatable, Sendable {
  let code: AppErrorCode
  let userMessage: String
  let safeSettingName: String?

  private init(code: AppErrorCode, userMessage: String, safeSettingName: String? = nil) {
    self.code = code
    self.userMessage = userMessage
    self.safeSettingName = safeSettingName
  }

  static func invalidConfiguration(setting: String) -> AppError {
    let cleanSetting = Self.sanitizeIdentifier(setting)
    return AppError(
      code: .invalidConfiguration,
      userMessage: "Configuração inválida em \(cleanSetting). Verifique as variáveis BRAIN_PANEL_*.",
      safeSettingName: cleanSetting
    )
  }

  static func executableNotFound(_ executable: KnownCLIExecutable) -> AppError {
    AppError(
      code: .executableNotFound,
      userMessage: "CLI '\(executable.rawValue)' não encontrada nos diretórios configurados."
    )
  }

  static func workingDirectoryUnavailable(provider: KnownProviderID) -> AppError {
    AppError(
      code: .workingDirectoryUnavailable,
      userMessage: "Não foi possível preparar o diretório isolado de trabalho para \(provider.displayName)."
    )
  }

  static func terminalUnavailable() -> AppError {
    AppError(
      code: .terminalUnavailable,
      userMessage: "Não foi possível abrir o pseudo-terminal local de leitura."
    )
  }

  static func terminalWriteFailed() -> AppError {
    AppError(
      code: .terminalWriteFailed,
      userMessage: "Falha ao enviar o comando de consulta ao pseudo-terminal."
    )
  }

  static func collectorTimedOut(provider: KnownProviderID) -> AppError {
    AppError(
      code: .collectorTimedOut,
      userMessage: "Tempo esgotado ao consultar as cotas de \(provider.displayName)."
    )
  }

  static func unauthenticatedSession(provider: KnownProviderID, executable: KnownCLIExecutable) -> AppError {
    AppError(
      code: .unauthenticatedSession,
      userMessage:
        "\(provider.displayName) não iniciou pronto; confira o login na CLI '\(executable.rawValue)'."
    )
  }

  static func untrustedPromptFormat(provider: KnownProviderID) -> AppError {
    AppError(
      code: .untrustedPromptFormat,
      userMessage: "Confirmação de diretório de \(provider.displayName) em formato desconhecido."
    )
  }

  static func unexpectedOutputFormat(provider: KnownProviderID) -> AppError {
    AppError(
      code: .unexpectedOutputFormat,
      userMessage: "Formato inesperado na tela de cotas de \(provider.displayName)."
    )
  }

  static func transcriptReadFailed() -> AppError {
    AppError(
      code: .transcriptReadFailed,
      userMessage: "Não foi possível ler o registro local de sessões ativas."
    )
  }

  static func internalFailure() -> AppError {
    AppError(
      code: .internalFailure,
      userMessage: "Falha interna ao atualizar os dados. Tente atualizar novamente."
    )
  }

  private static func sanitizeIdentifier(_ raw: String) -> String {
    let filtered = raw.prefix(64).filter { char in
      char.isASCII && (char.isLetter || char.isNumber || char == "_" || char == "-")
    }
    return filtered.isEmpty ? "DESCONHECIDA" : String(filtered)
  }
}

/// Handler global que converte qualquer falha em `AppError` sem vazar detalhes internos.
nonisolated enum ErrorHandler {
  static func normalize(_ error: any Error) -> AppError {
    if let appError = error as? AppError {
      return appError
    }
    return AppError.internalFailure()
  }
}
