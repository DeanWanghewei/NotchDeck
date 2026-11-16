# NotchDeck 插件市场接入

官方插件市场已独立到 [DeanWanghewei/NotchDeck-Plugins](https://github.com/DeanWanghewei/NotchDeck-Plugins)。该仓库管理公开目录、插件介绍、使用文档、版本化解析脚本与发布校验；Swift 原生实现继续在本仓库审查、编译和分发。

## 职责与文件

| 位置 | 职责 |
|---|---|
| 独立仓库 `plugins/<id>/manifest.json` | 已发布插件的元数据源 |
| 独立仓库 `catalog.json` | 从 manifest 生成的公开目录，新客户端固定读取 |
| 独立仓库 `adapters/<id>/<version>/*.js` | 版本化脚本，禁止覆盖已有路径 |
| 本仓库 `Modules/MarketplacePlugins.swift` | 随应用编译的可信 Swift 工厂与版本 |
| 本仓库 `marketplace/bundled-catalog.json` | 当前源码对应的离线目录，随应用打包 |
| 本仓库 `marketplace/catalog.json`、`marketplace/scripts/` | 旧客户端兼容入口及脚本测试 fixture，保留原地址 |

原固定的媒体、音量、应用、系统监控、进程监控、自定义、时钟与订阅额度共用市场管理。首次迁移保留启停状态、布局与配置，时钟默认停用；显式移除后重启不会自动恢复，重新添加时启用并沿用配置。

## 添加与发布原生插件

1. 按 [组件开发约定](../docs/module-development.md) 实现 NotchModule、设置、生命周期与测试。
2. 在 MarketplacePlugins 注册工厂及版本，在 bundled-catalog.json 添加条目。新增可选插件不自动添加。
3. 完成全量测试、深浅色实际视图渲染与文档更新，随正式应用安装包发布。
4. 安装包可下载后，将该标签随附目录的对应条目提交到独立仓库的 manifest，并生成公开目录。
5. 独立仓库 CI 对照主应用最新正式 Release 的随附目录与 dmg，检查原生版本、最低应用版本、字段、来源与脚本哈希；通过审查后合并。

不得从领先正式版的 main 工作区直接复制完整目录；原生功能升级必须更新 NotchDeck。公开目录不决定新 Swift 工厂或动态执行文件。远端缺项时客户端补入随附条目，远端版本过高也不妨碍添加本机兼容版本。

## 独立更新适配脚本

在独立仓库新建版本目录，更新 manifest 中的 script.url、script.sha256、script.version；不要改变原生 version 或 minimumAppVersion。维护流程见 [贡献指南](https://github.com/DeanWanghewei/NotchDeck-Plugins/blob/main/CONTRIBUTING.md)。

同步主应用随附目录的脚本字段与测试 fixture，执行真实脚本和内置解析一致性测试。旧版应用不信任新仓库，不能把新脚本 URL 写入旧兼容目录；需要旧版修复时单独维护兼容发布。

## 客户端信任边界

- 公开目录固定读取 `https://raw.githubusercontent.com/DeanWanghewei/NotchDeck-Plugins/main/catalog.json`；文档和源码链接仅允许官方主应用或插件仓库的 HTTPS 地址。
- 新脚本仅允许独立仓库 `main/adapters/` 下的 JavaScript；为旧缓存保留主仓库 `main/marketplace/scripts/`。相似仓库名、路径穿越、编码路径、查询参数与外站均拒绝。
- 下载拒绝重定向，256 KiB 上限，无 Cookie；脚本安装与加载双重 SHA-256 校验。路径白名单在下载层也检查，不能绕过目录直接请求外站。
- JavaScriptCore 沙箱无文件、网络与进程权限，只产出请求模板与解析结果；凭据由宿主在发送前替换，API 主机仍由宿主白名单约束。
- 脚本仅在用户明确安装/更新时下载；解析失败回退内置 Swift，更新成功广播热加载。移除插件停止运行并保留配置、凭据和已安装脚本。
- 应用启动不联网；打开市场页一小时内至多自动检查一次，失败保留目录，手动检查不受节流影响。

## 验证

```sh
xcodegen generate
xcodebuild -project NotchDeck.xcodeproj -scheme NotchDeck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

本仓库 CI 继续校验旧兼容目录未超前于正式安装包；独立仓库 CI 负责新公开目录。市场页面提供官方插件仓库入口。UI 更改须完成 NSHostingView + cacheDisplay 深浅色渲染目检。
