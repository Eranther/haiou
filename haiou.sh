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

SCRIPT_VERSION="2026.05.10.7"

XRAY_CONFIG="/usr/local/etc/xray/config.json"
INFO_FILE="/root/reality-info.txt"
STATE_FILE="/root/reality-state.json"

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

    KEYS=$(xray x25519 2>&1)

    PRIVATE_KEY=$(printf '%s\n' "$KEYS" | awk '
        BEGIN { want_next = 0 }
        {
            line = $0
            lower = tolower(line)

            if (want_next == 1) {
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^[A-Za-z0-9_-]{20,}$/) {
                        print $i
                        exit
                    }
                }
            }

            if (lower ~ /private/ && lower ~ /key/) {
                sub(/^[^:]*:[[:space:]]*/, "", line)
                n = split(line, parts, /[[:space:]]+/)
                for (i = n; i >= 1; i--) {
                    if (parts[i] ~ /^[A-Za-z0-9_-]{20,}$/) {
                        print parts[i]
                        exit
                    }
                }
                want_next = 1
            }
        }
    ')

    PUBLIC_KEY=$(printf '%s\n' "$KEYS" | awk '
        BEGIN { want_next = 0 }
        {
            line = $0
            lower = tolower(line)

            if (want_next == 1) {
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^[A-Za-z0-9_-]{20,}$/) {
                        print $i
                        exit
                    }
                }
            }

            if (lower ~ /public/ && lower ~ /key/) {
                sub(/^[^:]*:[[:space:]]*/, "", line)
                n = split(line, parts, /[[:space:]]+/)
                for (i = n; i >= 1; i--) {
                    if (parts[i] ~ /^[A-Za-z0-9_-]{20,}$/) {
                        print parts[i]
                        exit
                    }
                }
                want_next = 1
            }
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
# 检查生成后的配置关键字段
############################################################
validate_generated_config() {

    local config_private_key

    config_private_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey // ""' "$XRAY_CONFIG")

    if [[ -z "$config_private_key" ]]; then
        echo
        echo -e "${RED}生成的 Xray 配置 privateKey 为空，已停止。${PLAIN}"
        echo "脚本版本: ${SCRIPT_VERSION}"
        echo "脚本路径: ${BASH_SOURCE[0]}"
        echo
        echo "xray x25519 原始输出:"
        printf '%s\n' "$KEYS"
        return 1
    fi
}

############################################################
# 写入节点状态
############################################################
save_node_state() {

    jq -n \
        --arg server_ip "$SERVER_IP" \
        --arg port "$PORT" \
        --arg uuid "$UUID" \
        --arg sni "$SNI" \
        --arg public_key "$PUBLIC_KEY" \
        --arg short_id "$SHORT_ID" \
        --arg xhttp_path "$XHTTP_PATH" \
        --arg node_name "$NODE_NAME" \
        --arg clash_mode "stream-one" \
        '{
            server_ip: $server_ip,
            port: $port,
            uuid: $uuid,
            sni: $sni,
            public_key: $public_key,
            short_id: $short_id,
            xhttp_path: $xhttp_path,
            node_name: $node_name,
            clash_mode: $clash_mode
        }' > "$STATE_FILE"
}

############################################################
# 读取旧 info 文件字段
############################################################
read_info_value() {

    local label="$1"

    awk -v label="$label" '
        $0 == label ":" {
            getline
            print
            exit
        }
    ' "$INFO_FILE"
}

############################################################
# 读取节点状态
############################################################
load_node_state() {

    if [[ -f "$STATE_FILE" ]]; then
        if ! command -v jq >/dev/null 2>&1; then
            echo -e "${RED}缺少 jq，请先选择安装 / 重装或执行: apt install -y jq${PLAIN}"
            return 1
        fi

        SERVER_IP=$(jq -r '.server_ip // ""' "$STATE_FILE")
        PORT=$(jq -r '.port // ""' "$STATE_FILE")
        UUID=$(jq -r '.uuid // ""' "$STATE_FILE")
        SNI=$(jq -r '.sni // ""' "$STATE_FILE")
        PUBLIC_KEY=$(jq -r '.public_key // ""' "$STATE_FILE")
        SHORT_ID=$(jq -r '.short_id // ""' "$STATE_FILE")
        XHTTP_PATH=$(jq -r '.xhttp_path // "/xhttp"' "$STATE_FILE")
        NODE_NAME=$(jq -r '.node_name // "Haiou-Reality-XHTTP"' "$STATE_FILE")
        CLASH_MODE=$(jq -r '.clash_mode // "stream-one"' "$STATE_FILE")
    elif [[ -f "$INFO_FILE" ]]; then
        SERVER_IP=$(read_info_value "服务器 IP")
        PORT=$(read_info_value "端口")
        UUID=$(read_info_value "UUID")
        SNI=$(read_info_value "SNI")
        PUBLIC_KEY=$(read_info_value "PublicKey")
        SHORT_ID=$(read_info_value "ShortID")
        XHTTP_PATH=$(read_info_value "Path")
        NODE_NAME="Haiou-Reality-XHTTP"
        CLASH_MODE="stream-one"
    else
        echo -e "${RED}未找到节点信息，请先安装节点${PLAIN}"
        return 1
    fi

    if [[ -z "$SERVER_IP" || -z "$PORT" || -z "$UUID" || -z "$SNI" || -z "$PUBLIC_KEY" || -z "$SHORT_ID" || -z "$XHTTP_PATH" ]]; then
        echo -e "${RED}节点信息不完整，无法生成 Clash Verge YAML${PLAIN}"
        return 1
    fi
}

############################################################
# 生成 Clash Verge / Mihomo 订阅
############################################################
write_clash_verge_yaml() {

    mkdir -p "$SUB_DIR"

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
    alpn:
      - h2
    servername: ${SNI}
    fingerprint: chrome
    client-fingerprint: chrome
    encryption: ""
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
    xhttp-opts:
      path: "${XHTTP_PATH}"
      host: ${SNI}
      mode: ${CLASH_MODE:-stream-one}

proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - "${NODE_NAME}"

rules:
  - MATCH,Proxy
EOF
}

############################################################
# 重新生成 Clash Verge 订阅
############################################################
regenerate_clash_verge_yaml() {

    load_node_state || return
    write_clash_verge_yaml

    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx || true
    open_firewall 80

    echo
    echo -e "${GREEN}Clash Verge YAML 已重新生成${PLAIN}"
    echo
    echo "订阅地址:"
    echo "http://${SERVER_IP}/reality-xhttp.yaml"
    echo
    echo "本地文件:"
    echo "$SUB_FILE"
}

############################################################
# 查看节点摘要
############################################################
show_nodes() {

    load_node_state || return

    echo
    echo "========================================="
    echo "当前节点"
    echo "========================================="
    echo "名称: ${NODE_NAME}"
    echo "地址: ${SERVER_IP}:${PORT}"
    echo "协议: VLESS + REALITY + XHTTP"
    echo "SNI: ${SNI}"
    echo "Path: ${XHTTP_PATH}"
    echo "Clash Verge YAML: http://${SERVER_IP}/reality-xhttp.yaml"
}

############################################################
# 删除节点配置
############################################################
delete_node() {

    if [[ ! -f "$XRAY_CONFIG" && ! -f "$INFO_FILE" && ! -f "$SUB_FILE" && ! -f "$STATE_FILE" ]]; then
        echo -e "${YELLOW}当前没有可删除的节点配置${PLAIN}"
        return
    fi

    read -rp "确认删除节点配置并停止 Xray? [y/N]: " confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "已取消"
        return
    fi

    systemctl stop xray || true

    rm -f "$XRAY_CONFIG"
    rm -f "$INFO_FILE"
    rm -f "$SUB_FILE"
    rm -f "$STATE_FILE"

    echo
    echo -e "${GREEN}节点配置已删除，Xray 已停止${PLAIN}"
    echo "如需移除 Xray 程序本体，请使用卸载功能。"
}

############################################################
# 生成配置
############################################################
generate_config() {

    clear

    echo -e "${GREEN}Haiou Reality XHTTP 安装${PLAIN}"
    echo "脚本版本: ${SCRIPT_VERSION}"
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

    validate_generated_config

    echo
    echo -e "${YELLOW}正在检测配置...${PLAIN}"

    test_xray_config

    systemctl enable xray
    systemctl restart xray

    systemctl enable nginx
    systemctl restart nginx

    open_firewall "$PORT"
    open_firewall 80

    VLESS_URI="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=${XHTTP_PATH}#${NODE_NAME}"

    CLASH_MODE="stream-one"
    save_node_state
    write_clash_verge_yaml

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
Clash Verge / Mihomo 订阅:
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

    wget --no-cache -O /usr/local/bin/haiou "${SCRIPT_URL}?$(date +%s)"

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
    rm -f "$STATE_FILE"

    echo
    echo -e "${GREEN}卸载完成${PLAIN}"
}

############################################################
# 菜单
############################################################
menu() {

    clear

    echo -e "${GREEN}Haiou Reality XHTTP${PLAIN} v${SCRIPT_VERSION}"
    echo
    echo "1. 安装 / 重装 VLESS + REALITY + XHTTP"
    echo "2. 查看节点摘要"
    echo "3. 查看二维码"
    echo "4. 重新生成 Clash Verge YAML"
    echo "5. 查看完整节点信息"
    echo "6. 删除节点配置"
    echo "7. 重启 Xray"
    echo "8. 查看 Xray 状态"
    echo "9. 更新 Xray"
    echo "10. 开启 BBR"
    echo "11. 更新 haiou"
    echo "12. 卸载"
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
            show_nodes
            ;;
        3)
            show_qrcode
            ;;
        4)
            regenerate_clash_verge_yaml
            ;;
        5)
            show_info
            ;;
        6)
            delete_node
            ;;
        7)
            restart_xray
            ;;
        8)
            status_xray
            ;;
        9)
            update_xray
            ;;
        10)
            enable_bbr
            ;;
        11)
            update_script
            ;;
        12)
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
