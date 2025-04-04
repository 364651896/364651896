#!/bin/bash
# Cloudflare优选脚本修复版 v5.7.1 (2024-06-20)
# 主要修复内容：
# 1. IPv6处理逻辑错误  2. cURL超时机制  3. 结果文件路径问题  4. 依赖检测增强

# 初始化配置（新增TERMUX路径检测）
COLOR_RED="\033[31m"
COLOR_GREEN="\033[32m"
COLOR_RESET="\033[0m"
DOMAIN="speed.cloudflare.com"
THREADS=$(( $(nproc) > 10 ? 10 : $(nproc) ))  # 自动适配CPU核心数
TEST_COUNT=3
MIN_SUCCESS=2
TIMEOUT=8  # 延长超时时间
DATA_SOURCES=(
    "https://www.cloudflare.com/ips-v4"
    "https://cf.iroot.eu.org/cloudflare/ips-v4"
)
DOWNLOAD_URL="https://$DOMAIN/__down?bytes=50000000"  # 减小测试文件尺寸

# 修复点1：增强的依赖检查
check_dependencies() {
    local missing=()
    declare -A required=(
        ["curl"]="网络请求"
        ["bc"]="数学计算"
        ["jq"]="JSON处理"
        ["sipcalc"]="IP计算"
        ["parallel"]="并行处理"
    )
    
    for cmd in "${!required[@]}"; do
        if ! command -v $cmd &>/dev/null; then
            missing+=("$cmd(${required[$cmd]})")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${COLOR_RED}缺少关键依赖: ${missing[*]}"
        echo "执行安装命令:"
        echo "pkg update && pkg install ${!required[*]}"
        exit 1
    fi
    
    # Termux特有路径检查
    if [ ! -d "$HOME/storage/downloads" ]; then
        echo -e "${COLOR_RED}未检测到Termux存储权限！${COLOR_RESET}"
        termux-setup-storage
    fi
}

# 修复点2：CIDR转换兼容IPv4/IPv6
cidr_to_ips() {
    local cidr=$1
    if [[ $cidr == *":"* ]]; then
        # IPv6简化处理（跳过扩展计算）
        echo "$cidr"
    else
        # IPv4精确计算
        sipcalc "$cidr" 2>/dev/null | grep -E 'Usable range' | awk '{print $4,$6}' | while read start end; do
            echo "$start-$end"
        done
    fi
}

# 修复点3：IP库更新容错机制
update_ip_pool() {
    echo -e "${COLOR_GREEN}[1/4] 更新全球IP数据库...${COLOR_RESET}"
    rm -f combined.txt temp.txt 2>/dev/null
    
    for url in "${DATA_SOURCES[@]}"; do
        echo "正在同步: $(basename "$url")"
        if ! curl -sL --retry 3 --max-time 10 "$url" > tmp_download; then
            echo -e "${COLOR_RED}   → 下载失败，跳过该源${COLOR_RESET}"
            continue
        fi
        
        while IFS= read -r cidr; do
            [[ -z "$cidr" ]] && continue
            if [[ $cidr == *"/"* ]]; then
                cidr_to_ips "$cidr" >> combined.txt
            else
                echo "$cidr" >> combined.txt
            fi
        done < tmp_download
        rm tmp_download
    done
    
    # 有效性过滤
    grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}(-[0-9]{1,3}\.){3}[0-9]{1,3}$' combined.txt | sort -u | shuf > testlist.txt
}

# 修复点4：增强的测速函数
speed_test() {
    local ip=$1
    local success=0 total_latency=0 max_speed=0
    
    for _ in $(seq 1 $TEST_COUNT); do
        local start=$(date +%s%N)
        local speed=$(curl --resolve "$DOMAIN:443:$ip" -so /dev/null \
            -w "%{speed_download}" "$DOWNLOAD_URL" \
            --tlsv1.3 --connect-timeout $TIMEOUT -m $TIMEOUT 2>&1 | awk '/[0-9]/{printf "%.0f", $1}')
        local end=$(date +%s%N)
        
        if [[ "$speed" =~ ^[0-9]+$ ]] && [ "$speed" -gt 0 ]; then
            success=$((success+1))
            latency=$(( (end - start)/1000000 ))
            total_latency=$((total_latency + latency))
            [ $speed -gt $max_speed ] && max_speed=$speed
        fi
    done
    
    local avg_latency=$(( total_latency / (success > 0 ? success : 1) ))
    local loss_rate=$(echo "scale=2; 1 - $success/$TEST_COUNT" | bc -l)
    local score=$(calculate_score $avg_latency $max_speed $loss_rate)
    
    if [ $success -ge $MIN_SUCCESS ]; then
        printf "%-15s %.2f %d %d %.2f\n" "$ip" $score $avg_latency $((max_speed/1048576)) $loss_rate
        return 0
    fi
    return 1
}

# 修复点5：结果存储路径适配Termux
save_results() {
    local output_dir="$HOME/storage/downloads/cf_results"
    mkdir -p "$output_dir"
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    cp final.txt "$output_dir/cf_${timestamp}.txt"
    
    echo -e "\n${COLOR_GREEN}结果文件路径:${COLOR_RESET}"
    echo "termux: $output_dir/cf_${timestamp}.txt"
    echo "系统文件管理器: /storage/emulated/0/Download/cf_results/cf_${timestamp}.txt"
}

# 主流程优化
main() {
    check_dependencies
    
    echo -e "${COLOR_GREEN}[0/4] 初始化Termux环境...${COLOR_RESET}"
    rm -rf results 2>/dev/null
    mkdir -p results
    
    update_ip_pool
    
    echo -e "${COLOR_GREEN}[2/4] 有效IP数量: $(wc -l < testlist.txt)${COLOR_RESET}"
    [ ! -s testlist.txt ] && {
        echo -e "${COLOR_RED}错误：未获取到有效IP列表！${COLOR_RESET}"
        exit 1
    }
    
    echo -e "${COLOR_GREEN}[3/4] 启动测速（线程数: $THREADS）...${COLOR_RESET}"
    export -f speed_test calculate_score
    cat testlist.txt | parallel -j $THREADS --bar --joblog results/job.log '
        if speed_test {}; then
            echo "$result" >> results/${PARALLEL_SEQ}.log
        fi
    '
    
    echo -e "${COLOR_GREEN}[4/4] 生成最终结果...${COLOR_RESET}"
    cat results/*.log 2>/dev/null | sort -nrk2 | awk '!seen[$1]++' > final.txt
    
    [ -s final.txt ] && {
        show_result
        save_results
    } || {
        echo -e "${COLOR_RED}所有测速失败，建议检查："
        echo "1. 网络连接状态"
        echo "2. 尝试更换测试域名: export DOMAIN=cdn.cloudflare.com"
        exit 1
    }
}

main "$@"
