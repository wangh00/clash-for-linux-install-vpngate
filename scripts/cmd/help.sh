#!/usr/bin/env bash

clashhelp() {
  cat <<EOF

Usage:
  clashctl COMMAND [OPTIONS]

Commands:
  (无参数)              打开交互式控制中心
  menu                  打开交互式控制中心
  on                    开启代理
  off                   关闭代理
  status                内核状态
  ui                    面板地址
  sub                   订阅管理
  node                  节点切换
  vpngate               VPNGate OpenVPN 出口（直连优先、前置回退）
  tun                   Tun 模式
  mixin                 Mixin 配置
  secret                Web 密钥
  log                   查看日志
  upgrade               升级内核

Global Options:
  -h, --help            显示帮助信息

更多使用说明：https://github.com/wangh00/clash-for-linux-install-vpngate
EOF
}
