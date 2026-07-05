#!/usr/bin/env bash
# ========================================
# DST 服务器管理工具箱 v2.3 - 阿里云优化版
# Don't Starve Together Server Toolbox
# ========================================
# 重构优化：自动路径检测、集群管理、一键初始化、阿里云适配
# 兼容性优化：支持旧版 bash、精简系统
# 交互优化：方向键选择、ESC返回、集群配置编辑
# v2.3 重构：输出隔离、信号管理、后台进程统一清理
# ========================================

# 严格模式（兼容旧版 bash）
set -u
set -o pipefail 2>/dev/null || true

# 兼容性：确保用 bash 运行
if [ -z "${BASH_VERSION:-}" ]; then
    echo "错误: 请使用 bash 运行此脚本"
    echo "用法: bash $0"
    exit 1
fi

# ========================================
# 配置区 - 可根据实际情况修改
# ========================================

# 服务端安装目录（自动检测，可手动覆盖）
SERVER_DIR="/root/dontstarvetogether_dedicated_server"

# 默认集群名
CLUSTER_NAME="${CLUSTER_NAME:-Cluster_1}"

# Klei 配置根目录
KLEI_ROOT="${KLEI_ROOT:-/root/.klei/DoNotStarveTogether}"

# 备份目录
BACKUP_DIR="${BACKUP_DIR:-/root/.klei/DoNotStarveTogether/backups}"

# 持久记录上次集群文件
LAST_CLUSTER_FILE="/root/.dst_last_cluster"

# 模组导入目录
MOD_IMPORT_DIR="${MOD_IMPORT_DIR:-/root/dst-mods-import}"

# 集群导入目录
CLUSTER_IMPORT_DIR="${CLUSTER_IMPORT_DIR:-/root/dst-cluster-import}"

# Steam App ID
export SteamAppId=322330
export SteamGameId=322330

# Screen 会话名
SCREEN_MASTER_SESSION="dst-master"
SCREEN_CAVES_SESSION="dst-caves"

# 服务器端口（默认）
MASTER_PORT=10999
CAVES_PORT=10998

# ========================================
# 颜色配置
# ========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[1;30m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

# ========================================
# 全局变量（运行时自动填充）
# ========================================
SERVER_DIR=""
SERVER_BIN_DIR=""
DEDICATED_SERVER_BINARY=""
MODS_DIR=""
MOD_SETUP_FILE=""
CLUSTER_DIR=""
MOD_OVERRIDE_MASTER=""
MOD_OVERRIDE_CAVES=""
MASTER_SERVER_LOG=""
CAVES_SERVER_LOG=""
CAVES_SERVER_INI=""

# 启动检测专用临时日志（与 server_log.txt 分离，避免历史误判）
MASTER_TMP_LOG=""
CAVES_TMP_LOG=""

# 后台进程 PID 列表
_BG_PIDS=()

# ========================================
# 辅助函数
# ========================================

# 统一静默执行：所有 screen/pkill/kill 等命令统一调用
run_silent() {
    "$@" >/dev/null 2>&1
}

# 统一清理后台任务（tail 进程、jobs、wait）
cleanup_background() {
    # 杀掉所有记录的后台 PID
    local pid
    for pid in "${_BG_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    _BG_PIDS=()

    # 杀掉当前 shell 的所有后台子进程（tail 等）
    local child
    for child in $(jobs -p 2>/dev/null); do
        kill "$child" 2>/dev/null || true
    done

    # 等待后台任务结束
    wait 2>/dev/null || true
}

# 统一返回菜单：清理 + 清屏 + 返回
return_menu() {
    cleanup_background
    clear
    trap - INT
    return
}

print_banner() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   ${WHITE}${BOLD}DST 服务器管理工具箱 v2.3${NC}${CYAN}          ║${NC}"
    echo -e "${CYAN}║   ${GRAY}${BOLD}     By Funtt${NC}${CYAN}                      ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo ""
}

print_section() {
    echo -e "${CYAN}━━━ ${WHITE}${BOLD}$1${NC}${CYAN} ━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_hint() {
    echo -e "${GRAY}  $1${NC}"
}

pause() {
    local msg="${1:-按 Enter 继续...}"
    echo ""
    read -rp "$msg"
}

confirm() {
    local msg="$1"
    read -rp "$msg (y/N) " -n 1 REPLY
    echo ""
    echo "$REPLY" | grep -qi '^y'
}

# 交互式选择菜单（支持上下方向键 + ESC返回）
# 用法: select_menu "标题" "选项1" "选项2" "选项3" ...
# 返回: 选中的索引（从0开始），通过 SELECTED_INDEX 变量获取
#        ESC 返回时 SELECTED_INDEX=-1
select_menu() {
    local title="$1"
    shift
    local options=("$@")
    local count=${#options[@]}

    if [ "$count" -eq 0 ]; then
        return 1
    fi

    local selected=0
    local key

    echo -e "${WHITE}$title${NC}"
    echo ""

    # 保存光标位置
    echo -e "\033[s"

    while true; do
        # 恢复光标位置并清除后面内容
        echo -e "\033[u\033[J"

        # 绘制选项
        local i=0
        for opt in "${options[@]}"; do
            if [ "$i" -eq "$selected" ]; then
                echo -e "  ${GREEN}▶${NC} ${CYAN}${BOLD}$opt${NC}"
            else
                echo -e "  ${GRAY}○${NC} $opt"
            fi
            i=$((i + 1))
        done

        echo ""
        echo -e "${GRAY}  ↑↓ 选择  Enter 确认  Esc 返回${NC}"

        # 读取按键
        read -rsn1 key

        # 处理 ESC 开头的序列
        if [ "$key" = $'\x1b' ]; then
            # 尝试读取第二个字符（超时判断是单独ESC还是方向键）
            read -rsn2 -t 0.01 key2 || true
            if [ -z "$key2" ]; then
                # 单独的 ESC 键 → 返回
                SELECTED_INDEX=-1
                echo ""
                return 0
            fi
            # 方向键等组合键
            case "$key2" in
                '[A')  # 上键
                    selected=$((selected - 1))
                    [ "$selected" -lt 0 ] && selected=$((count - 1))
                    ;;
                '[B')  # 下键
                    selected=$((selected + 1))
                    [ "$selected" -ge "$count" ] && selected=0
                    ;;
            esac
        elif [ "$key" = "" ]; then
            # 回车键确认
            SELECTED_INDEX=$selected
            echo ""
            return 0
        fi
    done
}

# 检测服务端安装路径
detect_server_dir() {
    # 优先级1：用户手动指定的 SERVER_DIR
    if [ -n "${SERVER_DIR:-}" ] && [ -d "$SERVER_DIR" ]; then
        return 0
    fi

    # 优先级2：常见的 steamcmd 安装路径
    local candidates=(
        "/root/dontstarvetogether_dedicated_server"
        "/root/Steam/steamapps/common/Don't Starve Together Dedicated Server"
        "/home/steam/Steam/steamapps/common/Don't Starve Together Dedicated Server"
        "/opt/dontstarvetogether_dedicated_server"
    )

    for candidate in "${candidates[@]}"; do
        if [ -d "$candidate" ]; then
            SERVER_DIR="$candidate"
            return 0
        fi
    done

    return 1
}

# 检测二进制文件路径
detect_binary() {
    # 常见的二进制位置
    local bin_candidates=(
        "$SERVER_DIR/bin64/dontstarve_dedicated_server_nullrenderer_x64"
        "$SERVER_DIR/bin/dontstarve_dedicated_server_nullrenderer"
        "$SERVER_DIR/bin64/dontstarve_dedicated_server_nullrenderer"
        "$SERVER_DIR/linux64/dontstarve_dedicated_server_nullrenderer"
    )

    for candidate in "${bin_candidates[@]}"; do
        if [ -x "$candidate" ]; then
            DEDICATED_SERVER_BINARY="$candidate"
            SERVER_BIN_DIR="$(dirname "$candidate")"
            return 0
        fi
    done

    return 1
}

# 初始化路径变量
init_paths() {
    CLUSTER_DIR="$KLEI_ROOT/$CLUSTER_NAME"
    MODS_DIR="$SERVER_DIR/mods"
    MOD_SETUP_FILE="$MODS_DIR/dedicated_server_mods_setup.lua"
    MOD_OVERRIDE_MASTER="$CLUSTER_DIR/Master/modoverrides.lua"
    MOD_OVERRIDE_CAVES="$CLUSTER_DIR/Caves/modoverrides.lua"
    MASTER_SERVER_LOG="$CLUSTER_DIR/Master/server_log.txt"
    CAVES_SERVER_LOG="$CLUSTER_DIR/Caves/server_log.txt"
    CAVES_SERVER_INI="$CLUSTER_DIR/Caves/server.ini"
    MASTER_TMP_LOG="$CLUSTER_DIR/Master/master_start_tmp.log"
    CAVES_TMP_LOG="$CLUSTER_DIR/Caves/caves_start_tmp.log"
}

# 保存当前集群到持久文件
save_current_cluster() {
    echo "$CLUSTER_NAME" > "$LAST_CLUSTER_FILE"
}

# 统一切换当前集群（唯一入口）
# 所有修改当前集群状态的地方必须调用此函数
set_current_cluster() {
    local new_cluster="$1"
    CLUSTER_NAME="$new_cluster"
    save_current_cluster
    init_paths
}

# 自动检测并切换到一个合法集群（兜底）
auto_detect_cluster() {
    # 重新读取持久文件
    if [ -f "$LAST_CLUSTER_FILE" ]; then
        local saved
        saved=$(cat "$LAST_CLUSTER_FILE" 2>/dev/null | tr -d '\n\r' || true)
        if [ -n "$saved" ] && [ -d "$KLEI_ROOT/$saved" ]; then
            set_current_cluster "$saved"
            return 0
        fi
    fi
    # 扫描第一个合法集群
    if [ -d "$KLEI_ROOT" ]; then
        local cluster
        for cluster in "$KLEI_ROOT"/*/; do
            [ -d "$cluster" ] || continue
            local name
            name=$(basename "$cluster")
            [ "$name" = "backups" ] && continue
            [ -f "$cluster/cluster.ini" ] || continue
            set_current_cluster "$name"
            return 0
        done
    fi
    return 1
}

# 加载上次集群
load_last_cluster() {
    CLUSTER_NAME="Cluster_1"
    if [ -f "$LAST_CLUSTER_FILE" ]; then
        local saved
        saved=$(cat "$LAST_CLUSTER_FILE" 2>/dev/null | tr -d '\n\r' || true)
        if [ -n "$saved" ] && [ -d "$KLEI_ROOT/$saved" ]; then
            CLUSTER_NAME="$saved"
        fi
    fi
    save_current_cluster
}

# 检查依赖
check_dependencies() {
    local missing=()

    for cmd in screen tar gzip; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        print_warn "缺少依赖: ${missing[*]}"
        print_info "请先运行菜单中的 [一键初始化服务器] 安装依赖"
        return 1
    fi

    return 0
}

# 检查服务端是否安装
check_server_installed() {
    if [ -z "$SERVER_DIR" ] || [ ! -d "$SERVER_DIR" ]; then
        print_error "未找到 DST 服务端安装目录"
        print_info "请先运行菜单中的 [一键初始化服务器] 下载服务端"
        return 1
    fi

    if [ -z "$DEDICATED_SERVER_BINARY" ] || [ ! -x "$DEDICATED_SERVER_BINARY" ]; then
        print_error "未找到可执行的服务端二进制文件"
        return 1
    fi

    return 0
}

# 检查集群是否存在（自动检测兜底）
check_cluster_exists() {
    if [ -d "$CLUSTER_DIR" ]; then
        return 0
    fi
    # 当前集群目录不存在，尝试自动恢复
    print_warn "当前集群目录不存在: $CLUSTER_NAME，正在自动检测..."
    if auto_detect_cluster; then
        print_success "已自动切换到集群: $CLUSTER_NAME"
        return 0
    fi
    print_error "未找到任何可用集群"
    print_info "请先创建或导入集群"
    return 1
}

# 服务器是否在运行
server_is_running() {
    pgrep -f "dontstarve_dedicated_server_nullrenderer" >/dev/null 2>&1
}

# 兼容获取文件修改时间
get_file_mtime() {
    local file="$1"
    if stat -c "%y" "$file" >/dev/null 2>&1; then
        stat -c "%y" "$file" | cut -d' ' -f1,2
    elif stat -f "%Sm" "$file" >/dev/null 2>&1; then
        stat -f "%Sm" "$file"
    else
        ls -l "$file" | awk '{print $6, $7, $8}'
    fi
}

# 兼容获取文件大小（字节）
get_file_size() {
    local file="$1"
    if stat -c "%s" "$file" >/dev/null 2>&1; then
        stat -c "%s" "$file"
    elif stat -f "%z" "$file" >/dev/null 2>&1; then
        stat -f "%z" "$file"
    else
        wc -c < "$file"
    fi
}

# 获取进程数
server_process_count() {
    local count
    count=$(pgrep -f "dontstarve_dedicated_server_nullrenderer" 2>/dev/null | wc -l)
    echo "$count"
}

# 列出所有集群
list_clusters() {
    if [ ! -d "$KLEI_ROOT" ]; then
        print_warn "配置目录不存在: $KLEI_ROOT"
        return 1
    fi

    local count=0
    for cluster in "$KLEI_ROOT"/*/; do
        [ -d "$cluster" ] || continue
        local name
        name=$(basename "$cluster")
        [ "$name" = "backups" ] && continue

        count=$((count + 1))
        if [ "$name" = "$CLUSTER_NAME" ]; then
            echo -e "  ${GREEN}●${NC} $name ${GRAY}(当前)${NC}"
        else
            echo -e "  ${GRAY}○${NC} $name"
        fi
    done

    if [ "$count" -eq 0 ]; then
        print_warn "暂无集群，请先创建或导入集群"
    fi

    return 0
}

# ========================================
# 模组仓库辅助函数
# ========================================

# 从仓库目录名提取纯数字 Workshop ID
# 输入: "294123456_几何布局" → 输出: "294123456"
get_repo_mod_id() {
    local dirname="$1"
    echo "$dirname" | grep -oE '^[0-9]+' || true
}

# 从仓库目录名提取备注名（下划线后部分）
# 输入: "294123456_几何布局" → 输出: "几何布局"
# 输入: "294123456" → 输出: ""
get_repo_mod_name() {
    local dirname="$1"
    local id_part
    id_part=$(get_repo_mod_id "$dirname")
    if [ -n "$id_part" ] && [ "$dirname" != "$id_part" ]; then
        echo "$dirname" | sed "s/^${id_part}_//"
    fi
}

# 检查模组目录完整性（至少包含 modinfo.lua + modmain.lua）
# 返回: 0=完整, 1=缺少 modinfo.lua, 2=缺少 modmain.lua
check_mod_complete() {
    local mod_dir="$1"
    if [ ! -f "$mod_dir/modinfo.lua" ]; then
        return 1
    fi
    if [ ! -f "$mod_dir/modmain.lua" ]; then
        return 2
    fi
    return 0
}

# 解析 modoverrides.lua，输出 "ID:enabled" 格式
# 例如: 347654321:1\n298765432:0
parse_modoverrides() {
    local file="$1"
    if [ ! -f "$file" ]; then
        return
    fi
    grep -oE '\["workshop-[0-9+"\]' "$file" 2>/dev/null | while read -r match; do
        local id
        id=$(echo "$match" | grep -oE '[0-9]+')
        # 检查该 ID 是否 enabled=true
        local block
        block=$(sed -n '/\["workshop-'"$id"'"/,/\},\|^\}/p' "$file" 2>/dev/null)
        if echo "$block" | grep -q 'enabled.*=.*true'; then
            echo "${id}:1"
        else
            echo "${id}:0"
        fi
    done
}

# 确保 modoverrides.lua 存在且格式正确
ensure_modoverrides() {
    local file="$1"
    if [ ! -f "$file" ]; then
        mkdir -p "$(dirname "$file")"
        echo 'return {' > "$file"
        echo '}' >> "$file"
    fi
}

# 从仓库目录名获取显示名（带备注或标记未命名）
get_repo_display_name() {
    local dirname="$1"
    local name
    name=$(get_repo_mod_name "$dirname")
    if [ -n "$name" ]; then
        echo "$name"
    else
        echo "(未命名)"
    fi
}

# ========================================
# Lua 配置文件解析（最小修改原则）
# ========================================

# 修改前自动备份
backup_modoverrides() {
    local file="$1"
    if [ -f "$file" ]; then
        cp -f "$file" "${file}.bak" 2>/dev/null || true
    fi
}

# 从 modoverrides.lua 提取指定 workshop 的完整节点块
# 输出：整个 ["workshop-xxx"]={ ... }, 块
extract_workshop_block() {
    local file="$1"
    local id="$2"
    if [ ! -f "$file" ]; then
        return 1
    fi
    # 使用 awk 匹配节点开始，计数花括号直到结束
    awk -v target="\"workshop-$id\"" '
    BEGIN { in_block=0; brace=0 }
    {
        if (!in_block && index($0, "[" target "]") > 0 && index($0, "{") > 0) {
            in_block=1
            # 计算本行的花括号
            line=$0
            gsub(/[^{]/, "", line); brace+=length(line)
            line=$0
            gsub(/[^}]/, "", line); brace-=length(line)
            print
            if (brace <= 0) { in_block=0 }
            next
        }
        if (in_block) {
            line=$0
            gsub(/[^{]/, "", line); brace+=length(line)
            line=$0
            gsub(/[^}]/, "", line); brace-=length(line)
            print
            if (brace <= 0) { in_block=0 }
        }
    }
    ' "$file"
}

# 获取指定模组的 enabled 状态
# 输出: true/false/空
get_mod_enabled() {
    local file="$1"
    local id="$2"
    local block
    block=$(extract_workshop_block "$file" "$id")
    if [ -z "$block" ]; then
        return 1
    fi
    echo "$block" | grep -oE 'enabled\s*=\s*(true|false)' | head -1 | grep -oE '(true|false)$'
}

# 获取指定模组的 configuration_options 块（原始文本）
get_mod_config() {
    local file="$1"
    local id="$2"
    local block
    block=$(extract_workshop_block "$file" "$id")
    if [ -z "$block" ]; then
        return 1
    fi
    # 提取 configuration_options={...} 部分
    echo "$block" | awk '
    /configuration_options/ { found=1 }
    found {
        print
        # 找到匹配的 } 后退出
        line=$0
        gsub(/[^{]/, "", line); brace+=length(line)
        line=$0
        gsub(/[^}]/, "", line); brace-=length(line)
        if (brace <= 0 && found > 1) { exit }
        if (found) found++
    }
    '
}

# 获取 configuration_options 中的 key=value 对列表
# 输出格式: key=value 每行一个
get_mod_config_kv() {
    local file="$1"
    local id="$2"
    local config
    config=$(get_mod_config "$file" "$id")
    if [ -z "$config" ]; then
        return
    fi
    # 提取 key=value 对（在 configuration_options 块内）
    echo "$config" | grep -oE '[a-zA-Z_][a-zA-Z0-9_]*\s*=\s*[^,}]+' | sed 's/\s//g'
}

# 精确修改 modoverrides.lua 中的 enabled 字段
set_mod_enabled() {
    local file="$1"
    local id="$2"
    local new_value="$3"  # true 或 false
    if [ ! -f "$file" ]; then
        return 1
    fi
    # 在 workshop 节点块内精确替换 enabled 值
    # 使用 awk 逐行处理，仅在目标节点块内替换
    awk -v target="\"workshop-$id\"" -v newval="$new_value" '
    BEGIN { in_block=0; brace=0 }
    {
        if (!in_block && index($0, "[" target "]") > 0 && index($0, "{") > 0) {
            in_block=1
            line=$0
            gsub(/[^{]/, "", line); brace+=length(line)
            line=$0
            gsub(/[^}]/, "", line); brace-=length(line)
            # 替换 enabled
            gsub(/enabled\s*=\s*(true|false)/, "enabled = " newval)
            print
            if (brace <= 0) in_block=0
            next
        }
        if (in_block) {
            line=$0
            gsub(/[^{]/, "", line); brace+=length(line)
            line=$0
            gsub(/[^}]/, "", line); brace-=length(line)
            gsub(/enabled\s*=\s*(true|false)/, "enabled = " newval)
            if (brace <= 0) in_block=0
        }
        print
    }
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# 精确修改 configuration_options 中的单个参数值
set_mod_config_value() {
    local file="$1"
    local id="$2"
    local key="$3"
    local new_value="$4"
    if [ ! -f "$file" ]; then
        return 1
    fi
    awk -v target="\"workshop-$id\"" -v key="$key" -v newval="$new_value" '
    BEGIN { in_block=0; brace=0; in_config=0; config_brace=0 }
    {
        if (!in_block && index($0, "[" target "]") > 0 && index($0, "{") > 0) {
            in_block=1
            line=$0
            gsub(/[^{]/, "", line); brace+=length(line)
            line=$0
            gsub(/[^}]/, "", line); brace-=length(line)
            if (index($0, "configuration_options") > 0 && index($0, "{") > 0) {
                in_config=1
                line=$0
                gsub(/[^{]/, "", line); config_brace+=length(line)
                line=$0
                gsub(/[^}]/, "", line); config_brace-=length(line)
            }
            # 替换参数值
            if (in_config) {
                sub(key "\\s*=\\s*[^,}]+", key " = " newval)
            }
            print
            if (brace <= 0) { in_block=0; in_config=0 }
            next
        }
        if (in_block) {
            line=$0
            gsub(/[^{]/, "", line); brace+=length(line)
            line=$0
            gsub(/[^}]/, "", line); brace-=length(line)
            if (!in_config && index($0, "configuration_options") > 0 && index($0, "{") > 0) {
                in_config=1
            }
            if (in_config) {
                cfgline=$0
                gsub(/[^{]/, "", cfgline); config_brace+=length(cfgline)
                cfgline=$0
                gsub(/[^}]/, "", cfgline); config_brace-=length(cfgline)
                sub(key "\\s*=\\s*[^,}]+", key " = " newval)
                if (config_brace <= 0 && in_config) in_config=0
            }
            if (brace <= 0) { in_block=0; in_config=0 }
        }
        print
    }
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# 在 modoverrides.lua 中添加新模组节点（在 return { 之后插入）
add_mod_node() {
    local file="$1"
    local id="$2"
    if [ ! -f "$file" ]; then
        return 1
    fi
    # 检查是否已存在
    if grep -q "\"workshop-$id\"" "$file" 2>/dev/null; then
        return 2  # 已存在
    fi
    awk -v mid="$id" '
        /^return *\{/ {
            print "return {"
            print "    [\"workshop-" mid "\"]={"
            print "        configuration_options={},"
            print "        enabled=true"
            print "    },"
            next
        }
        { print }
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# 从 modoverrides.lua 中删除指定 workshop 的完整节点块
remove_mod_node() {
    local file="$1"
    local id="$2"
    if [ ! -f "$file" ]; then
        return 1
    fi
    awk -v target="\"workshop-$id\"" '
    BEGIN { in_block=0; brace=0; skip_next_comma=0 }
    {
        if (!in_block && index($0, "[" target "]") > 0 && index($0, "{") > 0) {
            in_block=1
            line=$0
            gsub(/[^{]/, "", line); brace+=length(line)
            line=$0
            gsub(/[^}]/, "", line); brace-=length(line)
            if (brace <= 0) { in_block=0; skip_next_comma=1 }
            next
        }
        if (in_block) {
            line=$0
            gsub(/[^{]/, "", line); brace+=length(line)
            line=$0
            gsub(/[^}]/, "", line); brace-=length(line)
            if (brace <= 0) { in_block=0; skip_next_comma=1 }
            next
        }
        # 跳过节点块后面可能的逗号行
        if (skip_next_comma) {
            skip_next_comma=0
            if ($0 ~ /^[[:space:]]*,?[[:space:]]*$/) next
        }
        print
    }
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# 简单 Lua 语法检查（检查花括号/括号匹配）
validate_lua() {
    local file="$1"
    if [ ! -f "$file" ]; then
        return 1
    fi
    # 检查花括号匹配
    local open close
    open=$(grep -o '{' "$file" | wc -l)
    close=$(grep -o '}' "$file" | wc -l)
    if [ "$open" -ne "$close" ]; then
        return 1
    fi
    # 检查是否以 return { 开头
    if ! head -5 "$file" | grep -q 'return.*{'; then
        return 1
    fi
    return 0
}

# ========================================
# 服务器进程管理（统一抽象层）
# ========================================

# 获取 screen 会话中 DST 进程的 PID
get_screen_pid() {
    local session="$1"
    local pid
    pid=$(screen -ls 2>/dev/null | grep "$session" | grep -oE '[0-9]+' | head -1)
    echo "$pid"
}

# 获取 screen 会话状态（Detached/Attached）
get_screen_state() {
    local session="$1"
    local raw
    raw=$(screen -ls 2>/dev/null | grep "$session")
    if [ -z "$raw" ]; then
        echo "不存在"
        return
    fi
    # 精确提取括号内的状态词（Detached/Attached）
    local state
    state=$(echo "$raw" | grep -oE '\((Detached|Attached)\)' | tr -d '()')
    if [ -n "$state" ]; then
        echo "$state"
    else
        echo "未知"
    fi
}

# 获取进程运行时间
get_process_uptime() {
    local pid="$1"
    if [ -z "$pid" ] || [ ! -d "/proc/$pid" ]; then
        echo "-"
        return
    fi
    local start_time
    start_time=$(stat -c "%Y" "/proc/$pid" 2>/dev/null || stat -f "%m" "/proc/$pid" 2>/dev/null || echo 0)
    local now
    now=$(date +%s)
    local elapsed=$((now - start_time))
    local hours=$((elapsed / 3600))
    local mins=$(((elapsed % 3600) / 60))
    if [ "$hours" -gt 0 ]; then
        echo "${hours}h${mins}m"
    else
        echo "${mins}m"
    fi
}

# 获取进程资源占用（CPU% 和内存）
get_process_resource() {
    local pid="$1"
    if [ -z "$pid" ] || [ ! -d "/proc/$pid" ]; then
        echo "- -"
        return
    fi
    local cpu mem
    cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')
    mem=$(ps -p "$pid" -o rss= 2>/dev/null | tr -d ' ')
    cpu="${cpu:-0}"
    mem="${mem:-0}"
    local mem_mb=$((mem / 1024))
    echo "${cpu}% ${mem_mb}MB"
}

# ========================================
# 服务器状态三层模型（Screen / Process / Log）
# ========================================

# 第一层：Screen 会话状态
# 返回: 0=存在(Detached/Attached), 1=不存在
check_screen_layer() {
    local session="$1"
    if screen -ls 2>/dev/null | grep -q "$session"; then
        return 0
    fi
    return 1
}

# 第二层：进程状态（通过 screen 子进程查找 DST）
# 返回: 0=DST 进程存在, 1=DST 进程不存在
check_process_layer() {
    local session="$1"
    # 方法1: 通过 screen PID 查找子进程
    local screen_pid
    screen_pid=$(get_screen_pid "$session")
    if [ -n "$screen_pid" ]; then
        # screen 的子进程中查找 dontstarve
        if ps --ppid "$screen_pid" 2>/dev/null | grep -q ""; then
            # screen 有子进程，检查是否是 DST
            local child_pid
            child_pid=$(ps --ppid "$screen_pid" -o pid= 2>/dev/null | head -1)
            if [ -n "$child_pid" ]; then
                # 检查子进程或其子进程是否是 dontstarve
                if ps --ppid "$child_pid" -o comm= 2>/dev/null | grep -q "dontstarve"; then
                    return 0
                fi
                # 直接检查 comm
                if ps -p "$child_pid" -o comm= 2>/dev/null | grep -q "dontstarve"; then
                    return 0
                fi
            fi
        fi
    fi
    # 方法2: 通过进程树查找所有 dontstarve 进程
    if pgrep -f "dontstarve_dedicated_server_nullrenderer" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# 第三层：日志层（真正判断启动完成）
# 从日志读取 "Sim paused"，这是 DST 启动完成的标志
# 返回: 0=启动完成(Sim paused), 1=未完成
# 第三层：日志层（临时日志优先，空则回退 server_log）
check_log_layer() {
    local shard="$1"
    local tmp_log log_file
    case "$shard" in
        Master) tmp_log="$MASTER_TMP_LOG"; log_file="$MASTER_SERVER_LOG" ;;
        Caves) tmp_log="$CAVES_TMP_LOG"; log_file="$CAVES_SERVER_LOG" ;;
    esac
    # 优先临时日志
    if [ -s "$tmp_log" ] && grep -q "Sim paused" "$tmp_log" 2>/dev/null; then
        return 0
    fi
    # 回退 server_log.txt
    if [ -f "$log_file" ] && grep -q "Sim paused" "$log_file" 2>/dev/null; then
        return 0
    fi
    return 1
}

# 综合判断单个 shard 状态
# 返回状态文本：running / starting / no_screen / crashed / stopped
# 判定优先级：进程存在性 > 日志就绪 > Screen 会话
get_shard_status() {
    local shard="$1"
    local session
    case "$shard" in
        Master) session="$SCREEN_MASTER_SESSION" ;;
        Caves) session="$SCREEN_CAVES_SESSION" ;;
    esac

    # 第一层：进程是否存在（前置阻断）
    local process_ok=1
    check_process_layer "$session" && process_ok=0

    # 进程不存在 → 直接判定停止，不看日志
    if [ "$process_ok" -ne 0 ]; then
        # 检查 Screen 是否残留
        local screen_ok=1
        check_screen_layer "$session" && screen_ok=0
        if [ "$screen_ok" -eq 0 ]; then
            echo "crashed"  # Screen 存在但进程已退出
        else
            echo "stopped"  # 进程和 Screen 都不存在
        fi
        return
    fi

    # 第二层：进程存在，检查日志是否就绪
    local log_ok=1
    check_log_layer "$shard" && log_ok=0

    if [ "$log_ok" -eq 0 ]; then
        echo "running"  # 进程存在 + 日志 Sim paused → 运行中
        return
    fi

    # 第三层：进程存在但日志未就绪，检查 Screen
    local screen_ok=1
    check_screen_layer "$session" && screen_ok=0

    if [ "$screen_ok" -eq 0 ]; then
        echo "starting"  # 进程存在 + Screen 存在 + 日志未就绪 → 启动中
    else
        echo "no_screen"  # 进程存在但 Screen 丢失
    fi
}

# 兼容旧接口：判断服务器是否在运行
server_is_running() {
    pgrep -f "dontstarve_dedicated_server_nullrenderer" >/dev/null 2>&1
}

# 检查单个 shard 的运行状态（兼容旧接口）
# 返回: 0=正常, 1=Screen 丢失但 DST 运行, 2=Screen 存在但 DST 退出, 3=未运行
check_shard_status() {
    local session="$1"
    local shard_name="$2"

    local status
    status=$(get_shard_status "$shard_name")

    case "$status" in
        running|starting) return 0 ;;
        no_screen) return 1 ;;
        crashed) return 2 ;;
        *) return 3 ;;
    esac
}

# 启动单个 shard 进程
start_server_process() {
    local shard="$1"
    local session log_file tmp_log
    case "$shard" in
        Master)
            session="$SCREEN_MASTER_SESSION"
            log_file="$MASTER_SERVER_LOG"
            tmp_log="$MASTER_TMP_LOG"
            ;;
        Caves)
            session="$SCREEN_CAVES_SESSION"
            log_file="$CAVES_SERVER_LOG"
            tmp_log="$CAVES_TMP_LOG"
            ;;
    esac

    # 清空本次启动专用临时检测日志
    mkdir -p "$(dirname "$tmp_log")"
    > "$tmp_log"

    cd "$SERVER_BIN_DIR"
    # 使用 setsid + tee 分流：同时写入完整日志和临时检测日志
    setsid screen -dmS "$session" bash -c "\"$DEDICATED_SERVER_BINARY\" \
        -console \
        -cluster \"$CLUSTER_NAME\" \
        -shard \"$shard\" 2>&1 | tee -a \"$log_file\" \"$tmp_log\""
}

# 停止单个 shard 进程（精确匹配，不用模糊 pkill）
stop_server_process() {
    local shard="$1"
    local session
    case "$shard" in
        Master) session="$SCREEN_MASTER_SESSION" ;;
        Caves) session="$SCREEN_CAVES_SESSION" ;;
    esac

    # 优雅停止：发送关闭指令给 screen
    if screen -ls 2>/dev/null | grep -q "$session"; then
        screen -S "$session" -X stuff "c_shutdown(true)^M" 2>/dev/null || true
    fi
}

# 强制停止单个 shard（精确 PID，不用 pkill -f）
force_stop_server_process() {
    local shard="$1"
    local session
    case "$shard" in
        Master) session="$SCREEN_MASTER_SESSION" ;;
        Caves) session="$SCREEN_CAVES_SESSION" ;;
    esac

    # 通过 screen 会话 PID 精确杀
    local screen_pid
    screen_pid=$(get_screen_pid "$session")
    if [ -n "$screen_pid" ]; then
        kill "$screen_pid" 2>/dev/null || true
    fi

    # 精确查找该 shard 的 DST 进程并杀掉
    local dst_pids
    dst_pids=$(pgrep -f "dontstarve_dedicated_server_nullrenderer.*-shard $shard.*-cluster $CLUSTER_NAME" 2>/dev/null)
    if [ -n "$dst_pids" ]; then
        echo "$dst_pids" | while read -r pid; do
            kill "$pid" 2>/dev/null || true
        done
    fi
}

# 检查 Screen 会话是否 Detached，若 Attached 则自动 Detach
ensure_screen_detached() {
    local session="$1"
    local state
    state=$(get_screen_state "$session")
    if [ "$state" = "Attached" ]; then
        run_silent screen -d "$session"
    fi
}

# 自动异常检测（菜单循环中调用）
auto_anomaly_check() {
    local has_anomaly=0

    for shard in Master Caves; do
        local status
        status=$(get_shard_status "$shard")

        case "$status" in
            no_screen)
                echo -e "  ${YELLOW}⚠${NC} $shard: DST 正在运行，但 Screen 会话已丢失"
                has_anomaly=1
                ;;
            crashed)
                echo -e "  ${YELLOW}⚠${NC} $shard: Screen 存在，但 DST 已退出"
                echo -e "    ${GRAY}建议：重新启动服务器${NC}"
                has_anomaly=1
                ;;
        esac
    done

    return $has_anomaly
}

# ========================================
# 服务器管理功能
# ========================================

# ========================================
# 启动检测（基于日志行偏移，避免历史误判）
# ========================================

# 获取日志文件当前行数
get_log_line_count() {
    local file="$1"
    if [ -f "$file" ]; then
        wc -l < "$file" 2>/dev/null | tr -d ' '
    else
        echo 0
    fi
}

# 检查日志新增行中是否包含指定字符串
# 参数: log_file, line_offset, pattern
# 仅从第 line_offset+1 行开始检查新内容
check_new_log_contains() {
    local file="$1"
    local line_offset="$2"
    local pattern="$3"
    # 文件不存在或为空 → 未就绪
    if [ ! -f "$file" ] || [ ! -s "$file" ]; then
        return 1
    fi
    # 文件行数不足 → 没有新内容
    local current_lines
    current_lines=$(get_log_line_count "$file")
    if [ "$current_lines" -le "$line_offset" ]; then
        return 1
    fi
    # 用 sed 提取新行，直接 grep（避免 tail|grep 管道缓冲问题）
    sed -n "$((line_offset + 1)),\$p" "$file" 2>/dev/null | grep -q "$pattern" 2>/dev/null
}

# 获取日志新增行数
get_new_log_lines() {
    local file="$1"
    local line_offset="$2"
    if [ ! -f "$file" ]; then
        echo 0
        return
    fi
    local current_lines
    current_lines=$(get_log_line_count "$file")
    local new_lines=$((current_lines - line_offset))
    [ "$new_lines" -lt 0 ] && new_lines=0
    echo "$new_lines"
}

# 检查单个 shard 是否就绪（临时日志优先，空则回退 server_log）
# 参数: shard_name
# 返回: 0=就绪(Sim paused), 1=未就绪
check_shard_ready() {
    local shard="$1"
    local tmp_log log_file
    case "$shard" in
        Master) tmp_log="$MASTER_TMP_LOG"; log_file="$MASTER_SERVER_LOG" ;;
        Caves) tmp_log="$CAVES_TMP_LOG"; log_file="$CAVES_SERVER_LOG" ;;
    esac
    # 优先读临时日志（无历史干扰）
    if [ -s "$tmp_log" ] && grep -q "Sim paused" "$tmp_log" 2>/dev/null; then
        return 0
    fi
    # tmp 为空时回退读 server_log.txt（DST 直接写文件，tee 可能未捕获）
    if [ -f "$log_file" ] && grep -q "Sim paused" "$log_file" 2>/dev/null; then
        return 0
    fi
    return 1
}

# 检查临时检测日志中是否有错误信息
check_log_errors() {
    local tmp_log="$1"
    if [ ! -f "$tmp_log" ] || [ ! -s "$tmp_log" ]; then
        return
    fi
    if grep -qi "Lua Error\|Mod Error\|Exception\|ERROR.*failed\|FATAL" "$tmp_log" 2>/dev/null; then
        grep -i "Lua Error\|Mod Error\|Exception\|ERROR.*failed\|FATAL" "$tmp_log" 2>/dev/null | tail -5
    fi
}

# 显示单个分片的启动进度状态
# 参数: shard, ready_state(0/1), line_offset
show_shard_progress() {
    local shard="$1"
    local ready="$2"
    local line_offset="$3"

    if [ "$ready" -eq 1 ]; then
        echo -n "${GREEN}✓ 已启动${NC}"
        return
    fi

    # 检查是否有新日志行
    local new_lines
    new_lines=$(get_new_log_lines "$shard_log_file" "$line_offset")

    if [ "$new_lines" -gt 0 ]; then
        echo -n "${YELLOW}◐ 初始化世界...${NC}"
    else
        echo -n "${GRAY}○ 启动中...${NC}"
    fi
}

# 统一刷新启动进度显示（基于临时检测日志）
# 参数: waited, max_wait, master_ready, caves_ready
show_start_progress() {
    local waited="$1"
    local max_wait="$2"
    local master_ready="$3"
    local caves_ready="$4"

    # Master 状态
    local master_icon
    if [ "$master_ready" -eq 1 ]; then
        master_icon="${GREEN}✓ 已启动${NC}"
    elif [ -s "$MASTER_TMP_LOG" ]; then
        # 临时日志有内容 → 正在初始化
        master_icon="${YELLOW}◐ 初始化世界...${NC}"
    else
        master_icon="${GRAY}○ 启动中...${NC}"
    fi

    # Caves 状态（独立判断）
    local caves_icon
    if [ "$caves_ready" -eq 1 ]; then
        caves_icon="${GREEN}✓ 已启动${NC}"
    elif [ -s "$CAVES_TMP_LOG" ]; then
        caves_icon="${YELLOW}◐ 初始化世界...${NC}"
    else
        caves_icon="${GRAY}○ 启动中...${NC}"
    fi

    printf "\r  等待：%02d/%02d 秒  Master：%b  Caves：%b                                        " \
        "$waited" "$max_wait" "$master_icon" "$caves_icon"
}

# 等待服务器就绪（基于临时检测日志，无历史干扰）
wait_server_ready() {
    local waited=0
    local max_wait=120
    local is_timeout=0

    # Ctrl+C 跳过等待
    trap 'echo ""; print_warn "已跳过等待"; trap - INT; return 0' INT

    # 循环内实时刷新状态
    while [ "$waited" -lt "$max_wait" ]; do
        local master_has_log=0
        local master_complete=0
        local caves_has_log=0
        local caves_complete=0

        # Master 完整三层校验：文件存在 → 文件非空 → Sim paused
        if [ -f "$MASTER_TMP_LOG" ]; then
            if [ -s "$MASTER_TMP_LOG" ]; then
                master_has_log=1
                grep -q "Sim paused" "$MASTER_TMP_LOG" 2>/dev/null 1>/dev/null && master_complete=1
            fi
        fi
        # Caves 独立完整三层校验，和 Master 完全隔离
        if [ -f "$CAVES_TMP_LOG" ]; then
            if [ -s "$CAVES_TMP_LOG" ]; then
                caves_has_log=1
                grep -q "Sim paused" "$CAVES_TMP_LOG" 2>/dev/null 1>/dev/null && caves_complete=1
            fi
        fi

        # 双分片全部就绪，跳出循环
        if [ "$master_complete" -eq 1 ] && [ "$caves_complete" -eq 1 ]; then
            break
        fi

        # Master 三段 UI
        local master_ui
        if [ "$master_complete" -eq 1 ]; then
            master_ui="${GREEN}✓ 已启动${NC}"
        elif [ "$master_has_log" -eq 1 ]; then
            master_ui="${YELLOW}◐ 初始化世界...${NC}"
        else
            master_ui="${GRAY}○ 启动中...${NC}"
        fi
        # Caves 三段 UI
        local caves_ui
        if [ "$caves_complete" -eq 1 ]; then
            caves_ui="${GREEN}✓ 已启动${NC}"
        elif [ "$caves_has_log" -eq 1 ]; then
            caves_ui="${YELLOW}◐ 初始化世界...${NC}"
        else
            caves_ui="${GRAY}○ 启动中...${NC}"
        fi

        # 清空单行刷新进度
        printf "\r\033[K等待: %02d/%02d 秒  Master: %b  Caves: %b" \
            "$waited" "$max_wait" "$master_ui" "$caves_ui"

        sleep 1
        waited=$((waited + 1))
    done

    # --------------------------
    # 循环结束后【关键修复】：重新读取日志，刷新最终真实状态
    # --------------------------
    local final_master_complete=0
    local final_caves_complete=0
    # 重读 Master
    if [ -f "$MASTER_TMP_LOG" ] && [ -s "$MASTER_TMP_LOG" ]; then
        grep -q "Sim paused" "$MASTER_TMP_LOG" 2>/dev/null 1>/dev/null && final_master_complete=1
    fi
    # 重读 Caves（单独强制检索，解决卡初始化）
    if [ -f "$CAVES_TMP_LOG" ] && [ -s "$CAVES_TMP_LOG" ]; then
        grep -q "Sim paused" "$CAVES_TMP_LOG" 2>/dev/null 1>/dev/null && final_caves_complete=1
    fi

    # 重新判定超时：双分片都就绪=无超时，否则标记超时
    if [ "$final_master_complete" -eq 1 ] && [ "$final_caves_complete" -eq 1 ]; then
        is_timeout=0
    else
        is_timeout=1
    fi

    # 换行清空残留进度行
    echo ""
    echo ""
    print_success "Master 和 Caves 均已启动完成 (Sim paused)"

    # 仅超时才输出警告，正常就绪完全隐藏超时区块
    if [ "$is_timeout" -eq 1 ]; then
        echo ""
        echo -e "${YELLOW}⚠ 服务器启动超时（${max_wait}秒）${NC}"
        print_hint "未发现明显错误，服务器可能仍在加载"
        print_hint "请查看日志确认：$MASTER_SERVER_LOG / $CAVES_SERVER_LOG"
    fi

    # 打印 Screen 会话状态（固定保留，不受超时逻辑影响）
    echo ""
    echo -e "${WHITE}Screen 会话状态:${NC}"
    if screen -ls 2>/dev/null | grep -qw "$SCREEN_MASTER_SESSION"; then
        echo -e "Screen: Master  ${GREEN}✓ Detached${NC}"
    else
        echo -e "Screen: Master  ${RED}× 会话不存在${NC}"
    fi
    if screen -ls 2>/dev/null | grep -qw "$SCREEN_CAVES_SESSION"; then
        echo -e "Screen: Caves   ${GREEN}✓ Detached${NC}"
    else
        echo -e "Screen: Caves   ${RED}× 会话不存在${NC}"
    fi

    echo ""
    print_hint "使用 screen -r $SCREEN_MASTER_SESSION 查看地面控制台"
    print_hint "使用 screen -r $SCREEN_CAVES_SESSION 查看洞穴控制台"
    print_hint "按 Ctrl+A+D 退出 Screen 控制台（不会关闭服务器）"
    echo ""

    trap - INT
    return 0
}

start_server() {
    print_banner
    print_section "启动服务器"

    if ! check_server_installed; then
        pause
        return
    fi

    if ! check_cluster_exists; then
        pause
        return
    fi

    if server_is_running; then
        print_warn "服务器已经在运行中"
        echo -e "  当前进程数: $(server_process_count)"
        pause
        return
    fi

    print_info "正在启动地面 (Master) 服务器..."
    start_server_process "Master"

    print_info "正在启动洞穴 (Caves) 服务器..."
    start_server_process "Caves"

    echo ""
    print_success "服务器启动命令已发送"
    echo ""
    echo -e "${WHITE}启动信息:${NC}"
    echo -e "  集群: $CLUSTER_NAME"
    echo -e "  Master Screen: $SCREEN_MASTER_SESSION"
    echo -e "  Caves Screen: $SCREEN_CAVES_SESSION"
    echo ""

    print_info "等待服务器初始化（约 30-120 秒）..."
    echo -e "${GRAY}  提示: 可随时按 Ctrl+C 跳过等待${NC}"
    echo ""

    # 局部 trap：Ctrl+C 只跳过等待，不退出工具箱
    trap 'echo ""; print_info "已跳过等待"; trap - INT; break' INT

    wait_server_ready
    local wait_result=$?

    trap - INT

    # 确保 Screen 会话处于 Detached 状态
    ensure_screen_detached "$SCREEN_MASTER_SESSION"
    ensure_screen_detached "$SCREEN_CAVES_SESSION"

    # 启动后验证
    echo ""
    echo -e "${WHITE}Screen 会话状态:${NC}"
    for shard in Master Caves; do
        local session
        case "$shard" in
            Master) session="$SCREEN_MASTER_SESSION" ;;
            Caves) session="$SCREEN_CAVES_SESSION" ;;
        esac
        local state
        state=$(get_screen_state "$session")
        if [ "$state" = "Detached" ]; then
            echo -e "  Screen: $shard  ${GREEN}✓ Detached${NC}"
        elif [ "$state" = "Attached" ]; then
            echo -e "  Screen: $shard  ${YELLOW}⚠ Attached${NC} (已自动 Detach)"
        else
            echo -e "  Screen: $shard  ${RED}✗ $state${NC}"
        fi
    done

    echo ""
    print_hint "使用 screen -r $SCREEN_MASTER_SESSION 查看地面控制台"
    print_hint "使用 screen -r $SCREEN_CAVES_SESSION 查看洞穴控制台"
    print_hint "按 Ctrl+A+D 退出 Screen 控制台（不会关闭服务器）"

    pause
}

stop_server() {
    print_banner
    print_section "停止服务器"

    if ! server_is_running; then
        print_warn "服务器没有在运行"
        pause
        return
    fi

    local proc_count
    proc_count=$(server_process_count)

    print_info "正在停止服务器 (当前 $proc_count 个进程)..."

    # 优雅停止：通过 screen session 精确发送关闭指令
    stop_server_process "Master"
    stop_server_process "Caves"

    # 等待优雅关闭
    local waited=0
    while [ "$waited" -lt 10 ]; do
        if ! server_is_running; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    # 超时则精确强制停止
    if server_is_running; then
        print_warn "优雅停止超时，强制结束进程..."
        force_stop_server_process "Master"
        force_stop_server_process "Caves"
        sleep 2
    fi

    # 清理残留 screen 会话
    for session in "$SCREEN_MASTER_SESSION" "$SCREEN_CAVES_SESSION"; do
        local screen_pid
        screen_pid=$(get_screen_pid "$session")
        if [ -n "$screen_pid" ]; then
            run_silent screen -S "$session" -X quit
        fi
    done

    if server_is_running; then
        print_error "部分进程可能仍在运行"
    else
        print_success "服务器已停止"
    fi

    # 停止完成后清空临时检测日志，避免下次启动误判
    [ -f "$MASTER_TMP_LOG" ] && > "$MASTER_TMP_LOG"
    [ -f "$CAVES_TMP_LOG" ] && > "$CAVES_TMP_LOG"

    pause
}

# 静默停止服务器（仅供重启内部调用，无 pause 回车）
silent_stop_server() {
    if ! server_is_running; then
        return
    fi

    local proc_count
    proc_count=$(server_process_count)
    print_info "正在停止旧服务 (当前 $proc_count 个进程)..."

    # 优雅停止
    stop_server_process "Master"
    stop_server_process "Caves"

    # 等待优雅关闭
    local waited=0
    while [ "$waited" -lt 10 ]; do
        if ! server_is_running; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    # 强制停止残留进程
    if server_is_running; then
        print_warn "优雅关闭超时，强制结束进程..."
        force_stop_server_process "Master"
        force_stop_server_process "Caves"
        sleep 2
    fi

    # 清理残留 screen 会话
    for session in "$SCREEN_MASTER_SESSION" "$SCREEN_CAVES_SESSION"; do
        local screen_pid
        screen_pid=$(get_screen_pid "$session")
        if [ -n "$screen_pid" ]; then
            run_silent screen -S "$session" -X quit
        fi
    done

    # 清空临时检测日志
    [ -f "$MASTER_TMP_LOG" ] && > "$MASTER_TMP_LOG"
    [ -f "$CAVES_TMP_LOG" ] && > "$CAVES_TMP_LOG"

    print_success "旧服务器已全部关闭"
}

restart_server() {
    print_banner
    print_section "重启服务器"
    print_info "全自动重启：关闭旧服务 → 启动新服务"

    # 仅执行静默停止，无 pause 阻断
    if server_is_running; then
        silent_stop_server
        print_success "旧服务器已全部关闭"
        sleep 1
    fi

    # 直接调用原生 start_server，100% 复用启动界面、等待循环、进度 UI
    start_server
}

# 显示单个 shard 的详细状态
show_shard_detail() {
    local shard="$1"
    local session
    case "$shard" in
        Master) session="$SCREEN_MASTER_SESSION" ;;
        Caves) session="$SCREEN_CAVES_SESSION" ;;
    esac

    # 三层状态
    local screen_ok=1
    local process_ok=1
    local log_ok=1
    check_screen_layer "$session" && screen_ok=0
    check_process_layer "$session" && process_ok=0
    check_log_layer "$shard" && log_ok=0

    local status_text
    status_text=$(get_shard_status "$shard")

    echo -e "  ${WHITE}$shard${NC}"

    # 状态行
    case "$status_text" in
        running)
            echo -e "    状态：${GREEN}✓ 运行中${NC} (Sim paused)"
            ;;
        starting)
            echo -e "    状态：${YELLOW}启动中...${NC}"
            ;;
        no_screen)
            echo -e "    状态：${YELLOW}DST 运行中，Screen 会话丢失${NC}"
            ;;
        crashed)
            echo -e "    状态：${RED}Screen 存在，DST 已退出${NC}"
            echo -e "    ${GRAY}建议：重新启动服务器${NC}"
            ;;
        stopped)
            echo -e "    状态：${RED}未运行${NC}"
            echo ""
            return
            ;;
    esac

    # Screen 层
    local screen_state
    screen_state=$(get_screen_state "$session")
    if [ "$screen_ok" -eq 0 ]; then
        if [ "$screen_state" = "Detached" ]; then
            echo -e "    Screen：${GREEN}✓ Detached${NC}"
        elif [ "$screen_state" = "Attached" ]; then
            echo -e "    Screen：${GREEN}✓ Attached${NC}"
        else
            echo -e "    Screen：${GREEN}✓ $screen_state${NC}"
        fi
    else
        echo -e "    Screen：${RED}(会话不存在)${NC}"
    fi

    # 进程层（PID 信息，辅助）
    local dst_pid
    dst_pid=$(pgrep -f "dontstarve_dedicated_server_nullrenderer" 2>/dev/null | head -1)
    if [ -n "$dst_pid" ]; then
        local resource
        resource=$(get_process_resource "$dst_pid")
        local uptime
        uptime=$(get_process_uptime "$dst_pid")
        local cpu="${resource%% *}"
        local mem="${resource#* }"
        echo -e "    PID：${CYAN}$dst_pid${NC}"
        echo -e "    CPU：${CYAN}$cpu${NC}  Memory：${CYAN}$mem${NC}"
        echo -e "    运行时间：${CYAN}$uptime${NC}"
    fi

    # 日志层
    if [ "$log_ok" -eq 0 ]; then
        echo -e "    日志检测：${GREEN}✓ Sim paused${NC}"
    else
        echo -e "    日志检测：${YELLOW}等待启动完成...${NC}"
    fi

    echo ""
}

server_status() {
    print_banner
    print_section "服务器运行状态"

    echo -e "${CYAN}========================${NC}"
    echo -e "${WHITE}${BOLD}  当前集群：$CLUSTER_NAME${NC}"
    echo -e "${CYAN}========================${NC}"
    echo ""

    # 使用三层模型判断是否运行（进程存在性优先）
    local master_state
    master_state=$(get_shard_status "Master")
    local caves_state
    caves_state=$(get_shard_status "Caves")

    local any_running=0
    [ "$master_state" = "running" ] || [ "$master_state" = "starting" ] || [ "$master_state" = "no_screen" ] && any_running=1
    [ "$caves_state" = "running" ] || [ "$caves_state" = "starting" ] || [ "$caves_state" = "no_screen" ] && any_running=1

    if [ "$any_running" -eq 1 ]; then
        show_shard_detail "Master"
        echo -e "  ${GRAY}-----------------------${NC}"
        echo ""
        show_shard_detail "Caves"

        # 异常检测
        echo -e "${CYAN}========================${NC}"
        auto_anomaly_check
        if [ $? -eq 0 ]; then
            echo -e "  ${GREEN}✓ 所有服务正常运行${NC}"
        fi

        # 端口监听
        echo ""
        echo -e "${WHITE}端口监听:${NC}"
        for port in $MASTER_PORT $CAVES_PORT; do
            local listening=0
            if command -v ss >/dev/null 2>&1; then
                ss -uln 2>/dev/null | grep -q ":$port " && listening=1
            elif command -v netstat >/dev/null 2>&1; then
                netstat -uln 2>/dev/null | grep -q ":$port " && listening=1
            fi
            if [ "$listening" -eq 1 ]; then
                echo -e "  ${GREEN}UDP $port 监听中${NC}"
            else
                echo -e "  ${GRAY}UDP $port 未监听${NC}"
            fi
        done
    else
        echo -e "  ${RED}服务器未运行${NC}"
        echo ""
    fi

    echo ""
    echo -e "${CYAN}========================${NC}"
    echo -e "${WHITE}系统资源:${NC}"
    echo -e "  内存: $(free -h | awk '/Mem:/ {print $3 " / " $2}')"
    echo -e "  磁盘: $(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')"

    pause
}

# ========================================
# 日志系统
# ========================================

# 尾部查看单个日志文件（带前缀，Ctrl+C 清屏返回）
tail_log_with_prefix() {
    local log_file="$1"
    local prefix="$2"

    if [ ! -f "$log_file" ]; then
        print_error "${prefix}日志文件不存在"
        return
    fi

    print_info "实时${prefix}日志，Ctrl+C 返回"
    echo ""

    # 局部 trap：Ctrl+C 退出后清屏
    trap 'trap - INT; return_menu; return' INT

    tail -f "$log_file" 2>/dev/null | while IFS= read -r line; do
        echo "[${prefix}] $line"
    done

    trap - INT
}

# 合并查看地面+洞穴日志
tail_merge_logs() {
    local has_master=0
    local has_caves=0
    [ -f "$MASTER_SERVER_LOG" ] && has_master=1
    [ -f "$CAVES_SERVER_LOG" ] && has_caves=1

    if [ "$has_master" -eq 0 ] && [ "$has_caves" -eq 0 ]; then
        print_error "地面、洞穴日志文件均不存在"
        return
    fi

    print_info "【合并实时日志】[地面] 代表地面 | [洞穴] 代表洞穴，Ctrl+C 返回"
    echo ""

    # 局部 trap：Ctrl+C 杀掉所有 tail 子进程并清屏
    trap 'cleanup_background; trap - INT; return_menu; return' INT

    if [ "$has_master" -eq 1 ]; then
        tail -f "$MASTER_SERVER_LOG" 2>/dev/null | sed 's/^/[地面] /' &
        _BG_PIDS+=($!)
    fi
    if [ "$has_caves" -eq 1 ]; then
        tail -f "$CAVES_SERVER_LOG" 2>/dev/null | sed 's/^/[洞穴] /' &
        _BG_PIDS+=($!)
    fi

    wait

    trap - INT
}

view_logs() {
    print_banner
    print_section "查看服务器日志"

    if ! check_cluster_exists; then
        pause
        return
    fi

    local log_options=(
        "地面服务器日志 (最后80行)"
        "洞穴服务器日志 (最后80行)"
        "单独实时地面日志"
        "单独实时洞穴日志"
        "地面+洞穴 合并实时日志"
        "返回"
    )

    select_menu "请选择要查看的日志:" "${log_options[@]}"
    local choice=$SELECTED_INDEX

    if [ "$choice" -eq -1 ] || [ "$choice" -eq 5 ]; then
        return
    fi
    case "$choice" in
        0)
            if [ -f "$MASTER_SERVER_LOG" ]; then
                echo ""
                print_info "显示地面日志最后80行..."
                echo ""
                tail -80 "$MASTER_SERVER_LOG"
            else
                print_error "地面日志文件不存在"
            fi
            ;;
        1)
            if [ -f "$CAVES_SERVER_LOG" ]; then
                echo ""
                print_info "显示洞穴日志最后80行..."
                echo ""
                tail -80 "$CAVES_SERVER_LOG"
            else
                print_error "洞穴日志文件不存在"
            fi
            ;;
        2)
            tail_log_with_prefix "$MASTER_SERVER_LOG" "地面"
            ;;
        3)
            tail_log_with_prefix "$CAVES_SERVER_LOG" "洞穴"
            ;;
        4)
            tail_merge_logs
            ;;
    esac

    # 退出日志模式后清屏恢复菜单
    cleanup_background
    clear
    pause
}

# ========================================
# 集群管理功能
# ========================================

switch_cluster() {
    print_banner
    print_section "切换当前集群"

    if [ ! -d "$KLEI_ROOT" ]; then
        print_warn "配置目录不存在: $KLEI_ROOT"
        pause
        return
    fi

    # 收集所有集群
    local cluster_names=()
    for cluster in "$KLEI_ROOT"/*/; do
        [ -d "$cluster" ] || continue
        local name
        name=$(basename "$cluster")
        [ "$name" = "backups" ] && continue
        cluster_names+=("$name")
    done

    if [ ${#cluster_names[@]} -eq 0 ]; then
        print_warn "暂无集群，请先创建或导入集群"
        pause
        return
    fi

    # 交互式选择
    select_menu "可用集群（当前: $CLUSTER_NAME）:" "${cluster_names[@]}"

    # ESC 返回
    if [ "$SELECTED_INDEX" -eq -1 ]; then
        return
    fi

    local new_cluster="${cluster_names[$SELECTED_INDEX]}"

    if [ "$new_cluster" = "$CLUSTER_NAME" ]; then
        print_info "已经是当前集群了"
        pause
        return
    fi

    set_current_cluster "$new_cluster"

    print_success "已切换到集群: $CLUSTER_NAME"
    pause
}

create_cluster() {
    print_banner
    print_section "创建新集群"

    read -rp "请输入新集群名称 (如 Cluster_2): " new_cluster

    if [ -z "$new_cluster" ]; then
        print_warn "名称不能为空"
        pause
        return
    fi

    local new_cluster_dir="$KLEI_ROOT/$new_cluster"

    if [ -d "$new_cluster_dir" ]; then
        print_error "集群已存在: $new_cluster"
        pause
        return
    fi

    read -rp "服务器显示名称 (显示在游戏列表中): " display_name
    display_name="${display_name:-My DST Server}"

    read -rp "服务器密码 (留空则无密码): " server_pwd
    server_pwd="${server_pwd:-}"

    read -rp "最大玩家数 (默认 6): " max_players
    max_players="${max_players:-6}"

    echo ""
    print_info "正在创建集群目录结构..."

    mkdir -p "$new_cluster_dir/Master"
    mkdir -p "$new_cluster_dir/Caves"

    # 生成 cluster.ini（标准格式，不含 server_name/server_password）
    cat > "$new_cluster_dir/cluster.ini" <<EOF
[NETWORK]
cluster_name = $display_name
cluster_password = $server_pwd
cluster_description =
lan_only_cluster = false
offline_cluster = false
cluster_language = zh
whitelist_slots = 0

[GAMEPLAY]
game_mode = survival
max_players = $max_players
pvp = false
pause_when_empty = true
vote_kick_enabled = true

[MISC]
console_enabled = true
max_snapshots = 6

[SHARD]
shard_enabled = true
bind_ip = 127.0.0.1
master_ip = 127.0.0.1
master_port = 10889
cluster_key = dstclusterkey
EOF

    # 生成 Master/server.ini
    cat > "$new_cluster_dir/Master/server.ini" <<EOF
[NETWORK]
server_port = 10999

[SHARD]
is_master = true
name = Master
id = 1

[STEAM]
master_server_port = 27016
authentication_port = 8766

[ACCOUNT]
encode_user_path = true
EOF

    # 生成 Caves/server.ini
    cat > "$new_cluster_dir/Caves/server.ini" <<EOF
[NETWORK]
server_port = 10998

[SHARD]
is_master = false
name = Caves
id = 2

[STEAM]
master_server_port = 27017
authentication_port = 8767

[ACCOUNT]
encode_user_path = true
EOF

    # 生成空的 modoverrides.lua
    echo 'return {}' > "$new_cluster_dir/Master/modoverrides.lua"
    echo 'return {}' > "$new_cluster_dir/Caves/modoverrides.lua"

    # 生成世界配置
    cat > "$new_cluster_dir/Master/worldgenoverride.lua" <<EOF
return {
  override_enabled = true,
  preset = "SURVIVAL_TOGETHER",
}
EOF

    cat > "$new_cluster_dir/Caves/worldgenoverride.lua" <<EOF
return {
  override_enabled = true,
  preset = "DST_CAVE",
}
EOF

    print_success "集群创建成功: $new_cluster"
    echo ""
    print_warn "重要: 你还需要添加 cluster_token.txt 才能正常运行"
    print_hint "1. 访问 https://accounts.klei.com/account/game/servers?game=DontStarveTogether"
    print_hint "2. 登录后获取服务器令牌"
    print_hint "3. 将令牌写入: $new_cluster_dir/cluster_token.txt"
    print_hint "   命令: echo '你的令牌' > $new_cluster_dir/cluster_token.txt"

    if confirm "是否切换到这个新集群?"; then
        set_current_cluster "$new_cluster"
    fi

    pause
}

import_cluster() {
    print_banner
    print_section "导入集群"

    if [ ! -d "$CLUSTER_IMPORT_DIR" ]; then
        mkdir -p "$CLUSTER_IMPORT_DIR"
        print_info "已创建导入目录: $CLUSTER_IMPORT_DIR"
    fi

    echo ""
    print_info "导入目录: $CLUSTER_IMPORT_DIR"
    echo ""
    print_hint "1. 将集群文件夹上传到上述目录"
    print_hint "2. 文件夹名即为集群名"
    print_hint "3. 确保文件夹内包含 cluster.ini、Master、Caves"
    echo ""

    # 列出可导入的集群
    local import_list=()
    local import_names=()
    for item in "$CLUSTER_IMPORT_DIR"/*/; do
        [ -d "$item" ] || continue
        local name
        name=$(basename "$item")
        if [ -f "$item/cluster.ini" ]; then
            import_list+=("$name")
            import_names+=("$name")
        fi
    done

    if [ ${#import_list[@]} -eq 0 ]; then
        print_warn "导入目录中没有找到可导入的集群"
        print_hint "请先使用 SFTP/SCP 将集群文件夹上传到 $CLUSTER_IMPORT_DIR"
        pause
        return
    fi

    # 交互式选择
    select_menu "选择要导入的集群:" "${import_list[@]}"

    # ESC 返回
    if [ "$SELECTED_INDEX" -eq -1 ]; then
        return
    fi

    local selected="${import_names[$SELECTED_INDEX]}"

    local target="$KLEI_ROOT/$selected"

    if [ -d "$target" ]; then
        print_warn "目标集群已存在: $selected"
        if ! confirm "是否覆盖?"; then
            pause
            return
        fi
        rm -rf "$target"
    fi

    cp -r "$CLUSTER_IMPORT_DIR/$selected" "$target"

    print_success "集群导入成功: $selected"

    if confirm "是否切换到这个集群?"; then
        set_current_cluster "$selected"
    fi

    pause
}

# ========================================
# 集群配置修改功能
# ========================================

edit_cluster_config() {
    print_banner
    print_section "修改集群配置"

    # 收集所有集群
    local cluster_names=()
    for cluster in "$KLEI_ROOT"/*/; do
        [ -d "$cluster" ] || continue
        local name
        name=$(basename "$cluster")
        [ "$name" = "backups" ] && continue
        cluster_names+=("$name")
    done

    if [ ${#cluster_names[@]} -eq 0 ]; then
        print_warn "暂无集群，请先创建或导入集群"
        pause
        return
    fi

    # 选择要修改的集群
    select_menu "选择要修改的集群:" "${cluster_names[@]}"
    if [ "$SELECTED_INDEX" -eq -1 ]; then
        return
    fi

    local target_cluster="${cluster_names[$SELECTED_INDEX]}"
    local target_dir="$KLEI_ROOT/$target_cluster"
    local cluster_ini="$target_dir/cluster.ini"
    local master_ini="$target_dir/Master/server.ini"
    local caves_ini="$target_dir/Caves/server.ini"

    if [ ! -f "$cluster_ini" ]; then
        print_error "集群配置文件不存在: $cluster_ini"
        pause
        return
    fi

    # 通用INI读取函数
    read_ini_val() {
        local key="$1"
        local file="$2"
        grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null | head -1 | sed -E 's/^[[:space:]]*'"${key}"'[[:space:]]*=[[:space:]]*//' | sed -E 's/[[:space:]]*$//'
    }

    while true; do
        # 读取配置（只使用 cluster_name / cluster_password）
        local server_name
        server_name=$(read_ini_val "cluster_name" "$cluster_ini")

        local server_pwd
        server_pwd=$(read_ini_val "cluster_password" "$cluster_ini")

        local max_players
        max_players=$(read_ini_val "max_players" "$cluster_ini")
        local game_mode
        game_mode=$(read_ini_val "game_mode" "$cluster_ini")
        local pvp
        pvp=$(read_ini_val "pvp" "$cluster_ini")
        local master_port_val
        master_port_val=$(read_ini_val "server_port" "$master_ini")
        local caves_port_val
        caves_port_val=$(read_ini_val "server_port" "$caves_ini")

        # 空值默认兜底
        max_players="${max_players:-6}"
        game_mode="${game_mode:-survival}"
        pvp="${pvp:-false}"
        master_port_val="${master_port_val:-10999}"
        caves_port_val="${caves_port_val:-10998}"

        print_banner
        print_section "修改集群配置: $target_cluster"
        echo -e "${WHITE}当前配置:${NC}"
        echo ""
        echo -e "  集群名称:     ${CYAN}$target_cluster${NC}"
        echo -e "  服务器名称:   ${CYAN}${server_name:-(未设置)}${NC}"
        echo -e "  服务器密码:   ${CYAN}${server_pwd:-(无)}${NC}"
        echo -e "  最大玩家数:   ${CYAN}${max_players}${NC}"
        echo -e "  游戏模式:     ${CYAN}${game_mode}${NC}"
        echo -e "  PVP:          ${CYAN}${pvp}${NC}"
        echo -e "  Master端口:   ${CYAN}${master_port_val}${NC}"
        echo -e "  Caves端口:    ${CYAN}${caves_port_val}${NC}"
        echo ""

        local options=(
            "修改集群名称"
            "修改服务器名称"
            "修改服务器密码"
            "修改最大玩家数"
            "修改游戏模式"
            "切换 PVP 开关"
            "修改服务器端口"
            "返回"
        )

        select_menu "请选择要修改的项:" "${options[@]}"
        local choice=$SELECTED_INDEX

        if [ "$choice" -eq -1 ] || [ "$choice" -eq 7 ]; then
            break
        fi

        case "$choice" in
            0)
                # 修改集群文件夹名称
                echo ""
                read -rp "输入新的集群名称: " new_name
                if [ -z "$new_name" ]; then
                    print_warn "名称不能为空"
                    pause
                    continue
                fi
                if [ -d "$KLEI_ROOT/$new_name" ]; then
                    print_error "集群已存在: $new_name"
                    pause
                    continue
                fi
                if server_is_running; then
                    if [ "$CLUSTER_NAME" = "$target_cluster" ]; then
                        print_warn "当前集群正在运行，无法重命名"
                        pause
                        continue
                    fi
                fi

                local old_target="$target_cluster"
                mv "$target_dir" "$KLEI_ROOT/$new_name" || true
                target_cluster="$new_name"
                target_dir="$KLEI_ROOT/$new_name"
                cluster_ini="$target_dir/cluster.ini"
                master_ini="$target_dir/Master/server.ini"
                caves_ini="$target_dir/Caves/server.ini"

                # 同步全局 CLUSTER_NAME（如果是当前集群）
                if [ "$CLUSTER_NAME" = "$old_target" ]; then
                    set_current_cluster "$new_name"
                fi

                print_success "集群目录已重命名为: $new_name"
                pause
                ;;
            1)
                # 修改服务器显示名称（只修改 cluster_name）
                echo ""
                read -rp "输入新的服务器名称: " new_server_name
                if [ -z "$new_server_name" ]; then
                    print_warn "名称不能为空"
                    pause
                    continue
                fi

                sed -i -E 's/^[[:space:]]*cluster_name[[:space:]]*=.*/cluster_name = '"$new_server_name"'/' "$cluster_ini" || true

                print_success "服务器名称已更新"
                pause
                ;;
            2)
                # 修改服务器密码（只修改 cluster_password）
                echo ""
                read -rp "输入新的服务器密码 (留空则无密码): " new_pwd

                sed -i -E 's/^[[:space:]]*cluster_password[[:space:]]*=.*/cluster_password = '"$new_pwd"'/' "$cluster_ini" || true

                if [ -z "$new_pwd" ]; then
                    print_success "已清除服务器密码"
                else
                    print_success "服务器密码已更新"
                fi
                pause
                ;;
            3)
                # 修改最大玩家数
                echo ""
                read -rp "输入最大玩家数 (1-16): " new_max
                if ! echo "$new_max" | grep -qE '^[0-9]+$' || [ "$new_max" -lt 1 ] || [ "$new_max" -gt 16 ]; then
                    print_error "请输入 1-16 之间的数字"
                    pause
                    continue
                fi
                sed -i -E "s/^[[:space:]]*max_players[[:space:]]*=.*/max_players = $new_max/" "$cluster_ini" || true
                print_success "最大玩家数已更新为: $new_max"
                pause
                ;;
            4)
                # 修改游戏模式
                local modes=("survival 生存" "endless 无尽" "wilderness 荒野")
                select_menu "选择游戏模式:" "${modes[@]}"
                if [ "$SELECTED_INDEX" -eq -1 ]; then
                    continue
                fi
                local mode_key
                case "$SELECTED_INDEX" in
                    0) mode_key="survival" ;;
                    1) mode_key="endless" ;;
                    2) mode_key="wilderness" ;;
                esac
                sed -i -E "s/^[[:space:]]*game_mode[[:space:]]*=.*/game_mode = $mode_key/" "$cluster_ini" || true
                print_success "游戏模式已更新为: $mode_key"
                pause
                ;;
            5)
                # 切换PVP
                if [ "$pvp" = "true" ]; then
                    sed -i -E "s/^[[:space:]]*pvp[[:space:]]*=.*/pvp = false/" "$cluster_ini" || true
                    print_success "已关闭 PVP"
                else
                    sed -i -E "s/^[[:space:]]*pvp[[:space:]]*=.*/pvp = true/" "$cluster_ini" || true
                    print_success "已开启 PVP"
                fi
                pause
                ;;
            6)
                # 修改游戏端口
                echo ""
                read -rp "输入 Master 游戏端口 (默认 10999): " new_master_port
                if ! echo "$new_master_port" | grep -qE '^[0-9]+$'; then
                    print_error "无效的端口号"
                    pause
                    continue
                fi
                read -rp "输入 Caves 游戏端口 (默认 10998): " new_caves_port
                if ! echo "$new_caves_port" | grep -qE '^[0-9]+$'; then
                    print_error "无效的端口号"
                    pause
                    continue
                fi
                sed -i -E "s/^[[:space:]]*server_port[[:space:]]*=.*/server_port = $new_master_port/" "$master_ini" || true
                sed -i -E "s/^[[:space:]]*server_port[[:space:]]*=.*/server_port = $new_caves_port/" "$caves_ini" || true
                print_success "端口已更新 (Master: $new_master_port, Caves: $new_caves_port)"
                print_warn "记得同步更新阿里云安全组与系统防火墙UDP端口规则"
                pause
                ;;
        esac
    done
}

# ========================================
# 当前集群配置查看
# ========================================

view_cluster_config() {
    print_banner
    print_section "查看当前集群配置"

    if ! check_cluster_exists; then
        pause
        return
    fi

    local cluster_ini="$CLUSTER_DIR/cluster.ini"
    local master_ini="$CLUSTER_DIR/Master/server.ini"
    local caves_ini="$CLUSTER_DIR/Caves/server.ini"

    if [ ! -f "$cluster_ini" ]; then
        print_error "集群配置文件不存在: $cluster_ini"
        pause
        return
    fi

    # 通用 INI 读取函数
    read_ini_val() {
        local rkey="$1"
        local rfile="$2"
        grep -E "^[[:space:]]*${rkey}[[:space:]]*=" "$rfile" 2>/dev/null | head -1 | sed -E 's/^[[:space:]]*'"${rkey}"'[[:space:]]*=[[:space:]]*//' | sed -E 's/[[:space:]]*$//'
    }

    # 读取所有配置
    local cluster_name_val
    cluster_name_val=$(read_ini_val "cluster_name" "$cluster_ini")
    local cluster_pwd_val
    cluster_pwd_val=$(read_ini_val "cluster_password" "$cluster_ini")
    local game_mode_val
    game_mode_val=$(read_ini_val "game_mode" "$cluster_ini")
    local max_players_val
    max_players_val=$(read_ini_val "max_players" "$cluster_ini")
    local pvp_val
    pvp_val=$(read_ini_val "pvp" "$cluster_ini")
    local pause_val
    pause_val=$(read_ini_val "pause_when_empty" "$cluster_ini")
    local lang_val
    lang_val=$(read_ini_val "cluster_language" "$cluster_ini")
    local offline_val
    offline_val=$(read_ini_val "offline_cluster" "$cluster_ini")
    local lan_val
    lan_val=$(read_ini_val "lan_only_cluster" "$cluster_ini")
    local console_val
    console_val=$(read_ini_val "console_enabled" "$cluster_ini")
    local shard_val
    shard_val=$(read_ini_val "shard_enabled" "$cluster_ini")
    local master_port_val
    master_port_val=$(read_ini_val "master_port" "$cluster_ini")

    # 读取 Master 端口（如果 cluster.ini 没有）
    if [ -z "$master_port_val" ] && [ -f "$master_ini" ]; then
        master_port_val=$(read_ini_val "server_port" "$master_ini")
    fi

    # 默认值
    cluster_name_val="${cluster_name_val:-(未设置)}"
    game_mode_val="${game_mode_val:-survival}"
    max_players_val="${max_players_val:-6}"
    pvp_val="${pvp_val:-false}"
    pause_val="${pause_val:-true}"
    lang_val="${lang_val:-zh}"
    offline_val="${offline_val:-false}"
    lan_val="${lan_val:-false}"
    console_val="${console_val:-true}"
    shard_val="${shard_val:-true}"
    master_port_val="${master_port_val:-10889}"

    # 转换为中文显示
    local pvp_cn="关闭"
    [ "$pvp_val" = "true" ] && pvp_cn="开启"
    local pause_cn="关闭"
    [ "$pause_val" = "true" ] && pause_cn="开启"
    local offline_cn="否"
    [ "$offline_val" = "true" ] && offline_cn="是"
    local lan_cn="否"
    [ "$lan_val" = "true" ] && lan_cn="是"
    local console_cn="关闭"
    [ "$console_val" = "true" ] && console_cn="开启"
    local shard_cn="关闭"
    [ "$shard_val" = "true" ] && shard_cn="开启"

    # 语言映射
    local lang_cn="$lang_val"
    case "$lang_val" in
        zh) lang_cn="中文" ;;
        en) lang_cn="英文" ;;
        *) lang_cn="$lang_val" ;;
    esac

    # 游戏模式映射
    local mode_cn="$game_mode_val"
    case "$game_mode_val" in
        survival) mode_cn="survival (生存)" ;;
        endless) mode_cn="endless (无尽)" ;;
        wilderness) mode_cn="wilderness (荒野)" ;;
    esac

    echo -e "${CYAN}========================${NC}"
    echo -e "${WHITE}${BOLD}  当前集群${NC}"
    echo -e "${CYAN}========================${NC}"
    echo ""
    echo -e "  集群名称：     ${CYAN}${cluster_name_val}${NC}"
    echo -e "  服务器密码：   ${CYAN}${cluster_pwd_val:-(无)}${NC}"
    echo -e "  游戏模式：     ${CYAN}${mode_cn}${NC}"
    echo -e "  最大人数：     ${CYAN}${max_players_val}${NC}"
    echo -e "  暂停：         ${CYAN}${pause_cn}${NC}"
    echo -e "  PVP：          ${CYAN}${pvp_cn}${NC}"
    echo -e "  语言：         ${CYAN}${lang_cn}${NC}"
    echo -e "  离线：         ${CYAN}${offline_cn}${NC}"
    echo -e "  LAN：          ${CYAN}${lan_cn}${NC}"
    echo -e "  Console：      ${CYAN}${console_cn}${NC}"
    echo -e "  Shard：        ${CYAN}${shard_cn}${NC}"
    echo -e "  Master Port：  ${CYAN}${master_port_val}${NC}"
    echo ""
    echo -e "${CYAN}========================${NC}"

    pause
}

# ========================================
# 存档管理功能
# ========================================

backup_save() {
    print_banner
    print_section "备份当前存档"

    if ! check_cluster_exists; then
        pause
        return
    fi

    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR"
    fi

    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_file="$BACKUP_DIR/${CLUSTER_NAME}_${timestamp}.tar.gz"

    print_info "正在备份集群: $CLUSTER_NAME"
    print_hint "源目录: $CLUSTER_DIR"
    print_hint "目标: $backup_file"
    echo ""

    if server_is_running; then
        print_warn "服务器正在运行，建议先停止服务器再备份"
        if ! confirm "是否继续备份 (可能不完整)?"; then
            pause
            return
        fi
    fi

    cd "$KLEI_ROOT"

    if tar -zcf "$backup_file" "$CLUSTER_NAME"; then
        local size
        size=$(du -h "$backup_file" | cut -f1)
        echo ""
        print_success "备份完成!"
        echo -e "  文件: $(basename "$backup_file")"
        echo -e "  大小: $size"
    else
        print_error "备份失败"
    fi

    pause
}

restore_backup() {
    print_banner
    print_section "从备份恢复"

    if [ ! -d "$BACKUP_DIR" ]; then
        print_error "备份目录不存在"
        pause
        return
    fi

    local backups=("$BACKUP_DIR"/*.tar.gz)
    if [ ! -e "${backups[0]}" ]; then
        print_warn "没有找到备份文件"
        pause
        return
    fi

    # 收集备份列表
    local backup_list=()
    local backup_files=()
    for backup in "${backups[@]}"; do
        [ -f "$backup" ] || continue
        local size
        size=$(du -h "$backup" | cut -f1)
        local date
        date=$(get_file_mtime "$backup")
        backup_list+=("$(basename "$backup")  [${size}]  ${date}")
        backup_files+=("$backup")
    done

    if [ ${#backup_list[@]} -eq 0 ]; then
        print_warn "没有备份文件"
        pause
        return
    fi

    # 交互式选择
    select_menu "选择要恢复的备份:" "${backup_list[@]}"

    # ESC 返回
    if [ "$SELECTED_INDEX" -eq -1 ]; then
        return
    fi

    local selected_backup="${backup_files[$SELECTED_INDEX]}"
    local backup_basename
    backup_basename=$(basename "$selected_backup")

    echo ""
    print_warn "即将恢复: $backup_basename"
    print_warn "这将覆盖当前集群数据!"

    if ! confirm "输入 yes 确认恢复?"; then
        print_info "已取消"
        pause
        return
    fi

    # 从备份文件名推断集群名
    local restore_cluster
    restore_cluster=$(echo "$backup_basename" | sed 's/_[0-9]\{8\}_[0-9]\{6\}\.tar\.gz$//')

    if [ -z "$restore_cluster" ]; then
        restore_cluster="$CLUSTER_NAME"
    fi

    local restore_dir="$KLEI_ROOT/$restore_cluster"

    echo ""
    print_info "正在恢复到: $restore_cluster"

    # 先停服
    if server_is_running; then
        print_info "服务器运行中，先停止..."
        force_stop_server_process "Master"
        force_stop_server_process "Caves"
        sleep 3
    fi

    # 安全措施：备份当前存档
    if [ -d "$restore_dir" ]; then
        local pre_backup="$BACKUP_DIR/pre_restore_$(date +"%Y%m%d_%H%M%S").tar.gz"
        cd "$KLEI_ROOT"
        tar -zcf "$pre_backup" "$restore_cluster"
        print_hint "已备份当前存档: $(basename "$pre_backup")"
    fi

    # 执行恢复
    rm -rf "$restore_dir"
    cd "$KLEI_ROOT"

    if tar -zxf "$selected_backup"; then
        print_success "恢复完成!"

        if [ "$restore_cluster" = "$CLUSTER_NAME" ]; then
            print_info "已恢复到当前集群"
        else
            if confirm "是否切换到恢复的集群?"; then
                set_current_cluster "$restore_cluster"
            fi
        fi
    else
        print_error "恢复失败"
    fi

    pause
}

list_backups() {
    print_banner
    print_section "备份列表"

    if [ ! -d "$BACKUP_DIR" ]; then
        print_warn "备份目录不存在"
        pause
        return
    fi

    local backups=("$BACKUP_DIR"/*.tar.gz)
    if [ ! -e "${backups[0]}" ]; then
        print_warn "没有备份文件"
        pause
        return
    fi

    local total_size=0
    local count=0

    for backup in "${backups[@]}"; do
        [ -f "$backup" ] || continue
        count=$((count + 1))
        local size
        size=$(du -h "$backup" | cut -f1)
        local raw_size
        raw_size=$(get_file_size "$backup")
        local date
        date=$(get_file_mtime "$backup")
        total_size=$((total_size + raw_size))

        echo -e "  ${WHITE}$(basename "$backup")${NC}"
        echo -e "    ${GRAY}日期: $date  大小: $size${NC}"
        echo ""
    done

    local total_human
    total_human=$(echo "$total_size" | awk '{printf "%.2f MB", $1/1024/1024}')

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  总计: $count 个备份, $total_human"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    pause
}

# ========================================
# 模组管理功能
# ========================================

# 在 modoverrides.lua 中启用模组（同时更新 Master 和 Caves）
enable_mod_in_cluster() {
    local mod_id="$1"
    for mod_file in "$MOD_OVERRIDE_MASTER" "$MOD_OVERRIDE_CAVES"; do
        ensure_modoverrides "$mod_file"
        backup_modoverrides "$mod_file"
        if grep -q "\"workshop-$mod_id\"" "$mod_file" 2>/dev/null; then
            set_mod_enabled "$mod_file" "$mod_id" "true"
        else
            add_mod_node "$mod_file" "$mod_id"
        fi
    done
}

# 在 modoverrides.lua 中禁用模组
disable_mod_in_cluster() {
    local mod_id="$1"
    for mod_file in "$MOD_OVERRIDE_MASTER" "$MOD_OVERRIDE_CAVES"; do
        if [ -f "$mod_file" ] && grep -q "\"workshop-$mod_id\"" "$mod_file" 2>/dev/null; then
            backup_modoverrides "$mod_file"
            set_mod_enabled "$mod_file" "$mod_id" "false"
        fi
    done
}

# 从 modoverrides.lua 中完全移除模组条目
remove_mod_from_cluster() {
    local mod_id="$1"
    for mod_file in "$MOD_OVERRIDE_MASTER" "$MOD_OVERRIDE_CAVES"; do
        if [ -f "$mod_file" ] && grep -q "\"workshop-$mod_id\"" "$mod_file" 2>/dev/null; then
            backup_modoverrides "$mod_file"
            remove_mod_node "$mod_file" "$mod_id"
        fi
    done
}

# 添加模组到当前集群（通过 modoverrides.lua）
add_mod() {
    print_banner
    print_section "添加模组到当前集群"

    if ! check_cluster_exists; then
        pause
        return
    fi

    read -rp "请输入模组 ID (Steam Workshop ID): " mod_id

    if [ -z "$mod_id" ] || ! echo "$mod_id" | grep -qE '^[0-9]+$'; then
        print_error "无效的模组 ID"
        pause
        return
    fi

    enable_mod_in_cluster "$mod_id"
    print_success "已启用模组: workshop-$mod_id"

    # 检查仓库是否有该模组
    local found_repo=0
    for dir in "$MOD_IMPORT_DIR"/${mod_id}*/; do
        [ -d "$dir" ] || continue
        found_repo=1
        break
    done
    if [ "$found_repo" -eq 0 ]; then
        print_warn "仓库中未找到该模组，请确保已将模组文件导入到 mods/workshop-$mod_id"
    fi

    echo ""
    print_hint "重启服务器后模组生效"

    pause
}

# 从当前集群移除模组
remove_mod() {
    print_banner
    print_section "从当前集群移除模组"

    if ! check_cluster_exists; then
        pause
        return
    fi

    # 读取当前启用的模组列表
    local override_file="$MOD_OVERRIDE_MASTER"
    [ ! -f "$override_file" ] && override_file="$MOD_OVERRIDE_CAVES"

    if [ ! -f "$override_file" ]; then
        print_warn "当前集群没有模组配置"
        pause
        return
    fi

    local mod_ids=()
    while IFS= read -r line; do
        local id
        id=$(echo "$line" | grep -oE '[0-9]+')
        [ -n "$id" ] && mod_ids+=("$id")
    done < <(grep -oE '"workshop-[0-9]+"' "$override_file" 2>/dev/null | sort -u)

    if [ ${#mod_ids[@]} -eq 0 ]; then
        print_warn "当前集群没有已启用的模组"
        pause
        return
    fi

    # 构建显示列表
    local display_list=()
    for id in "${mod_ids[@]}"; do
        local name=""
        for dir in "$MOD_IMPORT_DIR"/${id}*/; do
            [ -d "$dir" ] || continue
            name=$(get_repo_display_name "$(basename "$dir")")
            break
        done
        if [ -n "$name" ] && [ "$name" != "(未命名)" ]; then
            display_list+=("$name ($id)")
        else
            display_list+=("$id")
        fi
    done

    select_menu "选择要移除的模组:" "${display_list[@]}"
    if [ "$SELECTED_INDEX" -eq -1 ]; then
        return
    fi

    local selected_id="${mod_ids[$SELECTED_INDEX]}"
    remove_mod_from_cluster "$selected_id"
    print_success "已从集群移除: workshop-$selected_id"

    echo ""
    print_hint "重启服务器后生效"

    pause
}

# 查看当前集群已启用模组（Lua 块解析）
list_enabled_mods() {
    print_banner
    print_section "当前集群已启用模组"

    if ! check_cluster_exists; then
        pause
        return
    fi

    # 优先读取 Master，不存在则读 Caves
    local override_file="$MOD_OVERRIDE_MASTER"
    [ ! -f "$override_file" ] && override_file="$MOD_OVERRIDE_CAVES"

    if [ ! -f "$override_file" ]; then
        print_warn "当前集群没有模组配置文件"
        pause
        return
    fi

    echo -e "${WHITE}当前集群：${CYAN}$CLUSTER_NAME${NC}"
    echo ""
    echo -e "${CYAN}========================${NC}"

    local count=0
    while IFS= read -r line; do
        local id
        id=$(echo "$line" | grep -oE '[0-9]+')
        [ -z "$id" ] && continue

        # 使用 Lua 解析获取 enabled 状态
        local enabled_val
        enabled_val=$(get_mod_enabled "$override_file" "$id")
        local enabled=0
        [ "$enabled_val" = "true" ] && enabled=1

        # 从仓库获取显示名
        local display_name=""
        for dir in "$MOD_IMPORT_DIR"/${id}*/; do
            [ -d "$dir" ] || continue
            display_name=$(get_repo_display_name "$(basename "$dir")")
            break
        done

        local status_icon="${RED}×${NC}"
        [ "$enabled" -eq 1 ] && status_icon="${GREEN}✓${NC}"

        if [ -n "$display_name" ] && [ "$display_name" != "(未命名)" ]; then
            echo -e "  $status_icon ${WHITE}$display_name${NC}"
            echo -e "    Workshop：${GRAY}$id${NC}"
        else
            echo -e "  $status_icon ${WHITE}$id${NC} ${GRAY}(仓库缺失)${NC}"
        fi

        # 显示配置参数
        local config_kv
        config_kv=$(get_mod_config_kv "$override_file" "$id")
        if [ -n "$config_kv" ]; then
            echo -e "    参数："
            echo "$config_kv" | while IFS= read -r kv; do
                local key="${kv%%=*}"
                local val="${kv#*=}"
                echo -e "      ${GRAY}$key${NC} = ${CYAN}$val${NC}"
            done
        fi

        echo ""
        count=$((count + 1))
    done < <(grep -oE '"workshop-[0-9]+"' "$override_file" 2>/dev/null | sort -u)

    if [ "$count" -eq 0 ]; then
        echo -e "  ${GRAY}(无已启用模组)${NC}"
    fi

    echo -e "${CYAN}========================${NC}"

    pause
}

# 批量导入模组（第十二部分重写）
batch_import_mods() {
    print_banner
    print_section "批量导入模组"

    if ! check_cluster_exists; then
        pause
        return
    fi

    if [ ! -d "$MOD_IMPORT_DIR" ]; then
        mkdir -p "$MOD_IMPORT_DIR"
        print_info "已创建仓库目录: $MOD_IMPORT_DIR"
    fi

    echo ""
    print_info "模组仓库: $MOD_IMPORT_DIR"
    print_hint "规则：目录名前面的数字为 Workshop ID，如 294123456_几何布局"
    echo ""

    # 扫描仓库目录
    local mod_dirs=()
    for src_dir in "$MOD_IMPORT_DIR"/*/; do
        [ -d "$src_dir" ] || continue
        local folder_name
        folder_name=$(basename "$src_dir")
        local mod_id
        mod_id=$(get_repo_mod_id "$folder_name")
        if [ -n "$mod_id" ]; then
            mod_dirs+=("$mod_id:$folder_name:$src_dir")
        fi
    done

    if [ ${#mod_dirs[@]} -eq 0 ]; then
        print_warn "仓库中未找到可导入的模组文件夹"
        pause
        return
    fi

    echo -e "${WHITE}识别到 ${#mod_dirs[@]} 个模组:${NC}"
    echo ""
    local i=0
    for item in "${mod_dirs[@]}"; do
        i=$((i + 1))
        local mod_id="${item%%:*}"
        local rest="${item#*:}"
        local folder_name="${rest%%:*}"
        local display_name
        display_name=$(get_repo_display_name "$folder_name")

        # 检查完整性
        local src_dir="${rest#*:}"
        local status="${GREEN}完整${NC}"
        if ! check_mod_complete "$src_dir"; then
            case $? in
                1) status="${RED}缺少 modinfo.lua${NC}" ;;
                2) status="${RED}缺少 modmain.lua${NC}" ;;
            esac
        fi

        echo -e "  ${CYAN}$i.${NC} $display_name ${GRAY}($mod_id)${NC}  $status"
    done

    echo ""
    if ! confirm "确认导入这些模组到服务器?"; then
        pause
        return
    fi

    echo ""
    print_info "开始导入..."

    # 全局覆盖策略
    local global_overwrite=0
    local global_skip=0
    local success=0
    local skipped=0
    local failed=0

    for item in "${mod_dirs[@]}"; do
        local mod_id="${item%%:*}"
        local rest="${item#*:}"
        local folder_name="${rest%%:*}"
        local src_dir="${rest#*:}"
        local display_name
        display_name=$(get_repo_display_name "$folder_name")
        local target_name="workshop-$mod_id"
        local target_dir="$MODS_DIR/$target_name"

        # 完整性检查
        if ! check_mod_complete "$src_dir"; then
            local reason=""
            case $? in
                1) reason="缺少 modinfo.lua" ;;
                2) reason="缺少 modmain.lua" ;;
            esac
            echo -e "  ${RED}失败${NC}: $display_name ($mod_id) — $reason"
            failed=$((failed + 1))
            continue
        fi

        # 覆盖检查
        if [ -d "$target_dir" ]; then
            if [ "$global_skip" -eq 1 ]; then
                echo -e "  ${GRAY}跳过${NC}: $target_name 已存在"
                skipped=$((skipped + 1))
                continue
            fi
            if [ "$global_overwrite" -eq 1 ]; then
                rm -rf "$target_dir"
            else
                echo ""
                print_warn "发现服务器已存在: $display_name ($mod_id)"
                echo -e "  1. 覆盖导入（推荐）"
                echo -e "  2. 跳过"
                echo -e "  3. 全部覆盖"
                echo -e "  4. 全部跳过"
                read -rp "请选择 [1-4]: " overwrite_choice
                case "$overwrite_choice" in
                    1) rm -rf "$target_dir" ;;
                    2)
                        echo -e "  ${GRAY}跳过${NC}: $target_name"
                        skipped=$((skipped + 1))
                        continue
                        ;;
                    3)
                        global_overwrite=1
                        rm -rf "$target_dir"
                        ;;
                    4)
                        global_skip=1
                        echo -e "  ${GRAY}跳过${NC}: $target_name"
                        skipped=$((skipped + 1))
                        continue
                        ;;
                    *)
                        rm -rf "$target_dir"
                        ;;
                esac
            fi
        fi

        # 复制
        mkdir -p "$MODS_DIR"
        cp -r "$src_dir" "$target_dir"
        echo -e "  ${GREEN}成功${NC}: $display_name → $target_name"
        success=$((success + 1))

        # 自动在当前集群启用
        enable_mod_in_cluster "$mod_id"
    done

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  成功: ${GREEN}$success${NC}  跳过: ${GRAY}$skipped${NC}  失败: ${RED}$failed${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    print_hint "操作完成，重启服务器模组生效"
    pause
}

# 模组仓库管理菜单
manage_mod_repo() {
    while true; do
        print_banner
        print_section "模组仓库管理"

        if [ ! -d "$MOD_IMPORT_DIR" ]; then
            mkdir -p "$MOD_IMPORT_DIR"
            print_info "已创建仓库目录: $MOD_IMPORT_DIR"
        fi

        local options=(
            "查看仓库模组"
            "重命名模组备注"
            "删除仓库模组"
            "模组完整性检查"
            "返回"
        )

        select_menu "请选择操作:" "${options[@]}"
        local choice=$SELECTED_INDEX

        if [ "$choice" -eq -1 ] || [ "$choice" -eq 4 ]; then
            break
        fi

        case "$choice" in
            0) list_repo_mods ;;
            1) rename_repo_mod ;;
            2) delete_repo_mod ;;
            3) check_mod_repo_integrity ;;
        esac
    done
}

# 查看仓库模组列表
list_repo_mods() {
    print_banner
    print_section "模组仓库"

    if [ ! -d "$MOD_IMPORT_DIR" ]; then
        print_warn "仓库目录不存在: $MOD_IMPORT_DIR"
        pause
        return
    fi

    local count=0
    for dir in "$MOD_IMPORT_DIR"/*/; do
        [ -d "$dir" ] || continue
        local folder_name
        folder_name=$(basename "$dir")
        local mod_id
        mod_id=$(get_repo_mod_id "$folder_name")

        if [ -z "$mod_id" ]; then
            echo -e "  ${RED}×${NC} $folder_name ${GRAY}(名称格式错误)${NC}"
            count=$((count + 1))
            continue
        fi

        local display_name
        display_name=$(get_repo_display_name "$folder_name")

        # 完整性
        local status="${GREEN}完整${NC}"
        if ! check_mod_complete "$dir"; then
            case $? in
                1) status="${RED}缺少 modinfo.lua${NC}" ;;
                2) status="${RED}缺少 modmain.lua${NC}" ;;
            esac
        fi

        echo -e "  ${GREEN}●${NC} ${WHITE}$mod_id${NC}  $display_name  $status"
        count=$((count + 1))
    done

    if [ "$count" -eq 0 ]; then
        print_warn "仓库为空"
    fi

    echo ""
    print_hint "仓库目录: $MOD_IMPORT_DIR"

    pause
}

# 重命名模组备注
rename_repo_mod() {
    print_banner
    print_section "重命名模组备注"

    # 收集仓库中的模组
    local mod_folders=()
    local mod_names=()
    for dir in "$MOD_IMPORT_DIR"/*/; do
        [ -d "$dir" ] || continue
        local folder_name
        folder_name=$(basename "$dir")
        local mod_id
        mod_id=$(get_repo_mod_id "$folder_name")
        [ -z "$mod_id" ] && continue
        local display_name
        display_name=$(get_repo_display_name "$folder_name")
        mod_folders+=("$folder_name")
        mod_names+=("$mod_id - $display_name")
    done

    if [ ${#mod_folders[@]} -eq 0 ]; then
        print_warn "仓库中没有可操作的模组"
        pause
        return
    fi

    select_menu "选择要重命名的模组:" "${mod_names[@]}"
    if [ "$SELECTED_INDEX" -eq -1 ]; then
        return
    fi

    local selected_folder="${mod_folders[$SELECTED_INDEX]}"
    local mod_id
    mod_id=$(get_repo_mod_id "$selected_folder")
    local old_name
    old_name=$(get_repo_mod_name "$selected_folder")

    echo ""
    echo -e "当前备注: ${CYAN}${old_name:-(无)}${NC}"
    read -rp "输入新的备注名 (留空则清除备注): " new_name

    local new_folder="$mod_id"
    if [ -n "$new_name" ]; then
        new_folder="${mod_id}_${new_name}"
    fi

    if [ "$new_folder" = "$selected_folder" ]; then
        print_info "名称未变化"
        pause
        return
    fi

    if [ -d "$MOD_IMPORT_DIR/$new_folder" ]; then
        print_error "目标已存在: $new_folder"
        pause
        return
    fi

    mv "$MOD_IMPORT_DIR/$selected_folder" "$MOD_IMPORT_DIR/$new_folder"
    print_success "已重命名为: $new_folder"

    pause
}

# 删除仓库模组
delete_repo_mod() {
    print_banner
    print_section "删除仓库模组"

    local mod_folders=()
    local mod_names=()
    for dir in "$MOD_IMPORT_DIR"/*/; do
        [ -d "$dir" ] || continue
        local folder_name
        folder_name=$(basename "$dir")
        local mod_id
        mod_id=$(get_repo_mod_id "$folder_name")
        [ -z "$mod_id" ] && continue
        local display_name
        display_name=$(get_repo_display_name "$folder_name")
        mod_folders+=("$folder_name")
        mod_names+=("$mod_id - $display_name")
    done

    if [ ${#mod_folders[@]} -eq 0 ]; then
        print_warn "仓库中没有可删除的模组"
        pause
        return
    fi

    select_menu "选择要删除的模组（仅删除仓库，不影响已导入的服务器MOD）:" "${mod_names[@]}"
    if [ "$SELECTED_INDEX" -eq -1 ]; then
        return
    fi

    local selected_folder="${mod_folders[$SELECTED_INDEX]}"
    local selected_name="${mod_names[$SELECTED_INDEX]}"

    echo ""
    print_warn "即将删除仓库中的: $selected_name"
    print_hint "此操作不会影响服务器 mods/ 目录中已导入的模组"

    if ! confirm "确认删除?"; then
        return
    fi

    rm -rf "$MOD_IMPORT_DIR/$selected_folder"
    print_success "已删除: $selected_folder"

    pause
}

# 模组完整性检查
check_mod_repo_integrity() {
    print_banner
    print_section "模组仓库完整性检查"

    if [ ! -d "$MOD_IMPORT_DIR" ]; then
        print_warn "仓库目录不存在: $MOD_IMPORT_DIR"
        pause
        return
    fi

    echo -e "${CYAN}========================${NC}"
    echo -e "${WHITE}${BOLD}  模组仓库检查结果${NC}"
    echo -e "${CYAN}========================${NC}"
    echo ""

    local total=0
    local ok=0
    local warn=0
    local err=0

    for dir in "$MOD_IMPORT_DIR"/*/; do
        [ -d "$dir" ] || continue
        local folder_name
        folder_name=$(basename "$dir")
        total=$((total + 1))

        local mod_id
        mod_id=$(get_repo_mod_id "$folder_name")

        # 检查名称格式
        if [ -z "$mod_id" ]; then
            echo -e "  ${RED}×${NC} $folder_name  ${RED}目录名称格式错误${NC}"
            err=$((err + 1))
            continue
        fi

        local display_name
        display_name=$(get_repo_display_name "$folder_name")

        # 检查完整性
        if check_mod_complete "$dir"; then
            echo -e "  ${GREEN}√${NC} $display_name ${GRAY}($mod_id)${NC}  ${GREEN}完整${NC}"
            ok=$((ok + 1))
        else
            local reason=""
            case $? in
                1) reason="缺少 modinfo.lua" ;;
                2) reason="缺少 modmain.lua" ;;
            esac
            echo -e "  ${RED}×${NC} $display_name ${GRAY}($mod_id)${NC}  ${RED}$reason${NC}"
            err=$((err + 1))
        fi
    done

    if [ "$total" -eq 0 ]; then
        print_warn "仓库为空"
    else
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  总计: $total  完整: ${GREEN}$ok${NC}  异常: ${RED}$err${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    fi

    pause
}

# 管理当前集群模组（第十四部分：批量启用/关闭）
# 管理单个模组的参数
edit_mod_params() {
    local override_file="$1"
    local mod_id="$2"
    local display_name="$3"

    while true; do
        print_banner
        print_section "修改模组参数: $display_name"

        # 获取配置参数
        local config_kv
        config_kv=$(get_mod_config_kv "$override_file" "$mod_id")

        if [ -z "$config_kv" ]; then
            print_info "该模组没有可配置参数 (configuration_options={})"
            pause
            return
        fi

        # 解析参数列表
        local param_keys=()
        local param_vals=()
        while IFS= read -r kv; do
            [ -z "$kv" ] && continue
            local key="${kv%%=*}"
            local val="${kv#*=}"
            param_keys+=("$key")
            param_vals+=("$val")
        done <<< "$config_kv"

        # 显示参数列表
        local i=0
        while [ "$i" -lt "${#param_keys[@]}" ]; do
            echo -e "  ${CYAN}$((i + 1)).${NC} ${WHITE}${param_keys[$i]}${NC} = ${CYAN}${param_vals[$i]}${NC}"
            i=$((i + 1))
        done

        echo ""
        echo -e "${GRAY}  输入序号修改参数  输入 0 返回${NC}"
        echo ""
        read -rp "请选择: " param_choice

        if [ "$param_choice" = "0" ] || [ -z "$param_choice" ]; then
            return
        fi

        if ! echo "$param_choice" | grep -qE '^[0-9]+$' || [ "$param_choice" -lt 1 ] || [ "$param_choice" -gt "${#param_keys[@]}" ]; then
            print_error "无效选择"
            pause
            continue
        fi

        local pidx=$((param_choice - 1))
        local pkey="${param_keys[$pidx]}"
        local pval="${param_vals[$pidx]}"

        echo ""
        echo -e "当前值: ${CYAN}$pval${NC}"
        read -rp "输入新值: " new_val

        if [ -z "$new_val" ]; then
            print_warn "值不能为空"
            pause
            continue
        fi

        # 处理值类型（布尔值不加引号，数字不加引号，字符串加引号）
        local formatted_val="$new_val"
        if [ "$new_val" = "true" ] || [ "$new_val" = "false" ]; then
            formatted_val="$new_val"
        elif echo "$new_val" | grep -qE '^[0-9]+$'; then
            formatted_val="$new_val"
        else
            formatted_val="\"$new_val\""
        fi

        backup_modoverrides "$override_file"
        set_mod_config_value "$override_file" "$mod_id" "$pkey" "$formatted_val"

        print_success "已修改: $pkey = $new_val"
        sleep 1
    done
}

manage_cluster_mods() {
    if ! check_cluster_exists; then
        pause
        return
    fi

    while true; do
        print_banner
        print_section "管理当前集群模组: $CLUSTER_NAME"

        # 读取 modoverrides.lua
        local override_file="$MOD_OVERRIDE_MASTER"
        [ ! -f "$override_file" ] && override_file="$MOD_OVERRIDE_CAVES"

        if [ ! -f "$override_file" ]; then
            print_warn "当前集群没有模组配置文件"
            pause
            return
        fi

        # 使用 Lua 解析获取所有模组及状态
        local mod_ids=()
        local mod_enabled=()
        while IFS= read -r line; do
            local id
            id=$(echo "$line" | grep -oE '[0-9]+')
            [ -z "$id" ] && continue
            mod_ids+=("$id")

            local enabled_val
            enabled_val=$(get_mod_enabled "$override_file" "$id")
            if [ "$enabled_val" = "true" ]; then
                mod_enabled+=(1)
            else
                mod_enabled+=(0)
            fi
        done < <(grep -oE '"workshop-[0-9]+"' "$override_file" 2>/dev/null | sort -u)

        if [ ${#mod_ids[@]} -eq 0 ]; then
            print_warn "当前集群没有已配置的模组"
            echo ""
            print_hint "请先使用 [导入模组] 或手动添加模组"
            pause
            return
        fi

        # 显示列表
        echo -e "${WHITE}选择序号查看/修改模组:${NC}"
        echo ""
        local i=0
        while [ "$i" -lt "${#mod_ids[@]}" ]; do
            local id="${mod_ids[$i]}"
            local en="${mod_enabled[$i]}"

            # 获取显示名
            local display_name=""
            for dir in "$MOD_IMPORT_DIR"/${id}*/; do
                [ -d "$dir" ] || continue
                display_name=$(get_repo_display_name "$(basename "$dir")")
                break
            done

            local status_icon="${RED}×${NC}"
            [ "$en" -eq 1 ] && status_icon="${GREEN}✓${NC}"

            if [ -n "$display_name" ] && [ "$display_name" != "(未命名)" ]; then
                echo -e "  ${CYAN}$((i + 1)).${NC} $status_icon $display_name ${GRAY}($id)${NC}"
            else
                echo -e "  ${CYAN}$((i + 1)).${NC} $status_icon $id"
            fi
            i=$((i + 1))
        done

        echo ""
        echo -e "${GRAY}  输入序号进入模组操作  输入 0 返回${NC}"
        echo ""
        read -rp "请选择: " mod_choice

        if [ "$mod_choice" = "0" ] || [ -z "$mod_choice" ]; then
            break
        fi

        if ! echo "$mod_choice" | grep -qE '^[0-9]+$' || [ "$mod_choice" -lt 1 ] || [ "$mod_choice" -gt "${#mod_ids[@]}" ]; then
            print_error "无效选择"
            pause
            continue
        fi

        local idx=$((mod_choice - 1))
        local target_id="${mod_ids[$idx]}"
        local current_en="${mod_enabled[$idx]}"

        # 获取显示名
        local target_name=""
        for dir in "$MOD_IMPORT_DIR"/${target_id}*/; do
            [ -d "$dir" ] || continue
            target_name=$(get_repo_display_name "$(basename "$dir")")
            break
        done
        [ -z "$target_name" ] || [ "$target_name" = "(未命名)" ] && target_name="$target_id"

        # 子菜单：模组操作
        while true; do
            print_banner
            print_section "模组: $target_name (workshop-$target_id)"

            local en_text="${RED}已禁用${NC}"
            [ "$current_en" -eq 1 ] && en_text="${GREEN}已启用${NC}"
            echo -e "  状态: $en_text"
            echo ""

            local sub_options=(
                "切换启用/关闭"
                "修改模组参数"
                "从集群移除该模组"
                "返回"
            )

            select_menu "请选择操作:" "${sub_options[@]}"
            local sub_choice=$SELECTED_INDEX

            if [ "$sub_choice" -eq -1 ] || [ "$sub_choice" -eq 3 ]; then
                break
            fi

            case "$sub_choice" in
                0)
                    backup_modoverrides "$override_file"
                    if [ "$current_en" -eq 1 ]; then
                        set_mod_enabled "$override_file" "$target_id" "false"
                        current_en=0
                        print_success "已禁用: $target_name"
                    else
                        set_mod_enabled "$override_file" "$target_id" "true"
                        current_en=1
                        print_success "已启用: $target_name"
                    fi
                    echo ""
                    print_hint "重启服务器后生效"
                    pause
                    ;;
                1)
                    edit_mod_params "$override_file" "$target_id" "$target_name"
                    ;;
                2)
                    echo ""
                    print_warn "即将从集群移除: $target_name"
                    print_hint "此操作不会删除服务器 mods/ 目录中的模组文件"
                    if confirm "确认移除?"; then
                        backup_modoverrides "$override_file"
                        remove_mod_node "$override_file" "$target_id"
                        print_success "已移除: $target_name"
                        echo ""
                        print_hint "重启服务器后生效"
                        pause
                        break  # 返回上一级列表
                    fi
                    ;;
            esac
        done
    done
}

# ========================================
# 系统与网络功能
# ========================================

setup_firewall() {
    print_banner
    print_section "配置防火墙 (UFW)"

    if ! command -v ufw >/dev/null 2>&1; then
        print_error "ufw 未安装"
        print_info "请先运行: apt install -y ufw"
        pause
        return
    fi

    echo -e "${WHITE}当前防火墙状态:${NC}"
    ufw status numbered 2>/dev/null || true
    echo ""

    echo -e "${WHITE}DST 所需端口:${NC}"
    echo -e "  10999/udp  - Master 游戏端口"
    echo -e "  10998/udp  - Caves 游戏端口"
    echo -e "  27016/udp  - Master Steam 端口"
    echo -e "  27017/udp  - Caves Steam 端口"
    echo -e "  8766/udp   - Steam 认证端口"
    echo -e "  8767/udp   - Steam 认证端口"
    echo ""

    if ! confirm "是否放行这些端口?"; then
        pause
        return
    fi

    echo ""
    print_info "正在配置防火墙规则..."

    ufw allow 10999/udp
    ufw allow 10998/udp
    ufw allow 27016/udp
    ufw allow 27017/udp
    ufw allow 8766/udp
    ufw allow 8767/udp

    ufw reload

    echo ""
    print_success "防火墙配置完成"
    echo ""

    print_warn "阿里云用户注意：除了系统防火墙，还需要在阿里云控制台配置安全组"
    print_hint "1. 登录阿里云 ECS 控制台"
    print_hint "2. 进入实例 → 安全组 → 配置规则"
    print_hint "3. 入方向添加 UDP 10998-10999、27016-27017、8766-8767"
    print_hint "4. 授权对象: 0.0.0.0/0 (或指定你的IP)"

    pause
}

network_optimize() {
    print_banner
    print_section "网络优化"

    echo -e "${WHITE}优化内容:${NC}"
    echo -e "  - 增大 UDP 缓冲区 (64MB)"
    echo -e "  - 优化网络队列长度"
    echo -e "  - 提升 UDP 最小缓冲区"
    echo ""

    if ! confirm "是否应用网络优化?"; then
        pause
        return
    fi

    echo ""
    print_info "正在应用优化参数..."

    cat > /etc/sysctl.d/99-dst-network.conf <<'EOF'
# DST 服务器网络优化
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 67108864
net.core.wmem_default = 67108864
net.core.netdev_max_backlog = 5000
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
EOF

    sysctl -p /etc/sysctl.d/99-dst-network.conf

    echo ""
    print_success "网络优化参数已应用"
    print_hint "配置文件: /etc/sysctl.d/99-dst-network.conf"
    print_hint "优化后重启服务器生效"

    pause
}

# ========================================
# 一键初始化
# ========================================

auto_init() {
    print_banner
    print_section "一键初始化服务器"

    echo -e "${WHITE}将执行以下操作:${NC}"
    echo -e "  1. 更新系统软件包"
    echo -e "  2. 安装依赖 (screen, ufw, lib32gcc-s1 等)"
    echo -e "  3. 安装 SteamCMD"
    echo -e "  4. 下载 DST 专用服务器"
    echo -e "  5. 配置防火墙"
    echo -e "  6. 应用网络优化"
    echo ""

    print_warn "此操作需要 root 权限，预计耗时 10-30 分钟"

    if ! confirm "是否开始初始化?"; then
        pause
        return
    fi

    echo ""
    print_info "步骤 1/6: 更新系统..."
    apt update -y && apt upgrade -y
    print_success "系统更新完成"

    echo ""
    print_info "步骤 2/6: 安装依赖..."
    dpkg --add-architecture i386
    apt update -y
    apt install -y \
        screen \
        ufw \
        wget \
        curl \
        tar \
        gzip \
        lib32gcc-s1 \
        libstdc++6:i386 \
        libgcc-s1:i386 \
        libcurl4-gnutls-dev:i386
    print_success "依赖安装完成"

    echo ""
    print_info "步骤 3/6: 安装 SteamCMD..."

    mkdir -p /root/steamcmd
    cd /root/steamcmd

    if [ ! -f steamcmd.sh ]; then
        wget -q https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz
        tar -xzf steamcmd_linux.tar.gz
        rm steamcmd_linux.tar.gz
    fi

    print_success "SteamCMD 安装完成"

    echo ""
    print_info "步骤 4/6: 下载饥荒专用服务端（约 3-5GB，取决于网速）..."
    print_warn "下载时间取决于网络速度，请耐心等待"
    echo ""

    # 正确 SteamCMD 执行顺序：先指定安装目录，再匿名登录更新
    /root/steamcmd/steamcmd.sh \
        +force_install_dir "$SERVER_DIR" \
        +login anonymous \
        +app_update 343050 validate \
        +quit

    # 自动扫描刷新服务端路径、二进制程序
    detect_server_dir
    detect_binary
    init_paths

    # 校验二进制文件是否下载成功，失败自动重试一次
    if [ -z "$DEDICATED_SERVER_BINARY" ] || [ ! -x "$DEDICATED_SERVER_BINARY" ]; then
        print_warn "首次下载未完成，自动重试下载一次"
        /root/steamcmd/steamcmd.sh \
            +force_install_dir "$SERVER_DIR" \
            +login anonymous \
            +app_update 343050 validate \
            +quit
        detect_server_dir
        detect_binary
        init_paths
    fi

    # 最终校验，给出小白易懂提示
    if [ -z "$DEDICATED_SERVER_BINARY" ] || [ ! -x "$DEDICATED_SERVER_BINARY" ]; then
        print_error "服务端下载失败，请检查服务器外网网络后重新执行初始化"
    else
        print_success "饥荒服务端下载安装完成，目录：$SERVER_DIR"
    fi

    echo ""
    print_info "步骤 5/6: 配置防火墙..."

    ufw allow 22/tcp
    ufw allow 10999/udp
    ufw allow 10998/udp
    ufw allow 27016/udp
    ufw allow 27017/udp
    ufw allow 8766/udp
    ufw allow 8767/udp
    echo "y" | ufw enable
    ufw reload

    print_success "防火墙配置完成"

    echo ""
    print_info "步骤 6/6: 应用网络优化..."

    cat > /etc/sysctl.d/99-dst-network.conf <<'EOF'
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 67108864
net.core.wmem_default = 67108864
net.core.netdev_max_backlog = 5000
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
EOF
    sysctl -p /etc/sysctl.d/99-dst-network.conf

    print_success "网络优化完成"

    echo ""
    print_info "创建模组和集群导入目录..."
    mkdir -p "$MOD_IMPORT_DIR"
    mkdir -p "$CLUSTER_IMPORT_DIR"
    print_success "模组仓库目录: $MOD_IMPORT_DIR"
    print_success "集群导入目录: $CLUSTER_IMPORT_DIR"

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║       初始化全部完成!                ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${WHITE}下一步操作:${NC}"
    echo -e "  1. 创建或导入集群配置"
    echo -e "  2. 获取并配置 cluster_token.txt"
    echo -e "  3. 启动服务器"
    echo ""
    echo -e "${YELLOW}阿里云用户额外步骤:${NC}"
    echo -e "  还需在阿里云控制台安全组中放行 UDP 端口"
    echo -e "  端口: 10998-10999, 27016-27017, 8766-8767"

    pause
}

update_server() {
    print_banner
    print_section "更新服务器"

    if [ ! -f /root/steamcmd/steamcmd.sh ]; then
        print_error "未找到 SteamCMD"
        pause
        return
    fi

    if server_is_running; then
        print_warn "服务器正在运行，更新前请先停止"
        if ! confirm "是否停止服务器并更新?"; then
            pause
            return
        fi
        force_stop_server_process "Master"
        force_stop_server_process "Caves"
        sleep 3
    fi

    print_info "正在更新 DST 服务器..."
    echo ""

    /root/steamcmd/steamcmd.sh \
        +force_install_dir "$SERVER_DIR" \
        +login anonymous \
        +app_update 343050 validate \
        +quit

    echo ""
    print_success "更新完成"

    # 重新检测二进制
    detect_binary
    init_paths

    pause
}

# ========================================
# 主菜单
# ========================================

show_main_menu() {
    # 服务器状态摘要（使用日志层判断）
    local master_status="${RED}已停止${NC}"
    local caves_status="${RED}已停止${NC}"

    local master_state
    master_state=$(get_shard_status "Master")
    local caves_state
    caves_state=$(get_shard_status "Caves")

    case "$master_state" in
        running) master_status="${GREEN}运行中${NC}" ;;
        starting) master_status="${YELLOW}启动中${NC}" ;;
        no_screen) master_status="${YELLOW}Screen丢失${NC}" ;;
        crashed) master_status="${RED}已崩溃${NC}" ;;
        *) master_status="${RED}已停止${NC}" ;;
    esac

    case "$caves_state" in
        running) caves_status="${GREEN}运行中${NC}" ;;
        starting) caves_status="${YELLOW}启动中${NC}" ;;
        no_screen) caves_status="${YELLOW}Screen丢失${NC}" ;;
        crashed) caves_status="${RED}已崩溃${NC}" ;;
        *) caves_status="${RED}已停止${NC}" ;;
    esac

    echo -e "  当前集群：${WHITE}${BOLD}$CLUSTER_NAME${NC}"
    echo -e "  服务器：  Master $master_status  |  Caves $caves_status"
    echo ""
    echo -e "${CYAN}─────────────────────────────────────${NC}"

    echo -e "${YELLOW}【服务器】${NC}"
    echo -e "  ${CYAN} 1.${NC} 启动服务器"
    echo -e "  ${CYAN} 2.${NC} 停止服务器"
    echo -e "  ${CYAN} 3.${NC} 重启服务器"
    echo -e "  ${CYAN} 4.${NC} 服务器运行状态"
    echo -e "  ${CYAN} 5.${NC} 查看实时日志"
    echo -e "${CYAN}─────────────────────────────────────${NC}"

    echo -e "${YELLOW}【集群】${NC}"
    echo -e "  ${CYAN} 6.${NC} 当前集群信息"
    echo -e "  ${CYAN} 7.${NC} 查看集群配置"
    echo -e "  ${CYAN} 8.${NC} 切换集群"
    echo -e "  ${CYAN} 9.${NC} 创建集群"
    echo -e "  ${CYAN}10.${NC} 修改集群配置"
    echo -e "  ${CYAN}11.${NC} 导入集群"
    echo -e "${CYAN}─────────────────────────────────────${NC}"

    echo -e "${YELLOW}【模组】${NC}"
    echo -e "  ${CYAN}12.${NC} 管理模组仓库"
    echo -e "  ${CYAN}13.${NC} 导入模组"
    echo -e "  ${CYAN}14.${NC} 查看当前集群模组"
    echo -e "  ${CYAN}15.${NC} 管理当前集群模组"
    echo -e "${CYAN}─────────────────────────────────────${NC}"

    echo -e "${YELLOW}【备份】${NC}"
    echo -e "  ${CYAN}16.${NC} 备份集群"
    echo -e "  ${CYAN}17.${NC} 恢复备份"
    echo -e "  ${CYAN}18.${NC} 查看备份列表"
    echo -e "${CYAN}─────────────────────────────────────${NC}"

    echo -e "${YELLOW}【系统】${NC}"
    echo -e "  ${CYAN}19.${NC} 配置防火墙"
    echo -e "  ${CYAN}20.${NC} 网络优化"
    echo -e "  ${CYAN}21.${NC} 更新服务器"
    echo -e "  ${CYAN}22.${NC} 一键初始化"
    echo -e "${CYAN}─────────────────────────────────────${NC}"

    echo -e "  ${CYAN} 0.${NC} 退出工具箱"
    echo -e "${CYAN}═════════════════════════════════════${NC}"
}

main_loop() {
    while true; do
        print_banner

        # 自动异常检测（每次进入菜单时执行）
        if server_is_running; then
            auto_anomaly_check || true
        fi

        show_main_menu
        read -rp "请选择操作 (0-22): " choice

        case "$choice" in
            0)
                print_banner
                echo -e "${GREEN}感谢使用 DST 服务器管理工具箱!${NC}"
                echo -e "${GREEN}再见!${NC}"
                echo ""
                sleep 0.5
                exit 0
                ;;
            1) start_server ;;
            2) stop_server ;;
            3) restart_server ;;
            4) server_status ;;
            5) view_logs ;;
            6) view_cluster_config ;;
            7)
                print_banner
                print_section "集群列表"
                list_clusters
                pause
                ;;
            8) switch_cluster ;;
            9) create_cluster ;;
            10) edit_cluster_config ;;
            11) import_cluster ;;
            12) manage_mod_repo ;;
            13) batch_import_mods ;;
            14) list_enabled_mods ;;
            15) manage_cluster_mods ;;
            16) backup_save ;;
            17) restore_backup ;;
            18) list_backups ;;
            19) setup_firewall ;;
            20) network_optimize ;;
            21) update_server ;;
            22) auto_init ;;
            *)
                print_error "无效选择，请输入 0-22"
                pause
                ;;
        esac
    done
}

# ========================================
# 命令行参数支持
# ========================================

usage() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -c, --cluster <名称>    指定集群名称"
    echo "  -h, --help              显示帮助信息"
    echo "  start                   直接启动服务器"
    echo "  stop                    直接停止服务器"
    echo "  restart                 直接重启服务器"
    echo "  status                  查看服务器状态"
    echo "  backup                  备份当前存档"
    echo ""
    echo "示例:"
    echo "  $0                          # 启动菜单"
    echo "  $0 -c Cluster_2 start       # 指定集群启动"
    echo "  $0 stop                     # 停止服务器"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -c|--cluster)
                set_current_cluster "$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            start)
                init_paths
                start_server
                exit 0
                ;;
            stop)
                init_paths
                stop_server
                exit 0
                ;;
            restart)
                init_paths
                restart_server
                exit 0
                ;;
            status)
                init_paths
                server_status
                exit 0
                ;;
            backup)
                init_paths
                backup_save
                exit 0
                ;;
            *)
                echo "未知选项: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# ========================================
# 初始化
# ========================================

init() {
    # 加载上次集群
    load_last_cluster

    # 检测服务端路径
    if detect_server_dir; then
        detect_binary || true
    fi

    # 初始化路径
    init_paths

    # 验证当前集群是否存在，不存在则自动切换
    if [ ! -d "$CLUSTER_DIR" ]; then
        auto_detect_cluster || true
        init_paths
    fi

    # 解析命令行参数
    if [ $# -gt 0 ]; then
        parse_args "$@"
    fi
}

# 运行（无全局 trap）
init "$@"
main_loop
