#!/bin/bash
# Android一键优选脚本 - 2025.04更新

# 配置区
MAX_IPS=200                # 最大测试IP数量
THREADS=30                 # 并发线程数（建议≤50）
TEST_FILE="https://speed.cloudflare.com/__down?bytes=300000000"  # 300MB测速文件
IP_SOURCES=(               # 动态IP源（每小时更新）
  "https://stock.hostmonit.com/CloudFlareYes"
  "https://raw.githubusercontent.com/badafans/better-cloudflare-ip/master/ip.txt"
)

# 环境检测与依赖安装
if ! command -v jq &>/dev/null || ! command -v bc &>/dev/null; then
  pkg update -y && pkg install -y curl jq bc
fi

# 动态IP池更新
update_ip_pool() {
  echo "? 更新Cloudflare IP池..."
  rm -f ip.txt
  for url in "${IP_SOURCES[@]}"; do
    curl -sL "$url" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?' >> ip.txt
  done
  sort -u ip.txt | shuf | head -n $MAX_IPS > ip_filtered.txt
}

# 网络类型识别（移动/电信/联通）
detect_isp() {
  case $(curl -sL --max-time 3 http://ipinfo.io/org) in
    *"Mobile"*)  echo "mobile" ;;
    *"Telecom"*) echo "telecom" ;;
    *"Unicom"*)  echo "unicom" ;;
    *)           echo "other" ;;
  esac
}

# 运营商定制化过滤
ISP_FILTER=$(detect_isp)
case $ISP_FILTER in
  "mobile")   FILTER="172.64.32.|104.28.14." ;;    # 香港/新加坡
  "telecom")  FILTER="104.16.160.|172.64.0." ;;    # 洛杉矶/旧金山
  "unicom")   FILTER="108.162.236.|104.23.240." ;; # 亚特兰大/混合段
  *)          FILTER="" ;;
esac

# 动态权重测速算法
speed_test() {
  echo "? 开始三网智能测速..."
  grep -E "$FILTER" ip_filtered.txt | xargs -P $THREADS -I {} sh -c "
    ip={}
    latency=\$(ping -c 4 \$ip | awk -F'/' '/^rtt/ {print \$5}' || echo 999)
    loss=\$(ping -c 4 \$ip | awk -F'%' '/packet loss/ {print \$1}' | tr -d ' ' || echo 100)
    speed=\$(curl -sL --max-time 10 '$TEST_FILE' --resolve speed.cloudflare.com:443:\$ip | \
      awk '{if(\$0~/\|/) print \$3/125000; else print \$1/125000}' | tail -1)
    score=\$(echo \"scale=2; (0.5*\$speed) + (0.3*(1000/\$latency)) + (0.2*(100-\$loss))\" | bc)
    echo \"\$ip,\$latency,\$loss,\$speed,\$score\"
  " > result.csv
  
  # 结果排序与输出
  sort -t',' -k5 -nr result.csv | head -n 10
}

# 代理配置自动化
apply_proxy() {
  BEST_IP=$(awk -F',' 'NR==1 {print $1}' result.csv)
  echo "? 应用优选IP: $BEST_IP"
  
  # 自动配置Surfboard/Sagernet（需root）
  if [ -f /data/data/com.getsurfboard/files/conf.json ]; then
    sed -i "s/\"server\": \".*\"/\"server\": \"$BEST_IP\"/g" /data/data/com.getsurfboard/files/conf.json
    am broadcast -a com.getsurfboard.RELOAD >/dev/null
  fi
  
  # Termux通知提醒
  termux-notification -t "优选完成" -c "最佳IP: $BEST_IP 速度: $(awk -F',' 'NR==1 {print $4}' result.csv)MB/s"
}

# 主流程
update_ip_pool
speed_test
apply_proxy
