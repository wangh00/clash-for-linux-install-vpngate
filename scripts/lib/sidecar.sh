#!/usr/bin/env bash

# Xray 旁代理：只提供独立 mixed 端口，不创建第二张 TUN。Xray 发起的
# 出站连接由主 Mihomo TUN 捕获；核心下载则显式经过主 mixed-port，故不依赖
# TUN 是否开启。

_sidecar_init_files() {
    mkdir -p "$CLASH_SIDECAR_DIR"
    chmod 700 "$CLASH_SIDECAR_DIR" 2>/dev/null || true
    [ -s "$CLASH_SIDECAR_STATE" ] || cat >"$CLASH_SIDECAR_STATE" <<EOF
enabled: false
listen: "${CLASHCTL_SIDECAR_LISTEN:-0.0.0.0}"
port: ${CLASHCTL_SIDECAR_PORT:-10112}
node-name: ""
server: ""
server-port: 0
method: ""
core-version: ""
updated-at: ""
last-test-at: ""
last-test-ip: ""
last-error: ""
EOF
    chmod 600 "$CLASH_SIDECAR_STATE" 2>/dev/null || true
}

_sidecar_state_get() {
    _sidecar_init_files
    STATE_KEY=$1 "$BIN_YQ" '.[strenv(STATE_KEY)] // ""' "$CLASH_SIDECAR_STATE" 2>/dev/null
}

_sidecar_state_set() {
    local key=$1 value=$2
    STATE_KEY=$key STATE_VALUE=$value "$BIN_YQ" -i \
        '.[strenv(STATE_KEY)] = strenv(STATE_VALUE)' "$CLASH_SIDECAR_STATE"
}

_sidecar_state_set_bool() {
    local key=$1 value=$2
    STATE_KEY=$key STATE_VALUE=$value "$BIN_YQ" -i \
        '.[strenv(STATE_KEY)] = (strenv(STATE_VALUE) == "true")' "$CLASH_SIDECAR_STATE"
}

_sidecar_state_set_num() {
    local key=$1 value=$2
    STATE_KEY=$key STATE_VALUE=$value "$BIN_YQ" -i \
        '.[strenv(STATE_KEY)] = (strenv(STATE_VALUE) | tonumber)' "$CLASH_SIDECAR_STATE"
}

_sidecar_with_lock() {
    _sidecar_init_files
    command -v flock >/dev/null 2>&1 || {
        "$@"
        return
    }
    (
        flock -w 120 7 || {
            _errorcat '另一项旁代理操作正在进行，请稍后重试'
            exit 1
        }
        "$@"
    ) 7>>"$CLASH_SIDECAR_LOCK"
}

_sidecar_version() {
    [ -x "$BIN_XRAY" ] || return 1
    "$BIN_XRAY" version 2>/dev/null | awk 'NR==1{print $2}'
}

_sidecar_is_active() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] &&
        [ -f "$CLASH_SIDECAR_SERVICE_PATH" ]; then
        systemctl is-active --quiet "$CLASH_SIDECAR_SERVICE" 2>/dev/null
        return
    fi
    [ -s "$CLASH_SIDECAR_PID" ] || return 1
    kill -0 "$(cat "$CLASH_SIDECAR_PID" 2>/dev/null)" 2>/dev/null
}

_sidecar_is_active_or_enabled() {
    _sidecar_is_active && return 0
    [ "$(_sidecar_state_get enabled 2>/dev/null)" = true ]
}

_sidecar_listener_line() {
    local port=${1:-$(_sidecar_state_get port)}
    command -v ss >/dev/null 2>&1 || return 1
    ss -H -lntp "sport = :$port" 2>/dev/null | head -1
}

_sidecar_port_conflicts() {
    local port=$1 line
    line=$(_sidecar_listener_line "$port")
    [ -n "$line" ] || return 1
    if _sidecar_is_active && grep -q 'xray' <<<"$line" &&
        [ "$port" = "$(_sidecar_state_get port)" ]; then
        return 1
    fi
    return 0
}

_sidecar_install_service() {
    _is_root || {
        _errorcat '安装旁代理服务需要 root 权限'
        return 1
    }
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] || return 0
    cat >"$CLASH_SIDECAR_SERVICE_PATH" <<EOF
[Unit]
Description=clashctl Xray Sidecar Proxy
After=network-online.target ${CLASHCTL_KERNEL}.service

[Service]
Type=simple
User=root
LimitNOFILE=1000000
ExecStart=${BIN_XRAY} run -config ${CLASH_SIDECAR_CONFIG}
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$CLASH_SIDECAR_SERVICE_PATH"
    systemctl daemon-reload || return
    systemctl enable --quiet "$CLASH_SIDECAR_SERVICE"
}

_sidecar_remove_service() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl disable --now "$CLASH_SIDECAR_SERVICE" >/dev/null 2>&1 || true
        rm -f "$CLASH_SIDECAR_SERVICE_PATH"
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed "$CLASH_SIDECAR_SERVICE" >/dev/null 2>&1 || true
    fi
    if [ -s "$CLASH_SIDECAR_PID" ]; then
        kill "$(cat "$CLASH_SIDECAR_PID" 2>/dev/null)" 2>/dev/null || true
        rm -f "$CLASH_SIDECAR_PID"
    fi
}

_sidecar_service_start() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        _sidecar_install_service || return
        systemctl restart "$CLASH_SIDECAR_SERVICE"
        return
    fi
    [ -s "$CLASH_SIDECAR_PID" ] &&
        kill "$(cat "$CLASH_SIDECAR_PID" 2>/dev/null)" 2>/dev/null || true
    (
        nohup "$BIN_XRAY" run -config "$CLASH_SIDECAR_CONFIG" \
            </dev/null >>"$CLASH_SIDECAR_LOG" 2>&1 &
        printf '%s\n' "$!" >"$CLASH_SIDECAR_PID"
    )
}

_sidecar_service_stop() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] &&
        [ -f "$CLASH_SIDECAR_SERVICE_PATH" ]; then
        systemctl disable --now "$CLASH_SIDECAR_SERVICE" >/dev/null
    elif [ -s "$CLASH_SIDECAR_PID" ]; then
        kill "$(cat "$CLASH_SIDECAR_PID" 2>/dev/null)" 2>/dev/null || true
        rm -f "$CLASH_SIDECAR_PID"
    fi
}

_sidecar_service_restart() {
    _sidecar_is_active || return 0
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] &&
        [ -f "$CLASH_SIDECAR_SERVICE_PATH" ]; then
        systemctl restart "$CLASH_SIDECAR_SERVICE"
    else
        _sidecar_service_stop && _sidecar_service_start
    fi
}

_sidecar_proxy_args() {
    local port auth attempt
    SIDECAR_CURL_PROXY_ARGS=()
    service_is_active >/dev/null 2>&1 || service_start >/dev/null || {
        _errorcat '主 Mihomo 无法启动，不能通过其代理端口下载 Xray'
        return 1
    }
    for attempt in 1 2 3 4 5; do
        port=$("$BIN_YQ" '.mixed-port // .port // .socks-port // ""' \
            "$CLASH_CONFIG_RUNTIME" 2>/dev/null)
        [ -n "$port" ] && _is_port_used "$port" && break
        sleep 1
    done
    [[ "$port" =~ ^[0-9]+$ ]] || {
        _errorcat '无法读取主 Mihomo 代理端口'
        return 1
    }
    auth=$("$BIN_YQ" '.authentication[0] // ""' "$CLASH_CONFIG_RUNTIME" 2>/dev/null)
    SIDECAR_CURL_PROXY_ARGS=(--noproxy '' --proxy "http://127.0.0.1:$port")
    [ -z "$auth" ] || SIDECAR_CURL_PROXY_ARGS+=(--proxy-user "$auth")
    SIDECAR_MAIN_PROXY_PORT=$port
}

_sidecar_latest_tag() {
    local effective
    effective=$(curl "${SIDECAR_CURL_PROXY_ARGS[@]}" -fsSL --max-time 20 \
        -o /dev/null -w '%{url_effective}' \
        https://github.com/XTLS/Xray-core/releases/latest) || return 1
    effective=${effective%%\?*}
    effective=${effective%/}
    [[ ${effective##*/} =~ ^v[0-9] ]] || return 1
    printf '%s\n' "${effective##*/}"
}

_sidecar_asset_name() {
    case "$(uname -m)" in
    x86_64) printf 'Xray-linux-64.zip\n' ;;
    i?86) printf 'Xray-linux-32.zip\n' ;;
    aarch64 | arm64) printf 'Xray-linux-arm64-v8a.zip\n' ;;
    armv7*) printf 'Xray-linux-arm32-v7a.zip\n' ;;
    *)
        _errorcat "Xray 暂不支持当前架构：$(uname -m)"
        return 1
        ;;
    esac
}

_sidecar_core_update_locked() {
    local requested=${1:-latest} tag asset base tmp zip digest expected actual
    local was_active=false old_version='' backup=''
    _sidecar_init_files
    _is_root || {
        _errorcat '更新 Xray 核心需要 root 权限'
        return 1
    }
    _sidecar_proxy_args || return
    if [ "$requested" = latest ]; then
        _okcat '🔎' '通过主 Mihomo 代理端口查询 Xray 最新稳定版…'
        tag=$(_sidecar_latest_tag) || {
            _errorcat '无法查询 Xray 最新版本'
            return 1
        }
    else
        tag=$requested
        [[ "$tag" == v* ]] || tag="v$tag"
        [[ "$tag" =~ ^v[0-9][0-9A-Za-z._-]*$ ]] || {
            _errorcat "无效 Xray 版本：$requested"
            return 1
        }
    fi
    old_version=$(_sidecar_version 2>/dev/null || true)
    if [ -n "$old_version" ] && [ "v$old_version" = "$tag" ]; then
        _okcat '✅' "Xray 已是 $tag"
        _sidecar_state_set core-version "$old_version"
        return 0
    fi

    asset=$(_sidecar_asset_name) || return
    base="https://github.com/XTLS/Xray-core/releases/download/${tag}"
    tmp=$(mktemp -d "${CLASH_SIDECAR_DIR}/.core-update.XXXXXX") || return
    zip="$tmp/$asset"
    digest="$zip.dgst"
    _okcat '⬇️' "通过主 Mihomo 端口 $SIDECAR_MAIN_PROXY_PORT 下载 Xray $tag"
    if ! curl "${SIDECAR_CURL_PROXY_ARGS[@]}" --fail --location --show-error \
        --max-time "${CLASHCTL_SIDECAR_DOWNLOAD_TIMEOUT:-180}" \
        --retry 1 --output "$zip" "$base/$asset" ||
        ! curl "${SIDECAR_CURL_PROXY_ARGS[@]}" --fail --location --show-error \
            --max-time 30 --retry 1 --output "$digest" "$base/$asset.dgst"; then
        rm -rf "$tmp"
        _sidecar_state_set last-error 'Xray 核心下载失败'
        _errorcat 'Xray 核心下载失败'
        return 1
    fi
    expected=$(sed -nE 's/^SHA2-256=[[:space:]]*([0-9a-fA-F]+).*/\1/p' "$digest" | head -1)
    actual=$(sha256sum "$zip" | awk '{print $1}')
    [ -n "$expected" ] && [ "${expected,,}" = "${actual,,}" ] || {
        rm -rf "$tmp"
        _sidecar_state_set last-error 'Xray 核心 SHA256 校验失败'
        _errorcat 'Xray 核心 SHA256 校验失败'
        return 1
    }
    unzip -p "$zip" xray >"$tmp/xray" || {
        rm -rf "$tmp"
        _errorcat '无法从压缩包提取 Xray'
        return 1
    }
    chmod 755 "$tmp/xray"
    "$tmp/xray" version 2>/dev/null | head -1 | grep -Fq "${tag#v}" || {
        rm -rf "$tmp"
        _errorcat '下载的 Xray 版本与目标版本不一致'
        return 1
    }
    if [ -s "$CLASH_SIDECAR_CONFIG" ]; then
        "$tmp/xray" run -test -config "$CLASH_SIDECAR_CONFIG" >/dev/null || {
            rm -rf "$tmp"
            _errorcat '现有旁代理配置无法通过新 Xray 校验，已取消升级'
            return 1
        }
    fi

    _sidecar_is_active && was_active=true
    [ ! -x "$BIN_XRAY" ] || {
        backup="$tmp/xray.old"
        cp "$BIN_XRAY" "$backup"
    }
    /usr/bin/install -D -m 755 "$tmp/xray" "$BIN_XRAY" || {
        rm -rf "$tmp"
        return 1
    }
    if [ "$was_active" = true ] && ! _sidecar_service_restart; then
        [ -z "$backup" ] || /usr/bin/install -m 755 "$backup" "$BIN_XRAY"
        _sidecar_service_start >/dev/null 2>&1 || true
        rm -rf "$tmp"
        _errorcat 'Xray 升级后启动失败，已恢复旧核心'
        return 1
    fi
    old_version=$(_sidecar_version)
    _sidecar_state_set core-version "$old_version"
    _sidecar_state_set updated-at "$(date '+%Y-%m-%d %H:%M:%S')"
    _sidecar_state_set last-error ''
    rm -rf "$tmp"
    _okcat '✅' "Xray 核心已更新：$old_version"
}

_sidecar_b64_decode() {
    local value=$1 mod
    value=${value//-/+}
    value=${value//_/\/}
    mod=$((${#value} % 4))
    [ "$mod" -eq 0 ] || value+=$(printf '%*s' "$((4 - mod))" '' | tr ' ' '=')
    printf '%s' "$value" | base64 -d 2>/dev/null
}

_sidecar_url_decode() {
    local value=${1//+/ }
    printf '%b' "${value//%/\\x}"
}

_sidecar_parse_ss_uri() {
    local uri=$1 body fragment authority userinfo hostport credentials decoded
    [[ "$uri" == ss://* ]] || {
        _errorcat '当前只支持导入 ss:// 节点'
        return 1
    }
    body=${uri#ss://}
    fragment=''
    if [[ "$body" == *#* ]]; then
        fragment=${body#*#}
        body=${body%%#*}
    fi
    if [[ "$body" == *\?* ]]; then
        [ -z "${body#*\?}" ] || {
            _errorcat '暂不支持带 plugin 参数的 Shadowsocks 节点'
            return 1
        }
        body=${body%%\?*}
    fi

    if [[ "$body" == *@* ]]; then
        userinfo=${body%@*}
        hostport=${body##*@}
        userinfo=$(_sidecar_url_decode "$userinfo")
        if [[ "$userinfo" == *:* ]]; then
            credentials=$userinfo
        else
            credentials=$(_sidecar_b64_decode "$userinfo") || return 1
        fi
    else
        decoded=$(_sidecar_b64_decode "$body") || return 1
        [[ "$decoded" == *@* ]] || {
            _errorcat '无法解析 Shadowsocks 分享链接'
            return 1
        }
        credentials=${decoded%@*}
        hostport=${decoded##*@}
    fi
    [[ "$credentials" == *:* ]] || {
        _errorcat 'Shadowsocks 链接缺少加密方法或密码'
        return 1
    }
    SIDECAR_NODE_METHOD=${credentials%%:*}
    SIDECAR_NODE_PASSWORD=${credentials#*:}

    if [[ "$hostport" == \[*\]:* ]]; then
        SIDECAR_NODE_SERVER=${hostport#\[}
        SIDECAR_NODE_SERVER=${SIDECAR_NODE_SERVER%%\]*}
        SIDECAR_NODE_PORT=${hostport##*:}
    else
        SIDECAR_NODE_SERVER=${hostport%:*}
        SIDECAR_NODE_PORT=${hostport##*:}
    fi
    [[ "$SIDECAR_NODE_PORT" =~ ^[0-9]+$ ]] &&
        ((SIDECAR_NODE_PORT >= 1 && SIDECAR_NODE_PORT <= 65535)) || {
        _errorcat 'Shadowsocks 服务器端口无效'
        return 1
    }
    [ -n "$SIDECAR_NODE_SERVER" ] && [ -n "$SIDECAR_NODE_METHOD" ] &&
        [ -n "$SIDECAR_NODE_PASSWORD" ] || {
        _errorcat 'Shadowsocks 链接字段不完整'
        return 1
    }
    SIDECAR_NODE_NAME=$(_sidecar_url_decode "$fragment")
    [ -n "$SIDECAR_NODE_NAME" ] ||
        SIDECAR_NODE_NAME="${SIDECAR_NODE_SERVER}:${SIDECAR_NODE_PORT}"
}

_sidecar_write_ss_config() {
    local target=$1 listen=$2 port=$3
    SIDECAR_LISTEN=$listen SIDECAR_PORT=$port SIDECAR_METHOD=$SIDECAR_NODE_METHOD \
        SIDECAR_PASSWORD=$SIDECAR_NODE_PASSWORD SIDECAR_SERVER=$SIDECAR_NODE_SERVER \
        SIDECAR_SERVER_PORT=$SIDECAR_NODE_PORT "$BIN_YQ" -n -o=json '
          {
            "log": {"loglevel": "warning"},
            "inbounds": [{
              "tag": "mixed-in",
              "listen": strenv(SIDECAR_LISTEN),
              "port": (strenv(SIDECAR_PORT) | tonumber),
              "protocol": "mixed",
              "sniffing": {"enabled": true, "destOverride": ["http", "tls"], "routeOnly": false},
              "settings": {"auth": "noauth", "udp": true, "allowTransparent": false}
            }],
            "outbounds": [{
              "tag": "proxy",
              "protocol": "shadowsocks",
              "settings": {"servers": [{
                "address": strenv(SIDECAR_SERVER),
                "port": (strenv(SIDECAR_SERVER_PORT) | tonumber),
                "method": strenv(SIDECAR_METHOD),
                "password": strenv(SIDECAR_PASSWORD),
                "level": 1
              }]},
              "streamSettings": {"network": "tcp"},
              "mux": {"enabled": false, "concurrency": -1}
            }, {"tag": "direct", "protocol": "freedom"}, {"tag": "block", "protocol": "blackhole"}],
            "routing": {"domainStrategy": "AsIs", "rules": []}
          }
        ' >"$target"
}

_sidecar_import_locked() {
    local uri=$1 listen port tmp backup='' was_active=false
    _sidecar_init_files
    _sidecar_parse_ss_uri "$uri" || return
    listen=$(_sidecar_state_get listen)
    port=$(_sidecar_state_get port)
    tmp=$(mktemp "${CLASH_SIDECAR_DIR}/.config.XXXXXX") || return
    _sidecar_write_ss_config "$tmp" "$listen" "$port" || {
        rm -f "$tmp"
        return 1
    }
    if [ -x "$BIN_XRAY" ]; then
        "$BIN_XRAY" run -test -config "$tmp" >/dev/null || {
            rm -f "$tmp"
            _errorcat 'Xray 配置校验失败，未保存节点'
            return 1
        }
    fi
    _sidecar_is_active && was_active=true
    [ ! -s "$CLASH_SIDECAR_CONFIG" ] || {
        backup="${CLASH_SIDECAR_CONFIG}.bak.$$"
        cp "$CLASH_SIDECAR_CONFIG" "$backup"
    }
    /usr/bin/install -m 600 "$tmp" "$CLASH_SIDECAR_CONFIG"
    rm -f "$tmp"
    if [ "$was_active" = true ] && ! _sidecar_service_restart; then
        [ -z "$backup" ] || mv -f "$backup" "$CLASH_SIDECAR_CONFIG"
        _sidecar_service_start >/dev/null 2>&1 || true
        _errorcat '新节点启动失败，已恢复原配置'
        return 1
    fi
    [ -z "$backup" ] || rm -f "$backup"
    _sidecar_state_set node-name "$SIDECAR_NODE_NAME"
    _sidecar_state_set server "$SIDECAR_NODE_SERVER"
    _sidecar_state_set_num server-port "$SIDECAR_NODE_PORT"
    _sidecar_state_set method "$SIDECAR_NODE_METHOD"
    _sidecar_state_set updated-at "$(date '+%Y-%m-%d %H:%M:%S')"
    _sidecar_state_set last-error ''
    _okcat '✅' "旁代理节点已导入：$SIDECAR_NODE_NAME"
}

_sidecar_start_locked() {
    local port line attempt
    _sidecar_init_files
    [ "$(_vpngate_state_get enabled 2>/dev/null)" != true ] || {
        _errorcat 'VPNGate 正在启用；旁代理与 VPNGate 互斥，请先执行 clashctl vpngate off'
        return 1
    }
    service_is_active >/dev/null 2>&1 || service_start || return
    tunstatus >/dev/null 2>&1 || {
        _errorcat '主 Mihomo TUN 尚未开启；请先执行 clashctl tun on'
        return 1
    }
    [ -s "$CLASH_SIDECAR_CONFIG" ] || {
        _errorcat '尚未导入旁代理节点：clashctl sidecar import <ss://...>'
        return 1
    }
    [ -x "$BIN_XRAY" ] || {
        _okcat 'ℹ️' '首次使用，安装已验证的 Xray 核心…'
        _sidecar_core_update_locked "${CLASHCTL_XRAY_VERSION:-v25.5.16}" || return
    }
    "$BIN_XRAY" run -test -config "$CLASH_SIDECAR_CONFIG" >/dev/null || {
        _errorcat 'Xray 配置校验失败'
        return 1
    }
    port=$(_sidecar_state_get port)
    _sidecar_port_conflicts "$port" && {
        line=$(_sidecar_listener_line "$port")
        _errorcat "旁代理端口 $port 已被占用：$line"
        return 1
    }
    _sidecar_service_start || {
        _sidecar_state_set last-error 'Xray 服务启动失败'
        return 1
    }
    for attempt in 1 2 3 4 5; do
        _sidecar_is_active && [ -n "$(_sidecar_listener_line "$port")" ] && break
        sleep 1
    done
    _sidecar_is_active && [ -n "$(_sidecar_listener_line "$port")" ] || {
        _sidecar_service_stop >/dev/null 2>&1 || true
        _sidecar_state_set last-error "Xray 未监听端口 $port"
        _errorcat "Xray 启动后未监听端口 $port"
        return 1
    }
    _sidecar_state_set_bool enabled true
    _sidecar_state_set last-error ''
    _okcat '✅' "旁代理已开启：$(_sidecar_state_get listen):$port"
}

_sidecar_stop_locked() {
    _sidecar_init_files
    _sidecar_service_stop || return
    _sidecar_state_set_bool enabled false
    _okcat '✅' '旁代理已关闭；主 Mihomo 与 TUN 保持不变'
}

_sidecar_set_port_locked() {
    local port=$1 tmp backup was_active=false
    [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1024 && port <= 65535)) || {
        _errorcat '旁代理端口必须在 1024～65535 之间'
        return 1
    }
    [ "$port" = "$(_sidecar_state_get port)" ] && {
        _okcat 'ℹ️' "旁代理端口已经是 $port"
        return 0
    }
    _sidecar_port_conflicts "$port" && {
        _errorcat "端口 $port 已被占用：$(_sidecar_listener_line "$port")"
        return 1
    }
    if [ ! -s "$CLASH_SIDECAR_CONFIG" ]; then
        _sidecar_state_set_num port "$port"
        _okcat '✅' "旁代理端口已设置：$port"
        return 0
    fi
    tmp=$(mktemp "${CLASH_SIDECAR_DIR}/.config.XXXXXX") || return
    SIDECAR_PORT=$port "$BIN_YQ" -p=json -o=json \
        '.inbounds[0].port = (strenv(SIDECAR_PORT) | tonumber)' \
        "$CLASH_SIDECAR_CONFIG" >"$tmp" || { rm -f "$tmp"; return 1; }
    [ ! -x "$BIN_XRAY" ] || "$BIN_XRAY" run -test -config "$tmp" >/dev/null || {
        rm -f "$tmp"
        _errorcat '修改后的 Xray 配置校验失败'
        return 1
    }
    backup="${CLASH_SIDECAR_CONFIG}.bak.$$"
    cp "$CLASH_SIDECAR_CONFIG" "$backup"
    _sidecar_is_active && was_active=true
    /usr/bin/install -m 600 "$tmp" "$CLASH_SIDECAR_CONFIG"
    rm -f "$tmp"
    if [ "$was_active" = true ] && ! _sidecar_service_restart; then
        mv -f "$backup" "$CLASH_SIDECAR_CONFIG"
        _sidecar_service_start >/dev/null 2>&1 || true
        _errorcat '新端口启动失败，已恢复原端口'
        return 1
    fi
    rm -f "$backup"
    _sidecar_state_set_num port "$port"
    _okcat '✅' "旁代理端口已设置：$port"
}

_sidecar_test() {
    local port url=${1:-${CLASHCTL_SIDECAR_TEST_URL:-https://api.ip.sb/ip}}
    local tmp code rc body
    _sidecar_is_active || {
        _errorcat '旁代理未运行'
        return 1
    }
    port=$(_sidecar_state_get port)
    tmp=$(mktemp "${CLASH_SIDECAR_DIR}/.test.XXXXXX") || return
    code=$(curl --noproxy '' -sS --max-time "${CLASHCTL_SIDECAR_TEST_TIMEOUT:-15}" \
        -A 'curl/8' -x "http://127.0.0.1:$port" -o "$tmp" -w '%{http_code}' "$url")
    rc=$?
    body=$(tr -d '\r\n' <"$tmp" | head -c 200)
    rm -f "$tmp"
    if [ "$rc" -eq 0 ] && [[ "$code" =~ ^2 ]]; then
        _sidecar_state_set last-test-at "$(date '+%Y-%m-%d %H:%M:%S')"
        _sidecar_state_set last-test-ip "$body"
        _sidecar_state_set last-error ''
        _okcat '✅' "旁代理测试成功：${body:-HTTP $code}"
        return 0
    fi
    _sidecar_state_set last-error "测试失败 curl=$rc http=$code"
    _errorcat "旁代理测试失败：curl=$rc HTTP=${code:-000}"
}

_sidecar_status() {
    local active=停止 enabled core listen port listener port_state=未监听 main=停止 tun=关闭 vg=关闭
    local node server server_port method last_test last_ip last_error
    _sidecar_init_files
    _sidecar_is_active && active=运行中
    [ "$(_sidecar_state_get enabled)" = true ] && enabled=开启 || enabled=关闭
    service_is_active >/dev/null 2>&1 && main=运行中
    tunstatus >/dev/null 2>&1 && tun=开启
    [ "$(_vpngate_state_get enabled 2>/dev/null)" = true ] && vg=开启
    core=$(_sidecar_version 2>/dev/null || true)
    listen=$(_sidecar_state_get listen)
    port=$(_sidecar_state_get port)
    listener=$(_sidecar_listener_line "$port")
    if [ -n "$listener" ]; then
        if _sidecar_is_active && grep -q 'xray' <<<"$listener"; then
            port_state=监听中
        else
            port_state='被其他进程占用（冲突）'
        fi
    fi
    node=$(_sidecar_state_get node-name)
    server=$(_sidecar_state_get server)
    server_port=$(_sidecar_state_get server-port)
    method=$(_sidecar_state_get method)
    last_test=$(_sidecar_state_get last-test-at)
    last_ip=$(_sidecar_state_get last-test-ip)
    last_error=$(_sidecar_state_get last-error)
    cat <<EOF
Xray 旁代理状态
  开关状态：$enabled
  服务进程：$active
  核心版本：${core:-未安装}
  监听地址：${listen:-0.0.0.0}:${port:-10112}
  端口状态：$port_state
  当前节点：${node:-未导入}
  节点地址：${server:-未设置}$([ -n "$server" ] && printf ':%s' "$server_port")
  加密方法：${method:-未设置}
  主 Mihomo：$main
  主 TUN：$tun
  VPNGate：$vg
  最近测试：${last_test:-从未}$([ -n "$last_ip" ] && printf ' → %s' "$last_ip")
  最近错误：${last_error:-无}
EOF
    [ -z "$listener" ] || printf '  监听进程：%s\n' "$listener"
}

_sidecar_logs() {
    local lines=${1:-80}
    if command -v journalctl >/dev/null 2>&1 && [ -f "$CLASH_SIDECAR_SERVICE_PATH" ]; then
        journalctl -u "$CLASH_SIDECAR_SERVICE" --no-pager -n "$lines"
    elif [ -s "$CLASH_SIDECAR_LOG" ]; then
        tail -n "$lines" "$CLASH_SIDECAR_LOG"
    else
        printf '暂无旁代理日志。\n'
    fi
}
