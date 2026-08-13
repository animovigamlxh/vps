#!/bin/bash

# 环境变量设置
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- 参数配置 ---
# 注意：以下变量通常由外部配置或脚本自动填充
threshold_mbps=100
MAX_COUNT=3
test_file_size=10
test_url="https://speed.cloudflare.com/__down?bytes=10485760"
STATE_FILE="/tmp/speedtest_fail_count"

# Telegram 配置 (如果此处为空，请确保在外部环境中设置了环境变量)
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"

# --- TG 通知函数 ---
send_tg_msg() {
    local message=$1
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TG_CHAT_ID}" \
            -d "text=$message" \
            -d "parse_mode=Markdown" > /dev/null
    fi
}

# --- 依赖检查 ---
for pkg in curl bc; do
    if ! command -v $pkg &> /dev/null; then
        apt-get update && apt-get install -y $pkg
    fi
done

# 读取当前计数
if [ -f "$STATE_FILE" ]; then
    fail_count=$(cat "$STATE_FILE")
else
    fail_count=0
fi

# 确保 fail_count 是数字
[[ ! "$fail_count" =~ ^-?[0-9]+$ ]] && fail_count=0

# --- 核心测速逻辑 ---
start_time=$(date +%s.%N)
http_code=$(curl -s -o /dev/null -w "%{http_code}" "$test_url")

if [ "$http_code" -ne 200 ]; then
    msg="⚠️ *测速异常*\\n节点：$(hostname)\\n状态：测速文件下载失败 (HTTP $http_code)"
    send_tg_msg "$msg"
    exit 1
fi

end_time=$(date +%s.%N)
duration=$(echo "$end_time - $start_time" | bc)
download_speed_mbps=$(echo "scale=2; ($test_file_size * 8) / $duration" | bc)

# 获取当前 v2node 服务运行状态
v2node_status=$(v2node status 2>&1)

# --- 防抖动与状态切换逻辑 (带边界封顶) ---
is_below=$(echo "$download_speed_mbps < $threshold_mbps" | bc -l)

if [ "$is_below" -eq 1 ]; then
    # 速度低于阈值 (累加正数)
    if [ "$fail_count" -lt 0 ]; then
        fail_count=1
    else
        fail_count=$((fail_count + 1))
    fi
    
    # 封顶：最大不超过 MAX_COUNT
    [ "$fail_count" -gt "$MAX_COUNT" ] && fail_count="$MAX_COUNT"
    
    echo "$fail_count" > "$STATE_FILE"

    if [ "$fail_count" -ge "$MAX_COUNT" ]; then
        action="🔴 *连续 ${fail_count} 次低于阈值，已停止 v2node*"
        [[ ! "$v2node_status" =~ "Stopped" && ! "$v2node_status" =~ "not running" && ! "$v2node_status" =~ "未运行" ]] && v2node stop
    else
        action="⚠️ *速度不达标 (${fail_count}/${MAX_COUNT} 次)*\\nv2node 保持当前状态"
    fi
else
    # 速度高于阈值 (累加负数，用绝对值表示成功次数)
    if [ "$fail_count" -gt 0 ]; then
        fail_count=-1
    else
        fail_count=$((fail_count - 1))
    fi
    
    # 封顶：绝对值最大不超过 MAX_COUNT
    min_limit=$(( -MAX_COUNT ))
    [ "$fail_count" -lt "$min_limit" ] && fail_count="$min_limit"
    
    echo "$fail_count" > "$STATE_FILE"

    abs_pass_count=${fail_count#-}

    if [ "$abs_pass_count" -ge "$MAX_COUNT" ]; then
        action="✅ *连续 ${abs_pass_count} 次达标，v2node 启动/运行中*"
        [[ "$v2node_status" =~ "Stopped" || "$v2node_status" =~ "not running" || "$v2node_status" =~ "未运行" ]] && v2node start
    else
        action="🟡 *速度已恢复达标 (${abs_pass_count}/${MAX_COUNT} 次)*\\nv2node 保持当前状态"
    fi
fi

# --- 发送最终执行结果 ---
final_msg="📊 *节点测速报告*\\n--------------------\\n节点名称：$(hostname)\\n实测带宽：*${download_speed_mbps} Mbps*\\n判定阈值：${threshold_mbps} Mbps\\n当前动作：${action}"
send_tg_msg "$final_msg"
