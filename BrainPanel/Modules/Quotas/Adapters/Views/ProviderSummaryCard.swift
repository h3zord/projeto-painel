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

  private var strokeColor: Color {
    if isStale {
      return .orange.opacity(isSelected ? 0.68 : 0.42)
    }
    return color.opacity(isSelected ? 0.55 : 0.16)
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

          if isStale {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: 9.5, weight: .semibold))
              .foregroundStyle(.orange)
              .help(provider.staleReason ?? provider.sessionState.label)
          }

          Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isSelected ? 180 : 0))
        }

        AlwaysVisibleLimits(
          session: provider.sessionLimit,
          weekly: provider.weeklyLimit,
          color: color
        )
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(9)
      .background(color.opacity(isSelected ? 0.15 : 0.09), in: RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .stroke(strokeColor, lineWidth: isSelected || isStale ? 1 : 0.5)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      "\(isSelected ? "Ocultar" : "Mostrar") detalhes de \(provider.name)\(isStale ? ", leitura defasada" : "")"
    )
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
