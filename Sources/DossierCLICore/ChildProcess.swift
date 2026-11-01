#if os(macOS)
  import Darwin
  import Foundation
  import Synchronization

  /// The process signals go on to, or 0 before there is one. Atomics are what a signal handler may touch.
  private let signalTarget = Atomic<Int32>(0)
  /// A signal that came before there was a process to pass it to.
  private let pendingSignal = Atomic<Int32>(0)

  /// Sends a pending signal to the command, if there's one of each yet. Both the handler and the
  /// spawning code call this, after setting their half, so a signal arriving during the spawn is
  /// seen by at least one, and sent by exactly one. Only what's async-signal-safe.
  private func passOnPendingSignal() {
    let target = signalTarget.load(ordering: .sequentiallyConsistent)
    guard target > 0 else { return }
    let pending = pendingSignal.exchange(0, ordering: .sequentiallyConsistent)
    if pending != 0 { kill(target, pending) }
  }

  /// Runs a command for `dossier update run`. `posix_spawnp` leaves the child in this process's group
  /// on these streams, so a terminal treats it as it would the command run by itself.
  enum ChildProcess {
    /// Runs a command to its end, with no shell, on this process's standard streams.
    ///
    /// - Parameters:
    ///   - command: The executable, found on `PATH` when it has no slash, and its arguments.
    ///   - standardOutputToError: Sends the command's standard output to standard error.
    /// - Returns: Its exit status, or 128 + the signal that killed it.
    /// - Throws: ``CLIFailure`` when it can't be started.
    static func run(_ command: [String], standardOutputToError: Bool) throws -> Int32 {
      var actions: posix_spawn_file_actions_t?
      posix_spawn_file_actions_init(&actions)
      defer { posix_spawn_file_actions_destroy(&actions) }
      if standardOutputToError { posix_spawn_file_actions_adddup2(&actions, STDERR_FILENO, STDOUT_FILENO) }

      let arguments: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
      let environment: [UnsafeMutablePointer<CChar>?] =
        ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
      defer {
        for pointer in arguments + environment { free(pointer) }
      }

      // A signal this thread has blocked would stay blocked in the command. Dispatch's worker threads
      // block them, so `withUpdate` on one of those would leave a command SIGTERM can't reach.
      var attributes: posix_spawnattr_t?
      posix_spawnattr_init(&attributes)
      defer { posix_spawnattr_destroy(&attributes) }
      var emptyMask = sigset_t()
      sigemptyset(&emptyMask)
      posix_spawnattr_setsigmask(&attributes, &emptyMask)
      posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGMASK))

      let restoreSignals = installSignalHandlers()
      defer { restoreSignals() }

      var pid: pid_t = 0
      let spawned = posix_spawnp(&pid, command[0], &actions, &attributes, arguments, environment)
      guard spawned == 0 else {
        throw CLIFailure(
          "command-not-run", "can't run \(command[0]): \(String(cString: strerror(spawned)))",
          status: spawned == ENOENT ? 127 : 126)
      }
      signalTarget.store(pid, ordering: .sequentiallyConsistent)
      defer { signalTarget.store(0, ordering: .sequentiallyConsistent) }
      passOnPendingSignal()

      var status: Int32 = 0
      while waitpid(pid, &status, 0) == -1 {
        guard errno == EINTR else {
          throw CLIFailure("command-lost", "can't wait for \(command[0]): \(String(cString: strerror(errno)))")
        }
      }
      let signal = status & 0x7F
      return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }

    /// While the command runs, this process stays to remove the marker. The handlers keep the signals
    /// from ending it, and, unlike ignoring them, are reset to the default in the child by `exec`.
    /// A signal this process was already ignoring, as under `nohup`, stays ignored by both.
    ///
    /// SIGTERM and SIGHUP are sent to one process, and go on to the command. SIGINT and SIGQUIT come
    /// from the terminal to the whole foreground group, the command included, so aren't sent twice:
    /// many tools read a second one as "stop at once".
    private static func installSignalHandlers() -> () -> Void {
      pendingSignal.store(0, ordering: .sequentiallyConsistent)
      var restore: [(Int32, sig_t?)] = []
      for number in [SIGTERM, SIGHUP, SIGINT, SIGQUIT] {
        let previous = signal(number) { number in
          guard number == SIGTERM || number == SIGHUP else { return }
          pendingSignal.store(number, ordering: .sequentiallyConsistent)
          passOnPendingSignal()
        }
        if unsafeBitCast(previous, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self) {
          signal(number, SIG_IGN)
        } else {
          restore.append((number, previous))
        }
      }
      return {
        for (number, handler) in restore { signal(number, handler) }
      }
    }
  }
#endif
