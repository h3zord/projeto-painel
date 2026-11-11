import Foundation

/// Resolve executáveis de CLIs locais e prepara diretórios privados de trabalho
/// a partir da configuração validada (`AppConfig`), sem ler o ambiente diretamente.
nonisolated struct CLIEnvironment: Sendable {
  let config: AppConfig

  func executableURL(for executable: KnownCLIExecutable) throws(AppError) -> URL {
    for directory in config.cliSearchPaths {
      let path = "\(directory)/\(executable.rawValue)"
      if FileManager.default.isExecutableFile(atPath: path) {
        return URL(filePath: path)
      }
    }
    throw AppError.executableNotFound(executable)
  }

  /// Diretório privado por provedor para evitar que prompts de confiança ou estado local
  /// das CLIs toquem repositórios reais do usuário.
  func workingDirectory(for provider: KnownProviderID) throws(AppError) -> URL {
    let directory = config.appSupportDirectory.appending(
      path: provider.rawValue,
      directoryHint: .isDirectory
    )
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      return directory
    } catch {
      throw AppError.workingDirectoryUnavailable(provider: provider)
    }
  }
}
