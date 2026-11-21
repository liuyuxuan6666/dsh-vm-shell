// test/harness.mjs - exercise the plugin's tool implementations without DSH.
//
//   node test/harness.mjs ["some guest powershell"]
//
// It builds a fake Cordis context that only implements tools.register, so the
// same code paths DSH would call are executed here.

import { apply } from '../plugin/index.js'

const tools = new Map()
const ctx = {
  tools: {
    register(definition) {
      tools.set(definition.name, definition)
      return () => tools.delete(definition.name)
    },
  },
}

apply(ctx)

if (tools.size === 0) {
  console.error('no tools registered')
  process.exit(1)
}

const call = async (name, args = {}) => {
  const tool = tools.get(name)
  if (!tool) throw new Error(`no tool ${name}`)
  const value = await tool.execute(args, {})
  // Every tool must satisfy its own declared output schema keys.
  for (const key of tool.output.schema.required ?? []) {
    if (value[key] === undefined) throw new Error(`${name}: result missing required '${key}'`)
  }
  const blocks = tool.output.render(args, value)
  return { value, text: blocks.map((b) => b.text).join('\n') }
}

const script = process.argv[2] ?? 'whoami; (Get-CimInstance Win32_OperatingSystem).Caption'

const status = await call('vm_status')
console.log('--- vm_status ---')
console.log(status.text)

console.log('--- vm_ps ---')
const ps = await call('vm_ps', { script })
console.log(ps.text)

console.log('--- vm_ps (elevation check) ---')
const elev = await call('vm_ps', {
  script: '([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)',
})
console.log(elev.text)

console.log('\nOK: tools =', [...tools.keys()].join(', '))
