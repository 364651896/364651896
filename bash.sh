#!/bin/bash
# Optimized Cloudflare IP Selector v2.1

# 配置区（可根据需要调整）
CF_IPS_URL="https://www.cloudflare.com/ips-v4"
BANDWIDTH=10                  # 默认带宽要求(Mbps)
THREADS=20                    # 测试线程数
TEST_DURATION=5              # 单IP测试时长(秒)
PACKET_LOSS_THRESHOLD=15     # 丢包率阈值(百分比)

# 运营商优选CIDR（根据网页3/11优化）
declare -A ISP_CIDR=(
  ["移动"]="104.16.96.0/20 104.18.48.0/20 172.64.32.0/24"
  ["电信"]="104.16.160.0/24 172.64.0.0/24 104.21.11.0/24" 
  ["联通"]="104.23.240.0/20 104.27.128.0/20 172.68.0.0/16"
)

# 多维度评分权重（参考网页6）
LATENCY_WEIGHT=0.3
SPEED_WEIGHT=0.4
STABILITY_WEIGHT=0.2
PACKET_LOSS_WEIGHT=0.1

# 初始化环境
function init_env() {
  mkdir -p tmp
  rm -rf tmp/*
  echo "正在更新IP库..."
  curl -s $CF_IPS_URL -o tmp/cf_ips.txt
  [[ $ISP ]] && filter_isp_cidr
}

# 运营商CIDR过滤（网页3/11方案）
function filter_isp_cidr() {
  grep -E "$(echo ${ISP_CIDR[$ISP]} | tr ' ' '|')" tmp/cf_ips.txt > tmp/filtered_ips.txt
  mv tmp/filtered_ips.txt tmp/cf_ips.txt
}

# 增强版网络测试（网页6/13方案）
function enhanced_test() {
  local ip=$1
  local latency=0 packet_loss=0 speed=0
  
  # 延迟测试（3次采样）
  for i in {1..3}; do
    resp=$(curl -sI --connect-timeout 2 -m 3 -w "%{time_connect}\n%{http_code}" "https://$ip" -o /dev/null)
    latency=$(bc <<< "$latency + $(awk 'NR==1{print $1*1000}' <<< "$resp")")
    [[ $(awk 'NR==2{print $1}' <<< "$resp") != 200 ]] && ((packet_loss++))
  done
  
  # 带宽测试（参考网页6）
  speed=$(curl -o /dev/null -x $ip:443 -w "%{speed_download}" "https://speed.cloudflare.com/__down?bytes=10000000" --connect-timeout 5 -m $TEST_DURATION | \
    awk '{printf "%.2f", $1/125000}') # 转换为Mbps
  
  # 综合评分（网页6算法）
  local score=$(bc <<< "scale=2; \
    ($latency/3)*$LATENCY_WEIGHT + \
    $speed*$SPEED_WEIGHT - \
    $packet_loss*10*$PACKET_LOSS_WEIGHT + \
    (100 - ${packet_loss}00/3)*$STABILITY_WEIGHT")
  
  echo "$score $ip $latency $packet_loss $speed"
}

# 主测试流程
function main_test() {
  echo "正在生成测试队列..."
  shuf tmp/cf_ips.txt | head -n 500 > tmp/test_queue.txt
  
  echo "启动多线程测试..."
  export -f enhanced_test
  parallel -j $THREADS --bar enhanced_test :::: tmp/test_queue.txt > tmp/raw_results.txt

  # 结果排序
  sort -nr tmp/raw_results.txt | awk '!seen[$2]++' | head -n 50 > tmp/final_results.txt
  
  # 打印结果
  printf "%-16s %-8s %-8s %-8s %-8s\n" "IP" "评分" "延迟(ms)" "丢包率(%)" "速度(Mbps)"
  awk '{printf "%-16s %-8.2f %-8.1f %-8.0f %-8.1f\n", $2,$1,$3/3,$4*33.3,$5}' tmp/final_results.txt
}

# 执行主流程
echo "请选择运营商（回车跳过）:"
select isp in 移动 电信 联通; do 
  [[ $isp ]] && ISP=$isp && break
done

init_env
main_test
