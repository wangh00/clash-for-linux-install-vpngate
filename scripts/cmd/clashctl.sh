#!/usr/bin/env bash

. "$CLASHCTL_HOME"/.env

for lib_file in "$CLASHCTL_HOME"/scripts/lib/*.sh; do
    . "$lib_file"
done

for cmd_file in "$CLASHCTL_HOME"/scripts/cmd/*.sh; do
    case "$cmd_file" in *clashctl.*) continue ;; esac
    . "$cmd_file"
done

_clashctl_dispatch() {
    local sub_cmd

    if [ $# -eq 0 ]; then
        if [ -t 0 ] && [ -t 1 ]; then
            clashmenu
        else
            clashhelp
        fi
        return
    fi

    sub_cmd=$1
    shift

    case $sub_cmd in
    -h | --help | help) sub_cmd=help ;;
    esac

    local target="clash${sub_cmd}"
    declare -F "$target" >&/dev/null || {
        _failcat "Unknown subcommand: $target"
        _failcat "Use 'clashctl help' for usage information."
        return
    }
    "$target" "$@"
}

# Bash 会把 source 过的函数保留在当前进程中。这里把 clashctl 设计成稳定的
# 轻量入口：每次调用先重新读取磁盘上的最新版模块，再交给新加载的 dispatcher。
# 因此本版本之后更新脚本无需再次手工 source，同时 clashctl on/off 对当前
# Shell 代理环境变量的修改仍然能够保留。
clashctl() {
    local -a clashctl_argv=("$@")
    . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"
    _clashctl_dispatch "${clashctl_argv[@]}"
}
