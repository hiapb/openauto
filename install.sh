#!/usr/bin/env bash

set -Eeuo pipefail

trap 'rc=$?; printf "\033[0;31m[ERROR] 第 %s 行执行失败，退出码 %s\033[0m\n" "${LINENO}" "$rc" >&2' ERR

# ==========================================
# UI 与日志
# ==========================================
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

pause() {
    echo
    read -n 1 -s -r -p "按任意键继续..."
    echo
}

# ==========================================
# 基础工具函数
# ==========================================
require_root() {
    if [ "${EUID}" -ne 0 ]; then
        log_error "此操作需要 root 权限。请使用 root 运行，或在外层使用 sudo。"
        return 1
    fi
}

require_cmd() {
    local cmd="$1"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        log_error "缺少必要命令: ${cmd}"
        return 1
    fi
}

service_is_active() {
    local svc="$1"
    systemctl is-active --quiet "${svc}" 2>/dev/null
}

container_is_running_exact() {
    local name="$1"
    if ! command -v docker >/dev/null 2>&1; then
        return 1
    fi
    docker ps --format '{{.Names}}' | grep -qx "${name}"
}

wait_for_http() {
    local url="$1"
    local retries="${2:-20}"
    local delay="${3:-2}"
    local i

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

restart_openclaw_service() {
    require_root || return 1

    systemctl restart openclaw
    sleep 2

    if service_is_active openclaw; then
        log_success "OpenClaw 服务已成功重启并通过验活。"
        return 0
    fi

    log_error "OpenClaw 服务重启失败。请检查日志: journalctl -u openclaw -n 80 --no-pager"
    return 1
}

# ==========================================
# 环境检查
# ==========================================
check_env() {
    if ! command -v apt-get >/dev/null 2>&1; then
        log_error "当前系统不受支持。仅支持 Debian/Ubuntu 系（依赖 apt-get）。"
        exit 1
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        log_error "当前系统缺少 systemd/systemctl，脚本无法继续。"
        exit 1
    fi

    if ! curl -fsS --max-time 5 https://registry.npmjs.org >/dev/null 2>&1; then
        log_warn "npm 官方源连通性不佳，后续安装可能失败或变慢。"
    fi

    if ! curl -fsS --max-time 5 https://deb.nodesource.com >/dev/null 2>&1; then
        log_warn "NodeSource 连通性不佳，Node.js 安装步骤可能失败。"
    fi
}

# ==========================================
# 状态探针
# ==========================================
check_core_status() {
    if service_is_active openclaw; then
        printf "${GREEN}运行中${NC}"
    else
        printf "${RED}已离线${NC}"
    fi
}

check_memory_status() {
    if container_is_running_exact qdrant; then
        printf "${GREEN}活跃${NC}"
    else
        printf "${RED}休眠${NC}"
    fi
}

# ==========================================
# Docker / Node / OpenClaw 检查
# ==========================================
ensure_docker() {
    require_root || return 1

    if command -v docker >/dev/null 2>&1; then
        log_info "Docker 已存在，跳过安装。"
        systemctl enable --now docker >/dev/null 2>&1 || true
        return 0
    fi

    log_warn "未检测到 Docker，正在执行官方安装脚本。"
    curl -fsSL https://get.docker.com | bash

    systemctl enable --now docker

    require_cmd docker
    log_success "Docker 已安装并启动。"
}

ensure_node20() {
    require_root || return 1

    if command -v node >/dev/null 2>&1; then
        if node -v | grep -q '^v20\.'; then
            log_info "Node.js V20 已存在，跳过安装。"
            return 0
        fi
        log_warn "检测到 Node.js，但版本不是 V20，将尝试覆盖安装。"
    fi

    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs >/dev/null 2>&1

    if ! command -v node >/dev/null 2>&1; then
        log_error "Node.js 安装后仍不可用。"
        return 1
    fi

    if ! node -v | grep -q '^v20\.'; then
        log_error "Node.js 安装完成，但版本不符合预期（需要 v20.x）。当前版本: $(node -v)"
        return 1
    fi

    log_success "Node.js V20 安装成功。"
}

# ==========================================
# 矩阵状态机与本地影子注册表
# ==========================================
MATRIX_DB="/opt/openclaw/matrix.db"

init_matrix_db() {
    mkdir -p /opt/openclaw
    if [[ ! -f "${MATRIX_DB}" ]]; then
        touch "${MATRIX_DB}"
        chmod 600 "${MATRIX_DB}" # 锁死权限
    fi
}

_gateway_inject() {
    local alias="$1" platform="$2" cred1="$3" cred2="$4"
    if [[ "${platform}" == "qq" ]]; then
        ( export OC_TEMP="${cred1}:${cred2}"; openclaw channels add --channel "${alias}" --token "${OC_TEMP}" >/dev/null 2>&1 )
    elif [[ "${platform}" == "tg" ]]; then
        openclaw channels add --channel "${alias}" --token "${cred1}" >/dev/null 2>&1
    fi
}

_gateway_eject() {
    openclaw channels remove --channel "$1" >/dev/null 2>&1 || true
}

list_matrix() {
    clear
    echo -e "${CYAN}=== 当前神经元矩阵状态池 ===${NC}"
    if [[ ! -s "${MATRIX_DB}" ]]; then
        echo -e "${YELLOW}注册表为空，暂无机器人节点。${NC}"
        return
    fi
    printf "%-18s | %-8s | %-10s\n" "节点代号 (Alias)" "通讯协议" "运行时状态"
    echo "------------------------------------------------"
    while IFS='|' read -r alias platform status c1 c2; do
        if [[ "${status}" == "active" ]]; then
            printf "%-18s | %-8s | ${GREEN}%-10s${NC}\n" "${alias}" "${platform}" "[运行中]"
        else
            printf "%-18s | %-8s | ${YELLOW}%-10s${NC}\n" "${alias}" "${platform}" "[已暂停]"
        fi
    done < "${MATRIX_DB}"
    echo "------------------------------------------------"
}

add_matrix_node() {
    require_root || return 1
    require_cmd openclaw || return 1
    init_matrix_db

    local alias platform c1 c2 plat_choice
    read -p "请输入唯一的节点代号 (如 qq_01, tg_main): " alias
    [[ -z "${alias}" ]] && { log_error "代号不能为空"; return 1; }
    if grep -q "^${alias}|" "${MATRIX_DB}"; then
        log_error "节点代号 [${alias}] 已存在，请使用其他命名！"; return 1
    fi

    echo -e "1) QQ 官方协议   2) Telegram 协议"
    read -p "选择平台(1-2): " plat_choice
    if [[ "${plat_choice}" == "1" ]]; then
        platform="qq"
        read -p "输入 QQ AppID: " c1
        read -s -p "输入 QQ AppSecret: " c2; echo
        [[ -z "${c1}" || -z "${c2}" ]] && { log_error "凭证缺失"; return 1; }
        openclaw plugins install @sliverp/qqbot@latest >/dev/null 2>&1 || true
    elif [[ "${plat_choice}" == "2" ]]; then
        platform="tg"
        read -s -p "输入 TG Bot Token: " c1; echo
        c2="none"
        [[ -z "${c1}" ]] && { log_error "凭证缺失"; return 1; }
    else
        log_error "无效选择"; return 1
    fi

    echo "${alias}|${platform}|active|${c1}|${c2}" >> "${MATRIX_DB}"
    _gateway_inject "${alias}" "${platform}" "${c1}" "${c2}"
    
    openclaw gateway restart
    restart_openclaw_service
    log_success "节点 [${alias}] 已挂载并激活。"
}

pause_matrix_node() {
    require_root || return 1
    require_cmd openclaw || return 1
    
    local alias record r_plat
    read -p "请输入需要【暂停】的节点代号: " alias
    record=$(grep "^${alias}|" "${MATRIX_DB}" || true)
    [[ -z "${record}" ]] && { log_error "未找到该节点"; return 1; }
    
    IFS='|' read -r _ r_plat r_status r_c1 r_c2 <<< "${record}"
    [[ "${r_status}" == "paused" ]] && { log_warn "节点已经是休眠状态。"; return 0; }

    # 防御性更新数据库
    grep -v "^${alias}|" "${MATRIX_DB}" > "${MATRIX_DB}.tmp"
    echo "${alias}|${r_plat}|paused|${r_c1}|${r_c2}" >> "${MATRIX_DB}.tmp"
    mv "${MATRIX_DB}.tmp" "${MATRIX_DB}"
    
    _gateway_eject "${alias}"
    openclaw gateway restart
    restart_openclaw_service
    log_warn "节点 [${alias}] 已物理断开，配置封存。"
}

resume_matrix_node() {
    require_root || return 1
    require_cmd openclaw || return 1

    local alias record
    read -p "请输入需要【唤醒】的节点代号: " alias
    record=$(grep "^${alias}|" "${MATRIX_DB}" || true)
    [[ -z "${record}" ]] && { log_error "未找到该节点"; return 1; }
    
    IFS='|' read -r r_alias r_plat r_status r_c1 r_c2 <<< "${record}"
    [[ "${r_status}" == "active" ]] && { log_warn "该节点已在运行中。"; return 0; }

    grep -v "^${alias}|" "${MATRIX_DB}" > "${MATRIX_DB}.tmp"
    echo "${alias}|${r_plat}|active|${r_c1}|${r_c2}" >> "${MATRIX_DB}.tmp"
    mv "${MATRIX_DB}.tmp" "${MATRIX_DB}"
    
    _gateway_inject "${r_alias}" "${r_plat}" "${r_c1}" "${r_c2}"
    openclaw gateway restart
    restart_openclaw_service
    log_success "节点 [${alias}] 唤醒成功。"
}

delete_matrix_node() {
    require_root || return 1
    require_cmd openclaw || return 1

    local alias
    read -p "请输入需要【永久销毁】的节点代号: " alias
    grep -q "^${alias}|" "${MATRIX_DB}" || { log_error "未找到该节点"; return 1; }
    
    read -p "确认彻底销毁 [${alias}]？(y/n): " confirm
    [[ "${confirm}" != "y" && "${confirm}" != "Y" ]] && return 0

    grep -v "^${alias}|" "${MATRIX_DB}" > "${MATRIX_DB}.tmp"
    mv "${MATRIX_DB}.tmp" "${MATRIX_DB}"
    
    _gateway_eject "${alias}"
    openclaw gateway restart
    restart_openclaw_service
    log_success "节点 [${alias}] 已永久抹除。"
}

manage_channels() {
    require_root || return
    require_cmd openclaw || { pause; return; }
    init_matrix_db

    while true; do
        list_matrix
        echo -e "${CYAN}=================================================${NC}"
        echo -e " ${GREEN}1.${NC} ➕ 新增挂载 (Add)"
        echo -e " ${YELLOW}2.${NC} ⏸️  暂停节点 (Pause)"
        echo -e " ${GREEN}3.${NC} ▶️  唤醒节点 (Resume)"
        echo -e " ${RED}4.${NC} 🗑️  永久销毁 (Delete)"
        echo -e " ${BLUE}0.${NC} ↩️  返回主菜单"
        echo -e "${CYAN}=================================================${NC}"
        read -r -p "下达指令 (0-4): " ch_choice

        case "${ch_choice}" in
            1) add_matrix_node; pause ;;
            2) pause_matrix_node; pause ;;
            3) resume_matrix_node; pause ;;
            4) delete_matrix_node; pause ;;
            0) break ;;
            *) log_error "无效指令"; sleep 1 ;;
        esac
    done
}

# ==========================================
# 记忆引擎部署
# ==========================================
deploy_memory_engine() {
    require_root || return 1

    clear
    log_info "开始部署 Qdrant 向量记忆库..."

    ensure_docker
    mkdir -p /opt/qdrant/storage
    docker rm -f qdrant >/dev/null 2>&1 || true

    log_info "创建并启动 qdrant 容器..."
    docker run -d --name qdrant \
        -p 6333:6333 \
        -p 6334:6334 \
        -v /opt/qdrant/storage:/qdrant/storage \
        --restart always \
        qdrant/qdrant >/dev/null

    log_info "等待 Qdrant 完成冷启动..."
    if wait_for_http "http://localhost:6333/healthz" 20 2 || wait_for_http "http://localhost:6333" 20 2; then
        echo
        if container_is_running_exact qdrant; then
            log_success "Qdrant 已成功启动并通过健康检查。"
        else
            log_error "Qdrant HTTP 接口可达，但容器状态异常。请检查: docker ps -a"
            return 1
        fi
    else
        echo
        log_error "Qdrant 健康检查超时。请查看日志: docker logs qdrant"
        return 1
    fi
}

# ==========================================
# 核心部署
# ==========================================
install_core() {
    require_root || return 1

    clear
    log_info "开始部署 OpenClaw 核心算力底座..."
    export DEBIAN_FRONTEND=noninteractive

    log_info "安装系统依赖..."
    apt-get update -y >/dev/null 2>&1
    apt-get install -y \
        curl wget git xvfb fluxbox x11vnc jq \
        libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
        libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
        libgbm1 libasound2 fonts-wqy-zenhei fonts-wqy-microhei >/dev/null 2>&1

    require_cmd xvfb-run
    ensure_node20

    log_info "安装 OpenClaw CLI..."
    npm install -g @openclaw/cli >/dev/null 2>&1

    local oc_path
    oc_path="$(command -v openclaw || true)"
    if [ -z "${oc_path}" ]; then
        log_error "OpenClaw CLI 安装后无法定位可执行文件。"
        return 1
    fi

    mkdir -p /opt/openclaw
    init_matrix_db

    log_info "写入 systemd 服务..."
    cat > /etc/systemd/system/openclaw.service <<SERVICE
[Unit]
Description=OpenClaw AI Gateway Daemon
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
        log_success "OpenClaw 核心服务已启动并通过验活。"
    else
        log_error "OpenClaw 服务启动失败。请查看日志: journalctl -u openclaw -n 80 --no-pager"
        return 1
    fi
}

# ==========================================
# 安全销毁
# ==========================================
nuke_system() {
    require_root || return 1

    log_warn "警告：此操作将删除 OpenClaw、本地数据、Qdrant 容器与相关目录。"
    read -p "请输入安全校验码 'DELETE-OPENCLAW' 确认执行: " nuke_confirm

    if [[ "${nuke_confirm}" != "DELETE-OPENCLAW" ]]; then
        log_warn "安全校验失败或已取消，终止销毁。"
        return 0
    fi

    log_info "停止并移除 OpenClaw 服务..."
    systemctl stop openclaw 2>/dev/null || true
    systemctl disable openclaw 2>/dev/null || true
    rm -f /etc/systemd/system/openclaw.service
    systemctl daemon-reload

    log_info "清理 OpenClaw 数据及注册表..."
    rm -rf /root/.openclaw /opt/openclaw

    if command -v npm >/dev/null 2>&1; then
        npm uninstall -g @openclaw/cli >/dev/null 2>&1 || true
    fi

    if command -v docker >/dev/null 2>&1; then
        log_info "清理 Qdrant 容器与数据..."
        docker rm -f qdrant >/dev/null 2>&1 || true
    fi
    rm -rf /opt/qdrant

    log_success "OpenClaw 与 Qdrant 相关痕迹已清除。"
}

# ==========================================
# 日志查看
# ==========================================
view_logs() {
    require_root || return 1
    journalctl -u openclaw -f
}

# ==========================================
# 命令模式 (暴露给外部脚本与 CI/CD 调度)
# ==========================================
cmd_install_core()  { install_core; }
cmd_deploy_memory() { deploy_memory_engine; }
cmd_restart_core()  { require_root || return 1; restart_openclaw_service; }
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

# ==========================================
# 菜单模式
# ==========================================
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}=================================================${NC}"
        echo -e "       ${GREEN}OpenClaw 矩阵算力中枢 (V3.1 终极融合版)${NC}"
        echo -e "       算力状态: $(check_core_status) | 记忆状态: $(check_memory_status)"
        echo -e "${BLUE}=================================================${NC}"
        echo -e " ${YELLOW}1.${NC} 🚀 部署 AI 算力底座 (Node/Xvfb/Systemd)"
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

# ==========================================
# 入口路由
# ==========================================
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
    *)
        log_error "未知命令: $1"
        show_help
        exit 1
        ;;
esac
