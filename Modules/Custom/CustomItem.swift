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
    struct Preset: Identifiable {
        let id: String
        let name: String
        let command: String
        let display: CustomItem.Display
        let note: String

        var item: CustomItem { CustomItem(name: name, command: command, display: display) }
    }

    /// 覆盖文本 / 热力图 × 单值 / 多值 / 失败标红 / 需认证几类写法；
    /// 除「先登录再取数」需替换占位符外，其余添加即可用。
    static let all: [Preset] = [
        Preset(id: "local-ip", name: "本机 IP",
               command: "ipconfig getifaddr en0", display: .text,
               note: "文本：命令输出原样显示"),
        Preset(id: "public-ip", name: "公网 IP",
               command: "curl -s --max-time 4 https://api.ipify.org", display: .text,
               note: "文本：curl 直接取公网地址"),
        Preset(id: "latency", name: "服务响应速度",
               command: "curl -sfo /dev/null -w '%{time_total}' --connect-timeout 2 --max-time 5 https://www.apple.com/",
               display: .heatmap,
               note: "把地址换成自己的服务（如 http://boom-fn:5666/）：越慢颜色越深，无法访问显示红色"),
        Preset(id: "disk", name: "磁盘占用",
               command: "df / | tail -1 | awk '{print $5}'", display: .heatmap,
               note: "输出如 78%（百分号可识别）；单值随探测累积为趋势"),
        Preset(id: "top-cpu", name: "CPU 前几名进程",
               command: "ps -arcHo %cpu | head -8", display: .heatmap,
               note: "多值示例：一次输出多个数字，整体渲染为一屏方格"),
        Preset(id: "auth", name: "先登录再取数（模板）",
               command: "TOKEN=$(curl -s -X POST https://api.example.com/login -d 'user=USER&pass=PASS' | grep -o '\"token\":\"[^\"]*\"' | cut -d'\"' -f4); curl -s -H \"Authorization: Bearer $TOKEN\" https://api.example.com/metrics",
               display: .heatmap,
               note: "模板：替换成真实接口与账号后再用；适合需要 token 的接口"),
    ]
}
