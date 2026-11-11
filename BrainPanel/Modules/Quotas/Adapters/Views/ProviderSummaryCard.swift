import SwiftUI

struct ProviderSummaryCard: View {
  let provider: ProviderUsage
  let isSelected: Bool
  let action: () -> Void

  private var color: Color {
    switch provider.tint {
    case .orange:
      .orange
    case .blue:
      .blue
    }
  }

  private var isStale: Bool {
    provider.sessionState.isStale
  }

  private var isUnavailable: Bool {
    provider.sessionState.isUnavailable
  }

  private var isLoading: Bool {
    provider.sessionState.isLoading
  }

  private var strokeColor: Color {
    if isUnavailable {
      return .red.opacity(isSelected ? 0.68 : 0.42)
    }
    if isStale {
      return .orange.opacity(isSelected ? 0.68 : 0.42)
    }
    return color.opacity(isSelected ? 0.55 : 0.16)
  }

  private var hasElevatedBorder: Bool {
    isSelected || isStale || isUnavailable
  }

  private var accessibilityValueSummary: String {
    switch provider.sessionState {
    case .loading:
      return "carregando leitura inicial"
    case .unavailable(let reason):
      return "indisponível, \(reason)"
    case .stale:
      return "leitura defasada, \(limitsVoiceOverSummary)"
    case .active:
      return limitsVoiceOverSummary
    }
  }

  private var limitsVoiceOverSummary: String {
    let sessionText = provider.sessionLimit.map { "\($0.remainingPercentage)%" } ?? "indisponível"
    let weeklyText = provider.weeklyLimit.map { "\($0.remainingPercentage)%" } ?? "indisponível"
    return "sessão \(sessionText), semanal \(weeklyText)"
  }

  @ViewBuilder
  private var iconView: some View {
    switch provider.icon {
    case .symbol(let name):
      Image(systemName: name)
        .font(.caption.weight(.semibold))
    case .asset(let name):
      Image(name)
        .resizable()
        .scaledToFit()
        .frame(width: 12.5, height: 12.5)
    }
  }

  @ViewBuilder
  private var statusIndicator: some View {
    if isUnavailable {
      Image(systemName: "xmark.octagon.fill")
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(.red)
        .help(provider.unavailableReason ?? provider.sessionState.label)
    } else if isStale {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(.orange)
        .help(provider.staleReason ?? provider.sessionState.label)
    } else if isLoading {
      Image(systemName: "clock")
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(.secondary)
        .help("Aguardando primeira leitura")
    }
  }

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 8.5) {
        HStack(spacing: 6) {
          iconView
            .foregroundStyle(color)
            .frame(width: 21, height: 21)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))

          Text(provider.name)
            .font(.caption.weight(.semibold))
            .lineLimit(1)

          Spacer(minLength: 0)

          statusIndicator

          Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isSelected ? 180 : 0))
        }

        switch provider.sessionState {
        case .loading:
          SummaryStateNotice(
            headline: "Carregando…",
            headlineColor: .secondary,
            detail: "Aguardando leitura inicial"
          )
        case .unavailable(let reason):
          SummaryStateNotice(
            headline: "Indisponível",
            headlineColor: .red,
            detail: reason
          )
          .help(reason)
        case .active, .stale:
          AlwaysVisibleLimits(
            session: provider.sessionLimit,
            weekly: provider.weeklyLimit,
            color: color
          )
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(9)
      .background(color.opacity(isSelected ? 0.15 : 0.09), in: RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .stroke(strokeColor, lineWidth: hasElevatedBorder ? 1 : 0.5)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(isSelected ? "Ocultar" : "Mostrar") detalhes de \(provider.name)")
    .accessibilityValue(accessibilityValueSummary)
  }
}

private struct SummaryStateNotice: View {
  let headline: String
  let headlineColor: Color
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 3) {
        Text("Estado")
          .font(.caption2)
          .foregroundStyle(.secondary)

        Spacer(minLength: 2)

        Text(headline)
          .font(.caption.weight(.semibold))
          .foregroundStyle(headlineColor)
          .lineLimit(1)
      }

      Text(detail)
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct AlwaysVisibleLimits: View {
  let session: UsageLimit?
  let weekly: UsageLimit?
  let color: Color

  var body: some View {
    VStack(spacing: 5) {
      PercentageLine(
        title: "Sessão",
        remainingPercentage: session?.remainingPercentage,
        color: color
      )

      PercentageLine(
        title: "Semanal",
        remainingPercentage: weekly?.remainingPercentage,
        color: color
      )
    }
  }
}

private struct PercentageLine: View {
  let title: LocalizedStringKey
  let remainingPercentage: Int?
  let color: Color

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 3) {
      Text(title)
        .font(.caption2)
        .foregroundStyle(.secondary)

      Spacer(minLength: 2)

      if let remainingPercentage {
        Text(remainingPercentage, format: .percent.scale(1))
          .font(.caption.monospacedDigit().weight(.semibold))
          .foregroundStyle(statusColor(for: remainingPercentage))
      } else {
        Text("—")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
  }

  private func statusColor(for remainingPercentage: Int) -> Color {
    switch remainingPercentage {
    case ...15:
      .red
    case ...35:
      .orange
    default:
      color
    }
  }
}
