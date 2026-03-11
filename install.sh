#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# OpenClaw 多实例管理台
# 适用场景：
# - 一台 VPS 跑多个 OpenClaw 实例
# - 每个实例一个 QQBot，或一个实例多个 Telegram Bot
# - 实例级修复第三方 API 配置
# - 实例级 Telegram pairing 审批
# ==========================================

BASE_DIR="${HOME}/.openclaw-manager"
INSTANCE_DIR="${BASE_DIR}/instances"
OPENCLAW_DIR="${HOME}/.openclaw"

DEFAULT_BASE_PORT="19001"
PORT_STEP="20"

info() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1"; }
err()  { echo -e "\033[31m[ERROR]\033[0m $1" >&2; }
die()  { echo -e "\033[31m[FATAL]\033[0m $1" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少依赖: $1"
}

ensure_dirs() {
    mkdir -p "$INSTANCE_DIR" "$OPENCLAW_DIR"
}

instance_meta_file() {
    local name="$1"
    echo "${INSTANCE_DIR}/${name}.env"
}

instance_exists() {
    local name="$1"
    [[ -f "$(instance_meta_file "$name")" ]]
}

load_instance() {
    local name="$1"
    local f
    f="$(instance_meta_file "$name")"
    [[ -f "$f" ]] || die "实例不存在: $name"
    # shellcheck disable=SC1090
    source "$f"
}

pick_instance() {
    local name=""
    read -r -p "请输入实例名称: " name
    [[ -n "$name" ]] || return 1
    instance_exists "$name" || { err "实例不存在。"; return 1; }
    echo "$name"
}

write_instance_meta() {
    local name="$1"
    local profile="$2"
    local port="$3"
    local config_path="$4"
    local state_dir="$5"
    local workspace="$6"

    cat > "$(instance_meta_file "$name")" <<EOF
NAME="${name}"
PROFILE="${profile}"
PORT="${port}"
CONFIG_PATH="${config_path}"
STATE_DIR="${state_dir}"
WORKSPACE="${workspace}"
EOF
}

port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn "( sport = :${port} )" 2>/dev/null | grep -q ":${port} "
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | grep -q "[.:]${port}[[:space:]]"
    else
        return 1
    fi
}

next_suggested_port() {
    local count=0
    if ls "${INSTANCE_DIR}"/*.env >/dev/null 2>&1; then
        count="$(ls "${INSTANCE_DIR}"/*.env 2>/dev/null | wc -l | tr -d ' ')"
    fi
    echo $(( DEFAULT_BASE_PORT + count * PORT_STEP ))
}

instance_env() {
    # 输出供 env 使用的实例级环境变量
    local name="$1"
    load_instance "$name"
    echo "OPENCLAW_CONFIG_PATH=${CONFIG_PATH} OPENCLAW_STATE_DIR=${STATE_DIR} OPENCLAW_GATEWAY_PORT=${PORT}"
}

run_for_instance() {
    local name="$1"
    shift
    load_instance "$name"
    OPENCLAW_CONFIG_PATH="${CONFIG_PATH}" \
    OPENCLAW_STATE_DIR="${STATE_DIR}" \
    OPENCLAW_GATEWAY_PORT="${PORT}" \
    openclaw --profile "${PROFILE}" "$@"
}

systemd_user_available() {
    systemctl --user --version >/dev/null 2>&1
}

service_name() {
    local profile="$1"
    echo "openclaw-gateway-${profile}.service"
}

print_instance_summary() {
    local name="$1"
    load_instance "$name"
    echo "实例名称 : ${NAME}"
    echo "Profile  : ${PROFILE}"
    echo "端口     : ${PORT}"
    echo "配置文件 : ${CONFIG_PATH}"
    echo "状态目录 : ${STATE_DIR}"
    echo "工作区   : ${WORKSPACE}"
    echo "服务名   : $(service_name "${PROFILE}")"
}

install_openclaw() {
    require_cmd curl
    require_cmd bash

    info "开始安装 OpenClaw（官方安装器）..."
    curl -fsSL https://openclaw.ai/install.sh | bash

    if ! command -v openclaw >/dev/null 2>&1; then
        die "安装后仍未找到 openclaw 命令，请检查安装器输出。"
    fi

    info "OpenClaw 安装完成。"
    warn "如果你打算让 systemd --user 常驻服务在退出 SSH 后继续运行，建议执行："
    echo "      loginctl enable-linger ${USER}"
}

create_instance() {
    require_cmd openclaw
    require_cmd python3
    ensure_dirs

    local name=""
    local port=""
    local config_path=""
    local state_dir=""
    local workspace=""
    local suggested_port=""

    read -r -p "请输入实例名称（例如 qq1 / tg-main）: " name
    [[ -n "$name" ]] || { err "实例名不能为空。"; return; }

    if instance_exists "$name"; then
        err "实例已存在。"
        return
    fi

    suggested_port="$(next_suggested_port)"
    read -r -p "请输入基础端口 [默认: ${suggested_port}]（建议不同实例至少相差 ${PORT_STEP}）: " port
    port="${port:-$suggested_port}"

    if [[ ! "$port" =~ ^[1-9][0-9]{3,4}$ ]] || (( port > 65535 )); then
        err "端口无效。"
        return
    fi

    if port_in_use "$port"; then
        err "端口 ${port} 已被占用。"
        return
    fi

    config_path="${OPENCLAW_DIR}/${name}.json"
    state_dir="${HOME}/.openclaw-${name}"
    workspace="${OPENCLAW_DIR}/workspace-${name}"

    mkdir -p "$state_dir" "$workspace"

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
  "channels": {}
}
EOF

    write_instance_meta "$name" "$name" "$port" "$config_path" "$state_dir" "$workspace"

    info "安装实例级 Gateway 服务..."
    run_for_instance "$name" gateway install --port "$port" || {
        err "gateway install 失败。"
        return
    }

    if systemd_user_available; then
        systemctl --user daemon-reload || true
        systemctl --user enable "$(service_name "$name")" >/dev/null 2>&1 || true
        systemctl --user restart "$(service_name "$name")" || true
    fi

    info "实例创建完成。"
    print_instance_summary "$name"
}

delete_instance() {
    local name=""
    local confirm=""
    name="$(pick_instance)" || return
    load_instance "$name"

    echo -e "\033[31m将删除实例 ${name} 的配置、状态目录、工作区及服务。\033[0m"
    read -r -p "确认删除？(y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "已取消。"; return; }

    run_for_instance "$name" gateway stop >/dev/null 2>&1 || true
    run_for_instance "$name" gateway uninstall >/dev/null 2>&1 || true

    if systemd_user_available; then
        systemctl --user daemon-reload || true
    fi

    rm -f "$CONFIG_PATH"
    rm -rf "$STATE_DIR" "$WORKSPACE"
    rm -f "$(instance_meta_file "$name")"

    info "实例 ${name} 已删除。"
}

list_instances() {
    ensure_dirs
    if ! ls "${INSTANCE_DIR}"/*.env >/dev/null 2>&1; then
        warn "当前没有任何实例。"
        return
    fi

    echo "=================================================="
    echo "OpenClaw 实例列表"
    echo "=================================================="
    for f in "${INSTANCE_DIR}"/*.env; do
        [ -e "$f" ] || continue
        # shellcheck disable=SC1090
        source "$f"
        local status="unknown"
        if systemd_user_available; then
            if systemctl --user is-active --quiet "$(service_name "${PROFILE}")"; then
                status="running"
            else
                status="stopped"
            fi
        fi
        echo "名称   : ${NAME}"
        echo "端口   : ${PORT}"
        echo "配置   : ${CONFIG_PATH}"
        echo "状态   : ${status}"
        echo "服务   : $(service_name "${PROFILE}")"
        echo "----------------------------------------------"
    done
}

start_instance() {
    local name=""
    name="$(pick_instance)" || return
    run_for_instance "$name" gateway start
    info "实例已启动：$name"
}

stop_instance() {
    local name=""
    name="$(pick_instance)" || return
    run_for_instance "$name" gateway stop
    info "实例已停止：$name"
}

restart_instance() {
    local name=""
    name="$(pick_instance)" || return
    run_for_instance "$name" gateway restart
    info "实例已重启：$name"
}

status_instance() {
    local name=""
    name="$(pick_instance)" || return

    print_instance_summary "$name"
    echo "--------------------------------------------------"
    run_for_instance "$name" gateway status || true
}

health_instance() {
    local name=""
    name="$(pick_instance)" || return
    load_instance "$name"
    run_for_instance "$name" gateway health --url "ws://127.0.0.1:${PORT}"
}

logs_instance() {
    local name=""
    name="$(pick_instance)" || return
    local mode=""
    read -r -p "1) CLI 日志  2) systemd 日志 [1/2]: " mode

    if [[ "$mode" == "2" ]]; then
        if ! systemd_user_available; then
            err "当前环境不可用 systemctl --user。"
            return
        fi
        load_instance "$name"
        journalctl --user -u "$(service_name "$PROFILE")" -n 200 --no-pager
    else
        run_for_instance "$name" channels logs --channel all || true
    fi
}

# ---- JSON 编辑助手 ----

json_edit_python() {
    local config="$1"
    local script="$2"
    python3 - "$config" <<PY
import json, os, sys
cfg_path = sys.argv[1]
with open(cfg_path, "r", encoding="utf-8") as f:
    data = json.load(f)
${script}
with open(cfg_path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\\n")
PY
}

ensure_channels_object() {
    local config="$1"
    json_edit_python "$config" '
data.setdefault("channels", {})
'
}

set_qqbot() {
    local name=""
    local app_id=""
    local secret=""

    name="$(pick_instance)" || return
    load_instance "$name"

    read -r -p "请输入 QQBot AppID: " app_id
    read -r -p "请输入 QQBot ClientSecret: " secret

    [[ -n "$app_id" && -n "$secret" ]] || { err "AppID / Secret 不能为空。"; return; }

    json_edit_python "$CONFIG_PATH" "
data.setdefault('channels', {})
data['channels']['qqbot'] = {
    'enabled': True,
    'allowFrom': ['*'],
    'appId': '${app_id}',
    'clientSecret': '${secret}'
}
"
    info "已写入实例 ${name} 的 qqbot 配置。"
    run_for_instance "$name" gateway restart || true
}

remove_qqbot() {
    local name=""
    name="$(pick_instance)" || return
    load_instance "$name"

    json_edit_python "$CONFIG_PATH" "
data.setdefault('channels', {})
data['channels'].pop('qqbot', None)
"
    info "已移除实例 ${name} 的 qqbot 配置。"
    run_for_instance "$name" gateway restart || true
}

set_telegram_default() {
    local name=""
    local token=""

    name="$(pick_instance)" || return
    load_instance "$name"

    read -r -p "请输入 Telegram 默认 Bot Token: " token
    [[ -n "$token" ]] || { err "Token 不能为空。"; return; }

    json_edit_python "$CONFIG_PATH" "
data.setdefault('channels', {})
tg = data['channels'].setdefault('telegram', {})
tg['enabled'] = True
tg['botToken'] = '${token}'
tg.setdefault('dmPolicy', 'pairing')
tg.setdefault('groupPolicy', 'allowlist')
tg.setdefault('streaming', 'partial')
"
    info "已写入 Telegram 默认 bot。"
    run_for_instance "$name" gateway restart || true
}

add_telegram_account() {
    local name=""
    local account_name=""
    local token=""

    name="$(pick_instance)" || return
    load_instance "$name"

    read -r -p "请输入 Telegram 账户名（例如 main / bot2）: " account_name
    read -r -p "请输入该账户的 Bot Token: " token

    [[ -n "$account_name" && -n "$token" ]] || { err "账户名和 Token 不能为空。"; return; }

    json_edit_python "$CONFIG_PATH" "
data.setdefault('channels', {})
tg = data['channels'].setdefault('telegram', {})
tg['enabled'] = True
accounts = tg.setdefault('accounts', {})
accounts['${account_name}'] = {
    'name': '${account_name}',
    'token': '${token}'
}
tg.setdefault('dmPolicy', 'pairing')
tg.setdefault('groupPolicy', 'allowlist')
tg.setdefault('streaming', 'partial')
"
    info "已添加/更新 Telegram 账户：${account_name}"
    run_for_instance "$name" gateway restart || true
}

remove_telegram_account() {
    local name=""
    local account_name=""

    name="$(pick_instance)" || return
    load_instance "$name"

    read -r -p "请输入要删除的 Telegram 账户名: " account_name
    [[ -n "$account_name" ]] || { err "账户名不能为空。"; return; }

    json_edit_python "$CONFIG_PATH" "
data.setdefault('channels', {})
tg = data['channels'].setdefault('telegram', {})
accounts = tg.setdefault('accounts', {})
accounts.pop('${account_name}', None)
"
    info "已删除 Telegram 账户：${account_name}"
    run_for_instance "$name" gateway restart || true
}

show_config_path() {
    local name=""
    name="$(pick_instance)" || return
    load_instance "$name"
    echo "$CONFIG_PATH"
}

show_config_snippet() {
    local name=""
    name="$(pick_instance)" || return
    load_instance "$name"
    python3 - "$CONFIG_PATH" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, 'r', encoding='utf-8') as f:
    data = json.load(f)
print(json.dumps(data.get("channels", {}), ensure_ascii=False, indent=2))
PY
}

# ---- 第三方 API 兼容修复 ----
# 你的旧 sed 做的是：
# 1) 把任意对象里的 "profile":"coding" 改为 "minimal"
# 2) 对含 baseUrl 的对象补 headers.User-Agent=curl/8.0.1
# 这里改成用 Python 递归处理 JSON，更稳一点。

repair_provider_config() {
    local name=""
    name="$(pick_instance)" || return
    load_instance "$name"

    python3 - "$CONFIG_PATH" <<'PY'
import json, sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

def walk(node):
    if isinstance(node, dict):
        if node.get("profile") == "coding":
            node["profile"] = "minimal"
        if "baseUrl" in node:
            headers = node.get("headers")
            if not isinstance(headers, dict):
                headers = {}
                node["headers"] = headers
            headers.setdefault("User-Agent", "curl/8.0.1")
        for v in node.values():
            walk(v)
    elif isinstance(node, list):
        for item in node:
            walk(item)

walk(data)

with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

    info "已对实例 ${name} 执行第三方 API 常见兼容修复。"
    run_for_instance "$name" gateway restart || true
}

# ---- Telegram pairing ----

pairing_list_telegram() {
    local name=""
    name="$(pick_instance)" || return
    run_for_instance "$name" pairing list telegram
}

pairing_approve_telegram() {
    local name=""
    local code=""
    name="$(pick_instance)" || return
    read -r -p "请输入 Telegram pairing code（例如 RA97GG5C）: " code
    [[ -n "$code" ]] || { err "code 不能为空。"; return; }
    run_for_instance "$name" pairing approve telegram "$code"
}

# ---- 备份 / 恢复 ----

backup_instance() {
    local name=""
    local backup_dir=""
    local ts=""
    local file=""
    name="$(pick_instance)" || return
    load_instance "$name"

    backup_dir="${BASE_DIR}/backups"
    mkdir -p "$backup_dir"
    ts="$(date +"%Y%m%d_%H%M%S")"
    file="${backup_dir}/${name}_${ts}.tar.gz"

    tar -czf "$file" \
        "$(instance_meta_file "$name")" \
        "$CONFIG_PATH" \
        "$STATE_DIR" \
        "$WORKSPACE"

    info "备份完成：$file"
}

# ---- 菜单 ----

menu_install() {
    echo " 1) 安装 OpenClaw"
    echo " 2) 创建实例"
    echo " 3) 删除实例"
    echo ""
    echo " 4) 启动实例"
    echo " 5) 停止实例"
    echo " 6) 重启实例"
    echo " 7) 查看实例状态"
    echo " 8) 健康检查"
    echo " 9) 查看日志"
    echo "10) 列出全部实例"
    echo ""
    echo "11) 配置 QQBot"
    echo "12) 删除 QQBot"
    echo "13) 配置 Telegram 默认 Bot"
    echo "14) 添加/更新 Telegram 多账号"
    echo "15) 删除 Telegram 多账号"
    echo "16) 查看当前 channels 配置"
    echo ""
    echo "17) 修复第三方 API 兼容项"
    echo "18) 查看 Telegram pairing 列表"
    echo "19) 批准 Telegram pairing"
    echo ""
    echo "20) 备份实例"
    echo "21) 查看实例配置文件路径"
    echo " 0) 退出"
}

main_menu() {
    clear
    echo "=================================================="
    echo "          OpenClaw 多实例菜单管理台"
    echo "=================================================="
    echo "当前用户: ${USER}"
    echo "实例目录: ${INSTANCE_DIR}"
    echo "OpenClaw 配置根目录: ${OPENCLAW_DIR}"
    echo "--------------------------------------------------"
    menu_install
    echo "=================================================="
}

main() {
    require_cmd python3
    ensure_dirs

    while true; do
        main_menu
        local choice=""
        read -r -p "请选择操作 [0-21]: " choice
        case "$choice" in
            1) install_openclaw ;;
            2) create_instance ;;
            3) delete_instance ;;
            4) start_instance ;;
            5) stop_instance ;;
            6) restart_instance ;;
            7) status_instance ;;
            8) health_instance ;;
            9) logs_instance ;;
            10) list_instances ;;
            11) set_qqbot ;;
            12) remove_qqbot ;;
            13) set_telegram_default ;;
            14) add_telegram_account ;;
            15) remove_telegram_account ;;
            16) show_config_snippet ;;
            17) repair_provider_config ;;
            18) pairing_list_telegram ;;
            19) pairing_approve_telegram ;;
            20) backup_instance ;;
            21) show_config_path ;;
            0) info "退出。"; exit 0 ;;
            *) warn "无效选择。" ;;
        esac
        echo ""
        read -r -p "按回车返回主菜单..."
    done
}

main
