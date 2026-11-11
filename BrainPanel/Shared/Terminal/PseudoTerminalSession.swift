import Darwin
import Foundation

@_silgen_name("brain_panel_pty_spawn")
nonisolated private func brainPanelPTYSpawn(
  _ executablePath: UnsafePointer<CChar>,
  _ argv: UnsafePointer<UnsafeMutablePointer<CChar>?>,
  _ envp: UnsafePointer<UnsafeMutablePointer<CChar>?>,
  _ workingDirectory: UnsafePointer<CChar>,
  _ masterFD: Int32,
  _ slaveFD: Int32,
  _ outErrno: UnsafeMutablePointer<Int32>
) -> pid_t

private nonisolated final class ActivePTYSessionRegistry: @unchecked Sendable {
  private final class WeakSession {
    weak var session: PseudoTerminalSession?

    init(_ session: PseudoTerminalSession) {
      self.session = session
    }
  }

  private let lock = NSLock()
  private var sessions: [UUID: WeakSession] = [:]

  func register(_ session: PseudoTerminalSession, id: UUID) {
    lock.withLock {
      sessions = sessions.filter { $0.value.session != nil }
      sessions[id] = WeakSession(session)
    }
  }

  func unregister(id: UUID) {
    _ = lock.withLock {
      sessions.removeValue(forKey: id)
    }
  }

  func snapshot() -> [PseudoTerminalSession] {
    lock.withLock {
      sessions = sessions.filter { $0.value.session != nil }
      return sessions.values.compactMap(\.session)
    }
  }
}

nonisolated final class PTYCaptureCancellationBox: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var activeSession: PseudoTerminalSession?

  var isCancelled: Bool {
    lock.withLock { cancelled }
  }

  func attach(_ session: PseudoTerminalSession?) {
    let shouldTerminateNow = lock.withLock { () -> Bool in
      if cancelled {
        activeSession = nil
        return true
      }
      activeSession = session
      return false
    }
    if shouldTerminateNow {
      session?.terminate(gracePeriod: 0.05)
    }
  }

  func cancel() {
    let session = lock.withLock { () -> PseudoTerminalSession? in
      cancelled = true
      let current = activeSession
      activeSession = nil
      return current
    }
    session?.terminate(gracePeriod: 0.05)
  }
}

/// Executa uma CLI interativa dentro de um pseudo-terminal somente-leitura com controlling TTY
/// (`setsid` + `TIOCSCTTY`), garantindo que o fechamento do descritor `master` entregue `SIGHUP`
/// imediato à sessão filha sem deixar processos órfãos.
nonisolated final class PseudoTerminalSession: @unchecked Sendable {
  typealias ByteWriter = (UnsafeRawPointer, Int) -> (written: Int, errorNumber: Int32)

  private static let defaultGracePeriodSeconds: TimeInterval = 0.2
  private static let pollStepMicroseconds: useconds_t = 5_000
  private static let activeRegistry = ActivePTYSessionRegistry()

  private let registrationID = UUID()
  private let childPID: pid_t
  private let master: Int32
  private let columns: Int
  private let rows: Int
  private let clock: any Clock
  private let masterCloser: (Int32) -> Int32
  private let ioLock = NSLock()
  private let lifecycleLock = NSLock()
  private let bufferLock = NSLock()
  private var buffer = Data()
  private var isMasterClosed = false
  private var hasReapedChild = false

  init(
    executable: URL,
    arguments: [String] = [],
    directory: URL,
    environment: [String: String],
    clock: any Clock = SystemClock(),
    columns: UInt16 = 120,
    rows: UInt16 = 50,
    masterCloser: @escaping (Int32) -> Int32 = { Darwin.close($0) }
  ) throws(AppError) {
    var masterDescriptor: Int32 = -1
    var slaveDescriptor: Int32 = -1
    var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)

    guard openpty(&masterDescriptor, &slaveDescriptor, nil, nil, &size) == 0 else {
      throw AppError.terminalUnavailable()
    }

    Self.configureCloseOnExecAndNonBlockingMaster(
      masterFD: masterDescriptor,
      slaveFD: slaveDescriptor
    )

    let argvStrings = [executable.path] + arguments
    let envStrings = environment.keys.sorted().map { key in
      "\(key)=\(environment[key] ?? "")"
    }

    var spawnErrno: Int32 = 0
    let spawnedPID = Self.spawnInNewSession(
      executablePath: executable.path,
      argvStrings: argvStrings,
      envStrings: envStrings,
      workingDirectory: directory.path,
      masterFD: masterDescriptor,
      slaveFD: slaveDescriptor,
      outErrno: &spawnErrno
    )

    // O filho já duplicou o slave em 0/1/2; fechar a cópia do pai permite receber EOF quando o filho sair.
    _ = Darwin.close(slaveDescriptor)

    guard spawnedPID > 0 else {
      _ = masterCloser(masterDescriptor)
      throw AppError.terminalUnavailable()
    }

    self.childPID = spawnedPID
    self.master = masterDescriptor
    self.columns = Int(columns)
    self.rows = Int(rows)
    self.clock = clock
    self.masterCloser = masterCloser

    Self.activeRegistry.register(self, id: registrationID)
  }

  deinit {
    terminate()
    closeMasterDescriptor()
  }

  static func terminateAllActiveSessions(
    gracePeriod: TimeInterval = PseudoTerminalSession.defaultGracePeriodSeconds
  ) {
    for session in activeRegistry.snapshot() {
      session.terminate(gracePeriod: gracePeriod)
    }
  }

  var processIdentifier: Int32 {
    childPID
  }

  /// Texto sequencial completo impresso pelo processo com códigos de controle removidos.
  var text: String {
    let snapshot = bufferLock.withLock { buffer }
    return TerminalText.clean(snapshot)
  }

  /// Grade emulada do terminal aplicando movimentos de cursor (necessária para TUIs que redesenham linhas).
  var screen: String {
    let snapshot = bufferLock.withLock { buffer }
    return TerminalScreen.render(snapshot, columns: columns, rows: rows)
  }

  /// Escreve todos os bytes no descritor mestre do PTY tratando escritas parciais e `EINTR`.
  func send(_ input: String) throws(AppError) {
    let alreadyClosed = ioLock.withLock { isMasterClosed }
    guard !alreadyClosed else {
      throw AppError.terminalWriteFailed()
    }
    let bytes = Array(input.utf8)
    try Self.writeAll(bytes) { pointer, count in
      ioLock.withLock {
        guard !isMasterClosed else {
          return (-1, EBADF)
        }
        let written = Darwin.write(master, pointer, count)
        return (written, written < 0 ? errno : 0)
      }
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
    if condition(text) { return true }
    let deadline = clock.now().addingTimeInterval(timeout)

    while clock.now() < deadline {
      guard readAvailable(waitingMilliseconds: 200) else { return false }
      if condition(text) { return true }
    }

    return false
  }

  @discardableResult
  func readSession(
    timeout: TimeInterval,
    until condition: (PseudoTerminalSession) -> Bool
  ) -> Bool {
    if condition(self) { return true }
    let deadline = clock.now().addingTimeInterval(timeout)

    while clock.now() < deadline {
      guard readAvailable(waitingMilliseconds: 200) else { return false }
      if condition(self) { return true }
    }

    return false
  }

  func readUntilQuiet(_ quietPeriod: TimeInterval, timeout: TimeInterval) {
    let deadline = clock.now().addingTimeInterval(timeout)
    var lastOutput = clock.now()

    while clock.now() < deadline {
      let previousCount = bufferLock.withLock { buffer.count }
      guard readAvailable(waitingMilliseconds: 100) else { return }

      let currentTime = clock.now()
      let currentCount = bufferLock.withLock { buffer.count }
      if currentCount != previousCount {
        lastOutput = currentTime
      } else if currentTime.timeIntervalSince(lastOutput) >= quietPeriod {
        return
      }
    }
  }

  /// Fecha o `master` (entregando `SIGHUP`), envia `SIGTERM` ao grupo de processos da sessão filha,
  /// aguarda `gracePeriod` e escala para `SIGKILL` no grupo se necessário, colhendo o filho.
  func terminate(gracePeriod: TimeInterval = PseudoTerminalSession.defaultGracePeriodSeconds) {
    Self.activeRegistry.unregister(id: registrationID)
    closeMasterDescriptor()

    let pid = childPID
    guard pid > 0 else { return }

    lifecycleLock.withLock {
      if isGroupOrLeaderAliveLocked(pid: pid) {
        _ = Darwin.kill(-pid, SIGTERM)
        if !hasReapedChild {
          _ = Darwin.kill(pid, SIGTERM)
        }

        let stepSeconds = Double(Self.pollStepMicroseconds) / 1_000_000
        let maxSteps = max(Int((max(gracePeriod, 0) / stepSeconds).rounded(.up)), 1)

        for _ in 0..<maxSteps {
          if !isGroupOrLeaderAliveLocked(pid: pid) {
            break
          }
          usleep(Self.pollStepMicroseconds)
        }

        if isGroupOrLeaderAliveLocked(pid: pid) {
          _ = Darwin.kill(-pid, SIGKILL)
          if !hasReapedChild {
            _ = Darwin.kill(pid, SIGKILL)
          }

          for _ in 0..<20 {
            if !isGroupOrLeaderAliveLocked(pid: pid) {
              break
            }
            usleep(2_500)
          }
        }
      }

      if !hasReapedChild {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        hasReapedChild = true
      }
    }
  }

  func closeMasterDescriptorWithoutTerminating() {
    closeMasterDescriptor()
  }

  private func closeMasterDescriptor() {
    ioLock.withLock {
      guard !isMasterClosed else { return }
      isMasterClosed = true
      _ = masterCloser(master)
    }
  }

  private func reapLeaderNonBlockingLocked(pid: pid_t) {
    guard !hasReapedChild else { return }
    var status: Int32 = 0
    let result = waitpid(pid, &status, WNOHANG)
    if result == pid || (result < 0 && errno == ECHILD) {
      hasReapedChild = true
    }
  }

  private func isGroupOrLeaderAliveLocked(pid: pid_t) -> Bool {
    reapLeaderNonBlockingLocked(pid: pid)
    if !hasReapedChild {
      return true
    }
    return Darwin.kill(-pid, 0) == 0
  }

  private func readAvailable(waitingMilliseconds: Int32) -> Bool {
    let closedBeforePoll = ioLock.withLock { isMasterClosed }
    guard !closedBeforePoll else { return false }

    var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
    let ready = poll(&descriptor, 1, waitingMilliseconds)
    if ready < 0 {
      return errno == EINTR
    }
    if (descriptor.revents & Int16(POLLNVAL)) != 0 {
      return false
    }
    guard ready > 0 else { return true }

    var chunk = [UInt8](repeating: 0, count: 65_536)
    let readOutcome: (count: Int, err: Int32, closed: Bool) = ioLock.withLock {
      guard !isMasterClosed else {
        return (0, 0, true)
      }
      let n = Darwin.read(master, &chunk, chunk.count)
      return (n, n < 0 ? errno : 0, false)
    }

    if readOutcome.closed {
      return false
    }
    if readOutcome.count < 0 {
      if readOutcome.err == EINTR {
        return true
      }
      if readOutcome.err == EAGAIN {
        return (descriptor.revents & Int16(POLLHUP | POLLERR)) == 0
      }
      return false
    }
    guard readOutcome.count > 0 else { return false }

    let data = Data(chunk[0..<readOutcome.count])
    bufferLock.withLock {
      buffer.append(data)
    }

    // Algumas TUIs aguardam resposta da posição atual do cursor antes de desenhar a tela.
    if data.range(of: Data("\u{1b}[6n".utf8)) != nil {
      try? send("\u{1b}[1;1R")
    }

    return true
  }

  private static func configureCloseOnExecAndNonBlockingMaster(
    masterFD: Int32,
    slaveFD: Int32
  ) {
    let masterFDFlags = fcntl(masterFD, F_GETFD)
    if masterFDFlags >= 0 {
      _ = fcntl(masterFD, F_SETFD, masterFDFlags | FD_CLOEXEC)
    }
    let slaveFDFlags = fcntl(slaveFD, F_GETFD)
    if slaveFDFlags >= 0 {
      _ = fcntl(slaveFD, F_SETFD, slaveFDFlags | FD_CLOEXEC)
    }
    let masterStatusFlags = fcntl(masterFD, F_GETFL)
    if masterStatusFlags >= 0 {
      _ = fcntl(masterFD, F_SETFL, masterStatusFlags | O_NONBLOCK)
    }
  }

  private static func spawnInNewSession(
    executablePath: String,
    argvStrings: [String],
    envStrings: [String],
    workingDirectory: String,
    masterFD: Int32,
    slaveFD: Int32,
    outErrno: inout Int32
  ) -> pid_t {
    var capturedErrno: Int32 = 0
    let pid = withNullTerminatedCStrings(argvStrings) { argvPointers -> pid_t in
      guard let argvPointers else {
        capturedErrno = ENOMEM
        return -1
      }
      return withNullTerminatedCStrings(envStrings) { envPointers -> pid_t in
        guard let envPointers else {
          capturedErrno = ENOMEM
          return -1
        }
        return executablePath.withCString { execPtr in
          workingDirectory.withCString { cwdPtr in
            argvPointers.withUnsafeBufferPointer { argvBuf in
              envPointers.withUnsafeBufferPointer { envBuf in
                guard let argvBase = argvBuf.baseAddress, let envBase = envBuf.baseAddress else {
                  capturedErrno = EINVAL
                  return -1
                }
                return brainPanelPTYSpawn(
                  execPtr,
                  argvBase,
                  envBase,
                  cwdPtr,
                  masterFD,
                  slaveFD,
                  &capturedErrno
                )
              }
            }
          }
        }
      }
    }
    outErrno = capturedErrno
    return pid
  }

  private static func withNullTerminatedCStrings<R>(
    _ strings: [String],
    body: ([UnsafeMutablePointer<CChar>?]?) -> R
  ) -> R {
    var allocated: [UnsafeMutablePointer<CChar>] = []
    allocated.reserveCapacity(strings.count)
    defer {
      for pointer in allocated {
        free(pointer)
      }
    }

    for value in strings {
      guard let duplicated = strdup(value) else {
        return body(nil)
      }
      allocated.append(duplicated)
    }

    var nullTerminated: [UnsafeMutablePointer<CChar>?] = allocated.map { Optional($0) }
    nullTerminated.append(nil)
    return body(nullTerminated)
  }
}
