#!/data/data/com.termux/files/usr/bin/bash
# Android Cloudflare IP优选引擎 v2.6 (2025.04.04)

# 配置参数
THREADS=12                   # 动态线程池容量
TIMEOUT=3                    # 单次检测超时(秒)
API_URL="https://cf.vi/ipv4" # 候选IP源API
SPEED_TEST_SIZE=5242880      # 测速数据量(5MB)

# 颜色定义
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; NC='\033[0m'

# 多维检测函数（输出到标准输出）
multi_detect() {
    local ip=$1
    local total_score=0
    
    # 维度1: TLS握手延迟
    local tls_delay=$(curl -x socks5://$ip:443 --resolve speed.cloudflare.com:443:$ip \
        -o /dev/null -s -w "%{time_appconnect}" \
        --connect-timeout $TIMEOUT https://speed.cloudflare.com/__down?bytes=1024)
    
    # 维度2: 下载速度
    local speed_result=$(curl -x socks5://$ip:443 --resolve speed.cloudflare.com:443:$ip \
        -o /dev/null -s -w "%{speed_download}_%{time_total}" \
        --connect-timeout $TIMEOUT https://speed.cloudflare.com/__down?bytes=$SPEED_TEST_SIZE)
    
    # 维度3: TCP端口可用性
    nc -zv -w $TIMEOUT $ip 443 &>/dev/null && tcp_score=1 || tcp_score=0
    
    # 计算综合得分
    local speed=$(awk -F_ '{printf "%.0f", $1/1024}' <<< $speed_result)
    local total_time=$(awk -F_ '{print $2}' <<< $speed_result)
    total_score=$(bc <<< "scale=2; ($tcp_score*0.3 + (1/$tls_delay)*0.4 + $speed/100*0.3)*100")
    
    # 输出标准化JSON并添加换行符[2,7](@ref)
    printf "{\"ip\":\"%s\",\"score\":%s,\"speed\":%s,\"delay\":%s}\n" "$ip" "$total_score" "$speed" "${tls_delay}000"
}

# 进度可视化（输出到标准错误）
progress_bar() {
    local current=$1 total=$2
    local width=30
    local percent=$((current*100/total))
    local fill=$((width*percent/100))
    printf "\r[${GREEN}%-${width}s${NC}] %d%%" "$(printf '#%.0s' $(seq 1 $fill))" "$percent" >&2
}

# 主流程
main() {
    echo -e "${YELLOW}[+] 获取候选IP列表...${NC}"
    ips=($(curl -sL $API_URL | jq -r '.data.v4.CT[].ip'))
    total=${#ips[@]}
    
    echo -e "${YELLOW}[+] 启动${THREADS}线程检测...${NC}"
    
    # 多线程检测并实时显示进度[3,6](@ref)
    (
        for ((i=0; i<total; i++)); do
            ((i%THREADS==0)) && wait
            multi_detect "${ips[$i]}" &
            progress_bar $i $total
        done
        wait
    ) | jq -s 'sort_by(-.score) | .[0:10]' | while read -r result; do
        echo "$result" 
    done | jq -r '.[] | "\(.ip)\t延迟:\(.delay|tonumber)ms\t速度:\(.speed)MB/s\t综合分:\(.score|floor)"'
    
    echo -e "\n${GREEN}=== 优选TOP10 IP ==="
    echo -e "====================${NC}"
}

main
