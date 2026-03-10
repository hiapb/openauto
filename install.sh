#!/usr/bin/env bash

set -Eeuo pipefail

on_error() {
    local rc=$?
    local line="${BASH_LINENO[0]:-unknown}"
    local cmd="${BASH_COMMAND:-unknown}"
    printf "\033[0;31m[FATAL] 第 %s 行的命令 [%s] 执行失败，退出码 %s\033[0m\n" "${line}" "${cmd}" "${rc}" >&2
    exit "${rc}"
}
trap on_error ERR

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { printf "${BLUE}[INFO] %s${NC}\n" "$1"; }
log_success() { printf "${GREEN}[SUCCESS] %s${NC}\n" "$1"; }
log_warn()    { printf "${YELLOW}[WARN] %s${NC}\n" "$1"; }
log_error()   { printf "${RED}[ERROR] %s${NC}\n" "$1"; }
pause()       { echo; read -n 1 -s -r -p "按任意键继续..."; echo; }

OPENCLAW_HOME="/opt/openclaw"
MATRIX_DB="${OPENCLAW_HOME}/matrix.db"
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
OPENCLAW_BIN_EXPECTED="/usr/bin/openclaw"

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "请提权至 root 用户执行。"
        return 1
    fi
    return 0
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "缺失依赖: $1"
        return 1
    fi
    return 0
}

service_is_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

container_is_running_exact() {
    if ! command -v docker >/dev/null 2>&1; then
        return 1
    fi
    docker ps --format '{{.Names}}' | grep -qx "$1"
}

wait_for_http() {
    local url="$1" retries="${2:-30}" delay="${3:-2}" i
    for ((i=1; i<=retries; i++)); do
        if curl -fsS --max-time 5 "${url}" >/dev/null 2>&1; then
            return 0
        fi
        printf "."
        sleep "${delay}"
    done
    echo
    return 1
}

check_env() {
    if ! command -v apt-get >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
        log_error "仅支持搭载 systemd 的 Debian/Ubuntu 服务器。"
        exit 1
    fi
}

check_core_status() {
    if command -v openclaw >/dev/null 2>&1; then
        if openclaw gateway status >/dev/null 2>&1; then
            printf "${GREEN}在线${NC}"
        else
            printf "${RED}离线${NC}"
        fi
    else
        printf "${RED}未安装${NC}"
    fi
}

check_memory_status() {
    if container_is_running_exact qdrant; then
        printf "${GREEN}活跃${NC}"
    else
        printf "${RED}休眠${NC}"
    fi
}

ensure_docker() {
    require_root || return 1
    if command -v docker >/dev/null 2>&1; then
        systemctl enable --now docker >/dev/null 2>&1 || true
        return 0
    fi
    curl -fsSL https://get.docker.com | bash
    systemctl enable --now docker
}

get_major_version() {
    local v="$1"
    v="${v#v}"
    printf "%s" "${v%%.*}"
}

get_full_node_version() {
    node -v 2>/dev/null | sed 's/^v//'
}

node_version_meets_minimum() {
    local current min
    current="$1"
    min="$2"
    dpkg --compare-versions "${current}" ge "${min}"
}

ensure_node22() {
    require_root || return 1

    local min_node="22.12.0"
    local reinstall=0

    if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
        local current_node
        current_node="$(get_full_node_version || true)"
        if [[ -n "${current_node}" ]] && node_version_meets_minimum "${current_node}" "${min_node}"; then
            log_success "Node.js 已满足要求: v${current_node}"
            return 0
        fi
        reinstall=1
    else
        reinstall=1
    fi

    if [[ "${reinstall}" -eq 1 ]]; then
        log_warn "检测到 Node.js 不满足 OpenClaw 当前要求，切换到 Node.js >= ${min_node} ..."
        apt-get remove -y nodejs npm libnode-dev >/dev/null 2>&1 || true
        apt-get autoremove -y >/dev/null 2>&1 || true

        mkdir -p /etc/apt/keyrings
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
            | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg

        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
            > /etc/apt/sources.list.d/nodesource.list

        apt-get update -y >/dev/null 2>&1
        if ! apt-get install -y nodejs >/dev/null 2>&1; then
            log_error "Node.js 22 安装失败。"
            return 1
        fi
    fi

    local current_node
    current_node="$(get_full_node_version || true)"
    if [[ -z "${current_node}" ]] || ! node_version_meets_minimum "${current_node}" "${min_node}"; then
        log_error "Node.js 版本仍不达标。当前: v${current_node:-unknown}，要求: >= ${min_node}"
        return 1
    fi

    log_success "Node.js 已就绪: v${current_node}"
}

_get_machine_key() {
    if [[ -f /etc/machine-id ]]; then
        cat /etc/machine-id
    else
        hostname
    fi
}

_encrypt() {
    if [[ "$1" == "none" || -z "$1" ]]; then
        echo -n "none"
        return 0
    fi
    echo -n "$1" | openssl enc -aes-256-cbc -pbkdf2 -salt -a -pass "pass:$(_get_machine_key)" 2>/dev/null || echo -n "ENC_ERR"
}

_decrypt() {
    if [[ "$1" == "none" || -z "$1" || "$1" == "ENC_ERR" ]]; then
        echo -n "$1"
        return 0
    fi
    echo -n "$1" | openssl enc -aes-256-cbc -pbkdf2 -salt -a -d -pass "pass:$(_get_machine_key)" 2>/dev/null || echo -n "DEC_ERR"
}

init_matrix_db() {
    mkdir -p "${OPENCLAW_HOME}"
    if [[ ! -f "${MATRIX_DB}" ]]; then
        touch "${MATRIX_DB}"
        chmod 600 "${MATRIX_DB}"
    fi
}

validate_alias() {
    if [[ ! "$1" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "节点代号非法，仅允许字母、数字、下划线和连字符。"
        return 1
    fi
    return 0
}

_gateway_inject() {
    local alias="$1" platform="$2" cred1="$3" cred2="$4"

    if [[ "${platform}" == "qq" ]]; then
        (
            export OC_TEMP="${cred1}:${cred2}"
            openclaw channels add --channel "${alias}" --token "${OC_TEMP}" >/dev/null 2>&1
        )
        return $?
    elif [[ "${platform}" == "tg" ]]; then
        openclaw channels add --channel "${alias}" --token "${cred1}" >/dev/null 2>&1
        return $?
    fi

    return 1
}

_gateway_eject() {
    openclaw channels remove --channel "$1" >/dev/null 2>&1 || true
}

list_matrix() {
    clear
    init_matrix_db
    echo -e "${CYAN}=== 节点状态池 (硬件级加密固化) ===${NC}"

    if [[ ! -s "${MATRIX_DB}" ]]; then
        echo -e "${YELLOW}无节点记录。${NC}"
        return
    fi

    printf "%-18s | %-8s | %-10s\n" "节点代号" "通讯协议" "运行时状态"
    echo "------------------------------------------------"

    while IFS='|' read -r alias platform status c1 c2; do
        if [[ "${status}" == "active" ]]; then
            printf "%-18s | %-8s | ${GREEN}%-10s${NC}\n" "${alias}" "${platform}" "[数据泵开启]"
        elif [[ "${status}" == "paused" ]]; then
            printf "%-18s | %-8s | ${YELLOW}%-10s${NC}\n" "${alias}" "${platform}" "[物理熔断]"
        fi
    done < "${MATRIX_DB}"

    echo "------------------------------------------------"
}

add_matrix_node() {
    require_root || return 1
    require_cmd openclaw || return 1
    init_matrix_db

    local alias platform c1 c2 plat_choice
    read -r -p "定义该节点的唯一机器代号: " alias
    validate_alias "${alias}" || return 1

    if awk -F'|' -v tgt="${alias}" '$1 == tgt {found=1} END {exit(found ? 0 : 1)}' "${MATRIX_DB}"; then
        log_error "代号已被占用。"
        return 1
    fi

    echo -e "1) 腾讯 QQ (官方)   2) Telegram (海外)"
    read -r -p "选择承载协议(1-2): " plat_choice

    if [[ "${plat_choice}" == "1" ]]; then
        platform="qq"
        read -r -p "输入 AppID: " c1
        read -r -s -p "输入 AppSecret: " c2
        echo
        if [[ -z "${c1}" || -z "${c2}" ]]; then
            log_error "握手凭证缺失"
            return 1
        fi
        openclaw plugins install @sliverp/qqbot@latest >/dev/null 2>&1 || true
    elif [[ "${plat_choice}" == "2" ]]; then
        platform="tg"
        read -r -s -p "输入 Bot Token: " c1
        echo
        c2="none"
        if [[ -z "${c1}" ]]; then
            log_error "Token 缺失"
            return 1
        fi
    else
        log_error "协议类型越界"
        return 1
    fi

    if ! _gateway_inject "${alias}" "${platform}" "${c1}" "${c2}"; then
        log_error "网关拒绝注入请求，事务已回滚。"
        return 1
    fi

    local enc_c1 enc_c2
    enc_c1="$(_encrypt "${c1}")"
    enc_c2="$(_encrypt "${c2}")"
    echo "${alias}|${platform}|active|${enc_c1}|${enc_c2}" >> "${MATRIX_DB}"

    restart_openclaw_service
    log_success "节点 [${alias}] 挂载成功。"
}

pause_matrix_node() {
    init_matrix_db

    local alias record r_plat r_status r_c1 r_c2
    read -r -p "输入需【休眠】的节点代号: " alias
    validate_alias "${alias}" || return 1

    record="$(awk -F'|' -v tgt="${alias}" '$1 == tgt' "${MATRIX_DB}")"
    if [[ -z "${record}" ]]; then
        log_error "未匹配到节点。"
        return 1
    fi

    IFS='|' read -r _ r_plat r_status r_c1 r_c2 <<< "${record}"
    if [[ "${r_status}" == "paused" ]]; then
        log_warn "节点已休眠。"
        return 0
    fi

    awk -F'|' -v tgt="${alias}" '$1 != tgt' "${MATRIX_DB}" > "${MATRIX_DB}.tmp"
    echo "${alias}|${r_plat}|paused|${r_c1}|${r_c2}" >> "${MATRIX_DB}.tmp"
    mv "${MATRIX_DB}.tmp" "${MATRIX_DB}"

    _gateway_eject "${alias}"
    restart_openclaw_service
    log_warn "节点 [${alias}] 已拔除物理连接。"
}

resume_matrix_node() {
    init_matrix_db

    local alias record r_plat r_status enc_c1 enc_c2 dec_c1 dec_c2
    read -r -p "输入需【唤醒】的节点代号: " alias
    validate_alias "${alias}" || return 1

    record="$(awk -F'|' -v tgt="${alias}" '$1 == tgt' "${MATRIX_DB}")"
    if [[ -z "${record}" ]]; then
        log_error "未匹配到节点。"
        return 1
    fi

    IFS='|' read -r _ r_plat r_status enc_c1 enc_c2 <<< "${record}"
    if [[ "${r_status}" == "active" ]]; then
        log_warn "节点正在运行。"
        return 0
    fi

    dec_c1="$(_decrypt "${enc_c1}")"
    dec_c2="$(_decrypt "${enc_c2}")"
    if [[ "${dec_c1}" == "DEC_ERR" || "${dec_c2}" == "DEC_ERR" ]]; then
        log_error "解密失败！"
        return 1
    fi

    if ! _gateway_inject "${alias}" "${r_plat}" "${dec_c1}" "${dec_c2}"; then
        log_error "网关唤醒拒绝，事务已回滚。"
        return 1
    fi

    awk -F'|' -v tgt="${alias}" '$1 != tgt' "${MATRIX_DB}" > "${MATRIX_DB}.tmp"
    echo "${alias}|${r_plat}|active|${enc_c1}|${enc_c2}" >> "${MATRIX_DB}.tmp"
    mv "${MATRIX_DB}.tmp" "${MATRIX_DB}"

    restart_openclaw_service
    log_success "节点 [${alias}] 解密注入成功。"
}

delete_matrix_node() {
    init_matrix_db

    local alias confirm
    read -r -p "输入需【永久销毁】的节点代号: " alias
    validate_alias "${alias}" || return 1

    if ! awk -F'|' -v tgt="${alias}" '$1 == tgt {found=1} END {exit(found ? 0 : 1)}' "${MATRIX_DB}"; then
        log_error "节点不存在"
        return 1
    fi

    read -r -p "确认物理抹除该节点？(y/n): " confirm
    if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
        return 0
    fi

    awk -F'|' -v tgt="${alias}" '$1 != tgt' "${MATRIX_DB}" > "${MATRIX_DB}.tmp"
    mv "${MATRIX_DB}.tmp" "${MATRIX_DB}"

    _gateway_eject "${alias}"
    restart_openclaw_service
    log_success "节点 [${alias}] 已粉碎。"
}

manage_channels() {
    require_root || return
    require_cmd openclaw || { pause; return; }
    init_matrix_db

    while true; do
        list_matrix
        echo -e "${CYAN}=================================================${NC}"
        echo -e " ${GREEN}1.${NC} ➕ 部署新流量节点 (Add)"
        echo -e " ${YELLOW}2.${NC} ⏸️  静默休眠节点 (Pause)"
        echo -e " ${GREEN}3.${NC} ▶️  热唤醒休眠节点 (Resume)"
        echo -e " ${RED}4.${NC} 🗑️  彻底销毁节点 (Delete)"
        echo -e " ${BLUE}0.${NC} ↩️  返回主控路由"
        echo -e "${CYAN}=================================================${NC}"
        read -r -p "指令下达 (0-4): " ch_choice

        case "${ch_choice}" in
            1) add_matrix_node; pause ;;
            2) pause_matrix_node; pause ;;
            3) resume_matrix_node; pause ;;
            4) delete_matrix_node; pause ;;
            0) break ;;
            *) log_error "指令解析失败"; sleep 1 ;;
        esac
    done
}

deploy_memory_engine() {
    require_root || return 1
    clear
    ensure_docker

    mkdir -p /opt/qdrant/storage
    docker rm -f qdrant >/dev/null 2>&1 || true
    docker run -d \
        --name qdrant \
        -p 6333:6333 \
        -p 6334:6334 \
        -v /opt/qdrant/storage:/qdrant/storage \
        --restart always \
        qdrant/qdrant >/dev/null

    if wait_for_http "http://127.0.0.1:6333/healthz" 20 2 || wait_for_http "http://127.0.0.1:6333" 20 2; then
        echo
        if container_is_running_exact qdrant; then
            log_success "Qdrant 启动成功。"
        else
            log_error "容器状态异常。"
            return 1
        fi
    else
        echo
        log_error "Qdrant 启动超时。"
        return 1
    fi
}

restart_openclaw_service() {
    require_root || return 1
    require_cmd openclaw || return 1

    if ! openclaw gateway restart >/dev/null 2>&1; then
        log_warn "gateway restart 失败，尝试 start ..."
        if ! openclaw gateway start >/dev/null 2>&1; then
            log_error "OpenClaw 服务重启失败。"
            return 1
        fi
    fi

    sleep 3
    if openclaw gateway status >/dev/null 2>&1; then
        log_success "引擎已热重载。"
        return 0
    fi

    log_error "服务重载失败，请执行 logs 指令排查。"
    return 1
}

install_openclaw_cli() {
    log_info "安装 OpenClaw CLI ..."
    local npm_log="/tmp/openclaw_npm_install.log"

    npm cache clean --force >/dev/null 2>&1 || true

    if ! npm install -g openclaw@latest > "${npm_log}" 2>&1; then
        log_error "CLI 引擎包拉取失败！底层 npm 日志如下："
        echo -e "${YELLOW}==================== NPM ERROR ====================${NC}"
        tail -n 60 "${npm_log}" || true
        echo -e "${YELLOW}===================================================${NC}"
        return 1
    fi

    if ! command -v openclaw >/dev/null 2>&1; then
        log_error "CLI 安装完成，但命令未进入 PATH。"
        return 1
    fi

    log_success "OpenClaw CLI 安装成功。"
}

prepare_system_dependencies() {
    log_info "刷新软件源矩阵..."
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y software-properties-common ca-certificates gnupg >/dev/null 2>&1 || true

    if command -v add-apt-repository >/dev/null 2>&1; then
        add-apt-repository universe -y >/dev/null 2>&1 || true
    fi

    apt-get update -y >/dev/null 2>&1 || true

    log_info "正在注入虚拟渲染与构建依赖..."
    local asound_pkg="libasound2"

    if apt-cache search --names-only '^libasound2t64$' | grep -q 'libasound2t64'; then
        asound_pkg="libasound2t64"
        log_warn "检测到 t64 新架构环境，已自动适配音频依赖矩阵。"
    fi

    if ! apt-get install -y \
        curl wget git xvfb fluxbox x11vnc jq \
        build-essential python3 pkg-config cmake make g++ \
        libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
        libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 \
        "${asound_pkg}" fonts-wqy-zenhei fonts-wqy-microhei >/dev/null 2>&1; then
        log_error "底层依赖注入失败。"
        return 1
    fi

    require_cmd xvfb-run
    require_cmd cmake
}

init_openclaw_gateway() {
    require_cmd openclaw || return 1
    mkdir -p "${OPENCLAW_HOME}"
    init_matrix_db

    log_info "开始初始化 OpenClaw ..."
    if openclaw onboard --install-daemon; then
        log_success "OpenClaw 已完成 onboard 初始化。"
        return 0
    fi

    log_warn "onboard --install-daemon 失败，尝试拆分执行..."
    if ! openclaw onboard; then
        log_error "openclaw onboard 初始化失败。"
        return 1
    fi

    if ! openclaw gateway install; then
        log_error "openclaw gateway install 失败。"
        return 1
    fi

    if ! openclaw gateway start; then
        log_error "openclaw gateway start 失败。"
        return 1
    fi

    log_success "OpenClaw Gateway 初始化完成。"
}

verify_openclaw_health() {
    log_info "验证 OpenClaw 服务状态..."
    sleep 3

    if openclaw gateway status >/dev/null 2>&1; then
        log_success "核心服务已启动。"
        return 0
    fi

    log_warn "gateway status 返回异常，尝试输出诊断信息..."
    openclaw gateway status || true
    openclaw logs --follow >/tmp/openclaw_logs_probe.txt 2>&1 &
    sleep 3
    pkill -f "openclaw logs --follow" >/dev/null 2>&1 || true

    if [[ -f /tmp/openclaw_logs_probe.txt ]]; then
        echo -e "${YELLOW}==================== GATEWAY LOG SNIPPET ====================${NC}"
        tail -n 50 /tmp/openclaw_logs_probe.txt || true
        echo -e "${YELLOW}=============================================================${NC}"
    fi

    log_error "核心启动失败。"
    return 1
}

install_core() {
    require_root || return 1
    clear
    log_info "开始部署 OpenClaw 核心..."
    export DEBIAN_FRONTEND=noninteractive

    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        log_warn "探针检测到 apt 锁，等待 5 秒..."
        sleep 5
    done

    prepare_system_dependencies
    ensure_node22
    install_openclaw_cli
    init_openclaw_gateway
    verify_openclaw_health
}

nuke_system() {
    require_root || return 1

    local backup_file="/root/openclaw_nuke_backup_$(date +%s).tar.gz"
    tar -czf "${backup_file}" /opt/openclaw /opt/qdrant "${HOME}/.openclaw" 2>/dev/null || true

    local nuke_confirm
    read -r -p "输入 'DELETE-OPENCLAW' 执行抹除: " nuke_confirm
    if [[ "${nuke_confirm}" != "DELETE-OPENCLAW" ]]; then
        return 0
    fi

    if command -v openclaw >/dev/null 2>&1; then
        openclaw gateway stop >/dev/null 2>&1 || true
        openclaw gateway uninstall >/dev/null 2>&1 || true
    fi

    rm -rf /root/.openclaw /root/.openclaw-* "${HOME}/.openclaw" "${HOME}/.openclaw-"* 2>/dev/null || true
    rm -rf /opt/openclaw

    if command -v npm >/dev/null 2>&1; then
        npm uninstall -g openclaw >/dev/null 2>&1 || true
    fi

    if command -v docker >/dev/null 2>&1; then
        docker rm -f qdrant >/dev/null 2>&1 || true
    fi

    rm -rf /opt/qdrant
    rm -f /tmp/openclaw_npm_install.log /tmp/openclaw_logs_probe.txt

    log_success "物理环境已清理。"
}

view_logs() {
    require_root || return 1
    require_cmd openclaw || return 1
    openclaw logs --follow
}

cmd_install_core()  { install_core; }
cmd_deploy_memory() { deploy_memory_engine; }
cmd_restart_core()  { restart_openclaw_service; }
cmd_stop_core()     { require_root || return 1; openclaw gateway stop; log_warn "OpenClaw 已停止。"; }
cmd_matrix_add()    { add_matrix_node; }
cmd_matrix_pause()  { pause_matrix_node; }
cmd_matrix_resume() { resume_matrix_node; }
cmd_matrix_delete() { delete_matrix_node; }
cmd_matrix_list()   { list_matrix; }
cmd_status()        { printf "算力状态: %b | 记忆状态: %b\n" "$(check_core_status)" "$(check_memory_status)"; }

show_help() {
    cat <<'EOF'
用法:
  ./openclaw_master.sh                 进入交互菜单
  ./openclaw_master.sh status          查看状态
  ./openclaw_master.sh install-core    部署 OpenClaw 核心
  ./openclaw_master.sh deploy-memory   部署 Qdrant
  ./openclaw_master.sh restart-core    重启 OpenClaw
  ./openclaw_master.sh stop-core       停止 OpenClaw
  ./openclaw_master.sh matrix-add      添加节点 (QQ/TG)
  ./openclaw_master.sh matrix-pause    暂停指定节点
  ./openclaw_master.sh matrix-resume   唤醒指定节点
  ./openclaw_master.sh matrix-delete   永久销毁节点
  ./openclaw_master.sh matrix-list     查看节点列表
  ./openclaw_master.sh logs            查看日志
  ./openclaw_master.sh nuke            销毁系统
  ./openclaw_master.sh help            显示帮助
EOF
}

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}=================================================${NC}"
        echo -e "       ${GREEN}OpenClaw 矩阵算力中枢2${NC}"
        echo -e "       算力状态: $(check_core_status) | 记忆状态: $(check_memory_status)"
        echo -e "${BLUE}=================================================${NC}"
        echo -e " ${YELLOW}1.${NC} 🚀 部署 AI 算力底座"
        echo -e " ${CYAN}2.${NC} 🧠 部署 Qdrant 向量记忆库"
        echo -e " ${CYAN}3.${NC} 📡 矩阵节点管理总线 (增删启停 QQ/TG)"
        echo -e " ${YELLOW}4.${NC} 🔄 热重载核心引擎"
        echo -e " ${YELLOW}5.${NC} 🛑 停止核心引擎"
        echo -e " ${YELLOW}6.${NC} 📜 查看内核级日志"
        echo -e " ${RED}9.${NC} ☢️  安全销毁系统"
        echo -e " ${YELLOW}0.${NC} 🚪 退出面板"
        echo -e "${BLUE}=================================================${NC}"
        read -r -p "指令下达: " main_choice

        case "${main_choice}" in
            1) install_core; pause ;;
            2) deploy_memory_engine; pause ;;
            3) manage_channels ;;
            4) restart_openclaw_service; pause ;;
            5) cmd_stop_core; pause ;;
            6) view_logs ;;
            9) nuke_system; pause ;;
            0) exit 0 ;;
            *) log_error "非法指令"; sleep 1 ;;
        esac
    done
}

check_env
case "${1:-menu}" in
    menu)           main_menu ;;
    status)         cmd_status ;;
    install-core)   cmd_install_core ;;
    deploy-memory)  cmd_deploy_memory ;;
    restart-core)   cmd_restart_core ;;
    stop-core)      cmd_stop_core ;;
    matrix-add)     cmd_matrix_add ;;
    matrix-pause)   cmd_matrix_pause ;;
    matrix-resume)  cmd_matrix_resume ;;
    matrix-delete)  cmd_matrix_delete ;;
    matrix-list)    cmd_matrix_list ;;
    logs)           view_logs ;;
    nuke)           nuke_system ;;
    help|-h|--help) show_help ;;
    *)              log_error "未知命令: $1"; show_help; exit 1 ;;
esac
