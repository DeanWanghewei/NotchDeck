# GLM / ChatGPT · Codex 订阅额度

“订阅额度”是插件市场的可选插件，展示多个 GLM Coding Plan 和 ChatGPT · Codex 账号的订阅用量，不代表 API 现金余额或 ChatGPT 网页聊天消息上限。

## 展示与账号管理

在设置 → **插件市场** 中添加 **订阅额度**。首次启用显示明确标注的离线演示，包含 GLM / Codex 各两个示例账号，不访问凭据或网络。添加自己的账号后，关闭“演示模式”才显示真实用量。

“布局与展示”支持 **顶部常驻 / 标签页 / 底部常驻**，以及 **百分比长条 / 百分比圆环 / 紧凑长条**。长条和圆环均显示已用及剩余数字、周期、重置说明，使用同一冷→暖色标。紧凑长条的重置时间可悬停查看。切换样式和位置不重新查询账号；旧版 `cards` / `compact` 配置继续有效。

组件设置 → **添加账号** 可多次添加 GLM 或 Codex。别名可留空，未命名时自动显示“GLM 账号 1”“Codex 账号 2”等名称；身份由内部稳定 id 区分，相同别名也不会串用数据。每个账号可以单独停用、编辑或移除，修改别名不重启查询。

删除账号会移除本软件保存的对应凭据，其他账号与原始 auth.json 不受影响。在市场中移除整个插件则只停止运行并保留配置和凭据，重新添加可恢复。

## GLM Coding Plan

添加账号时填写 Coding Plan 密钥，可选别名。每个密钥独立保存在本机钥匙串 `com.notchdeck.app.subscription-quota` 服务下，不写入 UserDefaults、日志或命令参数。编辑已有账号时，新密钥留空表示保留原密钥；替换时只取消该账号查询并清除其旧快照。

采用智谱官方 [glm-plan-usage 插件](https://github.com/zai-org/zai-coding-plugins/tree/main/plugins/glm-plan-usage) 的只读接口 `GET https://open.bigmodel.cn/api/monitor/usage/quota/limit`。固定中国区主机，禁用重定向与 Cookie，响应上限 256 KiB、最长 15 秒，不调用模型推理。

依照接口已确认的 `TOKENS_LIMIT` / `TIME_LIMIT` 和 `percentage` 显示“编码额度”/“工具调用”。当前没有稳定的周期、周额度与重置字段契约，不猜测“5 小时/每周”或估算重置时间；完整周期以[官方用量页](https://www.bigmodel.cn/coding-plan/personal/usage)为准。未带凭据的探针返回 HTTP 200 + 业务码 1001，客户端同时检查业务结果，不将认证失败显示为零用量。

## Codex：导入、验证与独立保存

添加 Codex 账号时，输入或选择该账号的 **auth.json 文件路径**，支持 `~/`、空格及自定义 JSON 文件名。文件需来自 Codex CLI 的 ChatGPT 登录，API Key 登录不能查询订阅额度；可在多份账号备份中分别选择。

点击 **验证并保存** 后：

1. 后台读取指定文件，校验 JSON 和 ChatGPT token 基本结构，上限 256 KiB。
2. 将登录放入权限为 0700 的独立临时 `CODEX_HOME`，auth.json 权限为 0600；强制使用 `cli_auth_credentials_store="file"`，避免回退到当前 CLI 登录或其他账号的钥匙串。临时环境不复制原目录的配置。
3. 用临时 `codex app-server` 完成握手，查询 `account/rateLimits/read`。不创建聊天，不执行工具或调用模型；CLI 自身可能在初始化时读取官方模型/插件目录。
4. **额度验证成功后**，才把该账号登录保存到 NotchDeck 的独立钥匙串项目，账号元数据另行持久化。失败或取消不会添加账号或替换已保存的登录。
5. 后续从钥匙串恢复登录，在隔离环境中查询；CLI 刷新后的 token 保存回同一账号，临时目录随后删除。

因此，切换 Codex 当前账号、移动或删除导入文件、重启 NotchDeck，都不会改变已保存的账号。源文件不被修改，也不需要持续存在。重新导入新文件可以更新某个账号的登录；登录被撤销或过期且无法刷新时，会提示重新导入。网页登录的官方用量页可能使用另一账号，需要自行核对。

组件自动查找 Homebrew、`/usr/local/bin`、`~/.local/bin`、Codex.app / ChatGPT.app 常见 CLI 路径，也可填写可执行文件路径，路径不作为 shell 命令解析。旧版跟随本机 CLI 登录的账号会保留并标记；编辑它并导入 auth.json 后才固定为独立保存的账号。

凭据存储依据 [OpenAI 官方 Authentication 文档](https://developers.openai.com/codex/auth/)，额度协议见 [App Server 文档](https://developers.openai.com/codex/app-server/)。面板优先使用 `rateLimitsByLimitId.codex`，兼容旧版 `rateLimits`；周期来自 `windowDurationMins`，重置来自 `resetsAt`，不混入独立模型或代码审查限额。

## 刷新、迁移与验证边界

- 启用后每 5 分钟刷新；展开面板时距上次查询至少 60 秒才补刷新，也可手动刷新。最多同时查询三个账号，每个账号不重叠，单账号错误不阻断其他账号。
- 停用、移除、更换凭据或切换模式会取消相应任务，旧回调不能覆盖新账号。失败保留该账号上次成功的数值及时间；首次失败不虚构 0%。
- CLI 查询硬超时 12 秒，输出限制 256 KiB，结束或取消后回收子进程和临时凭据目录。
- 旧版 GLM / Codex 开关自动迁移为账号；GLM 继续使用原钥匙串项目，迁移过程不读取凭据。新账号凭据按 id 隔离，UserDefaults 仅保存别名、启用状态和登录是否已导入等元数据。
- 解析、隔离目录、原文件不变、删除源文件后恢复查询、token 轮换、多账号并发、别名与旧配置迁移均有固定数据或模拟 CLI 测试。测试不使用真实账号；目前尚未使用有效 GLM 密钥或 ChatGPT 订阅登录核验端到端实时数值。
