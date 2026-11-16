/**
 * 截图提问 · 宿主半边
 *
 * 两条 webServer 精确路由，把「屏幕」变成页面能用的 PNG：
 *   POST /api/screenshot-ask/capture-region   圈选（隐藏 DSH → 静帧 → 拖框/微调 → 裁切）
 *   POST /api/screenshot-ask/capture          整屏（调试用，不弹覆盖层）
 *
 * 为什么走 webServer 路由：CommandResult 只有 {kind, text}，塞不下二进制；页面同源 fetch
 * 自带鉴权。为什么是常驻子进程：每次 execFile 一个新 PowerShell 要 2.4 s（.NET/WPF 冷启动），
 * 常驻后同样的事 ~0.3 s。
 *
 * 协议：stdin/stdout 各一行 JSON，靠 id 配对（见 lib/server.ps1 头部注释）。
 */

import { appendFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { spawn } from 'node:child_process'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

export const name = 'screenshot-ask'

// 全部走可选注入：服务缺失时静默降级，不拖垮整个 profile
export const inject = []

const LOG_FILE = join(tmpdir(), 'dsh-plugin-screenshot-ask.log')
const PLUGIN_DIR = dirname(fileURLToPath(import.meta.url))
const SERVER_SCRIPT = join(PLUGIN_DIR, 'lib', 'server.ps1')
const CAPTURE_ROUTE = '/api/screenshot-ask/capture'
const REGION_ROUTE = '/api/screenshot-ask/capture-region'
const CAPTURE_TIMEOUT_MS = 20000
// 圈选要等人拖框，超时只是兜底
const REGION_TIMEOUT_MS = 300000

// 同一时刻只允许一个圈选（覆盖层是全屏置顶窗，叠两个会抢输入）
let regionBusy = false

// ---------------------------------------------------------------- 常驻子进程

let child = null
let booting = null
let nextId = 1
const pending = new Map()
let stdoutBuffer = ''

function beat(line) {
  try {
    appendFileSync(LOG_FILE, `${new Date().toISOString()} ${line}\n`, 'utf8')
  } catch {
    // 心跳写不进去不影响功能
  }
}

function settleLine(line) {
  let payload
  try {
    payload = JSON.parse(line)
  } catch {
    beat(`server garbage: ${line.slice(0, 200)}`)
    return
  }
  const entry = pending.get(payload.id)
  if (!entry) {
    beat(`server orphan reply: ${line.slice(0, 120)}`)
    return
  }
  pending.delete(payload.id)
  clearTimeout(entry.timer)
  entry.resolve(payload)
}

function failAll(message) {
  for (const [id, entry] of pending) {
    pending.delete(id)
    clearTimeout(entry.timer)
    entry.reject(new Error(message))
  }
}

function stopServer(proc) {
  if (child !== proc) return
  child = null
  if (booting) {
    const { reject } = booting
    booting = null
    reject?.(new Error('截图进程已退出'))
  }
  failAll('截图进程已退出')
}

function attach(proc) {
  proc.stdout.setEncoding('utf8')
  proc.stdout.on('data', (chunk) => {
    stdoutBuffer += chunk
    let index
    while ((index = stdoutBuffer.indexOf('\n')) >= 0) {
      const line = stdoutBuffer.slice(0, index).trim()
      stdoutBuffer = stdoutBuffer.slice(index + 1)
      if (line) settleLine(line)
    }
  })
  proc.stderr.setEncoding('utf8')
  proc.stderr.on('data', (chunk) => beat(`server stderr: ${String(chunk).trim().slice(0, 400)}`))
  proc.on('error', (error) => {
    beat(`server spawn error: ${error.message}`)
    stopServer(proc)
  })
  proc.on('exit', (code) => {
    beat(`server exit: ${code}`)
    stopServer(proc)
  })
}

/** 起一个常驻 PowerShell 并以 ping 确认它已经预热完（WPF 已装载）。 */
function ensureServer() {
  if (child && child.exitCode === null && !child.killed) return Promise.resolve()
  if (booting) return booting.promise

  const deferred = {}
  deferred.promise = new Promise((resolve, reject) => {
    deferred.resolve = resolve
    deferred.reject = reject
  })
  booting = deferred

  const proc = spawn(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', SERVER_SCRIPT, '-LogFile', LOG_FILE],
    { windowsHide: true, detached: false, stdio: ['pipe', 'pipe', 'pipe'] },
  )
  child = proc
  stdoutBuffer = ''
  attach(proc)

  const pingId = nextId++
  const timer = setTimeout(() => {
    pending.delete(pingId)
    if (booting === deferred) booting = null
    deferred.reject(new Error('截图进程启动超时'))
  }, 30000)
  pending.set(pingId, {
    resolve: (payload) => {
      beat(`server warm (pid ${payload.pid})`)
      if (booting === deferred) booting = null
      deferred.resolve()
    },
    reject: (error) => {
      if (booting === deferred) booting = null
      deferred.reject(error)
    },
    timer,
  })
  try {
    proc.stdin.write(`${JSON.stringify({ id: pingId, op: 'ping' })}\n`)
  } catch (error) {
    clearTimeout(timer)
    pending.delete(pingId)
    if (booting === deferred) booting = null
    deferred.reject(error)
  }

  return deferred.promise
}

async function request(payload, timeoutMs) {
  await ensureServer()
  const proc = child
  if (!proc) throw new Error('截图进程不可用')
  const id = nextId++
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id)
      reject(new Error('截图进程无响应'))
    }, timeoutMs)
    pending.set(id, { resolve, reject, timer })
    try {
      proc.stdin.write(`${JSON.stringify({ ...payload, id })}\n`)
    } catch (error) {
      pending.delete(id)
      clearTimeout(timer)
      reject(error)
    }
  })
}

function shutdownServer() {
  const proc = child
  child = null
  failAll('截图进程已关闭')
  if (!proc) return
  try {
    proc.stdin.end()
  } catch {
    // 已经断了就不用管
  }
  setTimeout(() => {
    try {
      if (proc.exitCode === null) proc.kill()
    } catch {
      // ignore
    }
  }, 300).unref?.()
}

// ---------------------------------------------------------------- HTTP

function writeJson(res, status, body) {
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'referrer-policy': 'no-referrer',
  })
  res.end(JSON.stringify(body))
}

/**
 * webServer.register 拿到的就是原生 req/res，DSH 的 Host/Origin 准入不会自动套上来
 * （dsh-host-webserver 的 register 只是把路由塞进路由表）。所以每条路由入口都显式
 * 调一次 connection.requestRejection —— 它做的正是 DSH 对自家 /api 路由做的那套检查
 * （Host/Origin 校验 + 浏览器凭证），返回 401/403 就必须拒。
 *
 * 拿不到 connection 服务时退回「只认同源」的本地检查，并且拒绝没有 Origin 的请求；
 * 宁可少放行，也不给本机脚本留后门。
 */
let connectionRef

function sameOriginOnly(req, res) {
  const origin = req.headers.origin
  if (typeof origin !== 'string' || origin.length === 0) {
    writeJson(res, 403, { ok: false, code: 'untrusted', message: '请求缺少 Origin，已被拒绝' })
    return false
  }
  let hostname = ''
  try {
    hostname = new URL(origin).hostname
  } catch {
    hostname = ''
  }
  if (hostname !== '127.0.0.1' && hostname !== 'localhost' && hostname !== '::1') {
    writeJson(res, 403, { ok: false, code: 'origin', message: '来源不被允许' })
    return false
  }
  return true
}

function guard(req, res) {
  if (req.method !== 'POST') {
    writeJson(res, 405, { ok: false, code: 'method', message: '只接受 POST' })
    return false
  }
  if (connectionRef === undefined || typeof connectionRef.requestRejection !== 'function') {
    beat('guard: connection 服务不可用，退回同源检查')
    return sameOriginOnly(req, res)
  }
  let rejection
  try {
    rejection = connectionRef.requestRejection({ headers: req.headers })
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    beat(`guard: requestRejection 抛错（${message}），拒绝请求`)
    writeJson(res, 403, { ok: false, code: 'untrusted', message: '请求未通过 DSH 的准入检查' })
    return false
  }
  if (rejection === 401 || rejection === 403) {
    beat(`guard: 请求被 DSH 拒绝（${rejection}）`)
    writeJson(res, rejection, { ok: false, code: 'untrusted', message: '请求未通过 DSH 的准入检查' })
    return false
  }
  return true
}

function makeShotName(prefix) {
  const now = new Date()
  const pad = (value) => String(value).padStart(2, '0')
  const stamp = `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`
  return `screenshot-${prefix}-${stamp}.png`
}

function describeFailure(payload) {
  if (payload.error) return payload.error
  if (payload.code) return payload.message ?? payload.code
  return '未知错误'
}

async function handleRegion(req, res) {
  if (!guard(req, res)) return
  if (regionBusy) {
    writeJson(res, 409, { ok: false, code: 'busy', message: '上一次截图还没结束' })
    return
  }
  regionBusy = true
  const started = Date.now()
  try {
    const payload = await request({ op: 'region' }, REGION_TIMEOUT_MS)
    if (payload.ok) {
      const bytes = Math.round((payload.png.length * 3) / 4)
      beat(`region: ${payload.width}x${payload.height}, ${bytes}B, ${Date.now() - started}ms (script ${payload.ms}ms)`)
      writeJson(res, 200, {
        ok: true,
        dataUrl: `data:image/png;base64,${payload.png}`,
        width: payload.width,
        height: payload.height,
        bytes,
        name: makeShotName('region'),
      })
      return
    }
    if (payload.copied) {
      beat(`region: 已复制到剪贴板（${Date.now() - started}ms）`)
      writeJson(res, 200, { ok: false, copied: true, message: '已复制到剪贴板，没有放进输入框' })
      return
    }
    if (payload.cancelled) {
      beat(`region: 用户取消（${Date.now() - started}ms）`)
      writeJson(res, 200, { ok: false, cancelled: true })
      return
    }
    const message = describeFailure(payload)
    beat(`region-failed: ${message}`)
    writeJson(res, 500, { ok: false, code: 'error', message })
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    beat(`region-failed: ${message}`)
    writeJson(res, 500, { ok: false, code: 'error', message })
  } finally {
    regionBusy = false
  }
}

async function handleCapture(req, res) {
  if (!guard(req, res)) return
  const started = Date.now()
  try {
    const payload = await request({ op: 'full' }, CAPTURE_TIMEOUT_MS)
    if (!payload.ok) {
      const message = describeFailure(payload)
      beat(`capture-failed: ${message}`)
      writeJson(res, 500, { ok: false, code: 'error', message })
      return
    }
    const bytes = Math.round((payload.png.length * 3) / 4)
    beat(`capture: ${payload.width}x${payload.height}, ${bytes}B, ${Date.now() - started}ms`)
    writeJson(res, 200, {
      ok: true,
      dataUrl: `data:image/png;base64,${payload.png}`,
      width: payload.width,
      height: payload.height,
      bytes,
      name: makeShotName('full'),
    })
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    beat(`capture-failed: ${message}`)
    writeJson(res, 500, { ok: false, code: 'error', message })
  }
}

// ---------------------------------------------------------------- plugin

export function apply(ctx) {
  // connection 服务用来给自家路由补上 DSH 的准入检查；它缺失时 guard() 会退回同源检查，
  // 所以这里不把它做成硬依赖，避免老版本 DSH 上整条链路挂掉。
  connectionRef = ctx.get('connection')
  if (connectionRef === undefined || typeof connectionRef.requestRejection !== 'function') {
    beat('apply: 没有可用的 connection.requestRejection，路由将退回同源检查')
  }

  ctx.inject(['webServer'], (sctx) => {
    sctx.effect(() => {
      const disposeCapture = sctx.webServer.register({ kind: 'exact', path: CAPTURE_ROUTE, handler: handleCapture })
      const disposeRegion = sctx.webServer.register({ kind: 'exact', path: REGION_ROUTE, handler: handleRegion })
      beat(`route: ${CAPTURE_ROUTE} / ${REGION_ROUTE} 已注册`)
      return () => {
        disposeCapture()
        disposeRegion()
        shutdownServer()
      }
    }, 'screenshot-ask: capture bridge')
  })

  // Warm the capture process in the background so the first click is not the one that pays
  // for PowerShell startup + WPF assembly load. Ping only: no screen is read here.
  void ensureServer().catch((error) => {
    beat(`prewarm failed: ${error && error.message ? error.message : String(error)}`)
  })

  beat('apply: 路由已挂载，命令行由 client 半边提供')
}
