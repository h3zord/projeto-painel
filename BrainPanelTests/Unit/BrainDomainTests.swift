import Foundation
import XCTest

@testable import BrainPanel

final class BrainDomainTests: XCTestCase {
  private let referenceNow = Date(timeIntervalSince1970: 1_762_819_800)

  private static var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
  }

  private static func fixturesRoot() -> URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Fixtures/BrainState", directoryHint: .isDirectory)
  }

  // MARK: - 1. Esperando Você

  func testWaitingEvaluatorProcessesSanitizedFixturesMaskingFlexogravAndExcludingMyAssistant() throws {
    let root = Self.fixturesRoot()
    let pendingDir = root.appending(path: "brain-pending", directoryHint: .isDirectory)

    let pendingFiles = try FileManager.default.contentsOfDirectory(
      at: pendingDir,
      includingPropertiesForKeys: nil
    ).sorted { $0.lastPathComponent < $1.lastPathComponent }

    let pendingCandidates = try pendingFiles.map { url in
      BrainWaitingEvaluator.PendingCandidate(
        jsonData: try Data(contentsOf: url),
        transcriptModifiedAt: nil
      )
    }

    let openNames = try loadFixtureOpenSessionNames(root: root, livePIDs: [41001, 41002])
    XCTAssertEqual(openNames, ["painel-lead", "my-assistant"])

    let mailRoot = root.appending(path: "brain-mail", directoryHint: .isDirectory)
    let mailboxes: [BrainWaitingEvaluator.MailboxCandidate] = [
      .init(
        recipient: "painel-lead",
        messagePayloads: [
          try Data(contentsOf: mailRoot.appending(path: "painel-lead/new/msg-stuck.json"))
        ]
      ),
      .init(
        recipient: "my-assistant",
        messagePayloads: [
          try Data(contentsOf: mailRoot.appending(path: "my-assistant/new/msg-assistant.json"))
        ]
      ),
      .init(
        recipient: "caixa-dev",
        messagePayloads: [
          try Data(contentsOf: mailRoot.appending(path: "caixa-dev/new/msg-closed.json"))
        ]
      ),
    ]

    let state = BrainWaitingEvaluator.evaluate(
      pendingCandidates: pendingCandidates,
      mailboxes: mailboxes,
      openSessionNames: openNames,
      now: referenceNow
    )

    // Agrupou painel-lead mantendo o maior `at` (1762818600), descartou expired-question (> 7 dias)
    // e suprimiu `text` de flexograv-lead.
    XCTAssertEqual(state.pendingPrompts.map(\.sessionKey), ["painel-lead", "flexograv-lead"])
    XCTAssertEqual(state.pendingPrompts[0].text, "Escolha a estratégia da Etapa 3")
    XCTAssertEqual(
      state.pendingPrompts[0].askedAt,
      Date(timeIntervalSince1970: 1_762_818_600)
    )
    XCTAssertTrue(state.pendingPrompts[0].hasButton)
    XCTAssertEqual(state.pendingPrompts[0].elapsedSummary(now: referenceNow), "há 20m")
    XCTAssertNil(state.pendingPrompts[1].text)

    // painel-lead está aberta há > 1800s -> stuckMail; my-assistant aberta é excluída; caixa-dev fechada -> closedMail
    XCTAssertEqual(state.stuckMail.count, 1)
    XCTAssertEqual(state.stuckMail[0].recipient, "painel-lead")
    XCTAssertEqual(state.stuckMail[0].unreadCount, 1)
    XCTAssertEqual(state.stuckMail[0].senders, ["painel-dev"])
    XCTAssertFalse(String(describing: state).contains("CORPO-DE-COLEGA"))

    XCTAssertEqual(state.closedMail, [ClosedMailbox(recipient: "caixa-dev", unreadCount: 1)])
    XCTAssertEqual(state.waitingOnOwnerCount, 3)
  }

  func testWaitingExactBoundariesForTranscriptMtimeSevenDaysAndStuckMail() {
    let nowEpoch: TimeInterval = 1_762_819_800
    let now = Date(timeIntervalSince1970: nowEpoch)
    let askedEpoch: TimeInterval = 1_762_819_000

    let promptPayload = Data(
      #"{"name":"s1","at":1762819000,"text":"Pergunta"}"#.utf8
    )

    // Fronteira exata mtime == at + 30 -> NÃO descarta; mtime == at + 31 -> descarta
    let keptAtBoundary = BrainWaitingEvaluator.evaluate(
      pendingCandidates: [
        .init(
          jsonData: promptPayload,
          transcriptModifiedAt: Date(timeIntervalSince1970: askedEpoch + 30)
        )
      ],
      mailboxes: [],
      openSessionNames: [],
      now: now
    )
    XCTAssertEqual(keptAtBoundary.pendingPrompts.count, 1)

    let droppedPastBoundary = BrainWaitingEvaluator.evaluate(
      pendingCandidates: [
        .init(
          jsonData: promptPayload,
          transcriptModifiedAt: Date(timeIntervalSince1970: askedEpoch + 31)
        )
      ],
      mailboxes: [],
      openSessionNames: [],
      now: now
    )
    XCTAssertTrue(droppedPastBoundary.pendingPrompts.isEmpty)

    // Fronteira exata 7 dias: now - at == 7 * 86_400 mantém; + 1 descarta
    let exactSevenDaysAt = Int(nowEpoch - 7 * 86_400)
    let keptSevenDays = BrainWaitingEvaluator.evaluate(
      pendingCandidates: [
        .init(
          jsonData: Data(#"{"project":"p1","at":\#(exactSevenDaysAt),"text":"Limite"}"#.utf8),
          transcriptModifiedAt: nil
        )
      ],
      mailboxes: [],
      openSessionNames: [],
      now: now
    )
    XCTAssertEqual(keptSevenDays.pendingPrompts.count, 1)

    let droppedSevenDays = BrainWaitingEvaluator.evaluate(
      pendingCandidates: [
        .init(
          jsonData: Data(#"{"project":"p1","at":\#(exactSevenDaysAt - 1),"text":"Velha"}"#.utf8),
          transcriptModifiedAt: nil
        )
      ],
      mailboxes: [],
      openSessionNames: [],
      now: now
    )
    XCTAssertTrue(droppedSevenDays.pendingPrompts.isEmpty)

    // Fronteira exata stuckMail: now - oldestAt == 1_800 NÃO é stuck; == 1_801 É stuck
    let exactThresholdAt = Int(nowEpoch - 1_800)
    let notStuckYet = BrainWaitingEvaluator.evaluate(
      pendingCandidates: [],
      mailboxes: [
        .init(
          recipient: "loja-dev",
          messagePayloads: [Data(#"{"from":"loja-lead","at":\#(exactThresholdAt)}"#.utf8)]
        )
      ],
      openSessionNames: ["loja-dev"],
      now: now
    )
    XCTAssertTrue(notStuckYet.stuckMail.isEmpty)

    let stuckPastThreshold = BrainWaitingEvaluator.evaluate(
      pendingCandidates: [],
      mailboxes: [
        .init(
          recipient: "loja-dev",
          messagePayloads: [Data(#"{"from":"loja-lead","at":\#(exactThresholdAt - 1)}"#.utf8)]
        )
      ],
      openSessionNames: ["loja-dev"],
      now: now
    )
    XCTAssertEqual(stuckPastThreshold.stuckMail.count, 1)
  }

  // MARK: - 2. Fila da Máquina

  func testCIQueueEvaluatorProcessesSanitizedFixturesAndMasksCorporateFields() throws {
    let ciDir = Self.fixturesRoot().appending(path: "brain-ci", directoryHint: .isDirectory)
    let queueDir = ciDir.appending(path: "queue", directoryHint: .isDirectory)
    let ticketFiles = try FileManager.default.contentsOfDirectory(
      at: queueDir,
      includingPropertiesForKeys: nil
    ).sorted { $0.lastPathComponent < $1.lastPathComponent }

    let ticketPayloads = try ticketFiles.map { url in
      (id: url.deletingPathExtension().lastPathComponent, data: try Data(contentsOf: url))
    }

    let runsText = try String(contentsOf: ciDir.appending(path: "runs.jsonl"), encoding: .utf8)
    let alertsText = try String(contentsOf: ciDir.appending(path: "alerts.jsonl"), encoding: .utf8)

    let state = BrainCIQueueEvaluator.evaluate(
      inputs: .init(
        versionData: try Data(contentsOf: ciDir.appending(path: "version.json")),
        pausedData: try Data(contentsOf: ciDir.appending(path: "paused")),
        modeData: try Data(contentsOf: ciDir.appending(path: "mode")),
        vmNowData: try Data(contentsOf: ciDir.appending(path: "vm-now.json")),
        ticketPayloads: ticketPayloads,
        runLines: runsText.split(separator: "\n"),
        alertLines: alertsText.split(separator: "\n")
      ),
      now: referenceNow,
      calendar: Self.utcCalendar,
      isProcessAlive: { [41003, 41004, 41005, 41006].contains($0) }
    )

    XCTAssertEqual(state.queueVersion, 4)
    XCTAssertEqual(state.pauseState?.reason, "manutenção programada")
    XCTAssertTrue(state.isSerial)
    XCTAssertEqual(state.serialReason, "memória curta")
    XCTAssertEqual(state.vmAvailableMB, 8_192.0)

    XCTAssertEqual(state.runningTickets.count, 2)
    XCTAssertEqual(state.runningTickets[0].project, "projeto-painel")
    XCTAssertEqual(state.runningTickets[0].command, "make ci")
    XCTAssertEqual(state.runningTickets[0].commit, "82ac8dd")
    XCTAssertEqual(state.runningTickets[1].project, "flexograv")
    XCTAssertNil(state.runningTickets[1].command)
    XCTAssertNil(state.runningTickets[1].commit)

    XCTAssertEqual(state.waitingTickets.count, 1)
    XCTAssertEqual(state.waitingTickets[0].project, "projeto-caixa")
    XCTAssertEqual(state.waitingTickets[0].primaryWaitReason, "espera memória")
    XCTAssertTrue(state.waitingTickets[0].isSolo)

    // Hoje em UTC (>= 1762819200): 3 corridas v4 (1 verde painel, 1 interrompida painel com exit 0, 1 verde flexograv)
    XCTAssertEqual(state.todaySummary.totalCount, 3)
    XCTAssertEqual(state.todaySummary.greenCount, 2)
    XCTAssertEqual(state.todaySummary.nonGreenCount, 1)

    // 4 corridas v4 totais (3 de hoje + 1 de ontem), mais recente primeiro
    XCTAssertEqual(state.recentRuns.count, 4)
    XCTAssertEqual(state.recentRuns[0].project, "flexograv")
    XCTAssertNil(state.recentRuns[0].commit)
    XCTAssertFalse(state.recentRuns[1].isGreen)
    XCTAssertTrue(state.recentRuns[2].isGreen)
    XCTAssertEqual(state.recentRuns[2].commit, "82ac8ddb")

    // 2 alertas nas últimas 24h (o de flexograv tem alarm mascarado)
    XCTAssertEqual(state.recentAlerts.count, 2)
    XCTAssertEqual(state.recentAlerts[0].project, "flexograv")
    XCTAssertEqual(state.recentAlerts[0].alarm, "alerta da fila")
    XCTAssertEqual(state.recentAlerts[1].project, "projeto-painel")
    XCTAssertEqual(state.recentAlerts[1].alarm, "espera memória há 10 min")

    let dumped = String(describing: state)
    XCTAssertFalse(dumped.contains("CORPORATIVO"))
  }

  func testCIQueueExactBoundariesForSerialUntilVMFreshnessAndDeadPausePID() {
    let nowEpoch: TimeInterval = 1_762_819_800
    let now = Date(timeIntervalSince1970: nowEpoch)

    // Serial ativo exatamente em now == until; expira em now == until + 1
    let serialAtBoundary = BrainCIQueueEvaluator.evaluate(
      inputs: .init(
        versionData: nil,
        pausedData: Data(#"{"reason":"pausa morta","pid":99999,"at":1762819000}"#.utf8),
        modeData: Data(#"{"mode":"serial","reason":"carga","until":1762819800}"#.utf8),
        vmNowData: Data(#"{"at":1762819681,"available":4096.0}"#.utf8),
        ticketPayloads: [],
        runLines: [],
        alertLines: []
      ),
      now: now,
      calendar: Self.utcCalendar,
      isProcessAlive: { _ in false }
    )
    XCTAssertNil(serialAtBoundary.pauseState)
    XCTAssertTrue(serialAtBoundary.isSerial)
    XCTAssertEqual(serialAtBoundary.vmAvailableMB, 4_096.0)

    let expiredSerialAndVM = BrainCIQueueEvaluator.evaluate(
      inputs: .init(
        versionData: nil,
        pausedData: Data(#"{"reason":"pausa manual sem pid","at":1762819000}"#.utf8),
        modeData: Data(#"{"mode":"serial","reason":"carga","until":1762819799}"#.utf8),
        vmNowData: Data(#"{"at":1762819680,"available":4096.0}"#.utf8),
        ticketPayloads: [],
        runLines: [],
        alertLines: []
      ),
      now: now,
      calendar: Self.utcCalendar,
      isProcessAlive: { _ in false }
    )
    XCTAssertEqual(expiredSerialAndVM.pauseState?.reason, "pausa manual sem pid")
    XCTAssertFalse(expiredSerialAndVM.isSerial)
    XCTAssertNil(expiredSerialAndVM.serialReason)
    XCTAssertNil(expiredSerialAndVM.vmAvailableMB)
  }

  // MARK: - 3. Saúde & Backup

  func testHealthAndBackupEvaluatorProcessesFixturesAndExactBoundaries() throws {
    let root = Self.fixturesRoot()
    let logsDir = root.appending(path: "logs", directoryHint: .isDirectory)
    let doctorMtime = Date(timeIntervalSince1970: 1_762_819_500)

    let state = BrainHealthAndBackupEvaluator.evaluate(
      inputs: .init(
        doctorStateData: try Data(contentsOf: logsDir.appending(path: "brain-doctor.state")),
        doctorModifiedAt: doctorMtime,
        testStateData: try Data(contentsOf: logsDir.appending(path: "brain-test.state")),
        syncStateData: try Data(contentsOf: logsDir.appending(path: "brain-sync.state")),
        backupStateData: try Data(contentsOf: logsDir.appending(path: "brain-backup.state")),
        liveBackupProgressData: try Data(
          contentsOf: root.appending(path: "pages/backup-drive.json")
        )
      ),
      now: referenceNow
    )

    XCTAssertEqual(state.doctorCheckedAt, doctorMtime)
    XCTAssertEqual(state.doctorFailures.count, 1)
    XCTAssertEqual(state.doctorFailures[0].message, "backup: snapshot atrasado")
    XCTAssertEqual(state.doctorWarnings.count, 1)
    XCTAssertEqual(state.doctorWarnings[0].message, "orçamento: índice perto do teto")

    XCTAssertEqual(state.testSuite?.isPassing, true)
    XCTAssertEqual(state.testSuite?.ranCount, 414)
    XCTAssertEqual(state.syncStatus?.isPassing, true)
    XCTAssertEqual(state.syncStatus?.commitSHA, "8267b37")

    XCTAssertEqual(state.backupStatus?.isPassing, true)
    XCTAssertEqual(state.backupStatus?.isOverdue, false)
    XCTAssertEqual(state.backupStatus?.needsAttention, false)
    XCTAssertEqual(state.backupStatus?.snapshotID, "a1b2c3d4")

    // Progresso ao vivo: now (1762819800) - at (1762819770) == 30 <= 60 -> não travado
    XCTAssertEqual(state.liveBackupProgress?.phase, "arquivos")
    XCTAssertEqual(state.liveBackupProgress?.isStalled, false)
    XCTAssertTrue(state.isActivelyBackingUp)

    // Fronteiras exatas de atraso de backup (2 * 86_400) e travamento de progresso (60 s) + máscara flexograv
    let exactTwoDaysAt = Int(referenceNow.timeIntervalSince1970 - 2 * 86_400)
    let exactSixtyAt = Int(referenceNow.timeIntervalSince1970 - 60)

    let atBoundaries = BrainHealthAndBackupEvaluator.evaluate(
      inputs: .init(
        doctorStateData: nil,
        doctorModifiedAt: nil,
        testStateData: nil,
        syncStateData: nil,
        backupStateData: Data(#"{"result":"ok","at":\#(exactTwoDaysAt)}"#.utf8),
        liveBackupProgressData: Data(
          #"{"fase":"arquivos","at":\#(exactSixtyAt),"pct":0.5,"pasta":"Documents/flexograv/sub"}"#
            .utf8
        )
      ),
      now: referenceNow
    )
    XCTAssertEqual(atBoundaries.backupStatus?.isOverdue, false)
    XCTAssertEqual(atBoundaries.backupStatus?.needsAttention, false)
    XCTAssertEqual(atBoundaries.liveBackupProgress?.isStalled, false)
    XCTAssertEqual(atBoundaries.liveBackupProgress?.currentFolder, "flexograv")

    let pastBoundaries = BrainHealthAndBackupEvaluator.evaluate(
      inputs: .init(
        doctorStateData: nil,
        doctorModifiedAt: nil,
        testStateData: nil,
        syncStateData: nil,
        backupStateData: Data(#"{"result":"ok","at":\#(exactTwoDaysAt - 1)}"#.utf8),
        liveBackupProgressData: Data(
          #"{"fase":"arquivos","at":\#(exactSixtyAt - 1),"pct":0.5}"#.utf8
        )
      ),
      now: referenceNow
    )
    XCTAssertEqual(pastBoundaries.backupStatus?.isOverdue, true)
    XCTAssertEqual(pastBoundaries.backupStatus?.needsAttention, true)
    XCTAssertEqual(pastBoundaries.liveBackupProgress?.isStalled, true)
    XCTAssertFalse(pastBoundaries.isActivelyBackingUp)

    // Fase "fim" significa backup encerrado (não em execução)
    let finishedProgress = BrainHealthAndBackupEvaluator.evaluate(
      inputs: .init(
        doctorStateData: nil,
        doctorModifiedAt: nil,
        testStateData: nil,
        syncStateData: nil,
        backupStateData: nil,
        liveBackupProgressData: Data(#"{"fase":"fim","at":\#(exactSixtyAt - 500)}"#.utf8)
      ),
      now: referenceNow
    )
    XCTAssertNil(finishedProgress.liveBackupProgress)
  }

  // MARK: - 4. Jobs Agendados & Snapshot Agregado

  func testScheduledJobsEvaluatorAndSnapshotAggregates() throws {
    let root = Self.fixturesRoot()
    let agentsDir = root.appending(path: "launch-agents", directoryHint: .isDirectory)
    let logsDir = root.appending(path: "logs", directoryHint: .isDirectory)
    let weeklyDir = root.appending(path: "brain-weekly", directoryHint: .isDirectory)

    let plistURLs = try FileManager.default.contentsOfDirectory(
      at: agentsDir,
      includingPropertiesForKeys: nil
    ).sorted { $0.lastPathComponent < $1.lastPathComponent }

    let plists = try plistURLs.map { url in
      BrainScheduledJobsEvaluator.PlistCandidate(
        fallbackLabel: url.deletingPathExtension().lastPathComponent,
        plistData: try Data(contentsOf: url)
      )
    }

    let launchctlOutput = """
      PID\tStatus\tLabel
      501\t0\tcom.lucas.awake
      -\t0\tcom.lucas.brain-sync
      -\t0\tcom.lucas.brain-backup
      -\t0\tcom.lucas.brain-weekly
      """

    let scheduled = BrainScheduledJobsEvaluator.evaluate(
      inputs: .init(
        plists: plists,
        launchctlListOutput: launchctlOutput,
        syncStateData: try Data(contentsOf: logsDir.appending(path: "brain-sync.state")),
        backupStateData: try Data(contentsOf: logsDir.appending(path: "brain-backup.state")),
        weeklyStateData: try Data(contentsOf: weeklyDir.appending(path: "state.json")),
        faxinaData: try Data(contentsOf: weeklyDir.appending(path: "faxina.json")),
        rehearseStateData: try Data(contentsOf: logsDir.appending(path: "brain-rehearse.state")),
        isActivelyBackingUp: true
      ),
      now: referenceNow,
      calendar: Self.utcCalendar
    )

    XCTAssertEqual(scheduled.jobs.count, 4)

    let byLabel = Dictionary(uniqueKeysWithValues: scheduled.jobs.map { ($0.label, $0) })
    XCTAssertEqual(byLabel["com.lucas.awake"]?.title, "Awake: Mac acordado com trabalho")
    XCTAssertEqual(byLabel["com.lucas.awake"]?.scheduleSummary, "sempre ligado")
    XCTAssertEqual(byLabel["com.lucas.awake"]?.status, .running)

    // com.lucas.brain-backup está com pid "-" no launchctl, mas isActivelyBackingUp == true -> .running
    XCTAssertEqual(byLabel["com.lucas.brain-backup"]?.title, "Backup criptografado no Drive")
    XCTAssertEqual(byLabel["com.lucas.brain-backup"]?.status, .running)
    XCTAssertNotNil(byLabel["com.lucas.brain-backup"]?.nextRunAt)

    XCTAssertEqual(byLabel["com.lucas.brain-sync"]?.scheduleSummary, "a cada 1 h")
    XCTAssertEqual(byLabel["com.lucas.brain-sync"]?.status, .succeeded)

    XCTAssertEqual(byLabel["com.lucas.brain-weekly"]?.scheduleSummary, "domingo de madrugada")
    XCTAssertEqual(byLabel["com.lucas.brain-weekly"]?.status, .succeeded)
    XCTAssertNotNil(byLabel["com.lucas.brain-weekly"]?.nextRunAt)

    XCTAssertEqual(scheduled.weeklyCleanupAt, Date(timeIntervalSince1970: 1_762_700_100))
    XCTAssertEqual(scheduled.restoreRehearsal?.isPassing, true)
    XCTAssertEqual(scheduled.restoreRehearsal?.restoredCount, 40)

    // Snapshot saudável vs crítico
    let healthySnapshot = BrainSnapshot(
      waiting: .loaded(.empty),
      ciQueue: .loaded(.empty),
      healthAndBackup: .loaded(.empty),
      scheduledJobs: .loaded(scheduled),
      capturedAt: referenceNow
    )
    XCTAssertEqual(healthySnapshot.waitingOnOwnerCount, 0)
    XCTAssertFalse(healthySnapshot.hasCriticalFailure)
    XCTAssertFalse(healthySnapshot.needsAttentionBanner)

    let criticalHealth = HealthAndBackupState(
      doctorFailures: [DoctorFinding(key: "FAIL 14", severity: .fail, message: "backup atrasado")],
      doctorWarnings: [],
      doctorCheckedAt: referenceNow,
      testSuite: nil,
      syncStatus: nil,
      backupStatus: nil,
      liveBackupProgress: nil
    )
    let criticalSnapshot = BrainSnapshot(
      waiting: .loaded(.empty),
      ciQueue: .loaded(.empty),
      healthAndBackup: .loaded(criticalHealth),
      scheduledJobs: .loaded(scheduled),
      capturedAt: referenceNow
    )
    XCTAssertTrue(criticalSnapshot.hasCriticalFailure)
    XCTAssertTrue(criticalSnapshot.needsAttentionBanner)

    let previewSnapshot = BrainSnapshot.makePreviewData(now: referenceNow)
    XCTAssertGreaterThan(previewSnapshot.waitingOnOwnerCount, 0)
    XCTAssertTrue(previewSnapshot.needsAttentionBanner)
    XCTAssertTrue(previewSnapshot.degradedSections.isEmpty)
    XCTAssertEqual(RelativeTimeFormatter.compactDuration(seconds: 42), "42s")
    XCTAssertEqual(RelativeTimeFormatter.compactDuration(seconds: 3_900), "1h 05m")
  }

  private func loadFixtureOpenSessionNames(root: URL, livePIDs: Set<Int32>) throws -> Set<String> {
    var names: Set<String> = []
    for folder in ["brain-sessions", "claude-sessions"] {
      let dir = root.appending(path: folder, directoryHint: .isDirectory)
      let files = try FileManager.default.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: nil
      )
      for fileURL in files where fileURL.pathExtension == "json" {
        let data = try Data(contentsOf: fileURL)
        if let name = BrainWaitingEvaluator.parseOpenSessionName(
          from: data,
          filename: fileURL.lastPathComponent,
          isProcessAlive: { livePIDs.contains($0) }
        ) {
          names.insert(name)
        }
      }
    }
    return names
  }
}
