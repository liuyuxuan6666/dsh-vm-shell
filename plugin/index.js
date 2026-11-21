// dsh-vm-shell - drive an ELEVATED PowerShell inside a Hyper-V guest.
//
// The plugin is a client for the localhost agent installed by
// agent/Install-VmAgent.ps1. The agent runs as SYSTEM, so it can talk to
// PowerShell Direct over VMBus; this plugin runs as your normal user and never
// needs elevation itself.
//
// The point is not screen automation. The screen tools exist only to bootstrap
// (answer a UAC dialog, log in), because the guest's UAC prompt cannot be
// answered from inside the guest by a normal-integrity process.

import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import fs from 'node:fs'
import crypto from 'node:crypto'

export const name = 'dsh-vm-shell'
export const inject = ['tools']

const DEFAULT_PORT = 17801
const DEFAULT_SECRET_PATH = path.join(
  process.env.ProgramData ?? 'C:\\ProgramData',
  'DshVmShell',
  'secret.txt',
)

function resolveConfig(settings = {}) {
  return {
    port: Number(settings.port) > 0 ? Number(settings.port) : DEFAULT_PORT,
    // The HMAC key is normally read from the file the installer created. It can
    // also be supplied inline (hex) for a profile that manages its own secret.
    secretPath: typeof settings.secretPath === 'string' && settings.secretPath
      ? settings.secretPath
      : DEFAULT_SECRET_PATH,
    secret: typeof settings.secret === 'string' ? settings.secret.trim() : '',
    timeoutMs: Number(settings.timeoutMs) > 0 ? Number(settings.timeoutMs) : 150000,
  }
}

function readSecret(cfg) {
  const hex = cfg.secret || (() => {
    try {
      return fs.readFileSync(cfg.secretPath, 'utf8').trim()
    } catch {
      return ''
    }
  })()
  if (!hex) {
    throw new Error(
      `dsh-vm-shell: no signing secret at ${cfg.secretPath}. ` +
      `Run agent/Install-VmAgent.ps1 in an elevated PowerShell first.`,
    )
  }
  if (!/^[0-9a-fA-F]+$/.test(hex) || hex.length % 2 !== 0) {
    throw new Error(`dsh-vm-shell: signing secret at ${cfg.secretPath} is not valid hex`)
  }
  return Buffer.from(hex, 'hex')
}

/** One signed request/response line against the agent. */
function request(cfg, body) {
  const key = readSecret(cfg)
  const ts = Math.floor(Date.now() / 1000)
  const nonce = crypto.randomBytes(16).toString('hex')
  const b = Buffer.from(JSON.stringify(body), 'utf8').toString('base64')
  const sig = crypto.createHmac('sha256', key).update(`${ts}.${nonce}.${b}`).digest('hex')
  const line = JSON.stringify({ v: 1, ts, nonce, b, sig })
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host: '127.0.0.1', port: cfg.port })
    let buffer = ''
    let settled = false
    const done = (fn, value) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      socket.destroy()
      fn(value)
    }
    const timer = setTimeout(
      () => done(reject, new Error(`dsh-vm-shell: agent timed out after ${cfg.timeoutMs} ms`)),
      cfg.timeoutMs,
    )
    socket.setEncoding('utf8')
    socket.on('connect', () => socket.write(line + '\n'))
    socket.on('data', (chunk) => {
      buffer += chunk
      const nl = buffer.indexOf('\n')
      if (nl === -1) return
      // PowerShell's StreamWriter may prefix the first line with a UTF-8 BOM.
      const text = buffer.slice(0, nl).replace(/^\uFEFF/, '')
      try {
        done(resolve, JSON.parse(text))
      } catch (error) {
        done(reject, new Error(`dsh-vm-shell: bad reply from agent: ${text.slice(0, 200)}`))
      }
    })
    socket.on('error', (error) => {
      if (error.code === 'ECONNREFUSED') {
        done(reject, new Error(
          `dsh-vm-shell: agent not listening on 127.0.0.1:${cfg.port}. ` +
          `Check the "DshVmShell" scheduled task, or run agent/Install-VmAgent.ps1.`,
        ))
      } else {
        done(reject, new Error(`dsh-vm-shell: ${error.message}`))
      }
    })
  })
}

function expectOk(reply) {
  if (!reply || reply.ok !== true) {
    throw new Error(`dsh-vm-shell: agent refused: ${reply?.error ?? 'unknown error'}`)
  }
  return reply
}

const textBlock = (text) => [{ type: 'text', text }]

export function apply(ctx, settings = {}) {
  const cfg = resolveConfig(settings)
  const call = (payload) => request(cfg, payload)

  // ---------------------------------------------------------------- vm_ps
  ctx.tools.register({
    name: 'vm_ps',
    description:
      'Run a PowerShell script INSIDE the Hyper-V guest, elevated, and return its output. ' +
      'This is the main way to work on the guest: it uses PowerShell Direct over VMBus ' +
      '(no WinRM listener, no RDP, no network needed) with the saved guest admin account. ' +
      'The script runs as one block in the guest; text output is returned as a single string.',
    parameters: {
      type: 'object',
      properties: {
        script: {
          type: 'string',
          description: 'PowerShell source to run in the guest. Multiple statements are fine.',
        },
        timeoutSec: {
          type: 'number',
          description: 'How long the guest may take, in seconds. Default 120.',
        },
        bootWaitSec: {
          type: 'number',
          description:
            'If the VM is off, start it and wait up to this many seconds for the guest to answer. ' +
            'Default 180, which covers a cold boot.',
        },
      },
      required: ['script'],
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          output: { type: 'string' },
          errors: { type: 'string' },
          elevated: { type: 'boolean' },
          user: { type: 'string' },
          host: { type: 'string' },
          ps: { type: 'string' },
        },
        required: ['output'],
      },
      render: (_args, value) => textBlock(
        [
          `host=${value.host} user=${value.user} elevated=${value.elevated} ps=${value.ps}`,
          '--- output ---',
          value.output?.trimEnd() || '(empty)',
          value.errors ? `--- errors ---\n${value.errors}` : '',
        ].filter(Boolean).join('\n'),
      ),
    },
    async execute(args) {
      if (typeof args.script !== 'string' || args.script.trim() === '') {
        throw new Error('vm_ps: script must be a non-empty string')
      }
      const b64 = Buffer.from(args.script, 'utf8').toString('base64')
      const reply = expectOk(await call({
        op: 'ps',
        script: b64,
        timeout: args.timeoutSec ?? 120,
        bootWaitSec: args.bootWaitSec ?? 180,
      }))
      return {
        output: reply.output ?? '',
        errors: reply.errors ?? '',
        elevated: reply.elevated === true,
        user: reply.user ?? '',
        host: reply.host ?? '',
        ps: reply.ps ?? '',
      }
    },
  })

  // ------------------------------------------------------------ vm_status
  ctx.tools.register({
    name: 'vm_status',
    description:
      'Report whether the VmAgent is reachable, which VM it controls, the guest user, ' +
      'and the current PowerShell Direct session state.',
    parameters: { type: 'object', properties: {} },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          agent: { type: 'string' },
          vm: { type: 'string' },
          state: { type: 'number' },
          running: { type: 'boolean' },
          autoStart: { type: 'boolean' },
          guest: { type: 'string' },
          session: { type: 'string' },
        },
        required: ['agent'],
      },
      render: (_args, value) => textBlock(
        `agent=${value.agent} vm=${value.vm} state=${value.state} running=${value.running} ` +
        `autoStart=${value.autoStart} guest=${value.guest} session=${value.session}`,
      ),
    },
    async execute() {
      const reply = expectOk(await call({ op: 'info' }))
      return {
        agent: 'up',
        vm: reply.vm ?? '',
        state: typeof reply.state === 'number' ? reply.state : 0,
        running: reply.running === true,
        autoStart: reply.autoStart === true,
        guest: reply.guest ?? '',
        session: reply.session ?? 'none',
      }
    },
  })

  // ------------------------------------------------------------- vm_power
  ctx.tools.register({
    name: 'vm_power',
    description:
      'Read or change the Hyper-V power state: state, start, stop, reset. ' +
      'start waits for the guest to reach Running and is the tool to use when the VM did not ' +
      'come up after a host reboot; vm_ps also starts it on demand.',
    parameters: {
      type: 'object',
      properties: {
        action: {
          type: 'string',
          enum: ['state', 'start', 'stop', 'reset'],
          description: 'Default state.',
        },
      },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          action: { type: 'string' },
          state: { type: 'number' },
          running: { type: 'boolean' },
        },
        required: ['action'],
      },
      render: (_args, value) => textBlock(`${value.action}: state=${value.state} running=${value.running}`),
    },
    async execute(args) {
      const action = ['state', 'start', 'stop', 'reset'].includes(args.action) ? args.action : 'state'
      const reply = await call({ op: 'power', action })
      if (reply?.ok !== true) throw new Error(`vm_power: ${reply?.error ?? 'agent error'}`)
      return {
        action,
        state: typeof reply.state === 'number' ? reply.state : 0,
        running: reply.running === true || reply.started === true,
      }
    },
  })

  // --------------------------------------------------------------- vm_key
  ctx.tools.register({
    name: 'vm_key',
    description:
      'Send one virtual-key press to the guest through the hypervisor. Use it to bootstrap ' +
      '(open Start, accept a dialog) when the guest cannot be reached by script yet. ' +
      'It reaches the secure desktop, so it works on a UAC prompt.',
    parameters: {
      type: 'object',
      properties: {
        vk: {
          type: 'number',
          description: 'Windows virtual-key code, e.g. 13 Enter, 91 Left Windows, 27 Esc, 65 A.',
        },
        action: {
          type: 'string',
          enum: ['press', 'down', 'up'],
          description: 'Default press (down then up). Use down/up to build a chord such as Ctrl+Alt+Del.',
        },
      },
      required: ['vk'],
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: { ok: { type: 'boolean' } },
        required: ['ok'],
      },
      render: (_args, value) => textBlock(value.ok ? 'sent' : 'not sent'),
    },
    async execute(args) {
      if (!Number.isInteger(args.vk) || args.vk <= 0 || args.vk > 255) {
        throw new Error('vm_key: vk must be an integer between 1 and 255')
      }
      const op = args.action === 'down' ? 'keydown' : args.action === 'up' ? 'keyup' : 'key'
      const reply = await call({ op, vk: args.vk })
      return { ok: reply?.ok === true }
    },
  })

  // -------------------------------------------------------------- vm_type
  ctx.tools.register({
    name: 'vm_type',
    description:
      'Type ASCII text into the guest through the hypervisor keyboard. For bootstrapping only: ' +
      'the hypervisor keyboard has no IME, so non-ASCII text cannot be sent this way. ' +
      'Prefer vm_ps once the guest is reachable.',
    parameters: {
      type: 'object',
      properties: {
        text: { type: 'string', description: 'ASCII text to type.' },
      },
      required: ['text'],
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: { ok: { type: 'boolean' }, typed: { type: 'number' } },
        required: ['ok'],
      },
      render: (_args, value) => textBlock(value.ok ? `typed ${value.typed} chars` : 'not typed'),
    },
    async execute(args) {
      if (typeof args.text !== 'string' || args.text === '') {
        throw new Error('vm_type: text must be a non-empty string')
      }
      if (/[^\x20-\x7E\r\n\t]/.test(args.text)) {
        throw new Error('vm_type: only ASCII can be sent through the hypervisor keyboard; use vm_ps for anything else')
      }
      const reply = await call({ op: 'text', text: args.text })
      return { ok: reply?.ok === true, typed: args.text.length }
    },
  })

  // ----------------------------------------------------------- vm_uac_yes
  ctx.tools.register({
    name: 'vm_uac_yes',
    description:
      'Answer the guest UAC consent dialog with Yes (Alt+Y). Use when vm_ps reports that the ' +
      'guest is not reachable and a consent prompt is pending.',
    parameters: { type: 'object', properties: {} },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: { ok: { type: 'boolean' } },
        required: ['ok'],
      },
      render: (_args, value) => textBlock(value.ok ? 'accepted' : 'not sent'),
    },
    async execute() {
      const reply = await call({ op: 'uac-yes' })
      return { ok: reply?.ok === true }
    },
  })

  // -------------------------------------------------------- vm_screenshot
  ctx.tools.register({
    name: 'vm_screenshot',
    description:
      'Save a downscaled picture of the guest screen (Hyper-V thumbnail) to a local file and ' +
      'return its path. Low resolution and colours are approximate: use it to see whether a ' +
      'dialog or login screen is waiting, not to read dense UI.',
    parameters: {
      type: 'object',
      properties: {
        width: { type: 'number', description: 'Image width, default 1024 (the Hyper-V maximum).' },
        height: { type: 'number', description: 'Image height, default 640.' },
      },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: { path: { type: 'string' }, width: { type: 'number' }, height: { type: 'number' } },
        required: ['path'],
      },
      render: (_args, value) => textBlock(`${value.width}x${value.height} -> ${value.path}`),
    },
    async execute(args) {
      const width = Number.isInteger(args.width) && args.width > 0 ? Math.min(args.width, 1024) : 1024
      const height = Number.isInteger(args.height) && args.height > 0 ? Math.min(args.height, 1024) : 640
      const reply = expectOk(await call({ op: 'screen', w: width, h: height, fmt: 'bgr565' }))
      const file = path.join(os.tmpdir(), `dsh-vm-shell-${Date.now()}.png`)
      fs.writeFileSync(file, Buffer.from(reply.png, 'base64'))
      return { path: file, width, height }
    },
  })
}
