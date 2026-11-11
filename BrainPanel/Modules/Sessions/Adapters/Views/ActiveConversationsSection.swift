import SwiftUI

struct SessionsTabView: View {
  let conversations: [ActiveConversation]

  var body: some View {
    VStack(spacing: 8.5) {
      ActiveConversationsSection(conversations: conversations)
    }
  }
}

struct ActiveConversationsSection: View {
  let conversations: [ActiveConversation]

  private var countLabel: String {
    switch conversations.count {
    case 0:
      "Nenhuma aberta"
    case 1:
      "1 aberta"
    default:
      "\(conversations.count) abertas"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Conversas Ativas")
          .font(.caption.weight(.semibold))

        Spacer()

        Label(countLabel, systemImage: "circle.fill")
          .font(.caption2)
          .foregroundStyle(conversations.isEmpty ? .tertiary : .secondary)
          .symbolRenderingMode(.monochrome)
      }

      if conversations.isEmpty {
        Text("Nenhuma sessão ativa do Claude Code no momento.")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 2)
      } else {
        VStack(spacing: 8) {
          ForEach(conversations) { conversation in
            ActiveConversationRow(conversation: conversation)
          }
        }
      }
    }
    .padding(10)
    .background(.background.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
    }
  }
}

private struct ActiveConversationRow: View {
  let conversation: ActiveConversation

  private var providerColor: Color {
    switch conversation.tint {
    case .orange:
      .orange
    case .blue:
      .blue
    }
  }

  private var statusColor: Color {
    switch conversation.statusLevel {
    case .hardLimit:
      .red
    case .softWarning:
      .orange
    case .normal:
      providerColor
    }
  }

  @ViewBuilder
  private var iconView: some View {
    switch conversation.icon {
    case .symbol(let name):
      Image(systemName: name)
        .font(.system(size: 10, weight: .semibold))
    case .asset(let name):
      Image(name)
        .resizable()
        .scaledToFit()
        .frame(width: 11, height: 11)
    }
  }

  var body: some View {
    VStack(spacing: 4.5) {
      HStack(alignment: .center, spacing: 6) {
        iconView
          .foregroundStyle(providerColor)
          .frame(width: 18, height: 18)
          .background(providerColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 4.5))

        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text(conversation.name)
            .font(.caption.weight(.medium))
            .lineLimit(1)

          Text("· \(conversation.providerName)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }

        Spacer(minLength: 4)

        Text("\(conversation.formattedTokens) tokens")
          .font(.caption.monospacedDigit().weight(.semibold))
          .foregroundStyle(statusColor)
      }

      ProgressView(value: conversation.fractionOfHardLimit)
        .tint(statusColor)

      HStack {
        Text(conversation.statusDetail)
          .foregroundStyle(conversation.statusLevel == .normal ? .secondary : statusColor)

        Spacer()

        Text("Teto 500 mil")
          .foregroundStyle(.tertiary)
      }
      .font(.caption2)
    }
    .padding(7.5)
    .background(providerColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(
          statusColor.opacity(conversation.statusLevel == .normal ? 0.14 : 0.4),
          lineWidth: 0.5
        )
    }
    .accessibilityElement(children: .combine)
  }
}
