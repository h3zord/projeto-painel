import Foundation

nonisolated enum BrainWaitingEvaluator {
  static let answeredTranscriptGraceSeconds: TimeInterval = 30
  static let maxPendingAgeSeconds: TimeInterval = 7 * 86_400
  static let stuckMailThresholdSeconds: TimeInterval = 1_800
  static let excludedOpenRecipient = "my-assistant"

  struct PendingCandidate: Equatable, Sendable {
    let jsonData: Data
    let transcriptModifiedAt: Date?
  }

  struct MailboxCandidate: Equatable, Sendable {
    let recipient: String
    let messagePayloads: [Data]
  }

  nonisolated private struct OpenSessionRecord: Decodable {
    let pid: Int32
    let name: String?

    enum CodingKeys: String, CodingKey {
      case pid
      case name
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      if let numericPID = try? container.decode(Int32.self, forKey: .pid) {
        self.pid = numericPID
      } else {
        let stringPID = try container.decode(String.self, forKey: .pid)
        guard let parsed = Int32(stringPID) else {
          throw DecodingError.dataCorruptedError(
            forKey: .pid,
            in: container,
            debugDescription: "PID inválido"
          )
        }
        self.pid = parsed
      }
      self.name = try container.decodeIfPresent(String.self, forKey: .name)
    }
  }

  nonisolated private struct PendingRecord: Decodable {
    let name: String?
    let project: String?
    let tool: String?
    let transcript: String?
    let at: Double?
    let text: String?
    let explicit: Bool?
    let button: Bool?
  }

  /// Envelope estrito do `brain-mail`: `CodingKeys` omite deliberadamente `text` (dado de colega).
  nonisolated private struct MailEnvelopeRecord: Decodable {
    let sender: String?
    let at: Double?

    enum CodingKeys: String, CodingKey {
      case sender = "from"
      case at
    }
  }

  static func parseOpenSessionName(
    from jsonData: Data,
    filename: String,
    isProcessAlive: (Int32) -> Bool
  ) -> String? {
    guard
      filename != "antigravity-names.json",
      let record = try? JSONDecoder().decode(OpenSessionRecord.self, from: jsonData),
      isProcessAlive(record.pid),
      let cleanName = BrainPrivacyGuard.sanitizeSingleLine(record.name, maxLength: 120)
    else {
      return nil
    }
    return cleanName
  }

  static func evaluate(
    pendingCandidates: [PendingCandidate],
    mailboxes: [MailboxCandidate],
    openSessionNames: Set<String>,
    now: Date
  ) -> WaitingState {
    let decoder = JSONDecoder()
    let nowEpoch = now.timeIntervalSince1970

    var latestPromptsBySession: [String: (epoch: TimeInterval, prompt: PendingPrompt)] = [:]

    for candidate in pendingCandidates {
      guard
        let record = try? decoder.decode(PendingRecord.self, from: candidate.jsonData),
        let askedEpoch = record.at,
        askedEpoch > 0
      else {
        continue
      }

      if let mtime = candidate.transcriptModifiedAt?.timeIntervalSince1970,
        mtime > askedEpoch + answeredTranscriptGraceSeconds
      {
        continue
      }

      if nowEpoch - askedEpoch > maxPendingAgeSeconds {
        continue
      }

      let sessionKey =
        BrainPrivacyGuard.sanitizeSingleLine(record.name, maxLength: 120)
        ?? BrainPrivacyGuard.sanitizeSingleLine(record.project, maxLength: 120)
        ?? BrainPrivacyGuard.sanitizeSingleLine(record.tool, maxLength: 120)
        ?? "?"

      let isCorporate = BrainPrivacyGuard.isCorporateScope(
        record.project,
        record.transcript,
        record.name,
        sessionKey
      )
      let safeText =
        isCorporate ? nil : BrainPrivacyGuard.sanitizeSingleLine(record.text, maxLength: 400)

      let prompt = PendingPrompt(
        sessionKey: sessionKey,
        askedAt: Date(timeIntervalSince1970: askedEpoch),
        text: safeText,
        isExplicit: record.explicit ?? false,
        hasButton: record.button ?? false
      )

      if let existing = latestPromptsBySession[sessionKey] {
        if askedEpoch >= existing.epoch {
          latestPromptsBySession[sessionKey] = (askedEpoch, prompt)
        }
      } else {
        latestPromptsBySession[sessionKey] = (askedEpoch, prompt)
      }
    }

    let sortedPrompts =
      latestPromptsBySession.values
      .sorted { lhs, rhs in
        if lhs.epoch != rhs.epoch {
          return lhs.epoch < rhs.epoch
        }
        return lhs.prompt.sessionKey < rhs.prompt.sessionKey
      }
      .map(\.prompt)

    var stuckMail: [StuckMailbox] = []
    var closedMail: [ClosedMailbox] = []

    for mailbox in mailboxes {
      guard
        let recipient = BrainPrivacyGuard.sanitizeSingleLine(mailbox.recipient, maxLength: 120),
        !mailbox.messagePayloads.isEmpty
      else {
        continue
      }

      var validCount = 0
      var oldestEpoch: TimeInterval?
      var senderSet: Set<String> = []

      for payload in mailbox.messagePayloads {
        guard let envelope = try? decoder.decode(MailEnvelopeRecord.self, from: payload) else {
          continue
        }
        validCount += 1
        let msgEpoch = envelope.at ?? nowEpoch
        if let currentOldest = oldestEpoch {
          oldestEpoch = min(currentOldest, msgEpoch)
        } else {
          oldestEpoch = msgEpoch
        }
        if let cleanSender = BrainPrivacyGuard.sanitizeSingleLine(envelope.sender, maxLength: 80) {
          senderSet.insert(cleanSender)
        }
      }

      guard validCount > 0, let resolvedOldest = oldestEpoch else {
        continue
      }

      if openSessionNames.contains(recipient) {
        if recipient != excludedOpenRecipient,
          nowEpoch - resolvedOldest > stuckMailThresholdSeconds
        {
          stuckMail.append(
            StuckMailbox(
              recipient: recipient,
              unreadCount: validCount,
              oldestMessageAt: Date(timeIntervalSince1970: resolvedOldest),
              senders: senderSet.sorted()
            )
          )
        }
      } else {
        closedMail.append(
          ClosedMailbox(
            recipient: recipient,
            unreadCount: validCount
          )
        )
      }
    }

    stuckMail.sort { lhs, rhs in
      if lhs.oldestMessageAt != rhs.oldestMessageAt {
        return lhs.oldestMessageAt < rhs.oldestMessageAt
      }
      return lhs.recipient < rhs.recipient
    }
    closedMail.sort { $0.recipient < $1.recipient }

    return WaitingState(
      pendingPrompts: sortedPrompts,
      stuckMail: stuckMail,
      closedMail: closedMail
    )
  }
}
