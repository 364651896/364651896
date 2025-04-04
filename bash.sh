#!/bin/bash
# Cloudflare IP优选脚本增强版 v3.2 (2025-04-04)
# 功能：多协议支持 | 智能评分 | 动态超时 | 结果缓存

# 初始化配置
COLOR_RED="\033[31m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_RESET="\033[0m"
WORKDIR="$HOME/cf_ip_test"
CACHE_FILE="$WORKDIR/best_ip.cache"

# [新增] 智能评分算法 [6,8](@ref)
function calculate_score() {
    local latency=$1 speed=$2 stability=$3
    echo "scale=2; ($speed/1048576*60) + (1000/($latency+1)*30) + ((1-$stability)*10)" | bc -l
}

# [重构] 增强版测速函数
function enhanced_speedtest() {
    local ip=$1 proto=$2
    local results=() success=0 total_latency=0 max_speed=0

    # 动态超时调整 [6](@ref)
    local base_rtt=$(ping -c 2 1.1.1.1 | awk -F'/' 'END{print $5}')
    local TIMEOUT=$(( ${base_rtt%.*} / 100 + 2 ))
    [[ $TIMEOUT -lt 3 ]] && TIMEOUT=3
    [[ $TIMEOUT -gt 10 ]] && TIMEOUT=10

    for i in {1..3}; do
        local start=$(date +%s%N)
        if [ $proto -eq 1 ]; then
            local speed=$(curl --resolve $domain:443:$ip https://$domain/$file -o /dev/null \
                --connect-timeout $TIMEOUT -w "%{speed_download}\n%{http_code}" 2>/dev/null)
        else
            local speed=$(curl -x $ip:80 http://$domain/$file -o /dev/null \
                --connect-timeout $TIMEOUT -w "%{speed_download}\n%{http_code}" 2>/dev/null)
        fi
        
        if [[ $(echo "$speed" | tail -n1) == "200" ]]; then
            success=$((success+1))
            local speed_val=$(echo "$speed" | head -n1 | awk '{printf "%.0f", $1}')
            local latency=$(( ($(date +%s%N) - start)/1000000 ))
            total_latency=$((total_latency + latency))
            [ $speed_val -gt $max_speed ] && max_speed=$speed_val
        fi
        sleep 0.3 # 防止请求风暴 [6](@ref)
    done

    if [ $success -gt 0 ]; then
        local avg_latency=$(( total_latency / success ))
        local loss_rate=$(echo "scale=2; 1 - $success/3" | bc)
        local score=$(calculate_score $avg_latency $max_speed $loss_rate)
        printf "%-15s %.2f %d %d %.2f\n" "$ip" $score $avg_latency $((max_speed/1024)) $loss_rate
        return 0
    fi
    return 1
}

# [优化] 主测速流程
function cloudflaretest(){
    # 缓存检查 [6](@ref)
    if [ -f "$CACHE_FILE" ]; then
        local cached_ip=$(awk '{print $1}' $CACHE_FILE)
        local test_result=$(curl --resolve $domain:443:$cached_ip -m 2 -Is https://$domain | head -1)
        [[ "$test_result" == *"200"* ]] && {
            echo "使用缓存IP: $cached_ip"
            return 0
        }
    }

    # IP预筛选（Cloudflare核心ASN）[6](@ref)
    grep -E '104\.16|104\.24|172\.64' ips-v4.txt > $WORKDIR/premium-ips.txt
    shuf $WORKDIR/premium-ips.txt | head -500 > $WORKDIR/testlist.txt

    # 多线程测速
    export -f enhanced_speedtest calculate_score
    cat $WORKDIR/testlist.txt | xargs -P $THREADS -I {} bash -c 'enhanced_speedtest {} 1' > $WORKDIR/results.txt

    # 结果处理
    sort -nrk2 $WORKDIR/results.txt | head -10 > $WORKDIR/top10.txt
    local best_ip=$(awk 'NR==1{print $1}' $WORKDIR/top10.txt)
    local best_score=$(awk 'NR==1{print $2}' $WORKDIR/top10.txt)
    
    # 缓存最佳结果 [6](@ref)
    echo "$best_ip $best_score $(date +%s)" > $CACHE_FILE
}

# [保留] 数据检查与菜单系统
function datacheck(){
    # ... (原有数据下载逻辑不变)
}

# [优化] 主函数流程
main() {
    check_dependencies
    dynamic_timeout
    generate_ip_pool
    cloudflaretest
    show_result
}

# [新增] 结果显示函数
function show_result() {
    echo -e "\n${COLOR_GREEN}========== 优选TOP 10 IP（综合评分） ==========${COLOR_RESET}"
    awk '{printf "%-15s 评分:%-8.2f 延迟:%-4dms 带宽:%-3dMB/s 丢包率:%-5.2f%%\n", $1,$2,$3,$4,$5*100}' final.txt | head -10
    echo -e "${COLOR_GREEN}===============================================${COLOR_RESET}"
}

# 执行入口
main "$@"
