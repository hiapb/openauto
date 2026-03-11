#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/opt/openclaw-manager"
INSTANCE_DIR="${BASE_DIR}/instances"
BIN_PATH="/usr/local/bin/openclaw"

info() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1"; }
err()  { echo -e "\033[31m[ERROR]\033[0m $1" >&2; }
die()  { echo -e "\033[31m[FATAL]\033[0m $1" >&2; exit 1; }

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "请用 root 运行。"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少依赖: $1"
}

ensure_dirs() {
    mkdir -p "$INSTANCE_DIR"
}

install_openclaw() {
    info "更新系统并安装 OpenClaw ..."
    apt update -y
    apt upgrade -y
    curl -fsSL https://openclaw.ai/install.sh | bash

    if ! command -v openclaw >/dev/null 2>&1; then
        die "OpenClaw 安装后未找到命令，请检查 install.sh 输出。"
    fi

    info "OpenClaw 安装完成。"
    openclaw --help >/dev/null 2>&1 || true
}

instance_meta_file() {
    local name="$1"
    echo "${INSTANCE_DIR}/${name}.env"
}

instance_exists() {
    local name="$1"
    [[ -f "$(instance_meta_file "$name")" ]]
}

list_instances() {
    ensure_dirs
    if ! ls "${INSTANCE_DIR}"/*.env >/dev/null 2>&1; then
        warn "当前没有实例。"
        return
    fi

    echo "========================================"
    echo "实例列表"
    echo "========================================"
    for f in "${INSTANCE_DIR}"/*.env; do
        [ -e "$f" ] || continue
        # shellcheck disable=SC1090
        source "$f"
        local svc="openclaw-gateway-${PROFILE}.service"
        local active="unknown"
        if systemctl is-active --quiet "$svc"; then
            active="running"
        else
            active="stopped"
        fi
        echo "名称: ${NAME}"
        echo "Profile: ${PROFILE}"
        echo "端口: ${PORT}"
        echo "工作区: ${WORKSPACE}"
        echo "状态目录: ${STATE_DIR}"
        echo "配置文件: ${CONFIG_PATH}"
        echo "服务: ${svc}"
        echo "状态: ${active}"
        echo "----------------------------------------"
    done
}

create_instance() {
    ensure_dirs
    require_cmd openclaw

    local name=""
    local port=""
    local qq_appid=""
    local qq_secret=""
    local profile=""
    local state_dir=""
    local workspace=""
    local config_path=""
    local f=""

    read -r -p "请输入实例名称(例如 qq1): " name
    [[ -n "$name" ]] || { err "实例名不能为空"; return; }

    if instance_exists "$name"; then
        err "实例已存在。"
        return
    fi

    read -r -p "请输入基础端口(建议与其他实例至少相差 20，例如 19001): " port
    [[ "$port" =~ ^[1-9][0-9]{3,4}$ ]] || { err "端口格式无效"; return; }

    read -r -p "请输入 QQ Bot AppID: " qq_appid
    read -r -p "请输入 QQ Bot ClientSecret: " qq_secret

    profile="$name"
    state_dir="/root/.openclaw-${name}"
    workspace="/root/.openclaw/workspace-${name}"
    config_path="/root/.openclaw/${name}.json"

    mkdir -p "$state_dir" "$workspace" /root/.openclaw

    cat > "$config_path" <<EOF
{
  "gateway": {
    "mode": "local",
    "port": ${port}
  },
  "agents": {
    "defaults": {
      "workspace": "${workspace}"
    }
  },
  "channels": {
    "qqbot": {
      "enabled": true,
      "allowFrom": ["*"],
      "appId": "${qq_appid}",
      "clientSecret": "${qq_secret}"
    }
  }
}
EOF

    info "写入实例元数据..."
    f="$(instance_meta_file "$name")"
    cat > "$f" <<EOF
NAME="${name}"
PROFILE="${profile}"
PORT="${port}"
STATE_DIR="${state_dir}"
WORKSPACE="${workspace}"
CONFIG_PATH="${config_path}"
EOF

    info "安装 systemd 服务..."
    OPENCLAW_CONFIG_PATH="$config_path" \
    OPENCLAW_STATE_DIR="$state_dir" \
    openclaw --profile "$profile" gateway install || {
        err "gateway install 失败。"
        return
    }

    systemctl daemon-reload || true
    systemctl enable "openclaw-gateway-${profile}.service" || true
    systemctl restart "openclaw-gateway-${profile}.service" || true

    info "实例创建完成。"
    echo "实例名: $name"
    echo "服务名: openclaw-gateway-${profile}.service"
    echo "端口: $port"
    echo "配置: $config_path"
}

pick_instance() {
    local name=""
    read -r -p "请输入实例名称: " name
    [[ -n "$name" ]] || return 1
    instance_exists "$name" || { err "实例不存在。"; return 1; }
    echo "$name"
}

start_instance() {
    local name
    name="$(pick_instance)" || return
    # shellcheck disable=SC1090
    source "$(instance_meta_file "$name")"
    systemctl start "openclaw-gateway-${PROFILE}.service"
    info "已启动: ${name}"
}

stop_instance() {
    local name
    name="$(pick_instance)" || return
    # shellcheck disable=SC1090
    source "$(instance_meta_file "$name")"
    systemctl stop "openclaw-gateway-${PROFILE}.service"
    info "已停止: ${name}"
}

restart_instance() {
    local name
    name="$(pick_instance)" || return
    # shellcheck disable=SC1090
    source "$(instance_meta_file "$name")"
    systemctl restart "openclaw-gateway-${PROFILE}.service"
    info "已重启: ${name}"
}

status_instance() {
    local name
    name="$(pick_instance)" || return
    # shellcheck disable=SC1090
    source "$(instance_meta_file "$name")"
    systemctl status "openclaw-gateway-${PROFILE}.service" --no-pager
}

delete_instance() {
    local name=""
    local confirm=""
    name="$(pick_instance)" || return

    # shellcheck disable=SC1090
    source "$(instance_meta_file "$name")"

    echo -e "\033[31m警告：将删除实例 ${name} 的服务与配置。\033[0m"
    read -r -p "确认删除？(y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "已取消。"; return; }

    systemctl stop "openclaw-gateway-${PROFILE}.service" || true
    systemctl disable "openclaw-gateway-${PROFILE}.service" || true
    rm -f "/etc/systemd/system/openclaw-gateway-${PROFILE}.service" || true
    systemctl daemon-reload || true

    rm -f "$(instance_meta_file "$name")"
    rm -f "$CONFIG_PATH"
    rm -rf "$STATE_DIR"
    rm -rf "$WORKSPACE"

    info "实例 ${name} 已删除。"
}

main_menu() {
    clear
    echo "========================================"
    echo "         OpenClaw 多实例管理台"
    echo "========================================"
    echo " 1) 安装 OpenClaw"
    echo " 2) 创建新实例(QQ Bot)"
    echo " 3) 启动实例"
    echo " 4) 停止实例"
    echo " 5) 重启实例"
    echo " 6) 查看实例状态"
    echo " 7) 列出全部实例"
    echo " 8) 删除实例"
    echo " 0) 退出"
    echo "========================================"
}

main() {
    require_root
    ensure_dirs

    while true; do
        main_menu
        local choice=""
        read -r -p "请选择 [0-8]: " choice
        case "$choice" in
            1) install_openclaw ;;
            2) create_instance ;;
            3) start_instance ;;
            4) stop_instance ;;
            5) restart_instance ;;
            6) status_instance ;;
            7) list_instances ;;
            8) delete_instance ;;
            0) exit 0 ;;
            *) warn "无效选择。" ;;
        esac
        echo ""
        read -r -p "按回车继续..."
    done
}

main
