# NotchDeck

把 MacBook Pro 的刘海变成一个随手可用的信息控制台。

鼠标悬停刘海即展开面板，集成 **音乐播放控制**（Music / Spotify）、**系统资源监控**（CPU / 内存 / 磁盘 / 网络）、**Node.js 进程管理** 三大模块。下载即用，零配置；悬停检测仅读取鼠标坐标，**不需要辅助功能或输入监控权限**。

## 功能

| 模块 | 说明 |
|---|---|
| 触发 | 悬停刘海自动展开（0.2s 延迟，可调）；离开 1s 自动收起；全局快捷键 `⌘⇧I`；菜单栏图标兜底 |
| 音乐 | 封面 / 标题 / 歌手展示，播放 / 暂停 / 上一首 / 下一首，支持 Music 与 Spotify，点击封面跳转 App |
| 系统监控 | CPU、内存、磁盘使用率与网络上传 / 下载速率，每秒刷新，悬停显示详细数值 |
| Node 进程 | 列出监听端口的 Node.js 进程（端口 / 名称 / PID / CPU / 内存），一键 SIGTERM 结束 |
| 设置 | 悬停 / 收起开关与延迟、自定义全局快捷键、开机自启动 |

首次使用音乐控制时，macOS 会弹出一次"自动化"授权（控制 Music / Spotify），允许即可；只读歌曲信息不需要该权限。

## 环境要求

- macOS 13 Ventura 及以上
- 带刘海的 MacBook Pro（无刘海的显示器上可通过快捷键 / 菜单栏图标呼出）
- Xcode 15+（含 SwiftUI macOS 13 SDK）与 [xcodegen](https://github.com/yonaskolb/XcodeGen)

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
│   ├── AppModel.swift             # 可观察状态聚合根
│   ├── NotchWindowController.swift# NSPanel 管理与展开/收起状态机
│   ├── MouseTracker.swift         # 鼠标位置轮询（0.1s），悬停/离开检测
│   ├── HotKeyManager.swift        # Carbon RegisterEventHotKey 全局快捷键
│   └── SettingsStore.swift        # UserDefaults 封装
├── Modules/
│   ├── Music/                     # DistributedNotification + AppleScript
│   ├── System/                    # host_statistics64 / sysctl / getifaddrs
│   └── Node/                      # lsof / ps / kill(SIGTERM)
├── UI/                            # SwiftUI 视图（主面板 / 各模块 / 设置）
└── Resources/Assets.xcassets
```

## 设计要点

- **零权限悬停检测**：`NSEvent.mouseLocation` + Timer 轮询，不监听全局事件
- **NSPanel**：无边框 + `.nonactivatingPanel`，`.statusBar` 层级，主屏顶部居中，展开时从刘海向下"生长"（弹簧动画）
- **性能**：鼠标轮询 0.1s / 次，系统监控 1s / 次，Node 扫描 2s / 次（后台队列），空闲开销极低
- **安全**：不收集任何数据，所有监控仅本地处理
