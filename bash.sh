#!/data/data/com.termux/files/usr/bin/bash
# Android Cloudflare IP优选引擎 v2.5 (2025.04.04)

# 配置参数
THREADS=12                   # 动态线程池容量
TIMEOUT=3                    # 单次检测超时(秒)
TEST_COUNT=3                 # 单IP重复测试次数
API_URL="https://cf.vi/ipv4" # 候选IP源API
SPEED_TEST_SIZE=5242880      # 测速数据量(5MB)

# 颜色定义
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; NC='\033[0m'

# 多维检测函数
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
    
    echo "{\"ip\":\"$ip\",\"score\":$total_score,\"speed\":$speed,\"delay\":${tls_delay}000}"
}

# 进度可视化
progress_bar() {
    local current=$1 total=$2
    local width=30
    local percent=$((current*100/total))
    local fill=$((width*percent/100))
    printf "\r[${GREEN}%-${width}s${NC}] %d%%" "$(printf '#%.0s' $(seq 1 $fill))" "$percent"
}

# 主流程
main() {
    echo -e "${YELLOW}[+] 获取候选IP列表...${NC}"
    ips=($(curl -sL $API_URL | jq -r '.data.v4.CT[].ip'))
    total=${#ips[@]}
    
    echo -e "${YELLOW}[+] 启动${THREADS}线程检测...${NC}"
    rm -f results.tmp
    for ((i=0; i<total; i++)); do
        ((i%THREADS==0)) && wait
        progress_bar $i $total
        multi_detect ${ips[$i]} >> results.tmp &
    done
    wait
    
    echo -e "\n${YELLOW}[+] 生成优选报告...${NC}"
    sort_result=$(jq -s 'sort_by(-.score)' results.tmp | jq -r '.[0:10]')
    
    echo -e "\n${GREEN}=== 优选TOP10 IP ==="
    jq -r '.[] | "\(.ip)\t延迟:\(.delay|tonumber)ms\t速度:\(.speed)MB/s\t综合分:\(.score|floor)"' <<< "$sort_result"
    echo -e "====================${NC}"
    
    rm -f results.tmp
}

main
