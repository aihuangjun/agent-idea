import Foundation

/// 起一个脚本进程，边跑边把输出交出来（「运行」窗口用）。`ShellCommand` 是攒完一起返回的，这里要流式。
///
/// 用 `posix_spawn` 而不是 `Process`：要把子进程放进**自己的进程组**，停止时给整组发信号。
/// shell 脚本里起的子进程（`sleep`、开发服务器）收不到发给 bash 的 SIGTERM，只停 bash 的话它们会留下来接着跑。
public final class ScriptProcess: @unchecked Sendable {
    public enum Event: Sendable {
        case output(Data)
        case error(Data)
        /// 进程退出、两根管子都读完了。`signal` 非 nil 表示是被信号停掉的。
        case exited(status: Int32, signal: Int32?)
    }

    /// 停止时先 SIGTERM，这么久还没退就 SIGKILL。
    public static let terminationGrace: TimeInterval = 2
    /// 进程退了、管子却被它留下的孙子进程拿着（后台起的服务）时，等这么久就不等了。
    public static let pipeGraceAfterExit: TimeInterval = 2

    public let pid: pid_t
    private let lock = NSLock()
    private var hasExited = false
    private var exitStatus: (status: Int32, signal: Int32?) = (0, nil)

    private init(pid: pid_t) { self.pid = pid }

    /// 起进程。`onEvent` 在后台线程上回调；`.exited` 一定是最后一个、只来一次。
    public static func start(_ command: ScriptCommand, environment: [String: String],
                             onEvent: @escaping @Sendable (Event) -> Void) throws -> ScriptProcess {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // stdin 接 /dev/null：`input()` 直接读到 EOF，而不是安静地等一个永远不会来的回答
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, command.workingDirectory.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // 自己当组长（pgid = 自己的 pid）；把信号处理恢复成默认、不继承我们屏蔽掉的信号；
        // CLOEXEC_DEFAULT：除了上面 dup2 进去的 0/1/2，我们开着的描述符一个都不漏给子进程（管子的两端也包括在内）
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)
        posix_spawnattr_setflags(&attributes, flags)
        posix_spawnattr_setpgroup(&attributes, 0)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let argv = [command.executable.path] + command.arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let status = withCStrings(argv) { argvPointer in
            withCStrings(envp) { envPointer in
                posix_spawn(&pid, command.executable.path, &actions, &attributes, argvPointer, envPointer)
            }
        }
        // 写端只留给子进程：我们这边不关的话，读端永远等不到 EOF
        close(outPipe[1])
        close(errPipe[1])
        guard status == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw POSIXError(.init(rawValue: status) ?? .EIO)
        }

        let process = ScriptProcess(pid: pid)
        process.watch(out: outPipe[0], err: errPipe[0], onEvent: onEvent)
        return process
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !hasExited
    }

    /// 停掉整个进程组：先 SIGTERM，`terminationGrace` 后还在就 SIGKILL。
    public func stop() {
        guard isRunning else { return }
        kill(-pid, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.terminationGrace) { [self] in
            guard isRunning else { return }
            kill(-pid, SIGKILL)
        }
    }

    private func watch(out: Int32, err: Int32, onEvent: @escaping @Sendable (Event) -> Void) {
        let group = DispatchGroup()
        let finish = Once()

        // 阻塞的 read / waitpid 放 GCD 线程，不占 Swift 并发的协作线程池（理由同 ShellCommand.drain）
        for (descriptor, isError) in [(out, false), (err, true)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                Self.read(descriptor) { onEvent(isError ? .error($0) : .output($0)) }
                group.leave()
            }
        }
        let report: @Sendable () -> Void = { [self] in
            finish.run {
                lock.lock()
                let result = exitStatus
                lock.unlock()
                onEvent(.exited(status: result.status, signal: result.signal))
            }
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) < 0, errno == EINTR {}
            // WIFEXITED / WTERMSIG 是 C 宏，Swift 里展开不了，照 <sys/wait.h> 手算
            let termination = raw & 0x7F
            lock.lock()
            exitStatus = termination == 0 ? ((raw >> 8) & 0xFF, nil) : (128 + termination, termination)
            hasExited = true
            lock.unlock()
            // 进程退了，等管子读完再报；孙子进程拿着管子不放的话，过一会儿也报
            group.notify(queue: .global(qos: .utility)) { report() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.pipeGraceAfterExit) { report() }
        }
    }

    private static func read(_ descriptor: Int32, into sink: (Data) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                sink(Data(buffer[0..<count]))
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        close(descriptor)
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { body() }
        }
    }
}

/// 把 `[String]` 变成以 nil 结尾的 `char *[]`，只在 body 里有效。
private func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer { pointers.forEach { free($0) } }
    return body(pointers)
}
