#!/bin/bash

# --- 检查是否以root用户运行 ---
if [[ "$EUID" -ne 0 ]]; then
  echo "此脚本必须以root用户身份运行。请使用 sudo。"
  exit 1
fi

# ================= 1. 交互式输入配置 =================
echo "=========================================="
echo "    欢迎使用节点测速与自动开关配置脚本"
echo "=========================================="

read -p "1. 请输入你的 Telegram Bot Token: " TOKEN
read -p "2. 请输入你的 Telegram Chat ID: " CHAT_ID

if [ -z "$TOKEN" ] || [ -z "$CHAT_ID" ]; then
    echo "❌ 错误：Token 和 Chat ID 不能为空，请重新运行脚本！"
    exit 1
fi

read -p "3. 请输入带宽判定阈值 (Mbps, 默认 100): " threshold_mbps
threshold_mbps=${threshold_mbps:-100}

read -p "4. 请输入当前节点显示名称 (默认获取系统主机名): " node_name
node_name=${node_name:-$(hostname)}

read -p "5. 请输入执行间隔 (分钟, 默认 59): " interval_min
interval_min=${interval_min:-59}

MONITOR_SCRIPT="/usr/local/bin/speedtest_monitor.sh"

echo ""
echo "--- 当前设置配置 ---"
echo "Telegram Chat ID : $CHAT_ID"
echo "节点显示名称     : $node_name"
echo "带宽达标阈值     : ${threshold_mbps} Mbps"
echo "执行间隔         : ${interval_min} 分钟"
echo "--------------------"
echo "正在生成监控脚本 ${MONITOR_SCRIPT} ..."

# ================= 2. 写入监控脚本 (使用单引号 EOF 避免变量提前解析) =================
cat > "$MONITOR_SCRIPT" << 'EOF'
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

TOKEN="TOKEN_PLACEHOLDER"
CHAT_ID="CHAT_ID_PLACEHOLDER"
NODE_NAME="NODE_NAME_PLACEHOLDER"
THRESHOLD="THRESHOLD_PLACEHOLDER"

STATUS_FILE="/tmp/node_speed_status.txt"
COUNT_FILE="/tmp/node_check_count.txt"
TEST_URL="https://speed.cloudflare.com/__down?bytes=10485760"
TEST_FILE_SIZE=10

[ ! -f "$STATUS_FILE" ] && echo "1" > "$STATUS_FILE"
[ ! -f "$COUNT_FILE" ] && echo "0" > "$COUNT_FILE"
old_status=$(cat "$STATUS_FILE")
current_count=$(cat "$COUNT_FILE")

# 确保读取到的状态和计数器不是空的
[ -z "$old_status" ] && old_status="1"
[ -z "$current_count" ] && current_count="0"

send_tg_msg() {
    curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        -d "text=$1" \
        -d "parse_mode=Markdown"
}

# 测速
do_speedtest() {
    local start=$(date +%s.%N)
    local code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 "$TEST_URL")
    if [ "$code" -ne 200 ]; then echo "0.00"; return; fi
    local end=$(date +%s.%N)
    local duration=$(echo "$end - $start" | bc)
    echo "scale=2; ($TEST_FILE_SIZE * 8) / $duration" | bc | awk '{if($1=="") print "0.00"; else print $1}'
}

speed=$(do_speedtest)
[ -z "$speed" ] && speed="0.00"

# 比较
is_low=$(awk -v s="$speed" -v t="$THRESHOLD" 'BEGIN {print (s < t) ? 1 : 0}')

if [ "$is_low" -eq 1 ]; then
    # --- 情况 A: 速度【不达标】 ---
    if [ "$current_count" -gt 0 ]; then
        new_count=-1  # 如果之前是达标的，现在立刻反转为失败1次
    else
        new_count=$((current_count - 1)) # 持续失败，累计负数
    fi
    # 限制计数器下限，防止无限减小
    [ "$new_count" -lt -5 ] && new_count=-5
    echo "$new_count" > "$COUNT_FILE"
    
    # 触发关闭：连续 3 次失败且当前开启
    if [ "$new_count" -le -3 ] && [ "$old_status" == "1" ]; then
        xrayr stop &>/dev/null; v2bx stop &>/dev/null; v2node stop &>/dev/null
        echo "0" > "$STATUS_FILE"
        msg=$(echo -e "⚠️ 节点异常报警\n节点：${NODE_NAME}\n状态：连续 3 次不达标\n速度：$speed Mbps\n动作：🔴 停止服务")
        send_tg_msg "$msg"
    fi
else
    # --- 情况 B: 速度【达标】 ---
    if [ "$current_count" -lt 0 ]; then
        new_count=1   # 如果之前是不达标的，现在立刻反转为成功1次
    else
        new_count=$((current_count + 1)) # 持续达标，累计正数
    fi
    # 限制计数器上限，防止无限增加 (最高到 5)
    [ "$new_count" -gt 5 ] && new_count=5
    echo "$new_count" > "$COUNT_FILE"

    # 触发开启：连续 3 次成功且当前关闭
    if [ "$new_count" -ge 3 ] && [ "$old_status" == "0" ]; then
        xrayr start &>/dev/null; v2bx start &>/dev/null; v2node start &>/dev/null
        echo "1" > "$STATUS_FILE"
        msg=$(echo -e "✅ 节点恢复报告\n节点：${NODE_NAME}\n状态：连续 3 次已达标\n速度：$speed Mbps\n动作：🟢 开启服务")
        send_tg_msg "$msg"
    fi
fi
EOF

# ================= 3. 动态注入用户输入的值 =================
sed -i "s@TOKEN_PLACEHOLDER@$TOKEN@g" "$MONITOR_SCRIPT"
sed -i "s@CHAT_ID_PLACEHOLDER@$CHAT_ID@g" "$MONITOR_SCRIPT"
sed -i "s@NODE_NAME_PLACEHOLDER@$node_name@g" "$MONITOR_SCRIPT"
sed -i "s@THRESHOLD_PLACEHOLDER@$threshold_mbps@g" "$MONITOR_SCRIPT"

# 设置权限与定时任务
chmod +x "$MONITOR_SCRIPT"
(crontab -l 2>/dev/null | grep -v "speedtest_monitor.sh"; echo "*/$interval_min * * * * $MONITOR_SCRIPT > /dev/null 2>&1") | crontab -

echo ""
echo "✅ 安装成功！你可以直接执行以下命令测试："
echo "sudo $MONITOR_SCRIPT"
