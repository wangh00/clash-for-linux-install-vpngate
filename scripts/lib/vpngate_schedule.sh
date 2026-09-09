#!/usr/bin/env bash

VPNGATE_SCHEDULE_UNIT="clashctl-vpngate-update"
VPNGATE_SCHEDULE_SERVICE="${VPNGATE_SCHEDULE_UNIT}.service"
VPNGATE_SCHEDULE_TIMER="${VPNGATE_SCHEDULE_UNIT}.timer"
VPNGATE_SCHEDULE_SERVICE_PATH="/etc/systemd/system/${VPNGATE_SCHEDULE_SERVICE}"
VPNGATE_SCHEDULE_TIMER_PATH="/etc/systemd/system/${VPNGATE_SCHEDULE_TIMER}"

_vpngate_schedule_interval() {
    local interval
    interval=$(_vpngate_state_get auto-update-interval)
    [[ "$interval" =~ ^[0-9]+$ ]] && ((interval >= 5)) ||
        interval=${CLASHCTL_VPNGATE_UPDATE_INTERVAL:-60}
    [[ "$interval" =~ ^[0-9]+$ ]] && ((interval >= 5)) || interval=60
    printf '%s\n' "$interval"
}

_vpngate_schedule_validate_interval() {
    local interval=$1
    [[ "$interval" =~ ^[0-9]+$ ]] && ((interval >= 5 && interval <= 10080)) || {
        _errorcat "定时更新间隔必须是 5 到 10080 分钟之间的整数"
        return 1
    }
}

_vpngate_schedule_require_systemd() {
    _is_root || {
        _errorcat "管理 VPNGate systemd 定时任务需要 root 权限"
        return 1
    }
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] || {
        _errorcat "当前环境不是可用的 systemd；无法注册 VPNGate 定时任务"
        return 1
    }
}

_vpngate_schedule_write_units() {
    local interval=$1 boot_delay=${CLASHCTL_VPNGATE_UPDATE_BOOT_DELAY:-5}
    _vpngate_schedule_validate_interval "$interval" || return
    _vpngate_schedule_require_systemd || return
    [[ "$boot_delay" =~ ^[0-9]+$ ]] || boot_delay=5

    mkdir -p "$CLASH_VPNGATE_DIR"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'export CLASHCTL_HOME=%q\n' "$CLASHCTL_HOME"
        printf '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"\n'
        printf 'clashvpngate schedule run\n'
    } >"$CLASH_VPNGATE_SCHEDULE_RUNNER"
    chmod 700 "$CLASH_VPNGATE_SCHEDULE_RUNNER"

    cat >"$VPNGATE_SCHEDULE_SERVICE_PATH" <<EOF
[Unit]
Description=Refresh VPNGate nodes for clashctl
Wants=network-online.target
After=network-online.target ${CLASHCTL_KERNEL}.service

[Service]
Type=oneshot
ExecStart=/bin/bash ${CLASH_VPNGATE_SCHEDULE_RUNNER}
TimeoutStartSec=5min
Nice=10
EOF

    cat >"$VPNGATE_SCHEDULE_TIMER_PATH" <<EOF
[Unit]
Description=Periodically refresh VPNGate nodes for clashctl

[Timer]
OnBootSec=${boot_delay}min
OnUnitActiveSec=${interval}min
AccuracySec=1min
Persistent=true
Unit=${VPNGATE_SCHEDULE_SERVICE}

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
}

_vpngate_schedule_start() {
    _vpngate_init_files
    local interval=${1:-$(_vpngate_schedule_interval)}
    [ $# -le 1 ] || {
        _errorcat "用法：clashctl vpngate schedule start [分钟]"
        return 1
    }
    [ "$(_vpngate_state_get enabled)" = true ] || {
        _errorcat 'VPNGate 未启用；定时任务只会随 VPNGate 运行，请先执行 clashctl vpngate on'
        return 1
    }
    _vpngate_schedule_write_units "$interval" || return
    systemctl enable "$VPNGATE_SCHEDULE_TIMER" >/dev/null || return
    systemctl restart "$VPNGATE_SCHEDULE_TIMER" || return
    _vpngate_state_set_num auto-update-interval "$interval"
    _vpngate_state_set_bool auto-update-enabled true
    _okcat '✅' "VPNGate 定时更新已启动：每 $interval 分钟检查一次"
}

_vpngate_schedule_set_interval() {
    _vpngate_init_files
    [ $# -eq 1 ] || {
        _errorcat "用法：clashctl vpngate schedule interval <分钟>"
        return 1
    }
    local interval=$1 should_run=false
    _vpngate_schedule_validate_interval "$interval" || return
    if [ "$(_vpngate_state_get enabled)" = true ] &&
        [ "$(_vpngate_state_get auto-update-enabled)" = true ]; then
        should_run=true
    fi
    if [ "$should_run" = true ]; then
        _vpngate_schedule_write_units "$interval" || return
        _vpngate_state_set_num auto-update-interval "$interval"
        systemctl restart "$VPNGATE_SCHEDULE_TIMER" || return
        _okcat '✅' "VPNGate 定时更新间隔已改为 $interval 分钟，计时已重新开始"
    else
        _vpngate_state_set_num auto-update-interval "$interval"
        _okcat '✅' "VPNGate 定时更新间隔已保存为 $interval 分钟（当前不运行）"
    fi
}

# 暂停实际 timer，但保留用户“自动更新已配置”的偏好；下次 VPNGate 成功
# 启用后会恢复。VPNGate 关闭期间 systemd 不再周期唤醒空跑。
_vpngate_schedule_pause() {
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl disable --now "$VPNGATE_SCHEDULE_TIMER" >/dev/null 2>&1 || true
}

_vpngate_schedule_resume_if_configured() {
    [ "$(_vpngate_state_get enabled)" = true ] || return 0
    [ "$(_vpngate_state_get auto-update-enabled)" = true ] || return 0
    local interval
    interval=$(_vpngate_schedule_interval)
    _vpngate_schedule_write_units "$interval" || return
    systemctl enable "$VPNGATE_SCHEDULE_TIMER" >/dev/null || return
    systemctl restart "$VPNGATE_SCHEDULE_TIMER" || return
    _okcat '⏱️' "VPNGate 定时更新已随服务恢复：每 $interval 分钟"
}

_vpngate_schedule_stop() {
    _vpngate_init_files
    _vpngate_schedule_require_systemd || return
    systemctl disable --now "$VPNGATE_SCHEDULE_TIMER" >/dev/null 2>&1 || true
    _vpngate_state_set_bool auto-update-enabled false
    _okcat '✅' "VPNGate 定时更新已停止；节点和当前连接不受影响"
}

_vpngate_schedule_run() {
    _vpngate_init_files
    local now result error
    now=$(date '+%Y-%m-%d %H:%M:%S')
    _vpngate_state_set last-auto-check "$now"
    _vpngate_state_set last-auto-result running
    _vpngate_state_set last-auto-error ""

    # 兼容旧版本遗留的“VPNGate 已关闭但 timer 仍运行”状态：本次唤醒只做
    # 一次迁移性暂停，此后关闭期间不再周期空跑。
    if [ "$(_vpngate_state_get enabled)" != true ]; then
        _vpngate_schedule_pause
        _vpngate_state_set last-auto-result suspended-disabled
        _okcat 'ℹ️' "VPNGate 当前未启用，定时任务已暂停；下次启用后恢复"
        return 0
    fi

    if _vpngate_with_lock _vpngate_update_locked; then
        result=$(_vpngate_state_get last-update-result)
        _vpngate_state_set last-auto-result "${result:-success}"
        _vpngate_state_set last-auto-error ""
        return 0
    fi

    error=$(_vpngate_state_get last-update-error)
    [ -n "$error" ] || error="更新失败，请查看 journalctl -u $VPNGATE_SCHEDULE_SERVICE"
    _vpngate_state_set last-auto-result failed
    _vpngate_state_set last-auto-error "$error"
    return 1
}

_vpngate_schedule_next() {
    local next next_us
    systemctl is-active --quiet "$VPNGATE_SCHEDULE_TIMER" 2>/dev/null || return 0
    next=$(systemctl show "$VPNGATE_SCHEDULE_TIMER" \
        -p NextElapseUSecRealtime --value 2>/dev/null)
    if [ -z "$next" ]; then
        next_us=$(systemctl list-timers "$VPNGATE_SCHEDULE_TIMER" \
            --output=json --no-pager 2>/dev/null |
            "$BIN_YQ" -p=json '.[0].next // ""' 2>/dev/null)
        if [[ "$next_us" =~ ^[0-9]+$ ]] && [ "$next_us" -gt 0 ]; then
            next=$(date -d "@$((next_us / 1000000))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
        fi
    fi
    printf '%s\n' "$next"
}

_vpngate_schedule_status() {
    _vpngate_init_files
    local interval configured vpngate_enabled active=停止 enabled=否 next='未安排' last_check last_result last_error
    interval=$(_vpngate_schedule_interval)
    configured=$(_vpngate_state_get auto-update-enabled)
    vpngate_enabled=$(_vpngate_state_get enabled)

    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet "$VPNGATE_SCHEDULE_TIMER" 2>/dev/null && active=运行中
        systemctl is-enabled --quiet "$VPNGATE_SCHEDULE_TIMER" 2>/dev/null && enabled=是
        if [ "$active" = 运行中 ]; then
            next=$(_vpngate_schedule_next)
            [ -n "$next" ] || next='等待 systemd 计算'
        fi
    fi
    if [ "$active" != 运行中 ] && [ "$configured" = true ] &&
        [ "$vpngate_enabled" != true ]; then
        active='随 VPNGate 暂停'
        next='启用 VPNGate 后恢复'
    fi
    last_check=$(_vpngate_state_get last-auto-check)
    last_result=$(_vpngate_state_get last-auto-result)
    last_error=$(_vpngate_state_get last-auto-error)

    cat <<EOF
VPNGate 定时更新
  运行状态：$active
  开机启用：$enabled
  自动更新：$([ "$configured" = true ] && printf '已配置' || printf '未配置')
  更新间隔：$interval 分钟
  下次执行：$next
  上次执行：${last_check:-从未}
  上次结果：${last_result:-无}
EOF
    [ -z "$last_error" ] || printf '  上次错误：%s\n' "$last_error"
}

_vpngate_schedule_remove() {
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl disable --now "$VPNGATE_SCHEDULE_TIMER" >/dev/null 2>&1 || true
    rm -f "$VPNGATE_SCHEDULE_SERVICE_PATH" "$VPNGATE_SCHEDULE_TIMER_PATH" \
        "$CLASH_VPNGATE_SCHEDULE_RUNNER"
    systemctl daemon-reload >/dev/null 2>&1 || true
}

_vpngate_schedule() {
    case "${1:-status}" in
    status | '') _vpngate_schedule_status ;;
    start) shift; _vpngate_schedule_start "$@" ;;
    interval) shift; _vpngate_schedule_set_interval "$@" ;;
    stop) shift; [ $# -eq 0 ] || { _errorcat "schedule stop 不接受参数"; return 1; }; _vpngate_schedule_stop ;;
    run) shift; [ $# -eq 0 ] || { _errorcat "schedule run 不接受参数"; return 1; }; _vpngate_schedule_run ;;
    -h | --help | help)
        cat <<'EOF'
Usage:
  clashctl vpngate schedule status
  clashctl vpngate schedule start [分钟]
  clashctl vpngate schedule interval <分钟>
  clashctl vpngate schedule stop
  clashctl vpngate schedule run

默认每 60 分钟检查一次。定时任务只在 VPNGate 启用期间运行；关闭时自动
暂停，再次启用时恢复。节点没有变化时不会重启 Mihomo；发生变化时会事务化
加载新节点，并尽量恢复两个可见组更新前的手动选择。
EOF
        ;;
    *)
        _errorcat "未知 schedule 子命令：$1"
        return 1
        ;;
    esac
}
