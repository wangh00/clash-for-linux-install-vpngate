#!/usr/bin/env bash

clashoff() {
    local mode=all force=false
    while [ $# -gt 0 ]; do
        case "$1" in
        -e | --env-only) mode=env ;;
        -s | --service-only) mode=service ;;
        -f | --force) force=true ;;
        -h | --help) off_help; return 0 ;;
        *) _errorcat "未知选项：$1"; return 1 ;;
        esac
        shift
    done

    case "$mode" in
    env) off_env_only ;;
    service)
        off_service_only "$force" || return
        [ -n "$http_proxy" ] && _failcat "警告：当前终端代理未关闭"
        ;;
    all)
        off_service_only "$force" || return
        off_env_only
        ;;
    esac
}

off_env_only() {
    unset_system_proxy
    _okcat "终端代理已关闭"
}
off_service_only() {
    local force=${1:-false}
    if [ "$(_vpngate_state_get enabled 2>/dev/null)" = true ] && [ "$force" != true ]; then
        _errorcat "VPNGate 正在运行，直接停止 Mihomo 会中断 TUN 并使定时更新失败"
        _failcat "请先执行 clashctl vpngate off；维护场景可显式使用 clashctl off --service-only --force" || true
        return 1
    fi
    service_is_active >&/dev/null && {
        service_stop >/dev/null
        service_is_active >&/dev/null && tunstatus >&/dev/null && {
            service_sudo_stop || _errorcat "请先关闭 Tun 模式" || return
        }
        service_is_active >&/dev/null && {
            _failcat "$CLASHCTL_KERNEL 停止失败"
            return 1
        }
    }
    _okcat "$CLASHCTL_KERNEL 已停止"
}

unset_system_proxy() {
    unset http_proxy
    unset https_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
    unset all_proxy
    unset ALL_PROXY
    unset no_proxy
    unset NO_PROXY
}

off_help() {
    cat <<EOF

clashctl off - 关闭代理环境

Usage:
  clashctl off [OPTIONS]

Options:
  -s, --service-only 仅关闭 $CLASHCTL_KERNEL 服务
  -e, --env-only     仅关闭终端代理
  -f, --force        VPNGate 运行时仍强制停止服务（维护用途）
  -h, --help         显示帮助信息

EOF
}
