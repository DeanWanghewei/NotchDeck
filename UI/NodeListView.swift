import SwiftUI

/// Node 进程列表：端口、名称、PID、CPU/内存占用，支持结束进程（SIGTERM）
struct NodeListView: View {
    @EnvironmentObject private var app: AppModel

    private var processes: [NodeProcessInfo] {
        Array(app.node.processes.prefix(10))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Node 进程")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(app.node.processes.count)")
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
            }
            if processes.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, minHeight: 72)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 2) {
                        ForEach(processes) { process in
                            row(process)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("未发现监听端口的 Node.js 进程")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                Text("PID \(process.pid)")
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
                    app.node.scan()
                }
            } label: {
                Image(systemName: "xmark.bin")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("结束进程（SIGTERM）")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .help(process.commandLine)
    }
}
