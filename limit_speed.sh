bash <(cat << 'EOF'
#!/bin/bash

# --- 检查是否以root用户运行 ---
if [[ "$EUID" -ne 0 ]]; then
  echo "此脚本必须以root用户身份运行。请使用 sudo。"
  exit 1
fi

# ================= 交互式输入配置 =================
echo "=========================================="
echo "    欢迎使用 v2node 测速与自动开关配置脚本"
echo "=========================================="

read -p "1. 请输入你的 Telegram Bot Token: " TG_BOT_TOKEN
read -p "2. 请输入你的 Telegram Chat ID: " TG_CHAT_ID

if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
    echo "❌ 错误：Token 和 Chat ID 不能为空，请重新运行脚本！"
    exit 1
fi

# 交互式设定测速阈值
read -p "3. 请输入达标阈值 (单位: Mbps，默认 100): " INPUT_THRESHOLD
THRESHOLD_MBPS=${INPUT_THRESHOLD:-100}

# 交互式设定连续触发次数
read -p "4. 请输入连续触发次数 (默认 3 次): " INPUT_MAX_COUNT
MAX_COUNT=${INPUT_MAX_COUNT:-3}

MONITOR_SCRIPT="/usr/local/bin/speedtest_monitor.sh"
CRON_JOB="0 */12 * * * sudo $MONITOR_SCRIPT > /dev/null 2>&1"

echo ""
echo "--- 当前设置配置 ---"
echo "Telegram Chat ID : $TG_CHAT_ID"
echo "带宽达标阈值     : ${THRESHOLD_MBPS} Mbps"
echo "连续判断次数     : ${MAX_COUNT} 次"
echo "--------------------"
echo "正在生成监控脚本 ${MONITOR_SCRIPT} ..."

# 写入子脚本内容（已修复负数计数校验 Bug）
cat << 'SUBEOF' > "$MONITOR_SCRIPT"
#!/bin/bash

# 环境变量设置
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- 参数配置 ---
threshold_mbps=${THRESHOLD_MBPS}
MAX_COUNT=${MAX_COUNT}
test_file_size=10
test_url="https://speed.cloudflare.com/__down?bytes=10485760"
STATE_FILE="/tmp/speedtest_fail_count"

# Telegram 配置
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"

# --- TG 通知函数 ---
send_tg_msg() {
    local message="\$1"
    if [ -n "\$TG_BOT_TOKEN" ] && [ -n "\$TG_CHAT_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot\${TG_BOT_TOKEN}/sendMessage" \
            -d "chat_id=\${TG_CHAT_ID}" \
            -d "text=\${message}" \
            -d "parse_mode=Markdown" > /dev/null
    fi
}

# --- 依赖检查 ---
for pkg in curl bc; do
    if ! command -v "\$pkg" &> /dev/null; then
        apt-get update && apt-get install -y "\$pkg"
    fi
done

# 读取当前计数
if [ -f "\$STATE_FILE" ]; then
    fail_count=\$(cat "\$STATE_FILE")
else
    fail_count=0
fi

# 修复：允许负号开头的合法数字通过校验，防止负数被清零
case "\$fail_count" in
    ''|*[!0-9-]*) fail_count=0 ;;
esac

# --- 核心测速逻辑 ---
start_time=\$(date +%s.%N)
http_code=\$(curl -s -o /dev/null -w "%{http_code}" "\$test_url")

if [ "\$http_code" -ne 200 ]; then
    msg="⚠️ 测速异常%0A节点：\$(hostname)%0A状态：测速文件下载失败 (HTTP \$http_code)"
    send_tg_msg "\$msg"
    exit 1
fi

end_time=\$(date +%s.%N)
duration=\$(echo "\$end_time - \$start_time" | bc)
download_speed_mbps=\$(echo "scale=2; (\$test_file_size * 8) / \$duration" | bc)

# 获取当前 v2node 服务运行状态
v2node_status=\$(v2node status 2>&1)

# --- 防抖动与状态切换逻辑 ---
is_below=\$(echo "\$download_speed_mbps < \$threshold_mbps" | bc -l)

if [ "\$is_below" -eq 1 ]; then
    # 速度低于阈值 (累加正数)
    if [ "\$fail_count" -lt 0 ]; then
        fail_count=1
    else
        fail_count=\$((fail_count + 1))
    fi
    
    # 封顶：最大不超过 MAX_COUNT
    [ "\$fail_count" -gt "\$MAX_COUNT" ] && fail_count="\$MAX_COUNT"
    
    echo "\$fail_count" > "\$STATE_FILE"

    if [ "\$fail_count" -ge "\$MAX_COUNT" ]; then
        action="🔴 连续 \${fail_count} 次低于阈值，已停止 v2node"
        if ! echo "\$v2node_status" | grep -qE "Stopped|not running|未运行"; then
            v2node stop
        fi
    else
        action="⚠️ 速度不达标 (\${fail_count}/\${MAX_COUNT} 次)，v2node 保持当前状态"
    fi
else
    # 速度高于阈值 (累加负数，用绝对值表示成功次数)
    if [ "\$fail_count" -gt 0 ]; then
        fail_count=-1
    else
        fail_count=\$((fail_count - 1))
    fi
    
    # 封顶：绝对值最大不超过 MAX_COUNT
    min_limit=\$(( -MAX_COUNT ))
    [ "\$fail_count" -lt "\$min_limit" ] && fail_count="\$min_limit"
    
    echo "\$fail_count" > "\$STATE_FILE"

    # 去掉负号计算绝对值
    abs_pass_count=\${fail_count#-}

    if [ "\$abs_pass_count" -ge "\$MAX_COUNT" ]; then
        action="✅ 连续 \${abs_pass_count} 次达标，v2node 启动/运行中"
        if echo "\$v2node_status" | grep -qE "Stopped|not running|未运行"; then
            v2node start
        fi
    else
        action="🟡 速度已恢复达标 (\${abs_pass_count}/\${MAX_COUNT} 次)，待连续达标后再开启"
    fi
fi

# --- 发送最终执行结果 ---
final_msg="📊 节点测速报告%0A--------------------%0A节点名称：\$(hostname)%0A实测带宽：\${download_speed_mbps} Mbps%0A判定阈值：\${threshold_mbps} Mbps%0A当前动作：\${action}"
send_tg_msg "\$final_msg"
SUBEOF

# 动态替换子脚本中的变量占位符
sed -i "s/\${TG_BOT_TOKEN}/${TG_BOT_TOKEN}/g" "$MONITOR_SCRIPT"
sed -i "s/\${TG_CHAT_ID}/${TG_CHAT_ID}/g" "$MONITOR_SCRIPT"
sed -i "s/\${THRESHOLD_MBPS}/${THRESHOLD_MBPS}/g" "$MONITOR_SCRIPT"
sed -i "s/\${MAX_COUNT}/${MAX_COUNT}/g" "$MONITOR_SCRIPT"

# 赋予执行权限
chmod +x "$MONITOR_SCRIPT"

# --- 设置定时任务 ---
echo "--- 正在设置定时任务 ---"
(crontab -l 2>/dev/null | grep -F "${MONITOR_SCRIPT}" | grep -v "grep") || (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

echo ""
echo "✅ 安装完成！"
echo "监控脚本存放在：$MONITOR_SCRIPT"
echo "你可以直接执行 sudo $MONITOR_SCRIPT 立即运行一次测试。"
EOF
)
