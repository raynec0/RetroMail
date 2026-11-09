/**
 * RetroMail Push Worker —— 用 Cloudflare 免费服务把新邮件推送到 iPhone（Bark）。
 *
 * 两种方式可以同时开：
 *  A. 定时检查（scheduled）：每分钟用 TCP 连接登录你的 IMAP 邮箱，看收件箱有没有新邮件。最多约 1 分钟延迟，不用改邮箱设置。
 *  B. 邮件转发（email）：公司邮箱“自动转发一份副本”到你 Cloudflare 域名上的地址（如 push@你的域名），
 *     Cloudflare 收到后立刻推送，然后丢弃这份副本。几秒内送达。
 * 两种方式同时开时，同一封邮件只推送一次（按 Message-ID 去重）。
 *
 * 需要的绑定：
 *  - 机密变量 CONFIG：和 relay/config.json 一样的 JSON（RetroMail → 设置 → 即时推送 → 拷贝配置）
 *  - KV 命名空间 STATE：记录检查到哪里了、哪些邮件推送过
 *  - Cron 触发器：* * * * *（每分钟）
 *  - （方案 B）Email Routing 里把 push@你的域名 的动作设为“发送到 Worker”，选这个 Worker
 */
import { connect } from "cloudflare:sockets";

const enc = new TextEncoder();
const dec = new TextDecoder();

// ------------------------------------------------------------ 入口

export default {
  async scheduled(event, env, ctx) {
    ctx.waitUntil(checkAll(env));
  },

  async email(message, env, ctx) {
    try {
      await handleForwarded(message, env);
    } catch (e) {
      console.log("email handler error:", e && e.stack || e);
      await setStatus(env, { emailError: String(e), at: new Date().toISOString() });
    }
    // 不调用 forward()：推送完这份副本就丢弃（原邮件还在你的公司邮箱里）
  },

  async fetch(request, env) {
    const url = new URL(request.url);
    const cfg = loadConfig(env);
    const token = url.searchParams.get("token") || "";
    if (url.pathname === "/" || !cfg.token || token !== cfg.token) {
      return new Response("RetroMail push worker is running.\n", { headers: { "content-type": "text/plain; charset=utf-8" } });
    }
    if (url.pathname === "/test") {
      await push(cfg, cfg.accounts[0] || {}, "RetroMail", "Cloudflare 推送测试", "能看到这条通知，说明 Worker 和 Bark 设置正确。", "retromail://open");
      return new Response("sent\n");
    }
    if (url.pathname === "/run") {
      const r = await checkAll(env);
      return Response.json(r);
    }
    if (url.pathname === "/status") {
      return new Response((await env.STATE.get("status")) || "{}", { headers: { "content-type": "application/json" } });
    }
    return new Response("not found\n", { status: 404 });
  },
};

function loadConfig(env) {
  const raw = env.CONFIG;
  if (!raw) throw new Error("没有设置机密变量 CONFIG");
  return typeof raw === "string" ? JSON.parse(raw) : raw;
}

async function setStatus(env, patch) {
  try {
    const old = JSON.parse((await env.STATE.get("status")) || "{}");
    await env.STATE.put("status", JSON.stringify({ ...old, ...patch }));
  } catch (_) {}
}

// ------------------------------------------------------------ 方案 A：定时检查 IMAP

async function checkAll(env) {
  const cfg = loadConfig(env);
  const results = {};
  for (const acc of cfg.accounts || []) {
    const key = (acc.email || acc.username).toLowerCase();
    try {
      results[key] = await checkAccount(cfg, acc, env);
    } catch (e) {
      results[key] = "error: " + (e && e.message || e);
      console.log("check", key, "failed:", e && e.stack || e);
    }
  }
  await setStatus(env, { lastRun: new Date().toISOString(), results });
  return results;
}

async function checkAccount(cfg, acc, env) {
  const key = (acc.email || acc.username).toLowerCase();
  const folder = acc.folder || "INBOX";
  const stateKey = "uid:" + key + ":" + folder;
  const last = parseInt((await env.STATE.get(stateKey)) || "0", 10);
  const imap = await Imap.open(acc);
  try {
    await imap.login(acc.username, acc.password);
    const st = await imap.cmd(`STATUS ${quote(folder)} (UIDNEXT)`);
    const m = /UIDNEXT (\d+)/i.exec(st.text);
    const next = m ? parseInt(m[1], 10) : 0;
    if (!next) return "no UIDNEXT";
    if (!last || next < last) {
      // 第一次运行（或文件夹重建）：只记位置，不推送旧邮件
      await env.STATE.put(stateKey, String(next));
      return "initialized at " + next;
    }
    if (next <= last) return "no new mail";
    await imap.cmd(`EXAMINE ${quote(folder)}`);
    const f = await imap.cmd(
      `UID FETCH ${last}:* (UID FLAGS BODY.PEEK[HEADER.FIELDS (FROM SUBJECT MESSAGE-ID CONTENT-TYPE CONTENT-TRANSFER-ENCODING)] BODY.PEEK[TEXT]<0.1500>)`
    );
    const msgs = parseFetch(f).filter((x) => x.uid >= last).sort((a, b) => a.uid - b.uid).slice(-10);
    let sent = 0;
    for (const msg of msgs) {
      if (/\\Seen/i.test(msg.flags)) continue;
      const h = parseHeaders(msg.header);
      const mid = (h["message-id"] || "").trim();
      if (mid && (await env.STATE.get("seen:" + mid))) continue; // 方案 B 已经推过
      const { title, subtitle, body } = describe(cfg, acc, h, msg.text);
      await push(cfg, acc, title, subtitle, body, openURL(acc, folder, msg.uid, mid));
      if (mid) await env.STATE.put("seen:" + mid, "1", { expirationTtl: 172800 });
      sent++;
    }
    const newLast = Math.max(next, ...msgs.map((x) => x.uid + 1));
    await env.STATE.put(stateKey, String(newLast));
    return `pushed ${sent}`;
  } finally {
    await imap.close();
  }
}

// ------------------------------------------------------------ 方案 B：收到转发的副本

async function handleForwarded(message, env) {
  const cfg = loadConfig(env);
  const accounts = cfg.accounts || [];
  // 只读开头一部分，够取信头和预览即可
  const raw = await readStream(message.raw, 64 * 1024);
  const split = indexOfBlank(raw);
  const headerText = latin(raw.subarray(0, split < 0 ? raw.length : split));
  const h = parseHeaders(headerText);
  const mid = (h["message-id"] || "").trim();
  if (mid && (await env.STATE.get("seen:" + mid))) return;
  // 判断是哪个账户的邮件：看原始收件人
  const rcpt = ((h["to"] || "") + "," + (h["cc"] || "") + "," + (h["delivered-to"] || "") + "," + (h["x-original-to"] || "")).toLowerCase();
  const acc = accounts.find((a) => rcpt.includes((a.email || a.username || "").toLowerCase())) || accounts[0] || {};
  const bodyBytes = split < 0 ? new Uint8Array(0) : raw.subarray(split);
  const { title, subtitle, body } = describe(cfg, acc, h, bodyBytes);
  await push(cfg, acc, title, subtitle, body, openURL(acc, acc.folder || "INBOX", 0, mid));
  if (mid) await env.STATE.put("seen:" + mid, "1", { expirationTtl: 172800 });
  await setStatus(env, { lastEmail: new Date().toISOString(), lastEmailSubject: subtitle });
}

async function readStream(stream, limit) {
  const reader = stream.getReader();
  const chunks = [];
  let total = 0;
  while (total < limit) {
    const { value, done } = await reader.read();
    if (done) break;
    chunks.push(value);
    total += value.length;
  }
  try { reader.cancel(); } catch (_) {}
  const out = new Uint8Array(Math.min(total, limit));
  let o = 0;
  for (const c of chunks) {
    const n = Math.min(c.length, out.length - o);
    out.set(c.subarray(0, n), o);
    o += n;
    if (o >= out.length) break;
  }
  return out;
}

function indexOfBlank(b) {
  for (let i = 0; i + 3 < b.length; i++) {
    if (b[i] === 13 && b[i + 1] === 10 && b[i + 2] === 13 && b[i + 3] === 10) return i + 4;
    if (b[i] === 10 && b[i + 1] === 10) return i + 2;
  }
  return -1;
}

// ------------------------------------------------------------ 推送内容

function describe(cfg, acc, h, textBytes) {
  const from = decodeWords(h["from"] || "");
  const nm = /^\s*"?([^"<]*?)"?\s*<([^>]+)>/.exec(from);
  const sender = (nm && nm[1].trim()) || (nm && nm[2]) || from.trim() || "新邮件";
  let subtitle = decodeWords(h["subject"] || "").trim() || "（无主题）";
  let body = "";
  if (cfg.preview !== false) {
    body = preview(h, textBytes);
  } else if (cfg.show_subject === false) {
    subtitle = "你有一封新邮件";
  }
  if ((cfg.accounts || []).length > 1) body = (body + "\n— " + (acc.name || acc.email || "")).trim();
  return { title: sender, subtitle, body };
}

function openURL(acc, folder, uid, mid) {
  const p = new URLSearchParams({ email: acc.email || acc.username || "", folder });
  if (uid) p.set("uid", String(uid));
  if (mid) p.set("mid", mid);
  return "retromail://open?" + p.toString();
}

async function push(cfg, acc, title, subtitle, body, url) {
  const p = cfg.push || {};
  const kind = (p.type || "bark").toLowerCase();
  let r;
  if (kind === "ntfy") {
    const headers = { "content-type": "application/json; charset=utf-8" };
    if (p.token) headers.authorization = "Bearer " + p.token;
    r = await fetch((p.server || "https://ntfy.sh").replace(/\/$/, ""), {
      method: "POST",
      headers,
      body: JSON.stringify({ topic: p.topic, title, message: (subtitle + "\n" + body).trim() || " ", click: url, tags: ["envelope"], priority: p.priority || 4 }),
    });
  } else {
    const payload = {
      device_key: p.key, title, subtitle, body: body || " ",
      group: p.group || acc.name || "RetroMail", url, level: p.level || "timeSensitive",
    };
    if (p.sound) payload.sound = p.sound;
    if (p.icon) payload.icon = p.icon;
    r = await fetch((p.server || "https://api.day.app").replace(/\/$/, "") + "/push", {
      method: "POST",
      headers: { "content-type": "application/json; charset=utf-8" },
      body: JSON.stringify(payload),
    });
  }
  if (!r.ok) throw new Error("push failed: " + r.status + " " + (await r.text()).slice(0, 200));
}

// ------------------------------------------------------------ 最小 IMAP 客户端

class Imap {
  static async open(acc) {
    const port = parseInt(acc.port || 993, 10);
    const useSSL = acc.ssl !== undefined ? !!acc.ssl : port === 993;
    let socket = connect({ hostname: acc.host, port }, { secureTransport: useSSL ? "on" : (acc.starttls !== false ? "starttls" : "off"), allowHalfOpen: false });
    const im = new Imap(socket);
    await im.readLine(); // 欢迎语
    if (!useSSL && acc.starttls !== false) {
      await im.cmd("STARTTLS");
      im.release();
      socket = socket.startTls();
      im.attach(socket);
    }
    return im;
  }

  constructor(socket) {
    this.tag = 0;
    this.buf = new Uint8Array(0);
    this.attach(socket);
  }

  attach(socket) {
    this.socket = socket;
    this.reader = socket.readable.getReader();
    this.writer = socket.writable.getWriter();
  }

  release() {
    try { this.reader.releaseLock(); } catch (_) {}
    try { this.writer.releaseLock(); } catch (_) {}
  }

  async fill() {
    const { value, done } = await withTimeout(this.reader.read(), 25000, "读取超时");
    if (done) throw new Error("连接被服务器关闭");
    const n = new Uint8Array(this.buf.length + value.length);
    n.set(this.buf);
    n.set(value, this.buf.length);
    this.buf = n;
  }

  async readLine() {
    for (;;) {
      for (let i = 0; i + 1 < this.buf.length; i++) {
        if (this.buf[i] === 13 && this.buf[i + 1] === 10) {
          const line = this.buf.subarray(0, i);
          this.buf = this.buf.subarray(i + 2);
          return line;
        }
      }
      await this.fill();
    }
  }

  async readBytes(n) {
    while (this.buf.length < n) await this.fill();
    const out = this.buf.subarray(0, n);
    this.buf = this.buf.subarray(n);
    return out;
  }

  /** 发命令，返回 { text: 所有文字行, parts: [{text} 或 {literal}] , ok } */
  async cmd(command) {
    const tag = "R" + ++this.tag;
    await this.writer.write(enc.encode(tag + " " + command + "\r\n"));
    const parts = [];
    let text = "";
    for (;;) {
      const lineBytes = await this.readLine();
      const line = latin(lineBytes);
      parts.push({ text: line });
      text += line + "\n";
      const lit = /\{(\d+)\}$/.exec(line);
      if (lit) {
        const data = await this.readBytes(parseInt(lit[1], 10));
        parts.push({ literal: data });
        continue;
      }
      if (line.startsWith(tag + " ")) {
        if (!/^\S+ OK/i.test(line)) throw new Error(command.split(" ")[0] + " 失败: " + line.slice(tag.length + 1));
        return { text, parts };
      }
    }
  }

  async login(user, pass) {
    await this.cmd(`LOGIN ${quote(user)} ${quote(pass)}`);
  }

  async close() {
    try {
      await withTimeout(this.cmd("LOGOUT"), 3000, "logout");
    } catch (_) {}
    try { await this.socket.close(); } catch (_) {}
  }
}

function withTimeout(p, ms, msg) {
  let t;
  return Promise.race([p, new Promise((_, rej) => { t = setTimeout(() => rej(new Error(msg)), ms); })]).finally(() => clearTimeout(t));
}

function quote(s) {
  return '"' + String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
}

/** 把 FETCH 响应拆成每封邮件：uid、flags、信头、正文开头 */
function parseFetch(res) {
  const out = [];
  let cur = null;
  let pending = null; // 上一个文字片段里，紧跟在 {n} 前面的项目名
  for (const p of res.parts) {
    if (p.text !== undefined) {
      const t = p.text;
      if (/^\* \d+ FETCH/i.test(t)) {
        cur = { uid: 0, flags: "", header: "", text: new Uint8Array(0) };
        out.push(cur);
      }
      if (!cur) continue;
      const u = /UID (\d+)/i.exec(t);
      if (u) cur.uid = parseInt(u[1], 10);
      const fl = /FLAGS \(([^)]*)\)/i.exec(t);
      if (fl) cur.flags = fl[1];
      pending = /BODY\[HEADER[^\]]*\](<\d+>)? \{\d+\}$/i.test(t) ? "header" : /BODY\[TEXT\](<\d+>)? \{\d+\}$/i.test(t) ? "text" : null;
    } else if (cur && pending) {
      if (pending === "header") cur.header = latin(p.literal);
      else cur.text = p.literal;
      pending = null;
    }
  }
  return out.filter((m) => m.uid > 0);
}

// ------------------------------------------------------------ MIME 小工具

function latin(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i += 4096) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 4096));
  return s;
}

function bytesOf(latinStr) {
  const b = new Uint8Array(latinStr.length);
  for (let i = 0; i < latinStr.length; i++) b[i] = latinStr.charCodeAt(i) & 255;
  return b;
}

function decodeBytes(bytes, charset) {
  let cs = (charset || "utf-8").toLowerCase().trim();
  if (cs === "gb2312" || cs === "x-gbk" || cs === "cp936") cs = "gbk";
  for (const c of [cs, cs === "gbk" ? "gb18030" : null, "utf-8"]) {
    if (!c) continue;
    try {
      return new TextDecoder(c).decode(bytes);
    } catch (_) {}
  }
  return dec.decode(bytes);
}

function parseHeaders(text) {
  const out = {};
  const unfolded = text.replace(/\r?\n[ \t]+/g, " ");
  for (const line of unfolded.split(/\r?\n/)) {
    const i = line.indexOf(":");
    if (i > 0) {
      const k = line.slice(0, i).trim().toLowerCase();
      if (!(k in out)) out[k] = line.slice(i + 1).trim();
    }
  }
  return out;
}

function decodeWords(s) {
  // 先把原始 8 位字节当 UTF-8（有些邮件信头直接用 UTF-8）
  let t = s;
  if (/[\x80-\xff]/.test(t)) t = decodeBytes(bytesOf(t), "utf-8");
  return t
    .replace(/\?=\s+=\?/g, "?==?")
    .replace(/=\?([^?]+)\?([BbQq])\?([^?]*)\?=/g, (_, cs, mode, data) => {
      try {
        const bytes = mode.toUpperCase() === "B" ? safeB64(data) : qp(data.replace(/_/g, " "));
        return decodeBytes(bytes, cs);
      } catch (_) {
        return data;
      }
    });
}

function safeB64(s) {
  let clean = s.replace(/[^A-Za-z0-9+/]/g, "");
  if (clean.length % 4 === 1) clean = clean.slice(0, -1); // 被截断的残片
  while (clean.length % 4) clean += "=";
  try { return bytesOf(atob(clean)); } catch (_) { return new Uint8Array(0); }
}

function qp(s) {
  const t = s.replace(/=\r?\n/g, "");
  const out = [];
  for (let i = 0; i < t.length; i++) {
    if (t[i] === "=" && /^[0-9A-Fa-f]{2}$/.test(t.substr(i + 1, 2))) {
      out.push(parseInt(t.substr(i + 1, 2), 16));
      i += 2;
    } else {
      out.push(t.charCodeAt(i) & 255);
    }
  }
  return new Uint8Array(out);
}

function preview(h, textBytes, limit = 160) {
  try {
    let ctype = (h["content-type"] || "text/plain").toLowerCase();
    let cte = (h["content-transfer-encoding"] || "").toLowerCase();
    let raw = latin(textBytes);
    // 多段邮件：取第一个 text/plain（没有就 text/html）段
    const bm = /boundary="?([^";]+)"?/i.exec(h["content-type"] || "");
    if (ctype.startsWith("multipart") && bm) {
      const segs = raw.split("--" + bm[1]).slice(1);
      let pick = null;
      for (const want of ["text/plain", "text/html"]) {
        for (const seg of segs) {
          const sp = seg.search(/\r?\n\r?\n/);
          if (sp < 0) continue;
          const ph = parseHeaders(seg.slice(0, sp));
          const pt = (ph["content-type"] || "text/plain").toLowerCase();
          if (pt.startsWith(want)) { pick = { ph, body: seg.slice(sp).replace(/^\r?\n\r?\n/, "") }; break; }
          if (pt.startsWith("multipart")) {
            const ib = /boundary="?([^";]+)"?/i.exec(ph["content-type"] || "");
            if (ib) {
              for (const inner of seg.split("--" + ib[1]).slice(1)) {
                const isp = inner.search(/\r?\n\r?\n/);
                if (isp < 0) continue;
                const iph = parseHeaders(inner.slice(0, isp));
                if ((iph["content-type"] || "text/plain").toLowerCase().startsWith(want)) {
                  pick = { ph: iph, body: inner.slice(isp).replace(/^\r?\n\r?\n/, "") };
                  break;
                }
              }
            }
          }
          if (pick) break;
        }
        if (pick) break;
      }
      if (!pick) return "";
      ctype = (pick.ph["content-type"] || "text/plain").toLowerCase();
      cte = (pick.ph["content-transfer-encoding"] || "").toLowerCase();
      raw = pick.body;
      h = pick.ph;
    }
    const cs = (/charset="?([^";\s]+)"?/i.exec(h["content-type"] || "") || [])[1] || "utf-8";
    let bytes = cte === "base64" ? safeB64(raw) : cte === "quoted-printable" ? qp(raw) : bytesOf(raw);
    let text = decodeBytes(bytes, cs);
    if (ctype.includes("html")) {
      text = text.replace(/<(style|script|head)[^>]*>[\s\S]*?<\/\1>/gi, " ").replace(/<[^>]+>/g, " ")
        .replace(/&nbsp;/g, " ").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&").replace(/&quot;/g, '"');
    }
    const lines = [];
    for (const line of text.split(/\r?\n/)) {
      const s = line.trim();
      if (!s || s.startsWith(">")) continue;
      if (/^(-{2,}|_{5,})\s*$/.test(s)) break;
      if (/^(On .* wrote:|在.*写道[:：]|-----Original Message-----|发件人[:：]|From:)/.test(s)) break;
      lines.push(s);
    }
    let out = lines.join(" ").replace(/\[cid:[^\]]*\]|<mailto:[^>]*>|<https?:\/\/[^>]*>/g, "").replace(/\s+/g, " ").trim();
    return out.length > limit ? out.slice(0, limit) + "…" : out;
  } catch (_) {
    return "";
  }
}

// 测试用
export const _internal = { parseFetch, decodeWords, preview, parseHeaders, Imap, checkAccount, handleForwarded };
