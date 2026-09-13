import Darwin
import Foundation

/// PID 会复用，扫描时保留启动时间，结束前再次校验进程身份与归属。
struct ProcessIdentity: Equatable {
    let pid: pid_t
    let uid: uid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    static func read(_ pid: pid_t) -> ProcessIdentity? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessIdentity(pid: pid, uid: info.pbi_uid,
                               startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }
}

enum NodeProcessKiller {
    /// nil 表示已发送 SIGTERM；不对旧 PID、进程组或其他用户的进程发送信号。
    static func terminate(_ identity: ProcessIdentity) -> String? {
        guard identity.pid > 1, identity.pid != getpid(), identity.uid == getuid(),
              ProcessIdentity.read(identity.pid) == identity else {
            return "进程已退出或身份发生变化，请刷新后重试。"
        }
        guard kill(identity.pid, SIGTERM) == 0 else { return String(cString: strerror(errno)) }
        return nil
    }
}
