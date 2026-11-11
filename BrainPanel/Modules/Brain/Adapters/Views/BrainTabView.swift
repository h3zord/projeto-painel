import AppKit
import SwiftUI

struct BrainTabView: View {
  let snapshot: BrainSnapshot
  let referenceDate: Date
  let brainPagesURL: URL
  var openPagesAction: ((URL) -> Void)? = nil

  private var canOpenPages: Bool {
    AppConfig.isSafeLoopbackPagesURL(brainPagesURL)
  }

  private var headerTone: BrainCardTone {
    if snapshot.hasCriticalFailure {
      return .critical
    }
    if snapshot.waitingOnOwnerCount > 0 || !snapshot.degradedSections.isEmpty {
      return .warning
    }
    return .healthy
  }

  private var statusSummary: String {
    if snapshot.hasCriticalFailure {
      return "Atenção imediata"
    }
    if snapshot.waitingOnOwnerCount > 0 {
      let count = snapshot.waitingOnOwnerCount
      return count == 1 ? "1 item esperando você" : "\(count) itens esperando você"
    }
    if !snapshot.degradedSections.isEmpty {
      return "Leitura parcial (\(snapshot.degradedSections.count) com falha)"
    }
    if snapshot.capturedAt == nil {
      return "Aguardando leitura local"
    }
    return "Operacional em modo somente-leitura"
  }

  var body: some View {
    VStack(spacing: 8.5) {
      HStack(spacing: 7) {
        Circle()
          .fill(snapshot.capturedAt == nil ? Color.secondary.opacity(0.5) : headerTone.color)
          .frame(width: 6.5, height: 6.5)

        Text(statusSummary)
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)

        Spacer(minLength: 4)

        Button {
          openBrainPages()
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "globe")
              .font(.system(size: 9.5, weight: .semibold))
            Text("brain-pages")
              .font(.caption2.weight(.semibold))
            Image(systemName: "arrow.up.right")
              .font(.system(size: 8, weight: .bold))
          }
          .foregroundStyle(.blue)
          .padding(.horizontal, 7)
          .padding(.vertical, 3.5)
          .background(Color.blue.opacity(0.12), in: Capsule())
          .overlay {
            Capsule()
              .stroke(Color.blue.opacity(0.24), lineWidth: 0.5)
          }
        }
        .buttonStyle(.plain)
        .disabled(!canOpenPages)
        .help(brainPagesURL.absoluteString)
        .accessibilityLabel("Abrir painel web local brain-pages")
      }
      .padding(.horizontal, 2)

      ScrollView(.vertical, showsIndicators: true) {
        TimelineView(.periodic(from: referenceDate, by: 60)) { context in
          VStack(spacing: 8.5) {
            BrainWaitingCardView(state: snapshot.waiting, now: context.date)
            BrainCIQueueCardView(state: snapshot.ciQueue, now: context.date)
            BrainHealthCardView(state: snapshot.healthAndBackup, now: context.date)
            BrainScheduledJobsCardView(state: snapshot.scheduledJobs, now: context.date)
          }
          .padding(.trailing, 2)
        }
      }
      .frame(maxHeight: 416)
    }
  }

  private func openBrainPages() {
    let customOpener = openPagesAction
    _ = Self.openIfLoopbackSafe(brainPagesURL) { validatedURL in
      if let customOpener {
        customOpener(validatedURL)
      } else {
        NSWorkspace.shared.open(validatedURL)
      }
    }
  }

  nonisolated static func openIfLoopbackSafe(
    _ url: URL,
    using opener: (URL) -> Void
  ) -> Bool {
    guard AppConfig.isSafeLoopbackPagesURL(url) else { return false }
    opener(url)
    return true
  }
}
