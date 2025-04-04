#!/bin/bash
# Cloudflare智能优选脚本 - 2025.08专业版

# 配置区
MAX_IPS=300                # 最大候选IP数量
THREADS=50                 # 并发线程数（支持到100）
BANDWIDTH=20               # 带宽阈值(Mbps) 
TEST_FILE="https://cf.xiu2.xyz/urlspeed.txt"  # 智能测速文件
DATA_SOURCES=(             # 多源IP库
  "https://cf.vbar.fun/ip.txt"
  "https://zip.baipiao.eu.org/cloudflare/ips-v4"
)
COLOMAP_URL="https://cf.xiu2.xyz/colo.txt"     # 数据中心映射表

# 环境初始化
init_env() {
  ! command -v jq &>/dev/null && pkg install -y jq
  ! command -v parallel &>/dev/null && pkg install -y parallel
  [ ! -f colo.txt ] && curl -sL $COLOMAP_URL -o colo.txt
}

# 动态IP池更新
update_ip_pool() {
  echo "? 同步全球CF节点库..."
  rm -f ip_all.txt ip_filtered.txt
  parallel -j 10 "curl -sL {} | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?'" ::: ${DATA_SOURCES[@]} >> ip_all.txt
  
  # 智能去重+随机采样
  sort -u ip_all.txt | awk '
    BEGIN { srand() }
    { printf "%06d %s\n", int(rand()*1000000), $0 }
  ' | sort -n | cut -d' ' -f2 | head -n $MAX_IPS > ip_filtered.txt
}

# 网络类型识别
detect_isp() {
  local org_info=$(curl -sL --max-time 2 http://ipinfo.io/org 2>/dev/null)
  case "$org_info" in
    *"Mobile"*)  echo "移动" ;;
    *"Telecom"*) echo "电信" ;;
    *"Unicom"*)  echo "联通" ;;
    *)            echo "其他" ;;
  esac
}

# 分阶段测速算法
smart_speedtest() {
  local speed_threshold=$((BANDWIDTH * 128 * 1024))  # Mbps转Bytes/s
  
  # 阶段1：快速RTT筛查
  echo "? 一阶段RTT快速筛查..."
  cat ip_filtered.txt | parallel -j $THREADS "
    ip={}
    rtt=\$(ping -c 2 -W 1 \$ip 2>&1 | awk -F'/' '/rtt/ {print int(\$5)}')
    [ -z \"\$rtt\" ] && rtt=999
    loss=\$(ping -c 2 -W 1 \$ip | awk -F'%' '/loss/ {print \$1}' | tr -d ' ')
    echo \"\$ip,\$rtt,\$loss\"
  " > rtt.csv
  
  # 筛选低延迟IP（RTT<150ms & 丢包<20%）
  awk -F',' '$2 < 150 && $3 < 20' rtt.csv | sort -t, -k2n > qualified.csv
  
  # 阶段2：精确带宽测试
  echo "? 二阶段带宽精确测试..."
  cat qualified.csv | parallel --bar -j $THREADS "
    ip=\$(echo {} | cut -d',' -f1)
    colo=\$(curl -m 3 -s --resolve speedtest.net:443:\$ip https://speedtest.net/cdn-cgi/trace | 
      awk -F'=' '/colo=/ {print \$2}' | tr -d '\n')
    speed=\$(curl -m 10 --resolve speedtest.net:443:\$ip "https://speedtest.net/download?size=300000000" -o /dev/null -w '%{speed_download}' 2>/dev/null)
    speed=\${speed%.*}
    [ -z \"\$speed\" ] && speed=0
    echo \"\$ip,\$speed,\$colo\"
  " > speed.csv
  
  # 关联数据并生成结果
  join -t, qualified.csv speed.csv | awk -F',' '
    BEGIN { OFS=","; print "IP,RTT(ms),丢包%,带宽(Mbps),数据中心" }
    { 
      speed_mbps = int($4/125000)
      if (speed_mbps >= '$BANDWIDTH') 
        print $1,$2,$3"%",speed_mbps,$5
    }
  ' | sort -t',' -k4nr > result.csv
  
  # 显示优选结果
  echo "════════════════════════════════════"
  column -t -s',' result.csv | head -n 11
}

# 代理配置
apply_proxy() {
  local best_ip=$(awk -F',' 'NR==2 {print $1}' result.csv)
  local colo=$(grep $(awk -F',' 'NR==2 {print $5}' result.csv) colo.txt | cut -d' ' -f2)
  
  # 自动配置代理
  sed -i "s/server_address=.*/server_address=$best_ip/" $HOME/.surfboard.conf
  termux-notification -t "优选成功" -c "${colo}节点 | ${BANDWIDTH}Mbps带宽"
}

# 主流程
init_env
update_ip_pool
smart_speedtest
apply_proxy
