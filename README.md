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
| 媒体 | 封面/标题/进度/播放控制，支持 Music 与 Spotify（仅对已安装的 App 发起，绝不弹"选择应用"）；系统允许时自动启用系统级"正在播放"通道，覆盖浏览器视频等任意媒体源 |
| 音量 | 系统音量滑杆 + 静音切换，无需权限 |
| 系统监控 | CPU、内存、磁盘使用率与网络速率，每秒刷新，悬停显示详细数值 |
| Node 进程 | 监听端口的 Node.js 进程列表（端口/脚本/PID/CPU/内存），一键 SIGTERM，退出自动移除 |
| 自定义 | 用户添加 shell 命令小部件（如 `ipconfig getifaddr en0`），面板展开时自动执行并展示输出 |

首次使用媒体模块会弹一次 macOS"自动化"授权（控制 Music/Spotify），允许即可；拒绝仅影响媒体模块，其余功能不受影响。

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
│   ├── Media/                     # 媒体：MediaRemote 桥接（探测式）+ AppleScript
│   ├── Volume/                    # 音量：StandardAdditions 脚本
│   ├── System/                    # 系统监控：host_statistics64 / sysctl / getifaddrs
│   ├── Node/                      # Node 进程：lsof / ps / kill(SIGTERM)
│   └── Custom/                    # 自定义命令小部件
├── UI/                            # SwiftUI 视图（面板 / 标签栏 / 各模块 / 设置）
└── Resources/Assets.xcassets
```

## 设计要点

- **零权限悬停检测**：`NSEvent.mouseLocation` + Timer 轮询，不监听全局事件
- **不碰刘海**：面板悬浮于菜单栏下方（留 6pt 间距），完全不覆盖刘海/菜单栏
- **媒体兼容策略**：MediaRemote（系统级正在播放）在启动时探测，系统放行才启用；
  否则回退 AppleScript，且仅对已安装的 Music/Spotify 发起，避免"定位应用"弹窗
- **性能**：鼠标轮询 0.1s / 次，系统监控 1s / 次，Node 扫描 2s / 次（后台队列），空闲开销极低
- **安全**：不收集任何数据，所有监控仅本地处理
