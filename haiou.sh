#!/usr/bin/env bash

############################################################
# Haiou Reality XHTTP Script
#
# GitHub:
# https://github.com/Eranther/haiou
#
# Raw:
# https://raw.githubusercontent.com/Eranther/haiou/main/haiou.sh
#
# 功能:
# 1. 安装 Xray-core
# 2. 部署 VLESS + REALITY + XHTTP
# 3. 自动生成 VLESS 分享链接
# 4. 自动生成 Clash / Mihomo 订阅
# 5. ANSI 二维码输出
# 6. 开启 BBR
# 7. 更新 / 重启 / 卸载 Xray
# 8. 在线更新脚本
#
# 安装:
#
# wget -O /usr/local/bin/haiou \
# https://raw.githubusercontent.com/Eranther/haiou/main/haiou.sh && \
# chmod +x /usr/local/bin/haiou && \
# haiou
#
# 后续唤醒:
#
# haiou
#
############################################################

set -e

XRAY_CONFIG="/usr/local/etc/xray/config.json"
INFO_FILE="/root/reality-info.txt"

SUB_DIR="/var/www/html"
SUB_FILE="${SUB_DIR}/reality-xhttp.yaml"

SCRIPT_URL="https://raw.githubusercontent.com/Eranther/haiou/main/haiou.sh"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
PLAIN="\033[0m"

############################################################
# 检查 root
############################################################
check_root() {

    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}请使用 root 运行${PLAIN}"
        exit 1
    fi
}

############################################################
# 检查系统
############################################################
check_os() {

    if [[ ! -f /etc/debian_version ]]; then
        echo -e "${RED}当前脚本仅支持 Debian / Ubuntu${PLAIN}"
        exit 1
    fi
}

############################################################
# 安装基础依赖
############################################################
install_base() {

    apt update

    apt install -y \
    curl \
    wget \
    unzip \
    jq \
    openssl \
    uuid-runtime \
    qrencode \
    nginx \
    ca-certificates
}

############################################################
# 安装 Xray
############################################################
install_xray() {

    echo
    echo -e "${YELLOW}正在安装 / 更新 Xray-core...${PLAIN}"

    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

############################################################
# 开启 BBR
############################################################
enable_bbr() {

    grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || \
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf

    grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || \
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

    sysctl -p >/dev/null 2>&1 || true

    echo
    echo -e "${GREEN}BBR 已开启${PLAIN}"
}

############################################################
# 获取公网 IP
############################################################
get_ip() {

    SERVER_IP=$(curl -4 -s --max-time 8 https://api.ipify.org || true)

    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(curl -4 -s --max-time 8 https://ipv4.icanhazip.com || true)
    fi

    if [[ -z "$SERVER_IP" ]]; then
        read -rp "请输入服务器公网 IP: " SERVER_IP
    fi
}

############################################################
# 开放防火墙
############################################################
open_firewall() {

    local port="$1"

    if command -v ufw >/dev/null 2>&1; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    fi

    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}

############################################################
# 检测 Xray 配置
############################################################
test_xray_config() {

    if xray run -test -config "$XRAY_CONFIG"; then
        return 0
    fi

    if xray -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
        xray -test -config "$XRAY_CONFIG"
        return 0
    fi

    echo
    echo -e "${RED}Xray 配置检测失败，请检查上方错误信息${PLAIN}"
    return 1
}

############################################################
# 生成 Reality 密钥
############################################################
generate_reality_keys() {

    KEYS=$(xray x25519)

    PRIVATE_KEY=$(printf '%s\n' "$KEYS" | awk '
        tolower($0) ~ /private.*key/ {
            sub(/^[^:]*:[[:space:]]*/, "", $0)
            print $NF
            exit
        }
    ')

    PUBLIC_KEY=$(printf '%s\n' "$KEYS" | awk '
        tolower($0) ~ /public.*key/ {
            sub(/^[^:]*:[[:space:]]*/, "", $0)
            print $NF
            exit
        }
    ')

    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        echo
        echo -e "${RED}Reality 密钥生成失败，无法解析 xray x25519 输出:${PLAIN}"
        printf '%s\n' "$KEYS"
        return 1
    fi
}

############################################################
# 生成配置
############################################################
generate_config() {

    clear

    echo -e "${GREEN}Haiou Reality XHTTP 安装${PLAIN}"
    echo

    read -rp "请输入端口 [默认 443]: " PORT
    PORT=${PORT:-443}

    read -rp "请输入 Reality SNI [默认 www.microsoft.com]: " SNI
    SNI=${SNI:-www.microsoft.com}

    read -rp "请输入 XHTTP 路径 [默认 /xhttp]: " XHTTP_PATH
    XHTTP_PATH=${XHTTP_PATH:-/xhttp}

    read -rp "请输入节点名称 [默认 Haiou-Reality-XHTTP]: " NODE_NAME
    NODE_NAME=${NODE_NAME:-Haiou-Reality-XHTTP}

    UUID=$(xray uuid)

    generate_reality_keys

    SHORT_ID=$(openssl rand -hex 8)

    get_ip

    mkdir -p /usr/local/etc/xray
    mkdir -p "$SUB_DIR"

cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality-xhttp-in",
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "email": "haiou@reality"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {
          "path": "${XHTTP_PATH}",
          "mode": "auto"
        },
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": [
            "${SNI}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ]
}
EOF

    echo
    echo -e "${YELLOW}正在检测配置...${PLAIN}"

    test_xray_config

    systemctl enable xray
    systemctl restart xray

    systemctl enable nginx
    systemctl restart nginx

    open_firewall "$PORT"

    VLESS_URI="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=${XHTTP_PATH}#${NODE_NAME}"

cat > "$SUB_FILE" <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: false

proxies:
  - name: "${NODE_NAME}"
    type: vless
    server: ${SERVER_IP}
    port: ${PORT}
    uuid: ${UUID}
    network: xhttp
    tls: true
    udp: true
    servername: ${SNI}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
    xhttp-opts:
      path: "${XHTTP_PATH}"

proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - "${NODE_NAME}"

rules:
  - MATCH,Proxy
EOF

cat > "$INFO_FILE" <<EOF

=========================================
Haiou Reality XHTTP 安装完成
=========================================

服务器 IP:
${SERVER_IP}

端口:
${PORT}

协议:
VLESS

传输:
XHTTP

安全:
REALITY

UUID:
${UUID}

SNI:
${SNI}

PublicKey:
${PUBLIC_KEY}

ShortID:
${SHORT_ID}

Fingerprint:
chrome

Path:
${XHTTP_PATH}

Flow:
留空

=========================================
VLESS 分享链接:
=========================================

${VLESS_URI}

=========================================
Clash / Mihomo 订阅:
=========================================

http://${SERVER_IP}/reality-xhttp.yaml

=========================================
常用命令:
=========================================

唤醒脚本:
haiou

查看节点:
cat /root/reality-info.txt

查看日志:
journalctl -u xray -f

查看状态:
systemctl status xray

=========================================

EOF

    clear

    cat "$INFO_FILE"

    echo
    echo "========================================="
    echo "二维码:"
    echo "========================================="

    qrencode -t ANSIUTF8 "$VLESS_URI"

    echo
    echo -e "${GREEN}安装完成${PLAIN}"
}

############################################################
# 查看节点信息
############################################################
show_info() {

    if [[ -f "$INFO_FILE" ]]; then
        cat "$INFO_FILE"
    else
        echo -e "${RED}未找到节点信息${PLAIN}"
    fi
}

############################################################
# 查看二维码
############################################################
show_qrcode() {

    if [[ -f "$INFO_FILE" ]]; then

        URI=$(grep '^vless://' "$INFO_FILE" || true)

        if [[ -z "$URI" ]]; then
            echo -e "${RED}未找到二维码信息${PLAIN}"
            return
        fi

        echo
        echo "========================================="
        echo "二维码:"
        echo "========================================="

        qrencode -t ANSIUTF8 "$URI"

    else
        echo -e "${RED}未安装${PLAIN}"
    fi
}

############################################################
# 重启 Xray
############################################################
restart_xray() {

    systemctl restart xray

    echo
    echo -e "${GREEN}Xray 已重启${PLAIN}"
}

############################################################
# 查看状态
############################################################
status_xray() {

    systemctl status xray --no-pager
}

############################################################
# 更新 Xray
############################################################
update_xray() {

    echo
    echo -e "${YELLOW}正在更新 Xray-core...${PLAIN}"

    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

    systemctl restart xray || true

    echo
    echo -e "${GREEN}Xray 更新完成${PLAIN}"
}

############################################################
# 更新脚本
############################################################
update_script() {

    echo
    echo -e "${YELLOW}正在更新 haiou...${PLAIN}"

    wget -O /usr/local/bin/haiou "$SCRIPT_URL"

    chmod +x /usr/local/bin/haiou

    echo
    echo -e "${GREEN}脚本更新完成${PLAIN}"

    echo
    echo "重新执行:"
    echo "haiou"
}

############################################################
# 卸载
############################################################
uninstall_all() {

    read -rp "确认卸载? [y/N]: " confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "已取消"
        return
    fi

    systemctl stop xray || true
    systemctl disable xray || true

    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge || true

    rm -f "$INFO_FILE"
    rm -f "$SUB_FILE"

    echo
    echo -e "${GREEN}卸载完成${PLAIN}"
}

############################################################
# 菜单
############################################################
menu() {

    clear

    echo -e "${GREEN}Haiou Reality XHTTP${PLAIN}"
    echo
    echo "1. 安装 / 重装 VLESS + REALITY + XHTTP"
    echo "2. 查看节点信息"
    echo "3. 查看二维码"
    echo "4. 重启 Xray"
    echo "5. 查看 Xray 状态"
    echo "6. 更新 Xray"
    echo "7. 开启 BBR"
    echo "8. 更新 haiou"
    echo "9. 卸载"
    echo "0. 退出"
    echo

    read -rp "请选择: " choice

    case "$choice" in
        1)
            install_base
            install_xray
            generate_config
            ;;
        2)
            show_info
            ;;
        3)
            show_qrcode
            ;;
        4)
            restart_xray
            ;;
        5)
            status_xray
            ;;
        6)
            update_xray
            ;;
        7)
            enable_bbr
            ;;
        8)
            update_script
            ;;
        9)
            uninstall_all
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选择${PLAIN}"
            ;;
    esac
}

check_root
check_os

while true; do
    menu
    echo
    read -rp "按回车返回菜单..."
done
###
