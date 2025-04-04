#!/bin/bash
# Cloudflare IP优选脚本 v3.2 (2025-04-04更新)

# 初始化配置
COLOR_RED="\033[31m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_BLUE="\033[34m"
COLOR_RESET="\033[0m"
CF_API_URL="https://api.vvhan.com/tool/cf_ip"  # 优选IP数据源[1](@ref)
SPEED_TEST_URL="https://speed.cloudflare.com/__down?bytes=500000000"  # 测速文件[3](@ref)
MAX_PROCESS=50  # 最大并行进程数[7](@ref)

# 依赖检查函数
check_dependencies() {
    declare -a deps=("curl" "jq" "parallel")
    for cmd in "${deps[@]}"; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${COLOR_RED}错误：缺少必要依赖 $cmd，请先安装${COLOR_RESET}"
            exit 1
        fi
    done
}

# 智能IP获取函数
fetch_optimized_ips() {
    echo -e "${COLOR_BLUE}[1/5] 获取最新优选IP列表...${COLOR_RESET}"
    response=$(curl -sSL --retry 3 $CF_API_URL)
    
    if ! jq -e . <<< "$response" &> /dev/null; then
        echo -e "${COLOR_RED}错误：API响应异常，使用本地IP库${COLOR_RESET}"
        cat ips-v4.txt ips-v6.txt > combined.txt
        return
    fi

    # 解析JSON数据[1](@ref)
    declare -A ip_pool
    for type in v4 v6; do
        for isp in CM CU CT; do
            ips=$(jq -r ".data.$type.$isp[].ip" <<< "$response")
            while read ip; do
                ip_pool["$ip"]=1
            done <<< "$ips"
        done
    done
    
    printf "%s\n" "${!ip_pool[@]}" > combined.txt
}

# 动态测速函数
speed_test() {
    echo -e "${COLOR_BLUE}[2/5] 启动多线程测速(进程数：$MAX_PROCESS)...${COLOR_RESET}"
    
    # 并行测速模块[7](@ref)
    cat combined.txt | parallel -j $MAX_PROCESS '
        start=$(date +%s%N)
        if curl -sL --resolve speed.cloudflare.com:443:{} $SPEED_TEST_URL -o /dev/null --connect-timeout 3 --max-time 10; then
            latency=$(( ($(date +%s%N) - start) / 1000000 ))
            speed=$(curl -sL -w "%{speed_download}" $SPEED_TEST_URL -o /dev/null --connect-timeout 3 --max-time 10 | awk "{print \$1 / 1024}")
            printf "%.2f %d %s\n" $speed $latency {}
        fi
    ' | sort -nrk1 > result.txt
    
    # 异常处理[4](@ref)
    if [ ! -s result.txt ]; then
        echo -e "${COLOR_RED}错误：所有IP测速失败，检查网络连接${COLOR_RESET}"
        exit 1
    fi
}

# 结果分析函数
analyze_results() {
    echo -e "${COLOR_BLUE}[3/5] 生成优化报告...${COLOR_RESET}"
    
    # 综合评分算法[3,8](@ref)
    awk '{ 
        score = ($1/1024)*0.6 + (1000/($2+1))*0.4
        printf "[%s] 带宽：%.2f MB/s | 延迟：%d ms | 综合评分：%.2f\n", $3, $1, $2, score 
    }' result.txt | head -n 20
    
    best_ip=$(awk 'NR==1 {print $3}' result.txt)
    echo -e "\n${COLOR_GREEN}优选IP：$best_ip${COLOR_RESET}"
}

# DNS更新函数（需配置API密钥）
update_dns() {
    read -p "是否更新DNS记录？[y/N] " choice
    case "$choice" in
        y|Y)
            echo -e "${COLOR_BLUE}[4/5] 正在更新DNS解析...${COLOR_RESET}"
            # 此处添加DNSPod/阿里云API调用代码[1,6](@ref)
            ;;
        *)
            echo "跳过DNS更新"
            ;;
    esac
}

# 主流程
main() {
    check_dependencies
    fetch_optimized_ips
    speed_test
    analyze_results
    update_dns
    echo -e "${COLOR_GREEN}[5/5] 优选完成！${COLOR_RESET}"
}

# 执行入口
main "$@"
