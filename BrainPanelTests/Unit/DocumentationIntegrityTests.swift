import Foundation
import XCTest

@testable import BrainPanel

final class DocumentationIntegrityTests: XCTestCase {
  func testAgentsClaudeReadmeAndADRsMatchRepositoryReality() throws {
    let repoRoot = Self.repositoryRoot()
    let makefileURL = repoRoot.appending(path: "Makefile")
    let makefileContent = try String(contentsOf: makefileURL, encoding: .utf8)
    let declaredTargets = Self.extractMakefileTargets(from: makefileContent)

    let agentsContent = try String(
      contentsOf: repoRoot.appending(path: "AGENTS.md"),
      encoding: .utf8
    )
    XCTAssertTrue(
      agentsContent.contains("dev-methodology: b77ddd8"),
      "AGENTS.md precisa registrar o commit conferido da dev-methodology"
    )

    let claudeContent = try String(
      contentsOf: repoRoot.appending(path: "CLAUDE.md"),
      encoding: .utf8
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertEqual(claudeContent, "@AGENTS.md", "CLAUDE.md deve conter apenas @AGENTS.md")

    var docFiles: [URL] = [
      repoRoot.appending(path: "AGENTS.md"),
      repoRoot.appending(path: "README.md"),
    ]
    let adrDir = repoRoot.appending(path: "docs/adr", directoryHint: .isDirectory)
    let adrFiles =
      (try? FileManager.default.contentsOfDirectory(at: adrDir, includingPropertiesForKeys: nil))
      ?? []
    let markdownADRs = adrFiles.filter { $0.pathExtension == "md" }.sorted { $0.path < $1.path }
    XCTAssertGreaterThanOrEqual(markdownADRs.count, 2, "Os ADRs iniciais 0001 e 0002 devem existir")
    docFiles.append(contentsOf: markdownADRs)

    var documents: [(name: String, content: String)] = []
    for fileURL in docFiles {
      let text = try String(contentsOf: fileURL, encoding: .utf8)
      documents.append((fileURL.lastPathComponent, text))
    }

    let errors = Self.validateDocuments(
      documents: documents,
      repoRoot: repoRoot,
      declaredMakeTargets: declaredTargets
    )
    XCTAssertTrue(
      errors.isEmpty,
      "Integridade documental falhou:\n" + errors.joined(separator: "\n")
    )
  }

  func testDocumentationEvaluatorDetectsBrokenPathAndTarget() {
    let repoRoot = Self.repositoryRoot()
    let errors = Self.validateDocuments(
      documents: [
        (
          name: "falso.md",
          content: "Veja `BrainPanel/ArquivoInexistente.swift` e rode `make alvo-fantasma`."
        )
      ],
      repoRoot: repoRoot,
      declaredMakeTargets: ["test", "check", "ci"]
    )
    XCTAssertEqual(errors.count, 2)
  }

  static func extractMakefileTargets(from content: String) -> Set<String> {
    let pattern = #/(?m)^([a-zA-Z0-9][a-zA-Z0-9_-]*)\s*:/#
    var targets: Set<String> = []
    for match in content.matches(of: pattern) {
      targets.insert(String(match.output.1))
    }
    return targets
  }

  static func validateDocuments(
    documents: [(name: String, content: String)],
    repoRoot: URL,
    declaredMakeTargets: Set<String>
  ) -> [String] {
    var errors: [String] = []
    let inlineCodePattern = #/`([^`\n]+)`/#
    let makeCommandPattern = #/^make\s+([a-zA-Z0-9_-]+)(?:\s|$)/#

    let repoPrefixes = [
      "BrainPanel/",
      "BrainPanel.xcodeproj",
      "BrainPanelTests/",
      "scripts/",
      "docs/",
      ".github/",
      ".vscode/",
    ]
    let exactRepoFiles: Set<String> = [
      "Makefile",
      "AGENTS.md",
      "CLAUDE.md",
      "README.md",
      "LICENSE",
      ".gitignore",
      ".dockerignore",
      ".env.example",
      ".swift-format",
    ]

    for doc in documents {
      for match in doc.content.matches(of: inlineCodePattern) {
        let snippet = String(match.output.1).trimmingCharacters(in: .whitespaces)

        if let makeMatch = snippet.firstMatch(of: makeCommandPattern) {
          let target = String(makeMatch.output.1)
          if !declaredMakeTargets.contains(target) {
            errors.append("\(doc.name): alvo 'make \(target)' não existe no Makefile")
          }
          continue
        }

        let isRepoPath =
          exactRepoFiles.contains(snippet)
          || repoPrefixes.contains(where: { snippet.hasPrefix($0) })
        guard isRepoPath else { continue }
        guard !snippet.contains("<"), !snippet.contains("{"), !snippet.contains("*") else {
          continue
        }

        let cleanRelative = snippet.hasSuffix("/") ? String(snippet.dropLast()) : snippet
        let candidate = repoRoot.appending(path: cleanRelative)
        if !FileManager.default.fileExists(atPath: candidate.path) {
          errors.append("\(doc.name): caminho citado '\(snippet)' não existe no repositório")
        }
      }
    }

    return errors
  }

  private static func repositoryRoot() -> URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
