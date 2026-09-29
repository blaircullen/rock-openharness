import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import type { ExternalTmuxOwnership } from './agentOwnership.js'

let dataDir = ''

const external = (paneId = '%21', serverIdentity = '4242:1759000000'): ExternalTmuxOwnership => ({
  kind: 'external', backend: 'tmux', socketPath: '/private/tmp/tmux-501/default', serverIdentity, paneId,
})

const registryFile = () => join(dataDir, 'registry.json')
const readRegistry = () => JSON.parse(readFileSync(registryFile(), 'utf8')) as Array<Record<string, unknown>>

async function loadRegistryModule() {
  vi.resetModules()
  process.env.ADAPTER_DATA_DIR = dataDir
  process.env.CLAUDE_PROJECTS_DIR = dataDir
  process.env.CODEX_HOME = dataDir
  process.env.CURSOR_HOME = dataDir
  return import('./registry.js')
}

describe('registry: enrolling and unenrolling a borrowed tmux pane', () => {
  beforeEach(() => {
    dataDir = mkdtempSync(join(tmpdir(), 'adapter-registry-enroll-'))
    writeFileSync(registryFile(), '[]', { mode: 0o600 })
  })

  afterEach(() => {
    rmSync(dataDir, { recursive: true, force: true })
    delete process.env.ADAPTER_DATA_DIR
    delete process.env.CLAUDE_PROJECTS_DIR
    delete process.env.CODEX_HOME
    delete process.env.CURSOR_HOME
  })

  it('writes an external v3 terminal row that survives a reload and holds no managed route', async () => {
    const { registry } = await loadRegistryModule()
    registry.load()
    const row = registry.enrollExternal({ ownership: external(), cwd: '/Users/me/work', name: 'work:0.0' })
    expect(row).toMatchObject({ engine: 'terminal', tmuxPane: '%21', ownership: external(), defaultName: 'work:0.0', active: true })
    expect(readRegistry()).toEqual([expect.objectContaining({ schemaVersion: 3, agentId: row!.agentId, ownership: external() })])
    // Quarantined: no route, not advertised as a managed terminal, not resolvable by pane.
    expect(registry.byPaneEngine('%21', 'terminal')).toBeUndefined()
    expect(registry.advertised()).toEqual([])
    expect(registry.externalRows().map((entry) => entry.agentId)).toEqual([row!.agentId])

    const { registry: reloaded } = await loadRegistryModule()
    reloaded.load()
    expect(reloaded.byAgent(row!.agentId)).toMatchObject({ ownership: external(), tmuxPane: '%21' })
  })

  it('refuses a pane a managed row holds, and a second claim on the same enrollment', async () => {
    const { registry } = await loadRegistryModule()
    registry.load()
    const managed = registry.openPendingAgent({ engine: 'terminal', runtimes: [{ backend: 'tmux', paneId: '%30' }], cwd: '/tmp' })
    expect(managed).not.toBeNull()
    expect(registry.enrollExternal({ ownership: external('%30'), cwd: null, name: 'x' })).toBeNull()
    expect(registry.enrollExternal({ ownership: external('%21'), cwd: null, name: 'x' })).not.toBeNull()
    expect(registry.enrollExternal({ ownership: external('%21'), cwd: null, name: 'y' })).toBeNull()
    // The same pane id on a restarted server is a different enrollment.
    expect(registry.enrollExternal({ ownership: external('%21', '9999:1800000000'), cwd: null, name: 'z' })).not.toBeNull()
  })

  it('a stale enrollment never blocks a managed pane that reuses its id', async () => {
    const { registry } = await loadRegistryModule()
    registry.load()
    const borrowed = registry.enrollExternal({ ownership: external('%5'), cwd: null, name: 'old' })
    const managed = registry.openPendingAgent({ engine: 'terminal', runtimes: [{ backend: 'tmux', paneId: '%5' }], cwd: '/tmp' })
    expect(borrowed).not.toBeNull()
    expect(managed).not.toBeNull()
    expect(registry.byPaneEngine('%5', 'terminal')?.agentId).toBe(managed!.agentId)
  })

  it('unenrolls only an external row, leaving managed rows and the file consistent', async () => {
    const { registry } = await loadRegistryModule()
    registry.load()
    const managed = registry.openPendingAgent({ engine: 'terminal', runtimes: [{ backend: 'tmux', paneId: '%30' }], cwd: '/tmp' })!
    const borrowed = registry.enrollExternal({ ownership: external(), cwd: null, name: 'work' })!
    expect(registry.unenrollExternal(managed.agentId)).toBe(false)
    expect(registry.byAgent(managed.agentId)).toBeDefined()
    expect(registry.unenrollExternal(borrowed.agentId)).toBe(true)
    expect(registry.byAgent(borrowed.agentId)).toBeUndefined()
    expect(readRegistry().map((entry) => entry.agentId)).toEqual([managed.agentId])

    const { registry: reloaded } = await loadRegistryModule()
    reloaded.load()
    expect(reloaded.externalRows()).toEqual([])
    expect(reloaded.byAgent(managed.agentId)).toBeDefined()
  })
})
