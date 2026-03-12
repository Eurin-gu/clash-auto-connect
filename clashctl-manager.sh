#!/bin/bash
# clashctl 智能管理脚本 - 带节点延迟检测和自动切换功能
# 适用于 Ubuntu 22.04 系统

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 脚本版本
VERSION="2.0.0"

# Clash API 配置
API_HOST="127.0.0.1"
API_PORT="9090"
API_BASE="http://${API_HOST}:${API_PORT}"
# 注意：如果您的 Clash 配置了 secret，需要在这里设置
# 从外部文件读取密钥
if [ -f ~/.clash_secret ]; then
    source ~/.clash_secret
else
    echo "错误：未找到 ~/.clash_secret 文件，请先创建并写入密钥。"
    exit 1
fi
# 测试延迟的 URL（使用标准的 generate_204 测试地址 [citation:1][citation:3]）
TEST_URL="http://www.gstatic.com/generate_204"
TIMEOUT=5000  # 毫秒

# 打印带颜色的信息
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_debug() { echo -e "${CYAN}[DEBUG]${NC} $1"; }

# 检查 curl 和 jq 是否安装
check_dependencies() {
    if ! command -v curl &> /dev/null; then
        print_error "未找到 curl 命令，请安装: sudo apt install curl -y"
        return 1
    fi
    if ! command -v jq &> /dev/null; then
        print_warning "未找到 jq 命令，将使用 grep/sed 解析 (建议安装 jq 以获得更好体验)"
        print_info "安装 jq: sudo apt install jq -y"
        JQ_AVAILABLE=false
    else
        JQ_AVAILABLE=true
    fi
    return 0
}

# 检查 clashctl 是否可用
check_clashctl() {
    if command -v clashctl &> /dev/null; then
        print_success "找到 clashctl 命令"
        return 0
    else
        print_error "未找到 clashctl 命令"
        print_info "请确保 clashctl 已正确安装并在 PATH 中"
        return 1
    fi
}

# 检查 Clash API 是否可用
check_api() {
    local api_status
    local curl_cmd="curl -s -o /dev/null -w \"%{http_code}\" --connect-timeout 2"
    if [ -n "$CLASH_SECRET" ]; then
        curl_cmd="${curl_cmd} -H \"Authorization: Bearer ${CLASH_SECRET}\""
    fi
    curl_cmd="${curl_cmd} \"${API_BASE}/version\""
    api_status=$(eval $curl_cmd 2>/dev/null)
    if [ "$api_status" = "200" ]; then
        print_success "Clash API 可用 (${API_BASE})"
        return 0
    else
        print_error "Clash API 不可用 (HTTP $api_status)，请检查 secret 是否正确"
        return 1
    fi
}

# 带认证的 curl 请求
api_curl() {
    local method=$1
    local endpoint=$2
    local data=$3
    
    local curl_cmd="curl -s -X ${method}"
    if [ -n "$CLASH_SECRET" ]; then
        curl_cmd="${curl_cmd} -H \"Authorization: Bearer ${CLASH_SECRET}\""
    fi
    curl_cmd="${curl_cmd} -H \"Content-Type: application/json\""
    if [ -n "$data" ]; then
        curl_cmd="${curl_cmd} -d '${data}'"
    fi
    curl_cmd="${curl_cmd} ${API_BASE}${endpoint}"
    
    eval $curl_cmd
}

# 获取所有代理组和节点
# 获取所有 Selector 类型的代理组（策略组）
get_proxies() {
    # 所有输出到 stderr 避免污染返回值
    echo >&2 "[INFO] 获取代理节点列表..."
    
    local response
    response=$(api_curl "GET" "/proxies")
    
    if [ -z "$response" ]; then
        echo >&2 "[ERROR] 获取节点列表失败：API 无响应"
        return 1
    fi
    
    # 使用 jq 提取所有 type 为 Selector 的组名
    if command -v jq &> /dev/null; then
        local groups=$(echo "$response" | jq -r '.proxies | to_entries[] | select(.value.type == "Selector") | .key' 2>/dev/null)
        if [ -n "$groups" ]; then
            echo "$groups"
            return 0
        fi
    fi
    
    # 降级方案：尝试常见的组名（如果没有 jq）
    echo >&2 "[WARNING] 未找到 jq，使用降级方案"
    for group in "节点选择" "GLOBAL" "Proxy" "🚀 节点选择" "🎯 全球直连"; do
        if echo "$response" | grep -q "\"${group}\""; then
            echo "$group"
            return 0
        fi
    done
    
    echo >&2 "[ERROR] 无法找到代理组，API 返回："
    echo >&2 "$response" | head -20
    return 1
}
# 获取指定组内的节点列表
# 获取指定组内的节点列表
get_nodes_in_group() {
    local group=$1
    # 对组名进行 URL 编码（简单处理空格和特殊字符）
    local group_encoded=$(echo -n "$group" | sed 's/ /%20/g; s/🔰/%F0%9F%94%B0/g; s/：/%EF%BC%9A/g; s/-/%2D/g')
    
    echo >&2 "[INFO] 获取组 [${group}] 的节点列表..."
    
    local response
    response=$(api_curl "GET" "/proxies/${group_encoded}")
    
    if [ -z "$response" ]; then
        echo >&2 "[ERROR] 获取节点列表失败：API 无响应"
        return 1
    fi
    
    # 使用 jq 提取 all 数组
    if command -v jq &> /dev/null; then
        local nodes=$(echo "$response" | jq -r '.all[]?' 2>/dev/null)
        if [ -n "$nodes" ]; then
            echo "$nodes"
            return 0
        fi
    fi
    
    # 降级方案：手动提取（可能不稳定）
    local nodes=$(echo "$response" | grep -o '"all":\[[^]]*\]' | sed 's/"all":\[//g' | sed 's/\]//g' | sed 's/,/ /g' | sed 's/"//g')
    if [ -n "$nodes" ]; then
        echo "$nodes"
        return 0
    fi
    
    echo >&2 "[ERROR] 无法解析节点列表，API 返回："
    echo >&2 "$response" | head -10
    return 1
}

# 测试单个节点的延迟
test_node_delay() {
    local node=$1
    local node_encoded=$(echo -n "$node" | sed 's/ /%20/g; s/&/%26/g; s/?/%3F/g; s/:/%3A/g; s/\//%2F/g; s/#/%23/g; s/\[/%5B/g; s/\]/%5D/g; s/@/%40/g; s/!/%21/g; s/\$/%24/g; s/'\''/%27/g; s/(/%28/g; s/)/%29/g; s/\*/%2A/g; s/+/%2B/g; s/,/%2C/g; s/;/%3B/g; s/=/%3D/g')
    
    # 使用延迟测试 API [citation:1][citation:3]
    local url="${API_BASE}/proxies/${node_encoded}/delay?timeout=${TIMEOUT}&url=${TEST_URL}"
    
    local curl_cmd="curl -s -w '%{http_code}' -X GET"
    if [ -n "$CLASH_SECRET" ]; then
        curl_cmd="${curl_cmd} -H \"Authorization: Bearer ${CLASH_SECRET}\""
    fi
    curl_cmd="${curl_cmd} '${url}'"
    
    local response
    response=$(eval $curl_cmd 2>/dev/null)
    
    # 提取状态码（最后3位）
    local http_code=${response: -3}
    local body=${response%???}
    
    if [ "$http_code" = "200" ] && [ -n "$body" ]; then
        if [ "$JQ_AVAILABLE" = true ]; then
            echo "$body" | jq -r '.delay'
        else
            echo "$body" | grep -o '"delay":[0-9]*' | sed 's/"delay"://g'
        fi
    else
        echo "timeout"
    fi
}

# 批量测试节点延迟（带并发和进度条）
test_nodes_batch() {
    local nodes=($@)
    local total=${#nodes[@]}
    local results=()
    local pids=()
    local temp_dir=$(mktemp -d)
    
    print_info "开始批量测试节点延迟 (共 ${total} 个节点, 超时 ${TIMEOUT}ms)..."
    echo
    
    # 并发测试，每次最多5个并发
    for i in "${!nodes[@]}"; do
        local node="${nodes[$i]}"
        local temp_file="${temp_dir}/result_${i}"
        
        # 后台执行测试
        (
            delay=$(test_node_delay "$node")
            echo "$delay" > "$temp_file"
        ) &
        pids[$i]=$!
        
        # 控制并发数：每启动5个就等待一批
        if [ $(( (i+1) % 5 )) -eq 0 ] || [ $((i+1)) -eq $total ]; then
            # 等待这一批完成
            for j in "${!pids[@]}"; do
                if [ -n "${pids[$j]}" ]; then
                    wait ${pids[$j]} 2>/dev/null
                fi
            done
            pids=()
        fi
        
        # 显示进度
        printf "\r${CYAN}进度: %d/%d${NC}" $((i+1)) $total
    done
    echo -e "\n"
    
    # 收集结果
    for i in "${!nodes[@]}"; do
        local temp_file="${temp_dir}/result_${i}"
        if [ -f "$temp_file" ]; then
            delay=$(cat "$temp_file")
            results[$i]="$delay"
        else
            results[$i]="timeout"
        fi
    done
    
    # 清理临时文件
    rm -rf "$temp_dir"
    
    # 输出结果表格
    echo "========== 节点延迟测试结果 =========="
    printf "%-4s %-40s %-10s\n" "编号" "节点名称" "延迟(ms)"
    echo "----------------------------------------"
    
    local available_nodes=()
    local available_delays=()
    
    for i in "${!nodes[@]}"; do
        local node="${nodes[$i]}"
        local delay="${results[$i]}"
        local display_name=$(echo -n "$node" | cut -c 1-38)
        
        if [ "$delay" = "timeout" ]; then
            printf "%-4d %-40s ${RED}%-10s${NC}\n" $((i+1)) "$display_name" "超时"
        elif [ "$delay" -lt 100 ]; then
            printf "%-4d %-40s ${GREEN}%-10s${NC}\n" $((i+1)) "$display_name" "${delay}ms"
        elif [ "$delay" -lt 300 ]; then
            printf "%-4d %-40s ${YELLOW}%-10s${NC}\n" $((i+1)) "$display_name" "${delay}ms"
        else
            printf "%-4d %-40s ${CYAN}%-10s${NC}\n" $((i+1)) "$display_name" "${delay}ms"
        fi
        
        if [ "$delay" != "timeout" ]; then
            available_nodes+=("$node")
            available_delays+=("$delay")
        fi
    done
    echo "========================================"
    
    # 返回可用节点和延迟
    AVAILABLE_NODES=("${available_nodes[@]}")
    AVAILABLE_DELAYS=("${available_delays[@]}")
}

# 切换节点到指定组
switch_node() {
    local group=$1
    local node=$2
    local group_encoded=$(echo -n "$group" | sed 's/ /%20/g; s/🔰/%F0%9F%94%B0/g')
    
    print_info "切换组 [${group}] 到节点 [${node}]..."
    
    local data="{\"name\":\"${node}\"}"
    local response
    response=$(api_curl "PUT" "/proxies/${group_encoded}" "$data")
    
    if [ -z "$response" ] || [ "$response" = "{}" ]; then
        print_success "节点已切换到: ${node}"
        return 0
    else
        print_error "切换失败: $response"
        return 1
    fi
}

# 自动选择最快节点
auto_select_fastest() {
    local group=$1
    
    print_info "正在为组 [${group}] 自动选择最快节点..."
    
    # 获取节点列表
    local nodes=($(get_nodes_in_group "$group"))
    if [ ${#nodes[@]} -eq 0 ]; then
        print_error "未找到节点"
        return 1
    fi
    
    # 批量测试延迟
    test_nodes_batch "${nodes[@]}"
    
    if [ ${#AVAILABLE_NODES[@]} -eq 0 ]; then
        print_error "没有可用节点（全部超时）"
        return 1
    fi
    
    # 找出延迟最低的节点
    local min_delay=${AVAILABLE_DELAYS[0]}
    local best_node=${AVAILABLE_NODES[0]}
    local best_index=0
    
    for i in "${!AVAILABLE_DELAYS[@]}"; do
        if [ "${AVAILABLE_DELAYS[$i]}" -lt "$min_delay" ]; then
            min_delay="${AVAILABLE_DELAYS[$i]}"
            best_node="${AVAILABLE_NODES[$i]}"
            best_index=$i
        fi
    done
    
    print_success "最快节点: ${best_node} (延迟: ${min_delay}ms)"
    
    # 询问是否切换
    read -p "是否切换到该节点? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        switch_node "$group" "$best_node"
    else
        print_info "取消切换"
    fi
}

# 交互式选择节点
interactive_select() {
    local group=$1
    
    # 获取节点列表
    local nodes=($(get_nodes_in_group "$group"))
    if [ ${#nodes[@]} -eq 0 ]; then
        print_error "未找到节点"
        return 1
    fi
    
    echo "========== [${group}] 节点列表 =========="
    for i in "${!nodes[@]}"; do
        echo "$((i+1)). ${nodes[$i]}"
    done
    echo "0. 返回上级菜单"
    echo "========================================"
    
    read -p "请选择节点编号: " choice
    
    if [ "$choice" = "0" ]; then
        return 0
    fi
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#nodes[@]} ]; then
        local selected="${nodes[$((choice-1))]}"
        switch_node "$group" "$selected"
    else
        print_error "无效选择"
    fi
}

# 检查 Clash 服务状态
check_status() {
    print_info "检查 Clash 服务状态..."
    clashctl status
}

# 启动 Clash 服务
start_clash() {
    print_info "正在启动 Clash 服务..."
    
    if clashctl status | grep -q "running"; then
        print_success "Clash 服务已在运行"
        return 0
    fi
    
    if clashctl start; then
        print_success "Clash 服务启动成功"
        sleep 3  # 等待 API 就绪
        return 0
    else
        print_error "Clash 服务启动失败"
        return 1
    fi
}

# 停止 Clash 服务
stop_clash() {
    print_info "正在停止 Clash 服务..."
    if clashctl stop; then
        print_success "Clash 服务已停止"
        # 同时取消代理环境变量
        unset_proxy
        return 0
    else
        print_error "Clash 服务停止失败"
        return 1
    fi
}

# 重启 Clash 服务
restart_clash() {
    print_info "正在重启 Clash 服务..."
    if clashctl restart; then
        print_success "Clash 服务重启成功"
        sleep 3
        return 0
    else
        print_error "Clash 服务重启失败"
        return 1
    fi
}

# 更新订阅配置
update_subscription() {
    print_info "正在更新订阅配置..."
    if clashctl update; then
        print_success "订阅配置更新成功"
        return 0
    else
        print_error "订阅配置更新失败"
        return 1
    fi
}

# 设置代理环境变量
set_proxy_env() {
    local port=${1:-7890}
    
    print_info "设置代理环境变量 (端口: $port)..."
    
    export http_proxy="http://127.0.0.1:$port"
    export https_proxy="http://127.0.0.1:$port"
    export all_proxy="socks5://127.0.0.1:$port"
    export HTTP_PROXY="http://127.0.0.1:$port"
    export HTTPS_PROXY="http://127.0.0.1:$port"
    export ALL_PROXY="socks5://127.0.0.1:$port"
    
    print_success "代理环境变量已设置"
    
    # 可选：添加到 ~/.bashrc 以实现持久化
    if [ "$2" == "--persist" ]; then
        cat >> ~/.bashrc << EOF

# Clash 代理设置 (自动添加)
export http_proxy="http://127.0.0.1:$port"
export https_proxy="http://127.0.0.1:$port"
export all_proxy="socks5://127.0.0.1:$port"
export HTTP_PROXY="http://127.0.0.1:$port"
export HTTPS_PROXY="http://127.0.0.1:$port"
export ALL_PROXY="socks5://127.0.0.1:$port"
EOF
        print_success "代理设置已添加到 ~/.bashrc"
    fi
}

# 取消代理环境变量
unset_proxy() {
    print_info "取消代理环境变量..."
    
    unset http_proxy https_proxy all_proxy
    unset HTTP_PROXY HTTPS_PROXY ALL_PROXY
    
    print_success "代理环境变量已取消"
}

# 测试代理是否工作
test_proxy() {
    print_info "测试代理连接..."
    
    # 测试 http
    if curl -s -o /dev/null -w "%{http_code}" --max-time 5 --proxy http://127.0.0.1:7890 https://www.google.com | grep -q "200"; then
        print_success "代理工作正常 (可访问 Google)"
    else
        print_warning "代理可能有问题 (无法访问 Google)"
    fi
    
    # 测试 ip
    local ip=$(curl -s --max-time 5 --proxy http://127.0.0.1:7890 https://api.ipify.org)
    if [ -n "$ip" ]; then
        print_info "当前出口 IP: $ip"
    fi
}

# 完全自动连接（无人值守版）
auto_connect() {
    print_info "执行完全自动连接（无人值守模式）..."
    
    check_clashctl || return 1
    check_dependencies || return 1
    
    # 1. 启动服务
    start_clash || return 1
    
    # 2. 检查 API
    if ! check_api; then
        print_error "Clash API 未就绪"
        return 1
    fi
    
    # 3. 获取第一个代理组并自动切换到最快节点
    # 3. 获取代理组，优先选择 "节点选择" 组，否则用第一个
    local groups=($(get_proxies))
    if [ ${#groups[@]} -eq 0 ]; then
        print_warning "未找到代理组，跳过节点选择"
    else
        # 优先选择 "节点选择" 组（如果存在）
        local group="节点选择"
        if [[ " ${groups[@]} " =~ " ${group} " ]]; then
            print_info "使用指定的策略组: ${group}"
        else
            group="${groups[0]}"
            print_info "使用第一个可用策略组: ${group}"
        fi
        
        print_info "正在为组 [${group}] 自动选择最快节点..."
        
        # 获取节点列表
        local nodes=($(get_nodes_in_group "$group"))
        if [ ${#nodes[@]} -eq 0 ]; then
            print_warning "组内没有节点"
        else
            # 测试延迟
            test_nodes_batch "${nodes[@]}"
            
            if [ ${#AVAILABLE_NODES[@]} -eq 0 ]; then
                print_warning "没有可用节点"
            else
                # 找出延迟最低的节点
                local min_delay=${AVAILABLE_DELAYS[0]}
                local best_node=${AVAILABLE_NODES[0]}
                for i in "${!AVAILABLE_DELAYS[@]}"; do
                    if [ "${AVAILABLE_DELAYS[$i]}" -lt "$min_delay" ]; then
                        min_delay="${AVAILABLE_DELAYS[$i]}"
                        best_node="${AVAILABLE_NODES[$i]}"
                    fi
                done
                print_success "最快节点: ${best_node} (延迟: ${min_delay}ms)"
                
                # 自动切换（无需确认）
                switch_node "$group" "$best_node"
            fi
        fi
    fi
    
    # 4. 更新订阅（可选，如果你希望每次开机都更新订阅可以保留）
    # update_subscription
    
    # 5. 设置代理环境变量
    set_proxy_env 7890
    
    # 6. 测试连接
    test_proxy
    
    print_success "自动连接流程完成！"
}

# 显示菜单
show_menu() {
    echo "=========================================="
    echo "   clashctl 智能管理脚本 v$VERSION"
    echo "=========================================="
    echo "1) 启动 Clash 服务"
    echo "2) 停止 Clash 服务"
    echo "3) 重启 Clash 服务"
    echo "4) 查看服务状态"
    echo "5) 更新订阅配置"
    echo "------------------------------------------"
    echo "6) 查看代理组"
    echo "7) 手动选择节点"
    echo "8) 测试节点延迟"
    echo "9) 自动选择最快节点"
    echo "------------------------------------------"
    echo "10) 设置代理环境变量"
    echo "11) 取消代理环境变量"
    echo "12) 测试代理连接"
    echo "------------------------------------------"
    echo "13) 完全自动连接 (启动+最快节点+代理)"
    echo "0) 退出"
    echo "=========================================="
}

# 主函数
main() {
    # 检查基础依赖
    check_dependencies || exit 1
    
    # 如果没有参数，显示交互菜单
    if [ $# -eq 0 ]; then
        while true; do
            # 检查 clashctl 和 API
            check_clashctl > /dev/null 2>&1
            CLASHCTL_OK=$?
            check_api > /dev/null 2>&1
            API_OK=$?
            
            clear
            echo "=========================================="
            echo "   系统状态"
            echo "=========================================="
            if [ $CLASHCTL_OK -eq 0 ]; then
                echo -e "clashctl: ${GREEN}✓ 可用${NC}"
            else
                echo -e "clashctl: ${RED}✗ 未找到${NC}"
            fi
            if [ $API_OK -eq 0 ]; then
                echo -e "Clash API: ${GREEN}✓ 连接正常${NC}"
            else
                echo -e "Clash API: ${RED}✗ 未连接${NC}"
            fi
            show_menu
            
            read -p "请选择操作 [0-13]: " choice
            
            case $choice in
                1) start_clash ;;
                2) stop_clash ;;
                3) restart_clash ;;
                4) check_status ;;
                5) update_subscription ;;
                6) 
                    groups=($(get_proxies))
                    if [ ${#groups[@]} -gt 0 ]; then
                        echo "找到代理组:"
                        for g in "${groups[@]}"; do
                            echo "  - $g"
                        done
                    else
                        print_warning "未找到代理组"
                    fi
                    ;;
                7)
                    groups=($(get_proxies))
                    if [ ${#groups[@]} -eq 0 ]; then
                        print_error "未找到代理组"
                    else
                        echo "选择要操作的代理组:"
                        for i in "${!groups[@]}"; do
                            echo "$((i+1)). ${groups[$i]}"
                        done
                        read -p "请选择组编号: " g_choice
                        if [[ "$g_choice" =~ ^[0-9]+$ ]] && [ "$g_choice" -ge 1 ] && [ "$g_choice" -le ${#groups[@]} ]; then
                            interactive_select "${groups[$((g_choice-1))]}"
                        fi
                    fi
                    ;;
                8)
                    groups=($(get_proxies))
                    if [ ${#groups[@]} -eq 0 ]; then
                        print_error "未找到代理组"
                    else
                        echo "选择要测试的代理组:"
                        for i in "${!groups[@]}"; do
                            echo "$((i+1)). ${groups[$i]}"
                        done
                        read -p "请选择组编号: " g_choice
                        if [[ "$g_choice" =~ ^[0-9]+$ ]] && [ "$g_choice" -ge 1 ] && [ "$g_choice" -le ${#groups[@]} ]; then
                            nodes=($(get_nodes_in_group "${groups[$((g_choice-1))]}"))
                            if [ ${#nodes[@]} -gt 0 ]; then
                                test_nodes_batch "${nodes[@]}"
                            fi
                        fi
                    fi
                    ;;
                9)
                    groups=($(get_proxies))
                    if [ ${#groups[@]} -eq 0 ]; then
                        print_error "未找到代理组"
                    else
                        echo "选择要优化的代理组:"
                        for i in "${!groups[@]}"; do
                            echo "$((i+1)). ${groups[$i]}"
                        done
                        read -p "请选择组编号: " g_choice
                        if [[ "$g_choice" =~ ^[0-9]+$ ]] && [ "$g_choice" -ge 1 ] && [ "$g_choice" -le ${#groups[@]} ]; then
                            auto_select_fastest "${groups[$((g_choice-1))]}"
                        fi
                    fi
                    ;;
                10)
                    read -p "请输入代理端口 [默认: 7890]: " port
                    port=${port:-7890}
                    read -p "是否永久保存到 ~/.bashrc? (y/n): " persist
                    if [[ "$persist" =~ ^[Yy]$ ]]; then
                        set_proxy_env "$port" "--persist"
                    else
                        set_proxy_env "$port"
                    fi
                    ;;
                11) unset_proxy ;;
                12) test_proxy ;;
                13) auto_connect ;;
                0) 
                    print_info "再见！"
                    exit 0
                    ;;
                *) 
                    print_error "无效选择"
                    ;;
            esac
            
            echo
            read -p "按回车键继续..."
        done
    else
        # 命令行模式
        case "$1" in
            start) start_clash ;;
            stop) stop_clash ;;
            restart) restart_clash ;;
            status) check_status ;;
            update) update_subscription ;;
            proxy) set_proxy_env "${2:-7890}" "${3}" ;;
            noproxy) unset_proxy ;;
            test) test_proxy ;;
            auto) auto_connect ;;
            list)
                groups=($(get_proxies))
                if [ ${#groups[@]} -gt 0 ]; then
                    echo "代理组:"
                    for g in "${groups[@]}"; do
                        echo "  - $g"
                    done
                fi
                ;;
            nodes)
                if [ -n "$2" ]; then
                    nodes=($(get_nodes_in_group "$2"))
                    if [ ${#nodes[@]} -gt 0 ]; then
                        echo "节点列表 [$2]:"
                        for n in "${nodes[@]}"; do
                            echo "  - $n"
                        done
                    fi
                fi
                ;;
            speedtest)
                if [ -n "$2" ] && [ -n "$3" ]; then
                    # speedtest group1 node1
                    delay=$(test_node_delay "$3")
                    echo "节点 [$3] 延迟: $delay"
                elif [ -n "$2" ]; then
                    # speedtest group1
                    nodes=($(get_nodes_in_group "$2"))
                    if [ ${#nodes[@]} -gt 0 ]; then
                        test_nodes_batch "${nodes[@]}"
                    fi
                fi
                ;;
            switch)
                if [ -n "$2" ] && [ -n "$3" ]; then
                    switch_node "$2" "$3"
                fi
                ;;
            fastest)
                if [ -n "$2" ]; then
                    auto_select_fastest "$2"
                fi
                ;;
            help)
                echo "用法: $0 {start|stop|restart|status|update|proxy|noproxy|test|auto|list|nodes|speedtest|switch|fastest}"
                echo ""
                echo "  list                           - 列出所有代理组"
                echo "  nodes <组名>                   - 列出指定组的节点"
                echo "  speedtest <组名> [节点名]       - 测试节点延迟"
                echo "  switch <组名> <节点名>          - 切换到指定节点"
                echo "  fastest <组名>                 - 自动切换到最快节点"
                ;;
            *)
                print_error "未知命令: $1"
                echo "用法: $0 {start|stop|restart|status|update|proxy|noproxy|test|auto|list|nodes|speedtest|switch|fastest}"
                exit 1
                ;;
        esac
    fi
}

# 运行主函数，传递所有命令行参数
main "$@"
