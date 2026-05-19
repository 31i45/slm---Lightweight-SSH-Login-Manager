#!/bin/bash

# slm - 服务器登录管理器 (修复版)
# 功能: 远程主机信息CRUD与SSH免密登录
# 依赖: bash, awk, ssh, ssh-copy-id, column (均为Linux标准组件)

# ============================================================
# 配置
# ============================================================
readonly SLM_DIR="$HOME/.slm"
readonly SLM_FILE="$SLM_DIR/remotes.txt"
readonly SSH_KEY="$HOME/.ssh/id_rsa.pub"
readonly LOCK_DIR="$SLM_DIR/.lock"

# 字段分隔符: ASCII 31 (Unit Separator)
# 选择理由: 这是ASCII标准定义的字段分隔符，用户输入不可能包含
readonly FS=$'\x1f'

# ============================================================
# 原子锁 (mkdir原子操作，POSIX保证，零外部依赖)
# ============================================================
acquire_lock() {
    local timeout=${1:-10}
    local elapsed=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        ((elapsed++))
        [[ $elapsed -ge $timeout ]] && { echo "错误: 获取锁超时，可能有其他实例正在运行" >&2; return 1; }
        sleep 1
    done
    return 0
}

# 清理函数 (释放锁 + 清理临时文件)
cleanup() {
    rm -f "$SLM_FILE.tmp" 2>/dev/null
    rmdir "$LOCK_DIR" 2>/dev/null
}
trap cleanup EXIT

# ============================================================
# 初始化
# ============================================================
init() {
    # 创建目录
    [[ -d "$SLM_DIR" ]] || mkdir -p "$SLM_DIR" 2>/dev/null || { echo "错误: 无法创建 $SLM_DIR" >&2; return 1; }

    # 总是修复权限（即使目录/文件已存在）
    chmod 700 "$SLM_DIR" 2>/dev/null || { echo "错误: 无法设置目录权限" >&2; return 1; }

    # 创建数据文件
    if [[ ! -f "$SLM_FILE" ]]; then
        : > "$SLM_FILE" 2>/dev/null || { echo "错误: 无法创建 $SLM_FILE" >&2; return 1; }
    fi
    chmod 600 "$SLM_FILE" 2>/dev/null || { echo "错误: 无法设置文件权限" >&2; return 1; }

    # 确保文件以换行符结尾 (纯bash: 读取最后一个字节)
    if [[ -s "$SLM_FILE" ]]; then
        local last_byte
        read -r last_byte < <(tail -c 1 "$SLM_FILE" | od -An -tx1)
        [[ "${last_byte// /}" != "0a" ]] && echo >> "$SLM_FILE"
    fi

    return 0
}

# ============================================================
# 依赖检查 (只检查真正必须的外部命令)
# ============================================================
check_deps() {
    local dep
    for dep in ssh ssh-copy-id column; do
        command -v "$dep" >/dev/null 2>&1 || { echo "错误: 缺少 $dep" >&2; return 1; }
    done
    return 0
}

# ============================================================
# 输入验证 (纯bash，零外部进程)
# ============================================================
validate_ip() {
    local ip=$1
    [[ -z "$ip" ]] && return 1
    # IPv4
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        local IFS='.'; local -a octets=($ip)
        for octet in "${octets[@]}"; do
            (( octet > 255 )) && return 1
        done
        return 0
    fi
    # 主机名
    [[ "$ip" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] && return 0
    return 1
}

validate_port() {
    local port=$1
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 )) || return 1
    return 0
}

validate_user() {
    local user=$1
    [[ "$user" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || return 1
    return 0
}

# ============================================================
# 字段编解码 (纯bash，零外部进程)
# ============================================================
# 清洗字段: 移除FS和换行符 (纯bash参数扩展)
sanitize() {
    local s=$1
    s="${s//$FS/}"       # 移除字段分隔符
    s="${s//$'\n'/}"      # 移除换行
    s="${s//$'\r'/}"      # 移除回车
    printf '%s' "$s"
}

# 编码: ip FS user FS port FS tag
encode() {
    printf '%s' "$(sanitize "$1")$FS$(sanitize "$2")$FS$(sanitize "$3")$FS$(sanitize "${4:-$1}")"
}

# 解码: 将FS替换为空格，供 read 分割
decode() {
    printf '%s' "${1//$FS/ }"
}

# ============================================================
# 核心操作 (全部使用awk，统一工具，消除grep/sed)
# ============================================================

# 按行号查找
find_host() {
    local id=$1
    [[ -z "$id" ]] && { echo "错误: ID不能为空" >&2; return 1; }
    [[ ! "$id" =~ ^[0-9]+$ ]] && { echo "错误: ID必须是正整数" >&2; return 1; }
    [[ ! -s "$SLM_FILE" ]] && { echo "错误: 暂无主机记录" >&2; return 1; }

    local line
    line=$(awk -v n="$id" 'NR==n {print; exit}' "$SLM_FILE" 2>/dev/null)
    [[ -z "$line" ]] && { echo "错误: 未找到ID=$id的记录" >&2; return 1; }

    decode "$line"
    return 0
}

# 按行号删除 (awk按行号过滤，精确到行，不可能误删)
delete_line() {
    local id=$1
    awk -v n="$id" 'NR!=n' "$SLM_FILE" > "$SLM_FILE.tmp" 2>/dev/null
}

# 按行号替换 (awk按行号替换，精确到行，不可能误改)
replace_line() {
    local id=$1 content=$2
    awk -v n="$id" -v c="$content" 'NR==n {print c; next} {print}' "$SLM_FILE" > "$SLM_FILE.tmp" 2>/dev/null
}

# 检查记录是否存在 (awk按字段精确匹配，不使用正则)
record_exists() {
    local ip=$1 user=$2 port=$3
    # awk逐行按FS分割，逐字段精确比较 (字符串相等，非正则)
    awk -F"$FS" -v ip="$ip" -v u="$user" -v p="$port" \
        '$1==ip && $2==u && $3==p {found=1; exit} END {exit !found}' \
        "$SLM_FILE" 2>/dev/null
}

# ============================================================
# 命令实现
# ============================================================

cmd_add() {
    [[ $# -lt 3 ]] && { echo "用法: slm add <ip> <用户名> <端口> [标签]" >&2; return 1; }

    local ip=$1 user=$2 port=$3 tag=${4:-$ip}

    validate_ip "$ip"       || { echo "错误: IP地址无效 '$ip'" >&2; return 1; }
    validate_user "$user"   || { echo "错误: 用户名无效 '$user'" >&2; return 1; }
    validate_port "$port"   || { echo "错误: 端口无效 '$port' (1-65535)" >&2; return 1; }

    acquire_lock || return 1
    init || return 1

    # 用awk做精确字段匹配检查重复 (不使用grep)
    if record_exists "$ip" "$user" "$port"; then
        echo "错误: 记录已存在 $ip:$port - $user" >&2
        return 1
    fi

    local record
    record=$(encode "$ip" "$user" "$port" "$tag")
    printf '%s\n' "$record" >> "$SLM_FILE" || { echo "错误: 写入失败" >&2; return 1; }

    echo "添加成功: $(sanitize "$tag") ($ip:$port) - $user"
    return 0
}

cmd_del() {
    [[ $# -ne 1 ]] && { echo "用法: slm del <id>" >&2; return 1; }
    [[ ! "$1" =~ ^[0-9]+$ ]] && { echo "错误: ID必须是正整数" >&2; return 1; }
    local id=$1

    # 加锁后再读取，保证读取和操作之间数据一致
    acquire_lock || return 1

    local info
    info=$(find_host "$id") || return 1
    local ip user port tag
    read -r ip user port tag <<< "$info"

    echo -n "确定删除 '$(sanitize "$tag") ($ip:$port) - $user' ? (y/N): "
    read -r confirm
    [[ "$confirm" != [Yy] ]] && { echo "已取消"; return 0; }

    delete_line "$id" || { echo "错误: 删除失败" >&2; return 1; }
    mv "$SLM_FILE.tmp" "$SLM_FILE" && chmod 600 "$SLM_FILE" || { echo "错误: 更新失败" >&2; return 1; }

    echo "删除成功: $(sanitize "$tag") ($ip:$port) - $user"
    return 0
}

cmd_edit() {
    [[ $# -lt 2 ]] && { echo "用法: slm edit <id> [新ip] [新用户名] [新端口] [新标签]" >&2; return 1; }
    [[ ! "$1" =~ ^[0-9]+$ ]] && { echo "错误: ID必须是正整数" >&2; return 1; }
    local id=$1

    # 加锁后再读取，保证读取和操作之间数据一致
    acquire_lock || return 1

    local old_info
    old_info=$(find_host "$id") || return 1
    local old_ip old_user old_port old_tag
    read -r old_ip old_user old_port old_tag <<< "$old_info"

    local new_ip=${2:-$old_ip} new_user=${3:-$old_user} new_port=${4:-$old_port} new_tag=${5:-$old_tag}

    validate_ip "$new_ip"     || { echo "错误: IP地址无效 '$new_ip'" >&2; return 1; }
    validate_user "$new_user" || { echo "错误: 用户名无效 '$new_user'" >&2; return 1; }
    validate_port "$new_port" || { echo "错误: 端口无效 '$new_port'" >&2; return 1; }

    echo "原始: $(sanitize "$old_tag") ($old_ip:$old_port) - $old_user"
    echo "新的: $(sanitize "$new_tag") ($new_ip:$new_port) - $new_user"
    echo -n "确定修改? (y/N): "
    read -r confirm
    [[ "$confirm" != [Yy] ]] && { echo "已取消"; return 0; }

    local new_record
    new_record=$(encode "$new_ip" "$new_user" "$new_port" "$new_tag")
    replace_line "$id" "$new_record" || { echo "错误: 修改失败" >&2; return 1; }
    mv "$SLM_FILE.tmp" "$SLM_FILE" && chmod 600 "$SLM_FILE" || { echo "错误: 更新失败" >&2; return 1; }

    echo "更新成功: $(sanitize "$new_tag") ($new_ip:$new_port) - $new_user"
    return 0
}

cmd_list() {
    [[ ! -s "$SLM_FILE" ]] && { echo "暂无主机记录"; return 0; }
    {
        echo "ID|IP|UserName|Port|Tag"
        echo "----|---------------|----------|-----|------"
        awk -F"$FS" '{print NR "|" $1 "|" $2 "|" $3 "|" $4}' "$SLM_FILE"
    } | column -t -s '|'
    return 0
}

cmd_login() {
    [[ $# -ne 1 ]] && { echo "用法: slm login <id>" >&2; return 1; }
    local info
    info=$(find_host "$1") || return 1
    local ip user port tag
    read -r ip user port tag <<< "$info"

    echo "正在登录 $(sanitize "$tag") ($ip:$port) - $user..."
    ssh -o ConnectTimeout=10 -o ConnectionAttempts=1 \
        -o StrictHostKeyChecking=accept-new -p "$port" "$user@$ip"
}

cmd_push_key() {
    [[ $# -ne 1 ]] && { echo "用法: slm push-key <id>" >&2; return 1; }

    [[ ! -f "$SSH_KEY" ]] && { echo "错误: 未找到SSH密钥 $SSH_KEY\n请先运行: ssh-keygen -t rsa -b 4096" >&2; return 1; }

    local info
    info=$(find_host "$1") || return 1
    local ip user port tag
    read -r ip user port tag <<< "$info"

    echo "正在推送密钥到 $(sanitize "$tag") ($ip:$port) - $user..."
    ssh-copy-id -o ConnectTimeout=10 -o ConnectionAttempts=1 \
        -o StrictHostKeyChecking=accept-new -p "$port" "$user@$ip"

    local rc=$?
    [[ $rc -eq 0 ]] && echo "密钥推送成功，可使用 'slm login $1' 免密登录"
    return $rc
}

cmd_help() {
    cat <<-'EOF'
slm - 服务器登录管理器

用法: slm [命令] [参数]

命令:
    add <ip> <用户名> <端口> [标签]     添加远程主机
    del <id>                            删除记录
    edit <id> [新ip] [新用户名] [新端口] [新标签] 编辑记录
    list                                列出所有记录(默认)
    login <id>                          SSH登录
    push-key <id>                       推送SSH公钥
    help                                显示帮助
EOF
}

# ============================================================
# 主入口
# ============================================================
main() {
    check_deps || exit 1
    init || exit 1

    case "${1:-}" in
        add)      shift; cmd_add "$@" ;;
        del)      shift; cmd_del "$@" ;;
        edit)     shift; cmd_edit "$@" ;;
        list|"")  cmd_list ;;
        login)    shift; cmd_login "$@" ;;
        push-key) shift; cmd_push_key "$@" ;;
        help)     cmd_help ;;
        *)        echo "未知命令: $1" >&2; cmd_help; exit 1 ;;
    esac
    exit $?
}

main "$@"
