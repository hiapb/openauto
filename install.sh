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
# 通道管理
# ==========================================
add_qq_channel() {
    require_root || return 1
    require_cmd openclaw || return 1

    local qq_appid qq_secret

    read -p "请输入 QQ AppID: " qq_appid
    if [ -z "${qq_appid}" ]; then
        log_error "AppID 不能为空。"
        return 1
    fi

    read -s -p "请输入 QQ AppSecret: " qq_secret
    echo
    if [ -z "${qq_secret}" ]; then
        log_error "AppSecret 不能为空。"
        return 1
    fi

    log_info "安装 QQ 插件..."
    openclaw plugins install @sliverp/qqbot@latest

    log_warn "注意：受上游 openclaw CLI 参数设计限制，token 仍通过 --token 传入，理论上可能暴露在进程参数中。"

    log_info "注入 QQ 通道配置..."
    openclaw channels add --channel qqbot --token "${qq_appid}:${qq_secret}"

    log_info "热重载 OpenClaw 网关..."
    openclaw gateway restart
    restart_openclaw_service
}

remove_qq_channel() {
    require_root || return 1
    require_cmd openclaw || return 1

    read -p "确认摘除 QQ 通道？(y/n): " confirm
    if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
        log_warn "已取消。"
        return 0
    fi

    openclaw channels remove --channel qqbot
    restart_openclaw_service
}

manage_channels() {
    require_root || return
    require_cmd openclaw || { pause; return; }

    while true; do
        clear
        echo -e "${CYAN}=================================================${NC}"
        echo -e "       ${YELLOW}多端通道接入总线${NC}"
        echo -e "${CYAN}=================================================${NC}"
        echo -e " ${GREEN}1.${NC} 接入 QQ 官方协议"
        echo -e " ${RED}2.${NC} 摘除 QQ 通道"
        echo -e " ${YELLOW}0.${NC} 返回上一级"
        echo -e "${CYAN}=================================================${NC}"
        read -r -p "指令输入 (0-2): " ch_choice

        case "${ch_choice}" in
            1) add_qq_channel; pause ;;
            2) remove_qq_channel; pause ;;
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

    log_info "清理 OpenClaw 数据..."
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
# 命令模式
# ==========================================
cmd_install_core() {
    install_core
}

cmd_deploy_memory() {
    deploy_memory_engine
}

cmd_restart_core() {
    require_root || return 1
    restart_openclaw_service
}

cmd_stop_core() {
    require_root || return 1
    systemctl stop openclaw
    log_warn "OpenClaw 服务已停止。"
}

cmd_add_qq() {
    add_qq_channel
}

cmd_remove_qq() {
    remove_qq_channel
}

cmd_status() {
    printf "算力状态: %b | 记忆状态: %b\n" "$(check_core_status)" "$(check_memory_status)"
}

show_help() {
    cat <<'EOF'
用法:
  ./openclaw_master.sh                 进入交互菜单
  ./openclaw_master.sh status         查看状态
  ./openclaw_master.sh install-core   部署 OpenClaw 核心
  ./openclaw_master.sh deploy-memory  部署 Qdrant
  ./openclaw_master.sh restart-core   重启 OpenClaw
  ./openclaw_master.sh stop-core      停止 OpenClaw
  ./openclaw_master.sh add-qq         添加 QQ 通道
  ./openclaw_master.sh remove-qq      删除 QQ 通道
  ./openclaw_master.sh logs           查看 OpenClaw 日志
  ./openclaw_master.sh nuke           销毁 OpenClaw 与 Qdrant
  ./openclaw_master.sh help           显示帮助
EOF
}

# ==========================================
# 菜单模式
# ==========================================
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}=================================================${NC}"
        echo -e "       ${GREEN}OpenClaw 部署基座 ${NC}"
        echo -e "       算力状态: $(check_core_status) | 记忆状态: $(check_memory_status)"
        echo -e "${BLUE}=================================================${NC}"
        echo -e " ${YELLOW}1.${NC} 🚀 部署 AI 算力底座"
        echo -e " ${CYAN}2.${NC} 🧠 部署 Qdrant 向量记忆库"
        echo -e " ${CYAN}3.${NC} 📡 通道接入管理"
        echo -e " ${YELLOW}4.${NC} 🔄 重启核心引擎"
        echo -e " ${YELLOW}5.${NC} 🛑 停止核心引擎"
        echo -e " ${YELLOW}6.${NC} 📜 查看 OpenClaw 日志"
        echo -e " ${RED}9.${NC} ☢️  安全销毁系统"
        echo -e " ${YELLOW}0.${NC} 🚪 退出"
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
# 入口
# ==========================================
check_env

case "${1:-menu}" in
    menu)          main_menu ;;
    status)        cmd_status ;;
    install-core)  cmd_install_core ;;
    deploy-memory) cmd_deploy_memory ;;
    restart-core)  cmd_restart_core ;;
    stop-core)     cmd_stop_core ;;
    add-qq)        cmd_add_qq ;;
    remove-qq)     cmd_remove_qq ;;
    logs)          view_logs ;;
    nuke)          nuke_system ;;
    help|-h|--help) show_help ;;
    *)
        log_error "未知命令: $1"
        show_help
        exit 1
        ;;
esac
