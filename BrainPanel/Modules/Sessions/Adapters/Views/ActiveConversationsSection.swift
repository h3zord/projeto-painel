import SwiftUI

struct SessionsTabView: View {
  let conversations: [ActiveConversation]
  let referenceDate: Date
  var errorMessage: String? = nil

  var body: some View {
    VStack(spacing: 8.5) {
      ActiveConversationsSection(
        conversations: conversations,
        referenceDate: referenceDate,
        errorMessage: errorMessage
      )
    }
  }
}

struct ActiveConversationsSection: View {
  let conversations: [ActiveConversation]
  let referenceDate: Date
  var errorMessage: String? = nil

  private var countLabel: String {
    switch conversations.count {
    case 0:
      errorMessage == nil ? "Nenhuma aberta" : "Leitura falhou"
    case 1:
      "1 aberta"
    default:
      "\(conversations.count) abertas"
    }
  }

  private var borderColor: Color {
    if errorMessage != nil {
      return conversations.isEmpty ? Color.red.opacity(0.32) : Color.orange.opacity(0.32)
    }
    return Color.primary.opacity(0.1)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Conversas Ativas")
          .font(.caption.weight(.semibold))

        Spacer()

        if errorMessage != nil {
          Label(
            countLabel,
            systemImage: conversations.isEmpty
              ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
          )
          .font(.caption2.weight(.medium))
          .foregroundStyle(conversations.isEmpty ? .red : .orange)
        } else {
          Label(countLabel, systemImage: "circle.fill")
            .font(.caption2)
            .foregroundStyle(conversations.isEmpty ? .tertiary : .secondary)
            .symbolRenderingMode(.monochrome)
        }
      }

      if let errorMessage {
        SessionsDiagnosticBanner(
          message: errorMessage,
          hasPreservedConversations: !conversations.isEmpty
        )
      }

      if !conversations.isEmpty {
        VStack(spacing: 8) {
          ForEach(conversations) { conversation in
            ActiveConversationRow(
              conversation: conversation,
              referenceDate: referenceDate
            )
          }
        }
      } else if errorMessage == nil {
        Text("Nenhuma sessão ativa de Claude ou Antigravity no momento.")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 2)
      }
    }
    .padding(10)
    .background(.background.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(borderColor, lineWidth: 0.5)
    }
  }
}

private struct SessionsDiagnosticBanner: View {
  let message: String
  let hasPreservedConversations: Bool

  private var accentColor: Color {
    hasPreservedConversations ? .orange : .red
  }

  var body: some View {
    HStack(alignment: .top, spacing: 6) {
      Image(
        systemName: hasPreservedConversations
          ? "exclamationmark.triangle.fill" : "xmark.octagon.fill"
      )
      .font(.caption2)
      .foregroundStyle(accentColor)
      .padding(.top, 1)

      VStack(alignment: .leading, spacing: 2) {
        Text(message)
          .font(.caption2.weight(.medium))
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)

        if hasPreservedConversations {
          Text("Exibindo a última lista válida de conversas em cache.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(8)
    .background(accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .stroke(accentColor.opacity(0.24), lineWidth: 0.5)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct ActiveConversationRow: View {
  let conversation: ActiveConversation
  let referenceDate: Date

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

        Text(conversation.headlineMetric)
          .font(.caption.monospacedDigit().weight(.semibold))
          .foregroundStyle(conversation.isCompacted ? .secondary : statusColor)
      }

      ProgressView(value: conversation.usageFraction)
        .tint(statusColor)

      HStack {
        Text(conversation.statusDetail(now: referenceDate))
          .foregroundStyle(conversation.statusLevel == .normal ? .secondary : statusColor)

        Spacer(minLength: 4)

        Text(conversation.windowSummary)
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
