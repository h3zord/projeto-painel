import Foundation

nonisolated enum NotificationSourceFreshness: Equatable, Sendable {
  case uncollected
  case fresh
  case degraded
}

nonisolated struct NotificationQuotaWindowCandidate: Equatable, Sendable {
  let limitID: String
  let limitName: String
  let limitDetail: String?
  let remainingPercentage: Int

  init(
    limitID: String,
    limitName: String,
    limitDetail: String? = nil,
    remainingPercentage: Int
  ) {
    self.limitID = limitID
    self.limitName = limitName
    self.limitDetail = limitDetail
    self.remainingPercentage = remainingPercentage
  }
}

nonisolated struct NotificationProviderEvaluationInput: Equatable, Sendable {
  let providerID: String
  let providerName: String
  let freshness: NotificationSourceFreshness
  let usableWindows: [NotificationQuotaWindowCandidate]
}

nonisolated enum NotificationWaitingKind: Equatable, Sendable {
  case pendingPrompt(hasButton: Bool)
  case stuckMailbox(unreadCount: Int)
}

nonisolated struct NotificationWaitingCandidate: Equatable, Sendable {
  let targetName: String
  let kind: NotificationWaitingKind
  let additionalContextForPrivacyCheck: [String]
}

nonisolated struct NotificationHealthEvaluationInput: Equatable, Sendable {
  let freshness: NotificationSourceFreshness
  let doctorFailureCount: Int
  let isBackupFailing: Bool
  let isLiveBackupStalled: Bool
}

nonisolated struct NotificationEvaluationInput: Equatable, Sendable {
  let providers: [NotificationProviderEvaluationInput]
  let waitingFreshness: NotificationSourceFreshness
  let waitingCandidates: [NotificationWaitingCandidate]
  let health: NotificationHealthEvaluationInput
}

nonisolated enum DiscreteNotificationCategory: String, Equatable, Sendable {
  case criticalQuota = "critical_quota"
  case waitingOnOwner = "waiting_on_owner"
  case doctorFailure = "doctor_failure"
  case backupFailure = "backup_failure"
}

nonisolated struct DiscreteNotificationAlert: Equatable, Sendable {
  let identifier: String
  let incidentKey: String
  let category: DiscreteNotificationCategory
  let title: String
  let body: String
}

/// Motor puro de política de alertas discretos e cooldown por chave de incidente.
/// Preserva cooldowns ativos durante leituras degradadas e rearma imediatamente após resolução fresca.
nonisolated struct NotificationPolicyEngine: Sendable {
  static let defaultCooldownSeconds: TimeInterval = 3_600
  static let criticalQuotaRemainingThreshold = 15
  static let corporateMarker = "flexograv"
  private static let identifierPrefix = "com.h3zord.BrainPanel"

  let cooldownSeconds: TimeInterval
  private(set) var lastAlertedAtByIncident: [String: Date] = [:]

  init(cooldownSeconds: TimeInterval = Self.defaultCooldownSeconds) {
    self.cooldownSeconds = max(cooldownSeconds, 0)
  }

  mutating func evaluate(
    input: NotificationEvaluationInput,
    now: Date
  ) -> [DiscreteNotificationAlert] {
    var emitted: [DiscreteNotificationAlert] = []
    emitted.append(contentsOf: evaluateProviders(input.providers, now: now))
    emitted.append(
      contentsOf: evaluateWaiting(
        freshness: input.waitingFreshness,
        candidates: input.waitingCandidates,
        now: now
      )
    )
    emitted.append(contentsOf: evaluateHealth(input.health, now: now))
    return emitted
  }

  private mutating func evaluateProviders(
    _ providers: [NotificationProviderEvaluationInput],
    now: Date
  ) -> [DiscreteNotificationAlert] {
    var emitted: [DiscreteNotificationAlert] = []
    for provider in providers {
      let safeProviderKey = Self.sanitizeSlug(provider.providerID, fallback: "provider")
      let namespacePrefix = "quota:\(safeProviderKey):"

      switch provider.freshness {
      case .uncollected, .degraded:
        continue
      case .fresh:
        let safeProviderLabel = Self.sanitizeDisplayLabel(
          provider.providerName,
          fallback: safeProviderKey
        )
        var activeAlerts: [DiscreteNotificationAlert] = []
        for window in provider.usableWindows
        where window.remainingPercentage < Self.criticalQuotaRemainingThreshold {
          let rawWindowKey = window.limitID.isEmpty ? window.limitName : window.limitID
          let safeWindowKey = Self.sanitizeSlug(rawWindowKey, fallback: "window")
          let safeWindowLabel = Self.sanitizeDisplayLabel(
            window.limitName,
            fallback: safeWindowKey
          )
          let clampedRemaining = min(max(window.remainingPercentage, 0), 100)
          let detailSuffix: String
          if let rawDetail = window.limitDetail {
            let safeDetail = Self.sanitizeDisplayLabel(rawDetail, fallback: "")
            if !safeDetail.isEmpty,
              safeDetail.caseInsensitiveCompare(safeWindowLabel) != .orderedSame
            {
              detailSuffix = " (\(safeDetail))"
            } else {
              detailSuffix = ""
            }
          } else {
            detailSuffix = ""
          }

          activeAlerts.append(
            DiscreteNotificationAlert(
              identifier: "\(Self.identifierPrefix).quota.\(safeProviderKey).\(safeWindowKey)",
              incidentKey: "\(namespacePrefix)\(safeWindowKey)",
              category: .criticalQuota,
              title: "Cota crítica — \(safeProviderLabel)",
              body: "\(safeWindowLabel)\(detailSuffix) com \(clampedRemaining)% restante."
            )
          )
        }
        emitted.append(
          contentsOf: reconcileAndFilterCooldown(
            namespacePrefix: namespacePrefix,
            activeAlerts: activeAlerts,
            now: now
          )
        )
      }
    }
    return emitted
  }

  private mutating func evaluateWaiting(
    freshness: NotificationSourceFreshness,
    candidates: [NotificationWaitingCandidate],
    now: Date
  ) -> [DiscreteNotificationAlert] {
    let namespacePrefix = "waiting:"
    switch freshness {
    case .uncollected, .degraded:
      return []
    case .fresh:
      var activeAlerts: [DiscreteNotificationAlert] = []
      for candidate in candidates {
        let isCorporate = Self.isCorporateScope(
          targetName: candidate.targetName,
          additionalContext: candidate.additionalContextForPrivacyCheck
        )
        switch candidate.kind {
        case .pendingPrompt(let hasButton):
          if isCorporate {
            activeAlerts.append(
              DiscreteNotificationAlert(
                identifier: "\(Self.identifierPrefix).waiting.prompt.corporate",
                incidentKey: "waiting:prompt:corporate",
                category: .waitingOnOwner,
                title: "Sessão aguardando você",
                body: "Uma sessão de escopo restrito aguarda resposta."
              )
            )
          } else {
            let safeTarget = Self.sanitizeSlug(candidate.targetName, fallback: "sessao")
            let body =
              hasButton
              ? "A sessão \(safeTarget) aguarda uma decisão."
              : "A sessão \(safeTarget) aguarda resposta."
            activeAlerts.append(
              DiscreteNotificationAlert(
                identifier: "\(Self.identifierPrefix).waiting.prompt.\(safeTarget)",
                incidentKey: "waiting:prompt:\(safeTarget)",
                category: .waitingOnOwner,
                title: "Sessão aguardando você",
                body: body
              )
            )
          }
        case .stuckMailbox(let unreadCount):
          if isCorporate {
            activeAlerts.append(
              DiscreteNotificationAlert(
                identifier: "\(Self.identifierPrefix).waiting.mail.corporate",
                incidentKey: "waiting:mail:corporate",
                category: .waitingOnOwner,
                title: "Correio aguardando leitura",
                body: "Caixa de correio de escopo restrito aguarda leitura."
              )
            )
          } else {
            let safeTarget = Self.sanitizeSlug(candidate.targetName, fallback: "sessao")
            let count = max(unreadCount, 1)
            let body =
              count == 1
              ? "1 mensagem parada para \(safeTarget)."
              : "\(count) mensagens paradas para \(safeTarget)."
            activeAlerts.append(
              DiscreteNotificationAlert(
                identifier: "\(Self.identifierPrefix).waiting.mail.\(safeTarget)",
                incidentKey: "waiting:mail:\(safeTarget)",
                category: .waitingOnOwner,
                title: "Correio aguardando leitura",
                body: body
              )
            )
          }
        }
      }
      return reconcileAndFilterCooldown(
        namespacePrefix: namespacePrefix,
        activeAlerts: activeAlerts,
        now: now
      )
    }
  }

  private mutating func evaluateHealth(
    _ health: NotificationHealthEvaluationInput,
    now: Date
  ) -> [DiscreteNotificationAlert] {
    let namespacePrefix = "health:"
    switch health.freshness {
    case .uncollected, .degraded:
      return []
    case .fresh:
      var activeAlerts: [DiscreteNotificationAlert] = []
      if health.doctorFailureCount > 0 {
        let count = health.doctorFailureCount
        let body =
          count == 1
          ? "1 verificação crítica (FAIL) detectada no Brain."
          : "\(count) verificações críticas (FAIL) detectadas no Brain."
        activeAlerts.append(
          DiscreteNotificationAlert(
            identifier: "\(Self.identifierPrefix).health.doctor",
            incidentKey: "health:doctor_failure",
            category: .doctorFailure,
            title: "Falha no brain-doctor",
            body: body
          )
        )
      }

      if health.isBackupFailing || health.isLiveBackupStalled {
        let body: String =
          if health.isBackupFailing && health.isLiveBackupStalled {
            "O backup do Brain requer atenção e o progresso ao vivo estagnou."
          } else if health.isLiveBackupStalled {
            "O progresso ao vivo do backup do Brain está estagnado."
          } else {
            "O estado do backup do Brain requer atenção."
          }
        activeAlerts.append(
          DiscreteNotificationAlert(
            identifier: "\(Self.identifierPrefix).health.backup",
            incidentKey: "health:backup_attention",
            category: .backupFailure,
            title: "Atenção no brain-backup",
            body: body
          )
        )
      }

      return reconcileAndFilterCooldown(
        namespacePrefix: namespacePrefix,
        activeAlerts: activeAlerts,
        now: now
      )
    }
  }

  private mutating func reconcileAndFilterCooldown(
    namespacePrefix: String,
    activeAlerts: [DiscreteNotificationAlert],
    now: Date
  ) -> [DiscreteNotificationAlert] {
    var deduplicated: [DiscreteNotificationAlert] = []
    var activeKeys: Set<String> = []
    for alert in activeAlerts where activeKeys.insert(alert.incidentKey).inserted {
      deduplicated.append(alert)
    }

    let resolvedKeys = lastAlertedAtByIncident.keys.filter {
      $0.hasPrefix(namespacePrefix) && !activeKeys.contains($0)
    }
    for key in resolvedKeys {
      lastAlertedAtByIncident.removeValue(forKey: key)
    }

    var triggered: [DiscreteNotificationAlert] = []
    for alert in deduplicated {
      if let lastAlertedAt = lastAlertedAtByIncident[alert.incidentKey],
        now.timeIntervalSince(lastAlertedAt) < cooldownSeconds
      {
        continue
      }
      lastAlertedAtByIncident[alert.incidentKey] = now
      triggered.append(alert)
    }
    return triggered
  }

  private static func isCorporateScope(
    targetName: String,
    additionalContext: [String]
  ) -> Bool {
    if targetName.localizedStandardContains(corporateMarker) {
      return true
    }
    return additionalContext.contains { $0.localizedStandardContains(corporateMarker) }
  }

  private static func sanitizeSlug(_ raw: String, fallback: String) -> String {
    let redacted = redactSensitiveTokens(raw).lowercased()
    guard !redacted.localizedStandardContains(corporateMarker) else {
      return fallback
    }
    var buffer = ""
    var previousWasHyphen = false
    for scalar in redacted.unicodeScalars {
      let isAlphaNumeric =
        (scalar.value >= 0x61 && scalar.value <= 0x7A)
        || (scalar.value >= 0x30 && scalar.value <= 0x39)
      if isAlphaNumeric || scalar == "_" {
        buffer.unicodeScalars.append(scalar)
        previousWasHyphen = false
      } else if !buffer.isEmpty, !previousWasHyphen {
        buffer.append("-")
        previousWasHyphen = true
      }
      if buffer.count >= 48 {
        break
      }
    }
    while buffer.last == "-" {
      buffer.removeLast()
    }
    return buffer.isEmpty ? fallback : buffer
  }

  private static func sanitizeDisplayLabel(_ raw: String, fallback: String) -> String {
    let redacted = redactSensitiveTokens(raw)
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .filter { char in
        char.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
      }
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !redacted.isEmpty, !redacted.localizedStandardContains(corporateMarker) else {
      return fallback
    }
    return redacted.count > 60 ? String(redacted.prefix(60)) : redacted
  }

  private static func redactSensitiveTokens(_ raw: String) -> String {
    let emailRegex = #/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/#
    let cpfRegex = #/\b\d{3}\.?\d{3}\.?\d{3}-?\d{2}\b/#
    let secretTokenRegex =
      #/\b(?:sk-[A-Za-z0-9_\-]{8,}|gh[pousr]_[A-Za-z0-9_]{8,}|AIza[0-9A-Za-z_\-]{12,}|eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+)\b/#
    return
      raw
      .replacing(emailRegex, with: "")
      .replacing(cpfRegex, with: "")
      .replacing(secretTokenRegex, with: "")
  }
}
