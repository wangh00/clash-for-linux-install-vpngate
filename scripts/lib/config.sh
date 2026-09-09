#!/usr/bin/env bash

_get_bind_addr() {
  local allow_lan bind_addr
  IFS='|' read -r bind_addr allow_lan < <(
    "$BIN_YQ" '[.bind-address // "*", .allow-lan // false] | join("|")' "$CLASH_CONFIG_RUNTIME"
  )

  case $allow_lan in
  true)
    [ "$bind_addr" = "*" ] && bind_addr=$(_get_local_ip)
    ;;
  false)
    bind_addr=127.0.0.1
    ;;
  esac
  printf '%s\n' "$bind_addr"
}

_detect_proxy_port() {
  local mixed_port http_port socks_port
  IFS='|' read -r mixed_port http_port socks_port < <(
    "$BIN_YQ" '[.mixed-port // "", .port // "", .socks-port // ""] | join("|")' "$CLASH_CONFIG_RUNTIME"
  )

  [ -z "$mixed_port" ] && [ -z "$http_port" ] && [ -z "$socks_port" ] && mixed_port=7890

  local count=0
  local service_active=false
  service_is_active >&/dev/null && service_active=true

  local entries=(
    "mixed-port:$mixed_port"
    "port:$http_port"
    "socks-port:$socks_port"
  )

  local entry yaml_key port new_port
  for entry in "${entries[@]}"; do
    yaml_key=${entry%%:*}
    port=${entry#*:}

    [ -n "$port" ] && _is_port_used "$port" && [ "$service_active" != "true" ] && {
      new_port=$(_get_random_port) || return
      count=$((count + 1))
      _failcat '🎯' "端口冲突：[$yaml_key] $port 🎲 随机分配 $new_port"
      "$BIN_YQ" -i ".${yaml_key} = $new_port" "$CLASH_CONFIG_MIXIN"
    }
  done

  [ "$count" -gt 0 ] && _merge_config
}

_detect_ext_addr() {
  local ext_addr
  ext_addr=$("$BIN_YQ" '.external-controller // ""' "$CLASH_CONFIG_RUNTIME")

  local ext_ip=${ext_addr%%:*}
  local ext_port=${ext_addr##*:}

  EXT_IP=$ext_ip
  EXT_PORT=$ext_port
  [ "$ext_ip" = '0.0.0.0' ] && EXT_IP=$(_get_local_ip)

  local service_active=false
  service_is_active >&/dev/null && service_active=true

  _is_port_used "$EXT_PORT" && [ "$service_active" != "true" ] && {
    local new_port
    new_port=$(_get_random_port) || return
    _failcat '🎯' "端口冲突：[external-controller] ${EXT_PORT} 🎲 随机分配 $new_port"
    EXT_PORT=$new_port
    EXT_ADDR="$ext_ip:$new_port" "$BIN_YQ" -i '.external-controller = env(EXT_ADDR)' "$CLASH_CONFIG_MIXIN"
    _merge_config
  }
}

_get_secret() {
  "$BIN_YQ" '.secret // ""' "$CLASH_CONFIG_RUNTIME"
}

_configure_lan_proxy() {
  local port=${CLASHCTL_MIXED_PORT:-7890}
  local bind_addr=${CLASHCTL_LAN_BIND_ADDRESS:-0.0.0.0}
  local allow_lan=false username=${CLASHCTL_PROXY_USERNAME:-admin}
  local password=${CLASHCTL_PROXY_PASSWORD:-}
  [ "${CLASHCTL_LAN_ALLOW:-1}" = 1 ] && allow_lan=true

  [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || {
    _errorcat "CLASHCTL_MIXED_PORT 无效：$port"
    return 1
  }
  [ -n "$bind_addr" ] || bind_addr='*'
  [ "$allow_lan" = true ] && [ -n "$username" ] && [ -z "$password" ] && {
    password=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)
  }
  local proxy_auth=''
  [ -n "$username" ] && [ -n "$password" ] && proxy_auth="${username}:${password}"

  MIXED_PORT=$port BIND_ADDR=$bind_addr ALLOW_LAN=$allow_lan \
  PROXY_AUTH="$proxy_auth" "$BIN_YQ" -i '
    .mixed-port = (strenv(MIXED_PORT) | tonumber) |
    .bind-address = strenv(BIND_ADDR) |
    .allow-lan = (strenv(ALLOW_LAN) == "true") |
    .authentication = ([strenv(PROXY_AUTH)] | map(select(. != "")))
  ' "$CLASH_CONFIG_MIXIN"

  _set_env CLASHCTL_PROXY_USERNAME "$username"
  _set_env CLASHCTL_PROXY_PASSWORD "$password"
  _set_env CLASHCTL_MIXED_PORT "$port"
  _set_env CLASHCTL_LAN_BIND_ADDRESS "$bind_addr"
  _okcat '🔌' "局域网代理：http/socks5://${bind_addr}:${port}"
  [ -n "$username" ] && _okcat '🔐' "代理认证：${username}:${password}"
}

_valid_config() {
  local config="$1"
  [[ ! -e "$config" || "$(wc -l <"$config")" -lt 1 ]] && return 1

  local test_log
  test_log=$("$BIN_KERNEL" -d "$(dirname "$config")" -f "$config" -t 2>&1) || {
    printf '%s\n' "$test_log" >&2
    grep -qs "unsupport proxy type" <<<"$test_log" && {
      local prefix="检测到订阅中包含不受支持的代理协议"
      if [ "$CLASHCTL_KERNEL" = "clash" ]; then
        _errorcat "${prefix}, 推荐安装使用 mihomo 内核"
      else
        _errorcat "${prefix}, 请检查并升级内核版本"
      fi
    }
    return 1
  }
}

_merge_config() {
  # 订阅切换、Tun 开关与 VPNGate 定时更新都可能触发配置合并。统一串行化，
  # 避免 runtime.yaml 被多个 mv/重定向同时写坏。
  command -v flock >/dev/null 2>&1 || {
    _merge_config_unlocked
    return
  }
  (
    flock -w 60 8 || {
      _errorcat "另一项配置操作正在进行，请稍后重试"
      exit 1
    }
    _merge_config_unlocked
  ) 8>>"$CLASH_CONFIG_LOCK"
}

_merge_config_unlocked() {
  [ -s "$CLASH_VPNGATE_OVERLAY" ] || printf '{}\n' >"$CLASH_VPNGATE_OVERLAY"
  cat "$CLASH_CONFIG_RUNTIME" >"$CLASH_CONFIG_TEMP" 2>/dev/null
  # shellcheck disable=SC2016
  "$BIN_YQ" eval-all '
      ########################################
      #              Load Files              #
      ########################################
      select(fileIndex==0) as $config |
      select(fileIndex==1) as $mixin |
      select(fileIndex==2) as $vpngate |

      ########################################
      #              Deep Merge              #
      ########################################
      $mixin |= del(._custom) |
      $vpngate |= del(._custom) |
      (($config // {}) * $mixin * $vpngate) as $runtime |
      $runtime |

      ########################################
      #        Tun DNS fallback              #
      ########################################
      # DNS 默认不接管，仅在 Tun 开启且无任何 dns 配置时补
      # 最小骨架，避免 dns-hijack 劫持的查询收到 SERVFAIL。
      (((.tun.enable // false) == true)) as $tunOn |
      (select($tunOn and ((.dns // {}) | keys | length) == 0) | .dns = {
        "enable": true,
        "listen": "0.0.0.0:1053",
        "enhanced-mode": "fake-ip",
        "nameserver": ["114.114.114.114", "8.8.8.8"]
      }) // . |

      ########################################
      #               Rules                  #
      ########################################
      .rules = (
        ($vpngate.rules.prepend // []) +
        ($mixin.rules.prepend // []) +
        ($config.rules // []) +
        ($mixin.rules.append // []) +
        ($vpngate.rules.append // [])
      ) |

      ########################################
      #                Proxies               #
      ########################################
      .proxies = (
        ($vpngate.proxies.prepend // []) +
        ($mixin.proxies.prepend // []) +
        (
          ($config.proxies // []) as $configList |
          ($mixin.proxies.override // []) as $overrideList |
          $configList | map(
            . as $configItem |
            (
              $overrideList[] | select(.name == $configItem.name)
            ) // $configItem
          )
        ) +
        ($mixin.proxies.append // []) +
        ($vpngate.proxies.append // [])
      ) |

      ########################################
      #             ProxyGroups              #
      ########################################
      .proxy-groups = (
        ($vpngate.proxy-groups.prepend // []) +
        ($mixin.proxy-groups.prepend // []) +
        (
          ($config.proxy-groups // []) as $configList |
          ($mixin.proxy-groups.override // []) as $overrideList |
          $configList | map(
            . as $configItem |
            (
              $overrideList[] | select(.name == $configItem.name)
            ) // $configItem
          )
        ) +
        ($mixin.proxy-groups.append // []) +
        ($vpngate.proxy-groups.append // [])
      ) |

      ########################################
      #         ProxyGroups Inject           #
      ########################################
      ($mixin.proxy-groups.inject // {}) as $inj |
      .proxy-groups[] |= (
        . as $g |
        ($inj | .[$g.name] // []) as $extra |
        .proxies = ((.proxies // []) + $extra | unique)
      )
    ' "$CLASH_CONFIG_BASE" "$CLASH_CONFIG_MIXIN" "$CLASH_VPNGATE_OVERLAY" >"$CLASH_CONFIG_RUNTIME"

  _valid_config "$CLASH_CONFIG_RUNTIME" || {
    cat "$CLASH_CONFIG_TEMP" >"$CLASH_CONFIG_RUNTIME"
    _errorcat "验证失败：请检查 Mixin 配置"
    return 1
  }
}
tunstatus() {
  local device
  device=$("$BIN_YQ" '.tun.device // ""' "$CLASH_CONFIG_RUNTIME")
  [ -z "$device" ] && device="Meta"
  ip link show | grep -qs "$device" && {
    _okcat 'Tun 状态：启用'
    return 0
  }
  _failcat 'Tun 状态：关闭'
  return 1
}
_is_tun_enabled() {
  "$BIN_YQ" -e '.tun.enable == true' "$CLASH_CONFIG_RUNTIME" >&/dev/null
}
_apply_runtime_restart() {
  local was_tun_active=${1:-false}
  if [ "${was_tun_active}" = true ]; then
    service_sudo_stop >/dev/null
    service_is_active >&/dev/null && {
      _errorcat "请先关闭 Tun 模式"
      return 2
    }
  else
    service_stop >&/dev/null
  fi

  sleep 0.1

  # rc=2：合并成功（runtime 已是新配置）但服务重启失败
  if _is_tun_enabled; then
    service_sudo_start >/dev/null
    sleep 1
    tunstatus >&/dev/null || {
      _errorcat "Tun 模式重启失败，请检查代理内核日志"
      return 2
    }
  else
    service_start >/dev/null || return 2
  fi

  CLASHCTL_CONFIG_APPLY_METHOD=restart
}

# 使用 Mihomo Controller 原生 PUT /configs 热加载已经校验过的 runtime.yaml。
# VPNGate 节点轻微增减时无需停止进程和销毁 TUN；Controller 不支持、请求失败
# 或热加载后 TUN 异常时，由调用方自动回退到传统 systemd 重启。
_apply_runtime_hot_reload() {
  [ "$CLASHCTL_KERNEL" = mihomo ] || return 1
  service_is_active >/dev/null 2>&1 || return 1

  local ext_addr ext_port secret body code expected_tun=false attempt
  ext_addr=$("$BIN_YQ" '.external-controller // ""' "$CLASH_CONFIG_RUNTIME" 2>/dev/null)
  ext_port=${ext_addr##*:}
  [[ "$ext_port" =~ ^[0-9]+$ ]] || return 1
  secret=$(_get_secret)
  body=$(CONFIG_PATH=$CLASH_CONFIG_RUNTIME "$BIN_YQ" -n -o=json \
    '{"path": strenv(CONFIG_PATH)}') || return 1
  _is_tun_enabled && expected_tun=true

  local auth=()
  [ -n "$secret" ] && auth=(-H "Authorization: Bearer $secret")
  code=$(curl -sS --noproxy '*' --max-time "${CLASHCTL_API_TIMEOUT:-10}" \
    -X PUT "${auth[@]}" -H 'Content-Type: application/json' \
    --data-raw "$body" -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:${ext_port}/configs?force=true" 2>/dev/null) || return 1
  case "$code" in 200 | 204) ;; *) return 1 ;; esac

  # Controller 返回后配置切换仍可能在内核线程中收尾，最多等待 5 秒确认。
  for attempt in 1 2 3 4 5; do
    service_is_active >/dev/null 2>&1 || return 1
    if [ "$expected_tun" = true ]; then
      tunstatus >/dev/null 2>&1 && {
        CLASHCTL_CONFIG_APPLY_METHOD=hot-reload
        return 0
      }
    else
      CLASHCTL_CONFIG_APPLY_METHOD=hot-reload
      return 0
    fi
    sleep 1
  done
  return 1
}

_merge_config_restart() {
  # 设默认值，兼容调用方启用了 `set -u` 的场景。
  local was_tun_active=false
  tunstatus >&/dev/null && was_tun_active=true
  # rc=1：合并/校验失败（runtime 已由 _merge_config 回滚为旧配置）
  _merge_config || return 1
  _apply_runtime_restart "$was_tun_active"
}

# VPNGate 周期更新专用：优先热加载，失败才完整重启。配置合并/校验只做一次，
# 避免回退路径再次改写 runtime 或覆盖事务备份。
_merge_config_reload() {
  local was_tun_active=false
  tunstatus >/dev/null 2>&1 && was_tun_active=true
  _merge_config || return 1

  if [ "${CLASHCTL_VPNGATE_HOT_RELOAD:-1}" = 1 ] && _apply_runtime_hot_reload; then
    _okcat '♻️' 'Mihomo 配置已热加载，进程与 TUN 未重启'
    return 0
  fi

  _failcat '⚠️' 'Mihomo 热加载不可用，自动回退到完整重启' || true
  _apply_runtime_restart "$was_tun_active"
}
