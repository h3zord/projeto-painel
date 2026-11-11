import Foundation
import UserNotifications
import XCTest

@testable import BrainPanel

final class NotificationPolicyAndAdapterTests: XCTestCase {
  func testCriticalQuotaBoundaryFiresBelowFifteenPercentAndIgnoresFifteenPercentPlaceholdersAndUnavailable() {
    let clock = TestClock()
    var engine = NotificationPolicyEngine()

    // 1. Placeholders iniciais (.loading) nunca disparam, mesmo se tivessem 0% restante sem coleta
    let customZeroPlaceholder = ProviderUsage(
      id: "claude",
      name: "Claude",
      plan: "Max",
      icon: .asset("ClaudeIcon"),
      tint: .orange,
      sessionState: .loading,
      limits: [
        UsageLimit(
          id: "claude-session",
          name: "Sessão de 5 horas",
          detail: nil,
          window: .session,
          usedPercentage: 100,
          resetsAt: nil
        )
      ]
    )
    let unavailableProvider = ProviderUsage(
      id: "gemini",
      name: "Gemini",
      plan: "Pro",
      icon: .symbol("sparkle"),
      tint: .blue,
      sessionState: .unavailable("CLI indisponível"),
      limits: [
        UsageLimit(
          id: "gemini-session",
          name: "Gemini 2.5 Pro",
          detail: "Sessão de 5 horas",
          window: .session,
          usedPercentage: 100,
          resetsAt: nil
        )
      ]
    )
    let initialInput = NotificationSnapshotBridge.makeEvaluationInput(
      providers: ProviderUsage.placeholders + [customZeroPlaceholder, unavailableProvider],
      brainSnapshot: .empty,
      hasBrainCollector: false,
      isBrainSnapshotStale: false
    )
    XCTAssertTrue(engine.evaluate(input: initialInput, now: clock.now()).isEmpty)

    // 2. Fronteira exata: 15% restante (85% usado) NÃO dispara; 14% restante (86% usado) dispara
    let activeProviders = [
      ProviderUsage(
        id: "claude",
        name: "Claude",
        plan: "Max",
        icon: .asset("ClaudeIcon"),
        tint: .orange,
        sessionState: .active,
        limits: [
          UsageLimit(
            id: "claude-session",
            name: "Sessão de 5 horas",
            detail: nil,
            window: .session,
            usedPercentage: 85,
            resetsAt: nil
          ),
          UsageLimit(
            id: "claude-weekly",
            name: "Todos os modelos",
            detail: "Semanal",
            window: .weekly,
            usedPercentage: 86,
            resetsAt: nil
          ),
        ],
        lastUpdatedAt: clock.now()
      ),
      ProviderUsage(
        id: "gemini",
        name: "Gemini",
        plan: "Google AI Pro",
        icon: .symbol("sparkle"),
        tint: .blue,
        sessionState: .active,
        limits: [
          UsageLimit(
            id: "gemini-pro-session",
            name: "Gemini 2.5 Pro",
            detail: "Sessão de 5 horas",
            window: .session,
            usedPercentage: 92,
            resetsAt: nil
          ),
          UsageLimit(
            id: "gemini-pro-weekly",
            name: "Gemini 2.5 Pro",
            detail: "Semanal",
            window: .weekly,
            usedPercentage: 95,
            resetsAt: nil
          ),
        ],
        lastUpdatedAt: clock.now()
      ),
    ]

    let quotaInput = NotificationSnapshotBridge.makeEvaluationInput(
      providers: activeProviders,
      brainSnapshot: .empty,
      hasBrainCollector: false,
      isBrainSnapshotStale: false
    )
    let alerts = engine.evaluate(input: quotaInput, now: clock.now())
    XCTAssertEqual(alerts.count, 3)
    XCTAssertEqual(
      alerts.map(\.incidentKey),
      [
        "quota:claude:claude-weekly",
        "quota:gemini:gemini-pro-session",
        "quota:gemini:gemini-pro-weekly",
      ]
    )
    XCTAssertEqual(Set(alerts.map(\.identifier)).count, 3)
    XCTAssertTrue(alerts.allSatisfy { $0.category == .criticalQuota })
    XCTAssertTrue(alerts[0].title.contains("Claude"))
    XCTAssertTrue(alerts[0].body.contains("14%"))
    XCTAssertTrue(alerts[1].body.contains("8%"))
    XCTAssertTrue(alerts[2].body.contains("5%"))
  }

  func testWaitingTriggerCoversPendingPromptsAndStuckMailIgnoringClosedMailAndMasksCorporateScope() {
    let clock = TestClock()
    var engine = NotificationPolicyEngine()

    let snapshot = BrainSnapshot(
      waiting: .loaded(
        WaitingState(
          pendingPrompts: [
            PendingPrompt(
              sessionKey: "painel-lead",
              project: "projeto-painel",
              askedAt: clock.now().addingTimeInterval(-120),
              text: "Aprovar PR #16?",
              isExplicit: true,
              hasButton: true
            ),
            PendingPrompt(
              sessionKey: "flexograv-lead",
              project: nil,
              askedAt: clock.now().addingTimeInterval(-90),
              text: nil,
              isExplicit: true,
              hasButton: false
            ),
            PendingPrompt(
              sessionKey: "erp-interno",
              project: "flexograv-erp",
              askedAt: clock.now().addingTimeInterval(-60),
              text: "Segredo corporativo",
              isExplicit: true,
              hasButton: true
            ),
          ],
          stuckMail: [
            StuckMailbox(
              recipient: "caixa-lead",
              unreadCount: 2,
              oldestMessageAt: clock.now().addingTimeInterval(-2_400),
              senders: ["caixa-dev"]
            ),
            StuckMailbox(
              recipient: "erp-mail",
              unreadCount: 1,
              oldestMessageAt: clock.now().addingTimeInterval(-2_400),
              senders: ["flexograv-bot"]
            ),
          ],
          closedMail: [
            ClosedMailbox(recipient: "sitio-dev", unreadCount: 4)
          ]
        )
      ),
      ciQueue: .loaded(.empty),
      healthAndBackup: .loaded(.empty),
      scheduledJobs: .loaded(.empty),
      capturedAt: clock.now()
    )

    let input = NotificationSnapshotBridge.makeEvaluationInput(
      providers: [],
      brainSnapshot: snapshot,
      hasBrainCollector: true,
      isBrainSnapshotStale: false
    )
    let alerts = engine.evaluate(input: input, now: clock.now())

    XCTAssertEqual(
      alerts.map(\.incidentKey),
      [
        "waiting:prompt:painel-lead",
        "waiting:prompt:corporate",
        "waiting:mail:caixa-lead",
        "waiting:mail:corporate",
      ]
    )
    for alert in alerts {
      XCTAssertEqual(alert.category, .waitingOnOwner)
      XCTAssertFalse(alert.identifier.localizedStandardContains("flexograv"))
      XCTAssertFalse(alert.incidentKey.localizedStandardContains("flexograv"))
      XCTAssertFalse(alert.title.localizedStandardContains("flexograv"))
      XCTAssertFalse(alert.body.localizedStandardContains("flexograv"))
      XCTAssertFalse(alert.identifier.contains("erp-interno"))
      XCTAssertFalse(alert.body.contains("erp-interno"))
      XCTAssertFalse(alert.identifier.contains("erp-mail"))
      XCTAssertFalse(alert.body.contains("erp-mail"))
      XCTAssertFalse(alert.body.contains("sitio-dev"))
      XCTAssertFalse(alert.body.contains("Aprovar PR #16?"))
      XCTAssertFalse(alert.body.contains("Segredo corporativo"))
    }
    XCTAssertTrue(alerts[0].body.contains("painel-lead"))
    XCTAssertTrue(alerts[2].body.contains("caixa-lead"))
  }

  func testDoctorFailureFiresOnlyOnFailFindingsNotWarningsOrFailedSection() {
    let clock = TestClock()
    var engine = NotificationPolicyEngine()

    let warnOnlySnapshot = BrainSnapshot(
      waiting: .loaded(.empty),
      ciQueue: .loaded(.empty),
      healthAndBackup: .loaded(
        HealthAndBackupState(
          doctorFailures: [],
          doctorWarnings: [
            DoctorFinding(key: "WARN 23", severity: .warn, message: "índice próximo do teto")
          ],
          doctorCheckedAt: clock.now(),
          testSuite: nil,
          syncStatus: nil,
          backupStatus: nil,
          liveBackupProgress: nil
        )
      ),
      scheduledJobs: .loaded(.empty),
      capturedAt: clock.now()
    )
    let warnInput = NotificationSnapshotBridge.makeEvaluationInput(
      providers: [],
      brainSnapshot: warnOnlySnapshot,
      hasBrainCollector: true,
      isBrainSnapshotStale: false
    )
    XCTAssertTrue(engine.evaluate(input: warnInput, now: clock.now()).isEmpty)

    let failedSectionSnapshot = BrainSnapshot(
      waiting: .loaded(.empty),
      ciQueue: .loaded(.empty),
      healthAndBackup: .failed(AppError.brainStateReadFailed(section: .healthAndBackup)),
      scheduledJobs: .loaded(.empty),
      capturedAt: clock.now()
    )
    let failedSectionInput = NotificationSnapshotBridge.makeEvaluationInput(
      providers: [],
      brainSnapshot: failedSectionSnapshot,
      hasBrainCollector: true,
      isBrainSnapshotStale: false
    )
    XCTAssertTrue(engine.evaluate(input: failedSectionInput, now: clock.now()).isEmpty)

    let doctorFailSnapshot = BrainSnapshot(
      waiting: .loaded(.empty),
      ciQueue: .loaded(.empty),
      healthAndBackup: .loaded(
        HealthAndBackupState(
          doctorFailures: [
            DoctorFinding(key: "FAIL 14", severity: .fail, message: "/Users/privado/erro")
          ],
          doctorWarnings: [],
          doctorCheckedAt: clock.now(),
          testSuite: nil,
          syncStatus: nil,
          backupStatus: nil,
          liveBackupProgress: nil
        )
      ),
      scheduledJobs: .loaded(.empty),
      capturedAt: clock.now()
    )
    let failInput = NotificationSnapshotBridge.makeEvaluationInput(
      providers: [],
      brainSnapshot: doctorFailSnapshot,
      hasBrainCollector: true,
      isBrainSnapshotStale: false
    )
    let alerts = engine.evaluate(input: failInput, now: clock.now())
    XCTAssertEqual(alerts.count, 1)
    XCTAssertEqual(alerts.first?.category, .doctorFailure)
    XCTAssertEqual(alerts.first?.incidentKey, "health:doctor_failure")
    XCTAssertFalse(alerts[0].body.contains("/Users/privado"))
  }

  func testBackupFailureFiresIndependentlyWhenBackupNeedsAttentionOrLiveProgressIsStalled() {
    let clock = TestClock()

    // Caso 1: backup saudável + progresso ao vivo em andamento -> sem alerta
    var healthyEngine = NotificationPolicyEngine()
    let healthyBackup = BackupStatus(
      isPassing: true,
      isOverdue: false,
      reason: nil,
      completedAt: clock.now().addingTimeInterval(-3_600),
      snapshotID: "snap1",
      addedBytes: 1_024,
      filesCount: 10
    )
    let activeProgress = LiveBackupProgress(
      phase: "upload",
      startedAt: clock.now().addingTimeInterval(-60),
      heartbeatAt: clock.now().addingTimeInterval(-5),
      fractionCompleted: 0.5,
      processedBytes: 500,
      totalBytes: 1_000,
      estimatedRemainingSeconds: 30,
      errorCount: 0,
      currentFolder: "Brain",
      isStalled: false
    )
    let healthySnapshot = BrainSnapshot(
      waiting: .loaded(.empty),
      ciQueue: .loaded(.empty),
      healthAndBackup: .loaded(
        HealthAndBackupState(
          doctorFailures: [],
          doctorWarnings: [],
          doctorCheckedAt: clock.now(),
          testSuite: nil,
          syncStatus: nil,
          backupStatus: healthyBackup,
          liveBackupProgress: activeProgress
        )
      ),
      scheduledJobs: .loaded(.empty),
      capturedAt: clock.now()
    )
    let healthyInput = NotificationSnapshotBridge.makeEvaluationInput(
      providers: [],
      brainSnapshot: healthySnapshot,
      hasBrainCollector: true,
      isBrainSnapshotStale: false
    )
    XCTAssertTrue(healthyEngine.evaluate(input: healthyInput, now: clock.now()).isEmpty)

    // Caso 2: apenas backupStatus.needsAttention == true (sem liveBackupProgress) -> alerta!
    var overdueEngine = NotificationPolicyEngine()
    let overdueSnapshot = BrainSnapshot(
      waiting: .loaded(.empty),
      ciQueue: .loaded(.empty),
      healthAndBackup: .loaded(
        HealthAndBackupState(
          doctorFailures: [],
          doctorWarnings: [],
          doctorCheckedAt: clock.now(),
          testSuite: nil,
          syncStatus: nil,
          backupStatus: BackupStatus(
            isPassing: true,
            isOverdue: true,
            reason: "atrasado",
            completedAt: clock.now().addingTimeInterval(-3 * 86_400),
            snapshotID: "snap0",
            addedBytes: nil,
            filesCount: nil
          ),
          liveBackupProgress: nil
        )
      ),
      scheduledJobs: .loaded(.empty),
      capturedAt: clock.now()
    )
    let overdueInput = NotificationSnapshotBridge.makeEvaluationInput(
      providers: [],
      brainSnapshot: overdueSnapshot,
      hasBrainCollector: true,
      isBrainSnapshotStale: false
    )
    let overdueAlerts = overdueEngine.evaluate(input: overdueInput, now: clock.now())
    XCTAssertEqual(overdueAlerts.count, 1)
    XCTAssertEqual(overdueAlerts.first?.category, .backupFailure)

    // Caso 3: backupStatus saudável, mas liveBackupProgress.isStalled == true -> alerta!
    var stalledEngine = NotificationPolicyEngine()
    let stalledSnapshot = BrainSnapshot(
      waiting: .loaded(.empty),
      ciQueue: .loaded(.empty),
      healthAndBackup: .loaded(
        HealthAndBackupState(
          doctorFailures: [],
          doctorWarnings: [],
          doctorCheckedAt: clock.now(),
          testSuite: nil,
          syncStatus: nil,
          backupStatus: healthyBackup,
          liveBackupProgress: LiveBackupProgress(
            phase: "upload",
            startedAt: clock.now().addingTimeInterval(-600),
            heartbeatAt: clock.now().addingTimeInterval(-180),
            fractionCompleted: 0.4,
            processedBytes: 400,
            totalBytes: 1_000,
            estimatedRemainingSeconds: nil,
            errorCount: 0,
            currentFolder: "/Users/privado/Documents",
            isStalled: true
          )
        )
      ),
      scheduledJobs: .loaded(.empty),
      capturedAt: clock.now()
    )
    let stalledInput = NotificationSnapshotBridge.makeEvaluationInput(
      providers: [],
      brainSnapshot: stalledSnapshot,
      hasBrainCollector: true,
      isBrainSnapshotStale: false
    )
    let stalledAlerts = stalledEngine.evaluate(input: stalledInput, now: clock.now())
    XCTAssertEqual(stalledAlerts.count, 1)
    XCTAssertEqual(stalledAlerts.first?.category, .backupFailure)
    XCTAssertFalse(stalledAlerts[0].body.contains("/Users/privado"))
  }

  func testCooldownSuppressesUntilExactBoundaryRearmsOnHealthyResolutionAndPreservesDuringDegradedReads() {
    let clock = TestClock()
    var engine = NotificationPolicyEngine(cooldownSeconds: 3_600)

    let criticalClaude = ProviderUsage(
      id: "claude",
      name: "Claude",
      plan: "Max",
      icon: .asset("ClaudeIcon"),
      tint: .orange,
      sessionState: .active,
      limits: [
        UsageLimit(
          id: "claude-session",
          name: "Sessão de 5 horas",
          detail: nil,
          window: .session,
          usedPercentage: 90,
          resetsAt: nil
        )
      ],
      lastUpdatedAt: clock.now()
    )
    let doctorFailSnapshot = BrainSnapshot(
      waiting: .loaded(.empty),
      ciQueue: .loaded(.empty),
      healthAndBackup: .loaded(
        HealthAndBackupState(
          doctorFailures: [
            DoctorFinding(key: "FAIL 1", severity: .fail, message: "falha")
          ],
          doctorWarnings: [],
          doctorCheckedAt: clock.now(),
          testSuite: nil,
          syncStatus: nil,
          backupStatus: nil,
          liveBackupProgress: nil
        )
      ),
      scheduledJobs: .loaded(.empty),
      capturedAt: clock.now()
    )

    let activeInput = NotificationSnapshotBridge.makeEvaluationInput(
      providers: [criticalClaude],
      brainSnapshot: doctorFailSnapshot,
      hasBrainCollector: true,
      isBrainSnapshotStale: false
    )

    // t = 0: dispara ambos os incidentes
    let firstAlerts = engine.evaluate(input: activeInput, now: clock.now())
    XCTAssertEqual(firstAlerts.count, 2)

    // t = 3599s: 1 segundo antes da janela expirar -> suprime ambos
    clock.advance(by: 3_599)
    XCTAssertTrue(engine.evaluate(input: activeInput, now: clock.now()).isEmpty)

    // t = 3600s: fronteira exata da janela de 1h -> repete ambos os alertas
    clock.advance(by: 1)
    let repeatedAlerts = engine.evaluate(input: activeInput, now: clock.now())
    XCTAssertEqual(repeatedAlerts.count, 2)

    // t = 3700s: leitura falha (.stale para cota e .failed para seção Brain) -> não re-dispara nem limpa cooldown
    clock.advance(by: 100)
    let staleClaude = criticalClaude.stale(reason: "timeout", fallbackDate: clock.now())
    let failedBrain = BrainSnapshot(
      waiting: .loaded(.empty),
      ciQueue: .loaded(.empty),
      healthAndBackup: .failed(AppError.brainStateReadFailed(section: .healthAndBackup)),
      scheduledJobs: .loaded(.empty),
      capturedAt: clock.now()
    )
    let degradedInput = NotificationSnapshotBridge.makeEvaluationInput(
      providers: [staleClaude],
      brainSnapshot: failedBrain,
      hasBrainCollector: true,
      isBrainSnapshotStale: false
    )
    XCTAssertTrue(engine.evaluate(input: degradedInput, now: clock.now()).isEmpty)

    // t = 3800s: fontes voltam ao ar ainda em estado crítico (200s desde o último disparo em t = 3600s):
    // como o cooldown não foi limpo pela falha transitória, continua suprimido!
    clock.advance(by: 100)
    XCTAssertTrue(engine.evaluate(input: activeInput, now: clock.now()).isEmpty)

    // t = 7500s: mais de 1h após t = 3600s, porém ainda em .stale / isBrainSnapshotStale:
    // não re-dispara sobre dados congelados de leitura falha!
    clock.advance(by: 3_700)
    let staleAllInput = NotificationSnapshotBridge.makeEvaluationInput(
      providers: [staleClaude],
      brainSnapshot: doctorFailSnapshot,
      hasBrainCollector: true,
      isBrainSnapshotStale: true
    )
    XCTAssertTrue(engine.evaluate(input: staleAllInput, now: clock.now()).isEmpty)

    // t = 7510s: leitura fresca saudável (cota renovou para 80% restante e doctor sem FAIL) -> limpa estado e rearma
    clock.advance(by: 10)
    let recoveredClaude = ProviderUsage(
      id: "claude",
      name: "Claude",
      plan: "Max",
      icon: .asset("ClaudeIcon"),
      tint: .orange,
      sessionState: .active,
      limits: [
        UsageLimit(
          id: "claude-session",
          name: "Sessão de 5 horas",
          detail: nil,
          window: .session,
          usedPercentage: 20,
          resetsAt: nil
        )
      ],
      lastUpdatedAt: clock.now()
    )
    let recoveredInput = NotificationSnapshotBridge.makeEvaluationInput(
      providers: [recoveredClaude],
      brainSnapshot: BrainSnapshot(
        waiting: .loaded(.empty),
        ciQueue: .loaded(.empty),
        healthAndBackup: .loaded(.empty),
        scheduledJobs: .loaded(.empty),
        capturedAt: clock.now()
      ),
      hasBrainCollector: true,
      isBrainSnapshotStale: false
    )
    XCTAssertTrue(engine.evaluate(input: recoveredInput, now: clock.now()).isEmpty)
    XCTAssertTrue(engine.lastAlertedAtByIncident.isEmpty)

    // t = 7520s (apenas 10s depois!): problema volta -> rearme imediato dispara sem aguardar 1h!
    clock.advance(by: 10)
    let rearmedAlerts = engine.evaluate(input: activeInput, now: clock.now())
    XCTAssertEqual(rearmedAlerts.count, 2)
  }

  func testAdapterBuildsSilentNotificationContentHandlesDeniedAuthorizationAndIsolatesEnqueueFailures()
    async
  {
    let payload = SystemNotificationPayload(
      identifier: "com.h3zord.BrainPanel.quota.claude.claude-session",
      title: "Cota crítica — Claude",
      body: "Sessão de 5 horas com 12% restante.",
      threadIdentifier: "com.h3zord.BrainPanel.critical_quota",
      hasSound: false
    )
    let content = SystemUserNotificationBackend.makeNotificationContent(from: payload)
    XCTAssertEqual(content.title, payload.title)
    XCTAssertEqual(content.body, payload.body)
    XCTAssertEqual(content.threadIdentifier, payload.threadIdentifier)
    XCTAssertNil(content.sound)
    XCTAssertNil(content.badge)

    let clock = TestClock()
    let logSink = InMemoryLogSink()
    let logger = StructuredLogger(clock: clock, sink: logSink)

    // 1. Lista vazia não consulta autorização nem enfileira
    let untouchedBackend = StubUserNotificationBackend(authorizationResult: .success(true))
    let idleAdapter = UserNotificationCenterAdapter(backend: untouchedBackend, logger: logger)
    await idleAdapter.deliver([], refreshID: "refresh-empty")
    XCTAssertEqual(untouchedBackend.authorizationCalls, 0)
    XCTAssertTrue(untouchedBackend.enqueuedPayloads.isEmpty)

    // 2. Permissão negada pelo usuário suprime sem quebrar e registra evento seguro
    let deniedBackend = StubUserNotificationBackend(authorizationResult: .success(false))
    let deniedAdapter = UserNotificationCenterAdapter(backend: deniedBackend, logger: logger)
    let sampleAlerts = [
      DiscreteNotificationAlert(
        identifier: "com.h3zord.BrainPanel.quota.claude.claude-session",
        incidentKey: "quota:claude:claude-session",
        category: .criticalQuota,
        title: "Cota crítica — Claude",
        body: "Sessão de 5 horas com 10% restante."
      ),
      DiscreteNotificationAlert(
        identifier: "com.h3zord.BrainPanel.health.doctor",
        incidentKey: "health:doctor_failure",
        category: .doctorFailure,
        title: "Falha no brain-doctor",
        body: "1 verificação crítica (FAIL) detectada no Brain."
      ),
    ]
    await deniedAdapter.deliver(sampleAlerts, refreshID: "refresh-denied")
    XCTAssertEqual(deniedBackend.authorizationCalls, 1)
    XCTAssertTrue(deniedBackend.enqueuedPayloads.isEmpty)
    XCTAssertTrue(
      logSink.lines.contains {
        $0.contains("\"event\":\"notifications_suppressed_unauthorized\"")
          && $0.contains("\"refresh_id\":\"refresh-denied\"")
      }
    )

    // 3. Falha ao solicitar autorização registra evento seguro sem quebrar o fluxo
    struct SimulatedNotificationError: Error, LocalizedError {
      var errorDescription: String? { "Erro interno UNErrorDomain /Users/privado/segredo" }
    }
    let authErrorBackend = StubUserNotificationBackend(
      authorizationResult: .failure(SimulatedNotificationError())
    )
    let authErrorAdapter = UserNotificationCenterAdapter(backend: authErrorBackend, logger: logger)
    await authErrorAdapter.deliver(sampleAlerts, refreshID: "refresh-auth-error")
    XCTAssertEqual(authErrorBackend.authorizationCalls, 1)
    XCTAssertTrue(authErrorBackend.enqueuedPayloads.isEmpty)
    XCTAssertTrue(
      logSink.lines.contains {
        $0.contains("\"event\":\"notifications_authorization_failed\"")
          && $0.contains("\"error_code\":\"INTERNAL_FAILURE\"")
      }
    )

    // 4. Falha ao enfileirar o 1º alerta é isolada, entrega o 2º alerta sem som e não vaza erro bruto
    let partialBackend = StubUserNotificationBackend(
      authorizationResult: .success(true),
      enqueueErrorsByIdentifier: [
        "com.h3zord.BrainPanel.quota.claude.claude-session": SimulatedNotificationError()
      ]
    )
    let partialAdapter = UserNotificationCenterAdapter(backend: partialBackend, logger: logger)
    await partialAdapter.deliver(sampleAlerts, refreshID: "refresh-partial")

    XCTAssertEqual(partialBackend.enqueuedPayloads.count, 1)
    XCTAssertEqual(
      partialBackend.enqueuedPayloads.first?.identifier,
      "com.h3zord.BrainPanel.health.doctor"
    )
    XCTAssertEqual(partialBackend.enqueuedPayloads.first?.hasSound, false)
    XCTAssertTrue(
      logSink.lines.contains {
        $0.contains("\"event\":\"notification_delivery_failed\"")
          && $0.contains("\"error_code\":\"INTERNAL_FAILURE\"")
      }
    )
    XCTAssertTrue(
      logSink.lines.contains {
        $0.contains("\"event\":\"notifications_delivered\"")
          && $0.contains("\"notifications_count\":\"1\"")
      }
    )
    for line in logSink.lines {
      XCTAssertFalse(line.contains("/Users/privado"))
    }
  }
}

private nonisolated final class StubUserNotificationBackend: UserNotificationBackend,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let authorizationResult: Result<Bool, any Error>
  private let enqueueErrorsByIdentifier: [String: any Error]
  private(set) var authorizationCalls = 0
  private(set) var enqueuedPayloads: [SystemNotificationPayload] = []

  init(
    authorizationResult: Result<Bool, any Error>,
    enqueueErrorsByIdentifier: [String: any Error] = [:]
  ) {
    self.authorizationResult = authorizationResult
    self.enqueueErrorsByIdentifier = enqueueErrorsByIdentifier
  }

  func requestAlertOnlyAuthorization() async throws -> Bool {
    let result = lock.withLock {
      authorizationCalls += 1
      return authorizationResult
    }
    return try result.get()
  }

  func enqueue(_ payload: SystemNotificationPayload) async throws {
    if let error = enqueueErrorsByIdentifier[payload.identifier] {
      throw error
    }
    lock.withLock {
      enqueuedPayloads.append(payload)
    }
  }
}
