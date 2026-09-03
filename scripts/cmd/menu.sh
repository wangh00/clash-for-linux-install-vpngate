#!/usr/bin/env bash

# clashctl 交互式控制中心。底层仍调用原有 clash* 函数，所有历史命令保持兼容。

_menu_init_theme() {
    MENU_RESET='' MENU_BOLD='' MENU_DIM='' MENU_ACCENT='' MENU_BLUE=''
    MENU_GREEN='' MENU_YELLOW='' MENU_RED=''
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; then
        MENU_RESET=$'\033[0m'
        MENU_BOLD=$'\033[1m'
        MENU_DIM=$'\033[2m'
        MENU_ACCENT=$'\033[38;5;45m'
        MENU_BLUE=$'\033[38;5;75m'
        MENU_GREEN=$'\033[38;5;82m'
        MENU_YELLOW=$'\033[38;5;221m'
        MENU_RED=$'\033[38;5;203m'
    fi
}

_menu_repeat() {
    local char=$1 count=$2 fill
    printf -v fill '%*s' "$count" ''
    printf '%s' "${fill// /$char}"
}

_menu_rule() {
    printf '  %s' "$MENU_DIM"
    _menu_repeat '─' 54
    printf '%s\n' "$MENU_RESET"
}

# 对现有纯文本菜单统一着色，不改变任何编号、文字或处理逻辑。
_menu_options() {
    local line prefix number suffix
    while IFS= read -r line; do
        if [[ "$line" =~ ^([[:space:]]*)([0-9]+)(\..*)$ ]]; then
            prefix=${BASH_REMATCH[1]}
            number=${BASH_REMATCH[2]}
            suffix=${BASH_REMATCH[3]}
            if [ "$number" = 0 ]; then
                printf '%s%s%s%s%s\n' "$MENU_DIM" "$prefix" "$number" "$suffix" "$MENU_RESET"
            else
                printf '%s%s%s%s%s%s\n' "$prefix" "$MENU_BOLD$MENU_BLUE" "$number" \
                    "$MENU_RESET" "$suffix" "$MENU_RESET"
            fi
        else
            printf '%s\n' "$line"
        fi
    done
}

_menu_prompt() {
    printf '\n  %s›%s %s%s%s： ' "$MENU_ACCENT" "$MENU_RESET" "$MENU_BOLD" "${1:-请选择}" "$MENU_RESET"
}

_menu_init_theme

_menu_clear() {
    [ -t 1 ] && command -v clear >/dev/null 2>&1 && clear
}

_menu_pause() {
    [ -t 0 ] || return 0
    printf '\n  %s按 Enter 返回菜单…%s' "$MENU_DIM" "$MENU_RESET"
    IFS= read -r _ || true
}

_menu_confirm() {
    local prompt=$1 answer
    printf '\n  %s?%s %s %s[y/N]%s： ' "$MENU_YELLOW" "$MENU_RESET" "$prompt" "$MENU_DIM" "$MENU_RESET"
    IFS= read -r answer || return 1
    case "${answer,,}" in y | yes) return 0 ;; esac
    return 1
}

_menu_header() {
    local title=$1 width=54 title_width left right
    title_width=$(_dispwidth "$title")
    left=$(((width - title_width) / 2))
    right=$((width - title_width - left))
    ((left < 1)) && left=1
    ((right < 1)) && right=1

    printf '\n%s╭' "$MENU_ACCENT"
    _menu_repeat '─' "$width"
    printf '╮%s\n' "$MENU_RESET"
    printf '%s│%s%*s%s%s%s%*s%s│%s\n' \
        "$MENU_ACCENT" "$MENU_RESET" "$left" '' "$MENU_BOLD$MENU_ACCENT" "$title" \
        "$MENU_RESET" "$right" '' "$MENU_ACCENT" "$MENU_RESET"
    printf '%s╰' "$MENU_ACCENT"
    _menu_repeat '─' "$width"
    printf '╯%s\n' "$MENU_RESET"
}

_menu_main_summary() {
    local service_state=未运行 tun_state=关闭 sub=未设置 vg=关闭
    local route_mode route_leaf timer_state=停止 interval next bind_addr proxy_port
    service_is_active >/dev/null 2>&1 && service_state=运行中
    tunstatus >/dev/null 2>&1 && tun_state=开启
    sub=$(_sub_current 2>/dev/null)
    [ -n "$sub" ] || sub=未设置
    if [ -f "$CLASH_VPNGATE_STATE" ] &&
        [ "$(_vpngate_state_get enabled 2>/dev/null)" = true ]; then
        vg=开启
        route_mode=$(_vpngate_route_mode_label)
        route_leaf=$(_vpngate_route_leaf)
    fi
    if systemctl is-active --quiet "$VPNGATE_SCHEDULE_TIMER" 2>/dev/null; then
        timer_state=运行中
        interval=$(_vpngate_schedule_interval)
        next=$(_vpngate_schedule_next)
    fi
    bind_addr=$(_get_bind_addr 2>/dev/null)
    proxy_port=$("$BIN_YQ" '.mixed-port // .port // .socks-port // 7890' \
        "$CLASH_CONFIG_RUNTIME" 2>/dev/null)

    printf '\n  %s●%s Mihomo %s%s%s' \
        "$([ "$service_state" = 运行中 ] && printf '%s' "$MENU_GREEN" || printf '%s' "$MENU_RED")" \
        "$MENU_RESET" "$MENU_BOLD" "$service_state" "$MENU_RESET"
    printf '    %s●%s TUN %s%s%s' \
        "$([ "$tun_state" = 开启 ] && printf '%s' "$MENU_GREEN" || printf '%s' "$MENU_RED")" \
        "$MENU_RESET" "$MENU_BOLD" "$tun_state" "$MENU_RESET"
    printf '    %s●%s VPNGate %s%s%s\n' \
        "$([ "$vg" = 开启 ] && printf '%s' "$MENU_GREEN" || printf '%s' "$MENU_RED")" \
        "$MENU_RESET" "$MENU_BOLD" "$vg" "$MENU_RESET"
    printf '  %s订阅%s  %s\n' "$MENU_DIM" "$MENU_RESET" "$sub"
    if [ "$vg" = 开启 ]; then
        printf '  %s出口%s  %s%s%s\n' "$MENU_DIM" "$MENU_RESET" \
            "$MENU_GREEN" "${route_mode:-未获取}" "$MENU_RESET"
        printf '  %s节点%s  %s\n' "$MENU_DIM" "$MENU_RESET" "${route_leaf:-未获取}"
    fi
    printf '  %s更新%s  %s%s%s' "$MENU_DIM" "$MENU_RESET" \
        "$([ "$timer_state" = 运行中 ] && printf '%s' "$MENU_GREEN" || printf '%s' "$MENU_YELLOW")" \
        "$timer_state" "$MENU_RESET"
    [ "$timer_state" = 运行中 ] && printf ' · %s 分钟 · 下次 %s' "$interval" "${next:-等待计算}"
    printf '\n'
    printf '  %s代理%s  %s:%s\n' "$MENU_DIM" "$MENU_RESET" \
        "${bind_addr:-127.0.0.1}" "${proxy_port:-7890}"
    _menu_rule
}

_menu_service() {
    local choice
    while true; do
        _menu_clear
        _menu_header '服务与代理'
        _menu_options <<'EOF'
  1. 查看 Mihomo 状态
  2. 启动 Mihomo 服务
  3. 停止 Mihomo 服务
  4. 查看最近 80 行日志
  5. 升级稳定版内核
  0. 返回上一级
EOF
        _menu_prompt
        IFS= read -r choice || return
        case "$choice" in
        1) clashstatus; _menu_pause ;;
        2) clashon --service-only; _menu_pause ;;
        3) _menu_confirm '确认停止 Mihomo？' && clashoff --service-only; _menu_pause ;;
        4) clashlog --no-pager -n 80; _menu_pause ;;
        5) _menu_confirm '确认检查并升级稳定版内核？' && clashupgrade --release; _menu_pause ;;
        0 | b | B) return ;;
        *) _errorcat "无效选项：$choice" || true; sleep 1 ;;
        esac
    done
}

_menu_sub_add() {
    local url name proxy use_now answer
    local args=(add)
    printf '订阅链接: '
    IFS= read -r url || return
    [ -n "$url" ] || { _errorcat '订阅链接不能为空' || true; return 1; }
    printf '订阅名称（留空自动识别）: '
    IFS= read -r name || return
    printf '下载代理 URL（留空直连）: '
    IFS= read -r proxy || return
    printf '添加后立即启用？[Y/n]: '
    IFS= read -r answer || return

    [ -n "$name" ] && args+=(--name "$name")
    [ -n "$proxy" ] && args+=(--proxy "$proxy")
    case "${answer,,}" in n | no) ;; *) args+=(--use) ;; esac
    args+=("$url")
    clashsub "${args[@]}"
}

_menu_subscription() {
    local choice
    while true; do
        _menu_clear
        _menu_header '订阅与节点'
        _menu_options <<'EOF'
  1. 查看订阅列表
  2. 添加订阅
  3. 切换当前订阅
  4. 更新当前订阅
  5. 删除订阅
  6. 选择策略组节点
  7. 节点延迟测试
  0. 返回上一级
EOF
        _menu_prompt
        IFS= read -r choice || return
        case "$choice" in
        1) clashsub list; _menu_pause ;;
        2) _menu_sub_add; _menu_pause ;;
        3) clashsub use; _menu_pause ;;
        4) clashsub update; _menu_pause ;;
        5) clashsub del; _menu_pause ;;
        6) clashnode; _menu_pause ;;
        7) clashnode delay; _menu_pause ;;
        0 | b | B) return ;;
        *) _errorcat "无效选项：$choice" || true; sleep 1 ;;
        esac
    done
}

## 菜单内选择策略组时只接受序号，避免 Emoji、空格或特殊字符的组名被手输错误。
## 成功时把原始组名写入 MENU_VPNGATE_FRONT；0 取消则返回非 0。
_menu_vpngate_choose_front() {
    local default_front=${1:-} choice group marker
    local -a listed=() groups=()
    local i default_exists=false

    MENU_VPNGATE_FRONT=''
    mapfile -t listed < <(_vpngate_list_groups 2>/dev/null)
    for group in "${listed[@]}"; do
        [ -n "$group" ] && groups+=("$group")
    done

    [ "${#groups[@]}" -gt 0 ] || {
        _errorcat '没有可选的前置策略组；请先启用订阅并启动 Mihomo。' || true
        return 1
    }

    for group in "${groups[@]}"; do
        [ "$group" = "$default_front" ] && default_exists=true
    done

    printf '\n可用前置策略组：\n'
    for ((i = 0; i < ${#groups[@]}; i++)); do
        marker=''
        [ "${groups[$i]}" = "$default_front" ] && marker='（当前）'
        printf '  %2d. %s%s\n' "$((i + 1))" "${groups[$i]}" "$marker"
    done

    while true; do
        if [ "$default_exists" = true ]; then
            printf '请输入序号（直接回车保留当前，0 取消）: '
        else
            printf '请输入序号（0 取消）: '
        fi
        IFS= read -r choice || return 1

        if [ -z "$choice" ] && [ "$default_exists" = true ]; then
            MENU_VPNGATE_FRONT=$default_front
            return 0
        fi
        [ "$choice" = 0 ] && return 1
        if [[ "$choice" =~ ^[0-9]+$ ]] &&
            ((choice >= 1 && choice <= ${#groups[@]})); then
            MENU_VPNGATE_FRONT=${groups[$((choice - 1))]}
            return 0
        fi
        _errorcat '请输入列表中的有效序号。' || true
    done
}

_menu_vpngate_front() {
    local current_front
    current_front=$(_vpngate_state_get front-group 2>/dev/null)
    _menu_vpngate_choose_front "$current_front" || return 0
    clashvpngate front "$MENU_VPNGATE_FRONT"
}

_menu_vpngate_on() {
    local front country current_front front_route
    if [ "$(_vpngate_state_get enabled 2>/dev/null)" = true ] &&
        service_is_active >/dev/null 2>&1 && tunstatus >/dev/null 2>&1; then
        _okcat 'ℹ️' 'VPNGate 已经在运行，无需重复启用；需要刷新 API 时请选择“手动更新 VPNGate 节点”'
        return 0
    fi
    current_front=$(_vpngate_state_get front-group 2>/dev/null)

    # 已绑定过前置策略组时，启用操作直接复用它。overlay 的 dialer-proxy
    # 引用的是该“组”本身，因此 9090 内切换组成员无需再次跑此向导。
    if [ -n "$current_front" ] && _vpngate_front_exists "$current_front"; then
        front=$current_front
    else
        [ -n "$current_front" ] &&
            _failcat "已绑定的前置策略组不存在：$current_front，需要重新选择" || true
        _menu_vpngate_choose_front "$current_front" || return 0
        front=$MENU_VPNGATE_FRONT
    fi

    front_route=$(_vpngate_front_route "$front")
    printf '\n前置已绑定：%s\n' "$front"
    if [ -n "$front_route" ]; then
        printf '9090 当前链路：%s\n' "$front_route"
        printf '之后在 9090 切换这个策略组的节点，VPNGate 前置会自动跟随。\n'
    fi
    printf 'VPNGate 出口国家筛选（只影响 VPNGate 出口；直接回车=ALL）: '
    IFS= read -r country || return
    country=${country:-ALL}

    _menu_confirm "确认启用 VPNGate：前置=[$front] 国家=$country，导入全部有效节点？" || return 0
    clashvpngate on --front "$front" --country "$country" --limit ALL
}

_menu_vpngate_update() {
    local country args=(update --limit ALL)
    printf '国家代码（留空保持当前）: '
    IFS= read -r country || return
    [ -n "$country" ] && args+=(--country "$country")
    _menu_confirm '确认重新获取并加载全部有效 VPNGate 节点？' || return 0
    clashvpngate "${args[@]}"
}

_menu_vpngate_schedule() {
    local choice interval current
    while true; do
        _menu_clear
        _menu_header 'VPNGate 定时更新管理'
        clashvpngate schedule status
        _menu_options <<'EOF'

  1. 启动定时更新
  2. 修改更新间隔
  3. 立即执行一次检查
  4. 停止定时更新
  0. 返回上一级
EOF
        _menu_prompt
        IFS= read -r choice || return
        case "$choice" in
        1)
            current=$(_vpngate_schedule_interval)
            printf '更新间隔（分钟，直接回车使用 %s）: ' "$current"
            IFS= read -r interval || return
            clashvpngate schedule start "${interval:-$current}"
            _menu_pause
            ;;
        2)
            current=$(_vpngate_schedule_interval)
            printf '新的更新间隔（分钟，当前 %s）: ' "$current"
            IFS= read -r interval || return
            [ -n "$interval" ] && clashvpngate schedule interval "$interval"
            _menu_pause
            ;;
        3) clashvpngate schedule run; _menu_pause ;;
        4) _menu_confirm '确认停止 VPNGate 定时更新？' && clashvpngate schedule stop; _menu_pause ;;
        0 | b | B) return ;;
        *) _errorcat "无效选项：$choice" || true; sleep 1 ;;
        esac
    done
}

_menu_vpngate_route() {
    local choice
    while true; do
        _menu_clear
        _menu_header 'VPNGate 出口模式'
        clashvpngate route status
        _menu_options <<'EOF'

  1. 智能自动（直连优先，失败后经前置）
  2. 固定直连
  3. 固定经前置
  0. 返回上一级
EOF
        _menu_prompt
        IFS= read -r choice || return
        case "$choice" in
        1) clashvpngate route auto; _menu_pause ;;
        2) clashvpngate route direct; _menu_pause ;;
        3) clashvpngate route front; _menu_pause ;;
        0 | b | B) return ;;
        *) _errorcat "无效选项：$choice" || true; sleep 1 ;;
        esac
    done
}

_menu_vpngate_logs() {
    local choice
    while true; do
        _menu_clear
        _menu_header 'VPNGate 日志'
        _menu_options <<'EOF'
  1. 节点更新记录
  2. 定时任务日志
  3. Mihomo VPNGate/OpenVPN 日志
  4. 查看全部
  0. 返回上一级
EOF
        _menu_prompt
        IFS= read -r choice || return
        case "$choice" in
        1) clashvpngate logs update; _menu_pause ;;
        2) clashvpngate logs timer; _menu_pause ;;
        3) clashvpngate logs mihomo; _menu_pause ;;
        4) clashvpngate logs all; _menu_pause ;;
        0 | b | B) return ;;
        *) _errorcat "无效选项：$choice" || true; sleep 1 ;;
        esac
    done
}

_menu_vpngate_diagnose() {
    _menu_clear
    _menu_header 'VPNGate 综合诊断'
    clashvpngate diagnose
    _menu_pause
}

_menu_vpngate() {
    local choice
    while true; do
        _menu_clear
        _menu_header 'VPNGate 管理'
        _menu_options <<'EOF'
  1. 查看运行状态
  2. 综合诊断（依赖/API/出口/UI）
  3. 选择出口模式
  4. 查看/设置前置策略组
  5. 启用 VPNGate
  6. 手动更新 VPNGate 节点
  7. 测试 VPNGate-AUTO
  8. 定时更新管理
  9. 查看 VPNGate 日志
 10. Zashboard 补丁兼容性自检
 11. 关闭 VPNGate
  0. 返回上一级
EOF
        _menu_prompt
        IFS= read -r choice || return
        case "$choice" in
        1) clashvpngate status; _menu_pause ;;
        2) _menu_vpngate_diagnose ;;
        3) _menu_vpngate_route ;;
        4) _menu_vpngate_front; _menu_pause ;;
        5) _menu_vpngate_on; _menu_pause ;;
        6) _menu_vpngate_update; _menu_pause ;;
        7) clashvpngate test; _menu_pause ;;
        8) _menu_vpngate_schedule ;;
        9) _menu_vpngate_logs ;;
        10) clashvpngate ui-check; _menu_pause ;;
        11) _menu_confirm '确认关闭 VPNGate 并恢复普通订阅模式？' && clashvpngate off; _menu_pause ;;
        0 | b | B) return ;;
        *) _errorcat "无效选项：$choice" || true; sleep 1 ;;
        esac
    done
}

_menu_tun() {
    local choice
    while true; do
        _menu_clear
        _menu_header 'TUN 管理'
        _menu_options <<'EOF'
  1. 查看 TUN 状态
  2. 开启 TUN
  3. 关闭 TUN
  0. 返回上一级
EOF
        _menu_prompt
        IFS= read -r choice || return
        case "$choice" in
        1) clashtun; _menu_pause ;;
        2) _menu_confirm '确认开启全局 TUN？' && clashtun on; _menu_pause ;;
        3) _menu_confirm '确认关闭全局 TUN？' && clashtun off; _menu_pause ;;
        0 | b | B) return ;;
        *) _errorcat "无效选项：$choice" || true; sleep 1 ;;
        esac
    done
}

_menu_web() {
    local choice
    while true; do
        _menu_clear
        _menu_header 'Web 面板'
        _menu_options <<'EOF'
  1. 显示 Zashboard 地址和密钥
  0. 返回上一级
EOF
        _menu_prompt
        IFS= read -r choice || return
        case "$choice" in
        1) clashui; clashsecret; _menu_pause ;;
        0 | b | B) return ;;
        *) _errorcat "无效选项：$choice" || true; sleep 1 ;;
        esac
    done
}

_menu_config() {
    local choice secret
    while true; do
        _menu_clear
        _menu_header '配置与安全'
        _menu_options <<'EOF'
  1. 查看 Web 密钥
  2. 修改 Web 密钥
  3. 查看 Mixin 配置
  4. 编辑 Mixin 配置
  5. 查看运行时配置
  0. 返回上一级
EOF
        _menu_prompt
        IFS= read -r choice || return
        case "$choice" in
        1) clashsecret; _menu_pause ;;
        2)
            printf '输入新 Web 密钥: '
            IFS= read -r secret || return
            [ -n "$secret" ] && clashsecret "$secret"
            _menu_pause
            ;;
        3) clashmixin; _menu_pause ;;
        4) clashmixin -e; _menu_pause ;;
        5) clashmixin -r; _menu_pause ;;
        0 | b | B) return ;;
        *) _errorcat "无效选项：$choice" || true; sleep 1 ;;
        esac
    done
}

_menu_help() {
    local choice
    while true; do
        _menu_clear
        _menu_header '所有命令说明'
        _menu_options <<'EOF'
  1. 总命令列表
  2. 订阅命令
  3. 节点命令
  4. VPNGate 命令
  5. TUN 命令
  6. 启动命令
  7. 停止命令
  8. 配置命令
  9. 内核升级命令
  0. 返回上一级
EOF
        _menu_prompt
        IFS= read -r choice || return
        case "$choice" in
        1) clashhelp; _menu_pause ;;
        2) clashsub --help; _menu_pause ;;
        3) clashnode --help; _menu_pause ;;
        4) clashvpngate --help; _menu_pause ;;
        5) clashtun --help; _menu_pause ;;
        6) clashon --help; _menu_pause ;;
        7) clashoff --help; _menu_pause ;;
        8) clashmixin --help; _menu_pause ;;
        9) clashupgrade --help; _menu_pause ;;
        0 | b | B) return ;;
        *) _errorcat "无效选项：$choice" || true; sleep 1 ;;
        esac
    done
}

clashmenu() {
    local choice
    [ -t 0 ] && [ -t 1 ] || {
        clashhelp
        return
    }

    while true; do
        _menu_clear
        _menu_header 'clashctl 控制中心'
        _menu_main_summary
        _menu_options <<'EOF'

  1. 服务与代理
  2. 订阅与节点
  3. VPNGate 管理
  4. Web 面板
  5. TUN 管理
  6. 配置与安全
  7. 所有命令说明
  0. 退出
EOF
        _menu_prompt
        IFS= read -r choice || return
        case "$choice" in
        1) _menu_service ;;
        2) _menu_subscription ;;
        3) _menu_vpngate ;;
        4) _menu_web ;;
        5) _menu_tun ;;
        6) _menu_config ;;
        7) _menu_help ;;
        0 | q | Q | exit) return ;;
        *) _errorcat "无效选项：$choice" || true; sleep 1 ;;
        esac
    done
}
