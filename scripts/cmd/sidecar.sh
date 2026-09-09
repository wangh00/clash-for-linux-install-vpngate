#!/usr/bin/env bash

clashsidecar() {
    local command=${1:-status}
    [ $# -eq 0 ] || shift
    case "$command" in
    status | '')
        _sidecar_status
        ;;
    on | start)
        _sidecar_with_lock _sidecar_start_locked
        ;;
    off | stop)
        _sidecar_with_lock _sidecar_stop_locked
        ;;
    import | add)
        [ $# -eq 1 ] || {
            _errorcat '用法：clashctl sidecar import <节点分享链接>'
            return 1
        }
        _sidecar_with_lock _sidecar_import_locked "$1"
        ;;
    port)
        case "${1:-status}" in
        status | '')
            printf '配置端口：%s\n' "$(_sidecar_state_get port)"
            if [ -n "$(_sidecar_listener_line "$(_sidecar_state_get port)")" ]; then
                if _sidecar_is_active &&
                    grep -q 'xray' <<<"$(_sidecar_listener_line "$(_sidecar_state_get port)")"; then
                    printf '端口状态：监听中\n'
                else
                    printf '端口状态：被其他进程占用（冲突）\n'
                fi
                printf '监听进程：%s\n' "$(_sidecar_listener_line "$(_sidecar_state_get port)")"
            else
                printf '端口状态：未监听\n'
            fi
            ;;
        *)
            [ $# -eq 1 ] || {
                _errorcat '用法：clashctl sidecar port [端口]'
                return 1
            }
            _sidecar_with_lock _sidecar_set_port_locked "$1"
            ;;
        esac
        ;;
    test | check)
        [ $# -le 1 ] || {
            _errorcat '用法：clashctl sidecar test [URL]'
            return 1
        }
        _sidecar_test "${1:-}"
        ;;
    logs | log)
        [ $# -le 1 ] || {
            _errorcat '用法：clashctl sidecar logs [行数]'
            return 1
        }
        _sidecar_logs "${1:-80}"
        ;;
    core)
        case "${1:-version}" in
        version | status)
            if [ -x "$BIN_XRAY" ]; then
                "$BIN_XRAY" version | head -2
            else
                _errorcat 'Xray 核心尚未安装'
                return 1
            fi
            ;;
        update | upgrade)
            shift
            [ $# -le 1 ] || {
                _errorcat '用法：clashctl sidecar core update [latest|版本]'
                return 1
            }
            _sidecar_with_lock _sidecar_core_update_locked "${1:-latest}"
            ;;
        *)
            _errorcat "未知核心命令：$1"
            sidecar_help
            return 1
            ;;
        esac
        ;;
    -h | --help | help)
        sidecar_help
        ;;
    *)
        _errorcat "未知 sidecar 子命令：$command"
        sidecar_help
        return 1
        ;;
    esac
}

sidecar_help() {
    cat <<EOF
Usage:
  clashctl sidecar status
  clashctl sidecar import <节点分享链接>
  clashctl sidecar start|stop
  clashctl sidecar port [端口]
  clashctl sidecar test [URL]
  clashctl sidecar logs [行数]
  clashctl sidecar core version
  clashctl sidecar core update [latest|版本]

说明：
  - 旁代理使用独立 Xray mixed 端口，不开启第二个 TUN。
  - 启动旁代理前必须开启主 Mihomo TUN，并关闭 VPNGate。
  - 旁代理与 VPNGate 互斥，旁代理运行时 VPNGate 不能启用。
  - 核心更新固定通过主 Mihomo 代理端口下载，不依赖 TUN 状态。
  - 分享链接支持 Shadowsocks、VLESS、VMess（含旧版 Base64 JSON）和 Trojan。
  - 支持 TCP/RAW、WebSocket、gRPC、HTTP/2、HTTPUpgrade、XHTTP、mKCP，
    以及 TLS/REALITY 传输安全参数；每次导入会事务化替换当前旁代理节点。

EOF
}
