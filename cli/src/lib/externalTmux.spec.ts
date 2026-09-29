import { describe, expect, it, vi } from 'vitest'
import {
  ExternalTmuxController, FULL_INVENTORY_FORMAT, classifyPanes, parseFullInventory, statusAgainst,
  type ExternalRegistry, type FullTmuxInventory, type TmuxInventoryPane,
} from './externalTmux.js'
import type { ExternalTmuxOwnership } from './agentOwnership.js'
import type { RegisteredSession } from './registry.js'

const SOCKET = '/private/tmp/tmux-501/default'
const SEP = '|^|'

function line(fields: Partial<Record<'pid' | 'start' | 'socket' | 'pane' | 'panes' | 'window' | 'index' | 'session' | 'windowName' | 'command' | 'cwd', string>> = {}): string {
  return [
    fields.pid ?? '100', fields.start ?? '1700000000', fields.socket ?? SOCKET, fields.pane ?? '%3', fields.panes ?? '1',
    fields.window ?? '0', fields.index ?? '0', fields.session ?? 'work', fields.windowName ?? 'zsh', fields.command ?? 'zsh', fields.cwd ?? '/Users/me/work',
  ].join(SEP)
}

const pane = (overrides: Partial<TmuxInventoryPane> = {}): TmuxInventoryPane => ({
  paneId: '%3', sessionName: 'work', windowIndex: 0, paneIndex: 0, windowPanes: 1, windowName: 'zsh', command: 'zsh', cwd: '/Users/me/work',
  ...overrides,
})

const inventory = (panes: TmuxInventoryPane[], serverIdentity = '100:1700000000', socketPath = SOCKET): FullTmuxInventory =>
  ({ ok: true, server: { socketPath, serverIdentity }, panes })

const ownership = (paneId = '%3', serverIdentity = '100:1700000000'): ExternalTmuxOwnership =>
  ({ kind: 'external', backend: 'tmux', socketPath: SOCKET, serverIdentity, paneId })

function row(agentId: string, paneId: string, owned?: ExternalTmuxOwnership): RegisteredSession {
  return {
    schemaVersion: owned ? 3 : 2, agentId, engine: 'terminal', sessionId: '', active: true,
    runtimes: [{ backend: 'tmux', paneId }], primaryRuntimeKey: `tmux\u0000${paneId}`, tmuxPane: paneId,
    processIdentity: null, cwd: '/tmp', ...(owned ? { ownership: owned } : {}),
  } as unknown as RegisteredSession
}

/** An in-memory registry with the same refusals the real one makes for enrollment. */
function fakeRegistry(initial: RegisteredSession[] = []): ExternalRegistry & { rows: RegisteredSession[] } {
  const rows = [...initial]
  let next = 0
  return {
    rows,
    list: () => [...rows],
    byAgent: (agentId) => rows.find((candidate) => candidate.agentId === agentId),
    enrollExternal: vi.fn(({ ownership: owned }) => {
      if (rows.some((candidate) => !candidate.ownership && candidate.tmuxPane === owned.paneId)) return null
      const created = row(`borrowed-${++next}`, owned.paneId, owned)
      rows.push(created)
      return created
    }),
    unenrollExternal: vi.fn((agentId) => {
      const index = rows.findIndex((candidate) => candidate.agentId === agentId && !!candidate.ownership)
      if (index < 0) return false
      rows.splice(index, 1)
      return true
    }),
  }
}

describe('full tmux inventory parsing', () => {
  it('reads every pane with one server identity, keeping a separator inside the path', () => {
    const parsed = parseFullInventory(`${line()}\n${line({ pane: '%4', window: '2', index: '1', panes: '2', cwd: `/odd${SEP}path` })}\n`)
    expect(parsed).toEqual({
      ok: true,
      server: { socketPath: SOCKET, serverIdentity: '100:1700000000' },
      panes: [pane(), pane({ paneId: '%4', windowIndex: 2, paneIndex: 1, windowPanes: 2, cwd: `/odd${SEP}path` })],
    })
  })

  it('treats any malformed line as an error, never as fewer panes', () => {
    expect(parseFullInventory(`${line()}\ngarbage`)).toEqual({ ok: false, error: 'malformed tmux inventory line' })
    expect(parseFullInventory(line({ pane: '3' })).ok).toBe(false)
    expect(parseFullInventory(line({ socket: 'relative' })).ok).toBe(false)
    expect(parseFullInventory(line({ panes: '0' })).ok).toBe(false)
    expect(parseFullInventory(`${line()}\n${line()}`).ok).toBe(false)
  })

  it('refuses a listing that spans two server incarnations', () => {
    expect(parseFullInventory(`${line()}\n${line({ pane: '%9', start: '1700000001' })}`))
      .toEqual({ ok: false, error: 'tmux inventory spans more than one server' })
  })

  it('skips the panes a borrowed stream’s own view session lists a second time', () => {
    const view = 'harness_view-4242-1-0badc0de'
    const parsed = parseFullInventory(`${line({ session: view })}\n${line()}\n${line({ pane: '%9', session: view })}\n`)
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) return
    expect(parsed.panes.map((pane) => pane.paneId)).toEqual([line().split(SEP)[3]])
    expect(parsed.panes.some((pane) => pane.sessionName === view)).toBe(false)
    // A person's session that merely looks similar is still theirs.
    expect(parseFullInventory(line({ session: 'harness_view-notes' }))).toMatchObject({ ok: true, panes: [{ sessionName: 'harness_view-notes' }] })
  })

  it('reads an empty listing as a server with no panes', () => {
    expect(parseFullInventory('')).toEqual({ ok: true, server: null, panes: [] })
  })

  it('asks tmux for the server identity and socket, not just the pane', () => {
    expect(FULL_INVENTORY_FORMAT).toContain('#{pid}')
    expect(FULL_INVENTORY_FORMAT).toContain('#{start_time}')
    expect(FULL_INVENTORY_FORMAT).toContain('#{socket_path}')
  })
})

describe('classification: what may be enrolled', () => {
  it('refuses every pane managed discovery owns or can adopt, and panes that share a window', () => {
    const managed = row('managed-1', '%7')
    const stale = row('borrowed-old', '%5', ownership('%5', '99:1600000000'))
    const current = row('borrowed-now', '%6', ownership('%6'))
    const panes = classifyPanes(inventory([
      pane({ paneId: '%1', sessionName: 'harness-claude-1759000000000' }),
      pane({ paneId: '%2', sessionName: 'claude-1759000000000' }),
      pane({ paneId: '%7', sessionName: 'renamed-by-hand' }),
      pane({ paneId: '%5' }),
      pane({ paneId: '%6' }),
      pane({ paneId: '%8', windowPanes: 3 }),
      pane({ paneId: '%9' }),
    ]) as Extract<FullTmuxInventory, { ok: true }>, [managed, stale, current])
    expect(panes.map((candidate) => [candidate.paneId, candidate.state, candidate.agentId])).toEqual([
      ['%1', 'managed', undefined],
      ['%2', 'managed', undefined],
      ['%7', 'managed', undefined],
      // A stale enrollment from a restarted server does not claim the reused id.
      ['%5', 'available', undefined],
      ['%6', 'enrolled', 'borrowed-now'],
      ['%8', 'shared_window', undefined],
      ['%9', 'available', undefined],
    ])
  })
})

describe('status of an enrolled pane', () => {
  const managedIds = new Set<string>()

  it('is available only on the enrolled server incarnation, with the pane alone in its window', () => {
    expect(statusAgainst(ownership(), inventory([pane()]), managedIds)).toMatchObject({ available: true, reason: null, sessionName: 'work' })
  })

  it('reports a restarted server even when the pane id exists again', () => {
    expect(statusAgainst(ownership(), inventory([pane()], '555:1800000000'), managedIds))
      .toEqual({ available: false, reason: 'TMUX_SERVER_RESTARTED' })
  })

  it('separates failure to look from absence', () => {
    expect(statusAgainst(ownership(), { ok: false, error: 'tmux did not answer in time' }, managedIds))
      .toEqual({ available: false, reason: 'TMUX_INVENTORY_FAILED' })
    expect(statusAgainst(ownership(), { ok: true, server: null, panes: [] }, managedIds))
      .toEqual({ available: false, reason: 'TMUX_SERVER_NOT_RUNNING' })
    expect(statusAgainst(ownership(), inventory([]), managedIds)).toEqual({ available: false, reason: 'TMUX_PANE_GONE' })
  })

  it('refuses a socket change, a pane that became Harness’s own, and a split window', () => {
    expect(statusAgainst(ownership(), inventory([pane()], '100:1700000000', '/tmp/other/default'), managedIds).reason).toBe('TMUX_SOCKET_CHANGED')
    expect(statusAgainst(ownership(), inventory([pane({ sessionName: 'harness-x' })]), managedIds).reason).toBe('TMUX_PANE_MANAGED')
    expect(statusAgainst(ownership(), inventory([pane()]), new Set(['%3'])).reason).toBe('TMUX_PANE_MANAGED')
    expect(statusAgainst(ownership(), inventory([pane({ windowPanes: 2 })]), managedIds).reason).toBe('TMUX_PANE_SHARED_WINDOW')
  })
})

describe('ExternalTmuxController', () => {
  function setup(initial: RegisteredSession[] = [], first: FullTmuxInventory = inventory([pane()])) {
    const registry = fakeRegistry(initial)
    let current = first
    const readInventory = vi.fn(async () => current)
    const onChanged = vi.fn()
    const onRemoved = vi.fn(async () => {})
    const controller = new ExternalTmuxController({ registry, readInventory, onChanged, onRemoved })
    return { registry, controller, onChanged, onRemoved, readInventory, set: (next: FullTmuxInventory) => { current = next } }
  }

  it('lists panes without enrolling anything', async () => {
    const { controller, registry } = setup([], inventory([pane(), pane({ paneId: '%1', sessionName: 'harness-codex-1' })]))
    const listed = await controller.list()
    expect(listed).toMatchObject({ ok: true, server: { serverIdentity: '100:1700000000' } })
    expect(listed.ok && listed.panes.map((candidate) => candidate.state)).toEqual(['available', 'managed'])
    expect(registry.enrollExternal).not.toHaveBeenCalled()
    expect(registry.rows).toEqual([])
  })

  it('reports an unreadable server as an error, not an empty list', async () => {
    const { controller } = setup([], { ok: false, error: 'permission denied' })
    expect(await controller.list()).toEqual({ ok: false, error: 'TMUX_INVENTORY_FAILED', detail: 'permission denied' })
  })

  it('enrolls the listed pane with socket, server identity and pane id; a second enroll is the same row', async () => {
    const { controller, registry, onChanged } = setup()
    const first = await controller.enroll('%3', '100:1700000000')
    expect(first).toMatchObject({ ok: true, alreadyEnrolled: false })
    expect(registry.enrollExternal).toHaveBeenCalledWith({ ownership: ownership(), cwd: '/Users/me/work', name: 'work:0.0' })
    expect(controller.status(first.ok ? first.agent.agentId : '')).toMatchObject({ available: true })
    expect(onChanged).toHaveBeenCalled()
    const again = await controller.enroll('%3', '100:1700000000')
    expect(again).toMatchObject({ ok: true, alreadyEnrolled: true })
    expect(registry.rows).toHaveLength(1)
  })

  it('refuses a stale listing: the server restarted between list and enroll', async () => {
    const { controller, registry } = setup()
    expect(await controller.enroll('%3', '99:1600000000')).toMatchObject({ ok: false, error: 'TMUX_SERVER_CHANGED' })
    expect(registry.enrollExternal).not.toHaveBeenCalled()
  })

  it('refuses managed panes, shared windows, unknown panes, malformed input and unreadable tmux', async () => {
    const managed = row('managed-1', '%4')
    const { controller, registry, set } = setup([managed], inventory([
      pane({ paneId: '%1', sessionName: 'harness-claude-1' }), pane({ paneId: '%4' }), pane({ paneId: '%5', windowPanes: 2 }),
    ]))
    expect(await controller.enroll('%1', '100:1700000000')).toMatchObject({ ok: false, error: 'TMUX_PANE_MANAGED' })
    expect(await controller.enroll('%4', '100:1700000000')).toMatchObject({ ok: false, error: 'TMUX_PANE_MANAGED' })
    expect(await controller.enroll('%5', '100:1700000000')).toMatchObject({ ok: false, error: 'TMUX_PANE_SHARED_WINDOW' })
    expect(await controller.enroll('%6', '100:1700000000')).toMatchObject({ ok: false, error: 'TMUX_PANE_NOT_FOUND' })
    expect(await controller.enroll('3', '100:1700000000')).toMatchObject({ ok: false, error: 'INVALID_PANE' })
    expect(await controller.enroll('%3', '/tmp/evil.sock')).toMatchObject({ ok: false, error: 'INVALID_PANE' })
    set({ ok: false, error: 'tmux did not answer in time' })
    expect(await controller.enroll('%3', '100:1700000000')).toMatchObject({ ok: false, error: 'TMUX_INVENTORY_FAILED' })
    set({ ok: true, server: null, panes: [] })
    expect(await controller.enroll('%3', '100:1700000000')).toMatchObject({ ok: false, error: 'TMUX_SERVER_NOT_RUNNING' })
    expect(registry.enrollExternal).not.toHaveBeenCalled()
  })

  it('never routes a stale row to a reused pane id after a server restart', async () => {
    const enrolled = row('borrowed-1', '%3', ownership())
    const { controller, set, registry } = setup([enrolled])
    expect(await controller.verify(enrolled)).toEqual({ ok: true })
    set(inventory([pane({ command: 'vim' })], '555:1800000000'))
    expect(await controller.verify(enrolled)).toMatchObject({ ok: false, reason: 'TMUX_SERVER_RESTARTED' })
    expect(controller.status('borrowed-1')).toMatchObject({ available: false, reason: 'TMUX_SERVER_RESTARTED' })
    // The reused id is someone else's pane: listable and enrollable as a NEW pane, never as the old row.
    const listed = await controller.list()
    expect(listed.ok && listed.panes[0]).toMatchObject({ paneId: '%3', state: 'available' })
    expect(registry.rows.map((candidate) => candidate.agentId)).toEqual(['borrowed-1'])
  })

  it('keeps a row enrolled and unavailable when tmux cannot be read, remembering what it last saw', async () => {
    const enrolled = row('borrowed-1', '%3', ownership())
    const { controller, set, registry, onRemoved } = setup([enrolled])
    await controller.refresh()
    set({ ok: false, error: 'permission denied' })
    expect(await controller.verify(enrolled)).toMatchObject({ ok: false, reason: 'TMUX_INVENTORY_FAILED' })
    expect(controller.status('borrowed-1')).toMatchObject({ available: false, reason: 'TMUX_INVENTORY_FAILED', sessionName: 'work' })
    expect(registry.unenrollExternal).not.toHaveBeenCalled()
    expect(onRemoved).not.toHaveBeenCalled()
  })

  it('on boot marks a missing pane unavailable and never recreates or removes it', async () => {
    const enrolled = row('borrowed-1', '%3', ownership())
    const { controller, registry } = setup([enrolled], inventory([]))
    expect(controller.status('borrowed-1')).toEqual({ available: false, reason: 'NOT_CHECKED' })
    await controller.refresh()
    expect(controller.status('borrowed-1')).toEqual({ available: false, reason: 'TMUX_PANE_GONE' })
    expect(registry.rows).toEqual([enrolled])
    expect(registry.enrollExternal).not.toHaveBeenCalled()
  })

  it('unenrolls only external rows, closing views and telling clients, with no tmux side effect', async () => {
    const enrolled = row('borrowed-1', '%3', ownership())
    const managed = row('managed-1', '%4')
    const { controller, registry, onRemoved, readInventory } = setup([enrolled, managed])
    expect(await controller.unenroll('managed-1')).toMatchObject({ ok: false, error: 'NOT_EXTERNAL' })
    expect(await controller.unenroll('nope')).toMatchObject({ ok: false, error: 'AGENT_NOT_FOUND' })
    expect(await controller.unenroll('borrowed-1')).toEqual({ ok: true })
    expect(onRemoved).toHaveBeenCalledWith('borrowed-1')
    expect(registry.rows).toEqual([managed])
    // Unenrolling reads nothing from tmux and so cannot write anything to it either.
    expect(readInventory).not.toHaveBeenCalled()
  })

  it('serializes concurrent enrolls of one pane into one row', async () => {
    const { controller, registry } = setup()
    const [a, b] = await Promise.all([controller.enroll('%3', '100:1700000000'), controller.enroll('%3', '100:1700000000')])
    expect(a).toMatchObject({ ok: true, alreadyEnrolled: false })
    expect(b).toMatchObject({ ok: true, alreadyEnrolled: true })
    expect(registry.rows).toHaveLength(1)
  })
})
