# MiniMax（国内区）Coding Plan / Token Plan 额度查询接口调研

调研时间：2026-11-03。所有 URL 与 JSON 均为逐字摘自下列来源，未经杜撰；
无法从来源直接确认的条目统一标注「未验证」。

## 0. 一句话结论

存在**官方公开文档**的额度查询接口，国内区首选：

```
GET https://api.minimax.cn/v1/token_plan/remains      （官方 CLI 用的 CN base）
GET https://www.minimax.cn/v1/token_plan/remains      （官方 FAQ 文档里的写法）
```

认证用**订阅 Key**（`sk-cp-…`），请求头 `Authorization: Bearer <订阅 Key>`，
**无 body、无 query 参数**。响应 HTTP 200 里嵌 `base_resp.status_code`，
必须自己判断业务码（认证失败时 HTTP 仍是 200，不是 401）。

## 1. 端点清单（已确认）

| 区域 | 端点 | 来源 |
| --- | --- | --- |
| CN（官方 CLI） | `https://api.minimax.cn/v1/token_plan/remains` | mmx-cli npm v1.0.28 `dist/mmx.mjs`：`te={global:"https://api.minimax.io",cn:"https://api.minimax.cn"}`，`quotaEndpoint = ${baseUrl}/v1/token_plan/remains` |
| CN（官方文档） | `https://www.minimax.cn/v1/token_plan/remains` | https://platform.minimax.cn/docs/m-plan/faq.md 「如何查看 M Plan 用量 → 方式三」 |
| CN（旧域名） | `https://api.minimaxi.com/v1/token_plan/remains` | npm `pi-show-minimax-quota` `src/api.ts`；hermes-resetwatch `probe.py` 的 `MINIMAX_CN_TOKEN_PLAN_URL` |
| CN（旧域名 www） | `https://www.minimaxi.com/v1/token_plan/remains` | 本次实测可达 |
| Global | `https://api.minimax.io/v1/token_plan/remains` | mmx-cli `te.global`；PowerUserZ/OpenTokenUsage `docs/providers/minimax.md` |
| Global | `https://www.minimax.io/v1/token_plan/remains` | hermes-resetwatch `MINIMAX_TOKEN_PLAN_URLS` |

官方 FAQ 给出的完整命令（逐字）：

```bash
curl --location 'https://www.minimax.cn/v1/token_plan/remains' \
--header 'Authorization: Bearer <API Key>' \
--header 'Content-Type: application/json'
```

### 1.1 旧版控制台接口（Cookie 鉴权，非 API Key）

仅当拿不到订阅 Key 时才需要；需要浏览器会话 cookie，不适合菜单栏 App。

- `GET https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains?GroupId={group_id}`
  （回退 `https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains`）
  - 认证：网页会话 cookie（`_token`）+ 请求头 `x-group-id: {group_id}`；
    `group_id` 取自 cookie `minimax_group_id_v2`。
  - 来源：PyPI `minimax-remaining-mcp` `src/minimax_remaining_mcp/api.py` / `config.py`。
- `GET https://www.minimax.cn/backend/account/token_plan/remains_percent`
  - 当前国内控制台在用的百分比口径接口；Cookie + `X-Group-Id` 头。
  - 来源：CodexBar `Sources/CodexBarCore/Providers/MiniMax/MiniMaxUsageFetcher.swift`。
- `GET https://www.minimaxi.com/backend/account/token_plan_credit`
  - 套餐池（周维度积分总额）；同样需要网页 cookie。
  - 来源：同上，`config.py: USAGE_API_URL`。

## 2. 请求规格（已确认）

- 方法：`GET`，无 body、无 query 参数（`/v1/token_plan/remains` 不需要 GroupId）。
- 认证头：`Authorization: Bearer <订阅 Key>`。
  - 订阅 Key 前缀 `sk-cp-…`；普通按量计费 Key 前缀 `sk-api-…`，两者**不能混用**。
  - `x-api-key: <key>` 也可用（官方 CLI 探测区域时两种头都试），但不保证所有边缘节点都认。
- 建议附加（第三方客户端一致做法）：
  - `Content-Type: application/json`
  - `Accept: application/json`
  - CodexBar 额外发 `MM-API-Source: CodexBar`（非必需）。

## 3. 响应结构（已确认）

顶层（`/v1/token_plan/remains`）：

```json
{
  "model_remains": [ /* 每个模型桶一条 */ ],
  "base_resp": { "status_code": 0, "status_msg": "success" }
}
```

`model_remains[]` 单条字段：

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `model_name` | string | `"general"`（文本模型）/ `"video"`（视频）/ 具体 model id |
| `current_interval_remaining_percent` | number \| string | **5h 窗口剩余百分比**（服务端已算好） |
| `current_interval_status` | int | `1`=正常，`2`=已耗尽，`3`=不适用/无限 |
| `current_interval_total_count` | int | 5h 总量，实测常为 `0` |
| `current_interval_usage_count` | int | **实为「剩余」计数**（见 §5 陷阱） |
| `start_time` / `end_time` | int | 5h 窗口起止，epoch **毫秒** |
| `remains_time` | int | 距 5h 重置的毫秒数 |
| `current_weekly_remaining_percent` | number \| string | **周窗口剩余百分比** |
| `current_weekly_status` | int | `1`=正常，`3`=无限（官方 CLI 渲染成 `∞`） |
| `current_weekly_total_count` / `current_weekly_usage_count` | int | 周维度计数，常为 `0` |
| `weekly_start_time` / `weekly_end_time` | int | 周窗口起止，epoch 毫秒 |
| `weekly_remains_time` | int | 距周重置的毫秒数 |
| `weekly_boost_permille` | int | 周额度加成，per-mille；`1500` = 150% |
| `interval_boost_permille` | int | 5h 额度加成（拼写也可能是 `interval_boost_permill`） |
| `current_interval_used_percent` / `current_interval_total_percent` | string | 控制台百分比口径变体，形如 `"8%"` / `"100%"` |

套餐级字段（CodexBar 解析路径，可能出现在 `data` 包裹层或根层）：
`current_subscribe_title`、`plan_name`、`combo_title`、`current_plan_title`、
`points_balance`（别名 `point_balance` / `credits_balance` / `credit_balance` / `balance`）。

### 3.1 真实样本（CodexBar 测试固件，逐字）

来源：CodexBar `Tests/CodexBarTests/MiniMaxCurrentTokenPlanResponseTests.swift`

```json
{
  "model_remains": [
    {
      "start_time": 1782043200000,
      "end_time": 1782057600000,
      "remains_time": 7003536,
      "current_interval_total_count": 0,
      "current_interval_usage_count": 0,
      "model_name": "general",
      "current_weekly_total_count": 0,
      "current_weekly_usage_count": 0,
      "weekly_start_time": 1781452800000,
      "weekly_end_time": 1782057600000,
      "weekly_remains_time": 7003536,
      "current_interval_status": 1,
      "current_interval_remaining_percent": 100,
      "current_weekly_status": 1,
      "current_weekly_remaining_percent": 70,
      "weekly_boost_permille": 1500
    },
    {
      "start_time": 1781971200000,
      "end_time": 1782057600000,
      "remains_time": 7003536,
      "current_interval_total_count": 0,
      "current_interval_usage_count": 0,
      "model_name": "video",
      "current_weekly_total_count": 0,
      "current_weekly_usage_count": 0,
      "weekly_start_time": 1781452800000,
      "weekly_end_time": 1782057600000,
      "weekly_remains_time": 7003536,
      "current_interval_status": 3,
      "current_interval_remaining_percent": 100,
      "current_weekly_status": 3,
      "current_weekly_remaining_percent": 100
    }
  ],
  "base_resp": { "status_code": 0, "status_msg": "success" }
}
```

### 3.2 `data` 包裹变体

控制台口径（`/backend/account/token_plan/remains_percent`）有时多一层 `data`：

```json
{
  "base_resp": { "status_code": 0, "status_msg": "success" },
  "data": {
    "current_subscribe_title": "Token Plan Plus",
    "points_balance": "14000",
    "model_remains": [ { "model_name": "general", "current_interval_remaining_percent": "96", "...": "..." } ]
  }
}
```

来源：CodexBar `Tests/CodexBarTests/Fixtures/Providers/MiniMax/token-plan-normal.json`。
CodexBar 的解码器两形态都兼容（有 `data` 就解 `data`，否则解根层）。
`/v1/token_plan/remains` 本身返回根层还是 `data` 包裹层：**未验证**（见 §7）。

## 4. 官方口径的窗口语义（已确认）

来源：https://platform.minimax.cn/docs/m-plan/usage-rules.md 与 `.../docs/m-plan/faq.md`

- 两个独立窗口：**5 小时窗口**（仅非视频模型）+ **周窗口**（所有模型）。
- 窗口**从首次使用时开始计时**，到点即刷新，与使用量无关。
- 未用完的额度**不结转**到下一个窗口，也不结转到下一个计费周期。
- 视频模型只受周窗口约束。
- 额度与速率限制（RPM/TPM）分开计算。

因此 `remains_time` / `weekly_remains_time` 是「距本次窗口结束」的倒计时，
不是从请求时刻起滚动。

## 5. 语义陷阱（实现必读）

1. **认证失败也返回 HTTP 200**。`/v1/token_plan/remains` 的认证错误体是
   `{"base_resp":{"status_code":1004,...}}`，HTTP 状态仍是 200。必须校验
   `base_resp.status_code == 0`，不能只看 HTTP 码。
2. **`current_interval_usage_count` 名字骗人，它表示「剩余」不是「已用」**。
   官方 CLI 的 `ki(usage_count, total_count, remaining_percent)` 用
   `used = total - remaining`；OpenTokenUsage 文档写「Treat
   `current_interval_usage_count` as remaining prompts」；CodexBar 同样按剩余处理。
   但由于 `*_total_count` 实测常年为 `0`，**实际应直接用百分比**，不要用计数推导。
3. **百分比字段可能是字符串**：`"96"`、`"96%"`、`96` 都出现过。解析要容错。
4. **`status == 3` 表示无限**。官方 CLI：`fg(status) => status===3` 渲染成 `∞`；
   dsh-cost-meter 明确「`current_weekly_status: 3` → 周额度显示 ∞（无限制）」。
   但**缺失窗口不能当无限**，只有显式 `3` 才是。
5. **`weekly_boost_permille` = 1500 表示周额度 150%**，官方 CLI 会把百分比乘以
   `boost_permille / 1000`；渲染时需要考虑。
6. **一条 `model_remains` 里有多个模型桶**：`general`（文本）与 `video`（视频）。
   要看文本额度就取 `model_name == "general"`；npm `pi-show-minimax-quota` 取
   `model_remains[0]`，CodexBar 取「剩余百分比最小且 status==1」的那条，
   `minimax-remaining-mcp` 同样取最紧的那条。
7. **重置时间优先用 `end_time` / `weekly_end_time`（绝对 epoch ms）**，
   `remains_time` 只作为兜底（OpenTokenUsage 的做法）。

## 6. 错误码

### 6.1 本次实测（2026-11-03，逐字响应体）

| 请求 | HTTP | body |
| --- | --- | --- |
| `GET https://api.minimaxi.com/v1/token_plan/remains`（无 auth） | 200 | `{"base_resp":{"status_code":1004,"status_msg":"login fail: Please carry the API secret key in the 'Authorization' field of the request header"}}` |
| 同上 + `Authorization: Bearer sk-cp-000...0` | 200 | 同上（**坏 Key 不返回 401**） |
| 同上 + `Authorization: Bearer invalid` | 200 | 同上 |
| 同上 + `Authorization: Bearer sk-api-000...0` | 200 | 同上 |
| `GET https://www.minimaxi.com/v1/token_plan/remains` | 200 | 1004 同上 |
| `GET https://www.minimax.cn/v1/token_plan/remains` | 200 | 1004 同上 |
| `GET https://api.minimax.cn/v1/token_plan/remains` | 200 | 1004 同上 |
| `GET https://api.minimax.io/v1/token_plan/remains` | 200 | 1004 同上 |
| `GET https://www.minimax.io/v1/token_plan/remains` | 200 | 1004 同上 |
| `GET https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains?GroupId=123456789` | 200 | `{"base_resp":{"status_code":1004,"status_msg":"cookie is missing, log in again"}}` |
| `GET https://www.minimax.cn/backend/account/token_plan/remains_percent` | 200 | `{"base_resp":{"status_code":1016,"status_msg":"invalid api key"}}` |
| `GET https://api.minimaxi.com/account/query_balance` | **400** | `{"base_resp":{"status_code":1004,"status_msg":"not authorized"}}` |
| `GET https://www.minimaxi.com/backend/account/token_plan_credit` | **401** | `{"base_resp":{"status_code":1004,"status_msg":"not login"}}` |

补充：`api.minimaxi.com/v1/token_plan/remains` 不发生 301/302（`num_redirects=0`）。

### 6.2 官方 CLI 识别的业务码

来源：mmx-cli `dist/mmx.mjs` 的错误映射函数

- `1004` → 登录失败 / 未授权 / cookie 缺失
- `1016` → invalid api key
- `1002` / `1026` / `1039` → 内容审核命中
- `1027` → 输出被审核拦截
- `1028` / `1030` → 额度耗尽
- `2061` → 当前套餐不含该模型
- `2062` → `no active token plan`（`minimax-remaining-mcp` 报告：把控制台
  `api_key` 当 Bearer 打到旧版 `coding_plan/remains` 会得到这个码）

## 7. 凭据与获取方式（已确认）

- 需要**订阅 Key**（官方叫「订阅 Key」/ M Plan Key），前缀 `sk-cp-…`。
- 获取位置：https://platform.minimax.cn/console/plan （国内区套餐详情页）；
  国际区对应 https://platform.minimax.io/console/plan 。
- 与普通按量计费 API Key（`sk-api-…`）**相互独立、不能混用**：
  - `sk-cp-…` → 授权 `/v1/token_plan/remains`（套餐额度）
  - `sk-api-…` → 授权 `/account/query_balance`（账户余额）
  官方 CLI 的 `selectUsageEndpoint()` 就是按前缀分流。
- 区域判定：官方 CLI `mmx auth login` 会拿 Key 依次试 `global` / `cn` 两个 base，
  用 `base_resp.status_code === 0` 判定命中；也可用
  `mmx config set --key region --value cn` 手动指定。
- 旧版 Token Plan 用户继续可用，权益不变（见 `docs/m-plan/token-plan-notice.md`）。

## 8. 推荐实现（macOS 菜单栏 App）

```
GET https://api.minimax.cn/v1/token_plan/remains
Authorization: Bearer <sk-cp-...>
Content-Type: application/json
Accept: application/json
```

回退顺序建议：`api.minimax.cn` → `www.minimax.cn` → `api.minimaxi.com` →
`www.minimaxi.com`（后两者是旧域名）。dsh-cost-meter 的自动顺序是
`www.minimax.cn` → `www.minimax.io` → `www.minimaxi.com`，可作参考。

解析流程：

1. HTTP != 200 → 网络/服务端错误。
2. 解 JSON；`base_resp.status_code != 0` → 业务错误（1004/1016 归为「Key 无效或过期」）。
3. `model_remains` 取 `model_name == "general"`；缺失时退回首条。
4. 5h 行：剩余% = `current_interval_remaining_percent`（容错字符串 / `"x%"`），
   重置 = `end_time`（epoch ms），兜底 `now + remains_time`。
5. 周行：剩余% = `current_weekly_remaining_percent`，重置 = `weekly_end_time`，
   兜底 `now + weekly_remains_time`；`current_weekly_status == 3` → 显示 ∞。
6. 已用% = `100 - 剩余%`。
7. 套餐名 = `current_subscribe_title` → `plan_name` → `combo_title` → `current_plan_title`
   → `points_balance` 旁的标题；都缺就显示「Token Plan」。
8. 全部字段容错：任何缺失/畸形都退化为 0 或 nil，不要让 UI 崩。

## 9. 未验证 / 不确定

- **没有真实订阅 Key 的端到端验证**。本次所有实测都是无凭据 / 假凭据；
  1004 是「没带 key」的响应，**不能证明带真 key 一定返回 §3 的 schema**。
- `api.minimax.cn` 与 `www.minimax.cn` 对真 key 的行为差异未验证（官方 CLI 用前者，
  官方文档用后者，二者未认证时返回体完全一致）。
- `api.minimaxi.com` / `www.minimaxi.com` 这两个旧域名是否仍接受真订阅 Key 未验证。
- `/v1/token_plan/remains` 返回根层 `model_remains` 还是 `data` 包裹层未验证。
  官方 CLI、npm 包、opencodex、probe.py 都按**根层**解析；CodexBar 两种都兼容。
- 订阅 Key 是否也能用于旧版 `coding_plan/remains`（需要 GroupId + cookie）未验证。
- 没有官方「响应字段参考」文档页；`llms.txt` 里没有 `token_plan/remains` 的
  api-reference 条目，schema 全部来自第三方实现 + CodexBar 测试固件。

## 10. 来源索引

| 来源 | URL |
| --- | --- |
| 官方 FAQ（**含 curl 示例**） | https://platform.minimax.cn/docs/m-plan/faq.md |
| 官方 用量说明 | https://platform.minimax.cn/docs/m-plan/usage-rules.md |
| 官方 其他工具（Key 前缀 / base URL） | https://platform.minimax.cn/docs/m-plan/other-tools.md |
| 官方 Token Plan 老用户 | https://platform.minimax.cn/docs/m-plan/token-plan-notice.md |
| 官方文档索引 | https://platform.minimax.cn/docs/llms.txt |
| 官方 CLI（npm `mmx-cli` 1.0.28） | https://registry.npmjs.org/mmx-cli/-/mmx-cli-1.0.28.tgz |
| npm `pi-show-minimax-quota` 0.2.1（已弃用，继任者 `pi-show-provider-quota`） | https://registry.npmjs.org/pi-show-minimax-quota |
| PyPI `minimax-remaining-mcp` 0.1.4 | https://pypi.org/pypi/minimax-remaining-mcp/json |
| CodexBar MiniMax 实现 | https://api.github.com/repos/steipete/CodexBar/contents/Sources/CodexBarCore/Providers/MiniMax |
| CodexBar 文档 | https://api.github.com/repos/steipete/CodexBar/contents/docs/minimax.md |
| hermes-resetwatch probe.py | https://api.github.com/repos/Adolanium/hermes-resetwatch/contents/probe.py |
| dsh-cost-meter 域名说明 | https://raw.githubusercontent.com/Han-1413141/dsh-cost-meter/bc29c788710b5888877871f1bfeb1f030be495a8/docs/minimax-quota-endpoint.md |
| OpenTokenUsage minimax 适配文档 | https://api.github.com/repos/PowerUserZ/OpenTokenUsage/contents/docs/providers/minimax.md |
| opencodex minimax 配额探针 | https://api.github.com/repos/lidge-jun/opencodex/contents/src/providers/quota/vendor-probes-key.ts |

> 注：本机 `raw.githubusercontent.com` 直连超时，上述 raw 内容经
> `api.github.com/repos/{owner}/{repo}/contents/{path}` 取得，内容等价。
