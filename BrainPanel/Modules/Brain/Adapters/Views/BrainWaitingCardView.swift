import SwiftUI

struct BrainWaitingCardView: View {
  let state: BrainSectionState<WaitingState>
  let now: Date

  private var badgeInfo: (text: String, tone: BrainCardTone) {
    switch state {
    case .failed:
      return ("Falha", .critical)
    case .loaded(let waiting):
      let count = waiting.waitingOnOwnerCount
      if count > 0 {
        return ("\(count) pendente\(count == 1 ? "" : "s")", .warning)
      }
      return ("Em dia", .healthy)
    }
  }

  private var cardTone: BrainCardTone {
    switch state {
    case .failed:
      .critical
    case .loaded(let waiting):
      waiting.waitingOnOwnerCount > 0 ? .warning : .neutral
    }
  }

  var body: some View {
    BrainSectionCard(
      title: "Esperando Você & Correio",
      iconName: "person.wave.2.fill",
      iconTone: cardTone == .neutral ? .active : cardTone,
      badgeText: badgeInfo.text,
      badgeTone: badgeInfo.tone,
      cardTone: cardTone
    ) {
      switch state {
      case .failed(let appError):
        BrainSectionErrorView(message: appError.userMessage)
      case .loaded(let waiting):
        if waiting.pendingPrompts.isEmpty, waiting.stuckMail.isEmpty, waiting.closedMail.isEmpty {
          Text("Nenhuma pergunta pendente nem caixa de correio parada.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          VStack(alignment: .leading, spacing: 6.5) {
            ForEach(waiting.pendingPrompts) { prompt in
              BrainPendingPromptRowView(prompt: prompt, now: now)
            }

            ForEach(waiting.stuckMail) { mailbox in
              BrainStuckMailboxRowView(mailbox: mailbox, now: now)
            }

            if !waiting.closedMail.isEmpty {
              BrainClosedMailSummaryRow(closedMail: waiting.closedMail)
            }
          }
        }
      }
    }
  }
}

private struct BrainPendingPromptRowView: View {
  let prompt: PendingPrompt
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 3.5) {
      HStack(alignment: .center, spacing: 5) {
        Text(prompt.sessionKey)
          .font(.caption.weight(.semibold))
          .lineLimit(1)

        if prompt.hasButton {
          HStack(spacing: 2.5) {
            Image(systemName: "hand.tap.fill")
              .font(.system(size: 8, weight: .bold))
            Text("Botão")
              .font(.system(size: 9, weight: .semibold))
          }
          .foregroundStyle(.orange)
          .padding(.horizontal, 4.5)
          .padding(.vertical, 1)
          .background(Color.orange.opacity(0.16), in: Capsule())
        } else if !prompt.isExplicit {
          Text("Inferida")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4.5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.08), in: Capsule())
        }

        Spacer(minLength: 4)

        Text(prompt.elapsedSummary(now: now))
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      if let text = prompt.text {
        Text(text)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .help(text)
      }
    }
    .padding(7.5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.orange.opacity(0.22), lineWidth: 0.5)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct BrainStuckMailboxRowView: View {
  let mailbox: StuckMailbox
  let now: Date

  private var sendersLine: String? {
    guard !mailbox.senders.isEmpty else { return nil }
    return "De: " + mailbox.senders.joined(separator: ", ")
  }

  private var countText: String {
    mailbox.unreadCount == 1 ? "1 mensagem parada" : "\(mailbox.unreadCount) mensagens paradas"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline, spacing: 5) {
        Image(systemName: "tray.full.fill")
          .font(.system(size: 9.5, weight: .semibold))
          .foregroundStyle(.orange)

        Text(mailbox.recipient)
          .font(.caption.weight(.semibold))
          .lineLimit(1)

        Text("· \(countText)")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)

        Spacer(minLength: 4)

        Text(mailbox.elapsedSummary(now: now))
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      if let sendersLine {
        Text(sendersLine)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .help(sendersLine)
      }
    }
    .padding(7.5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.orange.opacity(0.18), lineWidth: 0.5)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct BrainClosedMailSummaryRow: View {
  let closedMail: [ClosedMailbox]

  private var summaryLine: String {
    let entries = closedMail.map { "\($0.recipient) (\($0.unreadCount))" }
    return "Sessão fechada com correio guardado: " + entries.joined(separator: ", ")
  }

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: "tray.fill")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.tertiary)

      Text(summaryLine)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help(summaryLine)
    }
    .padding(.top, 1)
    .accessibilityElement(children: .combine)
  }
}
