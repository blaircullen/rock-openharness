import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import {
  externalOnlyTmuxPanes, isExternallyOwned, managedTmuxPaneEngines, ownershipFitsRow, persistedSchemaVersion, sameOwnership, validOwnership,
  type ExternalTmuxOwnership,
} from './agentOwnership.js'

let dataDir = ''

const external = (paneId = '%21', serverIdentity = 'pid:4242@1759000000'): ExternalTmuxOwnership => ({
  kind: 'external', backend: 'tmux', socketPath: '/private/tmp/tmux-501/default', serverIdentity, paneId,
})

/** A persisted terminal row, as a future enrollment would write it: v3 because it is external. */
function terminalRow(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  const paneId = (overrides.tmuxPane as string | undefined) ?? '%21'
  return {
    schemaVersion: 3, active: true, launch: { state: 'ready' }, agentId: 'borrowed-1', sessionId: '', boundAt: null,
    engine: 'terminal', terminalHost: true, transcriptPath: null, projectDir: 'work', cwd: '/tmp/work',
    runtimes: [{ backend: 'tmux', paneId }], primaryRuntimeKey: `tmux\u0000${paneId}`, tmuxPane: paneId,
    source: null, title: null, model: null, cliVersion: null, processIdentity: null,
    registeredAt: 1, touchedAt: 1, lastHookAt: 1, lastTranscriptAt: 1,
    ownership: external(paneId),
    ...overrides,
  }
}

/** A persisted managed v2 row: no ownership field at all. */
function managedRow(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  const { ownership: _none, ...row } = terminalRow({ schemaVersion: 2, agentId: 'managed-1', ...overrides })
  return row
}

const registryFile = () => join(dataDir, 'registry.json')

function writeRegistry(rows: unknown[]): string {
  const bytes = JSON.stringify(rows)
  writeFileSync(registryFile(), bytes, { mode: 0o600 })
  return bytes
}

const readRegistry = () => JSON.parse(readFileSync(registryFile(), 'utf8')) as Array<Record<string, unknown>>

async function loadRegistryModule() {
  vi.resetModules()
  process.env.ADAPTER_DATA_DIR = dataDir
  process.env.CLAUDE_PROJECTS_DIR = dataDir
  process.env.CODEX_HOME = dataDir
  process.env.CURSOR_HOME = dataDir
  return import('./registry.js')
}

const processIdentity = (pid: number) => ({ pid, executable: 'claude', startMarker: `start ${pid}` })

describe('ownership shape', () => {
  it('accepts exactly managed or a complete external tmux claim', () => {
    expect(validOwnership({ kind: 'managed' })).toBe(true)
    expect(validOwnership(external())).toBe(true)
    for (const bad of [
      null, 'external', [], { kind: 'other' }, { kind: 'managed', extra: 1 },
      { ...external(), socketPath: 'relative/socket' },
      { ...external(), serverIdentity: '' },
      { ...external(), paneId: '21' },
      { ...external(), backend: 'herdr' },
      { ...external(), extra: true },
      { kind: 'external', backend: 'tmux', socketPath: '/tmp/s', paneId: '%1' },
    ]) expect(validOwnership(bad)).toBe(false)
  })

  it('fits an external claim only to an unbound terminal whose one tmux runtime is the enrolled pane', () => {
    const runtimes = [{ backend: 'tmux' as const, paneId: '%21' }]
    expect(ownershipFitsRow(external(), { engine: 'terminal', runtimes })).toBe(true)
    expect(ownershipFitsRow(external(), { engine: 'terminal', runtimes, sessionId: '', processIdentity: null })).toBe(true)
    expect(ownershipFitsRow(external(), { engine: 'claude', runtimes })).toBe(false)
    expect(ownershipFitsRow(external('%22'), { engine: 'terminal', runtimes })).toBe(false)
    expect(ownershipFitsRow(external(), { engine: 'terminal', runtimes: [...runtimes, { backend: 'tmux', paneId: '%23' }] })).toBe(false)
    expect(ownershipFitsRow(external(), { engine: 'terminal', runtimes, sessionId: 'bound' })).toBe(false)
    expect(ownershipFitsRow(external(), { engine: 'terminal', runtimes, processIdentity: processIdentity(1) })).toBe(false)
    expect(ownershipFitsRow({ kind: 'managed' }, { engine: 'claude', runtimes })).toBe(true)
  })

  it('treats absent and managed as managed, and anything else present as not Harness’s', () => {
    expect(isExternallyOwned(undefined)).toBe(false)
    expect(isExternallyOwned({})).toBe(false)
    expect(isExternallyOwned({ ownership: { kind: 'managed' } })).toBe(false)
    expect(isExternallyOwned({ ownership: external() })).toBe(true)
    expect(isExternallyOwned({ ownership: null })).toBe(true)
    expect(isExternallyOwned({ ownership: { kind: 'garbage' } })).toBe(true)
    expect(persistedSchemaVersion({})).toBe(2)
    expect(persistedSchemaVersion({ ownership: { kind: 'managed' } })).toBe(2)
    expect(persistedSchemaVersion({ ownership: external() })).toBe(3)
  })

  it('compares claims semantically: key order never matters, a different claim always does', () => {
    const reordered = { paneId: '%21', serverIdentity: 'pid:4242@1759000000', socketPath: '/private/tmp/tmux-501/default', backend: 'tmux', kind: 'external' }
    expect(sameOwnership(external(), reordered)).toBe(true)
    expect(sameOwnership(undefined, { kind: 'managed' })).toBe(true)
    expect(sameOwnership(external(), external('%22'))).toBe(false)
    expect(sameOwnership(external(), external('%21', 'pid:1@1'))).toBe(false)
    expect(sameOwnership(external(), undefined)).toBe(false)
    expect(sameOwnership({ kind: 'managed' }, { kind: 'managed', extra: 1 })).toBe(false)
    expect(sameOwnership({ b: 1, a: 2 }, { a: 2, b: 1 })).toBe(true)
  })

  it('never offers an external pane id to a legacy rename or to discovery’s mouse-on unless a managed row holds it', () => {
    const rows = [
      { engine: 'terminal' as const, runtimes: [{ backend: 'tmux' as const, paneId: '%1' }], ownership: external('%1') },
      { engine: 'terminal' as const, runtimes: [{ backend: 'tmux' as const, paneId: '%2' }], ownership: external('%2') },
      { engine: 'codex' as const, runtimes: [{ backend: 'tmux' as const, paneId: '%2' }] },
      { engine: 'claude' as const, runtimes: [{ backend: 'tmux' as const, paneId: '%3' }] },
    ]
    expect([...managedTmuxPaneEngines(rows)]).toEqual([['%2', 'codex'], ['%3', 'claude']])
    expect([...externalOnlyTmuxPanes(rows)]).toEqual(['%1'])
  })
})

/**
 * The gates the registry reader and stopped-agent reader had before `ownership` existed, copied from
 * `git show 805d3deb:cli/src/lib/registry.ts` (`hasUnknownRowSchema`, `load`'s legacy/v2 split and its
 * explicit row rebuild, `strictPersistedRow`'s schema check) and `stoppedAgents.ts` (`version !== 1`,
 * then that `strictPersistedRow`). Only the parts that decide whether a row loads, and whether
 * `ownership` survives, are kept. This models the v2-schema builds (d04c6a8b onward) only: builds
 * before d04c6a8b have no schema check and would read an external row as managed — the documented
 * compatibility floor in agentOwnership.ts, which no test here can move.
 */
const preOwnershipBuild = {
  hasUnknownRowSchema: (value: unknown): boolean => !!value && typeof value === 'object'
    && Object.hasOwn(value, 'schemaVersion')
    && (value as { schemaVersion?: unknown }).schemaVersion !== 2,
  /** 'blocked' = read-only, nothing loaded or overwritten. Otherwise the rows as that build holds them. */
  loadRegistry(stored: unknown[]): 'blocked' | Array<Record<string, unknown>> {
    if (stored.some(preOwnershipBuild.hasUnknownRowSchema)) return 'blocked'
    // `load` rebuilds each row from an explicit field list that has no `ownership`.
    return (stored as Array<Record<string, unknown>>).map(({ ownership: _dropped, ...row }) => row)
  },
  readArchive(raw: { version?: unknown; session?: { schemaVersion?: unknown } }): 'none' | 'row' {
    if (raw.version !== 1) return 'none'
    return raw.session?.schemaVersion !== 2 ? 'none' : 'row'
  },
}

describe('registry ownership persistence and boundaries', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    dataDir = mkdtempSync(join(tmpdir(), 'adapter-registry-ownership-'))
  })

  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
    rmSync(dataDir, { recursive: true, force: true })
    delete process.env.ADAPTER_DATA_DIR
    delete process.env.CLAUDE_PROJECTS_DIR
    delete process.env.CODEX_HOME
    delete process.env.CURSOR_HOME
  })

  it('round-trips an external row as v3 through load and save unchanged', async () => {
    writeRegistry([terminalRow()])
    const { registry } = await loadRegistryModule()
    registry.load()
    expect(registry.byAgent('borrowed-1')?.ownership).toEqual(external())

    // Any write re-serializes every row; the claim and its version must survive it.
    expect(registry.markOpened('borrowed-1')).not.toBeNull()
    expect(readRegistry().find((row) => row.agentId === 'borrowed-1')).toMatchObject({ schemaVersion: 3, ownership: external() })

    const { registry: reloaded } = await loadRegistryModule()
    reloaded.load()
    expect(reloaded.byAgent('borrowed-1')).toMatchObject({ engine: 'terminal', tmuxPane: '%21', ownership: external() })
  })

  it('keeps managed and legacy rows v2 without an ownership field', async () => {
    writeRegistry([
      terminalRow({ schemaVersion: 2, agentId: 'managed-explicit', ownership: { kind: 'managed' }, tmuxPane: '%30' }),
      { agentId: 'legacy-1', sessionId: '', engine: 'terminal', projectDir: 'demo', cwd: '/tmp/demo', tmuxPane: '%31' },
    ])
    const { registry } = await loadRegistryModule()
    registry.load()
    expect(registry.byAgent('managed-explicit')?.ownership).toEqual({ kind: 'managed' })
    expect(registry.byAgent('legacy-1')).toBeDefined()
    expect(registry.byAgent('legacy-1')).not.toHaveProperty('ownership')
    const opened = registry.openPendingAgent({ engine: 'codex', runtimes: [{ backend: 'tmux', paneId: '%32' }], cwd: '/tmp/x' })!
    expect(opened).not.toHaveProperty('ownership')
    const persisted = readRegistry()
    expect(persisted.every((row) => row.schemaVersion === 2)).toBe(true)
    expect(persisted.find((row) => row.agentId === 'legacy-1')).not.toHaveProperty('ownership')
    expect(persisted.find((row) => row.agentId === opened.agentId)).not.toHaveProperty('ownership')
  })

  it.each([
    ['a relative socket path', terminalRow({ ownership: { ...external(), socketPath: 'tmux-501/default' } })],
    ['null', terminalRow({ ownership: null })],
    ['an unknown kind', terminalRow({ ownership: { kind: 'borrowed' } })],
    ['an engine row', terminalRow({ engine: 'claude', terminalHost: undefined })],
    ['a pane id that is not the row’s runtime', terminalRow({ ownership: external('%99') })],
    ['bound to a session', terminalRow({ sessionId: 'session-x', boundAt: 1 })],
    ['carrying a process identity', terminalRow({ processIdentity: processIdentity(9) })],
    ['external on a v2 row (what an old build would strip)', terminalRow({ schemaVersion: 2 })],
    ['absent on a v3 row', managedRow({ agentId: 'borrowed-1', schemaVersion: 3 })],
    ['a legacy row', { agentId: 'legacy-x', sessionId: '', engine: 'terminal', projectDir: 'demo', tmuxPane: '%21', ownership: external() }],
  ])('preserves the file and blocks writes when ownership is %s', async (_label, bad) => {
    const good = managedRow({ tmuxPane: '%40' })
    const bytes = writeRegistry([good, bad])
    const { registry } = await loadRegistryModule()
    registry.load()
    // Never silently read as managed: nothing loads, and nothing may overwrite the operator's bytes.
    expect(registry.list()).toEqual([])
    expect(registry.openPendingAgent({ engine: 'codex', runtimes: [{ backend: 'tmux', paneId: '%41' }], cwd: '/tmp/x' })).toBeNull()
    registry.flush()
    expect(readFileSync(registryFile(), 'utf8')).toBe(bytes)
  })

  it('refuses two external rows claiming one pane of one server incarnation, but not of a restarted one', async () => {
    const bytes = writeRegistry([terminalRow(), terminalRow({ agentId: 'borrowed-2' })])
    const { registry } = await loadRegistryModule()
    registry.load()
    expect(registry.list()).toEqual([])
    registry.flush()
    expect(readFileSync(registryFile(), 'utf8')).toBe(bytes)

    writeRegistry([terminalRow(), terminalRow({ agentId: 'borrowed-2', ownership: external('%21', 'pid:9999@1760000000') })])
    const { registry: restarted } = await loadRegistryModule()
    restarted.load()
    expect(restarted.list().map((row) => row.agentId).sort()).toEqual(['borrowed-1', 'borrowed-2'])
  })

  describe('downgrade: the v2-schema builds before `ownership` (d04c6a8b onward)', () => {
    it('refuse every file this build writes with an external row, instead of reading it as managed', async () => {
      writeRegistry([terminalRow(), managedRow({ tmuxPane: '%40' })])
      const { registry } = await loadRegistryModule()
      registry.load()
      registry.markOpened('managed-1')
      const written = readRegistry()
      expect(written.find((row) => row.agentId === 'borrowed-1')?.schemaVersion).toBe(3)
      expect(preOwnershipBuild.loadRegistry(written)).toBe('blocked')

      // Why the version and not just the field: the same row at v2 loads there with its claim gone.
      const asV2 = written.map((row) => ({ ...row, schemaVersion: 2 }))
      const stripped = preOwnershipBuild.loadRegistry(asV2)
      expect(stripped).not.toBe('blocked')
      expect((stripped as Array<Record<string, unknown>>).find((row) => row.agentId === 'borrowed-1')).not.toHaveProperty('ownership')
    })

    it('still read a file with only managed and legacy rows', async () => {
      writeRegistry([managedRow({ tmuxPane: '%40' }), { agentId: 'legacy-1', sessionId: '', engine: 'terminal', projectDir: 'demo', tmuxPane: '%31' }])
      const { registry } = await loadRegistryModule()
      registry.load()
      registry.markOpened('managed-1')
      expect(preOwnershipBuild.loadRegistry(readRegistry())).not.toBe('blocked')
    })

    it('see no archive for an external row', () => {
      expect(preOwnershipBuild.readArchive({ version: 1, session: terminalRow() })).toBe('none')
      expect(preOwnershipBuild.readArchive({ version: 1, session: managedRow() })).toBe('row')
    })
  })

  describe('quarantine: an external row holds no pane-id route', () => {
    it('never resolves, blocks or evicts a managed pane that reuses its pane id', async () => {
      const transcriptPath = join(dataDir, 'session-x.jsonl')
      writeFileSync(transcriptPath, '{}\n')
      writeRegistry([terminalRow()])
      const { registry } = await loadRegistryModule()
      registry.load()
      const pane = { backend: 'tmux' as const, paneId: '%21' }

      // Not a route owner: a pane-id lookup does not find it.
      expect(registry.byRuntimeTerminal(pane)).toBeUndefined()
      expect(registry.byPaneEngine('%21', 'terminal')).toBeUndefined()

      // A new managed pane on the reused id opens, is found by that id, and binds its own hook.
      const discovered = registry.openProcessAgent({ engine: 'claude', runtimes: [pane], cwd: '/tmp/work', processIdentity: processIdentity(501) })
      expect(discovered?.isNew).toBe(true)
      expect(discovered?.evicted).toBeNull()
      const managedId = discovered!.entry.agentId
      expect(registry.byRuntimeEngine(pane, 'claude')?.agentId).toBe(managedId)
      const bound = registry.register({ engine: 'claude', sessionId: 'session-x', transcriptPath, tmuxPane: '%21', processIdentity: processIdentity(501) })
      expect(bound?.entry.agentId).toBe(managedId)
      expect(registry.bySession('session-x')?.agentId).toBe(managedId)

      // The external row is untouched and still addressable by its own id only.
      expect(registry.byAgent('borrowed-1')).toMatchObject({ engine: 'terminal', tmuxPane: '%21', sessionId: '', processIdentity: null, ownership: external() })
      expect(registry.list()).toHaveLength(2)

      // Both persist side by side: a shared pane id is not a collision.
      const persisted = readRegistry()
      expect(persisted.map((row) => row.agentId).sort()).toEqual(['borrowed-1', managedId].sort())
      const { registry: reloaded } = await loadRegistryModule()
      reloaded.load()
      expect(reloaded.list()).toHaveLength(2)
      expect(reloaded.byRuntimeEngine(pane, 'claude')?.agentId).toBe(managedId)
    })

    it('lets a pending pane and a moved row take the reused id', async () => {
      writeRegistry([terminalRow()])
      const { registry } = await loadRegistryModule()
      registry.load()
      const pending = registry.openPendingAgent({ engine: 'codex', runtimes: [{ backend: 'tmux', paneId: '%21' }], cwd: '/tmp/x' })
      expect(pending).not.toBeNull()
      expect(registry.byRuntimeEngine({ backend: 'tmux', paneId: '%21' }, 'codex')?.agentId).toBe(pending!.agentId)
      const other = registry.openPendingAgent({ engine: 'codex', runtimes: [{ backend: 'tmux', paneId: '%50' }], cwd: '/tmp/x' })!
      registry.removeAgent(pending!.agentId)
      expect(registry.updateRuntimes(other.agentId, [{ backend: 'tmux', paneId: '%21' }])).toBe(true)
      expect(registry.byRuntimeEngine({ backend: 'tmux', paneId: '%21' }, 'codex')?.agentId).toBe(other.agentId)
    })

    it('never converts, moves, re-identifies, advertises or resumes the external row itself', async () => {
      writeRegistry([terminalRow()])
      const { registry } = await loadRegistryModule()
      registry.load()

      expect(registry.adoptEngine('borrowed-1', 'claude', processIdentity(501))).toBeNull()
      expect(registry.updateRuntimes('borrowed-1', [{ backend: 'tmux', paneId: '%51' }])).toBe(false)
      expect(registry.releaseEngine('borrowed-1', true)).toBeNull()
      expect(registry.updateProcessIdentity('borrowed-1', processIdentity(502))).toBe(false)
      expect(registry.byProcess('terminal', processIdentity(502))).toBeUndefined()
      expect(registry.setTerminalAvailable('borrowed-1', true)).toBe(false)
      expect(registry.advertised()).toEqual([])
      expect(registry.resumePendingAgent({ ...registry.byAgent('borrowed-1')!, agentId: 'other' }, [{ backend: 'tmux', paneId: '%52' }])).toBeNull()

      expect(registry.byAgent('borrowed-1')).toMatchObject({ engine: 'terminal', tmuxPane: '%21', sessionId: '', processIdentity: null, ownership: external() })
    })

    it('leaves managed terminals adoptable as before', async () => {
      writeRegistry([managedRow({ agentId: 'managed-t' })])
      const { registry } = await loadRegistryModule()
      registry.load()
      expect(registry.adoptEngine('managed-t', 'claude', processIdentity(502))).toMatchObject({ engine: 'claude' })
    })
  })

  describe('save: a conflict an external claim causes fails closed once', () => {
    it('blocks writes, keeps the file, and does not retry on every later change', async () => {
      writeRegistry([terminalRow(), managedRow({ tmuxPane: '%40' })])
      const { registry } = await loadRegistryModule()
      registry.load()
      // Another writer (a daemon-down hook, an operator) adds a second claim on the same endpoint.
      const onDisk = writeRegistry([terminalRow(), managedRow({ tmuxPane: '%40' }), terminalRow({ agentId: 'borrowed-2' })])
      const error = vi.spyOn(console, 'error').mockImplementation(() => {})

      registry.markOpened('managed-1')
      expect(readFileSync(registryFile(), 'utf8')).toBe(onDisk)
      expect(error.mock.calls.filter(([message]) => message === '[registry] save failed:')).toHaveLength(1)
      expect(String(error.mock.calls.find(([message]) => message === '[registry] save failed:')?.[1])).toMatch(/external terminal claim/)

      // Every later write is skipped as blocked, not re-attempted and re-failed.
      registry.markOpened('managed-1')
      registry.setCwd('managed-1', '/tmp/elsewhere')
      expect(registry.openPendingAgent({ engine: 'codex', runtimes: [{ backend: 'tmux', paneId: '%60' }], cwd: '/tmp/x' })).toBeNull()
      expect(error.mock.calls.filter(([message]) => message === '[registry] save failed:')).toHaveLength(1)
      expect(error.mock.calls.some(([message]) => String(message).includes('save skipped'))).toBe(true)
      expect(readFileSync(registryFile(), 'utf8')).toBe(onDisk)
    })

    it('blocks writes when a merge would drop an external claim behind the daemon’s back', async () => {
      writeRegistry([terminalRow()])
      const { registry } = await loadRegistryModule()
      registry.load()
      // The file now says the pane is managed. The daemon holds it as external; neither silently wins.
      const onDisk = writeRegistry([managedRow({ agentId: 'borrowed-1' })])
      const error = vi.spyOn(console, 'error').mockImplementation(() => {})

      registry.markOpened('borrowed-1')
      registry.markOpened('borrowed-1')
      expect(readFileSync(registryFile(), 'utf8')).toBe(onDisk)
      expect(error.mock.calls.filter(([message]) => message === '[registry] save failed:')).toHaveLength(1)
      expect(registry.byAgent('borrowed-1')?.ownership).toEqual(external())
    })

    it('does not block writes when another writer re-serializes the same claim in a different key order', async () => {
      writeRegistry([terminalRow()])
      const { registry } = await loadRegistryModule()
      registry.load()
      const { kind, backend, socketPath, serverIdentity, paneId } = external()
      writeRegistry([terminalRow({ ownership: { paneId, serverIdentity, socketPath, backend, kind } })])
      const error = vi.spyOn(console, 'error').mockImplementation(() => {})

      expect(registry.markOpened('borrowed-1')).not.toBeNull()
      expect(error.mock.calls.filter(([message]) => message === '[registry] save failed:')).toHaveLength(0)
      const saved = readRegistry().find((row) => row.agentId === 'borrowed-1')
      expect(saved).toMatchObject({ schemaVersion: 3, ownership: external() })
      expect(saved?.lastOpenedAt).toEqual(expect.any(Number))
      // Still writable afterwards: nothing was blocked.
      registry.setCwd('borrowed-1', '/tmp/after')
      expect(readRegistry().find((row) => row.agentId === 'borrowed-1')).toMatchObject({ cwd: '/tmp/after' })
    })

    it('leaves an ordinary managed invariant failure as it was: logged, not blocked', async () => {
      writeRegistry([managedRow({ tmuxPane: '%40' })])
      const { registry } = await loadRegistryModule()
      registry.load()
      // A malformed managed row appears on disk: the old behaviour is a failed save, not a lock.
      writeRegistry([managedRow({ tmuxPane: '%40' }), managedRow({ agentId: 'managed-2', tmuxPane: '%41', engine: 'not-an-engine' })])
      const error = vi.spyOn(console, 'error').mockImplementation(() => {})
      registry.setCwd('managed-1', '/tmp/one')
      registry.setCwd('managed-1', '/tmp/two')
      expect(error.mock.calls.filter(([message]) => message === '[registry] save failed:')).toHaveLength(2)
      expect(error.mock.calls.some(([message]) => String(message).includes('save skipped'))).toBe(false)
    })
  })
})
