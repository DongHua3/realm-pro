#!/usr/bin/env bash
# ==============================================================================
# Realm 高性能网络中转一键管理脚本 (Pro 工业级增强版)
# 支持系统: Debian / Ubuntu / CentOS / Rocky / AlmaLinux / Fedora / Alpine / Arch
# 架构支持: x86_64 (glibc/musl), aarch64 (glibc/musl), armv7 (musl/glibc)
# 仓库核心: https://github.com/zhboner/realm
# 管理仓库: https://github.com/DongHua3/realm-pro
# ==============================================================================

# 严格模式与安全管道
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
RULES_DIR="${CONF_DIR}/rules.d"
GLOBAL_CONF="${CONF_DIR}/00-global.toml"
LEGACY_CONFIG="${CONF_DIR}/config.toml"
BACKUP_DIR="${CONF_DIR}/backup"
LOG_DIR="/var/log/realm"
LOG_FILE="${LOG_DIR}/realm.log"
SERVICE_FILE="/etc/systemd/system/realm.service"
OPENRC_SERVICE="/etc/init.d/realm"
BIN_PATH="/usr/local/bin/realm-bin"
SCRIPT_PATH="/usr/local/bin/realm"
SHORT_SCRIPT_PATH="/usr/local/bin/re"

# 脚本版本与官方源
SCRIPT_VERSION="2.1.4"
GITHUB_REPO="zhboner/realm"
SCRIPT_RAW_URL="https://raw.githubusercontent.com/DongHua3/realm-pro/main/realm.sh"

# 默认加速源 (可配置)
GH_MIRROR=""

# ------------------------------------------------------------------------------
# 基础打印与日志工具
# ------------------------------------------------------------------------------

info()    { echo -e "${CYAN}[信息]${PLAIN} $1"; }
success() { echo -e "${GREEN}[成功]${PLAIN} $1"; }
warn()    { echo -e "${YELLOW}[警告]${PLAIN} $1"; }
error()   { echo -e "${RED}[错误]${PLAIN} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此操作需要 root 权限，请使用 sudo 或 root 用户运行！"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# 系统环境与架构感知
# ------------------------------------------------------------------------------

check_sys() {
    INIT_SYS="systemd"
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        RELEASE=${ID:-unknown}
        RELEASE_LIKE=${ID_LIKE:-""}
    elif [[ -f /etc/redhat-release ]]; then
        RELEASE="centos"
        RELEASE_LIKE="rhel"
    elif [[ -f /etc/alpine-release ]]; then
        RELEASE="alpine"
        RELEASE_LIKE="alpine"
    else
        RELEASE="unknown"
        RELEASE_LIKE="unknown"
    fi

    # 检测包管理器
    if command -v apt-get >/dev/null 2>&1; then
        PKG_CMD="DEBIAN_FRONTEND=noninteractive apt-get install -y"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_CMD="dnf install -y"
    elif command -v yum >/dev/null 2>&1; then
        PKG_CMD="yum install -y"
    elif command -v apk >/dev/null 2>&1; then
        PKG_CMD="apk add --no-cache"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_CMD="pacman -Sy --noconfirm --needed"
    else
        PKG_CMD="apt-get install -y"
    fi

    # 检测 Init 系统 (systemd vs openrc)
    if [[ "$RELEASE" == "alpine" ]] || [[ -f /sbin/openrc-run ]] || ! command -v systemctl >/dev/null 2>&1; then
        INIT_SYS="openrc"
    else
        INIT_SYS="systemd"
    fi
}

check_arch() {
    ARCH=$(uname -m)
    local is_musl=false

    # 检测是否为 Musl libc
    if [[ "$RELEASE" == "alpine" ]] || (ldd --version 2>&1 | grep -qi "musl") || ls /lib/ld-musl* >/dev/null 2>&1; then
        is_musl=true
    fi

    case "$ARCH" in
        x86_64|amd64)
            if [ "$is_musl" = true ]; then
                REALM_ARCH="x86_64-unknown-linux-musl"
            else
                REALM_ARCH="x86_64-unknown-linux-gnu"
            fi
            ;;
        aarch64|arm64)
            if [ "$is_musl" = true ]; then
                REALM_ARCH="aarch64-unknown-linux-musl"
            else
                REALM_ARCH="aarch64-unknown-linux-gnu"
            fi
            ;;
        armv7*|armhf)
            REALM_ARCH="armv7-unknown-linux-musleabihf"
            ;;
        i386|i686)
            error "上游 (zhboner/realm) 官方未提供 32 位 x86 预编译二进制，请使用 64 位系统或手动通过 cargo 编译！"
            exit 1
            ;;
        *)
            error "暂不支持的 CPU 架构: $ARCH"
            exit 1
            ;;
    esac
}

install_dependencies() {
    info "正在安装必要的基础依赖..."
    check_sys

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget tar gzip lsof iproute2 iptables >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl wget tar gzip lsof iproute iptables >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget tar gzip lsof iproute iptables >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
        apk update >/dev/null 2>&1 || true
        apk add --no-cache curl wget tar gzip iproute2 bash iptables >/dev/null 2>&1 || true
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm --needed curl wget tar gzip iproute2 iptables >/dev/null 2>&1 || true
    fi

    # 关键依赖可用性自检 (避免静默失败导致后续安装莫名报错)
    local missing_deps=""
    for dep in curl wget tar; do
        command -v "$dep" >/dev/null 2>&1 || missing_deps="${missing_deps} ${dep}"
    done
    if [[ -n "$missing_deps" ]]; then
        error "关键依赖安装失败或不可用:${missing_deps}"
        error "请手动执行安装: ${PKG_CMD} curl wget tar，然后重新运行本脚本"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# 输入清洗与地址校验
# ------------------------------------------------------------------------------

# 清洗落地主机地址 (移除 http://, https://, 误粘的端口与空格换行, 剥离多余方括号)
clean_remote_host() {
    local host="$1"
    host=$(echo "$host" | tr -d "[:space:]\"'\r\n")
    # 移除协议头
    host=${host#http://}
    host=${host#https://}
    # 移除多余的尾部斜杠
    host=${host%%/*}

    # 剥离带端口的情况: [2001:db8::1]:443 或 1.2.3.4:443 或 domain.com:443 或 [domain.com]:443
    if [[ "$host" =~ ^\[(.*)\]:([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
    elif [[ "$host" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):[0-9]+$ ]] || [[ "$host" =~ ^([a-zA-Z0-9.-]+):[0-9]+$ ]]; then
        host="${BASH_REMATCH[1]}"
    fi

    # 清理残留的尾部冒号 (如 3x.hans1.cc.cd:)
    host=${host%:}

    # 如果带有方括号但其实是域名的畸形情况 (如 [3x.hans1.cc.cd] 或 [3x.hans1.cc.cd:])，剥离方括号
    if [[ "$host" =~ ^\[(.*)\]$ ]]; then
        local inner="${BASH_REMATCH[1]}"
        inner=${inner%:}
        if [[ "$inner" =~ \. ]] || [[ ! "$inner" =~ ^[a-fA-F0-9:]+$ ]]; then
            host="$inner"
        fi
    fi

    echo "$host"
}

# 格式化 IP (严格识别合法 IPv6 并补充方括号，绝不误套域名)
format_ip() {
    local ip="$1"
    [[ -z "$ip" ]] && return
    ip=$(echo "$ip" | tr -d '[:space:]')

    # 若已包含方括号且是合法 IPv6，原样返回
    if [[ "$ip" =~ ^\[[a-fA-F0-9:]+\]$ ]]; then
        echo "$ip"
        return
    fi

    # 严密判定：只有包含冒号、纯16进制字符、且不含点号(非域名)才视为 IPv6
    if [[ "$ip" =~ : ]] && [[ "$ip" =~ ^[a-fA-F0-9:]+$ ]] && [[ ! "$ip" =~ \. ]]; then
        echo "[$ip]"
    else
        echo "$ip"
    fi
}

# 精准解析 remote 字符串 (返回 clean host 与 port)
parse_remote_target() {
    local remote="$1"
    local r_host="" r_port=""
    if [[ "$remote" =~ ^\[(.*)\]:([0-9]+)$ ]]; then
        r_host="${BASH_REMATCH[1]}"
        r_port="${BASH_REMATCH[2]}"
    elif [[ "$remote" =~ ^\[(.*)\]$ ]]; then
        r_host="${BASH_REMATCH[1]}"
        r_port=""
    elif [[ "$remote" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+)$ ]] || [[ "$remote" =~ ^([a-zA-Z0-9.-]+):([0-9]+)$ ]]; then
        r_host="${BASH_REMATCH[1]}"
        r_port="${BASH_REMATCH[2]}"
    else
        r_host="$remote"
        r_port=""
    fi
    r_host=$(clean_remote_host "$r_host")
    echo "${r_host}|${r_port}"
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

# 检查系统端口占用
is_port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tuln | awk '{print $5}' | grep -Eq "(:|\])${port}$"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tuln | awk '{print $4}' | grep -Eq "(:|\])${port}$"
    elif command -v lsof >/dev/null 2>&1; then
        lsof -i :"$port" >/dev/null 2>&1
    else
        return 1
    fi
}

# 校验 TOML 语法 (若 Python 可用则通过 tomllib/tomli/toml 预检)
validate_toml() {
    local file="$1"
    local py_code=""
    if python3 -c "import tomllib" >/dev/null 2>&1; then
        py_code="import sys, tomllib; tomllib.load(open(sys.argv[1], 'rb'))"
    elif python3 -c "import tomli" >/dev/null 2>&1; then
        py_code="import sys, tomli; tomli.load(open(sys.argv[1], 'rb'))"
    elif python3 -c "import toml" >/dev/null 2>&1; then
        py_code="import sys, toml; toml.load(sys.argv[1])"
    fi

    if [[ -n "$py_code" ]]; then
        python3 -c "$py_code" "$file" >/dev/null 2>&1
        return $?
    fi
    return 0
}

# ------------------------------------------------------------------------------
# 防火墙联动与生命周期管理
# ------------------------------------------------------------------------------

firewall_allow() {
    local port="$1"
    local proto="${2:-both}"      # tcp / udp / both
    local src_ip="${3:-""}"       # 可选白名单 IP/CIDR

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw "active"; then
        local from_clause=""
        [[ -n "$src_ip" ]] && from_clause="from $src_ip"

        if [[ "$proto" == "tcp" || "$proto" == "both" ]]; then
            # shellcheck disable=SC2086
            ufw allow $from_clause to any port "$port" proto tcp >/dev/null 2>&1 || true
        fi
        if [[ "$proto" == "udp" || "$proto" == "both" ]]; then
            # shellcheck disable=SC2086
            ufw allow $from_clause to any port "$port" proto udp >/dev/null 2>&1 || true
        fi
        info "UFW 防火墙已放行端口: $port ($proto)"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        local def_zone
        def_zone=$(firewall-cmd --get-default-zone 2>/dev/null || echo "public")
        if [[ "$proto" == "tcp" || "$proto" == "both" ]]; then
            firewall-cmd --zone="$def_zone" --add-port="$port"/tcp --permanent >/dev/null 2>&1 || true
        fi
        if [[ "$proto" == "udp" || "$proto" == "both" ]]; then
            firewall-cmd --zone="$def_zone" --add-port="$port"/udp --permanent >/dev/null 2>&1 || true
        fi
        firewall-cmd --reload >/dev/null 2>&1 || true
        info "Firewalld 防火墙已放行端口: $port ($proto)"
    elif command -v iptables >/dev/null 2>&1; then
        local src_opt=""
        [[ -n "$src_ip" ]] && src_opt="-s $src_ip"

        if [[ "$proto" == "tcp" || "$proto" == "both" ]]; then
            # shellcheck disable=SC2086
            iptables -C INPUT $src_opt -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT $src_opt -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
            if command -v ip6tables >/dev/null 2>&1; then
                ip6tables -C INPUT $src_opt -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || ip6tables -I INPUT $src_opt -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
            fi
        fi
        if [[ "$proto" == "udp" || "$proto" == "both" ]]; then
            # shellcheck disable=SC2086
            iptables -C INPUT $src_opt -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT $src_opt -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
            if command -v ip6tables >/dev/null 2>&1; then
                ip6tables -C INPUT $src_opt -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1 || ip6tables -I INPUT $src_opt -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
            fi
        fi
        # 持久化保存
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1 || true
        fi
    fi
}

firewall_deny() {
    local port="$1"
    local proto="${2:-both}"

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw "active"; then
        if [[ "$proto" == "tcp" || "$proto" == "both" ]]; then
            ufw delete allow to any port "$port" proto tcp >/dev/null 2>&1 || true
        fi
        if [[ "$proto" == "udp" || "$proto" == "both" ]]; then
            ufw delete allow to any port "$port" proto udp >/dev/null 2>&1 || true
        fi
        info "UFW 防火墙已撤销放行端口: $port"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        local def_zone
        def_zone=$(firewall-cmd --get-default-zone 2>/dev/null || echo "public")
        if [[ "$proto" == "tcp" || "$proto" == "both" ]]; then
            firewall-cmd --zone="$def_zone" --remove-port="$port"/tcp --permanent >/dev/null 2>&1 || true
        fi
        if [[ "$proto" == "udp" || "$proto" == "both" ]]; then
            firewall-cmd --zone="$def_zone" --remove-port="$port"/udp --permanent >/dev/null 2>&1 || true
        fi
        firewall-cmd --reload >/dev/null 2>&1 || true
        info "Firewalld 防火墙已撤销放行端口: $port"
    elif command -v iptables >/dev/null 2>&1; then
        if [[ "$proto" == "tcp" || "$proto" == "both" ]]; then
            iptables -D INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
            command -v ip6tables >/dev/null 2>&1 && ip6tables -D INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
        fi
        if [[ "$proto" == "udp" || "$proto" == "both" ]]; then
            iptables -D INPUT -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
            command -v ip6tables >/dev/null 2>&1 && ip6tables -D INPUT -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
        fi
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1 || true
        fi
    fi
}

# ------------------------------------------------------------------------------
# 下载校验与安装
# ------------------------------------------------------------------------------

choose_mirror() {
    echo -e "\n${YELLOW}请选择 GitHub 下载加速源:${PLAIN}"
    echo "1. GitHub 官方直连 (默认推荐境外 VPS)"
    echo "2. ghproxy.net 加速代理 (适合中国大陆 VPS)"
    echo "3. mirror.ghproxy.com 加速代理"
    echo "4. 自定义 HTTPS 加速前缀"
    read -rp "请输入选项 [1-4, 默认 1]: " mirror_opt
    case "$mirror_opt" in
        2) GH_MIRROR="https://ghproxy.net/" ;;
        3) GH_MIRROR="https://mirror.ghproxy.com/" ;;
        4)
            read -rp "请输入自定义前缀 (必须以 https:// 开头): " GH_MIRROR
            if [[ "$GH_MIRROR" != https://* ]]; then
                warn "前缀不符合安全规范，已重置为官方直连！"
                GH_MIRROR=""
            fi
            [[ -n "$GH_MIRROR" && "$GH_MIRROR" != */ ]] && GH_MIRROR="${GH_MIRROR}/"
            ;;
        *) GH_MIRROR="" ;;
    esac
}

# 官方 API 获取 Release 资产不可变 SHA-256 Digest
get_verified_digest() {
    local tag="$1"
    local asset_name="realm-${REALM_ARCH}.tar.gz"
    # 直连官方 API 确保信任锚安全
    curl -fsSL --connect-timeout 10 "https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${tag}" 2>/dev/null \
        | awk -v asset="${asset_name}" '
            $0 ~ "\"name\":[[:space:]]*\"" asset "\"" { in_asset=1; next }
            in_asset && $0 ~ /"digest":[[:space:]]*"sha256:[a-f0-9]+"/ {
                sub(/.*"sha256:/, "");
                sub(/".*/, "");
                print $0;
                exit;
            }
            in_asset && $0 ~ /"browser_download_url":/ { in_asset=0 }
        ' || true
}

install_realm() {
    check_root
    check_arch
    install_dependencies
    choose_mirror

    info "正在获取 Realm 最新版本元数据..."
    local latest_version
    latest_version=$(curl -fsSL --connect-timeout 10 "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

    local curr_core_ver=""
    if [[ -f "$BIN_PATH" ]]; then
        curr_core_ver=$("$BIN_PATH" -v 2>/dev/null | awk '{print $2}')
    fi

    local download_url
    if [[ -z "$latest_version" ]]; then
        warn "获取最新版本号失败，将拉取最新稳定资产..."
        error "警告: 无法获取官方版本元数据，本次下载将无法执行 SHA-256 完整性校验！"
        read -rp "是否仍然继续下载安装？[y/N 默认 N]: " no_verify
        if [[ "$no_verify" != [yY] && "$no_verify" != [yY][eE][sS] ]]; then
            info "已取消安装。请检查网络后重试，或更换下载镜像源。"
            return 1
        fi
        download_url="${GH_MIRROR}https://github.com/${GITHUB_REPO}/releases/latest/download/realm-${REALM_ARCH}.tar.gz"
    else
        local clean_latest="${latest_version#v}"
        if [[ -n "$curr_core_ver" && "$curr_core_ver" == "$clean_latest" ]]; then
            success "当前 Realm 核心已是最新版本 (${GREEN}v${curr_core_ver}${PLAIN})，无需更新！"
            read -rp "是否强制重新下载并覆盖安装？[y/N 默认 N]: " force_reinstall
            if [[ "$force_reinstall" != [yY] && "$force_reinstall" != [yY][eE][sS] ]]; then
                return 0
            fi
        else
            info "发现 Realm 核心升级: 当前 [${YELLOW}${curr_core_ver:-未安装}${PLAIN}] ➔ 最新 [${GREEN}${latest_version}${PLAIN}]"
        fi
        download_url="${GH_MIRROR}https://github.com/${GITHUB_REPO}/releases/download/${latest_version}/realm-${REALM_ARCH}.tar.gz"
    fi
    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/realm_inst.XXXXXX)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp_dir'" EXIT

    info "正在下载: $download_url"
    if ! wget --timeout=30 --tries=2 -O "${tmp_dir}/realm.tar.gz" "$download_url"; then
        error "下载 Realm 二进制失败，请检查网络连接或切换镜像源！"
        return 1
    fi

    # 执行 SHA-256 完整性校验
    if [[ -n "$latest_version" ]]; then
        local expected_hash
        expected_hash=$(get_verified_digest "$latest_version")
        if [[ -n "$expected_hash" && "$expected_hash" =~ ^[a-f0-9]{64}$ ]]; then
            local actual_hash
            actual_hash=$(sha256sum "${tmp_dir}/realm.tar.gz" | awk '{print $1}')
            if [[ "$expected_hash" != "$actual_hash" ]]; then
                error "FATAL: SHA-256 校验失败！"
                error "期望值: $expected_hash"
                error "实际值: $actual_hash"
                error "文件可能被篡改或损坏，已强制中止安装！"
                return 1
            fi
            success "SHA-256 完整性校验通过！"
        else
            error "FATAL: 无法从官方 API 获取校验哈希（可能触发 GitHub 限流），为安全起见已中止安装。"
            error "请稍后重试，或更换下载镜像源。"
            return 1
        fi
    fi

    # 解压部署
    tar -xzf "${tmp_dir}/realm.tar.gz" -C "$tmp_dir"
    if [[ ! -f "${tmp_dir}/realm" ]]; then
        error "解压失败，未找到 realm 二进制！"
        return 1
    fi

    # 备份旧二进制
    if [[ -f "$BIN_PATH" ]]; then
        cp -f "$BIN_PATH" "${BIN_PATH}.bak" 2>/dev/null || true
    fi

    # 安装二进制并恢复 SELinux 上下文
    install -m 755 "${tmp_dir}/realm" "$BIN_PATH"
    command -v restorecon >/dev/null 2>&1 && restorecon -v "$BIN_PATH" >/dev/null 2>&1 || true

    # 安装管理脚本为全局快捷指令
    if [[ -f "$0" && "$0" != *"bash"* && "$0" != *"/dev/fd"* ]]; then
        install -m 755 "$0" "$SCRIPT_PATH" 2>/dev/null || true
    else
        curl -fsSL "${GH_MIRROR}${SCRIPT_RAW_URL}" -o "$SCRIPT_PATH" 2>/dev/null || wget -qO "$SCRIPT_PATH" "${GH_MIRROR}${SCRIPT_RAW_URL}" 2>/dev/null || true
        chmod +x "$SCRIPT_PATH" 2>/dev/null || true
    fi
    ln -sf "$SCRIPT_PATH" "$SHORT_SCRIPT_PATH" 2>/dev/null || cp -f "$SCRIPT_PATH" "$SHORT_SCRIPT_PATH" 2>/dev/null || true
    chmod +x "$SHORT_SCRIPT_PATH" 2>/dev/null || true

    # 初始化配置目录与 rules.d 架构
    init_config_structure

    # 配置守护服务
    setup_service

    if restart_service; then
        success "Realm 核心安装完成！"
        echo -e "${GREEN}快捷指令已就绪：在终端输入 ${BOLD}${YELLOW}re${PLAIN}${GREEN} 即可打开管理面板！${PLAIN}\n"
    else
        error "安装完成后服务启动失败，正在回滚..."
        [[ -f "${BIN_PATH}.bak" ]] && mv -f "${BIN_PATH}.bak" "$BIN_PATH"
        return 1
    fi
}

update_script() {
    check_root
    choose_mirror
    info "正在检测 GitHub 远程最新版本..."
    local tmp_script
    tmp_script=$(mktemp /tmp/realm_script.XXXXXX)
    if curl -fsSL --connect-timeout 10 "${GH_MIRROR}${SCRIPT_RAW_URL}?t=$(date +%s)" -o "$tmp_script" 2>/dev/null || wget -q --timeout=10 -O "$tmp_script" "${GH_MIRROR}${SCRIPT_RAW_URL}?t=$(date +%s)" 2>/dev/null; then
        if grep -qE "^[[:space:]]*SCRIPT_VERSION=['\"]?[0-9]+\.[0-9]+\.[0-9]+" "$tmp_script" 2>/dev/null \
            && grep -q "show_menu" "$tmp_script" 2>/dev/null \
            && grep -q "install_realm" "$tmp_script" 2>/dev/null \
            && grep -q "add_rule" "$tmp_script" 2>/dev/null; then
            local remote_ver
            remote_ver=$(grep -m1 '^[[:space:]]*SCRIPT_VERSION=' "$tmp_script" | sed -E 's/^[[:space:]]*SCRIPT_VERSION=["'\''"]?([^"'\''"]+)["'\''"]?.*/\1/')
            if [[ -n "$remote_ver" && "$remote_ver" == "$SCRIPT_VERSION" ]]; then
                success "当前管理脚本已是最新版本 (${GREEN}v${SCRIPT_VERSION}${PLAIN})，无需更新！"
                read -rp "是否强制重新覆盖当前脚本？[y/N 默认 N]: " force_script
                if [[ "$force_script" != [yY] && "$force_script" != [yY][eE][sS] ]]; then
                    rm -f "$tmp_script"
                    return 0
                fi
            else
                info "发现新版本脚本: 当前 [${YELLOW}v${SCRIPT_VERSION}${PLAIN}] ➔ 最新 [${GREEN}v${remote_ver:-未知}${PLAIN}]"
            fi

            install -m 755 "$tmp_script" "$SCRIPT_PATH"
            ln -sf "$SCRIPT_PATH" "$SHORT_SCRIPT_PATH" 2>/dev/null || true
            chmod +x "$SCRIPT_PATH" "$SHORT_SCRIPT_PATH" 2>/dev/null || true
            rm -f "$tmp_script"
            init_config_structure
            setup_service
            success "Realm Pro 管理脚本已成功升级至最新版 (v${remote_ver:-$SCRIPT_VERSION})！"
            echo ""
            read -rp "按回车键立即无缝载入新版控制面板..."
            exec "$SCRIPT_PATH"
        fi
    fi
    rm -f "$tmp_script"
    error "获取最新脚本失败，请检查网络连接或切换镜像源！"
}

init_config_structure() {
    mkdir -p "$CONF_DIR" "$RULES_DIR" "$BACKUP_DIR" "$LOG_DIR"
    chmod 700 "$CONF_DIR" "$BACKUP_DIR"

    # 初始化 00-global.toml 全局配置 (必须在首行声明 endpoints = [] 以满足 Realm 反序列化要求)
    if [[ ! -f "$GLOBAL_CONF" ]]; then
        cat > "$GLOBAL_CONF" <<EOF
endpoints = []

[log]
level = "warn"
output = "stdout"

[network]
no_tcp = false
use_udp = true
tcp_timeout = 5
udp_timeout = 30
tcp_keepalive = 15
tcp_keepalive_probe = 3
EOF
        chmod 600 "$GLOBAL_CONF"
        info "已初始化全局配置文件: $GLOBAL_CONF"
    else
        # 兼容性自愈：如果已有 00-global.toml 缺少 endpoints 字段，自动在首行注入
        if ! grep -q "^endpoints" "$GLOBAL_CONF" 2>/dev/null && ! grep -q "^\[\[endpoints" "$GLOBAL_CONF" 2>/dev/null; then
            sed -i '1i endpoints = []\n' "$GLOBAL_CONF" 2>/dev/null || true
        fi
    fi

    # 自动迁移旧版本 config.toml 单文件
    migrate_legacy_config
}

count_rules() {
    if [[ -d "$RULES_DIR" ]]; then
        find "$RULES_DIR" -maxdepth 1 -name "*.toml" 2>/dev/null | wc -l | tr -d '[:space:]'
    else
        echo "0"
    fi
}

migrate_legacy_config() {
    # 仅在从未迁移过（.migrated 标记不存在）时自动扫描并迁移历史配置
    if [[ ! -f "${CONF_DIR}/.migrated" ]]; then
        mkdir -p "${BACKUP_DIR}" "${RULES_DIR}"

        local candidate_files
        candidate_files=$(find "$CONF_DIR" -maxdepth 2 -type f ! -path "*/rules.d/*" ! -path "*/backup/*" ! -name "*.tar.gz" ! -name "*.bak" ! -name "00-global.toml" ! -name ".migrated" 2>/dev/null || true)

        for src_file in $candidate_files; do
            if grep -q -E "listen[[:space:]]*=" "$src_file" 2>/dev/null; then
                info "检测到历史配置文件: ${src_file}，正在提取规则..."

                # 极度健壮的规则提取器 (支持 [[endpoints]] 与 [[endpoint]]、任意缩进、引号、CRLF、自动纠偏)
                awk -v rdir="$RULES_DIR" '
                    BEGIN { in_ep=0; lport=""; has_proxy=0; pver=2; remark=""; listen_val=""; remote_val="" }
                    /^[[:space:]]*\[\[endpoints?\]\]/ {
                        if (in_ep == 1 && lport != "" && remote_val != "") {
                            fname = rdir "/" lport ".toml";
                            print "[[endpoints]]" > fname;
                            if (remark != "") print remark > fname;
                            print "listen = \"" listen_val "\"" > fname;
                            print "remote = \"" remote_val "\"" > fname;
                            if (has_proxy == 1) {
                                print "network = { send_proxy = true, send_proxy_version = " pver " }" > fname;
                            }
                            close(fname);
                        }
                        in_ep=1; lport=""; has_proxy=0; pver=2; remark=""; listen_val=""; remote_val=""; next
                    }
                    {
                        if (in_ep == 1) {
                            gsub(/\r/, "", $0);
                            if ($0 ~ /^[[:space:]]*#[[:space:]]*remark[[:space:]]*=/) {
                                remark=$0;
                                gsub(/^[[:space:]]+/, "", remark);
                            }
                            if ($0 ~ /^[[:space:]]*listen[[:space:]]*=/) {
                                line=$0;
                                gsub(/^[[:space:]]*listen[[:space:]]*=[[:space:]]*["\047]?/, "", line);
                                gsub(/["\047].*$/, "", line);
                                listen_val=line;
                                split(listen_val, arr, ":");
                                gsub(/[^0-9]/, "", arr[length(arr)]);
                                lport=arr[length(arr)];
                            }
                            if ($0 ~ /^[[:space:]]*remote[[:space:]]*=/) {
                                line=$0;
                                gsub(/^[[:space:]]*remote[[:space:]]*=[[:space:]]*["\047]?/, "", line);
                                gsub(/["\047].*$/, "", line);
                                # 自动纠偏历史可能存在的畸形方括号域名 (如 [domain.com:]:8443 -> domain.com:8443)
                                if (line ~ /^\[.*\]:[0-9]+$/) {
                                    split(line, r_parts, "]:");
                                    inner=r_parts[1];
                                    sub(/^\[/, "", inner);
                                    sub(/:$/, "", inner);
                                    r_port=r_parts[2];
                                    if (inner ~ /\./ || inner ~ /[^a-fA-F0-9:]/) {
                                        line=inner ":" r_port;
                                    }
                                }
                                remote_val=line;
                            }
                            if ($0 ~ /send_proxy[[:space:]]*=[[:space:]]*true/) has_proxy=1;
                            if ($0 ~ /send_proxy_version[[:space:]]*=[[:space:]]*1/) pver=1;
                        }
                    }
                    END {
                        if (in_ep == 1 && lport != "" && remote_val != "") {
                            fname = rdir "/" lport ".toml";
                            print "[[endpoints]]" > fname;
                            if (remark != "") print remark > fname;
                            print "listen = \"" listen_val "\"" > fname;
                            print "remote = \"" remote_val "\"" > fname;
                            if (has_proxy == 1) {
                                print "network = { send_proxy = true, send_proxy_version = " pver " }" > fname;
                            }
                            close(fname);
                        }
                    }
                ' "$src_file"

                # 若是当前 config.toml，则重命名备份避免与 rules.d 冲突
                [[ "$src_file" == "$LEGACY_CONFIG" ]] && mv -f "$LEGACY_CONFIG" "${LEGACY_CONFIG}.bak"
            fi
        done

        touch "${CONF_DIR}/.migrated"
        local new_count
        new_count=$(count_rules)
        if [[ "$new_count" -gt 0 ]]; then
            setup_service
            success "历史配置已成功恢复并无缝迁移！共恢复 ${new_count} 条中转规则！"
        fi
    fi
}

setup_service() {
    check_sys

    if [[ "$INIT_SYS" == "systemd" ]]; then
        # 生产级安全加固 Systemd Unit
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Realm High-Performance Relay Server
Documentation=https://github.com/${GITHUB_REPO}
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${CONF_DIR}
ExecStart=${BIN_PATH} -c ${CONF_DIR}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable realm >/dev/null 2>&1 || true
    else
        # OpenRC (Alpine Linux) 启动脚本 (配置标准与错误日志重定向)
        cat > "$OPENRC_SERVICE" <<'EOF'
#!/sbin/openrc-run
description="Realm High-Performance Relay Server"
command="/usr/local/bin/realm-bin"
command_args="-c /etc/realm"
command_background="yes"
pidfile="/run/realm.pid"
output_log="/var/log/realm/realm.log"
error_log="/var/log/realm/realm.log"

depend() {
    need net
    after firewall
}
EOF
        chmod +x "$OPENRC_SERVICE"
        rc-update add realm default >/dev/null 2>&1 || true
    fi
}

uninstall_realm() {
    check_root
    check_sys
    echo -e "${RED}${BOLD}警告: 即将卸载 Realm 转发服务！${PLAIN}"
    read -rp "是否保留配置文件及规则备份？(Y/n): " keep_conf
    keep_conf=${keep_conf:-y}

    info "正在停止服务并收回防火墙放行端口..."
    # 收集并撤销所有已放行端口
    local ports
    ports=$(get_all_rule_ports)
    for p in $ports; do
        firewall_deny "$p"
    done

    if [[ "$INIT_SYS" == "systemd" ]]; then
        systemctl stop realm >/dev/null 2>&1 || true
        systemctl disable realm >/dev/null 2>&1 || true
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload >/dev/null 2>&1 || true
    else
        rc-service realm stop >/dev/null 2>&1 || true
        rc-update del realm default >/dev/null 2>&1 || true
        rm -f "$OPENRC_SERVICE"
    fi

    rm -f "$BIN_PATH" "${BIN_PATH}.bak"

    if [[ "$keep_conf" =~ ^[Nn]$ ]]; then
        rm -rf "$CONF_DIR" "$LOG_DIR"
        info "已删除配置文件及日志目录。"
    else
        info "配置文件已保留在: $CONF_DIR"
    fi

    read -rp "是否移除快捷命令 're' 和 'realm'？(y/N): " rm_menu
    if [[ "$rm_menu" =~ ^[Yy]$ ]]; then
        rm -f "$SCRIPT_PATH" "$SHORT_SCRIPT_PATH"
        success "快捷命令已移除。"
    fi

    success "Realm 卸载完成！"
}

# ------------------------------------------------------------------------------
# 规则生命周期管理 (基于 rules.d 原子操作)
# ------------------------------------------------------------------------------

# 获取所有规则中的监听端口列表
get_all_rule_ports() {
    if [[ -d "$RULES_DIR" ]]; then
        # shellcheck disable=SC2012
        ls -1 "$RULES_DIR"/*.toml 2>/dev/null | sed -E 's/.*\/([0-9]+)\.toml/\1/' || true
    fi
}

# 解析单条规则 TOML 文件信息
# 输出: port|listen|remote|proxy_status|remark
parse_single_rule_file() {
    local file="$1"
    [[ ! -f "$file" ]] && return

    local port listen remote proxy remark
    listen=$(grep -E "^[[:space:]]*listen *=" "$file" | head -n 1 | sed -E 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*["\047]?([^"\047]+)["\047]?.*/\1/')
    remote=$(grep -E "^[[:space:]]*remote *=" "$file" | head -n 1 | sed -E 's/^[[:space:]]*remote[[:space:]]*=[[:space:]]*["\047]?([^"\047]+)["\047]?.*/\1/')
    remark=$(grep -E "^[[:space:]]*#[[:space:]]*remark *=" "$file" | head -n 1 | sed -E 's/^[[:space:]]*#[[:space:]]*remark[[:space:]]*=[[:space:]]*["\047]?([^"\047]+)["\047]?.*/\1/' || echo "-")
    [[ -z "$remark" ]] && remark="-"

    # PROXY Protocol 检测 (必须嵌套在 network 内部)
    if grep -q "send_proxy *= *true" "$file"; then
        if grep -q "send_proxy_version *= *1" "$file"; then
            proxy="开启(v1)"
        else
            proxy="开启(v2)"
        fi
    else
        proxy="关闭"
    fi

    port=$(echo "$listen" | awk -F':' '{print $NF}' | tr -d '][[:space:]"'\''')
    echo "${port}|${listen}|${remote}|${proxy}|${remark}"
}

# 根据输入的【端口号】或【序号 ID】解析出目标端口
resolve_target_port() {
    local input="$1"
    [[ -z "$input" || "$input" == "0" ]] && return 1

    # 如果直接匹配已有规则端口文件
    if [[ -f "${RULES_DIR}/${input}.toml" ]]; then
        echo "$input"
        return 0
    fi

    # 如果输入的是数字序号 (ID)
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        local rule_files=()
        while IFS= read -r f; do
            [[ -n "$f" ]] && rule_files+=("$f")
        done < <(ls -1 "$RULES_DIR"/*.toml 2>/dev/null || true)

        local idx=$((input - 1))
        if [[ $idx -ge 0 && $idx -lt ${#rule_files[@]} ]]; then
            local target_f="${rule_files[$idx]}"
            local p
            p=$(basename "$target_f" .toml)
            echo "$p"
            return 0
        fi
    fi

    return 1
}

list_rules() {
    echo -e "\n${BOLD}${CYAN}========== 当前 Realm 转发规则列表 ==========${PLAIN}"
    mkdir -p "$RULES_DIR"

    local rule_files
    rule_files=$(ls -1 "$RULES_DIR"/*.toml 2>/dev/null || true)

    if [[ -z "$rule_files" ]]; then
        echo -e "${YELLOW}暂无任何转发规则，请选择 [1] 添加规则。${PLAIN}"
        echo -e "${CYAN}==============================================${PLAIN}\n"
        return
    fi

    printf "%-4s | %-6s | %-20s | %-30s | %-10s | %-15s\n" "ID" "端口" "本地监听 (Listen)" "落地目标 (Remote)" "PROXY协议" "备注"
    echo "-------------------------------------------------------------------------------------------------"

    local count=0
    for rf in $rule_files; do
        count=$((count + 1))
        local rule_info
        rule_info=$(parse_single_rule_file "$rf")
        IFS="|" read -r port listen remote proxy remark <<< "$rule_info"
        printf "%-4s | %-6s | %-20s | %-30s | %-10s | %-15s\n" "$count" "$port" "$listen" "$remote" "$proxy" "$remark"
    done
    echo -e "${CYAN}==============================================${PLAIN}\n"
}

backup_rules() {
    mkdir -p "$BACKUP_DIR"
    local bak_file="${BACKUP_DIR}/realm_rules_$(date +%Y%m%d_%H%M%S).tar.gz"
    tar -czf "$bak_file" -C "$CONF_DIR" rules.d 00-global.toml 2>/dev/null || true
    # 轮转清理：仅保留最近 20 份备份
    # shellcheck disable=SC2012
    ls -1t "${BACKUP_DIR}"/realm_rules_*.tar.gz 2>/dev/null | tail -n +21 | xargs -r rm -f 2>/dev/null || true
}

add_rule() {
    check_root
    init_config_structure

    local l_port="" r_host="" r_port="" proxy_ver="0" remark="-" listen_ip="0.0.0.0"

    # 非交互传参模式解析: re add -l 8080 -r 1.1.1.1:443 -p 2 -m "备注"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -l|--listen) l_port="$2"; shift 2 ;;
            -r|--remote)
                if [[ "$2" =~ ^\[(.*)\]:([0-9]+)$ ]]; then
                    r_host="${BASH_REMATCH[1]}"
                    r_port="${BASH_REMATCH[2]}"
                elif [[ "$2" =~ ^(.*):([0-9]+)$ ]]; then
                    r_host="${BASH_REMATCH[1]}"
                    r_port="${BASH_REMATCH[2]}"
                else
                    r_host="$2"
                    if [[ -n "$3" && "$3" =~ ^[0-9]+$ ]]; then
                        r_port="$3"
                        shift
                    fi
                fi
                r_host=$(clean_remote_host "$r_host")
                r_host=$(format_ip "$r_host")
                shift 2 ;;
            -p|--proxy)  proxy_ver="$2"; shift 2 ;;
            -m|--remark) remark="$2"; shift 2 ;;
            --ip)        listen_ip="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    # 交互式引导模式
    if [[ -z "$l_port" ]]; then
        echo -e "\n${BOLD}${GREEN}=== 添加新的端口转发规则 ===${PLAIN}"

        # 1. 监听端口
        while true; do
            read -rp "请输入中转机(本地)监听端口 [1-65535]: " l_port
            if ! validate_port "$l_port"; then
                error "端口输入不合法，必须是 1 到 65535 之间的数字！"
                continue
            fi
            if [[ -f "${RULES_DIR}/${l_port}.toml" ]]; then
                error "该端口已在规则库中存在，请勿重复添加！"
                continue
            fi
            if is_port_in_use "$l_port"; then
                warn "检测到端口 $l_port 已被系统中其它进程占用，可能导致冲突！"
                read -rp "是否依然强制使用此端口？(y/N): " force_use
                [[ "$force_use" =~ ^[Yy]$ ]] && break
            else
                break
            fi
        done

        # 2. 监听地址类型
        echo -e "\n${YELLOW}请选择本地监听地址类型:${PLAIN}"
        echo "1. 0.0.0.0 (全部 IPv4 流量，默认推荐)"
        echo "2. [::]    (IPv4 + IPv6 双栈全面监听)"
        echo "3. 127.0.0.1 (仅限本机回环/前置代理调用)"
        read -rp "请选择 [1-3, 默认 1]: " ip_opt
        case "$ip_opt" in
            2) listen_ip="[::]" ;;
            3) listen_ip="127.0.0.1" ;;
            *) listen_ip="0.0.0.0" ;;
        esac

        # 3. 落地机目标地址
        while true; do
            read -rp "请输入落地机 IP 或 域名: " r_host
            r_host=$(clean_remote_host "$r_host")
            if [[ -z "$r_host" ]]; then
                error "落地机地址不能为空！"
                continue
            fi
            r_host=$(format_ip "$r_host")
            break
        done

        # 4. 落地机端口
        while true; do
            read -rp "请输入落地机目标端口 [1-65535]: " r_port
            if validate_port "$r_port"; then
                break
            else
                error "端口输入不合法，必须是 1 到 65535 之间的数字！"
            fi
        done

        # 5. PROXY Protocol
        echo -e "\n${YELLOW}是否启用 PROXY Protocol (透传客户端真实 IP)？${PLAIN}"
        echo "1. 不开启 (默认，绝大多数中转场景)"
        echo "2. 开启 PROXY Protocol v2 (推荐对接 Nginx / Xray)"
        echo "3. 开启 PROXY Protocol v1"
        read -rp "请选择 [1-3, 默认 1]: " p_choice
        case "$p_choice" in
            2) proxy_ver="2" ;;
            3) proxy_ver="1" ;;
            *) proxy_ver="0" ;;
        esac

        # 6. 备注
        read -rp "请输入规则备注说明 (可选，回车跳过): " remark
        remark=$(echo "$remark" | tr -d '"|\\\r\n')
        remark=${remark:-"-"}
    fi

    # 校验入参有效性
    if ! validate_port "$l_port" || ! validate_port "$r_port" || [[ -z "$r_host" ]]; then
        error "参数校验失败，无法添加规则！"
        return 1
    fi

    backup_rules
    local target_file="${RULES_DIR}/${l_port}.toml"

    # 写入规范合法的独立规则 TOML 文件
    {
        echo "[[endpoints]]"
        echo "# remark = \"${remark}\""
        echo "listen = \"${listen_ip}:${l_port}\""
        echo "remote = \"${r_host}:${r_port}\""
        if [[ "$proxy_ver" == "2" || "$proxy_ver" == "1" ]]; then
            echo "network = { send_proxy = true, send_proxy_version = ${proxy_ver} }"
        fi
    } > "$target_file"
    chmod 600 "$target_file"

    # 语法预检
    if ! validate_toml "$target_file"; then
        error "TOML 语法校验未通过，正在撤销..."
        rm -f "$target_file"
        return 1
    fi

    # 放行防火墙
    firewall_allow "$l_port"

    # 重启并验证
    if restart_service; then
        success "转发规则 [端口: ${l_port}] 添加成功并已实时生效！"
    else
        error "服务重启失败，正在回滚规则..."
        rm -f "$target_file"
        firewall_deny "$l_port"
        restart_service
        return 1
    fi
}

edit_rule() {
    check_root
    local target_input="$1"
    local rule_files
    rule_files=$(ls -1 "$RULES_DIR"/*.toml 2>/dev/null || true)
    [[ -z "$rule_files" ]] && { info "当前暂无任何转发规则。"; return; }

    if [[ -z "$target_input" ]]; then
        list_rules
        read -rp "请输入要修改的规则【端口号】或【序号ID】(输入 0 取消): " target_input
    fi
    [[ "$target_input" == "0" || -z "$target_input" ]] && return

    local target_port
    if ! target_port=$(resolve_target_port "$target_input"); then
        error "未找到匹配端口或序号为 [$target_input] 的规则！"
        return 1
    fi

    local target_file="${RULES_DIR}/${target_port}.toml"
    if [[ ! -f "$target_file" ]]; then
        error "未找到端口为 $target_port 的规则文件！"
        return 1
    fi

    local rule_info
    rule_info=$(parse_single_rule_file "$target_file")
    IFS="|" read -r port listen remote proxy remark <<< "$rule_info"

    local parse_res
    parse_res=$(parse_remote_target "$remote")
    IFS="|" read -r cur_r_host cur_r_port <<< "$parse_res"

    echo -e "\n${BOLD}${CYAN}正在修改端口 [${target_port}] 的规则 (直接回车保留原值):${PLAIN}"
    read -rp "新的落地目标 IP/域名 [当前: ${cur_r_host}]: " new_r_host
    new_r_host=${new_r_host:-$cur_r_host}
    new_r_host=$(clean_remote_host "$new_r_host")
    new_r_host=$(format_ip "$new_r_host")

    read -rp "新的落地目标端口 [当前: ${cur_r_port}]: " new_r_port
    new_r_port=${new_r_port:-$cur_r_port}
    if ! validate_port "$new_r_port"; then
        error "端口输入不合法，必须是 1 到 65535 之间的数字！"
        return 1
    fi

    read -rp "新的备注说明 [当前: ${remark}]: " new_remark
    new_remark=${new_remark:-$remark}
    new_remark=$(echo "$new_remark" | tr -d '"|\\\r\n')

    backup_rules
    {
        echo "[[endpoints]]"
        echo "# remark = \"${new_remark}\""
        echo "listen = \"${listen}\""
        echo "remote = \"${new_r_host}:${new_r_port}\""
        if [[ "$proxy" =~ 开启 ]]; then
            local pver=2
            [[ "$proxy" =~ v1 ]] && pver=1
            echo "network = { send_proxy = true, send_proxy_version = ${pver} }"
        fi
    } > "$target_file"
    chmod 600 "$target_file"

    if restart_service; then
        success "规则修改成功并已生效！"
    else
        error "修改后启动失败，正在还原..."
        # 还原最近备份
        local latest_bak
        latest_bak=$(ls -1t "${BACKUP_DIR}"/realm_rules_*.tar.gz 2>/dev/null | head -n 1)
        [[ -n "$latest_bak" ]] && tar -xzf "$latest_bak" -C "$CONF_DIR"
        restart_service
    fi
}

delete_rule() {
    check_root
    local target_input="$1"
    local rule_files
    rule_files=$(ls -1 "$RULES_DIR"/*.toml 2>/dev/null || true)
    [[ -z "$rule_files" ]] && { info "当前暂无任何转发规则。"; return; }

    if [[ -z "$target_input" ]]; then
        list_rules
        read -rp "请输入要删除的规则【端口号】或【序号ID】(输入 0 取消): " target_input
    fi
    [[ "$target_input" == "0" || -z "$target_input" ]] && return

    local del_port
    if ! del_port=$(resolve_target_port "$target_input"); then
        error "未找到匹配端口或序号为 [$target_input] 的规则！"
        return 1
    fi

    local target_file="${RULES_DIR}/${del_port}.toml"
    if [[ ! -f "$target_file" ]]; then
        error "未找到端口为 $del_port 的规则文件！"
        return 1
    fi

    backup_rules
    rm -f "$target_file"
    firewall_deny "$del_port"

    if restart_service; then
        success "端口 [${del_port}] 对应规则已成功删除！"
    else
        warn "服务重启提示异常，请使用 re doctor 进行排查。"
    fi
}

edit_raw_config() {
    check_root
    local editor="${EDITOR:-${VISUAL:-nano}}"
    if ! command -v "$editor" >/dev/null 2>&1; then
        editor="vi"
    fi
    info "即将使用 ${editor} 打开全局配置: $GLOBAL_CONF"
    read -rp "按回车键继续..."
    backup_rules
    "$editor" "$GLOBAL_CONF"
    if ! restart_service; then
        error "服务启动失败！改动前的配置已自动备份至: ${BACKUP_DIR}"
        echo -e "  如需还原，请执行: ${BOLD}tar -xzf \$(ls -1t ${BACKUP_DIR}/realm_rules_*.tar.gz | head -n1) -C ${CONF_DIR}${PLAIN}"
        echo -e "  还原后重启服务: ${BOLD}re restart${PLAIN}"
    fi
}

# ------------------------------------------------------------------------------
# 服务控制与健康监测
# ------------------------------------------------------------------------------

restart_service() {
    check_sys
    # 启动前自愈校验：确保 00-global.toml 包含 endpoints = []
    if [[ -f "$GLOBAL_CONF" ]] && ! grep -q "^endpoints" "$GLOBAL_CONF" 2>/dev/null && ! grep -q "^\[\[endpoints" "$GLOBAL_CONF" 2>/dev/null; then
        sed -i '1i endpoints = []\n' "$GLOBAL_CONF" 2>/dev/null || true
    fi
    info "正在重启 Realm 服务..."

    if [[ "$INIT_SYS" == "systemd" ]]; then
        systemctl daemon-reload
        systemctl restart realm >/dev/null 2>&1 || true

        # 3 秒动态轮询健康检查
        for _ in 1 2 3 4 5 6; do
            sleep 0.5
            if systemctl is-active --quiet realm 2>/dev/null; then
                success "Realm 服务运行正常！"
                return 0
            fi
        done

        error "Realm 服务启动失败！以下是最近的错误日志:"
        journalctl -u realm --no-pager -n 15 2>/dev/null || true
        return 1
    else
        rc-service realm restart >/dev/null 2>&1 || true
        sleep 1
        if rc-service realm status 2>/dev/null | grep -qw "started"; then
            success "Realm 服务运行正常！"
            return 0
        else
            error "Realm 服务启动失败！"
            return 1
        fi
    fi
}

view_logs() {
    echo -e "\n${CYAN}========== 实时运行日志 (按 Ctrl+C 退出) ==========${PLAIN}"
    check_sys
    if [[ "$INIT_SYS" == "systemd" ]]; then
        journalctl -u realm -f -n 50
    else
        if [[ -f "$LOG_FILE" ]]; then
            tail -f -n 50 "$LOG_FILE"
        else
            warn "未找到日志文件: $LOG_FILE"
        fi
    fi
}

# ------------------------------------------------------------------------------
# 综合系统与网络体检 (Doctor)
# ------------------------------------------------------------------------------

run_doctor() {
    echo -e "\n${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════╗"
    echo -e "║             Realm Pro 综合系统与链路体检报告              ║"
    echo -e "╚═══════════════════════════════════════════════════════════╝${PLAIN}\n"

    # 1. 核心状态
    echo -e "${BOLD}[1/4] 核心服务与二进制状态${PLAIN}"
    if [[ -f "$BIN_PATH" ]]; then
        local ver
        ver=$("$BIN_PATH" -v 2>/dev/null | awk '{print $2}' || echo "已安装")
        echo -e "  - 二进制程序: ${GREEN}正常${PLAIN} ($BIN_PATH, 版本: $ver)"
    else
        echo -e "  - 二进制程序: ${RED}未安装${PLAIN}"
    fi

    if [[ "$INIT_SYS" == "systemd" ]]; then
        if systemctl is-active --quiet realm 2>/dev/null; then
            echo -e "  - 服务状态: ${GREEN}运行中 (Active)${PLAIN}"
        else
            echo -e "  - 服务状态: ${RED}未运行 (Inactive)${PLAIN}"
        fi
    else
        if rc-service realm status 2>/dev/null | grep -qw "started"; then
            echo -e "  - 服务状态: ${GREEN}运行中 (OpenRC)${PLAIN}"
        else
            echo -e "  - 服务状态: ${RED}未运行${PLAIN}"
        fi
    fi

    # 2. 规则连通性 (异步并发高速体检)
    echo -e "\n${BOLD}[2/4] 转发规则与链路连通性体检${PLAIN}"
    local rule_files
    rule_files=$(ls -1 "$RULES_DIR"/*.toml 2>/dev/null || true)
    if [[ -z "$rule_files" ]]; then
        echo "  - 暂无任何转发规则"
    else
        local tmp_doc_dir
        tmp_doc_dir=$(mktemp -d /tmp/realm_doc.XXXXXX)
        local idx=0

        for rf in $rule_files; do
            idx=$((idx + 1))
            (
                rule_info=$(parse_single_rule_file "$rf")
                IFS="|" read -r port listen remote proxy remark <<< "$rule_info"

                parse_res=$(parse_remote_target "$remote")
                IFS="|" read -r r_host r_port <<< "$parse_res"
                r_host=$(echo "$r_host" | sed 's/\[//;s/\]//')

                # 监听状态检测
                listen_stat="${RED}未监听${PLAIN}"
                if is_port_in_use "$port"; then
                    listen_stat="${GREEN}监听中${PLAIN}"
                fi

                # 落地端 TCP 握手并发探测 (限时 1.5s)
                r_stat="${RED}连接失败${PLAIN}"
                if python3 -c "import sys, socket; s = socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=1.5); s.close()" "$r_host" "$r_port" >/dev/null 2>&1; then
                    r_stat="${GREEN}TCP连通${PLAIN}"
                elif command -v nc >/dev/null 2>&1 && timeout 1.5 nc -w 1 -z "$r_host" "$r_port" >/dev/null 2>&1; then
                    r_stat="${GREEN}TCP连通${PLAIN}"
                elif [[ ! "$r_host" =~ : ]] && timeout 1.5 bash -c "exec 3<>/dev/tcp/${r_host}/${r_port}" >/dev/null 2>&1; then
                    r_stat="${GREEN}TCP连通${PLAIN}"
                elif command -v curl >/dev/null 2>&1; then
                    curl_target="$r_host"
                    [[ "$curl_target" =~ : ]] && curl_target="[${curl_target}]"
                    if curl -s --connect-timeout 1.5 "telnet://${curl_target}:${r_port}" 2>&1 | grep -E -q "Connected"; then
                        r_stat="${GREEN}TCP连通${PLAIN}"
                    fi
                fi

                echo -e "  - 端口 [${BOLD}${YELLOW}${port}${PLAIN}] ➔ ${remote} (${remark})\n    本地: ${listen_stat} | 落地网络: ${r_stat} | PROXY协议: ${proxy}" > "${tmp_doc_dir}/${idx}.res"
            ) &
        done
        wait

        for ((i = 1; i <= idx; i++)); do
            [[ -f "${tmp_doc_dir}/${i}.res" ]] && cat "${tmp_doc_dir}/${i}.res"
        done
        rm -rf "$tmp_doc_dir"
    fi

    # 3. 防火墙状态检测
    echo -e "\n${BOLD}[3/4] 防火墙环境审计${PLAIN}"
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw "active"; then
        echo -e "  - 当前活动防火墙: ${GREEN}UFW (已启用)${PLAIN}"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        echo -e "  - 当前活动防火墙: ${GREEN}Firewalld (已启用)${PLAIN}"
    elif command -v iptables >/dev/null 2>&1; then
        echo -e "  - 当前活动防火墙: ${GREEN}IPTables${PLAIN}"
    else
        echo -e "  - 当前活动防火墙: ${YELLOW}未检测到活跃的防火墙软件 (系统直接放行)${PLAIN}"
    fi

    # 4. 系统句柄与资源限制
    echo -e "\n${BOLD}[4/4] 系统内核与句柄限制${PLAIN}"
    local nofile_limit
    nofile_limit=$(ulimit -n 2>/dev/null || echo "未知")
    echo -e "  - 当前 Shell 最大文件句柄限制: ${GREEN}${nofile_limit}${PLAIN}"
    echo -e "\n${CYAN}============================================================${PLAIN}\n"
}

network_diagnostic() {
    echo -e "\n${BOLD}${CYAN}=== 目标网络连通性诊断 ===${PLAIN}"
    read -rp "请输入待测试的落地机 IP 或 域名: " test_target
    test_target=$(clean_remote_host "$test_target")
    test_target=$(echo "$test_target" | sed 's/\[//;s/\]//')
    read -rp "请输入测试端口 [默认 443]: " test_port
    test_port=${test_port:-443}

    info "正在探测与目标 ${test_target}:${test_port} 的网络连通性..."
    local ok=false
    if python3 -c "import sys, socket; s = socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=3.0); s.close()" "$test_target" "$test_port" >/dev/null 2>&1; then
        ok=true
    elif command -v nc >/dev/null 2>&1; then
        if nc -w 3 -z "$test_target" "$test_port" 2>/dev/null || nc -z -v -w 3 "$test_target" "$test_port" 2>/dev/null; then
            ok=true
        fi
    elif [[ ! "$test_target" =~ : ]] && timeout 3 bash -c "exec 3<>/dev/tcp/${test_target}/${test_port}" >/dev/null 2>&1; then
        ok=true
    elif command -v curl >/dev/null 2>&1; then
        local curl_target="$test_target"
        [[ "$curl_target" =~ : ]] && curl_target="[${curl_target}]"
        if curl -v --connect-timeout 3 "telnet://${curl_target}:${test_port}" 2>&1 | grep -E -q "Connected"; then
            ok=true
        fi
    fi

    if [ "$ok" = true ]; then
        success "恭喜！与目标 ${test_target}:${test_port} 的 TCP 握手成功，网络通畅！"
    else
        error "无法连接目标 ${test_target}:${test_port}，请检查落地端防火墙与端口是否开放！"
    fi
}

# ------------------------------------------------------------------------------
# 状态信息与菜单面板
# ------------------------------------------------------------------------------

get_status_info() {
    check_sys
    if [[ ! -f "$BIN_PATH" ]]; then
        STATUS_TAG="${RED}未安装${PLAIN}"
        VER_TAG="-"
        AUTO_TAG="-"
        RULE_COUNT="0"
        return
    fi

    if [[ "$INIT_SYS" == "systemd" ]]; then
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
    else
        if rc-service realm status 2>/dev/null | grep -qw "started"; then
            STATUS_TAG="${GREEN}运行中${PLAIN}"
        else
            STATUS_TAG="${RED}已停止${PLAIN}"
        fi
        AUTO_TAG="${GREEN}OpenRC${PLAIN}"
    fi

    VER_TAG=$("$BIN_PATH" -v 2>/dev/null | awk '{print $2}')
    VER_TAG="${VER_TAG#v}"
    [[ -z "$VER_TAG" ]] && VER_TAG="未安装"

    RULE_COUNT=$(count_rules)
}

show_menu() {
    while true; do
        clear
        get_status_info
        echo -e "
${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════╗
║         Realm 高性能网络中转管理面板 (Pro 增强版)         ║
╚═══════════════════════════════════════════════════════════╝${PLAIN}
 状态: ${STATUS_TAG} | 自启: ${AUTO_TAG} | 脚本: ${CYAN}v${SCRIPT_VERSION}${PLAIN} | 核心: ${GREEN}v${VER_TAG}${PLAIN} | 规则数: ${YELLOW}${RULE_COUNT}${PLAIN}
-------------------------------------------------------------
 ${GREEN}1.${PLAIN} 添加转发规则 (端口/IPv4/IPv6/PROXY协议)
 ${GREEN}2.${PLAIN} 查看所有转发规则
 ${YELLOW}3.${PLAIN} 修改已有转发规则
 ${RED}4.${PLAIN} 删除指定转发规则
 ${YELLOW}5.${PLAIN} 编辑全局配置文件 (${GLOBAL_CONF})
-------------------------------------------------------------
 ${BLUE}6.${PLAIN} 启动服务
 ${BLUE}7.${PLAIN} 停止服务
 ${BLUE}8.${PLAIN} 重启服务
 ${BLUE}9.${PLAIN} 查看实时运行日志
 ${BLUE}10.${PLAIN} 综合系统与链路体检 (Doctor)
 ${BLUE}11.${PLAIN} 目标网络连通性诊断 (Ping/TCP)
-------------------------------------------------------------
 ${PURPLE}12.${PLAIN} 检查并更新管理脚本 (realm-pro)
 ${PURPLE}13.${PLAIN} 安装 / 更新 Realm 核心到最新版
 ${PURPLE}14.${PLAIN} 卸载 Realm 及相关配置
 ${PLAIN}0.${PLAIN} 退出管理面板
-------------------------------------------------------------"
        read -rp "请输入选项编号 [0-14]: " choice || break
        case "$choice" in
            1) add_rule ;;
            2) list_rules ;;
            3) edit_rule ;;
            4) delete_rule ;;
            5) edit_raw_config ;;
            6)
                check_root
                if [[ "$INIT_SYS" == "systemd" ]]; then
                    systemctl start realm && success "服务已启动！" || error "启动失败！"
                else
                    rc-service realm start && success "服务已启动！" || error "启动失败！"
                fi
                ;;
            7)
                check_root
                if [[ "$INIT_SYS" == "systemd" ]]; then
                    systemctl stop realm && warn "服务已停止！"
                else
                    rc-service realm stop && warn "服务已停止！"
                fi
                ;;
            8) check_root && restart_service ;;
            9) view_logs ;;
            10) run_doctor ;;
            11) network_diagnostic ;;
            12) update_script ;;
            13) install_realm ;;
            14) uninstall_realm ;;
            0) exit 0 ;;
            *)
                error "请输入有效的选项编号！"
                ;;
        esac
        echo ""
        read -rp "按回车键返回主菜单..." || break
    done
}

# ------------------------------------------------------------------------------
# 命令行路由分发入口
# ------------------------------------------------------------------------------

case "$1" in
    install)
        install_realm
        ;;
    uninstall)
        uninstall_realm
        ;;
    update)
        install_realm
        ;;
    update-script|update_script|self-update)
        update_script
        ;;
    start)
        check_root
        check_sys
        if [[ "$INIT_SYS" == "systemd" ]]; then
            systemctl start realm && success "Realm 已启动"
        else
            rc-service realm start && success "Realm 已启动"
        fi
        ;;
    stop)
        check_root
        check_sys
        if [[ "$INIT_SYS" == "systemd" ]]; then
            systemctl stop realm && warn "Realm 已停止"
        else
            rc-service realm stop && warn "Realm 已停止"
        fi
        ;;
    restart)
        check_root
        restart_service
        ;;
    status)
        check_sys
        if [[ "$INIT_SYS" == "systemd" ]]; then
            systemctl status realm
        else
            rc-service realm status
        fi
        ;;
    list|ls)
        list_rules
        ;;
    add)
        shift
        add_rule "$@"
        ;;
    edit)
        shift
        edit_rule "$@"
        ;;
    del|rm)
        shift
        delete_rule "$@"
        ;;
    log|logs)
        view_logs
        ;;
    doctor)
        run_doctor
        ;;
    backup)
        backup_rules
        success "规则已备份至 ${BACKUP_DIR}"
        ;;
    recover|migration)
        check_root
        migrate_legacy_config
        restart_service
        ;;
    version|-v|--version)
        echo "Realm Pro 管理脚本版本: ${SCRIPT_VERSION}"
        if [[ -f "$BIN_PATH" ]]; then
            "$BIN_PATH" -v
        fi
        ;;
    help|-h|--help)
        echo -e "Realm Pro 高性能网络中转管理工具 (${SCRIPT_VERSION})"
        echo "用法: re [命令] [参数]"
        echo ""
        echo "可用命令:"
        echo "  re                打开交互式管理面板"
        echo "  re list / ls      查看当前所有中转规则"
        echo "  re add            添加中转规则 (支持参数: -l <本地端口> -r <落地地址:端口> -p <1|2> -m <备注>)"
        echo "  re edit [端口|ID] 修改已有中转规则"
        echo "  re del [端口|ID]  删除指定中转规则"
        echo "  re doctor         执行综合系统与链路体检"
        echo "  re status         查看 Realm 服务状态"
        echo "  re start          启动服务"
        echo "  re stop           停止服务"
        echo "  re restart        重启服务并重载配置"
        echo "  re log / logs     查看实时运行日志"
        echo "  re update         更新 Realm 核心程序"
        echo "  re update-script  更新管理脚本 (self-update)"
        echo "  re backup         手动备份当前规则库"
        echo "  re uninstall      卸载 Realm 服务"
        echo "  re version / -v   查看版本信息"
        echo "  re help / -h      查看帮助信息"
        ;;
    *)
        show_menu
        ;;
esac
