import AppKit
import SwiftUI

struct ContentView: View {
  let store: UsageStore

  @State private var selectedTab: MenuTab
  @State private var selectedProviderID: ProviderUsage.ID?

  init(
    store: UsageStore,
    selectedTab: MenuTab = .quotas,
    selectedProviderID: ProviderUsage.ID? = nil
  ) {
    self.store = store
    self._selectedTab = State(initialValue: selectedTab)
    self._selectedProviderID = State(initialValue: selectedProviderID)
  }

  var body: some View {
    VStack(spacing: 8.5) {
      MenuTabBar(
        selectedTab: $selectedTab,
        activeSessionCount: store.activeConversations.count
      )

      switch selectedTab {
      case .quotas:
        VStack(spacing: 8.5) {
          QuotasSummaryView(
            providers: store.providers,
            referenceDate: store.currentDate,
            selectedProviderID: $selectedProviderID
          )
          ActiveConversationsSection(conversations: store.activeConversations)
        }
      case .sessions:
        SessionsTabView(conversations: store.activeConversations)
      }

      Divider()
        .opacity(0.4)

      HStack {
        Button {
          Task {
            await store.refresh()
          }
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "arrow.clockwise")
              .font(.system(size: 9, weight: .semibold))
              .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
              .animation(
                store.isRefreshing
                  ? .linear(duration: 1).repeatForever(autoreverses: false)
                  : .default,
                value: store.isRefreshing
              )
            Text(store.isRefreshing ? "Atualizando…" : "Atualizar")
              .font(.caption2)
          }
          .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(store.isRefreshing)

        Spacer()

        Button {
          NSApplication.shared.terminate(nil)
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "power")
              .font(.system(size: 9, weight: .semibold))
            Text("Encerrar")
              .font(.caption2)
          }
          .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 2)
    }
    .padding(10)
    .frame(width: 374)
    .background(.regularMaterial)
    .task {
      await store.refreshIfStale()
    }
  }
}

#Preview("Aba Cotas") {
  let previewEpoch = Date(timeIntervalSince1970: 1_762_819_200)
  ContentView(
    store: UsageStore(
      providers: ProviderUsage.makePreviewData(now: previewEpoch),
      activeConversations: ActiveConversation.previewData,
      collectors: [],
      conversationCollector: nil,
      startPeriodicRefresh: false
    ),
    selectedTab: .quotas
  )
}

#Preview("Aba Sessões") {
  let previewEpoch = Date(timeIntervalSince1970: 1_762_819_200)
  ContentView(
    store: UsageStore(
      providers: ProviderUsage.makePreviewData(now: previewEpoch),
      activeConversations: ActiveConversation.previewData,
      collectors: [],
      conversationCollector: nil,
      startPeriodicRefresh: false
    ),
    selectedTab: .sessions
  )
}
