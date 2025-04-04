#!/data/data/com.termux/files/usr/bin/bash
# Android Cloudflare IP优选引擎 v2.7 (2025.04.04)

# 配置参数
THREADS=8                    # 动态线程池容量
TIMEOUT=3                    # 单次检测超时(秒)
API_URL="https://api.vvhan.com/tool/cf_ip" # 替换为网页1推荐的稳定API
SPEED_TEST_SIZE=10485760     # 测速数据量(10MB)

# 颜色定义
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; NC='\033[0m'

# 增强型多维检测
multi_detect() {
    local ip=$1
    for _ in {1..3}; do  # 网页4建议的三次重试机制
        # 维度1: TLS握手延迟
        local tls_delay=$(curl -x socks5://$ip:443 --resolve speed.cloudflare.com:443:$ip \
            -o /dev/null -s -w "%{time_appconnect}" \
            --connect-timeout $TIMEOUT https://speed.cloudflare.com/__down?bytes=1024)
        
        # 维度2: 下载速度（网页6建议增大测试数据量）
        local speed_result=$(curl -x socks5://$ip:443 --resolve speed.cloudflare.com:443:$ip \
            -o /dev/null -s -w "%{speed_download}_%{time_total}" \
            --connect-timeout $TIMEOUT https://speed.cloudflare.com/__down?bytes=$SPEED_TEST_SIZE)
        
        # 成功获取数据则跳出循环
        [ -n "$tls_delay" ] && [ -n "$speed_result" ] && break
    done

    # 异常数据处理
    local speed=$(awk -F_ '{printf "%.0f", $1/1024}' <<< $speed_result 2>/dev/null)
    local delay=$(bc <<< "scale=0; ${tls_delay:-0}*1000/1" 2>/dev/null)
    [ -z "$speed" ] && speed=0

    # 输出标准化JSON（网页5建议字段类型强制转换）
    printf "{\"ip\":\"%s\",\"delay\":%d,\"speed\":%d}\n" "$ip" "${delay:-9999}" "$speed"
}

# 进度可视化（输出到错误流）
progress_bar() {
    ... # 保持不变
}

# 主流程增强
main() {
    # 候选IP获取（增加失败重试）
    echo -e "${YELLOW}[+] 获取候选IP列表...${NC}"
    ips=($(curl -sL --retry 3 $API_URL | jq -r '.data.v4.CT[].ip' 2>/dev/null))
    [ ${#ips[@]} -eq 0 ] && { echo -e "${RED}[!] IP获取失败，请检查API接口${NC}"; return 1; }

    # 多线程处理优化（网页3建议限制缓冲）
    echo -e "${YELLOW}[+] 启动${THREADS}线程检测...${NC}"
    {
        for ip in "${ips[@]}"; do
            ((i=i%THREADS)); ((i++==0)) && wait
            multi_detect "$ip" &
        done
        wait
    } | tee >(jq -c '. | select(.speed > 0 and .delay < 500)' > filtered.log) | \
      jq -s 'sort_by(-.speed, .delay) | .[0:10]' | \
      jq -r '.[] | "\(.ip)\t延迟:\(.delay)ms\t速度:\(.speed)MB/s"'

    echo -e "\n${GREEN}=== 优选TOP10 IP ==="
    cat filtered.log | jq -r '"\(.ip)\t延迟:\(.delay)ms\t速度:\(.speed)MB/s"'
    echo -e "====================${NC}"
    rm -f filtered.log
}

main
