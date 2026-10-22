# Cursor 额度条

在本机屏幕最上方显示当前 Cursor 账号的真实用量。数字在菜单栏 `Cursor 55%` 项里，和 Codex 用量提醒并排；顶端只留 2pt 进度线。不挡 WPS/Excel 表头，也不盖其他菜单栏用量项。

## 启动

```bash
quota-bar/scripts/start.sh
```

登录后自动启动：

```bash
quota-bar/scripts/install-login.sh
```

只拉一次真实额度、不弹窗：

```bash
quota-bar/scripts/build.sh
quota-bar/build/Cursor额度条.app/Contents/MacOS/QuotaBar --once
```

停止：

```bash
quota-bar/scripts/stop.sh
```

默认每 60 秒刷新。演示可加快：

```bash
QUOTA_BAR_REFRESH_SECONDS=10 quota-bar/scripts/start.sh
```

## 数据从哪来

1. 只读本机 Cursor 登录令牌：`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` 的 `cursorAuth/accessToken`
2. 用该会话请求 Cursor 官网用量接口：`GET https://cursor.com/api/usage-summary`
3. 条上只显示接口里真实存在的字段。读不到就显示中文错误，不编数字。

最近一次结果写在：

`~/Library/Application Support/CursorQuotaBar/last-snapshot.json`
