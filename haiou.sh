#!/usr/bin/env bash

############################################################
# Haiou Reality XHTTP Script
#
# 功能:
# 1. 安装 Xray-core
# 2. 部署 VLESS + REALITY + XHTTP
# 3. 自动生成分享链接
# 4. 自动生成 Clash 订阅
# 5. ANSI 二维码输出
# 6. 开启 BBR
# 7. 更新 / 重启 / 卸载 Xray
# 8. 在线更新脚本
#
# 安装:
#
# wget -O /usr/local/bin/haiou https://你的域名/reality.sh
#
# chmod +x /usr/local/bin/haiou
#
# 启动:
#
# haiou
#
############################################################

set -e

XRAY_CONFIG="/usr/local/etc/xray/config.json"
INFO_FILE="/root/reality-info.txt"

SUB_DIR="/var/www/html"
SUB_FILE="${SUB_DIR}/reality-xhttp.yaml"

SCRIPT_URL="https://你的域名/reality.sh"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 检查 root
check_root() {
    [[ $EUID -ne 0 ]] && \
    echo -e "${RED}请使用 root 运行${PLAIN}" && exit 1
}

# 安装基础依赖
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
    nginx
}

# 安装 Xray-core
install_xray() {

    echo -e "${YELLOW}安装 Xray-core...${PLAIN}"

    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

# 开启 BBR
enable_bbr() {

    grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || \
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf

    grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || \
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

    sysctl -p >/dev/null 2>&1 || true

    echo
    echo -e "${GREEN}BBR 已开启${PLAIN}"
}

# 获取公网 IP
get_ip() {

    SERVER_IP=$(curl -4 -s https://api.ipify.org)

    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(curl -4 -s https://ipv4.icanhazip.com)
    fi

    if [[ -z "$SERVER_IP" ]]; then
        read -rp "请输入服务器公网IP: " SERVER_IP
    fi
}

# 生成 Reality 配置
generate_config() {

    clear

    echo -e "${GREEN}Reality XHTTP 安装${PLAIN}"
    echo

    read -rp "请输入端口 [默认443]: " PORT
    PORT=${PORT:-443}

    read -rp "请输入SNI [默认 www.microsoft.com]: " SNI
    SNI=${SNI:-www.microsoft.com}

    read -rp "请输入XHTTP路径 [默认 /xhttp]: " XHTTP_PATH
    XHTTP_PATH=${XHTTP_PATH:-/xhttp}

    read -rp "请输入节点名称 [默认 Reality-XHTTP]: " NODE_NAME
    NODE_NAME=${NODE_NAME:-Reality-XHTTP}

    UUID=$(xray uuid)

    KEYS=$(xray x25519)

    PRIVATE_KEY=$(echo "$KEYS" | awk '/Private key/ {print $3}')
    PUBLIC_KEY=$(echo "$KEYS" | awk '/Public key/ {print $3}')

    SHORT_ID=$(openssl rand -hex 8)

    get_ip

    mkdir -p /usr/local/etc/xray

cat > $XRAY_CONFIG <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}"
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
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

    xray test -config $XRAY_CONFIG

    systemctl enable xray
    systemctl restart xray

    systemctl enable nginx
    systemctl restart nginx

    ufw allow ${PORT}/tcp >/dev/null 2>&1 || true

    VLESS_URI="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=${XHTTP_PATH}#${NODE_NAME}"

cat > $SUB_FILE <<EOF
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

cat > $INFO_FILE <<EOF

=========================================
Reality XHTTP 安装完成
=========================================

服务器IP:
${SERVER_IP}

端口:
${PORT}

协议:
VLESS

传输:
XHTTP

TLS:
REALITY

UUID:
${UUID}

SNI:
${SNI}

PublicKey:
${PUBLIC_KEY}

ShortID:
${SHORT_ID}

Path:
${XHTTP_PATH}

=========================================
VLESS 分享链接:
=========================================

${VLESS_URI}

=========================================
Clash订阅:
=========================================

http://${SERVER_IP}/reality-xhttp.yaml

=========================================

EOF

    clear

    cat $INFO_FILE

    echo
    echo "========================================="
    echo "二维码:"
    echo "========================================="

    qrencode -t ANSIUTF8 "$VLESS_URI"

    echo
    echo -e "${GREEN}安装完成${PLAIN}"
}

# 查看节点信息
show_info() {

    if [[ -f "$INFO_FILE" ]]; then
        cat "$INFO_FILE"
    else
        echo "未安装"
    fi
}

# 查看二维码
show_qrcode() {

    if [[ -f "$INFO_FILE" ]]; then

        URI=$(grep '^vless://' $INFO_FILE)

        echo
        echo "========================================="
        echo "二维码:"
        echo "========================================="

        qrencode -t ANSIUTF8 "$URI"

    else
        echo "未安装"
    fi
}

# 重启 Xray
restart_xray() {

    systemctl restart xray

    echo
    echo -e "${GREEN}Xray 已重启${PLAIN}"
}

# 更新 Xray
update_xray() {

    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

    echo
    echo -e "${GREEN}Xray 已更新${PLAIN}"
}

# 更新脚本
update_script() {

    wget -O /usr/local/bin/haiou $SCRIPT_URL

    chmod +x /usr/local/bin/haiou

    echo
    echo -e "${GREEN}脚本已更新${PLAIN}"
}

# 卸载
uninstall_all() {

    read -rp "确认卸载? [y/N]: " confirm

    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return

    systemctl stop xray || true
    systemctl disable xray || true

    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge

    rm -f "$INFO_FILE"
    rm -f "$SUB_FILE"

    echo
    echo -e "${GREEN}卸载完成${PLAIN}"
}

# 菜单
menu() {

    clear

    echo -e "${GREEN}Haiou Reality XHTTP${PLAIN}"
    echo
    echo "1. 安装 VLESS Reality XHTTP"
    echo "2. 查看节点信息"
    echo "3. 查看二维码"
    echo "4. 重启 Xray"
    echo "5. 更新 Xray"
    echo "6. 开启BBR"
    echo "7. 更新脚本"
    echo "8. 卸载"
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
            update_xray
            ;;
        6)
            enable_bbr
            ;;
        7)
            update_script
            ;;
        8)
            uninstall_all
            ;;
        0)
            exit 0
            ;;
    esac
}

check_root

while true; do
    menu
    echo
    read -rp "按回车继续..."
done