import SwiftUI

struct QuotasSummaryView: View {
  let providers: [ProviderUsage]
  let referenceDate: Date
  @Binding var selectedProviderID: ProviderUsage.ID?

  var body: some View {
    VStack(spacing: 8.5) {
      HStack(alignment: .top, spacing: 8.5) {
        ForEach(providers) { provider in
          ProviderSummaryCard(
            provider: provider,
            isSelected: selectedProviderID == provider.id
          ) {
            withAnimation(.smooth(duration: 0.28)) {
              selectedProviderID = selectedProviderID == provider.id ? nil : provider.id
            }
          }
        }
      }

      if let selectedProviderID {
        ForEach(providers) { provider in
          if provider.id == selectedProviderID {
            ProviderDetailsView(provider: provider, referenceDate: referenceDate)
              .transition(
                .asymmetric(
                  insertion: .opacity.combined(with: .scale(scale: 0.985, anchor: .top)),
                  removal: .opacity
                )
              )
          }
        }
      }
    }
  }
}
