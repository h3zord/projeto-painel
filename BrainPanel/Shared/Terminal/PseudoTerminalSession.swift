import Darwin
import Foundation

/// Executa uma CLI interativa dentro de um pseudo-terminal somente-leitura e captura a tela desenhada.
/// Os métodos de leitura bloqueiam em `poll`, devendo rodar apenas em fila de background.
nonisolated final class PseudoTerminalSession {
  typealias ByteWriter = (UnsafeRawPointer, Int) -> (written: Int, errorNumber: Int32)

  private static let defaultGracePeriodSeconds: TimeInterval = 0.2
  private static let pollStepMicroseconds: useconds_t = 5_000

  private let process = Process()
  private let master: Int32
  private let columns: Int
  private let rows: Int
  private let clock: any Clock
  private var buffer = Data()
  private var isMasterClosed = false

  init(
    executable: URL,
    arguments: [String] = [],
    directory: URL,
    environment: [String: String],
    clock: any Clock = SystemClock(),
    columns: UInt16 = 120,
    rows: UInt16 = 50
  ) throws(AppError) {
    var masterDescriptor: Int32 = 0
    var slaveDescriptor: Int32 = 0
    var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)

    guard openpty(&masterDescriptor, &slaveDescriptor, nil, nil, &size) == 0 else {
      throw AppError.terminalUnavailable()
    }

    self.master = masterDescriptor
    self.columns = Int(columns)
    self.rows = Int(rows)
    self.clock = clock

    let terminal = FileHandle(fileDescriptor: slaveDescriptor, closeOnDealloc: true)
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.environment = environment
    process.standardInput = terminal
    process.standardOutput = terminal
    process.standardError = terminal

    do {
      try process.run()
    } catch {
      Darwin.close(masterDescriptor)
      throw AppError.terminalUnavailable()
    }

    // O processo filho herdou sua cópia do descritor; manter a nossa aberta esconderia o EOF na saída.
    try? terminal.close()
  }

  deinit {
    terminate()
    closeMasterDescriptor()
  }

  var processIdentifier: Int32 {
    process.processIdentifier
  }

  /// Texto sequencial completo impresso pelo processo com códigos de controle removidos.
  var text: String {
    TerminalText.clean(buffer)
  }

  /// Grade emulada do terminal aplicando movimentos de cursor (necessária para TUIs que redesenham linhas).
  var screen: String {
    TerminalScreen.render(buffer, columns: columns, rows: rows)
  }

  /// Escreve todos os bytes no descritor mestre do PTY tratando escritas parciais e `EINTR`.
  func send(_ input: String) throws(AppError) {
    let bytes = Array(input.utf8)
    let descriptor = master
    try Self.writeAll(bytes) { pointer, count in
      let written = Darwin.write(descriptor, pointer, count)
      return (written, written < 0 ? errno : 0)
    }
  }

  static func writeAll(
    _ bytes: [UInt8],
    using writer: ByteWriter
  ) throws(AppError) {
    guard !bytes.isEmpty else { return }

    let succeeded = bytes.withUnsafeBytes { rawBuffer -> Bool in
      guard let baseAddress = rawBuffer.baseAddress else { return true }
      var offset = 0
      var transientAgainCount = 0

      while offset < rawBuffer.count {
        let pointer = baseAddress.advanced(by: offset)
        let result = writer(pointer, rawBuffer.count - offset)
        if result.written > 0 {
          offset += result.written
          transientAgainCount = 0
        } else if result.written < 0 && result.errorNumber == EINTR {
          continue
        } else if result.written < 0 && result.errorNumber == EAGAIN && transientAgainCount < 50 {
          transientAgainCount += 1
          usleep(1_000)
        } else {
          return false
        }
      }
      return true
    }

    guard succeeded else {
      throw AppError.terminalWriteFailed()
    }
  }

  @discardableResult
  func read(timeout: TimeInterval, until condition: (String) -> Bool) -> Bool {
    let deadline = clock.now().addingTimeInterval(timeout)

    while clock.now() < deadline {
      guard readAvailable(waitingMilliseconds: 200) else { return false }
      if condition(text) { return true }
    }

    return false
  }

  func readUntilQuiet(_ quietPeriod: TimeInterval, timeout: TimeInterval) {
    let deadline = clock.now().addingTimeInterval(timeout)
    var lastOutput = clock.now()

    while clock.now() < deadline {
      let previousCount = buffer.count
      guard readAvailable(waitingMilliseconds: 100) else { return }

      let currentTime = clock.now()
      if buffer.count != previousCount {
        lastOutput = currentTime
      } else if currentTime.timeIntervalSince(lastOutput) >= quietPeriod {
        return
      }
    }
  }

  /// Envia `SIGTERM`, aguarda o encerramento dentro de uma janela curta e escala para `SIGKILL`
  /// caso o processo filho continue vivo, colhendo o status de saída para não deixar órfãos nem zombies.
  func terminate(gracePeriod: TimeInterval = PseudoTerminalSession.defaultGracePeriodSeconds) {
    let pid = process.processIdentifier
    guard pid > 0 else { return }

    if process.isRunning {
      process.terminate()

      let stepSeconds = Double(Self.pollStepMicroseconds) / 1_000_000
      let maxSteps = max(Int((max(gracePeriod, 0) / stepSeconds).rounded(.up)), 1)

      for _ in 0..<maxSteps {
        if !process.isRunning {
          break
        }
        usleep(Self.pollStepMicroseconds)
      }

      if process.isRunning {
        _ = Darwin.kill(pid, SIGKILL)
      }
    }

    process.waitUntilExit()
  }

  private func closeMasterDescriptor() {
    guard !isMasterClosed else { return }
    isMasterClosed = true
    Darwin.close(master)
  }

  private func readAvailable(waitingMilliseconds: Int32) -> Bool {
    var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
    let ready = poll(&descriptor, 1, waitingMilliseconds)
    if ready < 0 && errno == EINTR {
      return true
    }
    guard ready > 0 else { return true }

    var chunk = [UInt8](repeating: 0, count: 65_536)
    let count = Darwin.read(master, &chunk, chunk.count)
    if count < 0 && errno == EINTR {
      return true
    }
    guard count > 0 else { return false }

    let data = Data(chunk[0..<count])
    buffer.append(data)

    // Algumas TUIs aguardam resposta da posição atual do cursor antes de desenhar a tela.
    if data.range(of: Data("\u{1b}[6n".utf8)) != nil {
      try? send("\u{1b}[1;1R")
    }

    return true
  }
}
