import Foundation

nonisolated protocol NotificationDelivering: Sendable {
  func deliver(_ alerts: [DiscreteNotificationAlert], refreshID: String) async
}
