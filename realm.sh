#!/usr/bin/env bash
# ==============================================================================
# Realm 高性能网络中转一键管理脚本 (Pro 增强版)
# 支持系统: Debian / Ubuntu / CentOS / Rocky / AlmaLinux / Fedora / Alpine / Arch
# 架构支持: x86_64, aarch64, armv7, i686
# 仓库核心: https://github.com/zhboner/realm
# ==============================================================================

# 严格模式中的安全退出
set -o pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
PLAIN='\033[0m'

# 路径定义
CONF_DIR="/etc/realm"
CONFIG_FILE="${CONF_DIR}/config.toml"
BACKUP_DIR="${CONF_DIR}/backup"
LOG_DIR="/var/log/realm"
LOG_FILE="${LOG_DIR}/realm.log"
SERVICE_FILE="/etc/systemd/system/realm.service"
BIN_PATH="/usr/local/bin/realm-bin"
SCRIPT_PATH="/usr/local/bin/realm"
SHORT_SCRIPT_PATH="/usr/local/bin/re"
TEMP_DIR="/tmp/realm_install"

# 脚本版本与官方源
SCRIPT_VERSION="2.0.0"
GITHUB_REPO="zhboner/realm"
SCRIPT_RAW_URL="https://raw.githubusercontent.com/DongHua3/realm-pro/main/realm.sh"

# 默认加速源 (可切换)
GH_MIRROR=""

# ------------------------------------------------------------------------------
# 工具函数
# ------------------------------------------------------------------------------

info()    { echo -e "${CYAN}[信息]${PLAIN} $1"; }
success() { echo -e "${GREEN}[成功]${PLAIN} $1"; }
warn()    { echo -e "${YELLOW}[警告]${PLAIN} $1"; }
error()   { echo -e "${RED}[错误]${PLAIN} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本必须以 root 用户权限运行！"
        exit 1
    fi
}

check_sys() {
    if [[ -f /etc/redhat-release ]]; then
        RELEASE="centos"
        PKG_CMD="yum install -y"
    elif grep -Eqi "debian" /etc/issue || grep -Eq "debian" /etc/*-release; then
        RELEASE="debian"
        PKG_CMD="apt-get install -y"
    elif grep -Eqi "ubuntu" /etc/issue || grep -Eq "ubuntu" /etc/*-release; then
        RELEASE="ubuntu"
        PKG_CMD="apt-get install -y"
    elif grep -Eqi "alpine" /etc/issue || grep -Eq "alpine" /etc/*-release; then
        RELEASE="alpine"
        PKG_CMD="apk add --no-cache"
    elif grep -Eqi "arch" /etc/issue || grep -Eq "arch" /etc/*-release; then
        RELEASE="arch"
        PKG_CMD="pacman -Sy --noconfirm"
    else
        RELEASE="unknown"
        PKG_CMD="apt-get install -y"
    fi
}

check_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)
            REALM_ARCH="x86_64-unknown-linux-gnu"
            ;;
        aarch64|arm64)
            REALM_ARCH="aarch64-unknown-linux-gnu"
            ;;
        armv7*|armhf)
            REALM_ARCH="armv7-unknown-linux-musleabihf"
            ;;
        i386|i686)
            REALM_ARCH="i686-unknown-linux-gnu"
            ;;
        *)
            error "不支持的 CPU 架构: $ARCH"
            exit 1
            ;;
    esac
}

install_dependencies() {
    info "正在安装必要的基础依赖..."
    check_sys
    if [[ "$RELEASE" == "debian" || "$RELEASE" == "ubuntu" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl wget tar gzip ufw lsof net-tools iproute2 jq >/dev/null 2>&1
    elif [[ "$RELEASE" == "centos" ]]; then
        yum install -y epel-release >/dev/null 2>&1
        yum install -y curl wget tar gzip firewalld lsof net-tools iproute jq >/dev/null 2>&1
    elif [[ "$RELEASE" == "alpine" ]]; then
        apk update >/dev/null 2>&1
        apk add --no-cache curl wget tar gzip iproute2 jq >/dev/null 2>&1
    elif [[ "$RELEASE" == "arch" ]]; then
        pacman -Sy --noconfirm curl wget tar gzip iproute2 jq >/dev/null 2>&1
    fi
}

# 格式化 IP (自动识别 IPv6 并补充方括号)
format_ip() {
    local ip="$1"
    # 如果已经包含方括号，直接返回
    if [[ "$ip" =~ ^\[.*\]$ ]]; then
        echo "$ip"
        return
    fi
    # 判断是否为 IPv6 地址 (包含冒号且不含点，或者符合 IPv6 特征)
    if [[ "$ip" =~ : && ! "$ip" =~ \. ]]; then
        echo "[$ip]"
    else
        echo "$ip"
    fi
}

# 校验端口合法性 (1-65535)
validate_port() {
    local port="$1"
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

# 检查本地端口占用
is_port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tuln | grep -q ":${port} "
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tuln | grep -q ":${port} "
    elif command -v lsof >/dev/null 2>&1; then
        lsof -i :"$port" >/dev/null 2>&1
    else
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 防火墙联动
# ------------------------------------------------------------------------------

firewall_allow() {
    local port="$1"
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw "active"; then
        ufw allow "$port"/tcp >/dev/null 2>&1
        ufw allow "$port"/udp >/dev/null 2>&1
        info "UFW 防火墙已放行端口: $port (TCP/UDP)"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --zone=public --add-port="$port"/tcp --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --add-port="$port"/udp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        info "Firewalld 防火墙已放行端口: $port (TCP/UDP)"
    elif command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1
        iptables -I INPUT -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1
    fi
}

firewall_deny() {
    local port="$1"
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw "active"; then
        ufw delete allow "$port"/tcp >/dev/null 2>&1
        ufw delete allow "$port"/udp >/dev/null 2>&1
        info "UFW 防火墙已移除放行端口: $port"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --zone=public --remove-port="$port"/tcp --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --remove-port="$port"/udp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        info "Firewalld 防火墙已移除放行端口: $port"
    fi
}

# ------------------------------------------------------------------------------
# 安装、更新与卸载
# ------------------------------------------------------------------------------

choose_mirror() {
    echo -e "${YELLOW}请选择 GitHub 下载镜像源 (国内/网络受阻 VPS 建议选加速源):${PLAIN}"
    echo "1. GitHub 官方直连 (默认推荐境外 VPS)"
    echo "2. ghproxy.net 加速代理 (适合中国大陆 VPS)"
    echo "3. mirror.ghproxy.com 加速代理"
    echo "4. 自定义加速前缀"
    read -rp "请输入选项 [1-4, 默认 1]: " mirror_opt
    case "$mirror_opt" in
        2) GH_MIRROR="https://ghproxy.net/" ;;
        3) GH_MIRROR="https://mirror.ghproxy.com/" ;;
        4)
            read -rp "请输入自定义前缀 (如 https://proxy.example.com/): " GH_MIRROR
            [[ -n "$GH_MIRROR" && "$GH_MIRROR" != */ ]] && GH_MIRROR="${GH_MIRROR}/"
            ;;
        *) GH_MIRROR="" ;;
    esac
}

install_realm() {
    check_arch
    install_dependencies
    choose_mirror

    info "正在获取 Realm 最新版本号..."
    local latest_version
    latest_version=$(curl -sL "${GH_MIRROR}https://api.github.com/repos/${GITHUB_REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

    if [[ -z "$latest_version" ]]; then
        warn "获取最新版本号失败，尝试直接下载最新稳定版..."
        DOWNLOAD_URL="${GH_MIRROR}https://github.com/${GITHUB_REPO}/releases/latest/download/realm-${REALM_ARCH}.tar.gz"
    else
        info "检测到最新版本: ${GREEN}${latest_version}${PLAIN}"
        DOWNLOAD_URL="${GH_MIRROR}https://github.com/${GITHUB_REPO}/releases/download/${latest_version}/realm-${REALM_ARCH}.tar.gz"
    fi

    rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"
    info "正在下载: $DOWNLOAD_URL"
    if ! wget -O "${TEMP_DIR}/realm.tar.gz" "$DOWNLOAD_URL"; then
        error "下载 Realm 二进制失败，请检查网络或切换镜像源！"
        rm -rf "$TEMP_DIR"
        return 1
    fi

    tar -xzf "${TEMP_DIR}/realm.tar.gz" -C "$TEMP_DIR"
    if [[ ! -f "${TEMP_DIR}/realm" ]]; then
        error "解压失败，未找到 realm 二进制程序！"
        rm -rf "$TEMP_DIR"
        return 1
    fi

    chmod +x "${TEMP_DIR}/realm"
    mv -f "${TEMP_DIR}/realm" "$BIN_PATH"
    rm -rf "$TEMP_DIR"

    # 安装管理脚本到系统全局命令 (支持 re 与 realm 双快捷指令)
    if [[ -f "$0" && "$0" != *"bash"* && "$0" != *"/dev/fd"* ]]; then
        cp -f "$0" "$SCRIPT_PATH" 2>/dev/null || true
    else
        curl -fsSL "${GH_MIRROR}${SCRIPT_RAW_URL}" -o "$SCRIPT_PATH" 2>/dev/null || wget -qO "$SCRIPT_PATH" "${GH_MIRROR}${SCRIPT_RAW_URL}" 2>/dev/null || true
    fi
    chmod +x "$SCRIPT_PATH" 2>/dev/null || true
    ln -sf "$SCRIPT_PATH" "$SHORT_SCRIPT_PATH" 2>/dev/null || cp -f "$SCRIPT_PATH" "$SHORT_SCRIPT_PATH" 2>/dev/null || true
    chmod +x "$SHORT_SCRIPT_PATH" 2>/dev/null || true

    # 创建必要目录
    mkdir -p "$CONF_DIR" "$BACKUP_DIR" "$LOG_DIR"

    # 初始化 config.toml
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" <<EOF
[log]
level = "warn"
output = "${LOG_FILE}"

[network]
no_tcp = false
use_udp = true
tcp_timeout = 5
udp_timeout = 30

EOF
        info "已初始化默认配置文件: $CONFIG_FILE"
    fi

    # 配置高质量 Systemd 守护服务
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Realm High-Performance Relay Server
Documentation=https://github.com/${GITHUB_REPO}
After=network.target network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=root
WorkingDirectory=${CONF_DIR}
ExecStart=${BIN_PATH} -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
LimitNPROC=512
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable realm >/dev/null 2>&1
    systemctl restart realm >/dev/null 2>&1

    success "Realm 核心安装完成！"
    echo -e "${GREEN}快捷指令已就绪：在任意终端输入 ${BOLD}${YELLOW}re${PLAIN}${GREEN} 即可打开管理面板！(也支持 ${BOLD}${YELLOW}realm${PLAIN}${GREEN})${PLAIN}\n"
}

uninstall_realm() {
    echo -e "${RED}${BOLD}警告: 即将卸载 Realm 及其中转服务！${PLAIN}"
    read -rp "是否保留配置文件及转发规则备份？(Y/n): " keep_conf
    keep_conf=${keep_conf:-y}

    info "正在停止并清理服务..."
    systemctl stop realm >/dev/null 2>&1
    systemctl disable realm >/dev/null 2>&1
    rm -f "$SERVICE_FILE"
    rm -f "$BIN_PATH"
    systemctl daemon-reload

    if [[ "$keep_conf" =~ ^[Nn]$ ]]; then
        rm -rf "$CONF_DIR" "$LOG_DIR"
        info "已删除配置文件及日志目录。"
    else
        info "配置文件已保留在: $CONF_DIR"
    fi

    # 询问是否移除快捷命令
    read -rp "是否移除快捷命令 're' 和 'realm'？(y/N): " rm_menu
    if [[ "$rm_menu" =~ ^[Yy]$ ]]; then
        rm -f "$SCRIPT_PATH" "$SHORT_SCRIPT_PATH"
        success "快捷命令已移除。"
    fi

    success "Realm 卸载完成！"
}

# ------------------------------------------------------------------------------
# 转发规则管理 (CRUD)
# ------------------------------------------------------------------------------

# 解析配置中的规则列表
parse_endpoints() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        return
    fi
    # 采用 awk 提取结构化信息 (序号, listen, remote, send_proxy, remark)
    awk '
        BEGIN { count=0; listen=""; remote=""; proxy="关闭"; remark="-"; in_ep=0 }
        /^\[\[endpoints\]\]/ {
            if (in_ep == 1 && listen != "") {
                count++;
                printf("%d|%s|%s|%s|%s\n", count, listen, remote, proxy, remark);
            }
            listen=""; remote=""; proxy="关闭"; remark="-"; in_ep=1; next
        }
        /^listen *=/ {
            gsub(/[ "]/, "", $0);
            split($0, arr, "=");
            listen=arr[2];
        }
        /^remote *=/ {
            gsub(/[ "]/, "", $0);
            split($0, arr, "=");
            remote=arr[2];
        }
        /^send_proxy *= *true/ {
            proxy="开启(v2)";
        }
        /^send_proxy_version *= *1/ {
            if (proxy ~ /开启/) proxy="开启(v1)";
        }
        /^# *remark *=/ {
            sub(/^# *remark *= */, "", $0);
            gsub(/^"|"$/, "", $0);
            remark=$0;
        }
        END {
            if (in_ep == 1 && listen != "") {
                count++;
                printf("%d|%s|%s|%s|%s\n", count, listen, remote, proxy, remark);
            }
        }
    ' "$CONFIG_FILE"
}

list_rules() {
    echo -e "\n${BOLD}${CYAN}========== 当前 Realm 转发规则列表 ==========${PLAIN}"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        warn "配置文件不存在，请先安装或初始化 Realm。"
        return
    fi

    local rules
    rules=$(parse_endpoints)
    if [[ -z "$rules" ]]; then
        echo -e "${YELLOW}暂无任何转发规则，请选择 [1] 添加规则。${PLAIN}"
        echo -e "${CYAN}==============================================${PLAIN}\n"
        return
    fi

    printf "%-4s | %-20s | %-32s | %-12s | %-15s\n" "ID" "本地监听 (Listen)" "落地目标 (Remote)" "PROXY协议" "备注说明"
    echo "-------------------------------------------------------------------------------------------------"
    while IFS="|" read -r id listen remote proxy remark; do
        printf "%-4s | %-20s | %-32s | %-12s | %-15s\n" "$id" "$listen" "$remote" "$proxy" "$remark"
    done <<< "$rules"
    echo -e "${CYAN}==============================================${PLAIN}\n"
}

backup_config() {
    mkdir -p "$BACKUP_DIR"
    local bak_file="${BACKUP_DIR}/config_$(date +%Y%m%d_%H%M%S).toml.bak"
    cp -f "$CONFIG_FILE" "$bak_file"
}

add_rule() {
    echo -e "\n${BOLD}${GREEN}=== 添加新的端口转发规则 ===${PLAIN}"

    # 1. 监听端口
    local l_port
    while true; do
        read -rp "请输入中转机(本地)监听端口 [1-65535]: " l_port
        if ! validate_port "$l_port"; then
            error "端口输入不合法，必须是 1 到 65535 之间的数字！"
            continue
        fi
        # 检查配置中是否已存在
        if grep -q "listen *= *\"0\.0\.0\.0:${l_port}\"" "$CONFIG_FILE" 2>/dev/null; then
            error "该端口已在 Realm 配置文件中被使用，请更换端口！"
            continue
        fi
        if is_port_in_use "$l_port"; then
            warn "检测到端口 $l_port 已被系统中其它进程占用，继续可能导致冲突！"
            read -rp "是否依然强制使用此端口？(y/N): " force_use
            [[ "$force_use" =~ ^[Yy]$ ]] && break
        else
            break
        fi
    done

    # 2. 监听地址类型 (默认全部 0.0.0.0 支持双栈)
    local l_ip="0.0.0.0"

    # 3. 落地机目标
    local r_host
    while true; do
        read -rp "请输入落地机 IP 或 域名: " r_host
        r_host=$(echo "$r_host" | tr -d '[:space:]')
        if [[ -z "$r_host" ]]; then
            error "落地机地址不能为空！"
            continue
        fi
        # 自动识别 IPv6
        r_host=$(format_ip "$r_host")
        break
    done

    # 4. 落地机端口
    local r_port
    while true; do
        read -rp "请输入落地机目标端口 [1-65535]: " r_port
        if validate_port "$r_port"; then
            break
        else
            error "端口输入不合法，必须是 1 到 65535 之间的数字！"
        fi
    done

    # 5. 高级选项：PROXY Protocol (传递源 IP)
    echo -e "\n${YELLOW}是否启用 PROXY Protocol (用于传递真实客户端源 IP)？${PLAIN}"
    echo "1. 不开启 (默认，绝大多数中转场景)"
    echo "2. 开启 PROXY Protocol v2 (推荐对接支持 PROXY 的落地节点，如 Nginx/V2Ray/Xray)"
    echo "3. 开启 PROXY Protocol v1"
    read -rp "请选择 [1-3, 默认 1]: " proxy_choice
    local enable_proxy=false
    local proxy_ver=2
    case "$proxy_choice" in
        2) enable_proxy=true; proxy_ver=2 ;;
        3) enable_proxy=true; proxy_ver=1 ;;
        *) enable_proxy=false ;;
    esac

    # 6. 备注
    read -rp "请输入该规则的备注说明 (可选，回车跳过): " rule_remark
    rule_remark=${rule_remark:-"-"}

    # 写入配置
    backup_config
    {
        echo ""
        echo "[[endpoints]]"
        echo "# remark = \"${rule_remark}\""
        echo "listen = \"${l_ip}:${l_port}\""
        echo "remote = \"${r_host}:${r_port}\""
        if [ "$enable_proxy" = true ]; then
            echo "send_proxy = true"
            echo "send_proxy_version = ${proxy_ver}"
        fi
    } >> "$CONFIG_FILE"

    # 防火墙放行
    firewall_allow "$l_port"

    # 重启并验证
    if restart_service; then
        success "转发规则添加成功并已实时生效！"
    else
        error "Realm 重启失败，正在尝试回滚配置..."
        # 回滚最近一次备份
        local latest_bak
        latest_bak=$(ls -t "${BACKUP_DIR}"/config_*.toml.bak 2>/dev/null | head -n 1)
        if [[ -n "$latest_bak" ]]; then
            cp -f "$latest_bak" "$CONFIG_FILE"
            systemctl restart realm
            warn "已回滚至添加前的配置状态！"
        fi
    fi
}

delete_rule() {
    list_rules
    local rules
    rules=$(parse_endpoints)
    if [[ -z "$rules" ]]; then
        return
    fi

    local total_count
    total_count=$(echo "$rules" | wc -l)

    read -rp "请输入要删除的规则 ID 序号 [1-${total_count}] (输入 0 取消): " del_id
    if [[ "$del_id" == "0" || -z "$del_id" ]]; then
        info "已取消删除。"
        return
    fi

    if ! [[ "$del_id" =~ ^[0-9]+$ ]] || [ "$del_id" -lt 1 ] || [ "$del_id" -gt "$total_count" ]; then
        error "输入的序号不存在！"
        return
    fi

    # 获取要删除规则的 listen 端口
    local target_rule
    target_rule=$(echo "$rules" | grep "^${del_id}|")
    local listen_addr
    listen_addr=$(echo "$target_rule" | awk -F'|' '{print $2}')
    local listen_port
    listen_port=$(echo "$listen_addr" | awk -F':' '{print $NF}')

    backup_config

    # 使用 awk 精确删除对应的 [[endpoints]] 块
    awk -v target="$del_id" '
        BEGIN { count=0; in_block=0; block_str="" }
        /^\[\[endpoints\]\]/ {
            if (in_block == 1) {
                count++;
                if (count != target) printf "%s", block_str;
            }
            in_block=1;
            block_str=$0 "\n";
            next
        }
        {
            if (in_block == 1) {
                block_str = block_str $0 "\n";
            } else {
                print $0;
            }
        }
        END {
            if (in_block == 1) {
                count++;
                if (count != target) printf "%s", block_str;
            }
        }
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv -f "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    if [[ -n "$listen_port" ]]; then
        firewall_deny "$listen_port"
    fi

    restart_service
    success "规则 [ID: ${del_id}] 删除成功，服务已更新！"
}

edit_raw_config() {
    local editor="nano"
    if ! command -v nano >/dev/null 2>&1; then
        editor="vi"
    fi
    info "即将使用 ${editor} 打开配置文件: $CONFIG_FILE"
    read -rp "按回车键继续..."
    backup_config
    "$editor" "$CONFIG_FILE"
    restart_service
}

# ------------------------------------------------------------------------------
# 服务控制与状态
# ------------------------------------------------------------------------------

restart_service() {
    info "正在重启 Realm 服务..."
    systemctl daemon-reload
    if systemctl restart realm; then
        sleep 0.5
        if systemctl is-active --quiet realm; then
            success "Realm 服务运行正常！"
            return 0
        fi
    fi
    error "Realm 服务启动失败！以下是最近的错误日志:"
    journalctl -u realm --no-pager -n 15
    return 1
}

view_logs() {
    echo -e "\n${CYAN}========== 实时日志 (按 Ctrl+C 退出) ==========${PLAIN}"
    if [[ -f "$LOG_FILE" && -s "$LOG_FILE" ]]; then
        tail -f -n 50 "$LOG_FILE"
    else
        journalctl -u realm -f -n 50
    fi
}

network_diagnostic() {
    echo -e "\n${BOLD}${CYAN}=== 目标网络连通性诊断 ===${PLAIN}"
    read -rp "请输入待测试的落地机 IP 或 域名: " test_target
    test_target=$(echo "$test_target" | tr -d '[:space:]' | sed 's/\[//;s/\]//')
    read -rp "请输入测试端口 [默认 443]: " test_port
    test_port=${test_port:-443}

    info "正在测试与目标 ${test_target}:${test_port} 的 TCP 握手延时..."
    if command -v nc >/dev/null 2>&1; then
        nc -z -v -w 3 "$test_target" "$test_port"
    elif command -v curl >/dev/null 2>&1; then
        curl -v -m 3 "telnet://${test_target}:${test_port}" 2>&1 | grep -E "Connected|Failed|refused"
    else
        ping -c 4 "$test_target"
    fi
}

get_status_info() {
    if [[ ! -f "$BIN_PATH" ]]; then
        STATUS_TAG="${RED}未安装${PLAIN}"
        VER_TAG="-"
        AUTO_TAG="-"
        RULE_COUNT="0"
        return
    fi

    if systemctl is-active --quiet realm 2>/dev/null; then
        STATUS_TAG="${GREEN}运行中${PLAIN}"
    else
        STATUS_TAG="${RED}已停止${PLAIN}"
    fi

    if systemctl is-enabled --quiet realm 2>/dev/null; then
        AUTO_TAG="${GREEN}已启用${PLAIN}"
    else
        AUTO_TAG="${YELLOW}已禁用${PLAIN}"
    fi

    VER_TAG=$("$BIN_PATH" -v 2>/dev/null | awk '{print $NF}')
    [[ -z "$VER_TAG" ]] && VER_TAG="已安装"

    if [[ -f "$CONFIG_FILE" ]]; then
        RULE_COUNT=$(grep -c "^\[\[endpoints\]\]" "$CONFIG_FILE" 2>/dev/null || echo "0")
    else
        RULE_COUNT="0"
    fi
}

# ------------------------------------------------------------------------------
# 主菜单
# ------------------------------------------------------------------------------

show_menu() {
    clear
    get_status_info
    echo -e "
${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════╗
║         Realm 高性能网络中转管理面板 (Pro 增强版)         ║
╚═══════════════════════════════════════════════════════════╝${PLAIN}
 状态: ${STATUS_TAG} | 快捷指令: ${BOLD}${YELLOW}re${PLAIN} | 版本: ${GREEN}${VER_TAG}${PLAIN} | 规则数: ${YELLOW}${RULE_COUNT}${PLAIN}
-------------------------------------------------------------
 ${GREEN}1.${PLAIN} 添加转发规则 (端口/IP/PROXY协议)
 ${GREEN}2.${PLAIN} 查看所有转发规则
 ${RED}3.${PLAIN} 删除指定转发规则
 ${YELLOW}4.${PLAIN} 直接编辑配置文件 (${CONFIG_FILE})
-------------------------------------------------------------
 ${BLUE}5.${PLAIN} 启动服务
 ${BLUE}6.${PLAIN} 停止服务
 ${BLUE}7.${PLAIN} 重启服务
 ${BLUE}8.${PLAIN} 查看实时运行日志
 ${BLUE}9.${PLAIN} 目标网络连通性诊断 (Ping/TCP)
-------------------------------------------------------------
 ${PURPLE}10.${PLAIN} 安装 / 更新 Realm 核心到最新版
 ${PURPLE}11.${PLAIN} 卸载 Realm 及相关配置
 ${PLAIN}0.${PLAIN} 退出管理面板
-------------------------------------------------------------"
    read -rp "请输入选项编号 [0-11]: " choice
    case "$choice" in
        1) add_rule ;;
        2) list_rules ;;
        3) delete_rule ;;
        4) edit_raw_config ;;
        5)
            systemctl start realm
            success "服务已启动！"
            ;;
        6)
            systemctl stop realm
            warn "服务已停止！"
            ;;
        7) restart_service ;;
        8) view_logs ;;
        9) network_diagnostic ;;
        10) install_realm ;;
        11) uninstall_realm ;;
        0) exit 0 ;;
        *)
            error "请输入有效的选项编号！"
            ;;
    esac
    echo ""
    read -rp "按回车键返回主菜单..."
    show_menu
}

# ------------------------------------------------------------------------------
# 命令行快速指令支持
# ------------------------------------------------------------------------------

check_root

case "$1" in
    install)
        install_realm
        ;;
    uninstall)
        uninstall_realm
        ;;
    start)
        systemctl start realm && success "Realm 已启动"
        ;;
    stop)
        systemctl stop realm && warn "Realm 已停止"
        ;;
    restart)
        restart_service
        ;;
    status)
        systemctl status realm
        ;;
    list|ls)
        list_rules
        ;;
    add)
        add_rule
        ;;
    del|rm)
        delete_rule
        ;;
    log|logs)
        view_logs
        ;;
    *)
        show_menu
        ;;
esac
