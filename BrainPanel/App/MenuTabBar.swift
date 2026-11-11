import SwiftUI

enum MenuTab: String, CaseIterable, Identifiable {
  case quotas = "Cotas"
  case sessions = "Sessões"

  var id: String { rawValue }

  var icon: String {
    switch self {
    case .quotas:
      "gauge.with.dots.needle.33percent"
    case .sessions:
      "bubble.left.and.bubble.right.fill"
    }
  }
}

struct MenuTabBar: View {
  @Binding var selectedTab: MenuTab
  let activeSessionCount: Int

  var body: some View {
    HStack(spacing: 5) {
      ForEach(MenuTab.allCases) { tab in
        let isSelected = selectedTab == tab
        Button {
          withAnimation(.smooth(duration: 0.22)) {
            selectedTab = tab
          }
        } label: {
          HStack(spacing: 5) {
            Image(systemName: tab.icon)
              .font(.system(size: 10, weight: .semibold))

            Text(tab.rawValue)
              .font(.caption.weight(.semibold))

            if tab == .sessions, activeSessionCount > 0 {
              Text("\(activeSessionCount)")
                .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                .padding(.horizontal, 4.5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.12), in: Capsule())
            }
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
      }
    }
    .padding(3)
    .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
    .overlay {
      RoundedRectangle(cornerRadius: 9)
        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
    }
  }
}
