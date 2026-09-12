import Darwin

/// 结束 Node 进程：直接发送 SIGTERM
enum NodeProcessKiller {
    @discardableResult
    static func terminate(pid: pid_t) -> Bool {
        kill(pid, SIGTERM) == 0
    }
}
