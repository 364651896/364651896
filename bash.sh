#!/bin/bash
# Cloudflare优选脚本完整修复版 v5.7 (2025-04-04)
# 适配Termux环境 | 完整函数导出 | 多源IP库支持

# 初始化配置
COLOR_RED="\033[31m"
COLOR_GREEN="\033[32m"
COLOR_RESET="\033[0m"
DOMAIN="speed.cloudflare.com"
THREADS=10
TEST_COUNT=3
MIN_SUCCESS=2
TIMEOUT=5
DATA_SOURCES=(
    "https://cf.iroot.eu.org/cloudflare/ips-v4"
    "https://www.cloudflare.com/ips-v4"
    "https://cf.iroot.eu.org/cloudflare/ips-v6"
)

# 依赖检查（网页6的Termux适配方案）
check_dependencies() {
    local missing=()
    for cmd in curl bc jq sipcalc parallel; do
        if ! command -v $cmd &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${COLOR_RED}缺少依赖: ${missing[*]}"
        echo "执行安装命令:"
        echo "pkg update && pkg install ${missing[*]}"
        exit 1
    fi
}

# CIDR转换（修复网页1的IPv6问题）
cidr_to_ips() {
    local cidr=$1
    if [[ $cidr == *":"* ]]; then
        echo "$cidr"  # 跳过IPv6处理
    else
        sipcalc "$cidr" | grep 'Usable range' | awk '{print $4,$6}'
    fi
}

# IP库更新（整合网页3的多源策略）
update_ip_pool() {
    echo -e "${COLOR_GREEN}[1/4] 更新全球IP数据库...${COLOR_RESET}"
    rm -f combined.txt temp.txt
    
    for url in "${DATA_SOURCES[@]}"; do
        echo "正在同步: $(basename $url)"
        curl -sL --retry 3 "$url" | while read -r cidr; do
            if [[ $cidr == *"/"* ]]; then
                cidr_to_ips "$cidr" >> combined.txt
            else
                echo "$cidr" >> combined.txt
            fi
        done
    done
    
    sort -u combined.txt | shuf > temp.txt
    mv temp.txt combined.txt
}

# 评分算法（网页3的优化公式）
calculate_score() {
    local latency=$1 speed=$2 loss_rate=$3
    echo "scale=2; (($speed/1048576)*60) + (1000/($latency+1))*30 + ((1-$loss_rate)*10)" | bc -l
}

# 测速核心（修复网页1的TLS验证）
speed_test() {
    local ip=$1
    local success=0 total_latency=0 max_speed=0
    
    for i in $(seq 1 $TEST_COUNT); do
        local start=$(date +%s%N)
        local speed=$(curl --resolve $DOMAIN:443:$ip -so /dev/null \
            -w "%{speed_download}" "https://$DOMAIN/__down?bytes=100000000" \
            --tlsv1.3 --connect-timeout $TIMEOUT -m $TIMEOUT 2>/dev/null | awk '{printf "%.0f", $1}')
        local end=$(date +%s%N)
        
        if [ "$speed" -gt 0 ]; then
            success=$((success+1))
            latency=$(( (end - start)/1000000 ))
            total_latency=$((total_latency + latency))
            [ $speed -gt $max_speed ] && max_speed=$speed
        fi
    done
    
    local avg_latency=$(( total_latency / (success + 1) ))
    local loss_rate=$(echo "scale=2; ($TEST_COUNT - $success)/$TEST_COUNT" | bc -l)
    local score=$(calculate_score $avg_latency $max_speed $loss_rate)
    
    if [ $success -ge $MIN_SUCCESS ]; then
        printf "%-15s %.2f %d %d %.2f\n" "$ip" $score $avg_latency $((max_speed/1048576)) $loss_rate
    fi
}

# 结果展示（网页4的格式优化）
show_result() {
    echo -e "\n${COLOR_GREEN}========== 优选TOP 10 IP ==========${COLOR_RESET}"
    awk '{printf "%-15s 评分:%.2f 延迟:%dms 带宽:%dMB/s 丢包率:%.2f%%\n", $1,$2,$3,$4,$5*100}' final.txt | head -10
    echo -e "${COLOR_GREEN}===================================${COLOR_RESET}"
}

# 主测速流程（网页5的并发优化）
main_test() {
    echo -e "${COLOR_GREEN}[3/4] 启动多线程测速...${COLOR_RESET}"
    rm -rf results && mkdir -p results
    
    export -f speed_test calculate_score  # 显式导出函数
    
    cat testlist.txt | parallel -j $THREADS --progress --bar '
        ip={}
        result=$(speed_test "$ip")
        [ -n "$result" ] && echo "$result" >> results/${#}.log
    ' 2>/dev/null
    
    if [ -z "$(ls -A results/*.log 2>/dev/null)" ]; then
        echo -e "${COLOR_RED}错误：所有测速失败，建议操作："
        echo "1. 检查termux网络权限"
        echo "2. 更换测试源：sed -i 's/speed.cloudflare.com/cdn.cloudflare.com/' \$0"
        exit 1
    fi
    
    cat results/*.log | sort -nrk2 | awk '!seen[$1]++' > final.txt
}

# 主流程（网页6的Termux适配）
main() {
    check_dependencies
    termux-setup-storage  # 申请存储权限
    
    echo -e "${COLOR_GREEN}[0/4] 初始化Termux环境...${COLOR_RESET}"
    mkdir -p $HOME/storage/downloads/cf_results
    
    update_ip_pool
    echo -e "${COLOR_GREEN}[2/4] 生成测试列表...${COLOR_RESET}"
    shuf combined.txt | head -500 > testlist.txt
    
    main_test
    show_result
    
    # 保存结果到下载目录
    cp final.txt $HOME/storage/downloads/cf_results/$(date +%Y%m%d).txt
    echo -e "结果文件已保存到：/storage/emulated/0/Download/cf_results/"
}

main "$@"
