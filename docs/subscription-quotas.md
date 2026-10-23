# GLM / ChatGPT · Codex 订阅额度

“订阅额度”是插件市场的首个可选插件，展示 GLM Coding Plan 和 ChatGPT 订阅关联的 Codex 使用率，全新安装时未添加。它与 API 账户现金余额、ChatGPT 网页聊天消息上限分开处理。

## 先看效果

在设置 → **插件市场** 中找到 **订阅额度**，点击“添加插件”，即可进入组件设置并启用面板内容。首次添加为离线演示，GLM 和 Codex 各显示两条示例周期、已用/剩余百分比和重置时间；面板明确标注“演示数据”。演示不联网，不访问钥匙串或 Codex 登录。

组件设置的“布局与展示”可选择 **顶部常驻 / 标签页 / 底部常驻**，以及 **用量卡片 / 紧凑列表**；模块管理中也可修改。默认在标签页显示用量卡片。紧凑列表减少卡片留白和套餐说明，保留每个周期的用量条、已用/剩余数字、演示或错误状态，重置说明在对应行悬停查看。底部常驻位于标签页下方，随内容滚动；切换位置和样式不重新查询账号。

在市场中可移除插件，停止采集并隐藏模块/设置入口。移除保留配置与密钥，重新添加会恢复；如需删除 GLM 密钥，请先在组件设置中点击“移除密钥”。升级前已配置该组件的用户会自动保留添加状态。插件目录和维护方式见 [marketplace/README.md](../marketplace/README.md)。

进入设置 → 订阅额度，关闭“演示模式”后才查询真实账户。两个服务独立连接；尚未连接的卡片保留引导和官方用量页入口。

## GLM Coding Plan

在组件设置中输入 Coding Plan 密钥，点击“保存并连接”。密钥仅保存到本机钥匙串的 `com.notchdeck.app.subscription-quota` 服务项目，不写入 UserDefaults、日志或命令参数。替换或移除密钥时取消旧查询并清除旧账户快照。

真实查询采用智谱官方 [glm-plan-usage 插件](https://github.com/zai-org/zai-coding-plugins/tree/main/plugins/glm-plan-usage) 的只读接口 `GET https://open.bigmodel.cn/api/monitor/usage/quota/limit`，Authorization 与官方脚本保持一致。客户端固定目标主机，禁用重定向与 Cookie，响应限制 256 KiB，最长 15 秒；不会调用模型推理接口。

当前只接入中国区 `open.bigmodel.cn`。GLM 实时数据依照接口已确认的 `TOKENS_LIMIT` / `TIME_LIMIT` 和 `percentage` 显示“编码额度”/“工具调用”。官方脚本尚无稳定的新版周期、周额度与重置字段契约，所以不会把未知数据强行标成“5 小时/每周”，也不会估算重置时间；完整周期以[官方用量页](https://www.bigmodel.cn/coding-plan/personal/usage)为准。官方套餐周期说明见[套餐概览](https://docs.bigmodel.cn/cn/coding-plan/overview)。

未带凭据的接口探针实测返回 HTTP 200、业务码 1001，组件同时校验业务结果，不把认证失败当成零用量。当前没有真实 GLM 密钥完成端到端额度核验；解析与错误状态用官方字段构造的固定数据测试。

## ChatGPT · Codex

开启“使用本机 Codex 的 ChatGPT 登录”。需已在 Codex CLI 中通过 ChatGPT 账号登录；API Key 登录不能读取订阅额度。NotchDeck 不触发登录、退出登录或切换账号，也不复制 `auth.json` 中的凭据。

组件自动查找 Homebrew / `/usr/local/bin` / `~/.local/bin` 的 Codex，以及 Codex.app / ChatGPT.app 常见内置 CLI 位置。找不到或存在多套登录环境时，在设置中填入希望使用的 **Codex CLI 可执行文件绝对路径**，点击“应用路径”。路径不会作为 shell 命令解析。

每次查询启动临时 `codex app-server`，完成 `initialize` / `initialized` 后仅请求 `account/rateLimits/read`，不创建聊天、执行工具或消耗模型额度。协议见 [OpenAI 官方 App Server 文档](https://learn.chatgpt.com/docs/app-server)。实机使用 codex-cli `0.163.0-alpha.11` 验证握手；本机当前为非 ChatGPT 认证，已确认能正确返回并展示登录提示，尚未核验真实订阅数值。

面板优先取 `rateLimitsByLimitId.codex`，兼容旧版 `rateLimits`。周期名称来自 `windowDurationMins`，重置来自 `resetsAt`，不会假设所有套餐固定为 5 小时或每周。独立模型/代码审查的限额不混入主额度。官方额度查看说明见 [Codex Pricing](https://learn.chatgpt.com/docs/pricing#where-can-i-see-my-current-usage-limits)。

## 刷新与失败状态

- 真实查询在组件启用后每 5 分钟更新；展开面板时距上次查询至少 60 秒才补刷新，也可手动刷新。
- 同一服务不重叠查询。停用、切换演示模式、更换配置或退出应用时取消在途任务；旧回调不能覆盖新状态。
- 查询失败保留当前账户上次成功的数值，并显示错误与上次更新时间；首次失败显示错误引导，不显示虚构的 0%。周期已到只提示“等待刷新”，不自行把额度恢复为满额。
- CLI 查询硬超时 12 秒，输出限制 256 KiB，结束后回收本次子进程。GLM 与 Codex 独立更新，一个失败不阻断另一个。

`Tests/SubscriptionQuotaTests.swift` 覆盖固定响应解析、主额度选择、缺失/认证失败、已用/剩余换算、CLI 握手/超时/取消/输出上限，以及离线演示、密钥替换和旧回调失效。测试使用临时偏好域、内存凭据存储与模拟 CLI，不接触真实账号。
