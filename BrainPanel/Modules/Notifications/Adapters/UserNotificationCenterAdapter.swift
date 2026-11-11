import Foundation
import UserNotifications

nonisolated struct SystemNotificationPayload: Equatable, Sendable {
  let identifier: String
  let title: String
  let body: String
  let threadIdentifier: String
  let hasSound: Bool
}

nonisolated protocol UserNotificationBackend: Sendable {
  func requestAlertOnlyAuthorization() async throws -> Bool
  func enqueue(_ payload: SystemNotificationPayload) async throws
}

nonisolated struct SystemUserNotificationBackend: UserNotificationBackend {
  func requestAlertOnlyAuthorization() async throws -> Bool {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    switch settings.authorizationStatus {
    case .authorized, .provisional:
      return true
    case .denied:
      return false
    case .notDetermined:
      return try await center.requestAuthorization(options: [.alert])
    @unknown default:
      return false
    }
  }

  func enqueue(_ payload: SystemNotificationPayload) async throws {
    let content = Self.makeNotificationContent(from: payload)
    let request = UNNotificationRequest(
      identifier: payload.identifier,
      content: content,
      trigger: nil
    )
    try await UNUserNotificationCenter.current().add(request)
  }

  static func makeNotificationContent(
    from payload: SystemNotificationPayload
  ) -> UNMutableNotificationContent {
    let content = UNMutableNotificationContent()
    content.title = payload.title
    content.body = payload.body
    content.threadIdentifier = payload.threadIdentifier
    content.sound = nil
    content.badge = nil
    return content
  }
}

nonisolated final class UserNotificationCenterAdapter: NotificationDelivering {
  private let backend: any UserNotificationBackend
  private let logger: StructuredLogger

  init(
    backend: any UserNotificationBackend = SystemUserNotificationBackend(),
    logger: StructuredLogger
  ) {
    self.backend = backend
    self.logger = logger
  }

  func deliver(_ alerts: [DiscreteNotificationAlert], refreshID: String) async {
    guard !alerts.isEmpty else { return }

    let isAuthorized: Bool
    do {
      isAuthorized = try await backend.requestAlertOnlyAuthorization()
    } catch {
      let appError = ErrorHandler.normalize(error)
      logger.warn(
        event: "notifications_authorization_failed",
        refreshID: refreshID,
        errorCode: appError.code,
        fields: [
          .status: "failed",
          .notificationsCount: "\(alerts.count)",
        ]
      )
      return
    }

    guard isAuthorized else {
      logger.info(
        event: "notifications_suppressed_unauthorized",
        refreshID: refreshID,
        fields: [
          .status: "denied",
          .notificationsCount: "\(alerts.count)",
        ]
      )
      return
    }

    var deliveredCount = 0
    for alert in alerts {
      let payload = SystemNotificationPayload(
        identifier: alert.identifier,
        title: alert.title,
        body: alert.body,
        threadIdentifier: "com.h3zord.BrainPanel.\(alert.category.rawValue)",
        hasSound: false
      )
      do {
        try await backend.enqueue(payload)
        deliveredCount += 1
      } catch {
        let appError = ErrorHandler.normalize(error)
        logger.warn(
          event: "notification_delivery_failed",
          refreshID: refreshID,
          errorCode: appError.code,
          fields: [.status: "failed"]
        )
      }
    }

    if deliveredCount > 0 {
      logger.info(
        event: "notifications_delivered",
        refreshID: refreshID,
        fields: [
          .status: "ok",
          .notificationsCount: "\(deliveredCount)",
        ]
      )
    }
  }
}
