import Foundation
import XCTest

@testable import BrainPanel

final class ArchitectureTests: XCTestCase {
  struct SourceUnit {
    let relativePath: String
    let content: String
  }

  func testProjectRespectsCleanArchitectureAndModuleBoundaries() throws {
    let repoRoot = Self.repositoryRoot()
    let brainPanelRoot = repoRoot.appending(path: "BrainPanel", directoryHint: .isDirectory)

    let requiredDirectories = [
      "App",
      "Modules/Quotas/Domain",
      "Modules/Quotas/Application",
      "Modules/Quotas/Adapters",
      "Modules/Sessions/Domain",
      "Modules/Sessions/Application",
      "Modules/Sessions/Adapters",
      "Shared/Config",
      "Shared/Clock",
      "Shared/Errors",
      "Shared/Logging",
      "Shared/Terminal",
    ]

    for relative in requiredDirectories {
      let dirURL = brainPanelRoot.appending(path: relative, directoryHint: .isDirectory)
      var isDirectory: ObjCBool = false
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDirectory)
          && isDirectory.boolValue,
        "Diretório obrigatório ausente: BrainPanel/\(relative)"
      )
    }

    let units = try Self.loadSourceUnits(in: brainPanelRoot)
    XCTAssertFalse(units.isEmpty)

    let violations = Self.evaluateArchitecture(units: units)
    XCTAssertTrue(
      violations.isEmpty,
      "Violações de arquitetura encontradas:\n" + violations.joined(separator: "\n")
    )
  }

  func testArchitectureEvaluatorCatchesPlantedViolations() {
    let syntheticUnits: [SourceUnit] = [
      SourceUnit(
        relativePath: "Shared/Terminal/PseudoTerminalSession.swift",
        content: "final class PseudoTerminalSession {}"
      ),
      SourceUnit(
        relativePath: "Modules/Quotas/Domain/ProviderUsage.swift",
        content: "import SwiftUI\nstruct ProviderUsage { let pty: PseudoTerminalSession? }"
      ),
      SourceUnit(
        relativePath: "Modules/Quotas/Adapters/ClaudeCollector.swift",
        content: "struct ClaudeCollector {}"
      ),
      SourceUnit(
        relativePath: "Modules/Sessions/Domain/ActiveConversation.swift",
        content: "import SQLite3\nstruct ActiveConversation { let leaked: ProviderUsage? }"
      ),
      SourceUnit(
        relativePath: "Modules/Sessions/Application/ConversationCollecting.swift",
        content: "import SQLite3\nprotocol ConversationCollecting { func bad(_ c: ClaudeCollector) }"
      ),
    ]

    let violations = Self.evaluateArchitecture(units: syntheticUnits)
    XCTAssertGreaterThanOrEqual(
      violations.count, 6, "Esperava flagrar todas as violações plantadas: \(violations)")
  }

  static func evaluateArchitecture(units: [SourceUnit]) -> [String] {
    var violations: [String] = []

    struct DeclaredSymbol {
      let name: String
      let path: String
      let category: String
      let moduleName: String?
    }

    var symbols: [DeclaredSymbol] = []
    for unit in units {
      let stripped = stripCommentsAndStrings(unit.content)
      let category = classifyCategory(path: unit.relativePath)
      let moduleName = extractModuleName(path: unit.relativePath)
      for typeName in extractDeclaredTypes(in: stripped) {
        symbols.append(
          DeclaredSymbol(
            name: typeName,
            path: unit.relativePath,
            category: category,
            moduleName: moduleName
          )
        )
      }
    }

    let domainForbiddenImports: Set<String> = [
      "SwiftUI", "AppKit", "Darwin", "OSLog", "Observation", "SQLite3",
    ]
    let applicationForbiddenImports: Set<String> = ["SwiftUI", "AppKit", "Darwin", "SQLite3"]

    let domainForbiddenCategories: Set<String> = [
      "module.application",
      "module.adapters",
      "app",
      "shared.config",
      "shared.logging",
      "shared.terminal",
    ]
    let applicationForbiddenCategories: Set<String> = [
      "module.adapters",
      "app",
      "shared.terminal",
    ]

    for unit in units {
      let stripped = stripCommentsAndStrings(unit.content)
      let imports = extractImports(in: stripped)
      let tokens = extractIdentifiers(in: stripped)
      let category = classifyCategory(path: unit.relativePath)
      let currentModule = extractModuleName(path: unit.relativePath)

      if category == "module.domain" {
        for imported in imports where domainForbiddenImports.contains(imported) {
          violations.append("\(unit.relativePath): Domain não pode importar '\(imported)'")
        }
        for symbol in symbols where domainForbiddenCategories.contains(symbol.category) {
          if tokens.contains(symbol.name) {
            violations.append(
              "\(unit.relativePath): Domain referencia tipo externo '\(symbol.name)' (\(symbol.path))"
            )
          }
        }
      }

      if category == "module.application" {
        for imported in imports where applicationForbiddenImports.contains(imported) {
          violations.append("\(unit.relativePath): Application não pode importar '\(imported)'")
        }
        for symbol in symbols where applicationForbiddenCategories.contains(symbol.category) {
          if tokens.contains(symbol.name) {
            violations.append(
              "\(unit.relativePath): Application referencia adaptador/infra '\(symbol.name)' (\(symbol.path))"
            )
          }
        }
      }

      if let currentModule {
        for symbol in symbols {
          guard let targetModule = symbol.moduleName, targetModule != currentModule else {
            continue
          }
          let isInternalToOtherModule =
            symbol.category == "module.domain" || symbol.category == "module.adapters"
          if isInternalToOtherModule, tokens.contains(symbol.name) {
            violations.append(
              "\(unit.relativePath): Módulo '\(currentModule)' acessa tipo interno '\(symbol.name)' do módulo '\(targetModule)' (\(symbol.path))"
            )
          }
        }
      }
    }

    return violations
  }

  private static func classifyCategory(path: String) -> String {
    if path.hasPrefix("App/") { return "app" }
    if path.hasPrefix("Shared/Config/") { return "shared.config" }
    if path.hasPrefix("Shared/Clock/") { return "shared.clock" }
    if path.hasPrefix("Shared/Errors/") { return "shared.errors" }
    if path.hasPrefix("Shared/Logging/") { return "shared.logging" }
    if path.hasPrefix("Shared/Terminal/") { return "shared.terminal" }
    if path.hasPrefix("Modules/") {
      if path.contains("/Domain/") { return "module.domain" }
      if path.contains("/Application/") { return "module.application" }
      if path.contains("/Adapters/") { return "module.adapters" }
    }
    return "other"
  }

  private static func extractModuleName(path: String) -> String? {
    let parts = path.split(separator: "/")
    guard parts.count >= 3, parts[0] == "Modules" else { return nil }
    return String(parts[1])
  }

  private static func extractImports(in code: String) -> [String] {
    let pattern = #/(?m)^\s*import\s+([A-Za-z0-9_]+)/#
    return code.matches(of: pattern).map { String($0.output.1) }
  }

  private static func extractDeclaredTypes(in code: String) -> [String] {
    let pattern =
      #/(?m)^(?:@[A-Za-z0-9_]+\s+)*(?:(?:public|internal|package|nonisolated|final)\s+)*(?:struct|class|enum|protocol|actor)\s+([A-Za-z_][A-Za-z0-9_]*)/#
    return code.matches(of: pattern).map { String($0.output.1) }
  }

  private static func extractIdentifiers(in code: String) -> Set<String> {
    let pattern = #/\b([A-Za-z_][A-Za-z0-9_]*)\b/#
    var result: Set<String> = []
    for match in code.matches(of: pattern) {
      result.insert(String(match.output.1))
    }
    return result
  }

  private static func stripCommentsAndStrings(_ source: String) -> String {
    var output = ""
    output.reserveCapacity(source.count)
    let chars = Array(source)
    var index = 0

    while index < chars.count {
      if index + 1 < chars.count, chars[index] == "/", chars[index + 1] == "/" {
        while index < chars.count, chars[index] != "\n" {
          index += 1
        }
        continue
      }
      if index + 1 < chars.count, chars[index] == "/", chars[index + 1] == "*" {
        index += 2
        while index + 1 < chars.count, !(chars[index] == "*" && chars[index + 1] == "/") {
          if chars[index] == "\n" { output.append("\n") }
          index += 1
        }
        index += 2
        continue
      }
      if chars[index] == "\"" {
        index += 1
        while index < chars.count {
          if chars[index] == "\\" {
            index += 2
            continue
          }
          if chars[index] == "\"" {
            index += 1
            break
          }
          if chars[index] == "\n" { output.append("\n") }
          index += 1
        }
        output.append(" ")
        continue
      }
      output.append(chars[index])
      index += 1
    }

    return output
  }

  private static func loadSourceUnits(in root: URL) throws -> [SourceUnit] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }

    var units: [SourceUnit] = []
    let prefix = root.standardizedFileURL.path + "/"

    for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
      let fullPath = fileURL.standardizedFileURL.path
      guard fullPath.hasPrefix(prefix) else { continue }
      let relative = String(fullPath.dropFirst(prefix.count))
      let content = try String(contentsOf: fileURL, encoding: .utf8)
      units.append(SourceUnit(relativePath: relative, content: content))
    }

    return units.sorted { $0.relativePath < $1.relativePath }
  }

  private static func repositoryRoot() -> URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
