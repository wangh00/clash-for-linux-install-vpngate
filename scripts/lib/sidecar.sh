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
protocol: ""
server: ""
server-port: 0
method: ""
transport: ""
security: ""
core-version: ""
updated-at: ""
last-test-at: ""
last-test-ip: ""
last-error: ""
EOF
    chmod 600 "$CLASH_SIDECAR_STATE" 2>/dev/null || true
    # 从只记录 Shadowsocks 的旧状态平滑迁移，配置文件仍是运行事实来源。
    if [ -s "$CLASH_SIDECAR_CONFIG" ] && ! grep -q '^protocol:' "$CLASH_SIDECAR_STATE"; then
        local protocol transport security
        protocol=$("$BIN_YQ" -p=json -r '.outbounds[0].protocol // ""' \
            "$CLASH_SIDECAR_CONFIG" 2>/dev/null)
        transport=$("$BIN_YQ" -p=json -r \
            '.outbounds[0].streamSettings.network // .outbounds[0].streamSettings.method // "tcp"' \
            "$CLASH_SIDECAR_CONFIG" 2>/dev/null)
        security=$("$BIN_YQ" -p=json -r '.outbounds[0].streamSettings.security // "none"' \
            "$CLASH_SIDECAR_CONFIG" 2>/dev/null)
        STATE_PROTOCOL=${protocol:-shadowsocks} STATE_TRANSPORT=${transport:-tcp} \
            STATE_SECURITY=${security:-none} "$BIN_YQ" -i '
              .protocol = strenv(STATE_PROTOCOL) |
              .transport = strenv(STATE_TRANSPORT) |
              .security = strenv(STATE_SECURITY)
            ' "$CLASH_SIDECAR_STATE"
    fi
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
    local value=$1 output='' prefix rest hex decoded
    while [[ "$value" == *%* ]]; do
        prefix=${value%%\%*}
        rest=${value#*%}
        hex=${rest:0:2}
        [[ "$hex" =~ ^[0-9A-Fa-f]{2}$ ]] && [ "$hex" != 00 ] || {
            _errorcat '节点链接包含无效的 URL 转义'
            return 1
        }
        printf -v decoded '%b' "\\x$hex"
        output+="$prefix$decoded"
        value=${rest:2}
    done
    printf '%s' "$output$value"
}

_sidecar_query_get() {
    local query=$1 wanted=$2 default=${3:-} pair key value
    while IFS= read -r pair; do
        key=${pair%%=*}
        [ "$key" = "$wanted" ] || continue
        if [[ "$pair" == *=* ]]; then
            value=${pair#*=}
        else
            value=''
        fi
        _sidecar_url_decode "$value" || return
        return 0
    done < <(tr '&' '\n' <<<"$query")
    printf '%s' "$default"
}

_sidecar_clean_label() {
    LC_ALL=C tr -d '\000-\037\177'
}

_sidecar_parse_host_port() {
    local hostport=$1 label=${2:-节点}
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
        _errorcat "$label服务器端口无效"
        return 1
    }
    [ -n "$SIDECAR_NODE_SERVER" ] || {
        _errorcat "$label服务器地址为空"
        return 1
    }
}

_sidecar_reset_node_vars() {
    SIDECAR_NODE_PROTOCOL=''
    SIDECAR_NODE_NAME=''
    SIDECAR_NODE_SERVER=''
    SIDECAR_NODE_PORT=''
    SIDECAR_NODE_USER=''
    SIDECAR_NODE_ALTER_ID=0
    SIDECAR_NODE_PASSWORD=''
    SIDECAR_NODE_METHOD=''
    SIDECAR_NODE_TRANSPORT='tcp'
    SIDECAR_NODE_SECURITY='none'
    SIDECAR_NODE_FLOW=''
    SIDECAR_NODE_SNI=''
    SIDECAR_NODE_FP=''
    SIDECAR_NODE_ALPN=''
    SIDECAR_NODE_INSECURE='false'
    SIDECAR_NODE_HOST=''
    SIDECAR_NODE_PATH=''
    SIDECAR_NODE_HEADER_TYPE=''
    SIDECAR_NODE_SEED=''
    SIDECAR_NODE_SERVICE_NAME=''
    SIDECAR_NODE_AUTHORITY=''
    SIDECAR_NODE_MODE=''
    SIDECAR_NODE_EXTRA=''
    SIDECAR_NODE_PBK=''
    SIDECAR_NODE_SID=''
    SIDECAR_NODE_SPX=''
}

_sidecar_parse_ss_uri() {
    local uri=$1 body fragment authority userinfo hostport credentials decoded
    [[ "$uri" == ss://* ]] || return 1
    SIDECAR_NODE_PROTOCOL=shadowsocks
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
        userinfo=$(_sidecar_url_decode "$userinfo") || return
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

    _sidecar_parse_host_port "$hostport" Shadowsocks || return
    [ -n "$SIDECAR_NODE_SERVER" ] && [ -n "$SIDECAR_NODE_METHOD" ] &&
        [ -n "$SIDECAR_NODE_PASSWORD" ] || {
        _errorcat 'Shadowsocks 链接字段不完整'
        return 1
    }
    SIDECAR_NODE_NAME=$(_sidecar_url_decode "$fragment") || return
    [ -n "$SIDECAR_NODE_NAME" ] ||
        SIDECAR_NODE_NAME="${SIDECAR_NODE_SERVER}:${SIDECAR_NODE_PORT}"
}

_sidecar_parse_standard_uri() {
    local uri=$1 scheme=$2 body fragment='' query='' authority userinfo hostport
    body=${uri#*://}
    if [[ "$body" == *#* ]]; then
        fragment=${body#*#}
        body=${body%%#*}
    fi
    if [[ "$body" == *\?* ]]; then
        query=${body#*\?}
        body=${body%%\?*}
    fi
    [[ "$body" == *@* ]] || {
        _errorcat "无法解析 ${scheme^^} 分享链接"
        return 1
    }
    userinfo=$(_sidecar_url_decode "${body%@*}") || return
    hostport=${body##*@}
    _sidecar_parse_host_port "$hostport" "${scheme^^}" || return
    [ -n "$userinfo" ] || {
        _errorcat "${scheme^^} 链接缺少用户 ID 或密码"
        return 1
    }

    SIDECAR_NODE_PROTOCOL=$scheme
    SIDECAR_NODE_USER=$userinfo
    SIDECAR_NODE_NAME=$(_sidecar_url_decode "$fragment") || return
    SIDECAR_NODE_TRANSPORT=$(_sidecar_query_get "$query" type tcp) || return
    SIDECAR_NODE_SECURITY=$(_sidecar_query_get "$query" security none) || return
    SIDECAR_NODE_FLOW=$(_sidecar_query_get "$query" flow '') || return
    SIDECAR_NODE_SNI=$(_sidecar_query_get "$query" sni '') || return
    SIDECAR_NODE_FP=$(_sidecar_query_get "$query" fp '') || return
    SIDECAR_NODE_ALPN=$(_sidecar_query_get "$query" alpn '') || return
    SIDECAR_NODE_INSECURE=$(_sidecar_query_get "$query" allowInsecure false) || return
    [ "$SIDECAR_NODE_INSECURE" != false ] ||
        SIDECAR_NODE_INSECURE=$(_sidecar_query_get "$query" insecure false) || return
    SIDECAR_NODE_HOST=$(_sidecar_query_get "$query" host '') || return
    SIDECAR_NODE_PATH=$(_sidecar_query_get "$query" path '') || return
    SIDECAR_NODE_HEADER_TYPE=$(_sidecar_query_get "$query" headerType '') || return
    SIDECAR_NODE_SEED=$(_sidecar_query_get "$query" seed '') || return
    SIDECAR_NODE_SERVICE_NAME=$(_sidecar_query_get "$query" serviceName '') || return
    [ -n "$SIDECAR_NODE_SERVICE_NAME" ] ||
        SIDECAR_NODE_SERVICE_NAME=$SIDECAR_NODE_PATH
    SIDECAR_NODE_AUTHORITY=$(_sidecar_query_get "$query" authority '') || return
    SIDECAR_NODE_MODE=$(_sidecar_query_get "$query" mode '') || return
    SIDECAR_NODE_EXTRA=$(_sidecar_query_get "$query" extra '') || return
    SIDECAR_NODE_PBK=$(_sidecar_query_get "$query" pbk '') || return
    SIDECAR_NODE_SID=$(_sidecar_query_get "$query" sid '') || return
    SIDECAR_NODE_SPX=$(_sidecar_query_get "$query" spx '') || return
    [ -n "$SIDECAR_NODE_NAME" ] ||
        SIDECAR_NODE_NAME="${SIDECAR_NODE_SERVER}:${SIDECAR_NODE_PORT}"

    case "$scheme" in
    vless)
        SIDECAR_NODE_METHOD=$(_sidecar_query_get "$query" encryption none) || return
        ;;
    vmess)
        SIDECAR_NODE_METHOD=$(_sidecar_query_get "$query" encryption auto) || return
        ;;
    trojan)
        # Trojan 分享链接省略 security 时按行业通用约定使用 TLS。
        [[ "&$query&" == *'&security='* ]] || SIDECAR_NODE_SECURITY=tls
        SIDECAR_NODE_PASSWORD=$userinfo
        SIDECAR_NODE_METHOD=$SIDECAR_NODE_SECURITY
        ;;
    esac
}

_sidecar_parse_vmess_legacy() {
    local uri=$1 body json
    body=${uri#vmess://}
    body=${body%%#*}
    json=$(_sidecar_b64_decode "$body") || {
        _errorcat 'VMess Base64 解码失败'
        return 1
    }
    printf '%s' "$json" | "$BIN_YQ" -p=json -e 'type == "!!map"' >/dev/null 2>&1 || {
        _errorcat 'VMess 分享链接中的 JSON 无效'
        return 1
    }
    SIDECAR_NODE_PROTOCOL=vmess
    SIDECAR_NODE_NAME=$(printf '%s' "$json" | "$BIN_YQ" -p=json -r '.ps // ""')
    SIDECAR_NODE_SERVER=$(printf '%s' "$json" | "$BIN_YQ" -p=json -r '.add // ""')
    SIDECAR_NODE_PORT=$(printf '%s' "$json" | "$BIN_YQ" -p=json -r '.port // ""')
    SIDECAR_NODE_USER=$(printf '%s' "$json" | "$BIN_YQ" -p=json -r '.id // ""')
    SIDECAR_NODE_ALTER_ID=$(printf '%s' "$json" | "$BIN_YQ" -p=json -r '.aid // 0')
    SIDECAR_NODE_METHOD=$(printf '%s' "$json" | "$BIN_YQ" -p=json -r '.scy // "auto"')
    SIDECAR_NODE_TRANSPORT=$(printf '%s' "$json" | "$BIN_YQ" -p=json -r '.net // "tcp"')
    SIDECAR_NODE_SECURITY=$(printf '%s' "$json" | "$BIN_YQ" -p=json -r '.tls // "none"')
    [ -n "$SIDECAR_NODE_SECURITY" ] || SIDECAR_NODE_SECURITY=none
    SIDECAR_NODE_SNI=$(printf '%s' "$json" | "$BIN_YQ" -p=json -r '.sni // ""')
    SIDECAR_NODE_FP=$(printf '%s' "$json" | "$BIN_YQ" -p=json -r '.fp // ""')
    SIDECAR_NODE_ALPN=$(printf '%s' "$json" | "$BIN_YQ" -p=json -r '.alpn // ""')
    SIDECAR_NODE_HOST=$(printf '%s' "$json" | "$BIN_YQ" -p=json -r '.host // ""')
    SIDECAR_NODE_PATH=$(printf '%s' "$json" | "$BIN_YQ" -p=json -r '.path // ""')
    SIDECAR_NODE_HEADER_TYPE=$(printf '%s' "$json" | "$BIN_YQ" -p=json -r '.type // ""')
    SIDECAR_NODE_SERVICE_NAME=$SIDECAR_NODE_PATH
    SIDECAR_NODE_AUTHORITY=$SIDECAR_NODE_HOST
    SIDECAR_NODE_INSECURE=$(printf '%s' "$json" | "$BIN_YQ" -p=json -r '.allowInsecure // false')
    _sidecar_parse_host_port "${SIDECAR_NODE_SERVER}:${SIDECAR_NODE_PORT}" VMess || return
    [ -n "$SIDECAR_NODE_USER" ] || {
        _errorcat 'VMess 链接缺少用户 ID'
        return 1
    }
    [[ "$SIDECAR_NODE_ALTER_ID" =~ ^[0-9]+$ ]] || {
        _errorcat 'VMess alterId 无效'
        return 1
    }
    [ -n "$SIDECAR_NODE_NAME" ] ||
        SIDECAR_NODE_NAME="${SIDECAR_NODE_SERVER}:${SIDECAR_NODE_PORT}"
}

_sidecar_parse_uri() {
    local uri=$1
    _sidecar_reset_node_vars
    case "$uri" in
    ss://*) _sidecar_parse_ss_uri "$uri" ;;
    vless://*) _sidecar_parse_standard_uri "$uri" vless ;;
    trojan://*) _sidecar_parse_standard_uri "$uri" trojan ;;
    vmess://*)
        if [[ "${uri#vmess://}" == *@* ]]; then
            _sidecar_parse_standard_uri "$uri" vmess
        else
            _sidecar_parse_vmess_legacy "$uri"
        fi
        ;;
    *)
        _errorcat '不支持的节点链接；当前支持 ss://、vless://、vmess://、trojan://'
        return 1
        ;;
    esac || return

    SIDECAR_NODE_NAME=$(printf '%s' "$SIDECAR_NODE_NAME" | _sidecar_clean_label)
    [ -n "$SIDECAR_NODE_NAME" ] ||
        SIDECAR_NODE_NAME="${SIDECAR_NODE_SERVER}:${SIDECAR_NODE_PORT}"

    case "$SIDECAR_NODE_TRANSPORT" in
    '' | tcp | raw) SIDECAR_NODE_TRANSPORT=tcp ;;
    ws | websocket) SIDECAR_NODE_TRANSPORT=ws ;;
    grpc | httpupgrade | xhttp) ;;
    http | h2)
        # Xray 26 已移除旧 HTTP transport；分享链接中的 HTTP/H2 兼容映射到
        # XHTTP stream-one，保留其 HTTP/2/3 单流语义。
        SIDECAR_NODE_TRANSPORT=xhttp
        [ -n "$SIDECAR_NODE_MODE" ] || SIDECAR_NODE_MODE=stream-one
        ;;
    kcp | mkcp) SIDECAR_NODE_TRANSPORT=kcp ;;
    *)
        _errorcat "暂不支持传输方式：$SIDECAR_NODE_TRANSPORT"
        return 1
        ;;
    esac
    case "$SIDECAR_NODE_SECURITY" in
    '' | none) SIDECAR_NODE_SECURITY=none ;;
    tls | reality) ;;
    xtls) SIDECAR_NODE_SECURITY=tls ;;
    *)
        _errorcat "暂不支持传输安全：$SIDECAR_NODE_SECURITY"
        return 1
        ;;
    esac
    if [ -n "$SIDECAR_NODE_EXTRA" ]; then
        printf '%s' "$SIDECAR_NODE_EXTRA" |
            "$BIN_YQ" -p=json -e 'type == "!!map"' >/dev/null 2>&1 || {
            _errorcat '节点链接中的 extra 不是有效 JSON 对象'
            return 1
        }
    fi
}

_sidecar_write_config() {
    local target=$1 listen=$2 port=$3 outbound
    outbound="${target}.outbound.json"
    : "${SIDECAR_NODE_TRANSPORT:=tcp}"
    : "${SIDECAR_NODE_SECURITY:=none}"
    : "${SIDECAR_NODE_PROTOCOL:=shadowsocks}"
    local path=${SIDECAR_NODE_PATH:-/}
    [ -n "$path" ] || path=/

    case "$SIDECAR_NODE_PROTOCOL" in
    shadowsocks)
        SIDECAR_SERVER=$SIDECAR_NODE_SERVER SIDECAR_SERVER_PORT=$SIDECAR_NODE_PORT \
            SIDECAR_METHOD=$SIDECAR_NODE_METHOD SIDECAR_PASSWORD=$SIDECAR_NODE_PASSWORD \
            "$BIN_YQ" -n -o=json '{
              "tag": "proxy", "protocol": "shadowsocks",
              "settings": {"servers": [{
                "address": strenv(SIDECAR_SERVER), "port": (strenv(SIDECAR_SERVER_PORT) | tonumber),
                "method": strenv(SIDECAR_METHOD), "password": strenv(SIDECAR_PASSWORD), "level": 1
              }]}, "mux": {"enabled": false, "concurrency": -1}
            }' >"$outbound"
        ;;
    vless)
        SIDECAR_SERVER=$SIDECAR_NODE_SERVER SIDECAR_SERVER_PORT=$SIDECAR_NODE_PORT \
            SIDECAR_USER=$SIDECAR_NODE_USER SIDECAR_METHOD=$SIDECAR_NODE_METHOD \
            SIDECAR_FLOW=$SIDECAR_NODE_FLOW "$BIN_YQ" -n -o=json '{
              "tag": "proxy", "protocol": "vless",
              "settings": {"vnext": [{
                "address": strenv(SIDECAR_SERVER), "port": (strenv(SIDECAR_SERVER_PORT) | tonumber),
                "users": [{"id": strenv(SIDECAR_USER), "encryption": strenv(SIDECAR_METHOD),
                  "flow": strenv(SIDECAR_FLOW), "level": 0}]
              }]}, "mux": {"enabled": false, "concurrency": -1}
            }' >"$outbound"
        ;;
    vmess)
        SIDECAR_SERVER=$SIDECAR_NODE_SERVER SIDECAR_SERVER_PORT=$SIDECAR_NODE_PORT \
            SIDECAR_USER=$SIDECAR_NODE_USER SIDECAR_METHOD=$SIDECAR_NODE_METHOD \
            SIDECAR_ALTER_ID=${SIDECAR_NODE_ALTER_ID:-0} \
            "$BIN_YQ" -n -o=json '{
              "tag": "proxy", "protocol": "vmess",
              "settings": {"vnext": [{
                "address": strenv(SIDECAR_SERVER), "port": (strenv(SIDECAR_SERVER_PORT) | tonumber),
                "users": [{"id": strenv(SIDECAR_USER), "security": strenv(SIDECAR_METHOD),
                  "alterId": (strenv(SIDECAR_ALTER_ID) | tonumber), "level": 0}]
              }]}, "mux": {"enabled": false, "concurrency": -1}
            }' >"$outbound"
        ;;
    trojan)
        SIDECAR_SERVER=$SIDECAR_NODE_SERVER SIDECAR_SERVER_PORT=$SIDECAR_NODE_PORT \
            SIDECAR_PASSWORD=$SIDECAR_NODE_PASSWORD "$BIN_YQ" -n -o=json '{
              "tag": "proxy", "protocol": "trojan",
              "settings": {"servers": [{
                "address": strenv(SIDECAR_SERVER), "port": (strenv(SIDECAR_SERVER_PORT) | tonumber),
                "password": strenv(SIDECAR_PASSWORD), "level": 0
              }]}, "mux": {"enabled": false, "concurrency": -1}
            }' >"$outbound"
        ;;
    *) rm -f "$outbound"; _errorcat "无法生成协议配置：$SIDECAR_NODE_PROTOCOL"; return 1 ;;
    esac || { rm -f "$outbound"; return 1; }

    SIDECAR_TRANSPORT=$SIDECAR_NODE_TRANSPORT SIDECAR_SECURITY=$SIDECAR_NODE_SECURITY \
        "$BIN_YQ" -i -o=json '.streamSettings = {
          "network": strenv(SIDECAR_TRANSPORT), "security": strenv(SIDECAR_SECURITY)
        }' "$outbound" || { rm -f "$outbound"; return 1; }
    case "$SIDECAR_NODE_TRANSPORT" in
    ws)
        SIDECAR_PATH=$path SIDECAR_HOST=$SIDECAR_NODE_HOST "$BIN_YQ" -i -o=json \
            '.streamSettings.wsSettings = {"path": strenv(SIDECAR_PATH),
              "headers": {"Host": strenv(SIDECAR_HOST)}}' "$outbound"
        ;;
    grpc)
        SIDECAR_SERVICE_NAME=$SIDECAR_NODE_SERVICE_NAME SIDECAR_AUTHORITY=$SIDECAR_NODE_AUTHORITY \
            "$BIN_YQ" -i -o=json '.streamSettings.grpcSettings = {
              "serviceName": strenv(SIDECAR_SERVICE_NAME), "authority": strenv(SIDECAR_AUTHORITY)
            }' "$outbound"
        ;;
    httpupgrade)
        SIDECAR_PATH=$path SIDECAR_HOST=$SIDECAR_NODE_HOST "$BIN_YQ" -i -o=json \
            '.streamSettings.httpupgradeSettings = {"path": strenv(SIDECAR_PATH),
              "host": strenv(SIDECAR_HOST)}' "$outbound"
        ;;
    xhttp)
        SIDECAR_PATH=$path SIDECAR_HOST=$SIDECAR_NODE_HOST SIDECAR_MODE=$SIDECAR_NODE_MODE \
            "$BIN_YQ" -i -o=json '.streamSettings.xhttpSettings = {
              "path": strenv(SIDECAR_PATH), "host": strenv(SIDECAR_HOST), "mode": strenv(SIDECAR_MODE)
            }' "$outbound" || { rm -f "$outbound"; return 1; }
        if [ -n "$SIDECAR_NODE_EXTRA" ]; then
            SIDECAR_EXTRA=$SIDECAR_NODE_EXTRA "$BIN_YQ" -i -o=json \
                '.streamSettings.xhttpSettings.extra = (strenv(SIDECAR_EXTRA) | from_json)' "$outbound"
        fi
        ;;
    kcp)
        # Xray 26 把旧 mKCP seed/header 迁移到了 FinalMask。分享链接仍沿用
        # 原字段，这里做等价转换，避免生成已被核心删除的 kcpSettings 字段。
        "$BIN_YQ" -i -o=json '.streamSettings.kcpSettings = {}' "$outbound" || {
            rm -f "$outbound"
            return 1
        }
        if [ -n "$SIDECAR_NODE_SEED" ]; then
            SIDECAR_SEED=$SIDECAR_NODE_SEED "$BIN_YQ" -i -o=json \
                '.streamSettings.finalmask.udp = [{"type": "mkcp-aes128gcm",
                  "settings": {"password": strenv(SIDECAR_SEED)}}]' "$outbound"
        else
            "$BIN_YQ" -i -o=json '.streamSettings.finalmask.udp = [
              {"type": "mkcp-original", "settings": {}}]' "$outbound"
        fi || { rm -f "$outbound"; return 1; }
        local kcp_header=${SIDECAR_NODE_HEADER_TYPE,,}
        case "$kcp_header" in
        '' | none) ;;
        wechat-video) kcp_header=wechat ;;
        srtp | utp | wechat | dtls | wireguard | dns) ;;
        *) _errorcat "不支持的 mKCP headerType：$SIDECAR_NODE_HEADER_TYPE"; rm -f "$outbound"; return 1 ;;
        esac
        if [ -n "$kcp_header" ] && [ "$kcp_header" != none ]; then
            SIDECAR_HEADER_MASK="header-$kcp_header" "$BIN_YQ" -i -o=json \
                '.streamSettings.finalmask.udp += [{"type": strenv(SIDECAR_HEADER_MASK), "settings": {}}]' \
                "$outbound"
        fi
        ;;
    tcp)
        if [ -n "$SIDECAR_NODE_HEADER_TYPE" ] && [ "$SIDECAR_NODE_HEADER_TYPE" != none ]; then
            SIDECAR_HEADER_TYPE=$SIDECAR_NODE_HEADER_TYPE "$BIN_YQ" -i -o=json \
                '.streamSettings.tcpSettings = {"header": {"type": strenv(SIDECAR_HEADER_TYPE)}}' "$outbound"
        fi
        ;;
    esac || { rm -f "$outbound"; return 1; }

    case "$SIDECAR_NODE_SECURITY" in
    tls)
        SIDECAR_SNI=$SIDECAR_NODE_SNI SIDECAR_FP=$SIDECAR_NODE_FP \
            SIDECAR_INSECURE=$SIDECAR_NODE_INSECURE "$BIN_YQ" -i -o=json \
            '.streamSettings.tlsSettings = {"serverName": strenv(SIDECAR_SNI),
              "fingerprint": strenv(SIDECAR_FP),
              "allowInsecure": (strenv(SIDECAR_INSECURE) == "true" or strenv(SIDECAR_INSECURE) == "1")}' \
            "$outbound" || { rm -f "$outbound"; return 1; }
        if [ -n "$SIDECAR_NODE_ALPN" ]; then
            SIDECAR_ALPN=$SIDECAR_NODE_ALPN "$BIN_YQ" -i -o=json \
                '.streamSettings.tlsSettings.alpn = (strenv(SIDECAR_ALPN) | split(","))' "$outbound"
        fi
        ;;
    reality)
        SIDECAR_SNI=$SIDECAR_NODE_SNI SIDECAR_FP=${SIDECAR_NODE_FP:-chrome} \
            SIDECAR_PBK=$SIDECAR_NODE_PBK SIDECAR_SID=$SIDECAR_NODE_SID \
            SIDECAR_SPX=$SIDECAR_NODE_SPX "$BIN_YQ" -i -o=json \
            '.streamSettings.realitySettings = {
              "serverName": strenv(SIDECAR_SNI), "fingerprint": strenv(SIDECAR_FP),
              "publicKey": strenv(SIDECAR_PBK), "shortId": strenv(SIDECAR_SID),
              "spiderX": strenv(SIDECAR_SPX)
            }' "$outbound"
        ;;
    esac || { rm -f "$outbound"; return 1; }

    SIDECAR_LISTEN=$listen SIDECAR_PORT=$port OUTBOUND_FILE=$outbound \
        "$BIN_YQ" -n -o=json '
          load(strenv(OUTBOUND_FILE)) as $proxy |
          {
            "log": {"loglevel": "warning"},
            "inbounds": [{
              "tag": "mixed-in", "listen": strenv(SIDECAR_LISTEN),
              "port": (strenv(SIDECAR_PORT) | tonumber), "protocol": "mixed",
              "sniffing": {"enabled": true, "destOverride": ["http", "tls"], "routeOnly": false},
              "settings": {"auth": "noauth", "udp": true, "allowTransparent": false}
            }],
            "outbounds": [$proxy, {"tag": "direct", "protocol": "freedom"},
              {"tag": "block", "protocol": "blackhole"}],
            "routing": {"domainStrategy": "AsIs", "rules": []}
          }
        ' >"$target"
    local rc=$?
    rm -f "$outbound"
    return "$rc"
}

# 兼容旧脚本/测试调用名。
_sidecar_write_ss_config() {
    _sidecar_write_config "$@"
}

_sidecar_import_locked() {
    local uri=$1 listen port tmp backup='' was_active=false
    _sidecar_init_files
    _sidecar_parse_uri "$uri" || return
    listen=$(_sidecar_state_get listen)
    port=$(_sidecar_state_get port)
    # Xray 26 依据扩展名识别配置格式，临时文件也必须保留 .json 后缀。
    tmp=$(mktemp "${CLASH_SIDECAR_DIR}/.config.XXXXXX.json") || return
    _sidecar_write_config "$tmp" "$listen" "$port" || {
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
    _sidecar_state_set protocol "$SIDECAR_NODE_PROTOCOL"
    _sidecar_state_set server "$SIDECAR_NODE_SERVER"
    _sidecar_state_set_num server-port "$SIDECAR_NODE_PORT"
    _sidecar_state_set method "$SIDECAR_NODE_METHOD"
    _sidecar_state_set transport "$SIDECAR_NODE_TRANSPORT"
    _sidecar_state_set security "$SIDECAR_NODE_SECURITY"
    _sidecar_state_set updated-at "$(date '+%Y-%m-%d %H:%M:%S')"
    _sidecar_state_set last-error ''
    _okcat '✅' "旁代理节点已导入：$SIDECAR_NODE_NAME（${SIDECAR_NODE_PROTOCOL}/${SIDECAR_NODE_TRANSPORT}）"
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
        _errorcat '尚未导入旁代理节点：clashctl sidecar import <分享链接>'
        return 1
    }
    [ -x "$BIN_XRAY" ] || {
        _okcat 'ℹ️' '首次使用，安装并校验 Xray 稳定版核心…'
        _sidecar_core_update_locked "${CLASHCTL_XRAY_VERSION:-latest}" || return
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
    tmp=$(mktemp "${CLASH_SIDECAR_DIR}/.config.XXXXXX.json") || return
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
    local node protocol server server_port method transport security last_test last_ip last_error
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
    protocol=$(_sidecar_state_get protocol)
    server=$(_sidecar_state_get server)
    server_port=$(_sidecar_state_get server-port)
    method=$(_sidecar_state_get method)
    transport=$(_sidecar_state_get transport)
    security=$(_sidecar_state_get security)
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
  节点协议：${protocol:-Shadowsocks（旧配置）}
  节点地址：${server:-未设置}$([ -n "$server" ] && printf ':%s' "$server_port")
  传输方式：${transport:-tcp}$([ -n "$security" ] && printf ' + %s' "$security")
  协议参数：${method:-未设置}
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
