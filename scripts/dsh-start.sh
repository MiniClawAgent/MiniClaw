#!/bin/bash
# dsh (deepseek-harness) 一键启动脚本
# 用法:~/dsh-start.sh    —— 启动服务,浏览器打开 http://127.0.0.1:3080
set -e

# npm 缓存被 root 占用时的绕行(本机已知问题)——必须 export,否则 npx 读不到
export npm_config_cache=/tmp/npm-cache

# 端口已被占用(服务已在跑)→ 直接提示打开
if lsof -iTCP:3080 -sTCP:LISTEN >/dev/null 2>&1; then
    echo "dsh 服务已在运行,直接打开:http://127.0.0.1:3080"
    open http://127.0.0.1:3080
    exit 0
fi

echo "正在启动 dsh web 服务(首次下载包可能需要 1-2 分钟)..."
cd /tmp
nohup npx -y @deepseek-ai/dsh web > ~/dsh-web.log 2>&1 &

# 等待端口就绪(最多 120 秒,每 3 秒报一次进度)
for i in $(seq 1 40); do
    sleep 3
    if lsof -iTCP:3080 -sTCP:LISTEN >/dev/null 2>&1; then
        echo "启动成功,正在打开:http://127.0.0.1:3080"
        open http://127.0.0.1:3080
        exit 0
    fi
    if [ $((i % 5)) -eq 0 ]; then
        echo "  等待中($((i * 3))s)... 日志:$(wc -c < ~/dsh-web.log 2>/dev/null || echo 0) 字节"
    fi
done

echo "启动超时,最后日志:"
tail -20 ~/dsh-web.log
echo "提示:若日志为空,请手动前台运行确认:"
echo "  cd /tmp && export npm_config_cache=/tmp/npm-cache && npx -y @deepseek-ai/dsh web"
exit 1
