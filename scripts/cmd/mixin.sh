#!/usr/bin/env bash

_mixin_view() {
    local config_file=$1
    # runtime.yaml 可能包含订阅生成的超长 flow-style 行；less 会把它误判为
    # binary。-f 强制按文本打开，-S 避免终端被超长行撑乱。
    if command -v less >/dev/null 2>&1; then
        less -f -S "$config_file"
    else
        cat "$config_file"
    fi
}

clashmixin() {
    case "$1" in
    -h | --help)
        mixin_help
        return 0
        ;;
    -e)
        "${EDITOR:-vim}" "$CLASH_CONFIG_MIXIN" && {
            _merge_config_restart && _okcat "配置更新成功，已重启生效"
        }
        ;;
    -r)
        _mixin_view "$CLASH_CONFIG_RUNTIME"
        ;;
    -c)
        _mixin_view "$CLASH_CONFIG_BASE"
        ;;
    *)
        _mixin_view "$CLASH_CONFIG_MIXIN"
        ;;
    esac
}

mixin_help() {
    cat <<EOF

- 查看 Mixin 配置：$CLASH_CONFIG_MIXIN
  clashctl mixin

- 编辑 Mixin 配置
  clashctl mixin -e

- 查看原始订阅配置：$CLASH_CONFIG_BASE
  clashctl mixin -c

- 查看运行时配置：$CLASH_CONFIG_RUNTIME
  clashctl mixin -r

EOF
}
