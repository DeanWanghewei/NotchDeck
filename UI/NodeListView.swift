import SwiftUI

/// 监听端口进程列表：零配置展示所有非系统监听进程，支持结束（SIGTERM）
struct NodeListView: View {
    @ObservedObject var scanner: NodeProcessScanner

    private var processes: [NodeProcessInfo] {
        scanner.processes
    }

    /// 固定行高与可见行数：高度可精确计算，避免 ScrollView 与动态窗口高度的反馈循环
    private let rowHeight: CGFloat = 34
    private let rowSpacing: CGFloat = 2
    private let maxVisibleRows = 8

    /// 列表固定高度 = 可见行数 × 行高 + 行距，超出部分在固定视口内滚动
    private var listHeight: CGFloat {
        let visible = max(1, min(processes.count, maxVisibleRows))
        return CGFloat(visible) * rowHeight + CGFloat(max(0, visible - 1)) * rowSpacing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if processes.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, minHeight: 72)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: rowSpacing) {
                        ForEach(processes) { process in
                            row(process)
                                .frame(height: rowHeight)
                        }
                    }
                    .padding(1)
                }
                .frame(height: listHeight)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("监听端口")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(scanner.processes.count)")
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.2)))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("暂无监听端口的进程")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("显示当前用户所有监听 TCP 端口的进程（系统守护进程除外）")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func row(_ process: NodeProcessInfo) -> some View {
        HStack(spacing: 10) {
            Text(":\(process.port)")
                .font(.system(size: 11, weight: .semibold).monospaced())
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.blue.opacity(0.2)))
                .foregroundStyle(.blue)
                .help("监听端口 \(process.port)")
            VStack(alignment: .leading, spacing: 1) {
                Text(process.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("PID \(process.pid) · \(process.executableName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(String(format: "%.1f%%", process.cpuPercent))
                .font(.caption.monospaced())
                .foregroundStyle(process.cpuPercent > 80 ? .orange : .secondary)
                .frame(width: 48, alignment: .trailing)
                .help("CPU \(String(format: "%.1f%%", process.cpuPercent))")
            Text(String(format: "%.0f MB", process.memoryMB))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
                .help("内存 \(String(format: "%.1f MB", process.memoryMB))")
            Button {
                NodeProcessKiller.terminate(pid: process.pid)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    scanner.scan()
                }
            } label: {
                Image(systemName: "xmark.bin")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ScalingButtonStyle())
            .help("结束进程（SIGTERM）")
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .contentShape(Rectangle())
        .help(process.commandLine)
    }
}
