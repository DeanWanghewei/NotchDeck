# NotchDeck 插件市场

插件市场与应用在同一个 GitHub 仓库维护。应用设置 → **插件市场** 以名称、简介与状态列表展示插件；进入详情后提供添加、设置、移除、使用说明与源码入口；首个插件是 [订阅额度](../docs/subscription-quotas.md)。

## 目录与分发

- [`catalog.json`](catalog.json)：面向已发布客户端的公开目录，原生插件版本与最低应用版本不得超过最新正式版已交付的内容。
- [`bundled-catalog.json`](bundled-catalog.json)：当前源码对应的随附目录，开发新功能时更新此文件。两份目录字段相同：插件 id、名称、介绍、版本、最低应用版本和文档/源码链接；schemaVersion 2 起可声明**适配脚本**（`script.url` / `script.sha256` / `script.version`）。
- [`../Modules/MarketplacePlugins.swift`](../Modules/MarketplacePlugins.swift)：随应用编译的可信 Swift 实现及版本。
- 应用打包时将 `bundled-catalog.json` 放进资源，全新安装可离线浏览和添加。
- “检查更新”只读 `main/marketplace/catalog.json`，成功后缓存到本机；失败保留已有目录。启动不自动联网；打开市场页且距上次成功检查或上次自动尝试超过 1 小时，会**静默自动刷新一次**（失败不提示、不更新检查时间），手动刷新不受节流且失败照常提示。
- 这一阶段提供**随应用发布的 Swift 插件**。添加将本机已有实现注册并启用；移除停止并取消注册，保留配置、凭据与已安装脚本。新实现和插件版本升级需要更新 NotchDeck，不从目录下载或运行 Swift / 动态库 / shell。
- 插件声明可用区域、默认位置和展示样式，用户可在模块管理或插件设置中覆盖。首个订阅额度插件支持顶部常驻 / 标签页 / 底部常驻，以及百分比长条 / 百分比圆环 / 紧凑长条，支持 GLM / Codex / MiniMax 多账号与可选别名。布局声明和实际视图由随附 Swift 实现决定；目录中的功能说明用于介绍。
- 详情页分别展示本机与目录版本。目录版本高于本机时，明确引导下载新版 NotchDeck、替换应用并重启；未提供的功能不可直接安装，但本机随附且兼容的旧版仍可添加、重新添加、设置与移除。不得仅因远端要求较高而禁用本机版本。

远端目录缺项时补入应用随附目录，避免已有插件失去管理入口；旧缓存也不会把随附的新版本降级；原生目录较旧但解析适配版本更新时，仍独立合并适配更新。应用回退版本后，无法识别的已添加插件仍保留移除入口。已有“订阅额度”配置会在首次升级时迁移为已添加；用户明确移除后，不会因保留的配置再次自动添加。移除与删除密钥分开：GLM 密钥在插件设置中单独删除。

## 适配脚本：唯一的应用内更新物

条目声明的 `script` 指向本仓库 raw 地址的 JavaScript 适配脚本（首个为 [`scripts/subscriptions-glm.js`](scripts/subscriptions-glm.js)，负责 GLM 额度接口的请求声明与响应解析）。安全边界：

- 下载仅在用户点击“安装解析适配/更新解析适配”时发生；传输策略与目录刷新一致（固定来源、拒绝重定向、256 KiB 上限、无 Cookie），下载内容与目录 `sha256` 逐字节比对，通过后原子落盘到应用 Data 目录 `NotchDeck/Plugins/<插件id>/`（目录 0700、文件 0600），每次加载再复验哈希，篡改即视为未安装。
- 脚本运行在 **JavaScriptCore 沙箱**：无网络、无文件、无进程能力，只产出“请求模板 + 解析函数”。凭据由宿主在发送前一刻替换请求头中的 `{credential}` 占位，**脚本永远拿不到密钥明文**；脚本声明的请求主机必须在宿主白名单（`open.bigmodel.cn` / `api.z.ai` / `dev.bigmodel.cn`）内，防止被诱导外发凭据。
- 更新成功后广播热加载通知，模块立即用新脚本刷新，**无需重装或重启应用**；脚本解析失败时同一响应自动回退内置 Swift 解析并在插件设置页提示，可用“停用脚本”开关强制内置。
- 远端元数据始终不能指定执行文件、命令或新的工厂；脚本本身也不落任何凭据。

## 通过 GitHub 维护

介绍、功能说明、文档链接可以直接通过 PR 修改 `catalog.json` 和文档；合并到 main 后，用户点击“检查更新”即可获取。不要仅修改目录版本号宣称发布了新代码。

**只改适配脚本（无需发版应用）**：

1. 修改 [`scripts/subscriptions-glm.js`](scripts/subscriptions-glm.js)，保持契约：全局 `adapter` 暴露 `request`（url + headers，可含 `{credential}` 占位）与 `parse(body)`（返回 `{ plan, windows: [{ title, usedPercent, resetsAtMs }] }`，认证失败抛 message 含 `signInRequired` 的异常）。
2. `shasum -a 256` 重新计算脚本哈希，连同 `script.version` 一起更新到 `catalog.json`，同步 `bundled-catalog.json` 的脚本字段；不要提升原生插件版本或最低应用版本。
3. 测试会加载真实脚本与内置解析逐字段比对（`Tests/SubscriptionQuotaTests.swift`），必须同步更新 fixture 后全量测试通过。
4. 合并 PR 后，用户打开插件市场即见“适配可更新”，点击按钮即刻生效。

新增插件或修改实现：

1. 按 [组件开发约定](../docs/module-development.md) 实现 `NotchModule`、独立设置和测试。
2. 在 `MarketplacePlugins.implementations` 注册稳定 id、实现版本和工厂。不要同时加入 `BuiltInModules`。
3. 在 `bundled-catalog.json` 添加同 id 条目，`version` 与工厂一致，`minimumAppVersion` 为首次随附该实现的应用版本。发版时同步 bump `project.yml`。
4. 添加中文使用文档与源码链接，完成全量测试及深浅色实际视图渲染检查。
5. 通过 PR 审查后合并、发布应用。GitHub Actions 在 PR/main 上测试与打包，只有推送 `v*` 标签才发布 Release；代码合并不等于正式发版。
6. **正式 Release 的安装包可下载后**，再将该标签的 `bundled-catalog.json` 同步到 `catalog.json` 并提交公开目录。可用 `git show <已发布标签>:marketplace/bundled-catalog.json > marketplace/catalog.json` 提取；若期间适配独立发版，保留较新的脚本字段与对应哈希，不回退脚本。旧标签仅有 `catalog.json` 时从该文件提取。不能从领先于正式版的当前工作区直接复制。

CI 用 `scripts/check-marketplace-release.py` 将公开目录与 GitHub 最新正式 Release 标签里的目录比较，拒绝未发布的原生版本、新插件或最低应用版本；独立适配版本不受原生版本限制。首次拆分时，公开目录保持 NotchDeck 0.22.0 / 插件 1.2.0，开发随附目录为 NotchDeck 0.23.0 / 插件 1.3.0。

## 目录格式（schemaVersion = 2，兼容 1）

| 字段 | 约定 |
|---|---|
| `id` | 不可变；小写英文、数字、连字符，最多 64 字符，不得重复 |
| `name` / `summary` / `details` | 中文名称、短介绍、完整介绍；最多 80 / 300 / 4000 字符 |
| `systemImage` / `author` | SF Symbols 图标名与作者；最多 80 字符 |
| `version` / `minimumAppVersion` | 1～3 段纯数字版本（如 `1.0.0` / `0.20.0`），数值比较 |
| `capabilities` | 最多 12 条功能或连接条件，每条最多 200 字符 |
| `documentationURL` / `sourceURL` | 本 GitHub 仓库下的 HTTPS 文档与源码链接 |
| `script`（可选） | `{ url, sha256, version }`：url 限本仓库 `raw.githubusercontent.com` 地址；sha256 为 64 位小写 hex；version 与插件实现版本相互独立 |

目录最多 100 项、256 KiB；不支持的 schema（仅 1、2）、无效字段、重复 id 或外站链接会整份拒绝，继续使用上次目录。远端元数据始终不能指定执行文件、命令或新的工厂。

`Tests/PluginMarketplaceTests.swift` 直接解析打包目录，校验与可信工厂的 id、名称、版本一致，覆盖版本比较、添加/移除/重启、配置迁移、网络失败、缓存、兼容性和关闭后的旧回调失效。验证命令与主工程相同：

```bash
xcodegen generate
xcodebuild -project NotchDeck.xcodeproj -scheme NotchDeck \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```
