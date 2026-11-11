import SwiftUI

struct BrainScheduledJobsCardView: View {
  let state: BrainSectionState<ScheduledJobsState>
  let now: Date
  let brainPagesURL: URL
  let canOpenPages: Bool
  let openURLAction: (URL) -> Void

  private func hasJobFailure(_ scheduled: ScheduledJobsState) -> Bool {
    if scheduled.restoreRehearsal?.isPassing == false {
      return true
    }
    return scheduled.jobs.contains { job in
      switch job.status {
      case .failed, .exitedWithError:
        true
      case .running, .succeeded, .loadedIdle, .unloaded:
        false
      }
    }
  }

  private var badgeInfo: (text: String, tone: BrainCardTone) {
    switch state {
    case .failed:
      return ("Falha", .critical)
    case .loaded(let scheduled):
      if hasJobFailure(scheduled) {
        return ("Falha", .critical)
      }
      return ("\(scheduled.jobs.count) jobs", .neutral)
    }
  }

  private var cardTone: BrainCardTone {
    switch state {
    case .failed:
      return .critical
    case .loaded(let scheduled):
      return hasJobFailure(scheduled) ? .critical : .neutral
    }
  }

  var body: some View {
    BrainSectionCard(
      title: "Jobs Agendados",
      iconName: "calendar.badge.clock",
      iconTone: cardTone == .critical ? .critical : .active,
      badgeText: badgeInfo.text,
      badgeTone: badgeInfo.tone,
      cardTone: cardTone,
      headerAccessory: {
        BrainInlineLinkButton(
          title: "Agenda",
          destinationURL: BrainPagesNavigator.resolveSection(
            .scheduledJobs,
            baseURL: brainPagesURL
          ),
          isEnabled: canOpenPages,
          accessibilityLabel: "Abrir seção de jobs agendados no brain-pages",
          action: openURLAction
        )
      }
    ) {
      switch state {
      case .failed(let appError):
        BrainSectionErrorView(message: appError.userMessage)
      case .loaded(let scheduled):
        if scheduled.jobs.isEmpty,
          scheduled.weeklyCleanupAt == nil,
          scheduled.restoreRehearsal == nil
        {
          Text("Nenhum LaunchAgent agendado encontrado.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        } else {
          VStack(alignment: .leading, spacing: 5.5) {
            ForEach(scheduled.jobs) { job in
              BrainScheduledJobRowView(job: job, now: now)
            }

            if scheduled.weeklyCleanupAt != nil || scheduled.restoreRehearsal != nil {
              Divider()
                .opacity(0.3)

              if let cleanupAt = scheduled.weeklyCleanupAt {
                HStack(spacing: 5) {
                  Image(systemName: "sparkles")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)

                  Text("Faxina semanal")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                  Spacer(minLength: 4)

                  Text(RelativeTimeFormatter.elapsedPhrase(since: cleanupAt, now: now))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                .accessibilityElement(children: .combine)
              }

              if let rehearsal = scheduled.restoreRehearsal {
                BrainRestoreRehearsalRowView(rehearsal: rehearsal, now: now)
              }
            }
          }
        }
      }
    }
  }
}

private struct BrainScheduledJobRowView: View {
  let job: ScheduledJob
  let now: Date

  private var statusDisplay: (label: String, color: Color) {
    switch job.status {
    case .running:
      ("Rodando", .blue)
    case .succeeded:
      ("OK", .green)
    case .loadedIdle:
      ("Aguardando", .secondary)
    case .unloaded:
      ("Inativo", .orange)
    case .failed:
      ("Falhou", .red)
    case .exitedWithError(let code):
      ("Erro \(code)", .red)
    }
  }

  private var timingSummary: String? {
    var parts: [String] = []
    if let lastRunAt = job.lastRunAt {
      parts.append("últ. \(RelativeTimeFormatter.elapsedPhrase(since: lastRunAt, now: now))")
    }
    if let nextRunAt = job.nextRunAt {
      let remaining = max(nextRunAt.timeIntervalSince(now), 0)
      parts.append("próx. em \(RelativeTimeFormatter.compactDuration(seconds: remaining))")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 5) {
        Circle()
          .fill(statusDisplay.color)
          .frame(width: 6, height: 6)

        Text(job.title)
          .font(.caption2.weight(.medium))
          .lineLimit(1)
          .help("\(job.title) (\(job.label))")

        Spacer(minLength: 4)

        Text(statusDisplay.label)
          .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
          .foregroundStyle(statusDisplay.color)
      }

      HStack(spacing: 4) {
        Text(job.scheduleSummary)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)

        Spacer(minLength: 4)

        if let timingSummary {
          Text(timingSummary)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
      .padding(.leading, 11)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct BrainRestoreRehearsalRowView: View {
  let rehearsal: RestoreRehearsalStatus
  let now: Date

  private var statusText: String {
    if rehearsal.isPassing {
      if let restored = rehearsal.restoredCount, let expected = rehearsal.expectedCount {
        return "OK (\(restored)/\(expected))"
      }
      return "OK"
    }
    return "Falhou"
  }

  var body: some View {
    HStack(spacing: 5) {
      Image(
        systemName: rehearsal.isPassing ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
      )
      .font(.system(size: 9, weight: .semibold))
      .foregroundStyle(rehearsal.isPassing ? .green : .red)

      Text("Ensaio de restauração:")
        .font(.caption2)
        .foregroundStyle(.secondary)

      Text(statusText)
        .font(.caption2.monospacedDigit().weight(.medium))
        .foregroundStyle(rehearsal.isPassing ? Color.primary : Color.red)

      Spacer(minLength: 4)

      Text(RelativeTimeFormatter.elapsedPhrase(since: rehearsal.ranAt, now: now))
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .accessibilityElement(children: .combine)
  }
}
