#!/bin/bash
# dsh (deepseek-harness) web 一键启动 / 打开
#
# 服务本身由 launchd 托管(Label: com.neartop.dsh-web),本脚本只做三件事:
#   1. 确保 LaunchAgent 已加载
#   2. 确保服务在跑(没跑就让 launchd 拉起来)
#   3. 等端口就绪后打开浏览器
#
# 因此本脚本可以在任意终端运行、随开随关,不会把服务绑在终端上。
#
# 注意: 完整的管理功能(停止/重启/更新/重装/卸载/监控)已收敛到桌面脚本
#   ~/Desktop/DSH管理脚本.sh          ← 推荐日常使用
# 本脚本只保留"确保在跑 + 打开界面"这一个精简入口, 供终端里快速调用。
set -u

LABEL="com.neartop.dsh-web"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PORT="${DSH_WEB_PORT:-3080}"
URL="http://127.0.0.1:$PORT"
LOG="${DSH_WEB_LOG:-/tmp/dsh-web.log}"

port_busy() { /usr/sbin/lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; }

# 取日志里最新一次启动打印的带 token 入口链接。服务以 --no-open 启动, 这个链接
# 不会被自动消费; 带 token 访问会 303 重定向并建立浏览器会话(不带 token 则 401)。
ui_entry_url() {
    [ -f "$LOG" ] || return 0
    grep -o 'http://[^[:space:]]*token=[A-Za-z0-9_-]*' "$LOG" 2>/dev/null | tail -1
}

if ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    if [ ! -f "$PLIST" ]; then
        echo "错误:找不到 $PLIST" >&2
        echo "请先安装:cp MiniClaw/scripts/$LABEL.plist ~/Library/LaunchAgents/" >&2
        exit 1
    fi
    echo "LaunchAgent 未加载,正在加载…"
    launchctl bootstrap "$DOMAIN" "$PLIST" || exit 1
fi

if port_busy; then
    echo "dsh 服务已在运行:$URL"
else
    echo "正在通过 launchd 启动 dsh web 服务…"
    launchctl kickstart "$DOMAIN/$LABEL" >/dev/null 2>&1
fi

# 等待端口就绪(最多 120 秒,每 15 秒报一次进度)
for i in $(seq 1 8); do
    if port_busy; then
        ENTRY=$(ui_entry_url)
        [ -n "$ENTRY" ] || ENTRY="$URL"
        echo "启动成功,正在打开:"
        echo "  $ENTRY"
        open "$ENTRY"
        exit 0
    fi
    sleep 15
    echo "  等待中($((i * 15))s)… 日志:$LOG"
done

echo "启动超时,日志尾部:"
tail -20 "$LOG" 2>/dev/null || echo "(日志为空)"
echo "排查:launchctl print $DOMAIN/$LABEL | head -30"
exit 1
