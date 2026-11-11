import SwiftUI

struct ProviderDetailsView: View {
  let provider: ProviderUsage
  let referenceDate: Date

  private var color: Color {
    switch provider.tint {
    case .orange:
      .orange
    case .blue:
      .blue
    }
  }

  private var borderColor: Color {
    if provider.sessionState.isUnavailable {
      return Color.red.opacity(0.34)
    }
    if provider.sessionState.isStale {
      return Color.orange.opacity(0.32)
    }
    return color.opacity(0.2)
  }

  private var geminiGroups: [GeminiModelGroup] {
    var orderedNames: [String] = []
    var groups: [String: [UsageLimit]] = [:]

    for limit in provider.limits {
      if groups[limit.name] == nil {
        orderedNames.append(limit.name)
      }
      groups[limit.name, default: []].append(limit)
    }

    return orderedNames.map { GeminiModelGroup(name: $0, limits: groups[$0] ?? []) }
  }

  @ViewBuilder
  private var headerBadge: some View {
    if provider.sessionState.isUnavailable {
      Label(provider.sessionState.label, systemImage: "xmark.octagon.fill")
        .font(.caption2.weight(.medium))
        .foregroundStyle(.red)
    } else if provider.sessionState.isStale {
      Label(provider.sessionState.label, systemImage: "exclamationmark.triangle.fill")
        .font(.caption2.weight(.medium))
        .foregroundStyle(.orange)
    } else if provider.sessionState.isLoading {
      Label("Carregando…", systemImage: "clock")
        .font(.caption2)
        .foregroundStyle(.secondary)
    } else {
      Label(provider.sessionState.label, systemImage: "circle.fill")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .symbolRenderingMode(.monochrome)
    }
  }

  var body: some View {
    VStack(spacing: 9) {
      HStack {
        Text(provider.name)
          .font(.caption.weight(.semibold))

        Spacer()

        headerBadge
      }

      if let reason = provider.unavailableReason {
        UnavailableProviderMessage(reason: reason)
      } else if provider.sessionState.isLoading {
        LoadingProviderMessage()
      } else {
        if case .stale(let reason, let lastUpdatedAt) = provider.sessionState {
          StaleProviderMessage(
            reason: reason,
            lastUpdatedAt: lastUpdatedAt,
            referenceDate: referenceDate
          )
        }

        if provider.id == KnownProviderID.gemini.rawValue {
          ForEach(geminiGroups) { group in
            GeminiModelGroupView(group: group, color: color, referenceDate: referenceDate)
          }
        } else {
          ForEach(provider.limits) { limit in
            DetailedLimitRow(limit: limit, color: color, referenceDate: referenceDate)
          }
        }
      }
    }
    .padding(10)
    .background(.background.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(borderColor, lineWidth: 0.5)
    }
  }
}

private struct GeminiModelGroup: Identifiable {
  var id: String { name }
  let name: String
  let limits: [UsageLimit]
}

private struct GeminiModelGroupView: View {
  let group: GeminiModelGroup
  let color: Color
  let referenceDate: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(group.name)
        .font(.caption.weight(.semibold))

      VStack(spacing: 6) {
        ForEach(group.limits) { limit in
          ModelSubLimitRow(limit: limit, color: color, referenceDate: referenceDate)
        }
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(color.opacity(0.14), lineWidth: 0.5)
    }
  }
}

private struct ModelSubLimitRow: View {
  let limit: UsageLimit
  let color: Color
  let referenceDate: Date

  var body: some View {
    VStack(spacing: 3.5) {
      HStack(alignment: .firstTextBaseline) {
        Text(limit.window == .session ? "Sessão de 5 horas" : "Semanal")
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)

        Spacer()

        Text("\(limit.remainingPercentage)% disponível")
          .font(.caption2.monospacedDigit().weight(.semibold))
      }

      ProgressView(value: limit.fraction)
        .tint(progressColor)

      HStack {
        Text("\(limit.usedPercentage)% usado")
          .foregroundStyle(.secondary)

        Spacer()

        if let resetsAt = limit.resetsAt {
          TimelineView(.periodic(from: referenceDate, by: 60)) { context in
            ResetTimeView(resetsAt: resetsAt, now: context.date)
          }
        } else if limit.usedPercentage == 0 {
          Text("Cota cheia")
            .foregroundStyle(.secondary)
        } else {
          Text("Renovação indisponível")
            .foregroundStyle(.tertiary)
        }
      }
      .font(.caption2)
    }
    .accessibilityElement(children: .combine)
  }

  private var progressColor: Color {
    switch limit.remainingPercentage {
    case ...15:
      .red
    case ...35:
      .orange
    default:
      color
    }
  }
}

private struct StaleProviderMessage: View {
  let reason: String
  let lastUpdatedAt: Date
  let referenceDate: Date

  var body: some View {
    TimelineView(.periodic(from: referenceDate, by: 60)) { context in
      HStack(alignment: .top, spacing: 6) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.caption2)
          .foregroundStyle(.orange)
          .padding(.top, 1)

        VStack(alignment: .leading, spacing: 2) {
          Text(reason)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)

          Text(ProviderUsage.staleAgeSummary(since: lastUpdatedAt, now: context.date))
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
      .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
      .overlay {
        RoundedRectangle(cornerRadius: 7)
          .stroke(Color.orange.opacity(0.24), lineWidth: 0.5)
      }
      .accessibilityElement(children: .combine)
    }
  }
}

private struct LoadingProviderMessage: View {
  var body: some View {
    Label {
      Text("Aguardando leitura inicial em modo somente-leitura…")
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "clock")
        .foregroundStyle(.secondary)
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(8)
    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
    .accessibilityElement(children: .combine)
  }
}

private struct UnavailableProviderMessage: View {
  let reason: String

  var body: some View {
    Label {
      Text(reason)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "xmark.octagon.fill")
        .foregroundStyle(.red)
    }
    .font(.caption)
    .foregroundStyle(.primary)
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

private struct DetailedLimitRow: View {
  let limit: UsageLimit
  let color: Color
  let referenceDate: Date

  var body: some View {
    VStack(spacing: 5) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 1) {
          Text(limit.name)
            .font(.caption.weight(.medium))

          if let detail = limit.detail {
            Text(detail)
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        }

        Spacer()

        Text("\(limit.remainingPercentage)% disponível")
          .font(.caption.monospacedDigit().weight(.semibold))
      }

      ProgressView(value: limit.fraction)
        .tint(progressColor)

      HStack {
        Text("\(limit.usedPercentage)% usado")
          .foregroundStyle(.secondary)

        Spacer()

        if let resetsAt = limit.resetsAt {
          TimelineView(.periodic(from: referenceDate, by: 60)) { context in
            ResetTimeView(resetsAt: resetsAt, now: context.date)
          }
        } else if limit.usedPercentage == 0 {
          Text("Cota cheia")
            .foregroundStyle(.secondary)
        } else {
          Text("Renovação indisponível")
            .foregroundStyle(.tertiary)
        }
      }
      .font(.caption2)
    }
    .accessibilityElement(children: .combine)
  }

  private var progressColor: Color {
    switch limit.remainingPercentage {
    case ...15:
      .red
    case ...35:
      .orange
    default:
      color
    }
  }
}

private struct ResetTimeView: View {
  let resetsAt: Date
  let now: Date

  var body: some View {
    let remaining = max(resetsAt.timeIntervalSince(now), 0)

    Label {
      Text(remaining == 0 ? "Renovando" : "Renova em \(durationText(for: remaining))")
    } icon: {
      Image(systemName: "clock")
    }
    .foregroundStyle(.secondary)
  }

  private func durationText(for interval: TimeInterval) -> String {
    let totalMinutes = Int(interval / 60)
    let days = totalMinutes / 1_440
    let hours = (totalMinutes % 1_440) / 60
    let minutes = totalMinutes % 60

    if days > 0 {
      return "\(days)d \(hours)h"
    }

    if hours > 0 {
      return "\(hours)h \(minutes)m"
    }

    return "\(minutes)m"
  }
}
