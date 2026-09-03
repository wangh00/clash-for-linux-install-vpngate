#!/usr/bin/env bash

VPNGATE_GROUP_DIRECT="VPNGate-直连"
VPNGATE_GROUP_FRONT="VPNGate-经前置"
VPNGATE_GROUP_AUTO="VPNGate-AUTO"
VPNGATE_GROUP_SMART_AUTO="VPNGate-智能自动"
VPNGATE_GROUP_DIRECT_AUTO="VPNGate-直连-AUTO"
VPNGATE_GROUP_FRONT_AUTO="VPNGate-经前置-AUTO"

_vpngate_init_files() {
    mkdir -p "$CLASH_VPNGATE_DIR"
    [ -s "$CLASH_VPNGATE_STATE" ] || cat >"$CLASH_VPNGATE_STATE" <<'EOF'
enabled: false
front-group: ""
country: ""
# 0 表示不限制，导入所有通过校验并去重的节点。
limit: 0
updated-at: ""
node-count: 0
checked-at: ""
last-update-result: ""
last-update-error: ""
last-apply-method: ""
auto-update-enabled: false
auto-update-interval: 60
last-auto-check: ""
last-auto-result: ""
last-auto-error: ""
EOF
    [ -s "$CLASH_VPNGATE_OVERLAY" ] || printf '{}\n' >"$CLASH_VPNGATE_OVERLAY"
    [ -s "$CLASH_VPNGATE_NODES_DIRECT" ] || printf 'proxies: []\n' >"$CLASH_VPNGATE_NODES_DIRECT"
    [ -s "$CLASH_VPNGATE_NODES_FRONT" ] || printf 'proxies: []\n' >"$CLASH_VPNGATE_NODES_FRONT"
}

_vpngate_state_get() {
    _vpngate_init_files
    STATE_KEY=$1 "$BIN_YQ" '.[strenv(STATE_KEY)] // ""' "$CLASH_VPNGATE_STATE" 2>/dev/null
}

_vpngate_state_set() {
    local key=$1 value=$2
    STATE_KEY=$key STATE_VALUE=$value "$BIN_YQ" -i '
      .[strenv(STATE_KEY)] = strenv(STATE_VALUE)
    ' "$CLASH_VPNGATE_STATE"
}

_vpngate_state_set_bool() {
    local key=$1 value=$2
    STATE_KEY=$key STATE_VALUE=$value "$BIN_YQ" -i '
      .[strenv(STATE_KEY)] = (strenv(STATE_VALUE) == "true")
    ' "$CLASH_VPNGATE_STATE"
}

_vpngate_state_set_num() {
    local key=$1 value=$2
    STATE_KEY=$key STATE_VALUE=$value "$BIN_YQ" -i '
      .[strenv(STATE_KEY)] = (strenv(STATE_VALUE) | tonumber)
    ' "$CLASH_VPNGATE_STATE"
}

_vpngate_with_lock() {
    _vpngate_init_files
    command -v flock >/dev/null 2>&1 || {
        "$@"
        return
    }
    (
        flock -w 120 7 || {
            _errorcat "另一项 VPNGate 操作正在进行，请稍后重试"
            exit 1
        }
        "$@"
    ) 7>>"$CLASH_VPNGATE_LOCK"
}

_vpngate_is_internal_group() {
    case "$1" in
    "$VPNGATE_GROUP_DIRECT" | "$VPNGATE_GROUP_FRONT" | "$VPNGATE_GROUP_AUTO" | \
        "$VPNGATE_GROUP_SMART_AUTO" | \
        "$VPNGATE_GROUP_DIRECT_AUTO" | "$VPNGATE_GROUP_FRONT_AUTO")
        return 0
        ;;
    *) return 1 ;;
    esac
}

_vpngate_filter_front_groups() {
    local group
    while IFS= read -r group; do
        [ -n "$group" ] || continue
        _vpngate_is_internal_group "$group" || printf '%s\n' "$group"
    done
}

_vpngate_list_groups() {
    if service_is_active >/dev/null 2>&1; then
        _node_groups 2>/dev/null | cut -f1 | _vpngate_filter_front_groups
        return
    fi
    "$BIN_YQ" '.proxy-groups // [] | .[] | .name' "$CLASH_CONFIG_RUNTIME" 2>/dev/null |
        _vpngate_filter_front_groups
}

_vpngate_front_exists() {
    local front=$1
    [ -n "$front" ] || return 1
    _vpngate_list_groups | grep -Fqx -- "$front"
}

_vpngate_limit_label() {
    local limit=${1:-0}
    if [ "$limit" = 0 ]; then
        printf 'ALL'
    else
        printf '%s' "$limit"
    fi
}

# 全部节点仍写入顶层并显示在手动选择组中；这里只限制隐藏 AUTO 组的后台
# 候选数量，避免首次启动时同时建立 174 条 OpenVPN 握手。它不是导入上限。
_vpngate_auto_probe_limit() {
    local limit=${CLASHCTL_VPNGATE_AUTO_PROBE_LIMIT:-20}
    [[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=20
    printf '%s\n' "$limit"
}

# 前置始终保存为“策略组”，而不是启动时解析出的某个具体节点。这样前端在
# 9090 改变该组的选择后，Mihomo 的 dialer-proxy 会自动走新的当前节点。
# 此函数仅用于展示这条当前链路，不会把节点名写回 VPNGate 状态。
_vpngate_front_route() {
    local current=${1:-} next route
    local i

    [ -n "$current" ] || return 0
    route=$current
    service_is_active >/dev/null 2>&1 || {
        printf '%s\n' "$route"
        return 0
    }

    # Selector / URLTest 可以嵌套；最多向下展示 8 层，避免异常配置形成循环。
    for ((i = 0; i < 8; i++)); do
        next=$(_node_now "$current" 2>/dev/null) || break
        [ -n "$next" ] && [ "$next" != "$current" ] || break
        route+=" → $next"
        current=$next
    done
    printf '%s\n' "$route"
}

_vpngate_route_mode_label() {
    local mode=${1:-$(_node_now "$VPNGATE_GROUP_AUTO" 2>/dev/null)}
    case "$mode" in
    "$VPNGATE_GROUP_SMART_AUTO") printf '智能自动' ;;
    "$VPNGATE_GROUP_DIRECT") printf '固定直连' ;;
    "$VPNGATE_GROUP_FRONT") printf '固定经前置' ;;
    *) printf '旧版自动/未获取' ;;
    esac
}

_vpngate_route_leaf() {
    local route
    route=$(_vpngate_front_route "${1:-$VPNGATE_GROUP_AUTO}")
    [ -n "$route" ] || return 0
    printf '%s\n' "${route##* → }"
}

_vpngate_local_proxy_args() {
    local mixed_port http_port bind_addr auth
    IFS='|' read -r mixed_port http_port auth < <(
        "$BIN_YQ" '[.mixed-port // "", .port // "", .authentication[0] // ""] | join("|")' \
            "$CLASH_CONFIG_RUNTIME"
    )
    local port=${http_port:-${mixed_port:-7890}}
    bind_addr=$(_get_bind_addr)
    case "$bind_addr" in
    '' | '*' | 0.0.0.0) bind_addr=127.0.0.1 ;;
    esac

    VPNGATE_CURL_PROXY=(--proxy "http://${bind_addr}:${port}")
    [ -n "$auth" ] && VPNGATE_CURL_PROXY+=(--proxy-user "$auth")
}

_vpngate_fetch_api() {
    local dest=$1
    service_is_active >/dev/null 2>&1 || {
        _errorcat "Mihomo 未运行，无法通过前置订阅获取 VPNGate 数据"
        return 1
    }
    _vpngate_local_proxy_args
    _okcat '🌐' '通过前置订阅获取 VPNGate 节点...'
    curl \
        --silent \
        --show-error \
        --fail \
        --location \
        --compressed \
        --connect-timeout "${CLASHCTL_VPNGATE_CONNECT_TIMEOUT:-10}" \
        --max-time "${CLASHCTL_VPNGATE_FETCH_TIMEOUT:-90}" \
        --retry "${CLASHCTL_VPNGATE_RETRY:-2}" \
        --retry-delay 1 \
        --user-agent "${CLASHCTL_SUB_UA:-clash-verge/v2.4.0}" \
        "${VPNGATE_CURL_PROXY[@]}" \
        --output "$dest" \
        "${CLASHCTL_VPNGATE_API_URL:-https://www.vpngate.net/api/iphone/}"
}

_vpngate_ovpn_value() {
    local file=$1 directive=$2
    awk -v wanted="$directive" '
      /^[[:space:]]*[#;]/ { next }
      {
        key=tolower($1)
        if (key == wanted) {
          $1=""
          sub(/^[[:space:]]+/, "")
          print
          exit
        }
      }
    ' "$file"
}

_vpngate_ovpn_block() {
    local file=$1 tag=$2
    awk -v open_tag="<${tag}>" -v close_tag="</${tag}>" '
      $0 == open_tag  { inside=1; next }
      $0 == close_tag { exit }
      inside      { print }
    ' "$file"
}

_vpngate_yaml_quote() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '"%s"' "$value"
}

_vpngate_yaml_block() {
    sed 's/^/      /'
}

# 把一个已解码的 VPNGate .ovpn 追加为 Mihomo OpenVPN 节点。
# 初版只接受 dev tun + proto tcp + 证书认证，保证经前置链时的兼容性。
_vpngate_append_node() {
    local file=$1 country=$2 api_ip=$3 output=$4
    local remote proto dev cipher data_ciphers data_fallback auth comp_lzo
    local mtu ping ping_restart key_direction ca cert key tls_auth tls_crypt tls_crypt_v2

    remote=$(_vpngate_ovpn_value "$file" remote)
    proto=$(_vpngate_ovpn_value "$file" proto)
    dev=$(_vpngate_ovpn_value "$file" dev)
    cipher=$(_vpngate_ovpn_value "$file" cipher)
    data_ciphers=$(_vpngate_ovpn_value "$file" data-ciphers)
    data_fallback=$(_vpngate_ovpn_value "$file" data-ciphers-fallback)
    auth=$(_vpngate_ovpn_value "$file" auth)
    comp_lzo=$(_vpngate_ovpn_value "$file" comp-lzo)
    mtu=$(_vpngate_ovpn_value "$file" tun-mtu)
    [ -n "$mtu" ] || mtu=$(_vpngate_ovpn_value "$file" link-mtu)
    ping=$(_vpngate_ovpn_value "$file" ping)
    ping_restart=$(_vpngate_ovpn_value "$file" ping-restart)
    key_direction=$(_vpngate_ovpn_value "$file" key-direction)

    local remote_host remote_port
    read -r remote_host remote_port _ <<<"$remote"
    [ -n "$remote_host" ] || remote_host=$api_ip
    [ -n "$remote_port" ] || remote_port=1194

    proto=${proto,,}
    case "$proto" in tcp*) proto=tcp ;; *) return 1 ;; esac
    dev=${dev,,}
    case "$dev" in '' | tun*) ;; *) return 1 ;; esac
    [[ "$remote_host" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    [[ "$remote_port" =~ ^[0-9]+$ ]] || return 1
    ((remote_port >= 1 && remote_port <= 65535)) || return 1

    ca=$(_vpngate_ovpn_block "$file" ca)
    cert=$(_vpngate_ovpn_block "$file" cert)
    key=$(_vpngate_ovpn_block "$file" key)
    [ -n "$ca" ] && [ -n "$cert" ] && [ -n "$key" ] || return 1
    tls_auth=$(_vpngate_ovpn_block "$file" tls-auth)
    tls_crypt=$(_vpngate_ovpn_block "$file" tls-crypt)
    tls_crypt_v2=$(_vpngate_ovpn_block "$file" tls-crypt-v2)

    local name="VPNGate-${country:-XX}-${api_ip}-${remote_port}"
    {
        printf '  - name: %s\n' "$(_vpngate_yaml_quote "$name")"
        printf '    type: openvpn\n'
        printf '    server: %s\n' "$(_vpngate_yaml_quote "$remote_host")"
        printf '    port: %s\n' "$remote_port"
        printf '    proto: tcp\n'
        printf '    udp: true\n'
        [ -n "$cipher" ] && printf '    cipher: %s\n' "$(_vpngate_yaml_quote "$cipher")"
        if [ -n "$data_ciphers" ]; then
            printf '    data-ciphers:\n'
            local dc
            while IFS= read -r dc; do
                [ -n "$dc" ] && printf '      - %s\n' "$(_vpngate_yaml_quote "$dc")"
            done < <(tr ':' '\n' <<<"$data_ciphers")
        fi
        [ -n "$data_fallback" ] && printf '    data-ciphers-fallback: %s\n' "$(_vpngate_yaml_quote "$data_fallback")"
        [ -n "$auth" ] && printf '    auth: %s\n' "$(_vpngate_yaml_quote "$auth")"
        case "${comp_lzo,,}" in yes | no | adaptive) printf '    comp-lzo: %s\n' "$(_vpngate_yaml_quote "${comp_lzo,,}")" ;; esac
        printf '    ca: |\n'; printf '%s\n' "$ca" | _vpngate_yaml_block
        printf '    cert: |\n'; printf '%s\n' "$cert" | _vpngate_yaml_block
        printf '    key: |\n'; printf '%s\n' "$key" | _vpngate_yaml_block
        if [ -n "$tls_auth" ]; then
            printf '    tls-auth: |\n'; printf '%s\n' "$tls_auth" | _vpngate_yaml_block
            [ -n "$key_direction" ] && printf '    key-direction: %s\n' "$(_vpngate_yaml_quote "$key_direction")"
        elif [ -n "$tls_crypt" ]; then
            printf '    tls-crypt: |\n'; printf '%s\n' "$tls_crypt" | _vpngate_yaml_block
        elif [ -n "$tls_crypt_v2" ]; then
            printf '    tls-crypt-v2: |\n'; printf '%s\n' "$tls_crypt_v2" | _vpngate_yaml_block
        fi
        [[ "$mtu" =~ ^[0-9]+$ ]] && printf '    mtu: %s\n' "$mtu"
        [[ "$ping" =~ ^[0-9]+$ ]] && printf '    ping: %s\n' "$ping"
        [[ "$ping_restart" =~ ^[0-9]+$ ]] && printf '    ping-restart: %s\n' "$ping_restart"
    } >>"$output"
    return 0
}

_vpngate_generate_nodes() {
    local csv=$1 country=$2 limit=$3
    local work_dir candidates nodes_tmp node_tmp ovpn count=0 node_name
    local -A seen_names=()
    work_dir=$(mktemp -d "${CLASH_VPNGATE_DIR}/.build.XXXXXX") || return 1
    candidates="${work_dir}/candidates.tsv"
    nodes_tmp="${work_dir}/nodes.yaml"
    node_tmp="${work_dir}/node.yaml"
    ovpn="${work_dir}/node.ovpn"

    awk -v country="$country" -f "${CLASHCTL_HOME}/scripts/lib/vpngate_csv.awk" "$csv" |
        LC_ALL=C sort -t $'\t' -k1,1nr -k2,2nr -k3,3n >"$candidates"
    printf 'proxies:\n' >"$nodes_tmp"

    local score speed ping country_short ip host config_b64
    while IFS=$'\t' read -r score speed ping country_short ip host config_b64; do
        [ "$limit" -gt 0 ] && [ "$count" -ge "$limit" ] && break
        printf '%s' "$config_b64" | tr -d '[:space:]' | base64 -d >"$ovpn" 2>/dev/null || continue
        sed -i 's/\r$//' "$ovpn"

        # 全量导入时 API 可能包含重复中继。先生成单节点 YAML，再按 Mihomo
        # 最终看到的代理名去重，避免 duplicate proxy name 导致配置启动失败。
        printf 'proxies:\n' >"$node_tmp"
        _vpngate_append_node "$ovpn" "$country_short" "$ip" "$node_tmp" || continue
        node_name=$("$BIN_YQ" -r '.proxies[0].name // ""' "$node_tmp" 2>/dev/null)
        [ -n "$node_name" ] || continue
        [ -z "${seen_names[$node_name]+x}" ] || continue
        seen_names["$node_name"]=1
        sed '1d' "$node_tmp" >>"$nodes_tmp"
        count=$((count + 1))
    done <"$candidates"

    [ "$count" -gt 0 ] || {
        rm -rf "$work_dir"
        _errorcat "没有解析出可用的 VPNGate TCP/OpenVPN 节点"
        return 1
    }
    "$BIN_YQ" -e '.proxies | type == "!!seq" and length > 0' "$nodes_tmp" >/dev/null || {
        rm -rf "$work_dir"
        _errorcat "生成的 VPNGate 节点 YAML 无效"
        return 1
    }

    # 对完整节点对象按名称排序后签名。API 的评分/排列变化不会触发无意义的
    # Mihomo 重启；节点、证书或连接参数真正变化时才发布新缓存。
    local old_signature new_signature
    old_signature=$(_vpngate_nodes_signature "$CLASH_VPNGATE_NODES_DIRECT")
    new_signature=$(_vpngate_nodes_signature "$nodes_tmp")
    VPNGATE_NODES_CHANGED=true
    if [ -n "$old_signature" ] && [ "$old_signature" = "$new_signature" ]; then
        VPNGATE_NODES_CHANGED=false
    else
        # 缓存两份未加前缀的原始节点。生成 overlay 时分别转换成
        # [直连]/[前置] 顶层代理。
        cp "$nodes_tmp" "${CLASH_VPNGATE_NODES_DIRECT}.tmp"
        cp "$nodes_tmp" "${CLASH_VPNGATE_NODES_FRONT}.tmp"
        mv -f "${CLASH_VPNGATE_NODES_DIRECT}.tmp" "$CLASH_VPNGATE_NODES_DIRECT"
        mv -f "${CLASH_VPNGATE_NODES_FRONT}.tmp" "$CLASH_VPNGATE_NODES_FRONT"
    fi
    cp "$csv" "${CLASH_VPNGATE_API_RAW}.tmp"
    mv -f "${CLASH_VPNGATE_API_RAW}.tmp" "$CLASH_VPNGATE_API_RAW"
    rm -rf "$work_dir"
    VPNGATE_GENERATED_COUNT=$count
}

_vpngate_nodes_signature() {
    local file=$1
    [ -s "$file" ] || return 0
    "$BIN_YQ" -o=json -I=0 '.proxies | sort_by(.name)' "$file" 2>/dev/null |
        sha256sum 2>/dev/null | awk '{print $1}'
}

_vpngate_build_static_nodes() {
    local front=$1 output_dir=$2
    local direct_file="${output_dir}/direct.yaml" front_file="${output_dir}/front.yaml"

    cp "$CLASH_VPNGATE_NODES_DIRECT" "$direct_file" || return 1
    cp "$CLASH_VPNGATE_NODES_FRONT" "$front_file" || return 1

    DIRECT_PREFIX='[直连] ' "$BIN_YQ" -i '
      .proxies |= map(.name = strenv(DIRECT_PREFIX) + .name)
    ' "$direct_file" || return 1
    FRONT_PREFIX='[前置] ' FRONT_GROUP="$front" "$BIN_YQ" -i '
      .proxies |= map(.name = strenv(FRONT_PREFIX) + .name |
                     .["dialer-proxy"] = strenv(FRONT_GROUP))
    ' "$front_file" || return 1

    "$BIN_YQ" -e '.proxies | type == "!!seq" and length > 0' "$direct_file" >/dev/null &&
        "$BIN_YQ" -e '.proxies | type == "!!seq" and length > 0' "$front_file" >/dev/null
}

# 按 API 综合评分顺序挑选不同 /24 的 AUTO 候选，避免榜首被同一个 VPNGate
# 网段占满。所有未选中的节点仍保留在可见组中，可全体测速和手动选择。
_vpngate_build_probe_names() {
    local source=$1 output=$2 limit=$3
    local rows="${output}.rows" name

    "$BIN_YQ" -r '.proxies[] | [.name, .server] | @tsv' "$source" |
        awk -F '\t' -v limit="$limit" '
          function subnet(server, parts, count) {
            count = split(server, parts, ".")
            if (count == 4 &&
                parts[1] ~ /^[0-9]+$/ && parts[2] ~ /^[0-9]+$/ &&
                parts[3] ~ /^[0-9]+$/ && parts[4] ~ /^[0-9]+$/) {
              return parts[1] "." parts[2] "." parts[3]
            }
            return server
          }
          {
            key = subnet($2)
            if (!(key in seen)) {
              seen[key] = 1
              print $1
              selected++
              if (selected >= limit) exit
            }
          }
        ' >"$rows" || return 1

    printf 'proxies:\n' >"$output"
    while IFS= read -r name; do
        [ -n "$name" ] && printf '  - %s\n' "$(_vpngate_yaml_quote "$name")" >>"$output"
    done <"$rows"
    rm -f "$rows"

    "$BIN_YQ" -e '.proxies | type == "!!seq" and length > 0' "$output" >/dev/null
}

_vpngate_write_overlay() {
    local mode=$1 front=$2
    local tmp="${CLASH_VPNGATE_OVERLAY}.tmp"
    local health_url=${CLASHCTL_VPNGATE_DELAY_URL:-https://cp.cloudflare.com}

    if [ "$mode" = off ]; then
        printf '{}\n' >"$tmp"
    elif [ "$mode" = bootstrap ]; then
        FRONT_GROUP=$front "$BIN_YQ" -n '
          {
            "tun": {"enable": true},
            "rules": {"prepend": ["DOMAIN,www.vpngate.net," + strenv(FRONT_GROUP)]}
          }
        ' >"$tmp"
    else
        local static_dir direct_static front_static direct_probe front_probe auto_probe_limit
        static_dir=$(mktemp -d "${CLASH_VPNGATE_DIR}/.static.XXXXXX") || return 1
        direct_static="${static_dir}/direct.yaml"
        front_static="${static_dir}/front.yaml"
        direct_probe="${static_dir}/direct-probe.yaml"
        front_probe="${static_dir}/front-probe.yaml"
        auto_probe_limit=$(_vpngate_auto_probe_limit)

        _vpngate_build_static_nodes "$front" "$static_dir" || {
            rm -rf "$static_dir"
            return 1
        }
        _vpngate_build_probe_names "$direct_static" "$direct_probe" "$auto_probe_limit" &&
            _vpngate_build_probe_names "$front_static" "$front_probe" "$auto_probe_limit" || {
            rm -rf "$static_dir"
            return 1
        }

        if ! DIRECT_FILE="$direct_static" FRONT_FILE="$front_static" \
            DIRECT_PROBE_FILE="$direct_probe" FRONT_PROBE_FILE="$front_probe" \
            FRONT_GROUP="$front" HEALTH_URL="$health_url" \
            GROUP_DIRECT=$VPNGATE_GROUP_DIRECT GROUP_FRONT=$VPNGATE_GROUP_FRONT GROUP_AUTO=$VPNGATE_GROUP_AUTO \
            GROUP_SMART_AUTO=$VPNGATE_GROUP_SMART_AUTO \
            GROUP_DIRECT_AUTO=$VPNGATE_GROUP_DIRECT_AUTO GROUP_FRONT_AUTO=$VPNGATE_GROUP_FRONT_AUTO \
            "$BIN_YQ" -n '
              (load(strenv(DIRECT_FILE)).proxies // []) as $direct |
              (load(strenv(FRONT_FILE)).proxies // []) as $front |
              ($direct | map(.name)) as $directNames |
              ($front | map(.name)) as $frontNames |
              (load(strenv(DIRECT_PROBE_FILE)).proxies // []) as $directProbeNames |
              (load(strenv(FRONT_PROBE_FILE)).proxies // []) as $frontProbeNames |
              {
                "tun": {"enable": true},
                "proxies": {"append": ($direct + $front)},
                "rules": {
                  "prepend": [
                    "DOMAIN,www.vpngate.net," + strenv(FRONT_GROUP),
                    "MATCH," + strenv(GROUP_AUTO)
                  ]
                },
                "proxy-groups": {
                  "append": [
                    {
                      "name": strenv(GROUP_DIRECT_AUTO), "type": "url-test",
                      "proxies": $directProbeNames, "url": strenv(HEALTH_URL),
                      "interval": 180, "timeout": 15000, "tolerance": 50,
                      "hidden": true
                    },
                    {
                      "name": strenv(GROUP_FRONT_AUTO), "type": "url-test",
                      "proxies": $frontProbeNames, "url": strenv(HEALTH_URL),
                      "interval": 300, "timeout": 20000, "tolerance": 100,
                      "hidden": true
                    },
                    {
                      "name": strenv(GROUP_DIRECT), "type": "select",
                      "proxies": [strenv(GROUP_DIRECT_AUTO)] + $directNames
                    },
                    {
                      "name": strenv(GROUP_FRONT), "type": "select",
                      "proxies": [strenv(GROUP_FRONT_AUTO)] + $frontNames
                    },
                    {
                      "name": strenv(GROUP_SMART_AUTO), "type": "fallback",
                      "proxies": [strenv(GROUP_DIRECT), strenv(GROUP_FRONT)],
                      "url": strenv(HEALTH_URL), "interval": 120, "timeout": 20000,
                      "hidden": true
                    },
                    {
                      "name": strenv(GROUP_AUTO), "type": "select",
                      "proxies": [strenv(GROUP_SMART_AUTO), strenv(GROUP_DIRECT), strenv(GROUP_FRONT)],
                      "hidden": true
                    }
                  ]
                }
              }
            ' >"$tmp"; then
            rm -rf "$static_dir"
            rm -f "$tmp"
            return 1
        fi
        rm -rf "$static_dir"
    fi

    "$BIN_YQ" -e '.' "$tmp" >/dev/null || {
        rm -f "$tmp"
        return 1
    }
    mv -f "$tmp" "$CLASH_VPNGATE_OVERLAY"
}

_vpngate_sync_nodes() {
    local country=$1 limit=$2
    local csv_tmp="${CLASH_VPNGATE_DIR}/.servers.$$.csv"
    _vpngate_fetch_api "$csv_tmp" || {
        rm -f "$csv_tmp"
        return 1
    }
    _vpngate_generate_nodes "$csv_tmp" "$country" "$limit" || {
        rm -f "$csv_tmp"
        return 1
    }
    rm -f "$csv_tmp"
    printf '%s 检查成功 country=%s limit=%s nodes=%s changed=%s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "${country:-ALL}" "$(_vpngate_limit_label "$limit")" \
        "$VPNGATE_GENERATED_COUNT" "$VPNGATE_NODES_CHANGED" >>"$CLASH_VPNGATE_LOG"
}
