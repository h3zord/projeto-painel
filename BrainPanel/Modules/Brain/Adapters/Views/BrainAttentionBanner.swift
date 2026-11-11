import SwiftUI

enum BrainCardTone {
  case neutral
  case active
  case warning
  case critical
  case healthy

  var color: Color {
    switch self {
    case .neutral:
      .secondary
    case .active:
      .blue
    case .warning:
      .orange
    case .critical:
      .red
    case .healthy:
      .green
    }
  }

  var borderColor: Color {
    switch self {
    case .neutral, .healthy:
      Color.primary.opacity(0.1)
    case .active:
      Color.blue.opacity(0.24)
    case .warning:
      Color.orange.opacity(0.32)
    case .critical:
      Color.red.opacity(0.36)
    }
  }
}

struct BrainAttentionBanner: View {
  let waitingCount: Int
  let hasCriticalFailure: Bool
  let action: () -> Void

  private var accentColor: Color {
    hasCriticalFailure ? .red : .orange
  }

  private var symbolName: String {
    hasCriticalFailure ? "exclamationmark.triangle.fill" : "bell.badge.fill"
  }

  private var summaryText: String {
    if hasCriticalFailure, waitingCount > 0 {
      let itemWord = waitingCount == 1 ? "pendência" : "pendências"
      return "Falha crítica no Brain · \(waitingCount) \(itemWord) esperando você"
    }
    if hasCriticalFailure {
      return "Falha crítica detectada no ecossistema Brain"
    }
    if waitingCount == 1 {
      return "1 item esperando sua decisão no Brain"
    }
    return "\(waitingCount) itens esperando sua decisão no Brain"
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 7) {
        Image(systemName: symbolName)
          .font(.system(size: 10.5, weight: .semibold))
          .foregroundStyle(accentColor)
          .frame(width: 20, height: 20)
          .background(accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))

        Text(summaryText)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)

        Spacer(minLength: 4)

        HStack(spacing: 2.5) {
          Text("Abrir")
            .font(.system(size: 10, weight: .semibold))
          Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .bold))
        }
        .foregroundStyle(accentColor)
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 6.5)
      .background(accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
      .overlay {
        RoundedRectangle(cornerRadius: 9)
          .stroke(accentColor.opacity(0.30), lineWidth: 0.75)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(summaryText). Ir para a aba Brain")
  }
}

struct BrainSectionBadge: View {
  let text: String
  let tone: BrainCardTone

  var body: some View {
    Text(text)
      .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
      .foregroundStyle(tone == .neutral ? Color.secondary : tone.color)
      .padding(.horizontal, 5.5)
      .padding(.vertical, 1.5)
      .background(
        (tone == .neutral ? Color.primary.opacity(0.08) : tone.color.opacity(0.14)),
        in: Capsule()
      )
  }
}

struct BrainHeaderLinkSpec: Identifiable {
  var id: String { title }
  let title: String
  let destinationURL: URL?
  let isEnabled: Bool
  let accessibilityLabel: String
  let action: (URL) -> Void
}

struct BrainInlineLinkButton: View {
  let spec: BrainHeaderLinkSpec

  private var effectiveDestination: URL? {
    guard spec.isEnabled, let destinationURL = spec.destinationURL else { return nil }
    return destinationURL
  }

  var body: some View {
    Button {
      if let effectiveDestination {
        spec.action(effectiveDestination)
      }
    } label: {
      HStack(spacing: 2.5) {
        Text(spec.title)
          .font(.system(size: 9.5, weight: .semibold))
        Image(systemName: "arrow.up.right")
          .font(.system(size: 7.5, weight: .bold))
      }
      .foregroundStyle(effectiveDestination != nil ? Color.blue : Color.secondary.opacity(0.45))
      .padding(.horizontal, 5.5)
      .padding(.vertical, 2)
      .background(
        (effectiveDestination != nil ? Color.blue.opacity(0.11) : Color.primary.opacity(0.05)),
        in: Capsule()
      )
      .overlay {
        Capsule()
          .stroke(
            effectiveDestination != nil ? Color.blue.opacity(0.22) : Color.primary.opacity(0.08),
            lineWidth: 0.5
          )
      }
    }
    .buttonStyle(.plain)
    .disabled(effectiveDestination == nil)
    .help(effectiveDestination?.absoluteString ?? "URL loopback indisponível")
    .accessibilityLabel(spec.accessibilityLabel)
    .accessibilityHint(
      effectiveDestination.map { "Abre \($0.absoluteString) no navegador" } ?? ""
    )
  }
}

struct BrainSectionCard<Content: View>: View {
  let title: String
  let iconName: String
  let iconTone: BrainCardTone
  let badgeText: String
  let badgeTone: BrainCardTone
  let cardTone: BrainCardTone
  var headerLinks: [BrainHeaderLinkSpec] = []
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 5) {
        HStack(spacing: 6) {
          Image(systemName: iconName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(iconTone == .neutral ? Color.secondary : iconTone.color)
            .frame(width: 19, height: 19)
            .background(
              (iconTone == .neutral ? Color.primary.opacity(0.08) : iconTone.color.opacity(0.14)),
              in: RoundedRectangle(cornerRadius: 4.5)
            )

          Text(title)
            .font(.caption.weight(.semibold))
            .lineLimit(1)

          Spacer(minLength: 4)

          BrainSectionBadge(text: badgeText, tone: badgeTone)
        }
        .accessibilityElement(children: .combine)

        if !headerLinks.isEmpty {
          HStack(spacing: 4) {
            ForEach(headerLinks) { linkSpec in
              BrainInlineLinkButton(spec: linkSpec)
            }
          }
        }
      }

      content()
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(cardTone.borderColor, lineWidth: 0.6)
    }
  }
}

struct BrainSectionErrorView: View {
  let message: String

  var body: some View {
    HStack(alignment: .top, spacing: 6) {
      Image(systemName: "xmark.octagon.fill")
        .font(.caption2)
        .foregroundStyle(.red)
        .padding(.top, 1)

      Text(message)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(8)
    .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .stroke(Color.red.opacity(0.24), lineWidth: 0.5)
    }
    .accessibilityElement(children: .combine)
  }
}
