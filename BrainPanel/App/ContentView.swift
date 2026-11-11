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
        activeSessionCount: store.activeConversations.count,
        brainWaitingCount: store.brainSnapshot.waitingOnOwnerCount,
        brainHasCriticalFailure: store.brainSnapshot.hasCriticalFailure,
        brainHasDegradedSection: !store.brainSnapshot.degradedSections.isEmpty
      )

      switch selectedTab {
      case .quotas:
        VStack(spacing: 8.5) {
          if store.brainSnapshot.needsAttentionBanner {
            BrainAttentionBanner(
              waitingCount: store.brainSnapshot.waitingOnOwnerCount,
              hasCriticalFailure: store.brainSnapshot.hasCriticalFailure
            ) {
              withAnimation(.smooth(duration: 0.22)) {
                selectedTab = .brain
              }
            }
          }

          QuotasSummaryView(
            providers: store.providers,
            referenceDate: store.currentDate,
            selectedProviderID: $selectedProviderID
          )

          ActiveConversationsSection(
            conversations: store.activeConversations,
            referenceDate: store.currentDate,
            errorMessage: store.lastConversationsError?.userMessage
          )
        }
      case .sessions:
        SessionsTabView(
          conversations: store.activeConversations,
          referenceDate: store.currentDate,
          errorMessage: store.lastConversationsError?.userMessage
        )
      case .brain:
        BrainTabView(
          snapshot: store.brainSnapshot,
          referenceDate: store.currentDate,
          brainPagesURL: store.brainPagesURL
        )
      }

      Divider()
        .opacity(0.4)

      HStack(spacing: 6) {
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
        .accessibilityLabel(
          store.isRefreshing ? "Atualizando dados locais" : "Atualizar dados locais"
        )

        Spacer(minLength: 4)

        TimelineView(.periodic(from: store.currentDate, by: 60)) { context in
          let summary = store.footerStatusSummary(now: context.date)
          Text(summary)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .accessibilityLabel("Estado da leitura: \(summary)")
        }

        Spacer(minLength: 4)

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
        .accessibilityLabel("Encerrar Brain Panel")
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

private nonisolated struct PreviewClock: Clock {
  let fixedDate: Date

  func now() -> Date {
    fixedDate
  }

  func sleep(for duration: Duration) async throws {
    try await Task.sleep(for: duration)
  }
}

#Preview("Aba Cotas") {
  let previewEpoch = Date(timeIntervalSince1970: 1_762_819_200)
  ContentView(
    store: UsageStore(
      providers: ProviderUsage.makePreviewData(now: previewEpoch),
      activeConversations: ActiveConversation.previewData,
      brainSnapshot: BrainSnapshot.makePreviewData(now: previewEpoch),
      collectors: [],
      conversationCollector: nil,
      clock: PreviewClock(fixedDate: previewEpoch),
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
      clock: PreviewClock(fixedDate: previewEpoch),
      startPeriodicRefresh: false
    ),
    selectedTab: .sessions
  )
}

#Preview("Aba Brain") {
  let previewEpoch = Date(timeIntervalSince1970: 1_762_819_200)
  ContentView(
    store: UsageStore(
      providers: ProviderUsage.makePreviewData(now: previewEpoch),
      activeConversations: ActiveConversation.previewData,
      brainSnapshot: BrainSnapshot.makePreviewData(now: previewEpoch),
      collectors: [],
      conversationCollector: nil,
      clock: PreviewClock(fixedDate: previewEpoch),
      startPeriodicRefresh: false
    ),
    selectedTab: .brain
  )
}
