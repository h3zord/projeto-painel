import Foundation

/// Extrai dinamicamente grupos de cota da tela `/quota` do Antigravity (`agy`) sem realizar I/O.
nonisolated enum GeminiQuotaParser {
  private struct ParsedGroup: Equatable {
    let idPrefix: String
    let displayName: String
  }

  private struct Entry {
    let group: ParsedGroup
    let window: LimitWindow
    let remaining: Double
    let resetsAt: Date?
  }

  static func makeUsage(from screen: String, now: Date) throws(AppError) -> ProviderUsage {
    let parsedEntries = entries(in: screen, now: now)
    guard !parsedEntries.isEmpty else {
      throw AppError.unexpectedOutputFormat(provider: .gemini)
    }

    var orderedGroupIDs: [String] = []
    var entriesByGroupID: [String: [Entry]] = [:]

    for entry in parsedEntries {
      if entriesByGroupID[entry.group.idPrefix] == nil {
        orderedGroupIDs.append(entry.group.idPrefix)
      }
      entriesByGroupID[entry.group.idPrefix, default: []].append(entry)
    }

    var limits: [UsageLimit] = []
    for groupID in orderedGroupIDs {
      guard let rawGroupEntries = entriesByGroupID[groupID] else { continue }

      var deduplicatedByWindow: [Entry] = []
      for entry in rawGroupEntries {
        if let existingIndex = deduplicatedByWindow.firstIndex(where: { $0.window == entry.window }) {
          deduplicatedByWindow[existingIndex] = entry
        } else {
          deduplicatedByWindow.append(entry)
        }
      }

      let sortedEntries = deduplicatedByWindow.sorted { lhs, rhs in
        lhs.window == .session && rhs.window == .weekly
      }

      for entry in sortedEntries {
        let kind = entry.window == .session ? "session" : "weekly"
        let detail = entry.window == .session ? "Sessão de 5 horas" : "Semanal"
        limits.append(
          UsageLimit(
            id: "\(entry.group.idPrefix)-\(kind)",
            name: entry.group.displayName,
            detail: detail,
            window: entry.window,
            usedPercentage: Int((100 - entry.remaining).rounded()),
            resetsAt: entry.resetsAt
          )
        )
      }
    }

    let plan =
      if screen.contains("Google AI Ultra") {
        "Google AI Ultra"
      } else if screen.contains("Google AI Pro") {
        "Google AI Pro"
      } else {
        "Google"
      }

    return ProviderUsage(
      id: KnownProviderID.gemini.rawValue,
      name: "Gemini",
      plan: plan,
      icon: .symbol("sparkle"),
      tint: .blue,
      sessionState: .active,
      limits: limits,
      lastUpdatedAt: now
    )
  }

  private static let lineDecorationCharacters: CharacterSet = {
    var characters = CharacterSet.whitespaces
    if let boxStart = Unicode.Scalar(0x2500), let boxEnd = Unicode.Scalar(0x257F) {
      characters.insert(charactersIn: boxStart...boxEnd)
    }
    return characters
  }()

  private static func entries(in screen: String, now: Date) -> [Entry] {
    guard let start = screen.range(of: "Models & Quota", options: .backwards) else {
      return []
    }

    let lines = screen[start.upperBound...]
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: lineDecorationCharacters) }
      .filter { !$0.isEmpty }

    var collected: [Entry] = []
    var currentGroup: ParsedGroup?
    var label: String?
    var remaining: Double?
    var resetsAt: Date?

    func flush() {
      if let currentGroup,
        let label,
        let remaining
      {
        let window: LimitWindow = isFiveHour(label) ? .session : .weekly
        collected.append(
          Entry(group: currentGroup, window: window, remaining: remaining, resetsAt: resetsAt)
        )
      }
      label = nil
      remaining = nil
      resetsAt = nil
    }

    for line in lines {
      if line.localizedCaseInsensitiveContains("within each group") {
        break
      }
      if isGroupHeader(line), let parsedGroup = makeParsedGroup(from: line) {
        flush()
        currentGroup = parsedGroup
      } else if line.contains("Limit") {
        flush()
        label = line
        if let value = percentage(in: line) {
          remaining = value
          resetsAt = resetDate(in: line, now: now)
        } else if line.localizedCaseInsensitiveContains("quota available") {
          remaining = 100
          resetsAt = nil
        }
      } else if label != nil, remaining == nil, let value = percentage(in: line) {
        remaining = value
        resetsAt = resetDate(in: line, now: now)
      } else if label != nil, remaining == nil,
        line.localizedCaseInsensitiveContains("quota available")
      {
        remaining = 100
        resetsAt = nil
      } else if remaining != nil, resetsAt == nil {
        resetsAt = resetDate(in: line, now: now)
      }
    }
    flush()

    return collected
  }

  private static func isFiveHour(_ label: String) -> Bool {
    label.localizedCaseInsensitiveContains("five hour")
      || label.localizedCaseInsensitiveContains("5-hour")
  }

  private static func isGroupHeader(_ line: String) -> Bool {
    guard line.count >= 3, !line.contains("%") else { return false }

    let lower = line.lowercased()
    if lower.contains("limit")
      || lower.contains("refreshes in")
      || lower.contains("resets in")
      || lower.contains("within each group")
      || lower.contains("models & quota")
    {
      return false
    }

    let letters = line.filter(\.isLetter)
    guard letters.count >= 3, letters.allSatisfy(\.isUppercase) else {
      return false
    }

    let allowedPunctuation: Set<Character> = [" ", ".", "-", "/", "&", "+", "_", "(", ")", ":"]
    return line.allSatisfy {
      $0.isLetter || $0.isNumber || allowedPunctuation.contains($0)
    }
  }

  private static func makeParsedGroup(from header: String) -> ParsedGroup? {
    let tokenPattern = #/[a-z0-9]+/#
    let slugTokens = header.lowercased().matches(of: tokenPattern).map { String($0.output) }
    guard !slugTokens.isEmpty else { return nil }

    let idPrefix: String
    if slugTokens.first == "gemini", slugTokens.count > 1 {
      idPrefix = slugTokens.joined(separator: "-")
    } else {
      idPrefix = (["gemini"] + slugTokens).joined(separator: "-")
    }

    return ParsedGroup(idPrefix: idPrefix, displayName: formatDisplayName(from: header))
  }

  private static func formatDisplayName(from header: String) -> String {
    var words =
      header
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)

    if words.count > 2, words.last == "MODELS" {
      words.removeLast()
    }

    return words.map(formatWordToken).joined(separator: " ")
  }

  private static func formatWordToken(_ token: String) -> String {
    if token == "AND" {
      return "e"
    }
    if token == "&" || token == "/" || token == "-" {
      return token
    }

    if token.contains("-") {
      return token.split(separator: "-", omittingEmptySubsequences: false)
        .map { formatAtomicWord(String($0)) }
        .joined(separator: "-")
    }
    if token.contains("/") {
      return token.split(separator: "/", omittingEmptySubsequences: false)
        .map { formatAtomicWord(String($0)) }
        .joined(separator: "/")
    }

    return formatAtomicWord(token)
  }

  private static func formatAtomicWord(_ word: String) -> String {
    let leading = word.prefix { !$0.isLetter && !$0.isNumber }
    let remainder = word.dropFirst(leading.count)
    let trailingReversed = remainder.reversed().prefix { !$0.isLetter && !$0.isNumber }
    let core = String(remainder.dropLast(trailingReversed.count))
    let trailing = String(trailingReversed.reversed())

    guard !core.isEmpty else {
      return word
    }

    let preservedAcronyms: Set<String> = ["GPT", "AI", "API", "CLI", "LLM", "UI"]
    if preservedAcronyms.contains(core) {
      return "\(leading)\(core)\(trailing)"
    }
    guard core.contains(where: \.isLetter), core.first?.isNumber != true else {
      return "\(leading)\(core)\(trailing)"
    }

    let lower = core.lowercased()
    guard let first = lower.first else { return word }
    return "\(leading)\(String(first).uppercased())\(lower.dropFirst())\(trailing)"
  }

  private static func percentage(in line: String) -> Double? {
    let percentPattern = #/(\d{1,3}(?:\.\d+)?)\s*%/#
    guard let match = line.firstMatch(of: percentPattern) else { return nil }
    return Double(match.output.1)
  }

  private static func resetDate(in line: String, now: Date) -> Date? {
    let durationPattern = #/(\d+)\s*(d|h|m|s)/#
    guard
      let marker = line.range(of: "refreshes in", options: .caseInsensitive)
        ?? line.range(of: "resets in", options: .caseInsensitive)
    else {
      return nil
    }

    let text = String(line[marker.upperBound...])
    let units: [String: TimeInterval] = ["d": 86_400, "h": 3_600, "m": 60, "s": 1]
    var seconds: TimeInterval = 0

    for match in text.matches(of: durationPattern) {
      guard
        let value = Double(match.output.1),
        let unit = units[String(match.output.2)]
      else {
        continue
      }
      seconds += value * unit
    }

    return seconds > 0 ? now.addingTimeInterval(seconds) : nil
  }
}
