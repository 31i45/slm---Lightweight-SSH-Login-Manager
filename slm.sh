#!/bin/bash

# slm - 服务器登录管理器
# 功能: 远程主机信息CRUD与SSH免密登录

# 配置
readonly SLM_DIR="$HOME/.slm"
readonly SLM_FILE="$SLM_DIR/remotes.txt"
readonly SSH_KEY="$HOME/.ssh/id_rsa.pub"

# 初始化 - 确保数据目录和文件存在
mkdir -p "$SLM_DIR" 2>/dev/null && touch "$SLM_FILE" 2>/dev/null && chmod 700 "$SLM_DIR" 2>/dev/null && chmod 600 "$SLM_FILE" 2>/dev/null

# 检查依赖
if ! command -v ssh >/dev/null; then
    echo "错误: 缺少必要依赖 ssh"
    exit 1
fi

if ! command -v ssh-copy-id >/dev/null; then
    echo "错误: 缺少必要依赖 ssh-copy-id"
    exit 1
fi

# 查找主机信息 (未找到时显示错误并返回非零状态码)
find_host() {
    local host_info
    
    [[ -z "$1" ]] && echo "错误: 主机标识不能为空" && return 1
    
    if [[ "$1" =~ ^[0-9]+$ ]]; then
        # 通过行号查找
        host_info=$(sed -n "${1}p" "$SLM_FILE" | tr '|' ' ')
    else
        # 通过IP查找
        host_info=$(grep -m1 "^$1|" "$SLM_FILE" | tr '|' ' ')
    fi
    
    # 检查是否找到主机
    [[ -z "$host_info" ]] && echo "错误: 未找到主机 $1" && return 1
    
    # 找到主机，输出信息
    echo "$host_info"
    return 0
}

# 添加主机
cmd_add() {
    [[ $# -lt 3 ]] && echo "用法: slm add <ip> <用户名> <端口> [标签]" && return 1
    
    local ip=$1 user=$2 port=$3 tag=${4:-$ip}
    
    # 检查IP是否已存在
    grep -q "^$ip|" "$SLM_FILE" && echo "错误: 主机 $ip 已存在" && return 1
    
    # 添加主机
    # 先获取当前行数，然后加1作为新主机ID
    local new_id=$(( $(grep -c "^" "$SLM_FILE") + 1 ))
    echo "$ip|$user|$port|$tag" >> "$SLM_FILE"
    echo "主机添加成功: $tag ($ip) [ID: $new_id]"
}

# 删除主机
cmd_del() {
    [[ $# -ne 1 ]] && echo "用法: slm del <id 或 ip>" && return 1
    
    local info=$(find_host "$1") || return $?
    
    # 使用read命令一次性提取多个字段，更高效
    read -r ip _ _ tag <<< "$info"
    
    echo "删除主机: $tag ($ip)"
    # 使用 && 确保前面命令成功才执行后面的
    grep -v "^$ip|" "$SLM_FILE" > "$SLM_FILE.new" && mv "$SLM_FILE.new" "$SLM_FILE"
}

# 编辑主机
cmd_edit() {
    [[ $# -lt 2 ]] && echo "用法: slm edit <id 或 ip> <新ip> <新用户名> <新端口> [新标签]" && return 1
    
    local info=$(find_host "$1") || return $?
    
    # 使用read命令一次性提取多个字段，更高效
    read -r old_ip old_user old_port old_tag <<< "$info"
    
    # 设置新值 (保留原值如果未提供新值)
    local new_ip=${2:-$old_ip}
    local new_user=${3:-$old_user}
    local new_port=${4:-$old_port}
    local new_tag=${5:-$old_tag}
    
    # 原子更新记录，确保所有操作成功才替换原文件
    (grep -v "^$old_ip|" "$SLM_FILE" && echo "$new_ip|$new_user|$new_port|$new_tag") > "$SLM_FILE.new" && \
    mv "$SLM_FILE.new" "$SLM_FILE" && \
    echo "主机更新成功: $new_tag ($new_ip)"
}

# 列出主机
cmd_list() {
    # 检查文件是否为空
    [[ ! -s "$SLM_FILE" ]] && echo "暂无主机记录" && return 0
    
    # 使用纯awk实现全部功能，更符合Unix哲学
    awk -F'|' 'BEGIN {printf "ID\tIP\t用户名\t端口\t标签\n--\t--\t----\t--\t---\n"} 
                {printf "%d\t%s\t%s\t%s\t%s\n", NR, $1, $2, $3, $4}' "$SLM_FILE"
}

# 登录主机
cmd_login() {
    [[ $# -ne 1 ]] && echo "用法: slm login <id 或 ip>" && return 1
    
    local info=$(find_host "$1") || return $?
    
    # 一次性提取所有字段，避免多次echo和cut调用
    read -r ip user port tag <<< "$info"
    
    echo "正在登录 $tag ($ip)..."
    ssh -p "$port" "$user@$ip"
}

# 推送SSH密钥
cmd_push_key() {
    [[ $# -ne 1 ]] && echo "用法: slm push-key <id 或 ip>" && return 1
    
    # 检查密钥
    [[ ! -f "$SSH_KEY" ]] && echo "错误: 未找到SSH密钥 $SSH_KEY\n请先运行 'ssh-keygen'" && return 1
    
    local info=$(find_host "$1") || return $?
    
    # 一次性提取所有字段，避免多次echo和cut调用
    read -r ip user port tag <<< "$info"
    
    echo "正在推送密钥到 $tag ($ip)..."
    ssh-copy-id -p "$port" "$user@$ip"
}

# 帮助信息
cmd_help() {
    cat <<-'EOF'
slm - 服务器登录管理器

用法: slm [命令] [参数]

命令:
  add <ip> <用户名> <端口> [标签]    添加远程主机
  del <id 或 ip>                    删除远程主机
  edit <id 或 ip> [参数...]         编辑远程主机信息
  list                              列出所有远程主机
  login <id 或 ip>                  登录远程主机
  push-key <id 或 ip>               推送SSH密钥实现免密登录
  help                              显示此帮助信息
EOF
}

# 主命令处理
case "$1" in
    add)       shift && cmd_add "$@"      ;;
    del)       shift && cmd_del "$@"      ;;
    edit)      shift && cmd_edit "$@"     ;;
    list)      cmd_list                    ;;
    login)     shift && cmd_login "$@"    ;;
    push-key)  shift && cmd_push_key "$@" ;;
    help)      cmd_help                    ;;
    "")        cmd_list                    ;;
    *)         echo "未知命令: $1" && cmd_help && exit 1 ;;
esac
