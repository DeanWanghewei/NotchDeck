"use strict";
// NotchDeck 订阅额度 GLM 适配脚本
// 契约：adapter.request 声明端点（主机必须在应用白名单内）；adapter.parse(body) 返回
// { plan, windows: [{ title, usedPercent, resetsAtMs }] }。脚本运行在无网络、无文件、
// 无进程的 JavaScriptCore 沙箱中，永远拿不到密钥明文——请求头里的 "{credential}"
// 占位由应用在发送前一刻替换。修改本文件后提交 PR，用户在插件市场点击“更新脚本”即生效，
// 无需更新应用。抛出 message 含 "signInRequired" 的异常会被应用按认证失败处理。
var adapter = {
  version: "1.0.0",
  request: {
    url: "https://open.bigmodel.cn/api/monitor/usage/quota/limit",
    headers: { "Authorization": "{credential}" }
  },

  parse: function (body) {
    var json;
    try { json = JSON.parse(body); } catch (e) { throw new Error("invalid"); }
    // 无凭据探针返回 HTTP 200 + code 1001，必须透传认证语义，不能当成零用量。
    if (json.code === 401 || json.code === 403 || json.code === 1001) {
      throw new Error("signInRequired");
    }
    if (json.success === false) { throw new Error("invalid"); }
    var data = json.data || json;

    var limits = (data.limits || []).filter(function (limit) {
      return (limit.type === "TOKENS_LIMIT" || limit.type === "TIME_LIMIT") &&
        typeof limit.percentage === "number" &&
        isFinite(limit.percentage) && limit.percentage >= 0;
    });

    // 完全相同的原始对象只保留第一份；JSON 序列化对同构对象稳定。
    var seen = [];
    limits = limits.filter(function (limit) {
      var key = JSON.stringify(limit);
      if (seen.indexOf(key) >= 0) { return false; }
      seen.push(key);
      return true;
    });

    var windows = limits.map(function (limit) {
      var title;
      if (limit.type !== "TOKENS_LIMIT") { title = "工具调用"; }
      else if (limit.unit === 3 && limit.number === 5) { title = "5 小时"; }
      else if (limit.unit === 6 && limit.number === 1) { title = "每周"; }
      else { title = "编码额度"; }
      return { title: title, usedPercent: limit.percentage, resetsAtMs: resetTime(limit.nextResetTime) };
    });

    // 同名窗口加序号，与内置解析的展示口径一致（如 “编码额度 1”）。
    var totals = {};
    windows.forEach(function (w) { totals[w.title] = (totals[w.title] || 0) + 1; });
    var counts = {};
    windows = windows.map(function (w) {
      if (totals[w.title] > 1) {
        counts[w.title] = (counts[w.title] || 0) + 1;
        w.title = w.title + " " + counts[w.title];
      }
      return w;
    });

    if (!windows.length) { throw new Error("invalid"); }
    return { plan: data.level || null, windows: windows };
  }
};

// nextResetTime 已实证形态：epoch 毫秒数字与 RFC3339 字符串；公开实现的样本
// 另含数字字符串与按秒计的数字（≥1e10 视为毫秒）。无法解析返回 null，不估算。
function resetTime(value) {
  var milliseconds = null;
  if (typeof value === "number" && isFinite(value) && value > 0) {
    milliseconds = value >= 1e10 ? value : value * 1000;
  } else if (typeof value === "string") {
    var parsed = Date.parse(value);
    if (!isNaN(parsed)) {
      milliseconds = parsed;
    } else if (/^\d+(\.\d+)?$/.test(value.trim())) {
      var number = Number(value);
      if (isFinite(number) && number > 0) { milliseconds = number >= 1e10 ? number : number * 1000; }
    }
  }
  // 上限约 2100 年，防把任意大数字当成有效时刻。
  if (milliseconds === null || milliseconds <= 0 || milliseconds / 1000 >= 4102444800) { return null; }
  return milliseconds;
}
