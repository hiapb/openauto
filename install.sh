#!/usr/bin/env bash

set -Eeuo pipefail

trap 'rc=$?; printf "\033[0;31m[FATAL] 第 %s 行的命令 [%s] 执行失败，退出码 %s\033[0m\n" "${BASH_LINENO[0]}" "${BASH_COMMAND}" "$rc" >&2' ERR

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

require_root() { [[ "${EUID}" -ne 0 ]] && { log_error "请提权至 root 用户执行。"; return 1; } || return 0; }
require_cmd()  { command -v "$1" >/dev/null 2>&1 || { log_error "缺失依赖: $1"; return 1; }; }
service_is_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
container_is_running_exact() { command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -qx "$1"; }

wait_for_http() {
    local url="$1" retries="${2:-20}" delay="${3:-2}" i
    for ((i=1; i<=retries; i++)); do
        if curl -fsS --max-time 5 "${url}" >/dev/null 2>&1; then return 0; fi
        printf "."
        sleep "${delay}"
    done
    echo; return 1
}

restart_openclaw_service() {
    require_root || return 1
    systemctl restart openclaw
    sleep 2
    service_is_active openclaw && { log_success "引擎已在内核级热重载。"; return 0; }
    log_error "服务重载溃败，请执行 logs 指令查阅 journald 日志。"
    return 1
}

check_env() {
    if ! command -v apt-get >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
        log_error "仅支持搭载 systemd 的 Debian/Ubuntu 服务器。"
        exit 1
    fi
}

check_core_status() { service_is_active openclaw && printf "${GREEN}在线${NC}" || printf "${RED}离线${NC}"; }
check_memory_status() { container_is_running_exact qdrant && printf "${GREEN}活跃${NC}" || printf "${RED}休眠${NC}"; }

ensure_docker() {
    require_root || return 1
    if command -v docker >/dev/null 2>&1; then
        systemctl enable --now docker >/dev/null 2>&1 || true
        return 0
    fi
    curl -fsSL https://get.docker.com | bash
    systemctl enable --now docker
}

ensure_node20() {
    require_root || return 1
    # 1. 严格校验 Node 与 NPM 双核心的存活与版本兼容性
    if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
        if node -v | grep -q '^v20\.'; then return 0; fi
    fi
    
    log_warn "探针检测到 Node.js 碎片或版本断层，启动焦土清理协议..."
    # 2. 斩断历史依赖包袱，防止新旧包发生符号链接碰撞
    apt-get remove -y nodejs npm libnode-dev >/dev/null 2>&1 || true
    apt-get autoremove -y >/dev/null 2>&1 || true

    # 3. 部署新架构并强制注入原生 C++ 编译护航链
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
    log_info "注入 Node.js 20 与原生编译工具链 (build-essential/python3)..."
    if ! apt-get install -y nodejs build-essential python3 >/dev/null 2>&1; then
        log_error "Node.js 引擎部署遭遇物理断层。"
        return 1
    fi
}

_get_machine_key() { [[ -f /etc/machine-id ]] && cat /etc/machine-id || hostname; }

_encrypt() {
    if [[ "$1" == "none" || -z "$1" ]]; then echo -n "none"; return; fi
    echo -n "$1" | openssl enc -aes-256-cbc -pbkdf2 -salt -a -pass "pass:$(_get_machine_key)" 2>/dev/null || echo -n "ENC_ERR"
}

_decrypt() {
    if [[ "$1" == "none" || -z "$1" || "$1" == "ENC_ERR" ]]; then echo -n "$1"; return; fi
    echo -n "$1" | openssl enc -aes-256-cbc -pbkdf2 -salt -a -d -pass "pass:$(_get_machine_key)" 2>/dev/null || echo -n "DEC_ERR"
}

MATRIX_DB="/opt/openclaw/matrix.db"

init_matrix_db() {
    mkdir -p /opt/openclaw
    [[ ! -f "${MATRIX_DB}" ]] && touch "${MATRIX_DB}" && chmod 600 "${MATRIX_DB}"
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
        ( export OC_TEMP="${cred1}:${cred2}"; openclaw channels add --channel "${alias}" --token "${OC_TEMP}" >/dev/null 2>&1 )
    elif [[ "${platform}" == "tg" ]]; then
        openclaw channels add --channel "${alias}" --token "${cred1}" >/dev/null 2>&1
    fi
}

_gateway_eject() { openclaw channels remove --channel "$1" >/dev/null 2>&1 || true; }

list_matrix() {
    clear
    echo -e "${CYAN}=== 节点状态池 (硬件级加密固化) ===${NC}"
    [[ ! -s "${MATRIX_DB}" ]] && { echo -e "${YELLOW}无节点记录。${NC}"; return; }
    printf "%-18s | %-8s | %-10s\n" "节点代号" "通讯协议" "运行时状态"
    echo "------------------------------------------------"
    while IFS='|' read -r alias platform status c1 c2; do
        [[ "${status}" == "active" ]] && printf "%-18s | %-8s | ${GREEN}%-10s${NC}\n" "${alias}" "${platform}" "[数据泵开启]"
        [[ "${status}" == "paused" ]] && printf "%-18s | %-8s | ${YELLOW}%-10s${NC}\n" "${alias}" "${platform}" "[物理熔断]"
    done < "${MATRIX_DB}"
    echo "------------------------------------------------"
}

add_matrix_node() {
    require_root || return 1
    require_cmd openclaw || return 1
    init_matrix_db
    local alias platform c1 c2 plat_choice
    read -p "定义该节点的唯一机器代号: " alias
    validate_alias "${alias}" || return 1
    if awk -F'|' -v tgt="${alias}" '$1 == tgt {found=1} END {if(found) exit 0; else exit 1}' "${MATRIX_DB}"; then
        log_error "代号已被占用。"; return 1
    fi
    echo -e "1) 腾讯 QQ (官方)   2) Telegram (海外)"
    read -p "选择承载协议(1-2): " plat_choice
    if [[ "${plat_choice}" == "1" ]]; then
        platform="qq"
        read -p "输入 AppID: " c1
        read -s -p "输入 AppSecret: " c2; echo
        [[ -z "${c1}" || -z "${c2}" ]] && { log_error "握手凭证缺失"; return 1; }
        openclaw plugins install @sliverp/qqbot@latest >/dev/null 2>&1 || true
    elif [[ "${plat_choice}" == "2" ]]; then
        platform="tg"
        read -s -p "输入 Bot Token: " c1; echo
        c2="none"
        [[ -z "${c1}" ]] && { log_error "Token 缺失"; return 1; }
    else
        log_error "协议类型越界"; return 1
    fi
    if ! _gateway_inject "${alias}" "${platform}" "${c1}" "${c2}"; then
        log_error "网关拒绝注入请求，事务已回滚。"
        return 1
    fi
    local enc_c1 enc_c2
    enc_c1=$(_encrypt "${c1}")
    enc_c2=$(_encrypt "${c2}")
    echo "${alias}|${platform}|active|${enc_c1}|${enc_c2}" >> "${MATRIX_DB}"
    restart_openclaw_service
    log_success "节点 [${alias}] 挂载成功。"
}

pause_matrix_node() {
    local alias record r_plat
    read -p "输入需【休眠】的节点代号: " alias
    validate_alias "${alias}" || return 1
    record=$(awk -F'|' -v tgt="${alias}" '$1 == tgt' "${MATRIX_DB}")
    [[ -z "${record}" ]] && { log_error "未匹配到节点。"; return 1; }
    IFS='|' read -r _ r_plat r_status r_c1 r_c2 <<< "${record}"
    [[ "${r_status}" == "paused" ]] && { log_warn "节点已休眠。"; return 0; }
    awk -F'|' -v tgt="${alias}" '$1 != tgt' "${MATRIX_DB}" > "${MATRIX_DB}.tmp"
    echo "${alias}|${r_plat}|paused|${r_c1}|${r_c2}" >> "${MATRIX_DB}.tmp"
    mv "${MATRIX_DB}.tmp" "${MATRIX_DB}"
    _gateway_eject "${alias}"
    restart_openclaw_service
    log_warn "节点 [${alias}] 已拔除物理连接。"
}

resume_matrix_node() {
    local alias record r_plat r_status enc_c1 enc_c2 dec_c1 dec_c2
    read -p "输入需【唤醒】的节点代号: " alias
    validate_alias "${alias}" || return 1
    record=$(awk -F'|' -v tgt="${alias}" '$1 == tgt' "${MATRIX_DB}")
    [[ -z "${record}" ]] && { log_error "未匹配到节点。"; return 1; }
    IFS='|' read -r _ r_plat r_status enc_c1 enc_c2 <<< "${record}"
    [[ "${r_status}" == "active" ]] && { log_warn "节点正在运行。"; return 0; }
    dec_c1=$(_decrypt "${enc_c1}")
    dec_c2=$(_decrypt "${enc_c2}")
    [[ "${dec_c1}" == "DEC_ERR" || "${dec_c2}" == "DEC_ERR" ]] && { log_error "解密失败！"; return 1; }
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
    local alias
    read -p "输入需【永久销毁】的节点代号: " alias
    validate_alias "${alias}" || return 1
    awk -F'|' -v tgt="${alias}" '$1 == tgt {found=1} END {if(found) exit 0; else exit 1}' "${MATRIX_DB}" || { log_error "节点不存在"; return 1; }
    read -p "确认物理抹除该节点？(y/n): " confirm
    [[ "${confirm}" != "y" && "${confirm}" != "Y" ]] && return 0
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
    docker run -d --name qdrant -p 6333:6333 -p 6334:6334 -v /opt/qdrant/storage:/qdrant/storage --restart always qdrant/qdrant >/dev/null
    if wait_for_http "http://localhost:6333/healthz" 20 2 || wait_for_http "http://localhost:6333" 20 2; then
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

install_core() {
    require_root || return 1
    clear
    log_info "开始烧录算力底层基座 (防阻塞模式)..."
    export DEBIAN_FRONTEND=noninteractive
    
    # 1. 暴力破解 Dpkg 锁死博弈
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        log_warn "探针检测到系统底层正被 apt 进程锁死 (可能在后台自动更新)，强制挂起等待 5 秒..."
        sleep 5
    done

    # 2. 强行补全可能缺失的 Universe 软件源
    log_info "正在刷新系统源矩阵并注入扩展仓库..."
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y software-properties-common >/dev/null 2>&1 || true
    add-apt-repository universe -y >/dev/null 2>&1 || true
    apt-get update -y >/dev/null 2>&1 || true

    log_info "正在向内核注入虚拟渲染依赖 (过程日志已开启可视化)..."
    
    # [核心逻辑]: 动态推断音频底层库版本，跨越 Y2038 t64 架构断层
    local asound_pkg="libasound2"
    if apt-cache search --names-only '^libasound2t64$' | grep -q 'libasound2t64'; then
        asound_pkg="libasound2t64"
        log_warn "检测到 t64 新架构环境，已自动适配音频依赖矩阵。"
    fi

    if ! apt-get install -y curl wget git xvfb fluxbox x11vnc jq libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 "${asound_pkg}" fonts-wqy-zenhei fonts-wqy-microhei; then
        log_error "底层依赖注入失败！请根据上方 APT 打印的红色英文报错排查源节点问题。"
        return 1
    fi

    require_cmd xvfb-run
    ensure_node20

    log_info "同步核心 CLI 包 (启用日志动态接管)..."
    local npm_log="/tmp/openclaw_npm_install.log"
    
    # [核心修正]: 斩除 @ 组织域，精准对齐官方的全局注册空间
    if ! npm install -g openclaw@latest > "${npm_log}" 2>&1; then
        log_error "CLI 引擎包拉取遭遇物理断层！底层 npm 死亡协议如下："
        echo -e "${YELLOW}==================== NPM ERROR ====================${NC}"
        tail -n 20 "${npm_log}"
        echo -e "${YELLOW}===================================================${NC}"
        return 1
    fi

    local oc_path
    oc_path="$(command -v openclaw || true)"
    if [ -z "${oc_path}" ]; then
        log_error "CLI 路径寻址失败。"
        return 1
    fi

    mkdir -p /opt/openclaw
    init_matrix_db

    if [[ -f /etc/systemd/system/openclaw.service ]]; then
        cp /etc/systemd/system/openclaw.service "/etc/systemd/system/openclaw.service.bak_$(date +%s)"
    fi

    cat > /etc/systemd/system/openclaw.service <<SERVICE
[Unit]
Description=OpenClaw AI Matrix Gateway
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/openclaw
Environment="DISPLAY=:99"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/usr/bin/xvfb-run -a -s "-screen 0 1920x1080x24 -ac +extension GLX +render -noreset" ${oc_path} start
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    systemctl enable openclaw >/dev/null 2>&1
    systemctl start openclaw

    sleep 2
    if service_is_active openclaw; then
        log_success "核心服务已启动。"
    else
        log_error "核心启动失败。"
        return 1
    fi
}

nuke_system() {
    require_root || return 1
    local backup_file="/root/openclaw_nuke_backup_$(date +%s).tar.gz"
    tar -czf "${backup_file}" /opt/openclaw /opt/qdrant 2>/dev/null || true
    read -p "输入 'DELETE-OPENCLAW' 执行抹除: " nuke_confirm
    [[ "${nuke_confirm}" != "DELETE-OPENCLAW" ]] && { return 0; }
    systemctl stop openclaw 2>/dev/null || true
    systemctl disable openclaw 2>/dev/null || true
    rm -f /etc/systemd/system/openclaw.service
    systemctl daemon-reload
    rm -rf /root/.openclaw /opt/openclaw
    command -v npm >/dev/null 2>&1 && npm uninstall -g openclaw >/dev/null 2>&1 || true
    command -v docker >/dev/null 2>&1 && docker rm -f qdrant >/dev/null 2>&1 || true
    rm -rf /opt/qdrant
    log_success "物理环境已清理。"
}

view_logs() {
    require_root || return 1
    journalctl -u openclaw -f
}

cmd_install_core()  { install_core; }
cmd_deploy_memory() { deploy_memory_engine; }
cmd_restart_core()  { restart_openclaw_service; }
cmd_stop_core()     { require_root || return 1; systemctl stop openclaw; log_warn "OpenClaw 已停止。"; }
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
        echo -e "       ${GREEN}OpenClaw 矩阵算力中枢 ${NC}"
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
    menu)          main_menu ;;
    status)        cmd_status ;;
    install-core)  cmd_install_core ;;
    deploy-memory) cmd_deploy_memory ;;
    restart-core)  cmd_restart_core ;;
    stop-core)     cmd_stop_core ;;
    matrix-add)    cmd_matrix_add ;;
    matrix-pause)  cmd_matrix_pause ;;
    matrix-resume) cmd_matrix_resume ;;
    matrix-delete) cmd_matrix_delete ;;
    matrix-list)   cmd_matrix_list ;;
    logs)          view_logs ;;
    nuke)          nuke_system ;;
    help|-h|--help) show_help ;;
    *)             log_error "未知命令: $1"; show_help; exit 1 ;;
esac
