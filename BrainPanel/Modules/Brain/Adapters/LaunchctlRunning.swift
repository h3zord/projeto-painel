import Darwin
import Foundation

nonisolated protocol LaunchctlRunning: Sendable {
  func listJobs() throws(AppError) -> String
}

nonisolated struct EmptyLaunchctlRunner: LaunchctlRunning {
  func listJobs() throws(AppError) -> String {
    ""
  }
}

/// Executa `launchctl list` (ou binário substituto em testes) sem shell, em grupo de processos próprio,
/// aplicando timeout estrito (`<= 3s` por padrão) e encerramento `SIGTERM` -> `SIGKILL` sem órfãos.
nonisolated struct ProcessLaunchctlRunner: LaunchctlRunning {
  static let defaultTimeoutSeconds: TimeInterval = 3.0
  static let maxOutputBytes = 512 * 1_024
  private static let graceStepMicroseconds: useconds_t = 5_000
  private static let graceStepCount = 16

  let executableURL: URL
  let arguments: [String]
  let timeoutSeconds: TimeInterval

  init(
    executableURL: URL = URL(filePath: "/bin/launchctl"),
    arguments: [String] = ["list"],
    timeoutSeconds: TimeInterval = Self.defaultTimeoutSeconds
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.timeoutSeconds = timeoutSeconds
  }

  func listJobs() throws(AppError) -> String {
    let executablePath = executableURL.path
    guard timeoutSeconds > 0, Darwin.access(executablePath, X_OK) == 0 else {
      throw AppError.brainStateReadFailed(section: .scheduledJobs)
    }

    var pipeFDs: [Int32] = [-1, -1]
    guard Darwin.pipe(&pipeFDs) == 0 else {
      throw AppError.brainStateReadFailed(section: .scheduledJobs)
    }

    let readFD = pipeFDs[0]
    let writeFD = pipeFDs[1]
    var isReadClosed = false
    var isWriteClosed = false
    defer {
      if !isReadClosed {
        _ = Darwin.close(readFD)
      }
      if !isWriteClosed {
        _ = Darwin.close(writeFD)
      }
    }

    _ = Darwin.fcntl(readFD, F_SETFD, FD_CLOEXEC)
    _ = Darwin.fcntl(writeFD, F_SETFD, FD_CLOEXEC)
    let currentFlags = Darwin.fcntl(readFD, F_GETFL)
    if currentFlags >= 0 {
      _ = Darwin.fcntl(readFD, F_SETFL, currentFlags | O_NONBLOCK)
    }

    var fileActions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&fileActions) == 0 else {
      throw AppError.brainStateReadFailed(section: .scheduledJobs)
    }
    defer { _ = posix_spawn_file_actions_destroy(&fileActions) }

    guard
      posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
      posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0,
      posix_spawn_file_actions_adddup2(&fileActions, writeFD, STDOUT_FILENO) == 0
    else {
      throw AppError.brainStateReadFailed(section: .scheduledJobs)
    }

    var spawnAttr: posix_spawnattr_t?
    guard posix_spawnattr_init(&spawnAttr) == 0 else {
      throw AppError.brainStateReadFailed(section: .scheduledJobs)
    }
    defer { _ = posix_spawnattr_destroy(&spawnAttr) }

    guard
      posix_spawnattr_setflags(&spawnAttr, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
      posix_spawnattr_setpgroup(&spawnAttr, 0) == 0
    else {
      throw AppError.brainStateReadFailed(section: .scheduledJobs)
    }

    let argvStrings = [executablePath] + arguments
    let envStrings = [
      "PATH=/usr/bin:/bin",
      "LANG=en_US.UTF-8",
      "LC_ALL=en_US.UTF-8",
    ]

    var cArgs: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) }
    cArgs.append(nil)
    defer {
      for ptr in cArgs where ptr != nil {
        free(ptr)
      }
    }

    var cEnv: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) }
    cEnv.append(nil)
    defer {
      for ptr in cEnv where ptr != nil {
        free(ptr)
      }
    }

    var pid: pid_t = 0
    let spawnResult = posix_spawn(
      &pid,
      executablePath,
      &fileActions,
      &spawnAttr,
      &cArgs,
      &cEnv
    )

    _ = Darwin.close(writeFD)
    isWriteClosed = true

    guard spawnResult == 0, pid > 0 else {
      throw AppError.brainStateReadFailed(section: .scheduledJobs)
    }

    let clampedTimeout = min(max(timeoutSeconds, 0.01), 30.0)
    let deadlineNs =
      clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) &+ UInt64(clampedTimeout * 1_000_000_000)

    var output = Data()
    var eofReached = false
    var failedOrTimedOut = false
    var chunk = [UInt8](repeating: 0, count: 16_384)

    while !eofReached && !failedOrTimedOut {
      let currentNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
      if currentNs >= deadlineNs {
        failedOrTimedOut = true
        break
      }

      let remainingMs = Int32(min((deadlineNs - currentNs) / 1_000_000 + 1, 50))
      var descriptor = pollfd(fd: readFD, events: Int16(POLLIN | POLLHUP), revents: 0)
      let ready = Darwin.poll(&descriptor, 1, remainingMs)
      if ready < 0 {
        if errno == EINTR {
          continue
        }
        failedOrTimedOut = true
        break
      }
      if ready == 0 {
        continue
      }

      while true {
        let count = Darwin.read(readFD, &chunk, chunk.count)
        if count > 0 {
          if output.count + count > Self.maxOutputBytes {
            failedOrTimedOut = true
            break
          }
          output.append(contentsOf: chunk[0..<count])
        } else if count == 0 {
          eofReached = true
          break
        } else if errno == EINTR {
          continue
        } else if errno == EAGAIN || errno == EWOULDBLOCK {
          break
        } else {
          failedOrTimedOut = true
          break
        }
      }
    }

    _ = Darwin.close(readFD)
    isReadClosed = true

    if failedOrTimedOut {
      Self.terminateProcessGroupAndReap(pid: pid)
      throw AppError.brainStateReadFailed(section: .scheduledJobs)
    }

    var exitStatus: Int32?
    while exitStatus == nil {
      var status: Int32 = 0
      let waited = Darwin.waitpid(pid, &status, WNOHANG)
      if waited == pid {
        exitStatus = status
        break
      }
      if waited < 0 && errno != EINTR {
        break
      }
      if clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) >= deadlineNs {
        break
      }
      usleep(2_000)
    }

    guard let status = exitStatus else {
      Self.terminateProcessGroupAndReap(pid: pid)
      throw AppError.brainStateReadFailed(section: .scheduledJobs)
    }

    // Caso o processo líder tenha saído deixando subprocesso em background no grupo, encerra o grupo.
    if Darwin.kill(-pid, 0) == 0 {
      _ = Darwin.kill(-pid, SIGKILL)
    }

    let exitedNormally = (status & 0x7f) == 0
    let exitCode = (status >> 8) & 0xff
    guard exitedNormally, exitCode == 0 else {
      throw AppError.brainStateReadFailed(section: .scheduledJobs)
    }

    return String(decoding: output, as: UTF8.self)
  }

  private static func terminateProcessGroupAndReap(pid: pid_t) {
    _ = Darwin.kill(-pid, SIGTERM)
    _ = Darwin.kill(pid, SIGTERM)

    var leaderReaped = false
    var status: Int32 = 0

    for _ in 0..<graceStepCount {
      if !leaderReaped, Darwin.waitpid(pid, &status, WNOHANG) == pid {
        leaderReaped = true
      }
      let groupStillAlive = Darwin.kill(-pid, 0) == 0
      if leaderReaped && !groupStillAlive {
        return
      }
      usleep(graceStepMicroseconds)
    }

    _ = Darwin.kill(-pid, SIGKILL)
    _ = Darwin.kill(pid, SIGKILL)

    if !leaderReaped {
      while Darwin.waitpid(pid, &status, 0) < 0 {
        if errno != EINTR {
          break
        }
      }
    }
  }
}
