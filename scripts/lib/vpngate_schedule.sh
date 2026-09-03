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
    local interval=$1 was_active=false
    _vpngate_schedule_validate_interval "$interval" || return
    systemctl is-active --quiet "$VPNGATE_SCHEDULE_TIMER" 2>/dev/null && was_active=true
    _vpngate_schedule_write_units "$interval" || return
    _vpngate_state_set_num auto-update-interval "$interval"
    if [ "$was_active" = true ]; then
        systemctl restart "$VPNGATE_SCHEDULE_TIMER" || return
        _vpngate_state_set_bool auto-update-enabled true
        _okcat '✅' "VPNGate 定时更新间隔已改为 $interval 分钟，计时已重新开始"
    else
        _vpngate_state_set_bool auto-update-enabled false
        _okcat '✅' "VPNGate 定时更新间隔已改为 $interval 分钟（任务仍为停止状态）"
    fi
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

    # 定时器可以保持启用而 VPNGate 模式临时关闭；这种情况正常跳过，不把
    # systemd unit 标成失败。重新开启 VPNGate 后下个周期会自动恢复检查。
    if [ "$(_vpngate_state_get enabled)" != true ]; then
        _vpngate_state_set last-auto-result skipped-disabled
        _okcat 'ℹ️' "VPNGate 当前未启用，本次定时更新已跳过"
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
    local interval configured active=停止 enabled=否 next='未安排' last_check last_result last_error
    interval=$(_vpngate_schedule_interval)
    configured=$(_vpngate_state_get auto-update-enabled)

    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet "$VPNGATE_SCHEDULE_TIMER" 2>/dev/null && active=运行中
        systemctl is-enabled --quiet "$VPNGATE_SCHEDULE_TIMER" 2>/dev/null && enabled=是
        if [ "$active" = 运行中 ]; then
            next=$(_vpngate_schedule_next)
            [ -n "$next" ] || next='等待 systemd 计算'
        fi
    fi
    last_check=$(_vpngate_state_get last-auto-check)
    last_result=$(_vpngate_state_get last-auto-result)
    last_error=$(_vpngate_state_get last-auto-error)

    cat <<EOF
VPNGate 定时更新
  运行状态：$active
  开机启用：$enabled
  配置记录：${configured:-false}
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

默认每 60 分钟检查一次。节点没有变化时不会重启 Mihomo；发生变化时会
事务化加载新节点，并尽量恢复两个可见组更新前的手动选择。
EOF
        ;;
    *)
        _errorcat "未知 schedule 子命令：$1"
        return 1
        ;;
    esac
}
