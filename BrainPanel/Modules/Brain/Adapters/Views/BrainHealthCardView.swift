import SwiftUI

struct BrainHealthCardView: View {
  let state: BrainSectionState<HealthAndBackupState>
  let now: Date

  private func hasCriticalHealthIssue(_ health: HealthAndBackupState) -> Bool {
    if !health.doctorFailures.isEmpty { return true }
    if health.testSuite?.isPassing == false { return true }
    if health.syncStatus?.isPassing == false { return true }
    if health.backupStatus?.needsAttention == true { return true }
    if health.liveBackupProgress?.isStalled == true { return true }
    return false
  }

  private var badgeInfo: (text: String, tone: BrainCardTone) {
    switch state {
    case .failed:
      return ("Falha", .critical)
    case .loaded(let health):
      if hasCriticalHealthIssue(health) {
        return ("Atenção", .critical)
      }
      if !health.doctorWarnings.isEmpty {
        let count = health.doctorWarnings.count
        return ("\(count) aviso\(count == 1 ? "" : "s")", .warning)
      }
      if health.isActivelyBackingUp {
        return ("Copiando", .active)
      }
      return ("Saudável", .healthy)
    }
  }

  private var cardTone: BrainCardTone {
    switch state {
    case .failed:
      return .critical
    case .loaded(let health):
      if hasCriticalHealthIssue(health) {
        return .critical
      }
      if !health.doctorWarnings.isEmpty {
        return .warning
      }
      if health.isActivelyBackingUp {
        return .active
      }
      return .neutral
    }
  }

  var body: some View {
    BrainSectionCard(
      title: "Saúde & Backup",
      iconName: "cross.case.fill",
      iconTone: badgeInfo.tone,
      badgeText: badgeInfo.text,
      badgeTone: badgeInfo.tone,
      cardTone: cardTone
    ) {
      switch state {
      case .failed(let appError):
        BrainSectionErrorView(message: appError.userMessage)
      case .loaded(let health):
        VStack(alignment: .leading, spacing: 6.5) {
          BrainDoctorSectionView(
            failures: health.doctorFailures,
            warnings: health.doctorWarnings,
            checkedAt: health.doctorCheckedAt,
            now: now
          )

          if health.testSuite != nil || health.syncStatus != nil {
            VStack(alignment: .leading, spacing: 4) {
              if let suite = health.testSuite {
                BrainTestSuiteRowView(suite: suite, now: now)
              }
              if let sync = health.syncStatus {
                BrainSyncStatusRowView(sync: sync, now: now)
              }
            }
          }

          if let liveBackup = health.liveBackupProgress {
            BrainLiveBackupProgressBox(progress: liveBackup)
          } else if let backup = health.backupStatus {
            BrainCompletedBackupRowView(backup: backup, now: now)
          }
        }
      }
    }
  }
}

private struct BrainDoctorSectionView: View {
  let failures: [DoctorFinding]
  let warnings: [DoctorFinding]
  let checkedAt: Date?
  let now: Date

  private var ageLabel: String {
    guard let checkedAt else { return "sem leitura recente" }
    return RelativeTimeFormatter.elapsedPhrase(since: checkedAt, now: now)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Label(
          failures.isEmpty && warnings.isEmpty
            ? "brain-doctor em dia" : "brain-doctor",
          systemImage: failures.isEmpty
            ? (warnings.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            : "xmark.octagon.fill"
        )
        .font(.caption2.weight(.medium))
        .foregroundStyle(
          failures.isEmpty ? (warnings.isEmpty ? Color.green : Color.orange) : Color.red
        )

        Spacer(minLength: 4)

        Text(ageLabel)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .accessibilityElement(children: .combine)

      ForEach(failures) { finding in
        BrainDoctorFindingRowView(finding: finding)
      }

      ForEach(warnings) { finding in
        BrainDoctorFindingRowView(finding: finding)
      }
    }
  }
}

private struct BrainDoctorFindingRowView: View {
  let finding: DoctorFinding

  private var findingColor: Color {
    finding.severity == .fail ? .red : .orange
  }

  var body: some View {
    let fullText = "\(finding.key) — \(finding.message)"
    HStack(alignment: .top, spacing: 5) {
      Image(
        systemName: finding.severity == .fail
          ? "xmark.circle.fill" : "exclamationmark.triangle.fill"
      )
      .font(.system(size: 9, weight: .semibold))
      .foregroundStyle(findingColor)
      .padding(.top, 1.5)

      Text(fullText)
        .font(.caption2)
        .foregroundStyle(.primary)
        .lineLimit(2)
        .help(fullText)
    }
    .padding(6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(findingColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6.5))
    .accessibilityElement(children: .combine)
  }
}

private struct BrainTestSuiteRowView: View {
  let suite: TestSuiteStatus
  let now: Date

  private var detailText: String {
    if suite.isPassing {
      return "\(suite.ranCount) verdes"
    }
    if suite.failedTests.isEmpty {
      return "falhou"
    }
    return "falhou (\(suite.failedTests.joined(separator: ", ")))"
  }

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: suite.isPassing ? "checkmark.circle.fill" : "xmark.octagon.fill")
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(suite.isPassing ? .green : .red)

      Text("brain-test:")
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)

      Text(detailText)
        .font(.caption2.monospacedDigit())
        .foregroundStyle(suite.isPassing ? Color.primary : Color.red)
        .lineLimit(1)
        .help(detailText)

      Spacer(minLength: 4)

      if let ranAt = suite.ranAt {
        Text(RelativeTimeFormatter.elapsedPhrase(since: ranAt, now: now))
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

private struct BrainSyncStatusRowView: View {
  let sync: SyncStatus
  let now: Date

  private var detailText: String {
    if sync.isPassing {
      if let sha = sync.commitSHA {
        return "OK (\(sha))"
      }
      return "OK"
    }
    return sync.reason ?? "falhou"
  }

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: sync.isPassing ? "checkmark.circle.fill" : "xmark.octagon.fill")
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(sync.isPassing ? .green : .red)

      Text("brain-sync:")
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)

      Text(detailText)
        .font(.caption2.monospacedDigit())
        .foregroundStyle(sync.isPassing ? Color.primary : Color.red)
        .lineLimit(1)
        .help(detailText)

      Spacer(minLength: 4)

      if let syncedAt = sync.syncedAt {
        Text(RelativeTimeFormatter.elapsedPhrase(since: syncedAt, now: now))
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

private struct BrainLiveBackupProgressBox: View {
  let progress: LiveBackupProgress

  private var clampedFraction: Double {
    min(max(progress.fractionCompleted, 0), 1)
  }

  private var percentageInt: Int {
    Int((clampedFraction * 100).rounded())
  }

  private var accentColor: Color {
    progress.isStalled ? .red : .blue
  }

  private var bytesSummary: String {
    let processed = ByteCountFormatter.string(fromByteCount: progress.processedBytes, countStyle: .file)
    let total = ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
    return "\(processed) / \(total)"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4.5) {
      HStack(spacing: 5) {
        Image(
          systemName: progress.isStalled
            ? "exclamationmark.octagon.fill" : "externaldrive.fill.badge.timemachine"
        )
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(accentColor)

        Text(
          progress.isStalled
            ? "Backup travado (\(progress.phase))"
            : "Backup em andamento (\(progress.phase))"
        )
        .font(.caption2.weight(.semibold))
        .foregroundStyle(progress.isStalled ? Color.red : Color.primary)
        .lineLimit(1)

        Spacer(minLength: 4)

        Text("\(percentageInt)%")
          .font(.caption2.monospacedDigit().weight(.semibold))
          .foregroundStyle(accentColor)
      }

      ProgressView(value: clampedFraction)
        .tint(accentColor)

      HStack(spacing: 4) {
        Text(bytesSummary)
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)

        if progress.errorCount > 0 {
          Text("· \(progress.errorCount) erro\(progress.errorCount == 1 ? "" : "s")")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.red)
        }

        Spacer(minLength: 4)

        if let eta = progress.estimatedRemainingSeconds, !progress.isStalled {
          Text("resta \(RelativeTimeFormatter.compactDuration(seconds: Double(eta)))")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
      }

      if let folder = progress.currentFolder {
        Text(folder)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(folder)
      }
    }
    .padding(7.5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(accentColor.opacity(0.24), lineWidth: 0.5)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct BrainCompletedBackupRowView: View {
  let backup: BackupStatus
  let now: Date

  private var statusColor: Color {
    if !backup.isPassing || backup.isOverdue {
      return .red
    }
    return .green
  }

  private var statusIcon: String {
    if !backup.isPassing {
      return "xmark.octagon.fill"
    }
    if backup.isOverdue {
      return "exclamationmark.triangle.fill"
    }
    return "checkmark.circle.fill"
  }

  private var detailText: String {
    if !backup.isPassing {
      return backup.reason ?? "falha no snapshot"
    }
    if backup.isOverdue {
      return "atrasado (> 2 dias)"
    }
    if let snapshotID = backup.snapshotID {
      return "snapshot \(snapshotID)"
    }
    return "em dia"
  }

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: statusIcon)
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(statusColor)

      Text("brain-backup:")
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)

      Text(detailText)
        .font(.caption2.monospacedDigit())
        .foregroundStyle(backup.needsAttention ? Color.red : Color.primary)
        .lineLimit(1)
        .help(detailText)

      Spacer(minLength: 4)

      if let completedAt = backup.completedAt {
        Text(RelativeTimeFormatter.elapsedPhrase(since: completedAt, now: now))
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .accessibilityElement(children: .combine)
  }
}
