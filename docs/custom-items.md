# 自定义子项写法指南

自定义子项 = **一条 zsh 命令 + 一种展示方式（文本 / 热力图）**。

添加入口：**设置 → 自定义 → 添加子项**（手写命令），或从同页的**示例模板**一键添加后改成自己的参数。示例模板的机器可读定义在 `Core/ModuleFramework.swift` 的 `CustomItemPresets`，与本文档一一对应。

## 规则速查

| 规则 | 说明 |
| --- | --- |
| 执行方式 | `/bin/zsh -lc`（登录 shell），可用 `curl`、`jq`、`git`、`awk` 及用户环境变量；**支持多行脚本**（编辑器为多行编辑框，整串交给 zsh 逐行执行） |
| 超时 | 单次最长 6 秒，超时按失败处理；网络命令建议自带 `--max-time 5` |
| 文本模式 | 标准输出原样显示（支持多行）；退出码非 0 时显示错误与退出码 |
| 热力图 · 数字解析 | 输出按空白 / 逗号 / 分号切分，逐个取数字：`42`、`3.14`、`45%`、`-3` 都可识别，非数字 token 忽略 |
| 热力图 · 多值 | 一次输出**多个**数字 → 整体渲染为一屏方格（左侧低、右侧高） |
| 热力图 · 单值 | 一次输出**一个**数字 → 随探测累积成时间线，面板中**单行显示**（右端为最新） |
| 热力图 · 保留时长 | 单值序列只保留最近 N 小时（设置 → 自定义 → 热力图保留时长，1~24 小时可选，默认 2 小时），更早的样本自动清除 |
| 热力图 · 压缩显示 | 样本多到一行放不下时，相邻样本自动合并为一格（每格取该段最新状态），仍保持单行 |
| 热力图 · 失败 | 退出码非 0 或超时 → 记为**红色方格**，摘要统计失败次数；错误原文在悬停提示里 |
| 后台探测 | 存在热力图子项时，每 30 秒自动执行一次（面板收起时趋势也在累积） |
| 管道陷阱 | `curl … \| jq …` 会吞掉 curl 的退出码，失败也会"成功"显示绿色；需标红请在命令前加 `set -o pipefail; ` |

## 案例

### 1. 本机 IP（文本）

```bash
ipconfig getifaddr en0
```

最简形态：输出一行文本，面板原样显示。Wi-Fi 机器上 `en0` 是无线网卡。

### 2. 公网 IP（文本）

```bash
curl -s --max-time 4 https://api.ipify.org
```

### 3. 服务是否正常 / 是否慢（热力图 · 单值，最常用）

```bash
curl -sfo /dev/null -w '%{time_total}' --connect-timeout 2 --max-time 5 http://boom-fn:5666/
```

- 正常：输出总耗时（秒），越慢绿色越深，时间线每 30 秒累积一点
- 无法访问 / 超时 / HTTP 4xx、5xx（`-f` 的作用）：curl 非 0 退出 → **红色方格**
- 摘要行显示「最新 0.012 · 高 0.2 · 低 0.01 · 失败 N」

变体：

```bash
# 只测建立连接的时间（不含传输）
curl -sfo /dev/null -w '%{time_connect}' --max-time 5 http://boom-fn:5666/

# 想看毫秒数（必须带 pipefail，否则管道吞掉 curl 失败状态）
set -o pipefail; curl -sfo /dev/null -w '%{time_total}' --max-time 5 http://boom-fn:5666/ | awk '{printf "%.0f\n", $1*1000}'
```

### 4. 磁盘占用趋势（热力图 · 单值）

```bash
df / | tail -1 | awk '{print $5}'
```

输出形如 `78%`（尾部百分号可识别），随探测累积出占用走势。

### 5. CPU 前几名进程（热力图 · 多值）

```bash
ps -arcHo %cpu | head -8
```

一次输出 8 个数字（按 CPU 排序的进程占用），整体渲染为一屏方格——多值模式的示例：适合「命令一次给出整段数据」的场景（如 API 返回最近 N 个点）。

### 6. 需要先认证再取数（热力图 · 模板）

```bash
TOKEN=$(curl -s -X POST https://api.example.com/login -d 'user=USER&pass=PASS' | grep -o '"token":"[^"]*"' | cut -d'"' -f4); curl -s -H "Authorization: Bearer $TOKEN" https://api.example.com/metrics
```

先登录拿 token、再带 token 请求目标接口的两段式写法。替换接口、账号与取数字段后即可用于内网服务；装了 `jq` 时可用 `jq -r .token` 替换中间的 grep/cut。注意第二段请求失败仍要保证整体退出码非 0（zsh 缺省以最后一条命令为准，天然满足）。

## 排错

| 现象 | 原因与处理 |
| --- | --- |
| 热力图卡片显示文本而不是方格 | 输出里没解析到数字：检查命令是否真的输出纯数字（`45%` 可以，`45ms`、`1,234` 这种会被切错） |
| 服务挂了但方格还是绿色 | 命令退出码仍为 0：常见于管道（见上表「管道陷阱」）或 `curl` 没加 `-f` |
| 数字一直显示 0.0 | 输出是秒级小数但界面按一位小数显示？已按量级自适应（0.023 会显示 0.023）；若仍异常检查单位 |
| 面板收起后趋势还在长 | 这是设计行为：热力图子项每 30 秒后台探测一次 |

## 给 AI Agent / 贡献者

- 示例模板（产品内的写法引导）定义在 `Core/ModuleFramework.swift` → `CustomItemPresets.all`，修改示例请同步更新本文档。
- 解析与采样逻辑在 `Modules/Custom/CustomItemsModule.swift`：`numbers(in:limit:)` 负责取数，`CustomHeatmapSample` 以 `value == nil` 表示失败样本，30 秒轮询即 `defaultPollInterval`。
- 渲染在 `UI/CustomItemsView.swift` → `CustomHeatmapView`：绿色按 `levelIndex` 分 5 档，失败为红色；`format(_:)` 按量级选小数位。
- 想新增展示方式（如仪表盘、进度条）：在 `CustomItem.Display` 加 case，模块里产出该形态的数据，视图里加对应渲染分支；旧数据靠 `CustomItem.init(from:)` 的 `decodeIfPresent` 回退保持兼容。
