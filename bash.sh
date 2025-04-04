#!/data/data/com.termux/files/usr/bin/bash
# 安卓专用Cloudflare IPv4极速优选脚本 v2025.04.04

# 环境初始化
export LD_LIBRARY_PATH=$PREFIX/lib:$LD_LIBRARY_PATH
apt update && apt install -y curl jq openssl 2>/dev/null

# 动态参数配置
THREADS=12                 # 并发线程数(建议8-16)
TEST_COUNT=3               # 单IP测试次数
MIN_SPEED=10240            # 最低速度要求(kB/s)
TIMEOUT=2                  # 超时时间(秒)

# 智能IP库管理
IP_DATA_URL="https://cfip.speedtest.tk/ips-v4"
LOCAL_IP_DB="$PREFIX/etc/cf_ip.db"

update_ip_db() {
    curl -sL $IP_DATA_URL -o $LOCAL_IP_DB 2>/dev/null || 
    echo "104.16.0.0/12" > $LOCAL_IP_DB  # 内置备用IP段
}

# 网络质量检测函数
measure_ip() {
    local ip=$1
    local latency=0
    local speed=0
    
    # TLS握手与传输速度综合检测
    for ((i=0; i<TEST_COUNT; i++)); do
        local result=$(curl -s --resolve speedtest.cloudflare.com:443:$ip \
            https://speedtest.cloudflare.com/__down?bytes=50000000 \
            -w "%{time_connect}_%{speed_download}" -o /dev/null \
            --connect-timeout $TIMEOUT)
        
        [ $? -ne 0 ] && return  # 跳过不可用IP
        
        local connect_time=$(echo $result | cut -d'_' -f1)
        local speed_download=$(echo $result | cut -d'_' -f2 | awk '{printf "%.0f", $1}')
        
        latency=$(echo "$latency + $connect_time" | bc)
        speed=$(echo "$speed + $speed_download" | bc)
    done

    # 计算平均值
    latency=$(echo "scale=3; $latency / $TEST_COUNT" | bc)
    speed=$(echo "scale=0; $speed / $TEST_COUNT" | bc)
    
    # 输出JSON格式结果
    echo "{\"ip\":\"$ip\",\"latency\":$latency,\"speed\":$speed}"
}

# 主测速流程
main() {
    update_ip_db
    echo "[+] 正在生成候选IP列表..."
    
    # 动态IP生成算法
    candidates=$(shuf $LOCAL_IP_DB | awk -F. '{print $1"."$2"."$3"."int(rand()*255)}' | head -n 500)
    
    # 并行检测
    echo "[+] 启动多线程检测..."
    for ip in $candidates; do
        ((i=i%THREADS)); ((i++==0)) && wait
        measure_ip $ip >> results.tmp &
    done
    wait

    # 结果分析
    echo "[+] 分析检测结果..."
    jq -c 'select(.speed > '$MIN_SPEED')' results.tmp | \
    jq -s 'sort_by(.latency, -.speed)' | \
    jq -r '.[] | "\(.ip) 延迟:\(.latency*1000|round)ms 速度:\(.speed/1024|round)MB/s"'
    
    # 清理临时文件
    rm -f results.tmp
}

# 执行入口
main
