import SwiftUI

struct BrainCIQueueCardView: View {
  let state: BrainSectionState<CIQueueState>
  let now: Date
  let brainPagesURL: URL
  let canOpenPages: Bool
  let openURLAction: (URL) -> Void

  private var badgeInfo: (text: String, tone: BrainCardTone) {
    switch state {
    case .failed:
      return ("Falha", .critical)
    case .loaded(let queue):
      if queue.pauseState != nil {
        return ("Pausada", .warning)
      }
      if !queue.runningTickets.isEmpty {
        return ("\(queue.runningTickets.count) rodando", .active)
      }
      if !queue.waitingTickets.isEmpty {
        return ("\(queue.waitingTickets.count) na fila", .warning)
      }
      return ("Livre", .neutral)
    }
  }

  private var cardTone: BrainCardTone {
    switch state {
    case .failed:
      return .critical
    case .loaded(let queue):
      if queue.pauseState != nil || !queue.recentAlerts.isEmpty {
        return .warning
      }
      if !queue.runningTickets.isEmpty {
        return .active
      }
      return .neutral
    }
  }

  private func freshVMMemoryText(for queue: CIQueueState) -> String? {
    guard let availableMB = queue.vmAvailableMB else { return nil }
    if let measuredAt = queue.vmMeasuredAt, now.timeIntervalSince(measuredAt) > 600 {
      return nil
    }
    if availableMB >= 1_024 {
      let gigabytes = availableMB / 1_024.0
      return String(format: "VM %.1f GB livres", gigabytes)
    }
    return "VM \(Int(availableMB.rounded())) MB livres"
  }

  var body: some View {
    BrainSectionCard(
      title: "Fila da Máquina (brain-ci)",
      iconName: "cpu.fill",
      iconTone: cardTone == .neutral ? .active : cardTone,
      badgeText: badgeInfo.text,
      badgeTone: badgeInfo.tone,
      cardTone: cardTone,
      headerAccessory: {
        BrainInlineLinkButton(
          title: "Fila",
          destinationURL: BrainPagesNavigator.resolveSection(.ciQueue, baseURL: brainPagesURL),
          isEnabled: canOpenPages,
          accessibilityLabel: "Abrir página da fila brain-ci no brain-pages",
          action: openURLAction
        )
      }
    ) {
      switch state {
      case .failed(let appError):
        BrainSectionErrorView(message: appError.userMessage)
      case .loaded(let queue):
        VStack(alignment: .leading, spacing: 6.5) {
          if let pause = queue.pauseState {
            BrainCINoticeBanner(
              iconName: "pause.circle.fill",
              title: "Fila pausada: \(pause.reason)",
              subtitle: pause.pausedAt.map {
                "Desde \(RelativeTimeFormatter.elapsedPhrase(since: $0, now: now))"
              },
              tone: .warning
            )
          }

          if queue.isSerial {
            let reasonSuffix = queue.serialReason.map { " — \($0)" } ?? ""
            BrainCINoticeBanner(
              iconName: "arrow.right.to.line.compact",
              title: "Modo serial ativo\(reasonSuffix)",
              subtitle: nil,
              tone: .warning
            )
          }

          HStack(spacing: 6) {
            let summary = queue.todaySummary
            let todayColor: Color =
              summary.nonGreenCount > 0
              ? .orange
              : (summary.totalCount > 0 ? .green : .secondary)

            Label(
              "Hoje: \(summary.greenCount)/\(summary.totalCount) verdes",
              systemImage: summary.nonGreenCount > 0
                ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
            )
            .font(.caption2.monospacedDigit())
            .foregroundStyle(todayColor)

            Spacer(minLength: 4)

            if let memoryText = freshVMMemoryText(for: queue) {
              Text(memoryText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
          }
          .accessibilityElement(children: .combine)

          if !queue.runningTickets.isEmpty {
            VStack(alignment: .leading, spacing: 4.5) {
              ForEach(queue.runningTickets) { ticket in
                BrainCITicketRowView(ticket: ticket, isRunning: true, now: now)
              }
            }
          }

          if !queue.waitingTickets.isEmpty {
            VStack(alignment: .leading, spacing: 4.5) {
              ForEach(queue.waitingTickets) { ticket in
                BrainCITicketRowView(ticket: ticket, isRunning: false, now: now)
              }
            }
          }

          if !queue.recentAlerts.isEmpty {
            VStack(alignment: .leading, spacing: 3.5) {
              ForEach(queue.recentAlerts.prefix(3)) { alert in
                BrainCIAlertRowView(alert: alert, now: now)
              }
            }
          }

          if !queue.recentRuns.isEmpty {
            Divider()
              .opacity(0.3)

            VStack(alignment: .leading, spacing: 3.5) {
              ForEach(queue.recentRuns.prefix(3)) { run in
                BrainCIRecentRunRowView(run: run, now: now)
              }
            }
          } else if queue.runningTickets.isEmpty,
            queue.waitingTickets.isEmpty,
            queue.recentAlerts.isEmpty,
            queue.pauseState == nil,
            queue.todaySummary.totalCount == 0
          {
            Text("Nenhum ticket em execução nem corridas registradas hoje.")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        }
      }
    }
  }
}

private struct BrainCINoticeBanner: View {
  let iconName: String
  let title: String
  let subtitle: String?
  let tone: BrainCardTone

  var body: some View {
    HStack(alignment: .top, spacing: 5.5) {
      Image(systemName: iconName)
        .font(.caption2)
        .foregroundStyle(tone.color)
        .padding(.top, 1)

      VStack(alignment: .leading, spacing: 1.5) {
        Text(title)
          .font(.caption2.weight(.medium))
          .foregroundStyle(.primary)
          .lineLimit(2)
          .help(title)

        if let subtitle {
          Text(subtitle)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(6.5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(tone.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .stroke(tone.color.opacity(0.22), lineWidth: 0.5)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct BrainCITicketRowView: View {
  let ticket: CIQueueTicket
  let isRunning: Bool
  let now: Date

  private var accentColor: Color {
    isRunning ? .blue : .orange
  }

  private var titleLine: String {
    var parts = [ticket.project]
    if let jobType = ticket.jobType {
      parts.append(jobType)
    } else if let role = ticket.role {
      parts.append(role)
    }
    return parts.joined(separator: " · ")
  }

  private var rightMetric: String? {
    if isRunning, let startedAt = ticket.startedAt {
      return RelativeTimeFormatter.compactDuration(seconds: now.timeIntervalSince(startedAt))
    }
    if !isRunning, let queuedAt = ticket.queuedAt {
      return RelativeTimeFormatter.compactDuration(seconds: now.timeIntervalSince(queuedAt))
    }
    return nil
  }

  private var detailLine: String? {
    if isRunning {
      return ticket.command
    }
    return ticket.primaryWaitReason ?? "aguardando vaga na fila"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2.5) {
      HStack(spacing: 5) {
        Image(systemName: isRunning ? "play.circle.fill" : "hourglass")
          .font(.system(size: 9.5, weight: .semibold))
          .foregroundStyle(accentColor)

        Text(titleLine)
          .font(.caption.weight(.medium))
          .lineLimit(1)

        if ticket.isSolo {
          Text("solo")
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(accentColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 0.5)
            .background(accentColor.opacity(0.15), in: Capsule())
        }

        Spacer(minLength: 4)

        if let rightMetric {
          Text(rightMetric)
            .font(.caption2.monospacedDigit().weight(.medium))
            .foregroundStyle(accentColor)
        }
      }

      if let detailLine {
        Text(detailLine)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .help(detailLine)
      }
    }
    .padding(6.5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .stroke(accentColor.opacity(0.18), lineWidth: 0.5)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct BrainCIRecentRunRowView: View {
  let run: CIRecentRun
  let now: Date

  private var runColor: Color {
    if run.isGreen {
      return .green
    }
    return run.isInterrupted ? .orange : .red
  }

  private var runIcon: String {
    if run.isGreen {
      return "checkmark.circle.fill"
    }
    return run.isInterrupted ? "stop.circle.fill" : "xmark.circle.fill"
  }

  private var labelText: String {
    if let jobType = run.jobType {
      return "\(run.project) · \(jobType)"
    }
    return run.project
  }

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: runIcon)
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(runColor)

      Text(labelText)
        .font(.caption2.weight(.medium))
        .lineLimit(1)

      Spacer(minLength: 4)

      Text(RelativeTimeFormatter.compactDuration(seconds: run.durationSeconds))
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)

      Text("· \(RelativeTimeFormatter.elapsedPhrase(since: run.endedAt, now: now))")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct BrainCIAlertRowView: View {
  let alert: CIQueueAlert
  let now: Date

  var body: some View {
    let summary = "\(alert.project): \(alert.alarm)"
    HStack(spacing: 5) {
      Image(systemName: "bell.fill")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.orange)

      Text(summary)
        .font(.caption2)
        .foregroundStyle(.primary)
        .lineLimit(1)
        .help(summary)

      Spacer(minLength: 4)

      Text(RelativeTimeFormatter.elapsedPhrase(since: alert.alertedAt, now: now))
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .accessibilityElement(children: .combine)
  }
}
