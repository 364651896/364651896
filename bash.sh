#!/data/data/com.termux/files/usr/bin/bash
# 安卓专用Cloudflare IPv4极速优选脚本 (2025.04.04)

# 环境变量
export LD_LIBRARY_PATH=$PREFIX/lib:$LD_LIBRARY_PATH
THREADS=10                  # 并发线程数（建议8-12）
TEST_COUNT=3                # 单IP测试次数
TIMEOUT=2                   # 超时时间（秒）
API_URL="https://api.vvhan.com/tool/cf_ip"  # 预筛选IP源[1,6](@ref)

# 获取预筛选IP列表（减少本地生成开销）
fetch_ips() {
    curl -sL $API_URL | jq -r '.data.v4.CT[].ip' > ips.txt
    shuf ips.txt | head -n 200  # 随机取200个IP测试
}

# 综合测速（延迟+带宽）
measure_ip() {
    local ip=$1
    local total_latency=0
    local max_speed=0
    
    for ((i=1; i<=$TEST_COUNT; i++)); do
        # TLS延迟检测
        result=$(curl --resolve speedtest.cloudflare.com:443:$ip \
            -o /dev/null -s -w "%{time_connect}_%{speed_download}" \
            --connect-timeout $TIMEOUT https://speedtest.cloudflare.com/__down?bytes=50000000)
        
        [ $? -ne 0 ] && return  # 跳过无效IP
        
        # 数据解析
        latency=$(echo $result | cut -d'_' -f1 | bc -l <<< "scale=3; $(cat) * 1000")
        speed=$(echo $result | cut -d'_' -f2 | awk '{printf "%.0f", $1/1024}')
        
        total_latency=$(echo "$total_latency + $latency" | bc)
        [ $speed -gt $max_speed ] && max_speed=$speed
    done

    # 计算平均延迟
    avg_latency=$(echo "scale=0; $total_latency / $TEST_COUNT" | bc)
    echo "{\"ip\":\"$ip\",\"latency\":$avg_latency,\"speed\":$max_speed}"
}

# 主流程
main() {
    echo "[+] 生成候选IP列表..."
    ips=$(fetch_ips)
    
    echo "[+] 启动多线程检测（$THREADS线程）..."
    for ip in $ips; do
        ((i=i%THREADS)); ((i++==0)) && wait
        measure_ip $ip >> results.tmp &
    done
    wait

    echo "[+] 分析检测结果..."
    jq -c 'select(.speed > 0)' results.tmp | \
    jq -s 'sort_by(.latency, -.speed)' | \
    jq -r '.[] | "\(.ip) 延迟:\(.latency|round)ms 速度:\(.speed)MB/s"'
    
    rm -f results.tmp ips.txt
}

main
