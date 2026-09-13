# NotchDeck

把 MacBook Pro 的刘海变成一个随手可用的信息控制台。

鼠标悬停刘海即展开**悬浮岛屿面板**，内容模块化组织：顶部**常驻区** + 底部**标签页区**，支持媒体控制、系统监控、Node 进程管理、音量控制与用户自定义命令小部件。悬停检测仅读取鼠标坐标，**不需要辅助功能或输入监控权限**。

## 功能

### 面板与交互
- 悬停刘海自动展开（0.2s 延迟，可调 0.1~0.5s）；鼠标离开 1s 自动收起（可调 0.5~2s）
- 全局快捷键 `⌘⇧I`（可自定义录制）、菜单栏图标兜底（右键菜单含设置/退出）
- 悬浮岛屿样式：四角大圆角卡片悬浮于菜单栏下方，**不覆盖、不加宽刘海**；高度随内容动态变化
- 上下两层布局：常驻区（空则不占位）+ 标签页区（多模块图标切换）

### 模块（可在设置中开启/关闭、配置常驻或切换）
| 模块 | 说明 |
|---|---|
| 媒体 | 封面/标题/进度/播放控制。媒体源由用户在设置中添加（Music / Spotify），**添加哪个才请求哪个的授权**，未安装的源不会出现在列表中 |
| 应用 | 用户从**已安装应用选择器**中挑选常用 App 添加到面板：一键启动/退出、运行状态，白名单应用带"已适配"标记（当前适配 Music、Spotify）。零权限（NSWorkspace 实现） |
| 音量 | 系统音量滑杆 + 静音切换，无需权限 |
| 系统监控 | CPU、内存、磁盘使用率与网络速率，每秒刷新，悬停显示详细数值 |
| 进程监控 | **零配置**列出当前用户所有监听 TCP 端口的进程（系统守护进程除外）：App 名/脚本名智能展示、PID/CPU/内存、一键 SIGTERM、退出自动移除 |
| 自定义 | 用户添加 shell 命令小部件（如 `ipconfig getifaddr en0`），面板展开时自动执行并展示输出 |

### 已适配白名单
`Core/ModuleFramework.swift` 中的 `AdaptedApps.whitelist` 记录已深度适配的 App（bundleID → 能力说明）。用户在选择器或设置中看到这些应用时，会显示"已适配"徽章，表示 NotchDeck 为其提供超出启动/退出的集成能力（如媒体播放控制）。扩展适配只需在白名单加一行并实现对应集成逻辑。

### 权限模型（默认最小权限）
- 全新安装启动：**不发起任何 AppleScript、不申请任何权限**，面板完整可用（监控/Node/音量/应用/自定义/交互）
- 媒体模块默认显示"未添加媒体源"引导；用户在设置中开启某个源后，**首次读取才触发该 App 的自动化授权弹窗**，仅此一次，拒绝也只影响该源
- 应用快捷控制走 `NSWorkspace` / `NSRunningApplication`，启动/退出用户自己的应用**无需任何权限**
- 悬停检测仅读取鼠标坐标（`NSEvent.mouseLocation`），无需辅助功能/输入监控权限

## 模块框架

面板是一个模块化框架（`Core/ModuleFramework.swift`）：

```swift
protocol NotchModule: ObservableObject {
    var id: String { get }          // 持久化配置 key
    var title: String { get }       // 名称
    var systemImage: String { get } // SF Symbol 图标
    var isAvailable: Bool { get }   // 不可用时不出现在面板与设置
    associatedtype Content: View
    func content() -> Content       // 面板内容
}
```

实现协议并 `registry.register(module)` 即可获得：设置中的开关与位置配置（常驻/切换）、布局与动画、面板动态高度等全部能力。内置五个模块全部走这套协议；"自定义子项"模块是用户扩展的第一入口，后续可基于此加载更丰富的外部插件。

## 环境要求

- macOS 13 Ventura 及以上
- 带刘海的 MacBook Pro（无刘海的显示器上可通过快捷键 / 菜单栏图标呼出）
- Xcode 15+ 与 [xcodegen](https://github.com/yonaskolb/XcodeGen)

## 构建与运行

```bash
brew install xcodegen        # 首次
xcodegen generate            # 由 project.yml 生成 NotchDeck.xcodeproj
open NotchDeck.xcodeproj     # Xcode 中 ⌘R 运行
```

或纯命令行构建：

```bash
xcodegen generate
xcodebuild -project NotchDeck.xcodeproj -scheme NotchDeck -configuration Debug build
```

> `.xcodeproj` 由 `project.yml` 生成，已加入 .gitignore，修改工程配置请编辑 `project.yml`。

## 工程结构

```
NotchDeck/
├── project.yml                    # xcodegen 工程定义
├── App/
│   ├── NotchDeckApp.swift         # 入口（SwiftUI App + AppDelegate 适配器）
│   └── AppDelegate.swift          # 初始化窗口、菜单栏、快捷键、设置窗口
├── Core/
│   ├── ModuleFramework.swift      # NotchModule 协议 + 注册表（面板框架核心）
│   ├── AppModel.swift             # 单例聚合根：状态 + 模块 + 布局计算
│   ├── NotchWindowController.swift# 悬浮岛屿 NSPanel：状态机 + 动态高度
│   ├── MouseTracker.swift         # 鼠标轮询（0.1s）悬停/离开检测
│   ├── HotKeyManager.swift        # Carbon 全局快捷键
│   ├── SettingsStore.swift        # UserDefaults 封装（含模块配置）
│   └── Shell.swift                # 外部命令执行（带超时）
├── Modules/
│   ├── Media/                     # 媒体：源注册表 + AppleScript（按需授权）
│   ├── Apps/                      # 应用快捷控制 + 已安装应用扫描
│   ├── Volume/                    # 音量：StandardAdditions 脚本
│   ├── System/                    # 系统监控：host_statistics64 / sysctl / getifaddrs
│   ├── Node/                      # Node 进程：lsof / ps / kill(SIGTERM)
│   └── Custom/                    # 自定义命令小部件
├── UI/                            # SwiftUI 视图（面板 / 标签栏 / 各模块 / 设置）
└── Resources/Assets.xcassets
```

## 设计要点

- **最小权限**：默认安装零权限申请；媒体源按需添加、按需授权
- **不碰刘海**：面板悬浮于菜单栏下方（留 6pt 间距），完全不覆盖刘海/菜单栏
- **动画**：展开/收起弹性过渡（缩放+位移动画）、标签页滑动切换、按钮按压缩放反馈；窗口高度随内容动态变化，时长与曲线协调避免"皮筋感"
- **媒体兼容策略**：MediaRemote 私有框架在 macOS 15.4+ 对第三方静默不应答且符号 ABI 已变化（ForOrigin 变体，错误调用会段错误），故不接入；媒体源走 AppleScript 注册表（`MediaModule.knownSources`），扩展新 App 只需加一行
- **性能**：鼠标轮询 0.1s / 次，系统监控 1s / 次，Node 扫描 2s / 次（后台队列），空闲开销极低
- **安全**：不收集任何数据，所有监控仅本地处理
