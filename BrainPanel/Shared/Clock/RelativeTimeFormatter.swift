import Foundation

/// Formatador puro de tempo decorrido relativo e durações curtas compartilhado pelos módulos do painel.
nonisolated enum RelativeTimeFormatter {
  static func elapsedPhrase(since timestamp: Date, now: Date) -> String {
    let elapsedSeconds = max(Int(now.timeIntervalSince(timestamp)), 0)
    let totalMinutes = elapsedSeconds / 60
    let days = totalMinutes / 1_440
    let hours = (totalMinutes % 1_440) / 60
    let minutes = totalMinutes % 60

    if days > 0 {
      return "há \(days)d \(hours)h"
    }
    if hours > 0 {
      return "há \(hours)h \(minutes)m"
    }
    if minutes > 0 {
      return "há \(minutes)m"
    }
    return "há instantes"
  }

  static func compactDuration(seconds: TimeInterval) -> String {
    let clamped = max(Int(seconds), 0)
    if clamped < 60 {
      return "\(clamped)s"
    }
    if clamped < 3_600 {
      return "\(clamped / 60)m"
    }
    if clamped < 86_400 {
      let hours = clamped / 3_600
      let minutes = (clamped % 3_600) / 60
      return String(format: "%dh %02dm", hours, minutes)
    }
    let days = clamped / 86_400
    let hours = (clamped % 86_400) / 3_600
    return "\(days)d \(hours)h"
  }
}
