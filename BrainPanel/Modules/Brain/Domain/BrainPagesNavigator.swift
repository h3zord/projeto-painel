import Foundation

nonisolated enum BrainPagesSectionTarget: Equatable, Sendable {
  case ciQueue
  case backupDrive
  case health
  case scheduledJobs
}

/// Resolução pura e determinística de destinos do servidor local `brain-pages`.
/// Toda URL retornada deriva exclusivamente da origem loopback de `baseURL`,
/// bloqueia dados corporativos (`flexograv`) e nunca presume `/<escopo>` ou `checklist-1`.
nonisolated enum BrainPagesNavigator {
  private static let maxURLStringLength = 1_024
  private static let maxSlugLength = 81
  private static let maxFragmentLength = 64
  private static let archivedSegmentLiteral = "_arquivo"

  private struct LoopbackOrigin {
    let host: String
    let port: Int?

    func makeURL(path: String, fragment: String?) -> URL? {
      var components = URLComponents()
      components.scheme = "http"
      components.host = host
      components.port = port
      components.path = path
      components.fragment = fragment
      return components.url
    }
  }

  static func resolveDestination(for prompt: PendingPrompt, baseURL: URL) -> URL? {
    guard let origin = extractLoopbackOrigin(from: baseURL) else {
      return nil
    }

    if BrainPrivacyGuard.isCorporateScope(prompt.sessionKey, prompt.project) {
      return origin.makeURL(path: "/", fragment: "esperando")
    }

    if let text = prompt.text,
      !BrainPrivacyGuard.isCorporateScope(text),
      let explicitTarget = extractExplicitPageTarget(from: text)
    {
      return origin.makeURL(path: explicitTarget.path, fragment: explicitTarget.fragment)
    }

    if let project = prompt.project, isValidSlugSegment(project) {
      return origin.makeURL(path: "/", fragment: "projetos")
    }

    return origin.makeURL(path: "/", fragment: "esperando")
  }

  static func resolveDestination(for _: StuckMailbox, baseURL: URL) -> URL? {
    guard let origin = extractLoopbackOrigin(from: baseURL) else {
      return nil
    }
    return origin.makeURL(path: "/", fragment: "esperando")
  }

  static func resolveSection(_ target: BrainPagesSectionTarget, baseURL: URL) -> URL? {
    guard let origin = extractLoopbackOrigin(from: baseURL) else {
      return nil
    }
    switch target {
    case .ciQueue:
      return origin.makeURL(path: "/fila", fragment: nil)
    case .backupDrive:
      return origin.makeURL(path: "/brain/backup-drive", fragment: nil)
    case .health:
      return origin.makeURL(path: "/", fragment: "saude")
    case .scheduledJobs:
      return origin.makeURL(path: "/", fragment: "agendados")
    }
  }

  // MARK: - Validação pura de origem, slugs e links explícitos

  private static func extractLoopbackOrigin(from url: URL) -> LoopbackOrigin? {
    let raw = url.absoluteString
    guard
      let components = parseSafeLoopbackComponents(raw),
      isSafeBasePath(components.path)
    else {
      return nil
    }
    let hashCount = raw.filter { $0 == "#" }.count
    guard hashCount <= 1 else {
      return nil
    }
    if hashCount == 1 {
      guard let fragment = components.fragment, isValidFragment(fragment) else {
        return nil
      }
    }
    guard let host = components.host?.lowercased() else {
      return nil
    }
    return LoopbackOrigin(host: host, port: components.port)
  }

  private static func extractExplicitPageTarget(
    from text: String
  ) -> (path: String, fragment: String?)? {
    let tokens = text.split { $0.isWhitespace || $0.isNewline }
    for token in tokens {
      guard let schemeRange = token.range(of: "http://", options: [.caseInsensitive]) else {
        continue
      }
      let rawSlice = String(token[schemeRange.lowerBound...])
      let candidate = trimTrailingSentencePunctuation(rawSlice)
      if let parsed = parseExplicitPageCandidate(candidate) {
        return parsed
      }
    }
    return nil
  }

  private static func trimTrailingSentencePunctuation(_ raw: String) -> String {
    var chars = Array(raw)
    let unconditionalClosers: Set<Character> = [")", "]", "}", ">", "\"", "'", ",", ";", "!"]

    while let last = chars.last {
      if unconditionalClosers.contains(last) {
        chars.removeLast()
        continue
      }
      if last == "." || last == ":" {
        guard chars.count >= 2 else { break }
        let previous = chars[chars.count - 2]
        if previous != "." && previous != ":" && previous != "/" {
          chars.removeLast()
          continue
        }
      }
      break
    }
    return String(chars)
  }

  private static func parseExplicitPageCandidate(
    _ raw: String
  ) -> (path: String, fragment: String?)? {
    guard
      !BrainPrivacyGuard.isCorporateScope(raw),
      let components = parseSafeLoopbackComponents(raw)
    else {
      return nil
    }

    let hashCount = raw.filter { $0 == "#" }.count
    guard hashCount <= 1 else {
      return nil
    }

    let validatedFragment: String?
    if hashCount == 1 {
      guard let fragment = components.fragment, isValidFragment(fragment) else {
        return nil
      }
      validatedFragment = fragment
    } else {
      validatedFragment = nil
    }

    let path = components.path
    guard path.hasPrefix("/"), !path.hasSuffix("/") else {
      return nil
    }

    let segments = path.dropFirst()
      .split(separator: "/", omittingEmptySubsequences: false)
      .map(String.init)

    switch segments.count {
    case 2:
      guard isValidSlugSegment(segments[0]), isValidSlugSegment(segments[1]) else {
        return nil
      }
    case 3:
      guard
        segments[1] == archivedSegmentLiteral,
        isValidSlugSegment(segments[0]),
        isValidSlugSegment(segments[2])
      else {
        return nil
      }
    default:
      return nil
    }

    return (path: "/" + segments.joined(separator: "/"), fragment: validatedFragment)
  }

  private static func parseSafeLoopbackComponents(_ raw: String) -> URLComponents? {
    guard
      !raw.isEmpty,
      raw.count <= maxURLStringLength,
      !raw.contains("\0"),
      !raw.contains("%"),
      !raw.contains("?"),
      !raw.contains("\\"),
      raw.allSatisfy({ !$0.isWhitespace && !$0.isNewline }),
      let components = URLComponents(string: raw),
      components.scheme?.lowercased() == "http",
      components.user == nil,
      components.password == nil,
      components.query == nil,
      let host = components.host?.lowercased(),
      host == "127.0.0.1" || host == "localhost"
    else {
      return nil
    }

    let withoutScheme = String(raw.dropFirst("http://".count))
    let authority = String(withoutScheme.prefix { $0 != "/" && $0 != "#" })
    guard !authority.contains("@") else {
      return nil
    }
    if authority.contains(":") {
      guard let port = components.port, (1...65_535).contains(port) else {
        return nil
      }
    } else if let port = components.port, !(1...65_535).contains(port) {
      return nil
    }
    return components
  }

  private static func isSafeBasePath(_ path: String) -> Bool {
    if path.isEmpty || path == "/" {
      return true
    }
    guard path.hasPrefix("/") else {
      return false
    }
    let body = path.hasSuffix("/") ? path.dropFirst().dropLast() : path.dropFirst()
    guard !body.isEmpty else {
      return false
    }
    let segments = body.split(separator: "/", omittingEmptySubsequences: false)
    return !segments.contains { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("..") }
  }

  static func isValidSlugSegment(_ segment: String) -> Bool {
    guard
      !segment.isEmpty,
      segment.unicodeScalars.count <= maxSlugLength,
      !segment.contains(".."),
      !BrainPrivacyGuard.isCorporateScope(segment),
      let first = segment.unicodeScalars.first,
      isLowerAlphaNumeric(first)
    else {
      return false
    }
    return segment.unicodeScalars.allSatisfy { scalar in
      isLowerAlphaNumeric(scalar) || scalar == "." || scalar == "-"
    }
  }

  private static func isValidFragment(_ fragment: String) -> Bool {
    guard
      !fragment.isEmpty,
      fragment.unicodeScalars.count <= maxFragmentLength,
      !BrainPrivacyGuard.isCorporateScope(fragment)
    else {
      return false
    }
    return fragment.unicodeScalars.allSatisfy { scalar in
      isLowerAlphaNumeric(scalar)
        || (scalar.value >= 0x41 && scalar.value <= 0x5A)
        || scalar == "_"
        || scalar == "-"
    }
  }

  private static func isLowerAlphaNumeric(_ scalar: UnicodeScalar) -> Bool {
    (scalar.value >= 0x61 && scalar.value <= 0x7A)
      || (scalar.value >= 0x30 && scalar.value <= 0x39)
  }
}
