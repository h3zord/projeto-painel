import Darwin
import Foundation

nonisolated enum LogLevel: String, Equatable, Sendable, Encodable {
  case info
  case warn
  case error
}

/// Chaves estruturadas permitidas no log JSON.
/// Texto livre vindo de fora (telas de CLI, transcripts, valores brutos de ambiente) não entra aqui.
nonisolated enum LogFieldKey: String, Equatable, Hashable, Sendable {
  case provider = "provider"
  case collector = "collector"
  case status = "status"
  case limitsCount = "limits_count"
  case conversationsCount = "conversations_count"
  case durationMs = "duration_ms"
  case mode = "mode"
  case setting = "setting"
  case bundleID = "bundle_id"
}

nonisolated protocol LogSink: Sendable {
  func write(_ line: String)
}

nonisolated struct StandardErrorLogSink: LogSink {
  func write(_ line: String) {
    let payload = Array((line + "\n").utf8)
    payload.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.baseAddress else { return }
      var offset = 0
      while offset < rawBuffer.count {
        let written = Darwin.write(STDERR_FILENO, base.advanced(by: offset), rawBuffer.count - offset)
        if written > 0 {
          offset += written
        } else if written < 0 && errno == EINTR {
          continue
        } else {
          break
        }
      }
    }
  }
}

/// Logger estruturado em JSON de linha única com correlação por `refresh_id` e sanitização estrita.
nonisolated struct StructuredLogger: Sendable {
  private struct Payload: Encodable {
    let timestamp: String
    let level: LogLevel
    let event: String
    let refreshID: String
    let errorCode: String?
    let fields: [String: String]

    enum CodingKeys: String, CodingKey {
      case timestamp
      case level
      case event
      case refreshID = "refresh_id"
      case errorCode = "error_code"
      case fields
    }
  }

  private let clock: any Clock
  private let sink: any LogSink

  init(clock: any Clock = SystemClock(), sink: any LogSink = StandardErrorLogSink()) {
    self.clock = clock
    self.sink = sink
  }

  func info(
    event: String,
    refreshID: String,
    fields: [LogFieldKey: String] = [:]
  ) {
    emit(level: .info, event: event, refreshID: refreshID, errorCode: nil, fields: fields)
  }

  func warn(
    event: String,
    refreshID: String,
    errorCode: AppErrorCode? = nil,
    fields: [LogFieldKey: String] = [:]
  ) {
    emit(level: .warn, event: event, refreshID: refreshID, errorCode: errorCode, fields: fields)
  }

  func error(
    event: String,
    refreshID: String,
    errorCode: AppErrorCode,
    fields: [LogFieldKey: String] = [:]
  ) {
    emit(level: .error, event: event, refreshID: refreshID, errorCode: errorCode, fields: fields)
  }

  private func emit(
    level: LogLevel,
    event: String,
    refreshID: String,
    errorCode: AppErrorCode?,
    fields: [LogFieldKey: String]
  ) {
    var sanitizedFields: [String: String] = [:]
    sanitizedFields.reserveCapacity(fields.count)
    for (key, value) in fields {
      sanitizedFields[key.rawValue] = LogSanitizer.sanitize(value)
    }

    let payload = Payload(
      timestamp: Self.iso8601Timestamp(from: clock.now()),
      level: level,
      event: LogSanitizer.sanitizeIdentifier(event),
      refreshID: LogSanitizer.sanitizeIdentifier(refreshID),
      errorCode: errorCode?.rawValue,
      fields: sanitizedFields
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(payload) else { return }
    sink.write(String(decoding: data, as: UTF8.self))
  }

  private static func iso8601Timestamp(from date: Date) -> String {
    date.ISO8601Format()
  }
}

nonisolated enum LogSanitizer {
  static func sanitize(_ raw: String) -> String {
    let emailRegex = #/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/#
    let cpfRegex = #/\b\d{3}\.?\d{3}\.?\d{3}-?\d{2}\b/#
    let secretTokenRegex =
      #/\b(?:sk-[A-Za-z0-9_\-]{8,}|gh[pousr]_[A-Za-z0-9_]{8,}|AIza[0-9A-Za-z_\-]{12,}|eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+)\b/#
    var value =
      raw
      .replacing(emailRegex, with: "[REDACTED_EMAIL]")
      .replacing(cpfRegex, with: "[REDACTED_DOC]")
      .replacing(secretTokenRegex, with: "[REDACTED_TOKEN]")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")

    if value.count > 120 {
      value = String(value.prefix(120))
    }
    return value
  }

  static func sanitizeIdentifier(_ raw: String) -> String {
    let clean = raw.prefix(64).filter { char in
      char.isASCII && (char.isLetter || char.isNumber || char == "_" || char == "-")
    }
    return clean.isEmpty ? "unknown" : String(clean)
  }
}
