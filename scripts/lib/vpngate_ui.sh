#!/usr/bin/env bash

# VPNGate 节点已经写入 Mihomo 顶层，原生单测与选择均可用。为避免 Zashboard
# 的“全体测速”同时发出约 87 个独立请求，在捕获阶段接管两个可见组的标题
# 测速按钮，改用 Mihomo 原生 /group/:name/delay；节点卡片主体仍由
# Zashboard 处理以手动选择，节点延迟按钮改用 Cloudflare 目标做原生单测。
# 补丁带静态和浏览器运行时双重兼容性自检；Zashboard 更新导致 DOM 结构变化
# 时会明确提示，而不是静默失效。
_vpngate_patch_zashboard() {
    local ui_dir="${CLASH_RESOURCES_DIR}/dist"
    local index="${ui_dir}/index.html"
    local worker="${ui_dir}/sw.js"
    local script="${ui_dir}/vpngate-ui.js"
    local script_hash index_hash tag

    [ -s "$index" ] || return 0

    cat >"$script" <<'JS'
;(() => {
  const patchVersion = '2026.09.04.1'
  const checkStorageKey = 'clashctl/vpngate-ui-check'
  const routeSelector = 'VPNGate-AUTO'
  const smartAuto = 'VPNGate-\u667a\u80fd\u81ea\u52a8'
  const groups = new Map([
    ['VPNGate-\u76f4\u8fde', 15000],
    ['VPNGate-\u7ecf\u524d\u7f6e', 20000],
  ])
  let running = false
  let routeState = null
  let lastProxies = null
  let compatibilityErrorShown = false
  let apiFailureSince = 0
  let domFailureSince = 0
  const latencyResults = new Map()

  const controller = () => {
    try {
      const list = JSON.parse(localStorage.getItem('setup/api-list') || '[]')
      const active = localStorage.getItem('setup/active-uuid')
      const api = list.find((item) => item.uuid === active) || list[0]
      if (!api) return null
      const path = String(api.secondaryPath || '').replace(/^\/+|\/+$/g, '')
      return {
        base: `${api.protocol}://${api.host}:${api.port}${path ? `/${path}` : ''}`,
        password: api.password || '',
      }
    } catch {
      return null
    }
  }

  const toast = (message, error = false) => {
    let el = document.getElementById('vpngate-group-test-toast')
    if (!el) {
      el = document.createElement('div')
      el.id = 'vpngate-group-test-toast'
      Object.assign(el.style, {
        position: 'fixed',
        top: '18px',
        left: '50%',
        transform: 'translateX(-50%)',
        zIndex: '99999',
        padding: '10px 16px',
        borderRadius: '10px',
        color: '#fff',
        fontSize: '14px',
        boxShadow: '0 8px 24px rgba(0,0,0,.2)',
      })
      document.body.appendChild(el)
    }
    el.style.background = error ? '#dc2626' : '#2563eb'
    el.textContent = message
    el.hidden = false
    return el
  }

  // Zashboard 3.25 的延迟标签由 Vue 管理。直接替换 textContent/innerHTML
  // 会破坏虚拟 DOM 的锚点；这里仅设置 data 属性，再用伪元素把结果显示在
  // 原来的 40x20 延迟框里，不触碰 Vue 创建的任何子节点。
  const latencyStyle = document.createElement('style')
  latencyStyle.id = 'vpngate-latency-overlay-style'
  latencyStyle.textContent = `
    .latency-tag[data-vpngate-delay] { position: relative !important; }
    .latency-tag[data-vpngate-delay] > * { visibility: hidden !important; }
    .latency-tag[data-vpngate-delay]::after {
      content: attr(data-vpngate-delay);
      position: absolute;
      inset: 0;
      display: grid;
      place-items: center;
      font-size: 12px;
      line-height: 16px;
      font-variant-numeric: tabular-nums;
      color: currentColor;
      pointer-events: none;
    }
  `
  document.head.appendChild(latencyStyle)

  const renderLatencyResults = () => {
    document.querySelectorAll('.collapse-content .cursor-pointer').forEach((card) => {
      const name = card.innerText?.split('\n')?.[0]?.trim()
      const tag = card.querySelector('.latency-tag')
      if (!tag) return
      const value = latencyResults.get(name)
      if (value === undefined) {
        const ownedTitle = tag.dataset.vpngateDelayTitle
        if (ownedTitle && tag.getAttribute('title') === ownedTitle) tag.removeAttribute('title')
        tag.removeAttribute('data-vpngate-delay')
        tag.removeAttribute('data-vpngate-delay-title')
        return
      }
      tag.dataset.vpngateDelay = value
      tag.dataset.vpngateDelayTitle = value === '…' ? 'VPNGate 节点测速中' : `VPNGate 延迟 ${value} ms`
      tag.title = tag.dataset.vpngateDelayTitle
    })
  }

  const setLatencyResult = (node, value) => {
    latencyResults.set(node, String(value))
    renderLatencyResults()
  }

  const restoreLatencyResult = (node, previous) => {
    if (previous === undefined) latencyResults.delete(node)
    else latencyResults.set(node, previous)
    renderLatencyResults()
  }

  const saveCompatibility = (status, errors = [], detail = '') => {
    const report = {
      version: patchVersion,
      status,
      ok: errors.length === 0,
      errors,
      detail,
      checkedAt: new Date().toISOString(),
      page: location.hash,
    }
    try {
      localStorage.setItem(checkStorageKey, JSON.stringify(report))
    } catch {
      // localStorage 被浏览器策略禁用时不影响代理功能。
    }
    if (errors.length && !compatibilityErrorShown) {
      compatibilityErrorShown = true
      toast(`VPNGate UI 补丁兼容性异常：${errors.join('；')}`, true)
    }
    return report
  }

  const selectRoute = async (target) => {
    const api = controller()
    if (!api) throw new Error('无法读取 Zashboard Controller 配置')
    const headers = {
      'Content-Type': 'application/json',
      ...(api.password ? {Authorization: `Bearer ${api.password}`} : {}),
    }
    const response = await fetch(`${api.base}/proxies/${encodeURIComponent(routeSelector)}`, {
      method: 'PUT',
      headers,
      body: JSON.stringify({name: target}),
    })
    if (!response.ok) {
      const data = await response.json().catch(() => ({}))
      throw new Error(data.message || `HTTP ${response.status}`)
    }
  }

  const groupNameOf = (title) => [...groups.keys()].find((name) =>
    title?.innerText?.trimStart()?.startsWith(name))

  // Zashboard 2.x 显示“Selector”，3.25.x 改成了全大写“SELECTOR”。
  // 以 Controller 返回的组类型为主、DOM 文本为兼容兜底，避免再次把纯
  // 样式/大小写变化误判成不支持测速的组。
  const isSelectorType = (value) => String(value || '').toLowerCase().includes('selector')
  const isSelectorGroup = (group, title) =>
    isSelectorType(lastProxies?.[group]?.type) || isSelectorType(title?.innerText)

  const resolveLeaf = (proxies, start) => {
    let current = start || ''
    for (let depth = 0; depth < 8; depth += 1) {
      const next = proxies[current]?.now
      if (!next || next === current) break
      current = next
    }
    return current
  }

  const renderActiveRoute = () => {
    if (!routeState) return
    document.querySelectorAll('.collapse').forEach((collapse) => {
      const title = collapse.querySelector(':scope > .collapse-title')
      const group = groupNameOf(title)
      if (!group) return

      const active = group === routeState.activeGroup
      let badge = title.querySelector('[data-vpngate-route-badge]')
      if (!badge) {
        badge = document.createElement('span')
        badge.dataset.vpngateRouteBadge = 'true'
        Object.assign(badge.style, {
          flexShrink: '0',
          padding: '2px 7px',
          borderRadius: '999px',
          color: '#fff',
          fontSize: '11px',
          lineHeight: '16px',
          cursor: 'pointer',
        })
        const firstRow = title.firstElementChild
        firstRow?.insertBefore(badge, firstRow.lastElementChild)
      }
      badge.dataset.vpngateGroup = group
      const fixed = routeState.mode !== smartAuto
      const badgeText = active
        ? `● 当前出口·${fixed ? '固定' : '自动'}`
        : '点击切换到此链路'
      if (badge.textContent !== badgeText) badge.textContent = badgeText
      badge.style.background = active ? '#16a34a' : '#64748b'
      badge.title = active
        ? (fixed ? '点击恢复“智能自动”模式' : '当前由程序自动选择直连/经前置')
        : `点击强制使用${group.replace('VPNGate-', '')}`

      let detail = title.querySelector('[data-vpngate-route-detail]')
      if (!detail) {
        detail = document.createElement('div')
        detail.dataset.vpngateRouteDetail = 'true'
        Object.assign(detail.style, {
          marginTop: '6px',
          overflow: 'hidden',
          textOverflow: 'ellipsis',
          whiteSpace: 'nowrap',
          fontSize: '11px',
        })
        title.appendChild(detail)
      }
      const leaf = routeState.leaves[group] || '未获取'
      const detailText = `${active ? '实际出口' : '备用选择'}：${leaf}` +
        (active && fixed ? '（固定模式，点绿色标记恢复自动）' : '')
      if (detail.textContent !== detailText) detail.textContent = detailText
      detail.style.color = active ? '#16a34a' : '#64748b'
      collapse.style.outline = active ? '2px solid #22c55e' : ''
      collapse.style.outlineOffset = active ? '-2px' : ''
      collapse.style.borderRadius = active ? '10px' : ''

      collapse.querySelectorAll(':scope > .collapse-content .cursor-pointer').forEach((card) => {
        card.style.boxShadow = ''
        if (card.hasAttribute('data-vpngate-active-node')) card.removeAttribute('title')
        card.removeAttribute('data-vpngate-active-node')
        const name = card.innerText?.split('\n')?.[0]?.trim()
        if (active && name === leaf) {
          card.dataset.vpngateActiveNode = 'true'
          card.style.boxShadow = 'inset 0 0 0 2px #22c55e'
          card.title = '当前实际使用的 VPNGate 出口节点'
        }
      })
    })
  }

  const checkCompatibility = (proxies = lastProxies, apiError = '') => {
    const errors = []
    if (!controller()) errors.push('无法读取 Zashboard Controller 配置')
    if (apiError) {
      if (!apiFailureSince) apiFailureSince = Date.now()
      if (Date.now() - apiFailureSince > 15000) errors.push(`Controller 持续请求失败：${apiError}`)
    } else {
      apiFailureSince = 0
    }

    if (!proxies) {
      return saveCompatibility(errors.length ? 'failed' : 'waiting', errors, '等待 /proxies 数据')
    }

    const names = [...groups.keys()]
    const present = names.filter((name) => proxies[name])
    if (present.length === 0) {
      // VPNGate 尚未启用时两个组本来就不存在，不应误报 UI 损坏。
      return saveCompatibility('inactive', errors, 'VPNGate 策略组尚未加载')
    }
    names.filter((name) => !proxies[name]).forEach((name) =>
      errors.push(`Mihomo 缺少策略组 ${name}`))
    present.filter((name) => !isSelectorType(proxies[name]?.type)).forEach((name) =>
      errors.push(`${name} 类型不是 Selector`))
    if (!proxies[routeSelector]) errors.push(`Mihomo 缺少顶层出口选择器 ${routeSelector}`)
    if (!proxies[smartAuto]) errors.push(`Mihomo 缺少智能自动组 ${smartAuto}`)

    const onProxyPage = location.hash.includes('/proxies')
    if (onProxyPage) {
      const collapses = [...document.querySelectorAll('.collapse')]
      const domErrors = []
      names.forEach((name) => {
        const collapse = collapses.find((item) =>
          groupNameOf(item.querySelector(':scope > .collapse-title')) === name)
        if (!collapse) {
          domErrors.push(`找不到 ${name} 的 .collapse`)
          return
        }
        if (collapse && !collapse.querySelector(':scope > .collapse-title .latency-tag')) {
          domErrors.push(`${name} 标题缺少 .latency-tag`)
        }
        if (collapse && !isSelectorGroup(name, collapse.querySelector(':scope > .collapse-title'))) {
          domErrors.push(`${name} 无法识别 Selector 类型`)
        }
      })
      if (domErrors.length) {
        if (!domFailureSince) domFailureSince = Date.now()
        if (Date.now() - domFailureSince > 15000) errors.push(...domErrors)
      } else {
        domFailureSince = 0
      }
    } else {
      domFailureSince = 0
    }

    const status = errors.length ? 'failed' : (onProxyPage ? 'passed' : 'partial')
    const detail = onProxyPage ? 'Controller 与 VPNGate DOM 已检查' : 'Controller 正常；进入代理页后检查 DOM'
    return saveCompatibility(status, errors, detail)
  }

  const refreshActiveRoute = async () => {
    const api = controller()
    if (!api) {
      checkCompatibility(null)
      return
    }
    try {
      const headers = api.password ? {Authorization: `Bearer ${api.password}`} : {}
      const response = await fetch(`${api.base}/proxies`, {headers})
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      const data = await response.json()
      const proxies = data.proxies || {}
      lastProxies = proxies
      const mode = proxies[routeSelector]?.now || ''
      const activeGroup = mode === smartAuto ? (proxies[smartAuto]?.now || '') : mode
      routeState = {
        activeGroup,
        mode,
        leaves: Object.fromEntries([...groups.keys()].map((group) => [
          group,
          resolveLeaf(proxies, proxies[group]?.now),
        ])),
      }
      renderActiveRoute()
      checkCompatibility(proxies)
    } catch (error) {
      // Controller 暂时重载时保留上一次标记，下个轮询周期再更新。
      checkCompatibility(lastProxies, error?.message || String(error))
    }
  }

  document.addEventListener('click', async (event) => {
    const routeBadge = event.target.closest?.('[data-vpngate-route-badge]')
    if (routeBadge) {
      event.preventDefault()
      event.stopPropagation()
      event.stopImmediatePropagation()
      const group = routeBadge.dataset.vpngateGroup
      const active = routeState?.activeGroup === group
      const target = active ? smartAuto : group
      if (active && routeState?.mode === smartAuto) {
        toast('当前已经是智能自动模式；程序会在直连失败时切换到经前置。')
        return
      }
      try {
        await selectRoute(target)
        toast(target === smartAuto
          ? '已恢复智能自动：直连优先，失败后使用经前置。'
          : `已固定使用 ${target}。`)
        await refreshActiveRoute()
      } catch (error) {
        toast(`切换 VPNGate 出口失败：${error.message || error}`, true)
      }
      return
    }

    const tag = event.target.closest?.('.latency-tag')
    const clickedCard = event.target.closest?.('.collapse-content .cursor-pointer')
    const collapse = (tag || clickedCard)?.closest?.('.collapse')
    const title = collapse?.querySelector?.(':scope > .collapse-title')
    const group = groupNameOf(title)

    // 在备用组中点击某个节点时，Zashboard 仍负责选择节点；补丁随后把顶层
    // 出口固定到该组，避免“经前置节点选中了但实际仍走直连”的错觉。
    if (!tag && clickedCard && groups.has(group) && routeState?.activeGroup !== group) {
      setTimeout(async () => {
        try {
          await selectRoute(group)
          toast(`已选择并固定使用 ${group}。`)
          await refreshActiveRoute()
        } catch (error) {
          toast(`切换 VPNGate 出口失败：${error.message || error}`, true)
        }
      }, 250)
      return
    }
    if (!tag || !groups.has(group) || !isSelectorGroup(group, title)) return

    const card = tag.closest('.cursor-pointer')
    const node = card?.innerText?.split('\n')?.[0]?.trim()
    const isGroupTest = Boolean(tag.closest('.collapse-title'))
    const isNodeTest = Boolean(node?.startsWith('[直连] VPNGate-') ||
      node?.startsWith('[前置] VPNGate-'))
    if (!isGroupTest && !isNodeTest) return

    // 阻止 Zashboard 为全体测速同时发起约 87 个独立请求。
    event.preventDefault()
    event.stopPropagation()
    event.stopImmediatePropagation()

    if (running) {
      toast('另一组 VPNGate 全体测速正在进行，请稍候。')
      return
    }
    const api = controller()
    if (!api) {
      toast('无法读取 Zashboard 的 Mihomo 连接配置。', true)
      return
    }

    running = true
    const timeout = groups.get(group)
    const previousResult = isNodeTest ? latencyResults.get(node) : undefined
    if (isNodeTest) setLatencyResult(node, '…')
    toast(isGroupTest
      ? `${group} 全体测速中，最长等待 ${timeout / 1000} 秒…`
      : `${node} 单节点测速中，最长等待 ${timeout / 1000} 秒…`)

    const abort = new AbortController()
    const timer = setTimeout(() => abort.abort(), timeout + 5000)
    try {
      // 与 Mihomo 的 VPNGate AUTO 健康检查保持一致，避免部分公共 VPN
      // 屏蔽 Google 测速地址而产生假超时。
      const testUrl = 'https://cp.cloudflare.com'
      const params = new URLSearchParams({url: testUrl, timeout: String(timeout)})
      const headers = api.password ? {Authorization: `Bearer ${api.password}`} : {}
      const endpoint = isGroupTest
        ? `group/${encodeURIComponent(group)}`
        : `proxies/${encodeURIComponent(node)}`
      const response = await fetch(
        `${api.base}/${endpoint}/delay?${params}`,
        {headers, signal: abort.signal},
      )
      const data = await response.json().catch(() => ({}))
      if (!response.ok) throw new Error(data.message || `HTTP ${response.status}`)
      if (isGroupTest) {
        const count = Object.values(data).filter((value) => Number.isFinite(value)).length
        toast(`${group} 全体测速完成：${count} 个节点返回延迟。`)
        setTimeout(() => location.reload(), 1200)
      } else {
        const delay = Number(data.delay)
        if (!Number.isFinite(delay) || delay <= 0) throw new Error('未返回有效延迟')
        setLatencyResult(node, delay)
        toast(`${node} 单节点测速完成：${delay} ms。`)
        setTimeout(() => {
          const el = document.getElementById('vpngate-group-test-toast')
          if (el) el.hidden = true
        }, 1800)
      }
    } catch (error) {
      if (isNodeTest) restoreLatencyResult(node, previousResult)
      toast(`${isGroupTest ? group + ' 全体' : node + ' 单节点'}测速失败：${error.message || error}`, true)
    } finally {
      clearTimeout(timer)
      running = false
    }
  }, true)

  new MutationObserver(() => {
    renderActiveRoute()
    renderLatencyResults()
    checkCompatibility()
  }).observe(document.getElementById('app') || document.body, {
    childList: true,
    subtree: true,
  })
  refreshActiveRoute()
  setTimeout(() => checkCompatibility(), 16000)
  setInterval(refreshActiveRoute, 3000)
})()
JS

    script_hash=$(sha256sum "$script" | awk '{print substr($1,1,12)}')
    tag="<script id=\"vpngate-disable-single-test\" src=\"./vpngate-ui.js?v=${script_hash}\"></script>"
    if grep -q 'id="vpngate-disable-single-test"' "$index"; then
        sed -E -i "s#<script id=\"vpngate-disable-single-test\"[^>]*></script>#${tag}#" "$index"
    else
        sed -i "\#</body>#i\\    ${tag}" "$index"
    fi

    # Zashboard 使用 Workbox 预缓存 index.html；同步 revision 才能让浏览器获得
    # 修改后的入口文件，而不是继续显示旧缓存。
    if [ -s "$worker" ]; then
        index_hash=$(md5sum "$index" | awk '{print $1}')
        sed -E -i "s#(url:\"index\\.html\",revision:\")[^\"]*#\\1${index_hash}#" "$worker"
    fi

    _vpngate_ui_static_check >/dev/null ||
        _errorcat "Zashboard VPNGate 补丁写入后静态自检失败，请执行 clashctl vpngate ui-check"
}

_vpngate_ui_static_check() {
    local ui_dir="${CLASH_RESOURCES_DIR}/dist"
    local index="${ui_dir}/index.html" worker="${ui_dir}/sw.js" script="${ui_dir}/vpngate-ui.js"
    local expected actual revision expected_revision

    [ -s "$index" ] && [ -s "$script" ] || return 1
    grep -q 'id="vpngate-disable-single-test"' "$index" || return 1
    grep -q "const patchVersion = '2026.09.04.1'" "$script" || return 1
    grep -q "checkStorageKey = 'clashctl/vpngate-ui-check'" "$script" || return 1
    grep -q "querySelectorAll('.collapse')" "$script" || return 1
    grep -q "'.latency-tag'" "$script" || return 1
    grep -q 'const isSelectorGroup' "$script" || return 1
    grep -q 'data-vpngate-delay' "$script" || return 1

    expected=$(sha256sum "$script" | awk '{print substr($1,1,12)}')
    actual=$(grep -oE 'vpngate-ui\.js\?v=[0-9a-f]+' "$index" | head -1 | cut -d= -f2)
    [ -n "$actual" ] && [ "$actual" = "$expected" ] || return 1

    if [ -s "$worker" ] && grep -q 'url:"index.html",revision:"' "$worker"; then
        expected_revision=$(md5sum "$index" | awk '{print $1}')
        revision=$(grep -oE 'url:"index\.html",revision:"[^"]+' "$worker" | head -1 |
            sed -E 's/.*revision:"//')
        [ "$revision" = "$expected_revision" ] || return 1
    fi
}

_vpngate_ui_check() {
    local ui_dir="${CLASH_RESOURCES_DIR}/dist" script="${ui_dir}/vpngate-ui.js"
    local failed=0 warned=0 runtime='未检查（Mihomo 未运行）'

    printf 'Zashboard VPNGate 补丁兼容性自检\n'
    if _vpngate_ui_static_check; then
        printf '  [OK] 静态注入、脚本版本、缓存 revision 一致\n'
    else
        printf '  [FAIL] 静态补丁不完整或缓存 revision 不一致\n'
        failed=$((failed + 1))
    fi

    if [ -s "$script" ]; then
        printf '  [OK] 浏览器运行时自检已内置（版本 2026.09.04.1）\n'
        printf '       结果键：localStorage["clashctl/vpngate-ui-check"]\n'
    fi

    if service_is_active >/dev/null 2>&1; then
        if _node_group_json "$VPNGATE_GROUP_DIRECT" >/dev/null 2>&1 &&
            _node_group_json "$VPNGATE_GROUP_FRONT" >/dev/null 2>&1 &&
            _node_group_json "$VPNGATE_GROUP_AUTO" >/dev/null 2>&1 &&
            _node_group_json "$VPNGATE_GROUP_SMART_AUTO" >/dev/null 2>&1; then
            runtime='可见策略组、顶层选择器和智能自动组均可从 Controller 读取'
            printf '  [OK] %s\n' "$runtime"
        elif [ "$(_vpngate_state_get enabled)" = true ]; then
            printf '  [FAIL] VPNGate 已启用，但 Controller 中缺少可见策略组\n'
            failed=$((failed + 1))
        else
            printf '  [WARN] VPNGate 未启用，暂不检查 Controller 策略组\n'
            warned=$((warned + 1))
        fi
    else
        printf '  [WARN] %s\n' "$runtime"
        warned=$((warned + 1))
    fi

    printf '检查结果：FAIL=%d WARN=%d\n' "$failed" "$warned"
    [ "$failed" -eq 0 ]
}
