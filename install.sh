#!/usr/bin/env bash

CLASHCTL_SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
. "$CLASHCTL_SRC/scripts/preflight.sh"

valid_env
parse_args "$@"

_okcat "安装内核：$CLASHCTL_KERNEL"
_okcat '📦' "安装路径：$CLASHCTL_HOME"

prepare_zip

install_service
install_clashctl

_configure_lan_proxy

_merge_config
_detect_proxy_port
clashui
[ -z "$(_get_secret)" ] && clashsecret "$(_get_random_val)" >/dev/null
clashsecret

_valid_config "$CLASH_CONFIG_BASE" && {
    CLASHCTL_SUB_URL="file://$CLASH_CONFIG_BASE"
}
[ -z "$CLASHCTL_SUB_URL" ] || clashsub add --use "$CLASHCTL_SUB_URL"
[ -n "$CLASHCTL_SUB_URL" ] ||
    _okcat 'ℹ️' '未配置初始订阅；安装完成后可执行 clashctl sub add --use <URL>'
_okcat '🎉' "请执行 source ~/.bashrc 为当前 SHELL 加载 clashctl 命令"
