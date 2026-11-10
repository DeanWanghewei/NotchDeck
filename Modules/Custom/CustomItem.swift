import Foundation

// MARK: - 自定义子项模型

/// 用户自定义的命令小部件：执行 shell 命令并展示输出
struct CustomItem: Codable, Identifiable, Equatable {
    /// 展示方式：text = 原样显示输出；heatmap = 输出解析为数值序列后按大小着色
    enum Display: String, Codable, Equatable {
        case text
        case heatmap
    }

    var id = UUID().uuidString
    var name = ""
    var command = ""
    var display: Display = .text
}

/// 旧版本持久化数据没有 display 字段，缺失或损坏时回退默认值而不是整体丢弃
extension CustomItem {
    private enum CodingKeys: String, CodingKey {
        case id, name, command, display
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        display = try container.decodeIfPresent(Display.self, forKey: .display) ?? .text
    }
}

// MARK: - 自定义子项示例模板

/// 设置页「示例模板」的数据源；同时作为命令写法的活文档，
/// 完整规则与更多变体见 docs/custom-items.md。
enum CustomItemPresets {
    /// 模板分类：设置页按此顺序分组展示，rawValue 直接用作分组标题
    enum Category: String, CaseIterable, Codable, Equatable {
        case system = "系统"
        case network = "网络"
        case development = "开发"
        case general = "通用"
    }

    struct Preset: Identifiable, Equatable {
        let id: String
        let name: String
        let command: String
        let display: CustomItem.Display
        let category: Category
        let note: String

        var item: CustomItem { CustomItem(name: name, command: command, display: display) }
    }

    /// 覆盖文本 / 热力图 × 单值 / 多值 / 失败标红 / 需认证几类写法，按场景分四组；
    /// 除「先登录再取数」与带占位符的模板外，其余添加即可用。
    /// 约定：含管道的命令必须以 `set -o pipefail; ` 前置，否则上游失败会被管道吞掉、显示成成功。
    static let all: [Preset] = [
        // MARK: 系统
        Preset(id: "disk", name: "磁盘占用",
               command: "set -o pipefail; df / | tail -1 | awk '{print $5}'", display: .heatmap,
               category: .system,
               note: "输出如 78%（百分号可识别）；单值随探测累积为趋势"),
        Preset(id: "top-cpu", name: "CPU 前几名进程",
               command: "set -o pipefail; ps -eo %cpu= | sort -nr | sed -n '1,8p'", display: .heatmap,
               category: .system,
               note: "多值示例：一次输出多个数字，整体渲染为一屏方格；只取 %cpu= 一列，带上 pid=、comm= 时进程名里的数字（如 Python 3.12）会混进热力图"),
        Preset(id: "cpu-total", name: "CPU 总占用",
               command: "set -o pipefail; top -l 2 -n 0 | awk -F'[,%]' '/CPU usage/ {idle=$5} END {if (idle == \"\") exit 1; printf \"%d\\n\", 100 - idle}'",
               display: .heatmap,
               category: .system,
               note: "整机 CPU 占用百分比（整数）；取两次采样之间的差值，比单次采样准"),
        Preset(id: "memory-usage", name: "内存占用百分比",
               command: "set -o pipefail; vm_stat | awk -F': ' -v total=\"$(sysctl -n hw.memsize)\" 'NR==1 {gsub(/[^0-9]/,\"\",$0); page=$0} /^Anonymous pages:/ {gsub(/[^0-9]/,\"\",$2); a=$2} /^Pages wired down:/ {gsub(/[^0-9]/,\"\",$2); w=$2} /^Pages occupied by compressor:/ {gsub(/[^0-9]/,\"\",$2); c=$2} END {if (a == \"\" || total == \"\" || page == \"\") exit 1; printf \"%d\\n\", (a+w+c)*page*100/total}'",
               display: .heatmap,
               category: .system,
               note: "已用内存百分比（匿名页 + 联动 + 压缩，近似活动监视器）；页大小从 vm_stat 首行动态取，不写死 4096"),
        Preset(id: "disk-free", name: "磁盘剩余空间",
               command: "set -o pipefail; df -k / | awk 'NR==2 {printf \"%d\\n\", $4/1024/1024}'", display: .heatmap,
               category: .system,
               note: "根卷剩余空间（GB，整数）；热力图只按数值大小着色，剩余越多颜色越深，不代表好坏"),
        Preset(id: "battery-level", name: "电池电量",
               command: "set -o pipefail; pmset -g batt | awk '/InternalBattery/ {for (i=1;i<=NF;i++) if ($i ~ /%;/) {gsub(/[^0-9.]/,\"\",$i); print $i; exit}}'",
               display: .heatmap,
               category: .system,
               note: "电池电量百分比；台式机没有电池时命令成功但无数字，显示「未解析到数字」，不会补 0"),

        // MARK: 网络
        Preset(id: "local-ip", name: "本机 IP",
               command: "ipconfig getifaddr en0", display: .text,
               category: .network,
               note: "文本：命令输出原样显示"),
        Preset(id: "public-ip", name: "公网 IP",
               command: "curl -s --max-time 4 https://api.ipify.org", display: .text,
               category: .network,
               note: "文本：curl 直接取公网地址"),
        Preset(id: "latency", name: "服务响应速度",
               command: "curl -sfo /dev/null -w '%{time_total}' --connect-timeout 2 --max-time 5 https://www.apple.com/",
               display: .heatmap,
               category: .network,
               note: "把地址换成自己的服务（如 http://boom-fn:5666/）：越慢颜色越深，无法访问显示红色"),
        Preset(id: "dns-lookup", name: "DNS 解析耗时",
               command: "curl -sfo /dev/null -w '%{time_namelookup}' --connect-timeout 2 --max-time 5 https://www.apple.com/",
               display: .heatmap,
               category: .network,
               note: "把域名换成你要监控的站点；数值是域名解析耗时（秒），越小越好"),
        Preset(id: "ping-loss", name: "Ping 丢包率",
               command: "set -o pipefail; ping -c 3 -W 1000 1.1.1.1 | grep -o '[0-9.]*% packet loss' | cut -d% -f1",
               display: .heatmap,
               category: .network,
               note: "把地址换成要监控的主机；3 个包约 2~3 秒；目标不可达时 ping 非 0 退出 → 红色失败方格"),

        // MARK: 开发
        Preset(id: "git-status", name: "Git 分支与改动",
               command: "set -o pipefail; repo=\"$HOME/Projects/my-repo\"; branch=$(git -C \"$repo\" rev-parse --abbrev-ref HEAD) || exit 1; dirty=$(git -C \"$repo\" status --porcelain | wc -l | tr -d ' '); printf '%s（改动 %s 个文件）\\n' \"$branch\" \"$dirty\"",
               display: .text,
               category: .development,
               note: "必须把 $HOME/Projects/my-repo 换成你的仓库目录；输出当前分支与未提交改动文件数"),
        Preset(id: "port-listening", name: "本地端口监听",
               command: "if lsof -nP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1; then printf '8080 端口监听中\\n'; else printf '8080 端口未监听\\n'; fi",
               display: .text,
               category: .development,
               note: "必须把 8080 换成你的端口；文本显示监听状态，不进热力图"),
        Preset(id: "docker-running", name: "Docker 运行容器数",
               command: "set -o pipefail; docker ps --filter status=running --format '{{.Names}}' | wc -l | tr -d ' '",
               display: .heatmap,
               category: .development,
               note: "需要 Docker 已启动；daemon 没运行时命令非 0 退出 → 红色失败方格，不会显示 0"),

        // MARK: 通用
        Preset(id: "auth", name: "先登录再取数（模板）",
               command: "set -o pipefail; TOKEN=$(curl -s -X POST https://api.example.com/login -d 'user=USER&pass=PASS' | grep -o '\"token\":\"[^\"]*\"' | cut -d'\"' -f4); curl -sf -H \"Authorization: Bearer $TOKEN\" https://api.example.com/metrics",
               display: .heatmap,
               category: .general,
               note: "模板：替换接口地址、账号与取数字段后再用；第二段带 -f，接口返回 4xx/5xx 才会显示为红色"),
    ]

    /// 分组顺序 = 分类声明顺序，保证设置页分组稳定
    static var categories: [Category] { Category.allCases }

    /// 某一分类下的模板（保持 all 中的书写顺序）
    static func presets(in category: Category) -> [Preset] {
        all.filter { $0.category == category }
    }
}
