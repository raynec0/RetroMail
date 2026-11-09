#!/usr/bin/env python3
"""
RetroMail Push Relay —— 让 iPhone 在 RetroMail 关闭时也能“秒到”新邮件通知。

原理：自签安装的应用用不了苹果推送服务（APNs），所以由一台常开的机器（VPS、NAS、软路由、家里的电脑……）
用 IMAP IDLE 一直盯着收件箱，有新邮件就通过 Bark（或 ntfy）推送到手机；点通知会直接在 RetroMail 里打开这封邮件。

只用 Python 标准库，Python 3.8+。
用法：
    python3 retromail_push.py                 # 常驻运行（IDLE，实时）
    python3 retromail_push.py --once          # 只检查一次（给定时任务 / GitHub Actions 用）
    python3 retromail_push.py --test          # 发一条测试通知
配置：同目录的 config.json，或环境变量 RETROMAIL_PUSH_CONFIG 指定路径，
      或环境变量 RETROMAIL_PUSH_CONFIG_JSON 直接放 JSON 内容。
"""
import email
import html
import imaplib
import json
import logging
import os
import re
import socket
import ssl
import sys
import threading
import time
import urllib.parse
import urllib.request
from email.header import decode_header, make_header
from email.utils import parseaddr

log = logging.getLogger("retromail-push")

HERE = os.path.dirname(os.path.abspath(__file__))
STATE_PATH = os.environ.get("RETROMAIL_PUSH_STATE", os.path.join(HERE, "state.json"))
_state_lock = threading.Lock()


# ---------------------------------------------------------------- 配置 / 状态

def load_config():
    raw = os.environ.get("RETROMAIL_PUSH_CONFIG_JSON")
    if raw:
        return json.loads(raw)
    path = os.environ.get("RETROMAIL_PUSH_CONFIG", os.path.join(HERE, "config.json"))
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def load_state():
    try:
        with open(STATE_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def save_state(state):
    with _state_lock:
        tmp = STATE_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(state, f)
        os.replace(tmp, STATE_PATH)


# ---------------------------------------------------------------- 文本处理

def decode_words(value):
    if not value:
        return ""
    try:
        return str(make_header(decode_header(value))).strip()
    except Exception:
        return value.strip()


def preview_text(header_bytes, text_bytes, limit=160):
    """从邮件开头的一小段里取出可读的正文预览。"""
    try:
        msg = email.message_from_bytes(header_bytes.rstrip(b"\r\n") + b"\r\n\r\n" + text_bytes)
        parts = list(msg.walk()) if msg.is_multipart() else [msg]
        chosen = None
        for want in ("text/plain", "text/html"):
            for p in parts:
                if p.get_content_type() == want:
                    chosen = p
                    break
            if chosen:
                break
        if chosen is None:
            return ""
        payload = chosen.get_payload(decode=True) or b""
        charset = chosen.get_content_charset() or "utf-8"
        try:
            text = payload.decode(charset, errors="replace")
        except LookupError:
            text = payload.decode("utf-8", errors="replace")
        if chosen.get_content_type() == "text/html":
            text = re.sub(r"(?is)<(style|script|head)[^>]*>.*?</\1>", " ", text)
            text = re.sub(r"(?s)<[^>]+>", " ", text)
            text = html.unescape(text)
        # 去掉引用、签名分隔线、链接杂项
        lines = []
        for line in text.splitlines():
            s = line.strip()
            if not s or s.startswith(">"):
                continue
            if re.match(r"^(-{2,}|_{5,})\s*$", s):
                break
            if re.match(r"^(On .* wrote:|在.*写道[:：]|-----Original Message-----|发件人[:：]|From:)", s):
                break
            lines.append(s)
        text = re.sub(r"\[cid:[^\]]*\]|<mailto:[^>]*>|<https?://[^>]*>", "", " ".join(lines))
        text = re.sub(r"\s+", " ", text).strip()
        return text[:limit] + ("…" if len(text) > limit else "")
    except Exception:
        return ""


# ---------------------------------------------------------------- 推送

def push(cfg, account, title, subtitle, body, url):
    p = cfg.get("push", {})
    kind = (p.get("type") or "bark").lower()
    if kind == "bark":
        server = (p.get("server") or "https://api.day.app").rstrip("/")
        payload = {
            "device_key": p["key"],
            "title": title,
            "subtitle": subtitle,
            "body": body or " ",
            "group": p.get("group") or account.get("name") or "RetroMail",
            "url": url,
            "level": p.get("level") or "timeSensitive",
        }
        if p.get("sound"):
            payload["sound"] = p["sound"]
        if p.get("icon"):
            payload["icon"] = p["icon"]
        if p.get("archive") is not None:
            payload["isArchive"] = 1 if p["archive"] else 0
        req = urllib.request.Request(server + "/push", data=json.dumps(payload).encode("utf-8"),
                                     headers={"Content-Type": "application/json; charset=utf-8"})
    elif kind == "ntfy":
        server = (p.get("server") or "https://ntfy.sh").rstrip("/")
        payload = {
            "topic": p["topic"],
            "title": title,
            "message": (subtitle + "\n" + body).strip() or " ",
            "click": url,
            "tags": ["envelope"],
            "priority": int(p.get("priority") or 4),
        }
        headers = {"Content-Type": "application/json; charset=utf-8"}
        if p.get("token"):
            headers["Authorization"] = "Bearer " + p["token"]
        req = urllib.request.Request(server, data=json.dumps(payload).encode("utf-8"), headers=headers)
    else:
        raise ValueError("push.type 只能是 bark 或 ntfy")
    with urllib.request.urlopen(req, timeout=20) as r:
        r.read()


def open_url(account, folder, uid):
    q = urllib.parse.urlencode({"email": account.get("email") or account["username"], "folder": folder, "uid": uid})
    return "retromail://open?" + q


# ---------------------------------------------------------------- IMAP

class Watcher(threading.Thread):
    def __init__(self, cfg, account, state):
        super().__init__(daemon=True, name=account.get("name") or account["username"])
        self.cfg = cfg
        self.acc = account
        self.state = state
        self.key = (account.get("email") or account["username"]).lower()
        self.folder = account.get("folder") or "INBOX"
        self.preview = cfg.get("preview", True)

    # -- 连接
    def connect(self):
        host = self.acc["host"]
        port = int(self.acc.get("port") or 993)
        ctx = ssl.create_default_context()
        if self.acc.get("allow_insecure"):
            # 服务器用自签证书时（与 RetroMail 里“允许不安全的证书”对应）
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        if self.acc.get("ssl", port == 993):
            M = imaplib.IMAP4_SSL(host, port, ssl_context=ctx, timeout=60)
        else:
            M = imaplib.IMAP4(host, port, timeout=60)
            if self.acc.get("starttls", True):
                M.starttls(ssl_context=ctx)
        M.login(self.acc["username"], self.acc["password"])
        # 有的国内企业邮箱（如网易）要求先发 ID
        if "ID" in M.capabilities:
            try:
                tag = M._new_tag()
                M.send(tag + b' ID ("name" "RetroMail" "version" "1.0")\r\n')
                while True:
                    line = M.readline()
                    if not line or line.startswith(tag):
                        break
            except Exception:
                pass
        typ, _ = M.select(self.mailbox(), readonly=True)
        if typ != "OK":
            raise RuntimeError("无法打开文件夹 " + self.folder)
        return M

    def mailbox(self):
        f = self.folder
        return '"' + f.replace('"', '\\"') + '"' if " " in f else f

    def uidnext(self, M):
        typ, data = M.status(self.mailbox(), "(UIDNEXT)")
        m = re.search(rb"UIDNEXT (\d+)", data[0] or b"")
        return int(m.group(1)) if m else 0

    # -- IDLE：等到有变化（True）或超时（False）
    def idle(self, M, seconds):
        tag = M._new_tag()
        M.send(tag + b" IDLE\r\n")
        line = M.readline()
        if not line.startswith(b"+"):
            raise RuntimeError("服务器不支持 IDLE: " + line.decode(errors="replace"))
        M.sock.settimeout(seconds)
        changed = False
        try:
            while True:
                line = M.readline()
                if not line:
                    raise EOFError("连接已断开")
                u = line.upper()
                if u.startswith(b"* BYE"):
                    raise EOFError("服务器断开")
                if b"EXISTS" in u or b"RECENT" in u:
                    changed = True
                    break
        except (socket.timeout, TimeoutError):
            pass
        M.sock.settimeout(60)
        M.send(b"DONE\r\n")
        while True:
            line = M.readline()
            if not line:
                raise EOFError("连接已断开")
            if line.startswith(tag):
                break
        return changed

    # -- 取新邮件并推送
    def check(self, M):
        last = int(self.state.get(self.key, 0))
        nxt = self.uidnext(M)
        if last == 0 or nxt < last:
            # 第一次运行，或者文件夹重建了：只记录位置，不推送旧邮件
            self.state[self.key] = nxt
            save_state(self.state)
            return 0
        if nxt <= last:
            return 0
        M.select(self.mailbox(), readonly=True)
        typ, data = M.uid("search", None, "UID %d:*" % last)
        uids = [int(x) for x in (data[0] or b"").split() if int(x) >= last]
        sent = 0
        for uid in sorted(uids)[-10:]:
            try:
                self.notify(M, uid)
                sent += 1
            except Exception as e:
                log.warning("[%s] 推送 UID %s 失败：%s", self.name, uid, e)
        self.state[self.key] = max([nxt] + [u + 1 for u in uids])
        save_state(self.state)
        return sent

    def notify(self, M, uid):
        typ, data = M.uid("fetch", str(uid),
                          "(FLAGS BODY.PEEK[HEADER.FIELDS (FROM SUBJECT CONTENT-TYPE CONTENT-TRANSFER-ENCODING MIME-VERSION)])")
        header = b""
        flags = b""
        for item in data:
            if isinstance(item, tuple):
                flags += item[0]
                header = item[1]
        if b"\\Seen" in flags:
            return  # 已经在别处读过了
        msg = email.message_from_bytes(header)
        name, addr = parseaddr(decode_words(msg.get("From", "")))
        sender = name or addr or "新邮件"
        subject = decode_words(msg.get("Subject", "")) or "（无主题）"
        body = ""
        if self.preview:
            typ, tdata = M.uid("fetch", str(uid), "(BODY.PEEK[TEXT]<0.2000>)")
            text = b""
            for item in tdata:
                if isinstance(item, tuple):
                    text = item[1]
            body = preview_text(header, text)
        if len(self.cfg.get("accounts", [])) > 1:
            body = (body + "\n— " + (self.acc.get("name") or self.key)).strip()
        if not self.preview:
            subject = subject if self.cfg.get("show_subject", True) else "你有一封新邮件"
        push(self.cfg, self.acc, sender, subject, body, open_url(self.acc, self.folder, uid))
        log.info("[%s] 已推送：%s - %s", self.name, sender, subject)

    # -- 常驻循环
    def run(self):
        backoff = 5
        while True:
            M = None
            try:
                M = self.connect()
                log.info("[%s] 已连接，开始监听 %s", self.name, self.folder)
                backoff = 5
                self.check(M)
                can_idle = "IDLE" in M.capabilities
                while True:
                    if can_idle:
                        # 多数服务器 29 分钟断开 IDLE；家宽 / 运营商 NAT 可能更早，这里 10 分钟重新进入一次
                        self.idle(M, int(self.cfg.get("idle_seconds", 600)))
                        M.noop()
                    else:
                        time.sleep(int(self.cfg.get("poll_seconds", 60)))
                        M.noop()
                    self.check(M)
            except Exception as e:
                log.warning("[%s] 连接出错：%s；%d 秒后重连", self.name, e, backoff)
                time.sleep(backoff)
                backoff = min(backoff * 2, 300)
            finally:
                try:
                    if M is not None:
                        M.logout()
                except Exception:
                    pass


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    cfg = load_config()
    state = load_state()
    accounts = cfg.get("accounts", [])
    if not accounts:
        sys.exit("config.json 里没有 accounts")
    if "--test" in sys.argv:
        a = accounts[0]
        push(cfg, a, "RetroMail", "推送中继测试", "能看到这条通知，说明推送设置正确。点一下会打开 RetroMail。",
             "retromail://open")
        print("已发送测试通知")
        return
    if "--once" in sys.argv:
        total = 0
        for a in accounts:
            w = Watcher(cfg, a, state)
            M = None
            try:
                M = w.connect()
                total += w.check(M)
            except Exception as e:
                log.warning("[%s] 检查失败：%s", w.name, e)
            finally:
                try:
                    if M is not None:
                        M.logout()
                except Exception:
                    pass
        log.info("检查完成，推送 %d 封", total)
        return
    threads = [Watcher(cfg, a, state) for a in accounts]
    for t in threads:
        t.start()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
