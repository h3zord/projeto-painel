import SwiftUI

enum MenuTab: String, CaseIterable, Identifiable {
  case quotas = "Cotas"
  case sessions = "Sessões"
  case brain = "Brain"

  var id: String { rawValue }

  var icon: String {
    switch self {
    case .quotas:
      "gauge.with.dots.needle.33percent"
    case .sessions:
      "bubble.left.and.bubble.right.fill"
    case .brain:
      "brain.head.profile"
    }
  }
}

struct MenuTabBar: View {
  @Binding var selectedTab: MenuTab
  let activeSessionCount: Int
  var brainWaitingCount: Int = 0
  var brainHasCriticalFailure: Bool = false
  var brainHasDegradedSection: Bool = false

  var body: some View {
    HStack(spacing: 5) {
      ForEach(MenuTab.allCases) { tab in
        let isSelected = selectedTab == tab
        Button {
          withAnimation(.smooth(duration: 0.22)) {
            selectedTab = tab
          }
        } label: {
          HStack(spacing: 4.5) {
            Image(systemName: tab.icon)
              .font(.system(size: 10, weight: .semibold))

            Text(tab.rawValue)
              .font(.caption.weight(.semibold))
              .lineLimit(1)

            badgeView(for: tab)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 5.5)
          .foregroundStyle(isSelected ? .primary : .secondary)
          .background(
            isSelected ? Color.primary.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: tab))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
      }
    }
    .padding(3)
    .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
    .overlay {
      RoundedRectangle(cornerRadius: 9)
        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
    }
  }

  @ViewBuilder
  private func badgeView(for tab: MenuTab) -> some View {
    switch tab {
    case .quotas:
      EmptyView()
    case .sessions:
      if activeSessionCount > 0 {
        Text("\(activeSessionCount)")
          .font(.system(size: 9.5, weight: .bold).monospacedDigit())
          .padding(.horizontal, 4.5)
          .padding(.vertical, 1)
          .background(Color.primary.opacity(0.12), in: Capsule())
      }
    case .brain:
      if brainHasCriticalFailure {
        HStack(spacing: 2) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 8.5, weight: .bold))
          if brainWaitingCount > 0 {
            Text("\(brainWaitingCount)")
              .font(.system(size: 9.5, weight: .bold).monospacedDigit())
          }
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 4.5)
        .padding(.vertical, 1)
        .background(Color.red.opacity(0.16), in: Capsule())
      } else if brainWaitingCount > 0 {
        Text("\(brainWaitingCount)")
          .font(.system(size: 9.5, weight: .bold).monospacedDigit())
          .foregroundStyle(.orange)
          .padding(.horizontal, 4.5)
          .padding(.vertical, 1)
          .background(Color.orange.opacity(0.18), in: Capsule())
      } else if brainHasDegradedSection {
        Image(systemName: "exclamationmark.circle.fill")
          .font(.system(size: 9.5, weight: .semibold))
          .foregroundStyle(.orange)
      }
    }
  }

  private func accessibilityLabel(for tab: MenuTab) -> String {
    switch tab {
    case .quotas:
      return "Aba Cotas"
    case .sessions:
      if activeSessionCount == 0 {
        return "Aba Sessões"
      }
      let suffix = activeSessionCount == 1 ? "1 sessão ativa" : "\(activeSessionCount) sessões ativas"
      return "Aba Sessões, \(suffix)"
    case .brain:
      var parts = ["Aba Brain"]
      if brainHasCriticalFailure {
        parts.append("falha crítica")
      }
      if brainWaitingCount == 1 {
        parts.append("1 item esperando você")
      } else if brainWaitingCount > 1 {
        parts.append("\(brainWaitingCount) itens esperando você")
      }
      if brainHasDegradedSection {
        parts.append("leitura parcial com falha")
      }
      return parts.joined(separator: ", ")
    }
  }
}
