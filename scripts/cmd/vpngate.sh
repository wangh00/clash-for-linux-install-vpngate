#!/usr/bin/env bash

clashvpngate() {
    case "${1:-status}" in
    on)
        shift
        _vpngate_parse_common_args "$@" || return
        _vpngate_with_lock _vpngate_on_locked
        ;;
    off)
        _vpngate_with_lock _vpngate_off_locked
        ;;
    update)
        shift
        _vpngate_parse_common_args "$@" || return
        _vpngate_with_lock _vpngate_update_locked
        ;;
    front)
        shift
        if [ $# -gt 0 ]; then
            _vpngate_with_lock _vpngate_front "$@"
        else
            _vpngate_front
        fi
        ;;
    route)
        shift
        _vpngate_route "$@"
        ;;
    test)
        clashnode delay -t "${CLASHCTL_VPNGATE_TEST_TIMEOUT:-20000}" -g "$VPNGATE_GROUP_AUTO"
        ;;
    schedule)
        shift
        _vpngate_schedule "$@"
        ;;
    ui-check)
        _vpngate_ui_check
        ;;
    logs | log)
        shift
        _vpngate_logs "$@"
        ;;
    diagnose | check)
        shift
        _vpngate_diagnose "$@"
        ;;
    status | '')
        _vpngate_status
        ;;
    -h | --help | help)
        vpngate_help
        ;;
    *)
        _errorcat "未知 vpngate 子命令：$1"
        vpngate_help
        return 1
        ;;
    esac
}

_vpngate_parse_common_args() {
    VPNGATE_ARG_FRONT=''
    VPNGATE_ARG_COUNTRY=''
    VPNGATE_ARG_COUNTRY_SET=false
    VPNGATE_ARG_LIMIT=''
    while [ $# -gt 0 ]; do
        case "$1" in
        --front)
            [ -n "${2-}" ] || { _errorcat "--front 需要策略组名称"; return 1; }
            VPNGATE_ARG_FRONT=$2
            shift
            ;;
        --front=*) VPNGATE_ARG_FRONT=${1#*=} ;;
        --country)
            [ -n "${2-}" ] || { _errorcat "--country 需要两位国家代码"; return 1; }
            VPNGATE_ARG_COUNTRY=$2
            VPNGATE_ARG_COUNTRY_SET=true
            shift
            ;;
        --country=*) VPNGATE_ARG_COUNTRY=${1#*=}; VPNGATE_ARG_COUNTRY_SET=true ;;
        --limit)
            [ -n "${2-}" ] || { _errorcat "--limit 需要非负整数或 ALL"; return 1; }
            VPNGATE_ARG_LIMIT=$2
            shift
            ;;
        --limit=*) VPNGATE_ARG_LIMIT=${1#*=} ;;
        -h | --help)
            vpngate_help
            return 2
            ;;
        *)
            _errorcat "未知选项：$1"
            return 1
            ;;
        esac
        shift
    done

    VPNGATE_ARG_COUNTRY=${VPNGATE_ARG_COUNTRY^^}
    [ "$VPNGATE_ARG_COUNTRY" = ALL ] && VPNGATE_ARG_COUNTRY=''
    [ -z "$VPNGATE_ARG_COUNTRY" ] || [[ "$VPNGATE_ARG_COUNTRY" =~ ^[A-Z]{2}$ ]] || {
        _errorcat "国家代码必须是两位字母，例如 JP、US、KR"
        return 1
    }
    [ "${VPNGATE_ARG_LIMIT^^}" = ALL ] && VPNGATE_ARG_LIMIT=0
    [ -z "$VPNGATE_ARG_LIMIT" ] || {
        [[ "$VPNGATE_ARG_LIMIT" =~ ^[0-9]+$ ]]
    } || {
        _errorcat "--limit 必须是非负整数；0/ALL 表示不限制"
        return 1
    }
}

_vpngate_resolve_options() {
    VPNGATE_FRONT=${VPNGATE_ARG_FRONT:-$(_vpngate_state_get front-group)}
    if [ "$VPNGATE_ARG_COUNTRY_SET" = true ]; then
        VPNGATE_COUNTRY=$VPNGATE_ARG_COUNTRY
    else
        VPNGATE_COUNTRY=$(_vpngate_state_get country)
    fi
    VPNGATE_LIMIT=${VPNGATE_ARG_LIMIT:-$(_vpngate_state_get limit)}
    [ -n "$VPNGATE_LIMIT" ] || VPNGATE_LIMIT=${CLASHCTL_VPNGATE_LIMIT:-0}
}

_vpngate_require_front_subscription() {
    [ "$CLASHCTL_KERNEL" = mihomo ] || {
        _errorcat "VPNGate 功能只支持 Mihomo 内核"
        return 1
    }
    [ -n "$(_sub_current)" ] || {
        _errorcat "必须先添加并启用一个前置订阅：clashctl sub add --use <url>"
        return 1
    }
}

_vpngate_on_locked() {
    _vpngate_init_files
    _vpngate_resolve_options
    if [ "$(_vpngate_state_get enabled)" = true ] &&
        service_is_active >/dev/null 2>&1 && tunstatus >/dev/null 2>&1; then
        _okcat 'ℹ️' 'VPNGate 已经在运行，本次不重复初始化；刷新节点请使用“手动更新 VPNGate 节点”'
        return 0
    fi
    _vpngate_require_front_subscription || return

    # 先启动普通订阅配置，随后才能从 Controller 获取策略组并通过前置抓 API。
    service_is_active >/dev/null 2>&1 || service_start || return
    sleep 1
    _vpngate_front_exists "$VPNGATE_FRONT" || {
        _errorcat "前置策略组不存在：${VPNGATE_FRONT:-<未设置>}"
        _failcat "可用策略组："
        _vpngate_list_groups >&2
        _errorcat "请先执行：clashctl vpngate front <策略组名称>"
        return 1
    }
    if _vpngate_is_internal_group "$VPNGATE_FRONT"; then
        _errorcat "前置策略组不能指向 VPNGate 自身，避免形成代理环路"
        return 1
    fi

    local backup="${CLASH_VPNGATE_OVERLAY}.bak.$$"
    cp "$CLASH_VPNGATE_OVERLAY" "$backup"

    # Bootstrap overlay 只强制 Tun，并让 API 域名走前置；此时尚不加载
    # VPNGate 节点，避免首次获取时产生循环依赖。
    _vpngate_write_overlay bootstrap "$VPNGATE_FRONT" && _merge_config_restart || {
        cp "$backup" "$CLASH_VPNGATE_OVERLAY"
        _merge_config_restart >/dev/null 2>&1 || true
        rm -f "$backup"
        _errorcat "VPNGate Bootstrap 配置启动失败"
        return 1
    }
    tunstatus >/dev/null 2>&1 || {
        cp "$backup" "$CLASH_VPNGATE_OVERLAY"
        _merge_config_restart >/dev/null 2>&1 || true
        rm -f "$backup"
        _errorcat "TUN 未成功启动，已取消 VPNGate 模式"
        return 1
    }

    _vpngate_sync_nodes "$VPNGATE_COUNTRY" "$VPNGATE_LIMIT" || {
        cp "$backup" "$CLASH_VPNGATE_OVERLAY"
        _merge_config_restart >/dev/null 2>&1 || true
        rm -f "$backup"
        _errorcat "VPNGate 节点更新失败，已恢复原配置"
        return 1
    }

    _vpngate_write_overlay full "$VPNGATE_FRONT" && _merge_config_restart || {
        cp "$backup" "$CLASH_VPNGATE_OVERLAY"
        _merge_config_restart >/dev/null 2>&1 || true
        rm -f "$backup"
        _errorcat "VPNGate 完整配置校验或启动失败，已恢复原配置"
        return 1
    }
    rm -f "$backup"

    _vpngate_state_set front-group "$VPNGATE_FRONT"
    _vpngate_state_set country "$VPNGATE_COUNTRY"
    _vpngate_state_set_num limit "$VPNGATE_LIMIT"
    _vpngate_state_set_num node-count "$VPNGATE_GENERATED_COUNT"
    _vpngate_state_set checked-at "$(date '+%Y-%m-%d %H:%M:%S')"
    _vpngate_state_set updated-at "$(date '+%Y-%m-%d %H:%M:%S')"
    _vpngate_state_set last-update-result changed
    _vpngate_state_set last-update-error ""
    _vpngate_state_set last-apply-method restart
    _vpngate_state_set_bool enabled true
    _okcat '✅' "VPNGate 已启用：前置=[$VPNGATE_FRONT] 国家=${VPNGATE_COUNTRY:-ALL} 节点=$VPNGATE_GENERATED_COUNT"
}

_vpngate_restore_one_selection() {
    local group=$1 old_selection=$2 fallback=$3 members='' target='' current=''
    local attempt

    # Mihomo 重启完成后 Controller 可能比 TUN 晚几百毫秒可用，短暂重试，
    # 避免因为启动竞态把本可保留的手动选择误判为已消失。
    for attempt in 1 2 3 4 5; do
        members=$(_node_members "$group" 2>/dev/null) && [ -n "$members" ] && break
        sleep 1
    done
    [ -n "$members" ] || {
        _failcat '⚠️' "无法读取 [$group] 成员，未能恢复更新前的选择" || true
        return 1
    }

    if [ -n "$old_selection" ] && grep -Fqx -- "$old_selection" <<<"$members"; then
        target=$old_selection
    else
        target=$fallback
        [ -z "$old_selection" ] ||
            _failcat '⚠️' "[$group] 原节点已从 VPNGate API 消失，已回退到 $fallback" || true
    fi

    current=$(_node_now "$group" 2>/dev/null)
    [ "$current" = "$target" ] && return 0
    _node_apply "$group" "$target"
}

_vpngate_restore_selections() {
    local direct_selection=$1 front_selection=$2 failed=0
    _vpngate_restore_one_selection "$VPNGATE_GROUP_DIRECT" "$direct_selection" \
        "$VPNGATE_GROUP_DIRECT_AUTO" || failed=1
    _vpngate_restore_one_selection "$VPNGATE_GROUP_FRONT" "$front_selection" \
        "$VPNGATE_GROUP_FRONT_AUTO" || failed=1
    return "$failed"
}

_vpngate_restore_route_mode() {
    local old_mode=$1 old_type=$2 target=$VPNGATE_GROUP_SMART_AUTO members
    # 旧版 VPNGate-AUTO 是 Fallback；迁移到可手动控制的 Selector 时不能把
    # 它当时碰巧选中的“直连”误认为用户固定模式，首次迁移仍保持智能自动。
    if [[ "$old_type" == *Selector* ]]; then
        case "$old_mode" in
        "$VPNGATE_GROUP_SMART_AUTO" | "$VPNGATE_GROUP_DIRECT" | "$VPNGATE_GROUP_FRONT")
            target=$old_mode
            ;;
        esac
    fi
    members=$(_node_members "$VPNGATE_GROUP_AUTO" 2>/dev/null) || return 1
    grep -Fqx -- "$target" <<<"$members" || return 1
    [ "$(_node_now "$VPNGATE_GROUP_AUTO" 2>/dev/null)" = "$target" ] ||
        _node_apply "$VPNGATE_GROUP_AUTO" "$target"
}

_vpngate_update_locked() {
    _vpngate_init_files
    _vpngate_resolve_options
    [ "$(_vpngate_state_get enabled)" = true ] || {
        _vpngate_state_set last-update-result failed
        _vpngate_state_set last-update-error "VPNGate 尚未启用"
        _errorcat "VPNGate 尚未启用，请先执行 clashctl vpngate on"
        return 1
    }
    _vpngate_front_exists "$VPNGATE_FRONT" || {
        _vpngate_state_set last-update-result failed
        _vpngate_state_set last-update-error "前置策略组不存在：$VPNGATE_FRONT"
        _errorcat "前置策略组不存在：$VPNGATE_FRONT"
        return 1
    }
    tunstatus >/dev/null 2>&1 || {
        _vpngate_state_set last-update-result failed
        _vpngate_state_set last-update-error "TUN 未启用"
        _errorcat "TUN 未启用，拒绝更新 VPNGate 模式"
        return 1
    }

    local old_direct old_front old_route_mode old_route_type transaction now
    old_direct=$(_node_now "$VPNGATE_GROUP_DIRECT" 2>/dev/null)
    old_front=$(_node_now "$VPNGATE_GROUP_FRONT" 2>/dev/null)
    old_route_mode=$(_node_now "$VPNGATE_GROUP_AUTO" 2>/dev/null)
    old_route_type=$(_node_group_json "$VPNGATE_GROUP_AUTO" 2>/dev/null |
        "$BIN_YQ" -p=json '.type // ""' 2>/dev/null)
    transaction=$(mktemp -d "${CLASH_VPNGATE_DIR}/.update-backup.XXXXXX") || return 1
    cp "$CLASH_VPNGATE_NODES_DIRECT" "$transaction/direct.yaml"
    cp "$CLASH_VPNGATE_NODES_FRONT" "$transaction/front.yaml"
    cp "$CLASH_VPNGATE_OVERLAY" "$transaction/overlay.yaml"
    [ ! -e "$CLASH_VPNGATE_API_RAW" ] || cp "$CLASH_VPNGATE_API_RAW" "$transaction/servers.csv"

    now=$(date '+%Y-%m-%d %H:%M:%S')
    _vpngate_state_set checked-at "$now"
    if ! _vpngate_sync_nodes "$VPNGATE_COUNTRY" "$VPNGATE_LIMIT"; then
        rm -rf "$transaction"
        _vpngate_state_set last-update-result failed
        _vpngate_state_set last-update-error "VPNGate API 获取或节点解析失败"
        return 1
    fi

    # 节点完整签名没有变化时只记录检查时间，不重载 Mihomo，也不会打断
    # 当前 OpenVPN 会话或用户在 9090 中固定的节点。
    if [ "$VPNGATE_NODES_CHANGED" != true ]; then
        rm -rf "$transaction"
        _vpngate_state_set front-group "$VPNGATE_FRONT"
        _vpngate_state_set country "$VPNGATE_COUNTRY"
        _vpngate_state_set_num limit "$VPNGATE_LIMIT"
        _vpngate_state_set_num node-count "$VPNGATE_GENERATED_COUNT"
        _vpngate_state_set last-update-result unchanged
        _vpngate_state_set last-update-error ""
        _okcat '✅' "VPNGate 定时检查完成：节点未变化，未重启 Mihomo（$VPNGATE_GENERATED_COUNT 个）"
        return 0
    fi

    CLASHCTL_CONFIG_APPLY_METHOD=''
    if ! _vpngate_write_overlay full "$VPNGATE_FRONT" || ! _merge_config_reload; then
        cp "$transaction/direct.yaml" "$CLASH_VPNGATE_NODES_DIRECT"
        cp "$transaction/front.yaml" "$CLASH_VPNGATE_NODES_FRONT"
        cp "$transaction/overlay.yaml" "$CLASH_VPNGATE_OVERLAY"
        if [ -e "$transaction/servers.csv" ]; then
            cp "$transaction/servers.csv" "$CLASH_VPNGATE_API_RAW"
        else
            rm -f "$CLASH_VPNGATE_API_RAW"
        fi
        _merge_config_restart >/dev/null 2>&1 || true
        _vpngate_restore_selections "$old_direct" "$old_front" >/dev/null 2>&1 || true
        [[ "$old_route_type" == *Selector* ]] &&
            _vpngate_restore_route_mode "$old_route_mode" "$old_route_type" >/dev/null 2>&1 || true
        rm -rf "$transaction"
        _vpngate_state_set last-update-result failed
        _vpngate_state_set last-update-error "新节点配置加载失败，已回滚"
        _errorcat "VPNGate 新节点配置加载失败，已恢复更新前配置"
        return 1
    fi

    rm -rf "$transaction"
    _vpngate_restore_selections "$old_direct" "$old_front" || true
    _vpngate_restore_route_mode "$old_route_mode" "$old_route_type" ||
        _failcat '⚠️' "未能恢复 VPNGate 更新前的出口模式，当前使用智能自动" || true
    _vpngate_state_set front-group "$VPNGATE_FRONT"
    _vpngate_state_set country "$VPNGATE_COUNTRY"
    _vpngate_state_set_num limit "$VPNGATE_LIMIT"
    _vpngate_state_set_num node-count "$VPNGATE_GENERATED_COUNT"
    _vpngate_state_set updated-at "$now"
    _vpngate_state_set last-update-result changed
    _vpngate_state_set last-update-error ""
    _vpngate_state_set last-apply-method "${CLASHCTL_CONFIG_APPLY_METHOD:-restart}"
    printf '%s 加载成功 method=%s nodes=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" \
        "${CLASHCTL_CONFIG_APPLY_METHOD:-restart}" "$VPNGATE_GENERATED_COUNT" >>"$CLASH_VPNGATE_LOG"
    _okcat '✅' "VPNGate 节点已更新：$VPNGATE_GENERATED_COUNT（${CLASHCTL_CONFIG_APPLY_METHOD:-restart}）"
}

_vpngate_off_locked() {
    _vpngate_init_files
    _vpngate_write_overlay off '' || return
    _merge_config_restart || return
    _vpngate_state_set_bool enabled false
    _okcat '✅' "VPNGate 已关闭；TUN 已恢复为用户 Mixin 中的原状态"
}

_vpngate_front() {
    _vpngate_init_files
    local front=${1:-}
    if [ -z "$front" ]; then
        printf '当前前置策略组：%s\n' "$(_vpngate_state_get front-group)"
        printf '可用策略组：\n'
        _vpngate_list_groups | sed 's/^/  - /'
        return
    fi
    _vpngate_front_exists "$front" || {
        _errorcat "策略组不存在：$front"
        return 1
    }
    if _vpngate_is_internal_group "$front"; then
        _errorcat "不能把 VPNGate 自身策略组设置为前置"
        return 1
    fi

    local old=$(_vpngate_state_get front-group)
    _vpngate_state_set front-group "$front"
    if [ "$(_vpngate_state_get enabled)" = true ]; then
        _vpngate_write_overlay full "$front" && _merge_config_restart || {
            _vpngate_state_set front-group "$old"
            _vpngate_write_overlay full "$old"
            _merge_config_restart >/dev/null 2>&1 || true
            return 1
        }
    fi
    _okcat '✅' "VPNGate 前置策略组：$front"
}

_vpngate_route() {
    local requested=${1:-status} target current active
    [ $# -le 1 ] || {
        _errorcat "用法：clashctl vpngate route [auto|direct|front]"
        return 1
    }
    current=$(_node_now "$VPNGATE_GROUP_AUTO" 2>/dev/null)
    case "${requested,,}" in
    status | '')
        if [ "$current" = "$VPNGATE_GROUP_SMART_AUTO" ]; then
            active=$(_node_now "$VPNGATE_GROUP_SMART_AUTO" 2>/dev/null)
            printf '出口模式：智能自动\n当前链路：%s\n' "${active:-未获取}"
        elif [ "$current" = "$VPNGATE_GROUP_DIRECT" ]; then
            printf '出口模式：固定直连\n'
        elif [ "$current" = "$VPNGATE_GROUP_FRONT" ]; then
            printf '出口模式：固定经前置\n'
        else
            printf '出口模式：旧版自动/未知（%s）\n' "${current:-未获取}"
        fi
        return 0
        ;;
    auto | smart) target=$VPNGATE_GROUP_SMART_AUTO ;;
    direct) target=$VPNGATE_GROUP_DIRECT ;;
    front) target=$VPNGATE_GROUP_FRONT ;;
    *)
        _errorcat "出口模式只接受：auto、direct、front"
        return 1
        ;;
    esac
    _node_apply "$VPNGATE_GROUP_AUTO" "$target"
}

_vpngate_status() {
    _vpngate_init_files
    local enabled front country limit count updated checked result apply_method route_mode route_label front_route outbound_route tun_state=关闭
    enabled=$(_vpngate_state_get enabled)
    front=$(_vpngate_state_get front-group)
    country=$(_vpngate_state_get country)
    limit=$(_vpngate_state_get limit)
    count=$(_vpngate_state_get node-count)
    updated=$(_vpngate_state_get updated-at)
    checked=$(_vpngate_state_get checked-at)
    result=$(_vpngate_state_get last-update-result)
    apply_method=$(_vpngate_state_get last-apply-method)
    route_mode=$(_node_now "$VPNGATE_GROUP_AUTO" 2>/dev/null)
    case "$route_mode" in
    "$VPNGATE_GROUP_SMART_AUTO") route_label=智能自动 ;;
    "$VPNGATE_GROUP_DIRECT") route_label=固定直连 ;;
    "$VPNGATE_GROUP_FRONT") route_label=固定经前置 ;;
    *) route_label=旧版自动/未获取 ;;
    esac
    front_route=$(_vpngate_front_route "$front")
    outbound_route=$(_vpngate_front_route "$VPNGATE_GROUP_AUTO")
    tunstatus >/dev/null 2>&1 && tun_state=开启
    cat <<EOF
VPNGate 状态
  启用：${enabled:-false}
  TUN：$tun_state
  前置策略组：${front:-未设置}
  9090 当前链路：${front_route:-未获取}
  国家筛选：${country:-ALL}
  节点范围：$([ "${limit:-0}" = 0 ] && printf '全部有效节点' || printf '最多 %s 个' "$limit")
  已生成节点：${count:-0}
  最近检查：${checked:-从未}
  节点变更时间：${updated:-从未}
  最近检查结果：${result:-无}
  最近加载方式：${apply_method:-无}
  出口模式：$route_label
  当前出口链路：${outbound_route:-未获取}
EOF
}

_vpngate_log_update() {
    printf '\n===== VPNGate 节点更新记录 =====\n'
    if [ -s "$CLASH_VPNGATE_LOG" ]; then
        tail -n "${1:-80}" "$CLASH_VPNGATE_LOG"
    else
        printf '暂无更新记录：%s\n' "$CLASH_VPNGATE_LOG"
    fi
}

_vpngate_log_timer() {
    printf '\n===== VPNGate systemd 定时任务 =====\n'
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -u "$VPNGATE_SCHEDULE_SERVICE" --no-pager -n "${1:-80}"
    else
        printf '当前系统没有 journalctl。\n'
    fi
}

_vpngate_log_mihomo() {
    printf '\n===== Mihomo 中的 VPNGate/OpenVPN 记录 =====\n'
    local content
    detect_service_manager
    if [ "$service_manager" = systemd ] && command -v journalctl >/dev/null 2>&1; then
        content=$(journalctl -u "$CLASHCTL_KERNEL" --no-pager -n 500 2>/dev/null |
            grep -Ei 'vpngate|openvpn|tun|dialer-proxy' | tail -n "${1:-80}")
    else
        content=$(tail -n 500 "$service_log_path" 2>/dev/null |
            grep -Ei 'vpngate|openvpn|tun|dialer-proxy' | tail -n "${1:-80}")
    fi
    if [ -n "$content" ]; then
        printf '%s\n' "$content"
    else
        printf '最近日志中没有 VPNGate/OpenVPN 相关记录。\n'
    fi
}

_vpngate_logs() {
    local kind=${1:-all} lines=${2:-80}
    [[ "$lines" =~ ^[1-9][0-9]*$ ]] || lines=80
    case "${kind,,}" in
    update) _vpngate_log_update "$lines" ;;
    timer | schedule) _vpngate_log_timer "$lines" ;;
    mihomo | kernel) _vpngate_log_mihomo "$lines" ;;
    all | '')
        _vpngate_log_update "$lines"
        _vpngate_log_timer "$lines"
        _vpngate_log_mihomo "$lines"
        ;;
    *)
        _errorcat "日志类型只接受：all、update、timer、mihomo"
        return 1
        ;;
    esac
}

_vpngate_diag_print() {
    local result=$1 label=$2 detail=${3:-}
    printf '  %-6s %-26s %s\n' "[$result]" "$label" "$detail"
}

_vpngate_diagnose() {
    [ $# -eq 0 ] || {
        _errorcat '用法：clashctl vpngate diagnose'
        return 1
    }
    _vpngate_init_files
    local fails=0 warns=0 cmd current front port top_type smart_type leaf delay line
    local enabled timer_result api_tmp
    printf 'VPNGate 综合诊断\n'
    enabled=$(_vpngate_state_get enabled)

    if [ "$CLASHCTL_KERNEL" = mihomo ] && [ -x "$BIN_KERNEL" ]; then
        _vpngate_diag_print OK 'Mihomo 内核' "$BIN_KERNEL"
    else
        _vpngate_diag_print FAIL 'Mihomo 内核' "当前=$CLASHCTL_KERNEL"
        fails=$((fails + 1))
    fi
    if [ -x "$BIN_YQ" ]; then
        _vpngate_diag_print OK 'YQ' "$BIN_YQ"
    else
        _vpngate_diag_print FAIL 'YQ' '文件不存在或不可执行'
        fails=$((fails + 1))
    fi
    for cmd in curl awk base64 sort ip flock sha256sum md5sum systemctl; do
        if command -v "$cmd" >/dev/null 2>&1; then
            _vpngate_diag_print OK "命令 $cmd" "$(command -v "$cmd")"
        else
            _vpngate_diag_print FAIL "命令 $cmd" '未安装'
            fails=$((fails + 1))
        fi
    done
    if [ -c /dev/net/tun ]; then
        _vpngate_diag_print OK '/dev/net/tun' '可用'
    else
        _vpngate_diag_print FAIL '/dev/net/tun' '不存在'
        fails=$((fails + 1))
    fi

    if service_is_active >/dev/null 2>&1; then
        _vpngate_diag_print OK 'Mihomo 服务' '运行中'
    else
        _vpngate_diag_print FAIL 'Mihomo 服务' '未运行'
        fails=$((fails + 1))
    fi
    if tunstatus >/dev/null 2>&1; then
        _vpngate_diag_print OK 'TUN' '运行中'
    elif [ "$enabled" = true ]; then
        _vpngate_diag_print FAIL 'TUN' 'VPNGate 已启用但 TUN 未运行'
        fails=$((fails + 1))
    else
        _vpngate_diag_print WARN 'TUN' '当前未运行（VPNGate 启用时会自动开启）'
        warns=$((warns + 1))
    fi

    current=$(_sub_current 2>/dev/null)
    if [ -n "$current" ]; then
        _vpngate_diag_print OK '前置订阅' "$current"
    else
        _vpngate_diag_print FAIL '前置订阅' '未添加或未启用'
        fails=$((fails + 1))
    fi
    front=$(_vpngate_state_get front-group)
    if [ -n "$front" ] && _vpngate_front_exists "$front"; then
        _vpngate_diag_print OK '前置策略组' "$front"
    else
        _vpngate_diag_print FAIL '前置策略组' "${front:-未设置}"
        fails=$((fails + 1))
    fi

    port=$("$BIN_YQ" '.mixed-port // .port // ""' "$CLASH_CONFIG_RUNTIME" 2>/dev/null)
    if [ -n "$port" ] && _is_port_used "$port"; then
        _vpngate_diag_print OK '本机代理端口' "$port 正在监听"
    else
        _vpngate_diag_print FAIL '本机代理端口' "${port:-未知} 未监听"
        fails=$((fails + 1))
    fi

    if [ "$enabled" = true ]; then
        top_type=$(_node_group_json "$VPNGATE_GROUP_AUTO" 2>/dev/null |
            "$BIN_YQ" -p=json '.type // ""' 2>/dev/null)
        smart_type=$(_node_group_json "$VPNGATE_GROUP_SMART_AUTO" 2>/dev/null |
            "$BIN_YQ" -p=json '.type // ""' 2>/dev/null)
        if [[ "$top_type" == *Selector* ]] && [[ "$smart_type" == *Fallback* ]]; then
            _vpngate_diag_print OK 'VPNGate 策略组结构' 'Selector + 智能 Fallback'
        else
            _vpngate_diag_print FAIL 'VPNGate 策略组结构' "AUTO=$top_type SMART=$smart_type"
            fails=$((fails + 1))
        fi
        _vpngate_diag_print OK '当前出口模式' "$(_vpngate_route_mode_label)"
        leaf=$(_vpngate_route_leaf)
        _vpngate_diag_print OK '当前出口节点' "${leaf:-未获取}"
    else
        _vpngate_diag_print WARN 'VPNGate 状态' '当前未启用'
        warns=$((warns + 1))
    fi

    if systemctl is-active --quiet "$VPNGATE_SCHEDULE_TIMER" 2>/dev/null; then
        timer_result=$(_vpngate_state_get last-auto-result)
        _vpngate_diag_print OK '定时更新' "运行中，每 $(_vpngate_schedule_interval) 分钟；最近=${timer_result:-无}"
    else
        _vpngate_diag_print WARN '定时更新' '未启动'
        warns=$((warns + 1))
    fi

    if _vpngate_ui_static_check; then
        _vpngate_diag_print OK 'Zashboard 补丁' '静态自检通过'
    else
        _vpngate_diag_print WARN 'Zashboard 补丁' '静态自检失败，可执行 clashctl ui 修复'
        warns=$((warns + 1))
    fi

    # 验证真实更新链路：显式通过本机 Mihomo 和前置订阅请求 API，但不发布节点。
    if service_is_active >/dev/null 2>&1 && [ -n "$front" ]; then
        api_tmp=$(mktemp "${CLASH_VPNGATE_DIR}/.diagnose-api.XXXXXX")
        if _vpngate_fetch_api "$api_tmp" && grep -aFq '*vpn_servers' "$api_tmp"; then
            _vpngate_diag_print OK 'VPNGate API' '经前置订阅请求成功'
        else
            _vpngate_diag_print FAIL 'VPNGate API' '经前置订阅请求失败'
            fails=$((fails + 1))
        fi
        rm -f "$api_tmp"
    fi

    if [ -n "$leaf" ]; then
        line=$(_node_delay_one "$leaf" \
            "timeout=8000&url=$(_node_urlencode "${CLASHCTL_VPNGATE_DELAY_URL:-https://cp.cloudflare.com}")" 2>/dev/null)
        delay=${line#*$'\t'}
        if [[ "$delay" =~ ^[1-9][0-9]*$ ]]; then
            _vpngate_diag_print OK '当前出口连通性' "${delay}ms"
        else
            _vpngate_diag_print WARN '当前出口连通性' '测速超时'
            warns=$((warns + 1))
        fi
    fi

    printf '\n诊断结果：FAIL=%d WARN=%d\n' "$fails" "$warns"
    [ "$fails" -eq 0 ]
}

vpngate_help() {
    cat <<EOF

clashctl vpngate - VPNGate OpenVPN 出口管理

Usage:
  clashctl vpngate front [策略组]             查看/设置前置订阅策略组
  clashctl vpngate route [auto|direct|front]   查看/切换智能、直连、经前置模式
  clashctl vpngate on [OPTIONS]               开启 TUN、获取节点并启用自动出口
  clashctl vpngate update [OPTIONS]           更新并重新加载节点
  clashctl vpngate off                        关闭 VPNGate 模式
  clashctl vpngate test                       测试 VPNGate-AUTO 策略组
  clashctl vpngate status                     查看状态
  clashctl vpngate schedule status            查看定时更新状态
  clashctl vpngate schedule start [分钟]      启动定时更新（默认 60 分钟）
  clashctl vpngate schedule interval <分钟>   修改定时更新间隔
  clashctl vpngate schedule stop              停止定时更新
  clashctl vpngate schedule run               立即执行一次更新检查
  clashctl vpngate ui-check                   检查 Zashboard 补丁兼容性
  clashctl vpngate logs [all|update|timer|mihomo] [行数]
                                               查看 VPNGate 相关日志
  clashctl vpngate diagnose                   执行完整链路综合诊断

Options:
  --front <策略组>      指定前置订阅策略组
  --country <代码>      两位国家代码，例如 JP、US、KR；ALL 表示全部
  --limit <数量|ALL>    可选导入上限；0/ALL 表示不限制（默认）

说明：
  - 默认导入 VPNGate 全部通过校验并去重的 TCP + dev tun OpenVPN 配置。
  - 每个节点同时生成“直连”和“经前置”两种逻辑节点。
  - 前置保存的是策略组，不是具体节点；在 9090 切换该策略组的节点后，
    新建的 VPNGate 前置连接会自动跟随。
  - 9090 只显示 VPNGate-直连、VPNGate-经前置两个组；每组首项是
    对应的 AUTO 自动选择，后面的节点可以直接点击并固定 IP。
  - 隐藏的 VPNGate-AUTO 是顶层出口选择器；默认指向 VPNGate-智能自动，
    也可以固定使用直连或经前置。
  - VPNGate 模式启用期间强制开启 TUN。

EOF
}
