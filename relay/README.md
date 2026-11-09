# RetroMail 推送中继（关掉应用也能秒收新邮件通知）

自签安装的应用用不了苹果推送（APNs），iOS 也不允许普通应用在后台一直联网，所以 RetroMail 关掉以后只能等 iOS 偶尔唤醒它。
这个中继程序和 Gmail、Spark 的做法一样：在一台**常开的机器**上用 IMAP IDLE 盯着收件箱，有新邮件就通过 **Bark** 推到 iPhone，
点通知直接在 RetroMail 里打开那封邮件。邮件密码只存在你自己的机器上。

## 1. 手机上
1. App Store 安装免费的 **Bark**，打开后复制推送地址 `https://api.day.app/XXXX/` 里的 `XXXX`（Key）。
2. RetroMail → 设置 → **即时推送** → 填入 Key → “发一条测试通知”。
3. 在同一页“拷贝配置 / 共享配置文件”，得到 `config.json`（也可以照 `config.example.json` 自己写）。

## 2. 常开的机器上（三选一）

**直接运行**（Python 3.8+，无需安装任何库）：
```bash
cd relay
python3 retromail_push.py --test   # 先发一条测试通知
python3 retromail_push.py          # 常驻运行；可以用 systemd / screen / nohup 保持后台
```

**Docker**：
```bash
cd relay
mkdir -p data && cp config.json data/
docker compose up -d --build
docker logs -f retromail-push
```

**systemd**（示例 `/etc/systemd/system/retromail-push.service`）：
```ini
[Unit]
Description=RetroMail Push Relay
After=network-online.target
[Service]
WorkingDirectory=/opt/retromail-push
ExecStart=/usr/bin/python3 /opt/retromail-push/retromail_push.py
Restart=always
[Install]
WantedBy=multi-user.target
```

没有常开的机器：可以用 `github-actions-mail-push.yml`（GitHub Actions 每 5 分钟检查一次，不是实时，说明见文件开头）。

## 3. 回到 RetroMail
设置 → 即时推送 → 打开“我已经在用推送中继”。这样 RetroMail 自己就不再弹重复通知，“后台保持在线”也可以关掉，最省电。

## 隐私
- 推送内容（发件人、主题、开头一两行）会经过 Bark 的服务器。介意的话：在配置里把 `preview` 设为 `false`，
  或自建 bark-server（`push.server` 改成你的地址），或改用 ntfy：`"push": {"type": "ntfy", "server": "https://ntfy.sh", "topic": "一个很难猜的名字"}`。
- 邮箱密码只在你的机器上，不会发给任何人。建议使用邮箱的“客户端专用密码 / 授权码”。
