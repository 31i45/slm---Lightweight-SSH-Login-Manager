#!/bin/bash

# slm - 服务器登录管理器
# 功能: 远程主机信息CRUD与SSH免密登录

readonly SLM_DIR="$HOME/.slm"
readonly SLM_FILE="$SLM_DIR/remotes.txt"
readonly SSH_KEY="$HOME/.ssh/id_rsa.pub"

[[ -d "$SLM_DIR" ]] || { mkdir -p "$SLM_DIR" && chmod 700 "$SLM_DIR"; }
[[ -f "$SLM_FILE" ]] || { touch "$SLM_FILE" && chmod 600 "$SLM_FILE"; }

for dep in ssh ssh-copy-id column; do
    command -v "$dep" >/dev/null 2>&1 || { echo "错误: 缺少 $dep" >&2; exit 1; }
done

find_host() {
    [[ -z "$1" ]] && { echo "错误: 参数不能为空" >&2; return 1; }
    [[ ! "$1" =~ ^[0-9]+$ ]] && { echo "错误: ID必须是数字" >&2; return 1; }
    local line
    line=$(awk -v n="$1" 'NR==n {print; exit}' "$SLM_FILE" 2>/dev/null)
    [[ -z "$line" ]] && { echo "错误: 未找到主机记录" >&2; return 1; }
    echo "${line//|/ }"
}

cmd_add() {
    [[ $# -lt 3 ]] && { echo "用法: slm add <ip> <用户名> <端口> [标签]" >&2; return 1; }
    local ip=$1 user=$2 port=$3 tag=${4:-$ip}
    grep -q "^$ip|$user|$port|" "$SLM_FILE" && { echo "错误: 记录已存在 $ip:$port - $user" >&2; return 1; }
    echo "$ip|$user|$port|$tag" >> "$SLM_FILE"
    echo "添加成功: $tag ($ip:$port) - $user"
}

cmd_del() {
    [[ $# -ne 1 ]] && { echo "用法: slm del <id>" >&2; return 1; }
    [[ ! "$1" =~ ^[0-9]+$ ]] && { echo "错误: ID必须是数字" >&2; return 1; }
    local info=$(find_host "$1") || return $?
    read -r ip user port tag <<< "$info"
    echo -n "确定删除 '$tag ($ip:$port) - $user' ? (y/N): "
    read -r confirm
    [[ "$confirm" != [Yy] ]] && { echo "已取消"; return 0; }
    awk -v n="$1" 'NR!=n' "$SLM_FILE" > "$SLM_FILE.tmp" && mv "$SLM_FILE.tmp" "$SLM_FILE"
    echo "删除成功: $tag ($ip:$port) - $user"
}

cmd_edit() {
    [[ $# -lt 2 ]] && { echo "用法: slm edit <id> [新ip] [新用户名] [新端口] [新标签]" >&2; return 1; }
    local info=$(find_host "$1") || return $?
    read -r old_ip old_user old_port old_tag <<< "$info"
    local new_ip=${2:-$old_ip} new_user=${3:-$old_user} new_port=${4:-$old_port} new_tag=${5:-$old_tag}
    echo "原始: $old_tag ($old_ip:$old_port) - $old_user"
    echo "新的: $new_tag ($new_ip:$new_port) - $new_user"
    echo -n "确定修改? (y/N): "
    read -r confirm
    [[ "$confirm" != [Yy] ]] && { echo "已取消"; return 0; }
    local new_record="$new_ip|$new_user|$new_port|$new_tag"
    awk -v n="$1" -v c="$new_record" 'NR==n {print c; next} {print}' "$SLM_FILE" > "$SLM_FILE.tmp" && mv "$SLM_FILE.tmp" "$SLM_FILE"
    echo "更新成功: $new_tag ($new_ip:$new_port) - $new_user"
}

cmd_list() {
    [[ ! -s "$SLM_FILE" ]] && { echo "暂无主机记录"; return 0; }
    { echo "ID|IP|UserName|Port|Tag"; echo "----|---------------|----------|-----|------"; awk -F'|' '{print NR "|" $0}' "$SLM_FILE"; } | column -t -s '|'
}

cmd_login() {
    [[ $# -ne 1 ]] && { echo "用法: slm login <id>" >&2; return 1; }
    local info=$(find_host "$1") || return $?
    read -r ip user port tag <<< "$info"
    echo "正在登录 $tag ($ip:$port) - $user..."
    ssh -o ConnectTimeout=10 -o ConnectionAttempts=1 -o StrictHostKeyChecking=accept-new -p "$port" "$user@$ip"
}

cmd_push_key() {
    [[ $# -ne 1 ]] && { echo "用法: slm push-key <id>" >&2; return 1; }
    [[ ! -f "$SSH_KEY" ]] && { echo "错误: 未找到SSH密钥 $SSH_KEY\n请先运行: ssh-keygen -t rsa -b 4096" >&2; return 1; }
    local info=$(find_host "$1") || return $?
    read -r ip user port tag <<< "$info"
    echo "正在推送密钥到 $tag ($ip:$port) - $user..."
    ssh-copy-id -o ConnectTimeout=10 -o ConnectionAttempts=1 -o StrictHostKeyChecking=accept-new -p "$port" "$user@$ip"
    [[ $? -eq 0 ]] && echo "密钥推送成功，可使用 'slm login $1' 免密登录"
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

case "${1:-}" in
    add)       shift; cmd_add "$@" ;;
    del)       shift; cmd_del "$@" ;;
    edit)      shift; cmd_edit "$@" ;;
    list|"")  cmd_list ;;
    login)     shift; cmd_login "$@" ;;
    push-key)  shift; cmd_push_key "$@" ;;
    help)      cmd_help ;;
    *)         echo "未知命令: $1" >&2; cmd_help; exit 1 ;;
esac
exit $?
