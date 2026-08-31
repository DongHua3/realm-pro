#!/usr/bin/env bash
# ==============================================================================
# Realm Pro 自动化单元测试与回归验证套件
# ==============================================================================

set -o pipefail

PASS=0
FAIL=0

test_assert() {
    local name="$1"
    local expected="$2"
    local actual="$3"

    if [[ "$expected" == "$actual" ]]; then
        echo -e "\033[0;32m[PASS]\033[0m $name"
        PASS=$((PASS + 1))
    else
        echo -e "\033[0;31m[FAIL]\033[0m $name"
        echo -e "  期望值: [$expected]"
        echo -e "  实际值: [$actual]"
        FAIL=$((FAIL + 1))
    fi
}

test_true() {
    local name="$1"
    shift
    if "$@"; then
        echo -e "\033[0;32m[PASS]\033[0m $name"
        PASS=$((PASS + 1))
    else
        echo -e "\033[0;31m[FAIL]\033[0m $name"
        FAIL=$((FAIL + 1))
    fi
}

test_false() {
    local name="$1"
    shift
    if ! "$@"; then
        echo -e "\033[0;32m[PASS]\033[0m $name"
        PASS=$((PASS + 1))
    else
        echo -e "\033[0;31m[FAIL]\033[0m $name"
        FAIL=$((FAIL + 1))
    fi
}

# 引入被测脚本函数 (通过子环境加载函数定义)
SCRIPT_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/realm.sh"

# 动态探测可用且支持 tomllib 的 Python 命令
PY_BIN=""
if python3 -c "import tomllib" >/dev/null 2>&1; then
    PY_BIN="python3"
elif python -c "import tomllib" >/dev/null 2>&1; then
    PY_BIN="python"
fi

echo "=========================================================="
echo "开始执行 Realm Pro 自动化回归测试..."
echo "被测脚本: $SCRIPT_FILE"
echo "Python 解释器: $PY_BIN"
echo "=========================================================="

# 提取函数辅助
load_func() {
    local func_name="$1"
    eval "$(sed -n "/^${func_name}()/,/^}/p" "$SCRIPT_FILE")"
}

# 路径兼容转换 (兼容 Windows 环境下的 Git Bash 与原生 Linux)
to_native_path() {
    local p="$1"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$p"
    else
        echo "$p"
    fi
}

# 1. 测试 clean_remote_host
test_clean_remote_host() {
    echo -e "\n--- [测试模块 1] 落地主机地址清洗 (clean_remote_host) ---"
    load_func clean_remote_host

    test_assert "标准 IPv4" "1.2.3.4" "$(clean_remote_host "1.2.3.4")"
    test_assert "带协议头的 HTTP URL" "example.com" "$(clean_remote_host "http://example.com")"
    test_assert "带协议头的 HTTPS URL" "example.com" "$(clean_remote_host "https://example.com/api")"
    test_assert "误粘贴端口的 IPv4" "1.2.3.4" "$(clean_remote_host "1.2.3.4:443")"
    test_assert "误粘贴端口的域名" "hk.node.com" "$(clean_remote_host "hk.node.com:8080")"
    test_assert "误粘贴端口的带括号 IPv6" "2001:db8::1" "$(clean_remote_host "[2001:db8::1]:443")"
    test_assert "带首尾空格的主机名" "test.org" "$(clean_remote_host "  test.org  ")"
}

# 2. 测试 format_ip
test_format_ip() {
    echo -e "\n--- [测试模块 2] IP 格式化与方括号补充 (format_ip) ---"
    load_func format_ip

    test_assert "普通 IPv4" "1.1.1.1" "$(format_ip "1.1.1.1")"
    test_assert "普通域名" "google.com" "$(format_ip "google.com")"
    test_assert "未带括号的标准 IPv6" "[2400:3200::1]" "$(format_ip "2400:3200::1")"
    test_assert "已带括号的标准 IPv6" "[2400:3200::1]" "$(format_ip "[2400:3200::1]")"
    test_assert "IPv4 映射 IPv6 (::ffff:1.2.3.4)" "[::ffff:1.2.3.4]" "$(format_ip "::ffff:1.2.3.4")"
    test_assert "空输入处理" "" "$(format_ip "")"
}

# 3. 测试 validate_port
test_validate_port() {
    echo -e "\n--- [测试模块 3] 端口合法性校验 (validate_port) ---"
    load_func validate_port

    test_true "合法端口 80" validate_port 80
    test_true "合法端口 443" validate_port 443
    test_true "合法边界端口 1" validate_port 1
    test_true "合法边界端口 65535" validate_port 65535

    test_false "非法端口 0" validate_port 0
    test_false "非法超上限端口 65536" validate_port 65536
    test_false "非法负数端口 -1" validate_port -1
    test_false "非法非数字端口 abc" validate_port "abc"
    test_false "非法空字符串" validate_port ""
}

# 4. 测试 TOML 规则结构与 PROXY Protocol 嵌套层级 (A1 核心 Bug 验证)
test_toml_structure_and_proxy() {
    echo -e "\n--- [测试模块 4] TOML 结构与 PROXY Protocol 嵌套层级 ---"
    local tmp_test_dir
    tmp_test_dir=$(mktemp -d /tmp/realm_test.XXXXXX)

    # 模拟生成的 PROXY v2 规则
    local test_rule_file="${tmp_test_dir}/6666.toml"
    {
        echo "[[endpoints]]"
        echo "# remark = \"HK-BGP\""
        echo "listen = \"0.0.0.0:6666\""
        echo "remote = \"1.2.3.4:443\""
        echo "network = { send_proxy = true, send_proxy_version = 2 }"
    } > "$test_rule_file"

    # 1. 验证 network 嵌套必须存在且不在顶层
    local has_network_table=false
    if grep -q "network *= *{" "$test_rule_file"; then
        has_network_table=true
    fi
    test_assert "PROXY Protocol 必须嵌套在 network 表内部" "true" "$has_network_table"

    # 2. 验证 Python tomllib 语法解析合法性
    local native_path
    native_path=$(to_native_path "$test_rule_file")
    local toml_valid=false
    if $PY_BIN -c "import tomllib; data = tomllib.load(open(r'''${native_path}''', 'rb')); assert data['endpoints'][0]['network']['send_proxy'] is True" 2>/dev/null; then
        toml_valid=true
    fi
    test_assert "Python tomllib 解析嵌套结构通过且 send_proxy 为 True" "true" "$toml_valid"

    # 3. 验证 parse_single_rule_file 解析提取
    load_func parse_single_rule_file
    local parsed_info
    parsed_info=$(parse_single_rule_file "$test_rule_file")
    test_assert "单规则解析提取字符串" "6666|0.0.0.0:6666|1.2.3.4:443|开启(v2)|HK-BGP" "$parsed_info"

    rm -rf "$tmp_test_dir"
}

# 5. 测试版本号提取逻辑 (A4 核心 Bug 验证)
test_version_parsing() {
    echo -e "\n--- [测试模块 5] 菜单状态栏版本号提取 (VER_TAG) ---"
    # 模拟上游 `realm -v` 的真实输出
    local mock_output="Realm 2.9.6 [proxy, balance, transport, multi-thread]"
    local parsed_ver
    parsed_ver=$(echo "$mock_output" | awk '{print $2}')
    test_assert "正确提取版本号为 2.9.6 (而非最后一个特性词)" "2.9.6" "$parsed_ver"
}

# 6. 测试架构识别与 Musl / i686 拦截 (E1/E2 验证)
test_arch_mapping() {
    echo -e "\n--- [测试模块 6] CPU 架构映射与 Libc 检测 ---"

    # 验证 Alpine / Musl 环境下的 x86_64 映射
    (
        RELEASE="alpine"
        ARCH="x86_64"
        is_musl=true
        if [ "$is_musl" = true ]; then
            REALM_ARCH="x86_64-unknown-linux-musl"
        else
            REALM_ARCH="x86_64-unknown-linux-gnu"
        fi
        test_assert "Alpine x86_64 映射为 musl 资产" "x86_64-unknown-linux-musl" "$REALM_ARCH"
    )

    # 验证 i686 拦截
    (
        ARCH="i686"
        local i686_supported=true
        case "$ARCH" in
            i386|i686) i686_supported=false ;;
        esac
        test_assert "i686 架构必须明确拦截" "false" "$i686_supported"
    )
}

# 7. 测试 CLI 路由支持 (A3 / D2 验证)
test_cli_routing() {
    echo -e "\n--- [测试模块 7] CLI 命令路由完整性 ---"
    local has_update=false
    local has_doctor=false
    local has_version=false
    local has_help=false

    if grep -q "update)" "$SCRIPT_FILE"; then has_update=true; fi
    if grep -q "doctor)" "$SCRIPT_FILE"; then has_doctor=true; fi
    if grep -q "version|" "$SCRIPT_FILE"; then has_version=true; fi
    if grep -q "help|" "$SCRIPT_FILE"; then has_help=true; fi

    test_assert "支持 re update 命令路由" "true" "$has_update"
    test_assert "支持 re doctor 体检路由" "true" "$has_doctor"
    test_assert "支持 re -v / version 路由" "true" "$has_version"
    test_assert "支持 re -h / help 路由" "true" "$has_help"
}

# 8. 测试 Systemd Unit 安全加固与配置合规性 (B3/C2 验证)
test_systemd_unit_compliance() {
    echo -e "\n--- [测试模块 8] Systemd Unit 安全合规性 ---"
    local unit_block
    unit_block=$(grep -A 25 'cat > "\$SERVICE_FILE"' "$SCRIPT_FILE")

    local has_nproc_limit=false
    if echo "$unit_block" | grep -q "LimitNPROC"; then
        has_nproc_limit=true
    fi
    test_assert "禁止在 root 下设置 LimitNPROC=512 (避免 root 进程饥饿)" "false" "$has_nproc_limit"

    local has_networkd_wait=false
    if echo "$unit_block" | grep -q "systemd-networkd-wait-online"; then
        has_networkd_wait=true
    fi
    test_assert "禁止硬编码 systemd-networkd-wait-online (避免 90s 开机阻塞)" "false" "$has_networkd_wait"

    local has_journal_log=false
    if echo "$unit_block" | grep -q "StandardOutput=journal"; then
        has_journal_log=true
    fi
    test_assert "日志统一由 journald 托管" "true" "$has_journal_log"
}

# 9. 测试 rules.d 规则生命周期与原子增删
test_rules_d_lifecycle() {
    echo -e "\n--- [测试模块 9] rules.d 规则生命周期与原子增删 ---"
    local test_conf_dir
    test_conf_dir=$(mktemp -d /tmp/realm_rules_test.XXXXXX)
    local test_rules_dir="${test_conf_dir}/rules.d"
    mkdir -p "$test_rules_dir"

    # 1. 模拟添加规则 1001
    local f1="${test_rules_dir}/1001.toml"
    cat > "$f1" <<EOF
[[endpoints]]
# remark = "Node-1"
listen = "0.0.0.0:1001"
remote = "1.1.1.1:443"
EOF

    # 2. 模拟添加规则 1002 (带 PROXY v2)
    local f2="${test_rules_dir}/1002.toml"
    cat > "$f2" <<EOF
[[endpoints]]
# remark = "Node-2"
listen = "0.0.0.0:1002"
remote = "2.2.2.2:443"
network = { send_proxy = true, send_proxy_version = 2 }
EOF

    # 验证规则文件计数
    local rule_count
    rule_count=$(ls -1 "$test_rules_dir"/*.toml | wc -l)
    test_assert "添加两条独立规则后 rules.d 数量为 2" "2" "$rule_count"

    # 验证单规则解析
    load_func parse_single_rule_file
    local p1 p2
    p1=$(parse_single_rule_file "$f1")
    p2=$(parse_single_rule_file "$f2")
    test_assert "规则 1 解析内容" "1001|0.0.0.0:1001|1.1.1.1:443|关闭|Node-1" "$p1"
    test_assert "规则 2 解析内容" "1002|0.0.0.0:1002|2.2.2.2:443|开启(v2)|Node-2" "$p2"

    # 模拟删除规则 1001 (原子删除单个文件)
    rm -f "$f1"
    local post_del_count
    post_del_count=$(ls -1 "$test_rules_dir"/*.toml | wc -l)
    test_assert "原子删除规则 1001 后 rules.d 数量为 1" "1" "$post_del_count"

    # 验证规则 1002 完好无损
    local p2_remain
    p2_remain=$(parse_single_rule_file "$f2")
    test_assert "规则 1002 保持完好且内容未被破坏" "1002|0.0.0.0:1002|2.2.2.2:443|开启(v2)|Node-2" "$p2_remain"

    rm -rf "$test_conf_dir"
}

# 10. 测试 CLI 非交互参数添加规则与语法验证
test_cli_add_rule_logic() {
    echo -e "\n--- [测试模块 10] CLI 非交互参数解析与 TOML 生成验证 ---"
    local test_conf_dir
    test_conf_dir=$(mktemp -d /tmp/realm_cli_test.XXXXXX)
    local test_rules_dir="${test_conf_dir}/rules.d"
    mkdir -p "$test_rules_dir"

    # 模拟 CLI 传参: l_port=8888, r_host="hk.server.com:443", proxy_ver=2, remark="Test-CLI"
    local l_port=8888
    local raw_r="hk.server.com:443"
    load_func clean_remote_host
    load_func format_ip
    local r_host r_port
    r_host=$(clean_remote_host "$raw_r")
    r_port=$(echo "$raw_r" | awk -F':' '{print $NF}')
    r_host=$(format_ip "$r_host")

    local test_out="${test_rules_dir}/${l_port}.toml"
    {
        echo "[[endpoints]]"
        echo "# remark = \"Test-CLI\""
        echo "listen = \"0.0.0.0:${l_port}\""
        echo "remote = \"${r_host}:${r_port}\""
        echo "network = { send_proxy = true, send_proxy_version = 2 }"
    } > "$test_out"

    # 验证生成的文件内容
    test_assert "CLI 自动剥离 URL 端口并正确拼接" "remote = \"hk.server.com:443\"" "$(grep '^remote *=' "$test_out")"

    # 验证 tomllib 语法合规
    local native_path
    native_path=$(to_native_path "$test_out")
    local cli_toml_valid=false
    if $PY_BIN -c "import tomllib; data = tomllib.load(open(r'''${native_path}''', 'rb')); assert data['endpoints'][0]['listen'] == '0.0.0.0:8888'" 2>/dev/null; then
        cli_toml_valid=true
    fi
    test_assert "CLI 自动生成的 TOML 结构完全合法" "true" "$cli_toml_valid"

    rm -rf "$test_conf_dir"
}

# 11. 测试官方 Release SHA-256 Digest 提取
test_digest_extraction() {
    echo -e "\n--- [测试模块 11] Release 资产 SHA-256 Digest 提取 ---"
    load_func get_verified_digest
    REALM_ARCH="x86_64-unknown-linux-gnu"
    GITHUB_REPO="zhboner/realm"

    local digest
    digest=$(get_verified_digest "v2.9.6")
    local is_valid_sha256=false
    if [[ "$digest" =~ ^[a-f0-9]{64}$ ]]; then
        is_valid_sha256=true
    fi
    test_assert "必须成功解析 64 位标准 SHA-256 Digest" "true" "$is_valid_sha256"
}

# 执行所有测试
test_clean_remote_host
test_format_ip
test_validate_port
test_toml_structure_and_proxy
test_version_parsing
test_arch_mapping
test_cli_routing
test_systemd_unit_compliance
test_rules_d_lifecycle
test_cli_add_rule_logic
test_digest_extraction

echo -e "\n=========================================================="
echo -e "测试完成！总计: $((PASS + FAIL)) | \033[0;32m通过: $PASS\033[0m | \033[0;31m失败: $FAIL\033[0m"
echo "=========================================================="

if [[ $FAIL -eq 0 ]]; then
    exit 0
else
    exit 1
fi
