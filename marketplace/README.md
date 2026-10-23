# NotchDeck 插件市场

插件市场与应用在同一个 GitHub 仓库维护。应用设置 → **插件市场** 提供目录、添加、移除、使用说明与源码入口；首个插件是 [订阅额度](../docs/subscription-quotas.md)。

## 目录与分发

- [`catalog.json`](catalog.json)：插件 id、名称、介绍、版本、最低应用版本和文档/源码链接。
- [`../Modules/MarketplacePlugins.swift`](../Modules/MarketplacePlugins.swift)：随应用编译的可信 Swift 实现及版本。
- 应用打包时将 `catalog.json` 放进资源，全新安装可离线浏览和添加。
- “刷新目录”只读 `main/marketplace/catalog.json`，成功后缓存到本机；失败保留已有目录。启动和打开市场都不会自动联网。
- 这一阶段提供**随应用发布的 Swift 插件**。添加将本机已有实现注册并启用；移除停止并取消注册，保留配置与凭据。新实现和插件版本升级需要更新 NotchDeck，不从目录下载或运行 Swift / 动态库 / shell。
- 插件声明可用区域、默认位置和展示样式，用户可在模块管理或插件设置中覆盖。首个订阅额度插件支持顶部常驻 / 标签页 / 底部常驻，以及用量卡片 / 紧凑列表。布局声明和实际视图由随附 Swift 实现决定；目录中的功能说明用于介绍。
- 刷新后遇到未知插件、目录版本高于本机实现、最低应用版本不满足时，提示获取新版，不能直接添加。已添加的旧版仍可运行与移除。

远端目录缺项时补入应用随附目录，避免已有插件失去管理入口；旧缓存也不会把随附的新版本降级。应用回退版本后，无法识别的已添加插件仍保留移除入口。已有“订阅额度”配置会在首次升级时迁移为已添加；用户明确移除后，不会因保留的配置再次自动添加。移除与删除密钥分开：GLM 密钥在插件设置中单独删除。

## 通过 GitHub 维护

介绍、功能说明、文档链接可以直接通过 PR 修改 `catalog.json` 和文档；合并到 main 后，用户点击“刷新目录”即可获取。不要仅修改目录版本号宣称发布了新代码。

新增插件或修改实现：

1. 按 [组件开发约定](../docs/module-development.md) 实现 `NotchModule`、独立设置和测试。
2. 在 `MarketplacePlugins.implementations` 注册稳定 id、实现版本和工厂。不要同时加入 `BuiltInModules`。
3. 在 `catalog.json` 添加同 id 条目，`version` 与工厂一致，`minimumAppVersion` 为首次随附该实现的应用版本。发版时同步 bump `project.yml`。
4. 添加中文使用文档与源码链接，完成全量测试及深浅色实际视图渲染检查。
5. 通过 PR 审查后合并、发布应用。现有 GitHub Actions 在 PR/main 上测试与打包，只有推送 `v*` 标签才发布 Release。

## 目录格式（schemaVersion = 1）

| 字段 | 约定 |
|---|---|
| `id` | 不可变；小写英文、数字、连字符，最多 64 字符，不得重复 |
| `name` / `summary` / `details` | 中文名称、短介绍、完整介绍；最多 80 / 300 / 4000 字符 |
| `systemImage` / `author` | SF Symbols 图标名与作者；最多 80 字符 |
| `version` / `minimumAppVersion` | 1～3 段纯数字版本（如 `1.0.0` / `0.20.0`），数值比较 |
| `capabilities` | 最多 12 条功能或连接条件，每条最多 200 字符 |
| `documentationURL` / `sourceURL` | 本 GitHub 仓库下的 HTTPS 文档与源码链接 |

目录最多 100 项、256 KiB；不支持的 schema、无效字段、重复 id 或外站链接会整份拒绝，继续使用上次目录。远端元数据始终不能指定执行文件、命令或新的工厂。

`Tests/PluginMarketplaceTests.swift` 直接解析打包目录，校验与可信工厂的 id、名称、版本一致，覆盖版本比较、添加/移除/重启、配置迁移、网络失败、缓存、兼容性和关闭后的旧回调失效。验证命令与主工程相同：

```bash
xcodegen generate
xcodebuild -project NotchDeck.xcodeproj -scheme NotchDeck \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```
