import SwiftUI

/// 监听端口进程：块状网格 / 行列表两种展示（可在面板头部或设置中切换），
/// 可按 App 进程 / 脚本进程过滤；由面板统一滚动
struct NodeListView: View {
    @ObservedObject var scanner: NodeProcessScanner
    @ObservedObject var settings = SettingsStore.shared
    @State private var terminationError: String?

    private var filtered: [NodeProcessInfo] {
        scanner.processes.filter { process in
            process.isAppProcess ? settings.showAppProcesses : settings.showScriptProcesses
        }
    }

    private let cardHeight: CGFloat = 96
    private let rowHeight: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if filtered.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, minHeight: 96)
            } else {
                if settings.processDisplay == "grid" {
                    grid
                } else {
                    rows
                }
            }
        }
        .alert("无法结束进程", isPresented: Binding(
            get: { terminationError != nil },
            set: { if !$0 { terminationError = nil } })) {
                Button("好", role: .cancel) { terminationError = nil }
            } message: {
                Text(terminationError ?? "")
            }
    }

    // MARK: - 头部（计数 + 展示方式切换）

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("监听端口")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: "\(filtered.count)")
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.2)))
            Spacer()
            Picker("展示方式", selection: $settings.processDisplay) {
                Image(systemName: "square.grid.2x2").tag("grid").help("块状展示")
                Image(systemName: "list.bullet").tag("list").help("列表展示")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 64)
            .controlSize(.mini)
        }
    }

    // MARK: - 块状网格

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10)],
                  spacing: 10) {
            ForEach(filtered) { process in
                card(process)
            }
        }
    }

    private func card(_ process: NodeProcessInfo) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 5) {
                Text(verbatim: ":\(process.port)")
                    .font(.system(size: 15, weight: .bold).monospaced())
                    .foregroundStyle(.blue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !process.isAppProcess {
                    Text("脚本")
                        .font(.system(size: 8, weight: .medium))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button {
                    kill(process)
                } label: {
                    Image(systemName: "xmark.bin")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(ScalingButtonStyle())
                .help("结束 PID \(process.pid)（SIGTERM）")
            }
            Text(process.displayName)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .help(process.displayName)
            HStack(spacing: 6) {
                Label(process.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—", systemImage: "cpu")
                Label(process.memoryMB.map { String(format: "%.0fM", $0) } ?? "—", systemImage: "memorychip")
            }
            .font(.system(size: 9))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: cardHeight, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .help(process.commandLine.isEmpty ? process.displayName : process.commandLine)
    }

    // MARK: - 行列表

    private var rows: some View {
        VStack(spacing: 2) {
            ForEach(filtered) { process in
                row(process)
                    .frame(height: rowHeight)
            }
        }
    }

    private func row(_ process: NodeProcessInfo) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: ":\(process.port)")
                .font(.system(size: 11, weight: .semibold).monospaced())
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.blue.opacity(0.2)))
                .foregroundStyle(.blue)
                .help("监听端口 \(process.port)")
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(process.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if !process.isAppProcess {
                        Text("脚本")
                            .font(.system(size: 8, weight: .medium))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                            .foregroundStyle(.orange)
                    }
                }
                Text(verbatim: "PID \(process.pid) · \(process.executableName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            // 指标缺失（ps 不可用）时显示占位「—」，不用 0.0% 冒充真实读数；
            // 橙色警示沿用全项目统一阈值 0.85（docs/design-conventions.md §1.3），缺失值走次要灰
            Text(process.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—")
                .font(.caption.monospaced())
                .foregroundStyle(process.cpuPercent.map { $0 > 85 } == true ? .orange : .secondary)
                .frame(width: 44, alignment: .trailing)
                .help(process.cpuPercent.map { "CPU \(String(format: "%.1f%%", $0))" } ?? "CPU 不可用")
            Text(process.memoryMB.map { String(format: "%.0f MB", $0) } ?? "—")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
                .help(process.memoryMB.map { "内存 \(String(format: "%.1f MB", $0))" } ?? "内存不可用")
            Button {
                kill(process)
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

    private func kill(_ process: NodeProcessInfo) {
        terminationError = NodeProcessKiller.terminate(process.identity)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            scanner.scan()
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
            Text("可在设置中调整 App / 脚本进程的显示过滤")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
