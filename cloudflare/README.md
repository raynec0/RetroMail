# 用 Cloudflare 免费推送新邮件（不需要自己的服务器）

`worker.js` 是一个 Cloudflare Worker，同时提供两种方式，同一封邮件只推送一次（按 Message-ID 去重）：

| 方式 | 延迟 | 需要什么 |
|---|---|---|
| A. 每分钟登录邮箱检查 | ≤ 1 分钟 | 邮箱的 IMAP 地址和密码（存成 Cloudflare 机密变量） |
| B. 收到转发的副本立即推送 | 几秒 | 一个托管在 Cloudflare 的域名 + 公司邮箱允许自动转发 |

通知通过 **Bark**（App Store 免费）推到 iPhone，点通知会直接在 RetroMail 里打开那封邮件。

---

## 准备
1. iPhone 安装 Bark，复制 Key。
2. RetroMail → 设置 → **即时推送**：填 Bark Key → “发一条测试通知”确认能收到 → 点 **“拷贝 CONFIG”**（会自动带上邮箱密码，只用于粘贴到 Cloudflare）。

## 一、部署 Worker（网页控制台，约 5 分钟）
1. 打开 dash.cloudflare.com → **Workers & Pages** → **Create** → **Create Worker**，名字填 `retromail-push` → **Deploy**。
2. 点 **Edit code**，把本文件夹里 `worker.js` 的全部内容粘贴进去，替换原来的代码 → **Deploy**。
3. 创建 KV：左侧 **Storage & Databases → KV → Create**，名字随意（如 `retromail-state`）。
4. 回到 Worker → **Settings → Bindings → Add → KV namespace**：变量名填 **`STATE`**，选刚建的 KV。
5. **Settings → Variables and Secrets → Add**：类型选 **Secret**，名称 **`CONFIG`**，值粘贴 RetroMail 里拷贝的内容 → **Deploy**。
6. **Settings → Trigger Events（触发器）→ Add → Cron Triggers**：填 `* * * * *`（每分钟）。
7. 复制 Worker 的地址（`https://retromail-push.你的子域.workers.dev`），填到 RetroMail → 即时推送 → “Worker 地址”，点 **“让 Worker 发测试通知”** 和 **“立即检查”**。
   第一次“立即检查”会显示 `initialized at …`（只记录位置，不推旧邮件），之后有新邮件就会推送。

至此方式 A 已经生效。

## 二、开启秒到（方式 B）
1. Cloudflare → 你的域名 → **Email → Email Routing**，按提示启用（会自动添加 MX 等 DNS 记录）。
   > 如果这个域名已经在别处收邮件（MX 指向别的邮件服务），启用 Email Routing 会接管它的收信；那就换一个子域名或另一个不收信的域名。
2. **Routing rules → Create address**：自定义地址填 `push`（即 `push@你的域名`），动作选 **Send to a Worker**，选 `retromail-push` → 保存。
3. 在**公司邮箱网页版**里设置自动转发：转发到 `push@你的域名`，并选择 **“保留副本 / 转发后在收件箱保留”**。
   - 腾讯企业邮：设置 → 收信规则 / 自动转发；网易企业邮：设置 → 来信分类 / 自动转发；Exchange / Outlook：规则 → 转发副本。
4. 给自己发一封测试邮件，几秒内应该收到 Bark 通知。

Worker 收到副本后只读取开头 64 KB（信头和正文开头），推送后**直接丢弃**，不会转存到任何地方。

## 常见问题
- **看运行情况**：打开 `https://你的Worker地址/status?token=口令`（口令在 CONFIG 的 `token` 字段），可以看到上次检查时间和每个邮箱的结果；或在 Cloudflare → Worker → **Logs** 里看实时日志。
- **登录失败**：很多企业邮箱需要“客户端专用密码 / 授权码”，并在邮箱设置里开启 IMAP。
- **连不上邮件服务器**：Cloudflare Worker 不能连接 Cloudflare 自己的 IP 和内网地址；如果公司邮件服务器在内网或挂在 Cloudflare 后面，只能用方式 B，或用 `relay/` 里的程序在自己的机器上跑。
- **免费额度**：每分钟一次一天是 1440 次，远低于每天 10 万次的免费请求额度。免费计划每次运行的 CPU 时间是 10 毫秒（等网络的时间不算）；如果日志里出现 “Exceeded CPU” ，升级到 Workers Paid（每月 5 美元）即可。
- **隐私**：推送内容（发件人、主题、开头一两行）会经过 Bark 的服务器。介意的话在 CONFIG 里把 `"preview": false`，或改用自建的 bark-server / ntfy。
- **两种方式会不会重复推送**：不会。按 Message-ID 去重，先到的那个推送，后到的跳过。
