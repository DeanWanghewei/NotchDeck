# AGENTS.md — NotchDeck 项目知识库与约束

NotchDeck 是 macOS 刘海信息岛（灵动岛）应用：SwiftUI + 无边框 NSPanel，悬浮/接壤于刘海下方，LSUIElement 无 Dock 图标。xcodegen 工程（`project.yml`），部署目标 macOS 13，零第三方依赖。

## 文档地图

| 文档 | 角色 |
|---|---|
| `README.md` | 产品文档：功能、权限模型、构建与验证命令 |
| `docs/design-conventions.md` | **项目约束**：颜色与数据展示规范（详见下） |
| `docs/custom-items.md` | 自定义命令小部件的用户文档（写法与规则） |
| `docs/macos-notes.md` | 平台实证笔记：各 macOS 版本的窗口/Space/电源陷阱与探针结论（开发参考，README 只留摘要） |
| `docs/PROJECT_REVIEW.md` | 一次性项目检查与修复记录（2026-09-13，历史存档，不随开发更新） |

## 硬约束（改动前必读）

1. **颜色与数据展示**：一切监控类 UI 遵循 `docs/design-conventions.md`。要点：
   - 连续负载（CPU 占用等）用 `HeatScale` 冷→暖色标（低=冷蓝、高=暖红），**禁止**红绿灯式配色；
   - 百分比必须显示数字，不允许只有图形；行式明细 = 标签 + 用量条 + 右对齐数值；
   - 自定义热力图绿色 5 档透明度 `[0.22, 0.42, 0.62, 0.82, 1.0]`，失败 = 实色红，失败色不得与最高值颜色相同；
   - 改颜色/档位必须同步回归测试与该文档。
2. **系统 API**：只走公开 API；GPU / 风扇 / 温度在当前 macOS 不可用是**探针实证**结论（见 `Modules/System/SystemMonitor.swift`、`BatteryAndSwap.swift` 注释），恢复前不得引入私有框架。新增数据源先探针验证（结论写注释），差分/解析做成纯函数并配测试。
3. **最小权限**：默认安装零权限申请；媒体源按需授权；悬停检测只用鼠标坐标。
4. **验证门槛**：`xcodegen generate && xcodebuild -project NotchDeck.xcodeproj -scheme NotchDeck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` 全绿（无宿主逻辑测试，不启动主程序）。UI 改动另需深浅两版窗口自渲染截图（`NSHostingView` + `cacheDisplay` 导出 PNG）目检。
5. **结构与风格**：Core（框架）/ Modules（按域分子目录）/ UI（视图）/ Tests 分层；中文注释与文档；注释讲"为什么/约束"，不讲代码在做什么。

## 关键实现锚点

- 模块框架：`Core/ModuleFramework.swift`（`NotchModule` 协议 + 注册表，start/stop 生命周期）
- 面板布局：`Core/PanelLayout.swift`（520 × 580 上限、接壤轮廓、与硬件刘海对齐）
- 系统采样：`Modules/System/SystemMonitor.swift`（后台串行队列、1s、差分基线在 `reset()` 重建）
- 悬停明细交互：`UI/SystemMonitorView.swift`（hover 展开 + 点击固定，离开整体区域才收起）
- 颜色定义：`UI/UIHelpers.swift` 的 `HeatScale`、`UI/CustomItemsView.swift` 的热力图档位

## 发版节奏

功能完成即更新 `README.md` 功能表（涉及颜色/展示时同步 `docs/design-conventions.md`）；`project.yml` 的 `MARKETING_VERSION` 随发版提交一起 bump（提交信息形如 `v0.19：……`）。
