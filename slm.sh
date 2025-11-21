#!/bin/bash

# slm - 服务器登录管理器
# 功能: 远程主机信息CRUD与SSH免密登录

# 配置
readonly SLM_DIR="$HOME/.slm"
readonly SLM_FILE="$SLM_DIR/remotes.txt"
readonly SSH_KEY="$HOME/.ssh/id_rsa.pub"

# 初始化 - 确保数据目录和文件存在
[[ -d "$SLM_DIR" ]] || { mkdir -p "$SLM_DIR" && chmod 700 "$SLM_DIR"; }
[[ -f "$SLM_FILE" ]] || { touch "$SLM_FILE" && chmod 600 "$SLM_FILE"; }

# 检查依赖
if ! command -v ssh >/dev/null; then
    echo "错误: 缺少必要依赖 ssh" >&2
    exit 1
fi

if ! command -v ssh-copy-id >/dev/null; then
    echo "错误: 缺少必要依赖 ssh-copy-id" >&2
    exit 1
fi

# 查找主机信息
find_host() {
    local line
    
    # 检查必需参数
    [[ -z "$1" ]] && echo "错误: 参数不能为空" >&2 && return 1
    
    if [[ "$1" =~ ^[0-9]+$ ]]; then
        # 通过行号(id)查找
        line=$(sed -n "${1}p;${1}q" "$SLM_FILE")
        # 或 line=$(nl -w1 -s'|' "$SLM_FILE" | grep "^${1}|")
        # 或 line=$(awk -v line="$1" 'NR==line {print; exit}' "$SLM_FILE")
    else
        echo "错误: 参数格式错误" >&2 && return 1
    fi
    
    # 检查是否找到主机记录
    [[ -z "$line" ]] && echo "错误: 未找到主机记录" >&2 && return 1
    
    # 找到主机，输出信息（纯bash替换|为空格，避免tr）
    echo "${line//|/ }"
    return 0
}

# 添加主机 - 需要提供IP、用户名、端口和可选标签
cmd_add() {
    # 检查必需参数
    [[ $# -lt 3 ]] && echo "用法: slm add <ip> <用户名> <端口> [标签]" >&2 && return 1
    
    local ip=$1 user=$2 port=$3 tag=${4:-$ip}
    
    # 检查IP+用户名+端口组合是否已存在
    grep -q "^$ip|$user|$port|" "$SLM_FILE" && echo "错误: 主机记录已存在，$ip:$port - $user" >&2 && return 1
    
    # 计算新主机ID并添加记录
    local new_id=$(( $(wc -l < "$SLM_FILE") + 1 ))
    echo "$ip|$user|$port|$tag" >> "$SLM_FILE"
    echo "主机记录添加成功: $tag ($ip:$port) - $user"
}

# 删除主机 - 支持通过ID删除
cmd_del() {
    # 检查参数数量是否为1(使用ID)
    [[ $# -ne 1 ]] && echo "用法: slm del <id>" >&2 && return 1
    
    # 检查参数是否为数字
    [[ ! "$1" =~ ^[0-9]+$ ]] && echo "错误: ID必须是数字" >&2 && return 1
    
    # 调用find_host获取主机信息
    local info=$(find_host "$1") || return $?
    
    # 使用read命令一次性提取多个字段，更高效
    read -r ip user port tag <<< "$info"
    
    # 添加二次确认机制
    echo -n "确定要删除 '$tag ($ip:$port) - $user' 吗? (y/N): "
    read -r confirm
    [[ "$confirm" != [Yy] ]] && echo "删除操作已取消" && return 0
    
    # 使用原子操作删除记录，确保数据安全
    (grep -v "^$ip|$user|$port|" "$SLM_FILE") > "$SLM_FILE.new" && \
    mv "$SLM_FILE.new" "$SLM_FILE" && \
    echo "主机记录删除成功: $tag ($ip:$port) - $user"
}

# 编辑主机
cmd_edit() {
    [[ $# -lt 2 ]] && echo "用法: slm edit <id> <新ip> <新用户名> <新端口> [新标签]" >&2 && return 1
    
    local info=$(find_host "$1") || return $?
    
    # 使用read命令一次性提取多个字段，更高效
    read -r old_ip old_user old_port old_tag <<< "$info"
    
    # 设置新值 (保留原值如果未提供新值)
    local new_ip=${2:-$old_ip}
    local new_user=${3:-$old_user}
    local new_port=${4:-$old_port}
    local new_tag=${5:-$old_tag}
    
    # 添加二次确认机制
    echo "原始记录: $old_tag ($old_ip:$old_port) - $old_user"
    echo "新的记录: $new_tag ($new_ip:$new_port) - $new_user"
    echo -n "确定要修改吗? (y/N): "
    read -r confirm
    [[ "$confirm" != [Yy] ]] && echo "修改操作已取消" && return 0
    
    # 使用原子操作更新记录，确保数据安全
    (sed "s#^$old_ip|$old_user|$old_port|.*#$new_ip|$new_user|$new_port|$new_tag#" "$SLM_FILE") > "$SLM_FILE.new" && \
    mv "$SLM_FILE.new" "$SLM_FILE" && \
    echo "主机更新成功: $new_tag ($new_ip:$new_port) - $new_user"
}

# 列出主机
cmd_list() {
    [[ ! -s "$SLM_FILE" ]] && echo "暂无主机记录" && return 0
    # 表头 + 数据行，用 | 分隔，交给 column 自动对齐
    { 
        echo "ID|IP|UserName|Port|Tag"
        echo "----|---------------|----------|-----|------"  # 分隔线与内容匹配
        # 给每行数据添加 ID（行号）
        awk -F'|' '{print NR "|" $0}' "$SLM_FILE"
        # 或 nl -w1 -s'|' "$SLM_FILE" 专门添加行号
        # 或 sed = "$SLM_FILE" | sed 'N; s/\n/|/'
    } | column -t -s '|'  # 以 | 为分隔符，自动对齐列
}

# 登录主机
cmd_login() {
    [[ $# -ne 1 ]] && echo "用法: slm login <id>" >&2 && return 1
    
    local info=$(find_host "$1") || return $?
    
    # 一次性提取所有字段，避免多次echo和cut调用
    read -r ip user port tag <<< "$info"
    
    echo "正在登录 $tag ($ip:$port) - $user..."
    # 添加超时选项避免SSH连接卡住
    ssh -o ConnectTimeout=10 -o ConnectionAttempts=1 -p "$port" "$user@$ip"
}

# 推送SSH密钥
cmd_push_key() {
    [[ $# -ne 1 ]] && echo "用法: slm push-key <id>" >&2 && return 1
    
    # 检查密钥
    [[ ! -f "$SSH_KEY" ]] && echo "错误: 未找到SSH密钥 $SSH_KEY\n请先运行 'ssh-keygen'" >&2 && return 1
    
    local info=$(find_host "$1") || return $?
    
    # 一次性提取所有字段，避免多次echo和cut调用
    read -r ip user port tag <<< "$info"
    
    echo "正在推送密钥到 $tag ($ip:$port) - $user..."
    # 添加超时选项避免ssh-copy-id命令在网络问题时长时间阻塞
    ssh-copy-id -o ConnectTimeout=10 -o ConnectionAttempts=1 -p "$port" "$user@$ip"
    
    # 使用ssh-copy-id的原生退出状态
    [[ $? -eq 0 ]] && echo "密钥推送成功，可以使用 'slm login $1' 免密登录"
}

# 帮助信息
cmd_help() {
    cat <<-'EOF'
slm - 服务器登录管理器

用法: slm [命令] [参数]

命令:
    add <ip> <用户名> <端口> [标签]     添加远程主机信息
    del <id>                            删除指定ID的远程主机记录
    edit <id> [新ip] [新用户名] [新端口] [新标签] 编辑远程主机信息字段
    list                                列出所有远程主机记录(默认命令)
    login <id>                          登录指定ID的远程主机
    push-key <id>                       推送SSH公钥实现免密登录
    help                                显示此帮助信息
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
    *)         echo "未知命令: $1" >&2 && cmd_help && exit 1 ;;
esac
exit $?
