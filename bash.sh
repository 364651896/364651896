#!/data/data/com.termux/files/usr/bin/bash
# Termux CloudflareST 一键部署脚本 v1.2 (2025.04.04)

# 配置参数
THREADS=8                     # 检测线程数
TEST_COUNT=10                 # 延迟测试次数[2](@ref)
SPEED_TEST_SIZE=10485760      # 下载测速数据量(10MB)[5](@ref)
DOWNLOAD_URL="https://github.com/XIU2/CloudflareSpeedTest/releases/download/v2.2.4/CloudflareST_android_arm64.tar.gz"

# 颜色定义
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; NC='\033[0m'

# 依赖安装检查
check_dependencies() {
    if ! command -v wget &> /dev/null; then
        echo -e "${YELLOW}[+] 安装wget工具...${NC}"
        pkg update -y && pkg install wget -y || {
            echo -e "${RED}[!] wget安装失败，请检查网络连接${NC}"
            exit 1
        }
    fi
}

# 文件下载与解压
download_binary() {
    echo -e "${YELLOW}[+] 下载CloudflareST安卓版...${NC}"
    wget --no-check-certificate "$DOWNLOAD_URL" -O CloudflareST.tar.gz || {
        echo -e "${RED}[!] 下载失败，请检查："
        echo "1. 网络代理设置"
        echo "2. 文件链接有效性"
        exit 1
    }
    
    echo -e "${YELLOW}[+] 解压文件...${NC}"
    tar -zxvf CloudflareST.tar.gz && chmod +x CloudflareST || {
        echo -e "${RED}[!] 解压失败，可能文件损坏${NC}"
        exit 1
    }
}

# 主测速流程
run_test() {
    echo -e "${YELLOW}[+] 启动多维检测(线程:${THREADS})...${NC}"
    ./CloudflareST -dn $TEST_COUNT -t $THREADS -sl $SPEED_TEST_SIZE
    
    echo -e "\n${GREEN}=== 优选结果TOP10 ==="
    cat result.csv | column -t -s ',' | head -n 11
    echo -e "=====================${NC}"
}

# 主流程
main() {
    check_dependencies
    download_binary
    run_test
    rm -f CloudflareST.tar.gz result.csv
}

main
