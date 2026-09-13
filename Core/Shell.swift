import Darwin
import Foundation

/// 有界命令执行：独立进程组、硬超时、取消、退出状态及受限输出。
enum Shell {
    enum Completion: Equatable {
        case exited(Int32)
        case timedOut
        case cancelled
        case launchFailed(Int32)
    }

    struct Result {
        let output: String
        let errorOutput: String
        let completion: Completion
        let outputTruncated: Bool
    }

    final class Cancellation {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    @discardableResult
    static func run(_ path: String, arguments: [String], timeout: TimeInterval = 6) -> String? {
        let result = execute(path, arguments: arguments, timeout: timeout)
        guard result.completion == .exited(0) else { return nil }
        return result.output
    }

    static func execute(_ path: String, arguments: [String], timeout: TimeInterval = 6,
                        outputLimit: Int = 256 * 1024, cancellation: Cancellation? = nil) -> Result {
        func failure(_ code: Int32) -> Result {
            Result(output: "", errorOutput: String(cString: strerror(code)),
                   completion: .launchFailed(code), outputTruncated: false)
        }
        guard timeout.isFinite, timeout > 0, outputLimit >= 0 else { return failure(EINVAL) }
        if cancellation?.isCancelled == true {
            return Result(output: "", errorOutput: "", completion: .cancelled, outputTruncated: false)
        }

        var outputPipe: [Int32] = [0, 0]
        var errorPipe: [Int32] = [0, 0]
        guard pipe(&outputPipe) == 0 else { return failure(errno) }
        guard pipe(&errorPipe) == 0 else {
            let code = errno
            outputPipe.forEach { close($0) }
            return failure(code)
        }
        defer {
            close(outputPipe[0])
            close(errorPipe[0])
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        // ps 等工具输出使用稳定的数值格式，避免本地化小数分隔符破坏解析；
        // 必须用 UTF-8 locale：C locale 会把非 ASCII 字节转义成 M- 记法，破坏中文 App 名
        var environment = ProcessInfo.processInfo.environment
        if path == "/bin/ps" || path == "/usr/sbin/lsof" { environment["LC_ALL"] = "en_US.UTF-8" }
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let launchStatus = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&pid, path, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        close(outputPipe[1])
        close(errorPipe[1])
        guard launchStatus == 0 else { return failure(launchStatus) }

        let descriptors = [outputPipe[0], errorPipe[0]]
        for descriptor in descriptors {
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        }
        var buffers = [Data(), Data()]
        var openStreams = [true, true]
        var truncated = false
        var exitStatus: Int32 = 0
        var exited = false
        var completion: Completion?
        let deadline = ProcessInfo.processInfo.systemUptime + timeout

        func drain(_ index: Int) {
            guard openStreams[index] else { return }
            var bytes = [UInt8](repeating: 0, count: 8192)
            // 即使命令持续输出，也必须返回外层循环检查超时与取消。
            for _ in 0..<16 {
                let count = read(descriptors[index], &bytes, bytes.count)
                if count > 0 {
                    let keep = min(count, max(0, outputLimit - buffers[index].count))
                    buffers[index].append(contentsOf: bytes.prefix(keep))
                    truncated = truncated || keep < count
                } else {
                    if count == 0 || (errno != EAGAIN && errno != EINTR) {
                        openStreams[index] = false
                    }
                    break
                }
            }
        }

        while true {
            drain(0)
            drain(1)
            if !exited {
                exited = waitpid(pid, &exitStatus, WNOHANG) == pid
            }
            if exited && !openStreams.contains(true) { break }
            let cancelled = cancellation?.isCancelled == true
            if cancelled || ProcessInfo.processInfo.systemUptime >= deadline {
                completion = cancelled ? .cancelled : .timedOut
                // 杀死本次启动的整个进程组，包含持有管道的子进程；不依赖 SIGTERM 配合。
                kill(-pid, SIGKILL)
                if !exited {
                    while waitpid(pid, &exitStatus, 0) == -1 && errno == EINTR {}
                }
                drain(0)
                drain(1)
                break
            }
            var polls = descriptors.enumerated().map { index, descriptor in
                pollfd(fd: openStreams[index] ? descriptor : -1, events: Int16(POLLIN | POLLHUP), revents: 0)
            }
            _ = poll(&polls, nfds_t(polls.count), 20)
        }
        let signal = exitStatus & 0x7f
        let code = signal == 0 ? (exitStatus >> 8) & 0xff : 128 + signal
        return Result(output: String(decoding: buffers[0], as: UTF8.self),
                      errorOutput: String(decoding: buffers[1], as: UTF8.self),
                      completion: completion ?? .exited(code), outputTruncated: truncated)
    }
}
