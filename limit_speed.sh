#!/bin/bash

# ================= 配置区 =================
# 1. 在这里填入你的 TG 机器人信息
TG_BOT_TOKEN="你的_BOT_TOKEN"
TG_CHAT_ID="你的_CHAT_ID"

# 2. 定义监控脚本的路径和文件名
MONITOR_SCRIPT="/usr/local/bin/speedtest_monitor.sh"
# 定时任务：每12小时运行一次
CRON_JOB="0 */12 * * * sudo $MONITOR_SCRIPT > /dev/null 2>&1"
# ==========================================

# --- 检查是否以root用户运行 ---
if [[ "$EUID" -ne 0 ]]; then
  echo "此脚本必须以root用户身份运行。请使用 sudo。"
  exit 1
fi

echo "--- 正在创建带防误判（连续3次触发）功能的监控脚本 ${MONITOR_SCRIPT} ---"

# 写入子脚本内容
cat > "$MONITOR_SCRIPT" << EOF
#!/bin/bash

# 环境变量设置
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- 参数配置 ---
threshold_mbps=100      # 判定阈值 (Mbps)
test_file_size=10       # 测试文件大小 (MB)
test_url="https://speed.cloudflare.com/__down?bytes=10485760" 
MAX_COUNT=3             # 连续触发阈值次数
STATE_FILE="/tmp/speedtest_fail_count"  # 存储连续失败/成功计数的临时文件

# --- TG 通知函数 ---
send_tg_msg() {
    local message=\$1
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \\
        -d "chat_id=${TG_CHAT_ID}" \\
        -d "text=\$message" \\
        -d "parse_mode=Markdown"
}

# --- 依赖检查 ---
for pkg in curl bc; do
    if ! command -v \$pkg &> /dev/null; then
        apt-get update && apt-get install -y \$pkg
    fi
done

# 读取当前失败计数（如果文件不存在，默认为 0）
if [ -f "\$STATE_FILE" ]; then
    fail_count=\$(cat "\$STATE_FILE")
else
    fail_count=0
fi

# --- 核心测速逻辑 ---
start_time=\$(date +%s.%N)
http_code=\$(curl -s -o /dev/null -w "%{http_code}" "\$test_url")

if [ "\$http_code" -ne 200 ]; then
    msg="⚠️ *测速异常*\\n节点：\$(hostname)\\n状态：测速文件下载失败 (HTTP \$http_code)"
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
    # 速度低于阈值
    if [ "\$fail_count" -lt 0 ]; then
        fail_count=1
    else
        fail_count=\$((fail_count + 1))
    fi
    echo "\$fail_count" > "\$STATE_FILE"

    if [ "\$fail_count" -ge "\$MAX_COUNT" ]; then
        action="🔴 *连续 \${fail_count} 次低于阈值，已停止 v2node*"
        # 如果未停止，则执行停止命令
        [[ ! "\$v2node_status" =~ "Stopped" && ! "\$v2node_status" =~ "not running" && ! "\$v2node_status" =~ "未运行" ]] && v2node stop
    else
        action="⚠️ *速度不达标 (\${fail_count}/\${MAX_COUNT} 次)*\\nv2node 保持当前状态，暂不关闭"
    fi
else
    # 速度高于或等于阈值
    if [ "\$fail_count" -gt 0 ]; then
        fail_count=-1
    else
        fail_count=\$((fail_count - 1))
    fi
    echo "\$fail_count" > "\$STATE_FILE"

    abs_pass_count=\${fail_count#-} # 取绝对值显示连续成功次数

    if [ "\$abs_pass_count" -ge "\$MAX_COUNT" ]; then
        action="✅ *连续 \${abs_pass_count} 次达标，v2node 启动/运行中*"
        # 如果已停止，则执行开启命令
        [[ "\$v2node_status" =~ "Stopped" || "\$v2node_status" =~ "not running" || "\$v2node_status" =~ "未运行" ]] && v2node start
    else
        action="🟡 *速度已恢复达标 (\${abs_pass_count}/\${MAX_COUNT} 次)*\\nv2node 保持当前状态，待连续达标后再开启"
    fi
fi

# --- 发送最终执行结果 ---
final_msg="📊 *节点测速报告*\\n--------------------\\n节点名称：\$(hostname)\\n实测带宽：*\${download_speed_mbps} Mbps*\\n判定阈值：\${threshold_mbps} Mbps\\n当前动作：\${action}"
send_tg_msg "\$final_msg"

EOF

# 赋予执行权限
chmod +x "$MONITOR_SCRIPT"

# --- 设置定时任务 ---
echo "--- 正在设置定时任务 ---"
(crontab -l 2>/dev/null | grep -F "${MONITOR_SCRIPT}" | grep -v "grep") || (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

echo "安装完成！"
echo "监控脚本：$MONITOR_SCRIPT"
echo "已更新为控制 v2node 服务，并启用连续 3 次判定机制。"
