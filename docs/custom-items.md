# 自定义子项写法指南

自定义子项 = **一条 zsh 命令 + 一种展示方式（文本 / 热力图）**。

添加入口：**设置 → 自定义 → 添加子项**（手写命令），或从同页的**示例模板**一键添加后改成自己的参数。示例模板按场景分成四组（系统 / 网络 / 开发 / 通用），机器可读定义在 `Modules/Custom/CustomItem.swift` 的 `CustomItemPresets`；本文档的每个小节与一条模板同名，命令原文照抄自模板，改模板必须同步改本文档（`Tests/CustomItemsTests.swift` 会做校验）。

## 规则速查

| 规则 | 说明 |
| --- | --- |
| 执行方式 | `/bin/zsh -lc`（登录 shell），可用 `curl`、`git`、`awk` 等用户环境里的命令；**支持多行脚本**（编辑器为多行编辑框，整串交给 zsh 逐行执行） |
| 超时 | 单次最长 6 秒，超时按失败处理；网络命令建议自带 `--max-time 5` |
| 文本模式 | 标准输出原样显示（支持多行）；退出码非 0 时显示错误与退出码。文本子项**只在面板展开时执行**，不参与后台探测 |
| 热力图 · 数字解析 | 输出按空白 / 逗号 / 分号切分，逐个取数字：`42`、`3.14`、`45%`、`-3` 都可识别，非数字 token 忽略 |
| 热力图 · 多值 | 一次输出**多个**数字 → 整体渲染为一屏方格（左侧低、右侧高） |
| 热力图 · 单值 | 一次输出**一个**数字 → 随探测累积成时间线，面板中**单行显示**（右端为最新） |
| 热力图 · 保留时长 | 单值序列只保留最近 N 小时（设置 → 自定义 → 热力图保留时长，1~24 小时可选，默认 2 小时），更早的样本自动清除 |
| 热力图 · 压缩显示 | 样本多到一行放不下时，相邻样本自动合并为一格（每格取该段最新状态），仍保持单行 |
| 热力图 · 失败 | 退出码非 0 或超时 → 记为**红色方格**，摘要统计失败次数；错误原文在悬停提示里 |
| 热力图 · 颜色 | 绿色 5 档深浅表示数值由低到高，**只表示数值大小，不表示好坏**（如「磁盘剩余空间」剩余越多越深） |
| 后台探测 | 存在热力图子项时按设置页的**热力图探测间隔**自动执行一次（10 秒 / 30 秒 / 1 分钟 / 5 分钟，默认 30 秒）；面板收起时趋势也在累积 |
| 管道陷阱 | `curl … \| awk …` 会吞掉 curl 的退出码，失败也会"成功"显示绿色；需标红请在命令前加 `set -o pipefail; ` |
| 缺失值 | 取不到的数据**不补 0、不造伪数值**：命令成功但没有数字时显示「未解析到数字」；命令失败时记为一次失败（红方格） |

## 管道与失败标记（写模板前必读）

1. **含管道的命令一律前置 `set -o pipefail; `**。zsh 缺省以管道最后一个命令的退出码为准，`curl` 失败会被 `grep` / `awk` 吞掉，命令看起来"成功"，热力图于是显示绿色而不是红色。示例模板里凡是带管道的命令都带了这一前缀；不带管道的（如 `curl -w` 直接输出耗时）不需要。
2. **不要用 `head` 截断上游输出**。`head` 读够行数就退出，上游（`ps` 等）会收到 `SIGPIPE` 而非零退出；配合 `pipefail` 整条命令会被判成失败、显示红色。示例模板改用 `sort` + `sed -n '1,8p'`：`sort` / `sed` 会把上游输出读完再截断，不会提前关闭管道。
3. **失败不是 0**。目标不可达、daemon 没启动、没有电池这类情况，命令应当非 0 退出（记为红方格），而不是输出 `0` —— 0 会被当成"真实读数为零"。
4. **需要替换的占位符**（地址、端口、目录、账号）必须在模板说明里写清楚，模板命令本身不写本机专有路径。

## 示例模板目录

| 分类 | 模板 | 展示方式 |
| --- | --- | --- |
| 系统 | 磁盘占用 | 热力图（单值） |
| 系统 | CPU 前几名进程 | 热力图（多值） |
| 系统 | CPU 总占用 | 热力图（单值） |
| 系统 | 内存占用百分比 | 热力图（单值） |
| 系统 | 磁盘剩余空间 | 热力图（单值） |
| 系统 | 电池电量 | 热力图（单值） |
| 网络 | 本机 IP | 文本 |
| 网络 | 公网 IP | 文本 |
| 网络 | 服务响应速度 | 热力图（单值） |
| 网络 | DNS 解析耗时 | 热力图（单值） |
| 网络 | Ping 丢包率 | 热力图（单值） |
| 开发 | Git 分支与改动 | 文本 |
| 开发 | 本地端口监听 | 文本 |
| 开发 | Docker 运行容器数 | 热力图（单值） |
| 通用 | 先登录再取数（模板） | 热力图（多值或单值） |

## 案例

<!-- CASES-START -->
### 磁盘占用

系统 · 热力图

```bash
set -o pipefail; df / | tail -1 | awk '{print $5}'
```

输出如 78%（百分号可识别）；单值随探测累积为趋势。

写法要点：`df /` 只输出根卷一行；`awk '{print $5}'` 取的是「已用百分比」字段（带 `%`，解析时会被剥掉）。

### CPU 前几名进程

系统 · 热力图

```bash
set -o pipefail; ps -eo %cpu= | sort -nr | sed -n '1,8p'
```

多值示例：一次输出多个数字，整体渲染为一屏方格；只取 %cpu= 一列，带上 pid=、comm= 时进程名里的数字（如 Python 3.12）会混进热力图。

写法要点：macOS 的 `ps` 没有 `-H` 选项（会报 illegal option），这里用 `-eo %cpu=` 只输出百分比一列，`sort -nr` 降序、`sed -n '1,8p'` 取前 8 行。`head` 读够行数就退出会让 `ps` 收到 SIGPIPE，配合 pipefail 整条命令会被误判成失败，所以这里用 `sed`。

### CPU 总占用

系统 · 热力图

```bash
set -o pipefail; top -l 2 -n 0 | awk -F'[,%]' '/CPU usage/ {idle=$5} END {if (idle == "") exit 1; printf "%d\n", 100 - idle}'
```

整机 CPU 占用百分比（整数）；取两次采样之间的差值，比单次采样准。

写法要点：`top -l 2` 取两次采样，`awk -F'[,%]'` 切出第三个数（idle），100 减掉就是总占用；解析不到 `CPU usage` 行时命令非 0 退出 → 红方格。

### 内存占用百分比

系统 · 热力图

```bash
set -o pipefail; vm_stat | awk -F': ' -v total="$(sysctl -n hw.memsize)" 'NR==1 {gsub(/[^0-9]/,"",$0); page=$0} /^Anonymous pages:/ {gsub(/[^0-9]/,"",$2); a=$2} /^Pages wired down:/ {gsub(/[^0-9]/,"",$2); w=$2} /^Pages occupied by compressor:/ {gsub(/[^0-9]/,"",$2); c=$2} END {if (a == "" || total == "" || page == "") exit 1; printf "%d\n", (a+w+c)*page*100/total}'
```

已用内存百分比（匿名页 + 联动 + 压缩，近似活动监视器）；页大小从 vm_stat 首行动态取，不写死 4096。

写法要点：苹果芯片页大小是 16 KB、Intel 是 4 KB，写死会让百分比算错；这里从 `vm_stat` 首行动态取页大小，`hw.memsize` 取物理内存，两者相乘才是字节数。

### 磁盘剩余空间

系统 · 热力图

```bash
set -o pipefail; df -k / | awk 'NR==2 {printf "%d\n", $4/1024/1024}'
```

根卷剩余空间（GB，整数）；热力图只按数值大小着色，剩余越多颜色越深，不代表好坏。

写法要点：`df -k` 的第 4 列是可用块数，除以 1024² 得到 GB（取整）。**热力图只按数值大小着色：剩余越多颜色越深，不代表好坏**——磁盘快满时颜色反而最浅。

### 电池电量

系统 · 热力图

```bash
set -o pipefail; pmset -g batt | awk '/InternalBattery/ {for (i=1;i<=NF;i++) if ($i ~ /%;/) {gsub(/[^0-9.]/,"",$i); print $i; exit}}'
```

电池电量百分比；台式机没有电池时命令成功但无数字，显示「未解析到数字」，不会补 0。

写法要点：`pmset -g batt` 里带 `%` 的那个字段就是电量；台式机没有电池时命令成功但无数字，显示「未解析到数字」，不会补 0。

### 本机 IP

网络 · 文本

```bash
ipconfig getifaddr en0
```

文本：命令输出原样显示。

写法要点：Wi-Fi 机器上 `en0` 是无线网卡，有线网卡常见是 `en1`；取不到时命令非 0 退出，文本模式会显示错误。

### 公网 IP

网络 · 文本

```bash
curl -s --max-time 4 https://api.ipify.org
```

文本：curl 直接取公网地址。

写法要点：ipify 是第三方公共服务，需要联网；不通时命令非 0 退出，文本模式显示错误信息。

### 服务响应速度

网络 · 热力图

```bash
curl -sfo /dev/null -w '%{time_total}' --connect-timeout 2 --max-time 5 https://www.apple.com/
```

把地址换成自己的服务（如 http://boom-fn:5666/）：越慢颜色越深，无法访问显示红色。

写法要点：`curl -f` 让 HTTP 4xx/5xx 也算失败（红方格）；`-w '%{time_total}'` 输出总耗时（秒）。常见变体：

```bash
# 只测建立连接的时间（不含传输）
curl -sfo /dev/null -w '%{time_connect}' --max-time 5 http://boom-fn:5666/

# 想看毫秒数（必须带 pipefail，否则管道吞掉 curl 失败状态）
set -o pipefail; curl -sfo /dev/null -w '%{time_total}' --max-time 5 http://boom-fn:5666/ | awk '{printf "%.0f\n", $1*1000}'
```

### DNS 解析耗时

网络 · 热力图

```bash
curl -sfo /dev/null -w '%{time_namelookup}' --connect-timeout 2 --max-time 5 https://www.apple.com/
```

把域名换成你要监控的站点；数值是域名解析耗时（秒），越小越好。

写法要点：`%{time_namelookup}` 只统计域名解析那一段，比 `%{time_total}` 更能反映 DNS 是否变慢；`--connect-timeout 2` 保证解析卡住时 2 秒内失败（红方格）。

### Ping 丢包率

网络 · 热力图

```bash
set -o pipefail; ping -c 3 -W 1000 1.1.1.1 | grep -o '[0-9.]*% packet loss' | cut -d% -f1
```

把地址换成要监控的主机；3 个包约 2~3 秒；目标不可达时 ping 非 0 退出 → 红色失败方格。

写法要点：`-W 1000` 把每个包的等待压到 1 秒，3 个包最坏约 3 秒，在 6 秒超时内；丢包率由 `ping` 自己算好，解析时只取 `%` 前面的数字。目标完全不可达时 `ping` 非 0 退出 → 记为一次失败（红方格），**不会**显示成「丢包 0%」。

### Git 分支与改动

开发 · 文本

```bash
set -o pipefail; repo="$HOME/Projects/my-repo"; branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD) || exit 1; dirty=$(git -C "$repo" status --porcelain | wc -l | tr -d ' '); printf '%s（改动 %s 个文件）\n' "$branch" "$dirty"
```

必须把 $HOME/Projects/my-repo 换成你的仓库目录；输出当前分支与未提交改动文件数。

写法要点：目录不是 git 仓库时 `rev-parse` 非 0 退出 → 显示错误文本而不是假的分支名；改动文件数来自 `status --porcelain` 的行数（未跟踪文件也算）。

### 本地端口监听

开发 · 文本

```bash
if lsof -nP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1; then printf '8080 端口监听中\n'; else printf '8080 端口未监听\n'; fi
```

必须把 8080 换成你的端口；文本显示监听状态，不进热力图。

写法要点：`lsof` 只能看到当前用户进程的端口（开发服务器通常是自己启动的，能看到）；没监听到时 `lsof` 非 0 退出，这里用 `if` 判一次，输出「未监听」而不是错误信息。

### Docker 运行容器数

开发 · 热力图

```bash
set -o pipefail; docker ps --filter status=running --format '{{.Names}}' | wc -l | tr -d ' '
```

需要 Docker 已启动；daemon 没运行时命令非 0 退出 → 红色失败方格，不会显示 0。

写法要点：`docker ps` 只列出运行中的容器；没装 Docker 或 daemon 没启动时命令非 0 退出 → 红方格，不会显示成「0 个容器」。

### 先登录再取数（模板）

通用 · 热力图

```bash
set -o pipefail; TOKEN=$(curl -s -X POST https://api.example.com/login -d 'user=USER&pass=PASS' | grep -o '"token":"[^"]*"' | cut -d'"' -f4); curl -sf -H "Authorization: Bearer $TOKEN" https://api.example.com/metrics
```

模板：替换接口地址、账号与取数字段后再用；第二段带 -f，接口返回 4xx/5xx 才会显示为红色。

写法要点：装了 `jq` 时可以用 `jq -r .token` 替换中间的 grep/cut；占位符（接口地址、账号）必须先替换。

<!-- CASES-END -->

## 排错

| 现象 | 原因与处理 |
| --- | --- |
| 热力图卡片显示文本而不是方格 | 输出里没解析到数字：检查命令是否真的输出纯数字（`45%` 可以，`45ms`、`1,234` 这种会被切错） |
| 服务挂了但方格还是绿色 | 命令退出码仍为 0：常见于管道（见上表「管道陷阱」）或 `curl` 没加 `-f` |
| 数字一直显示 0.0 | 输出是秒级小数但界面按一位小数显示？已按量级自适应（0.023 会显示 0.023）；若仍异常检查单位 |
| 显示「未解析到数字」 | 命令成功但输出里没有数字：台式机没有电池就属于这种情况，**不会**被补成 0 |
| 面板收起后趋势还在长 | 这是设计行为：热力图子项按设置页的探测间隔后台探测一次 |
| 文本子项在后台也跑 | 不该发生：文本子项只在面板展开 / 手动刷新 / 配置变更时执行；探测间隔调到 10 秒也不会加重文本命令 |

## 给 AI Agent / 贡献者

- 示例模板（产品内的写法引导）定义在 `Modules/Custom/CustomItem.swift` → `CustomItemPresets.all`；分类在 `CustomItemPresets.Category`，设置页按 `Category.allCases` 顺序分组。修改示例请同步更新本文档（`Tests/CustomItemsTests.swift` 会校验「文档小节标题 == 模板名」与「命令原文出现在文档里」）。
- 解析与采样逻辑在 `Modules/Custom/CustomItemsModule.swift`：`numbers(in:limit:)` 负责取数，`CustomHeatmapSample` 以 `value == nil` 表示失败样本；探测间隔取自 `SettingsStore.customPollInterval`（合法档位 `CustomPollInterval.options`，非法值回退默认 30 秒），`CustomItemsModule.defaultPollInterval` 保留为默认值来源。
- 渲染在 `UI/CustomItemsView.swift` → `CustomHeatmapView`：绿色按 `levelIndex` 分 5 档，失败为红色；`format(_:)` 按量级选小数位。
- 想新增展示方式（如仪表盘、进度条）：在 `CustomItem.Display` 加 case，模块里产出该形态的数据，视图里加对应渲染分支；旧数据靠 `CustomItem.init(from:)` 的 `decodeIfPresent` 回退保持兼容。
