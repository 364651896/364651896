#!/bin/bash
# Cloudflare优选一键脚本 v4.1 (2025-04-04更新)

CONFIG_URL="https://cdn.example.com/cf_optimizer.conf"
DATA_URL="https://cdn.example.com/cloudflare_data.tar.gz"

# 初始化配置
init_setup() {
    ! command -v jq &>/dev/null && apt-get install -y jq
    ! command -v bc &>/dev/null && apt-get install -y bc
    [ ! -d data ] && mkdir data
    
    # 自动更新数据包
    wget -N -q $DATA_URL -P data/ && tar -xzf data/cloudflare_data.tar.gz -C data/
}

# IPV4/IPV6优选核心
bettercloudflareip() {
    case $1 in
        1|2)
            ./CloudflareST -f data/ips-v4.txt -tl 200 -dn 20 -tll 40 $([ $1 -eq 1 ] && echo "-https")
            ;;
        3|4)
            ./CloudflareST -f data/ips-v6.txt -tl 200 -dn 20 -tll 40 $([ $3 -eq 1 ] && echo "-https")
            ;;
    esac
    best_ip=$(awk -F, 'NR>1 && $6>0 {print $1}' result.csv | head -1)
    sed -i "/$DOMAIN/d" /etc/hosts
    echo "$best_ip $DOMAIN" >> /etc/hosts
}

# 单IP测速模块
speed_test() {
    curl --resolve $DOMAIN:$2:$1 https://$DOMAIN/cdn-cgi/trace -o /dev/null \
        -w "延迟: %{time_connect}s\n速度: %{speed_download} B/s\n" -s --connect-timeout 3
}

# 交互式菜单
show_menu() {
    clear
    echo "=== Cloudflare优选工具 ==="
    select opt in "IPV4优选(TLS)" "IPV4优选" "IPV6优选(TLS)" "IPV6优选" "单IP测速(TLS)" "单IP测速" "清空缓存" "更新数据" "退出"; do
        case $REPLY in
            1) bettercloudflareip 1 ;;
            2) bettercloudflareip 2 ;;
            3) bettercloudflareip 3 ;;
            4) bettercloudflareip 4 ;;
            5) read -p "输入测试IP: " ip; speed_test $ip 443 ;;
            6) read -p "输入测试IP: " ip; speed_test $ip 80 ;;
            7) rm -rf data/*.txt result.csv ;;
            8) wget -N -q $DATA_URL -P data/ ;;
            9) exit 0 ;;
            *) echo -e "\033[31m错误选项，请重新选择\033[0m" ;;
        esac
        break
    done
}

# 一键执行入口
if [ "$1" == "--install" ]; then
    wget -N -q https://cdn.example.com/cf_optimizer.sh -O /usr/local/bin/cfopt
    chmod +x /usr/local/bin/cfopt
    cfopt
else
    init_setup
    while true; do show_menu; done
fi
