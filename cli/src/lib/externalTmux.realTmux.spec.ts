/**
 * Borrowed panes against a REAL tmux server — but never the person's. ⚠️ A bare `tmux` in a test once
 * killed every live pane on the machine, so:
 *   - TMUX is unset and TMUX_TMPDIR points at a fresh temp dir BEFORE anything runs, so the "default
 *     server" the code under test reaches is this file's own;
 *   - every command the test itself runs names that socket with `-S`;
 *   - the socket the code under test reports is asserted to be inside the temp dir before any step
 *     that changes a pane.
 */
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest'
import { execFileSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { ExternalTmuxController, readFullTmuxInventory, type ExternalRegistry } from './externalTmux.js'
import type { ExternalTmuxOwnership } from './agentOwnership.js'
import type { RegisteredSession } from './registry.js'
import { TmuxControlStream } from './tmuxStream.js'

const hasTmux = (() => { try { execFileSync('tmux', ['-V']); return true } catch { return false } })()

describe.skipIf(!hasTmux)('borrowed panes on a real, isolated tmux server', () => {
  const saved = { TMUX: process.env.TMUX, TMUX_PANE: process.env.TMUX_PANE, TMUX_TMPDIR: process.env.TMUX_TMPDIR }
  let dir = ''
  let socket = ''
  const tmux = (...args: string[]): string =>
    execFileSync('tmux', ['-S', socket, ...args], { env: process.env }).toString().trim()

  const rows: RegisteredSession[] = []
  const registry: ExternalRegistry = {
    list: () => [...rows],
    byAgent: (agentId) => rows.find((row) => row.agentId === agentId),
    enrollExternal: ({ ownership }) => {
      const row = {
        schemaVersion: 3, agentId: `borrowed-${rows.length + 1}`, engine: 'terminal', sessionId: '', active: true,
        runtimes: [{ backend: 'tmux', paneId: ownership.paneId }], primaryRuntimeKey: `tmux\u0000${ownership.paneId}`,
        tmuxPane: ownership.paneId, processIdentity: null, cwd: dir, ownership,
      } as unknown as RegisteredSession
      rows.push(row)
      return row
    },
    unenrollExternal: (agentId) => {
      const index = rows.findIndex((row) => row.agentId === agentId)
      if (index < 0) return false
      rows.splice(index, 1)
      return true
    },
  }
  const onRemoved = vi.fn()
  const controller = new ExternalTmuxController({ registry, onChanged: () => {}, onRemoved })

  const startServer = (): void => {
    tmux('new-session', '-d', '-s', 'mywork', '-x', '80', '-y', '24', 'cat')
    tmux('new-session', '-d', '-s', 'harness-codex-1', '-x', '80', '-y', '24', 'cat')
  }
  const alive = (paneId: string): boolean => tmux('list-panes', '-a', '-F', '#{pane_id}').split('\n').includes(paneId)

  let beforeStart: Awaited<ReturnType<typeof readFullTmuxInventory>> | null = null

  beforeAll(async () => {
    // /tmp keeps the socket path under macOS's 104-byte limit; realpath because tmux reports /private/tmp.
    dir = realpathSync(mkdtempSync('/tmp/oh-ext-'))
    delete process.env.TMUX
    delete process.env.TMUX_PANE
    process.env.TMUX_TMPDIR = dir
    socket = join(dir, `tmux-${process.getuid!()}`, 'default')
    // Before any server exists, the daemon's view is "not running", not an error.
    beforeStart = await readFullTmuxInventory()
    mkdirSync(join(dir, `tmux-${process.getuid!()}`), { recursive: true, mode: 0o700 })
    startServer()
  })

  afterAll(() => {
    try { tmux('kill-server') } catch { /* already gone */ }
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key]
      else process.env[key] = value
    }
    rmSync(dir, { recursive: true, force: true })
  })

  let enrolled: RegisteredSession
  let myPane = ''

  it('the default server the daemon reaches is this test’s isolated one', async () => {
    expect(beforeStart).toEqual({ ok: true, server: null, panes: [] })
    const inventory = await readFullTmuxInventory()
    expect(inventory.ok ? 'ok' : inventory.error).toBe('ok')
    if (!inventory.ok) return
    expect(inventory.server?.socketPath).toBe(socket)
    expect(inventory.server?.socketPath.startsWith(`${dir}/`)).toBe(true)
  })

  it('lists panes without enrolling, and classifies the harness session as managed', async () => {
    const listed = await controller.list()
    expect(listed.ok).toBe(true)
    if (!listed.ok) return
    const mine = listed.panes.find((pane) => pane.sessionName === 'mywork')!
    const managed = listed.panes.find((pane) => pane.sessionName === 'harness-codex-1')!
    expect(mine.state).toBe('available')
    expect(mine.command).toBeTruthy()
    expect(managed.state).toBe('managed')
    expect(rows).toHaveLength(0)
    myPane = mine.paneId

    const refused = await controller.enroll(managed.paneId, listed.server!.serverIdentity)
    expect(refused).toMatchObject({ ok: false, error: 'TMUX_PANE_MANAGED' })
    const ok = await controller.enroll(myPane, listed.server!.serverIdentity)
    expect(ok.ok).toBe(true)
    if (!ok.ok) return
    enrolled = ok.agent
    expect(enrolled.ownership).toMatchObject({ kind: 'external', socketPath: socket, paneId: myPane })
    expect((await controller.verify(enrolled)).ok).toBe(true)
  })

  it('opens a control stream with working input, and closing it leaves the pane and its sizing as found', async () => {
    const ownership = enrolled.ownership as ExternalTmuxOwnership
    const before = tmux('show-options', '-w', '-t', myPane, 'window-size')
    const chunks: Buffer[] = []
    const opened = await TmuxControlStream.open(myPane, { cols: 100, rows: 30 }, {
      onData: (bytes) => { chunks.push(Buffer.from(bytes)) },
      onClose: () => {},
    }, false, { expectServer: { socketPath: ownership.socketPath, serverIdentity: ownership.serverIdentity }, restoreWindowSize: true })
    expect(opened.state).toBe('succeeded')
    if (opened.state !== 'succeeded') return
    const typed = await opened.value.writeRaw(Buffer.from('borrowed-hello\r'))
    expect(typed.state).toBe('succeeded')
    const deadline = Date.now() + 3_000
    while (!tmux('capture-pane', '-p', '-t', myPane).includes('borrowed-hello') && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 50))
    }
    expect(tmux('capture-pane', '-p', '-t', myPane)).toContain('borrowed-hello')
    await opened.value.close()
    expect(alive(myPane)).toBe(true)
    expect(tmux('show-options', '-w', '-t', myPane, 'window-size')).toBe(before)
  })

  it('a takeover (second stream opens before the first closes) still puts the window sizing back', async () => {
    const ownership = enrolled.ownership as ExternalTmuxOwnership
    const before = tmux('show-options', '-w', '-t', myPane, 'window-size')
    const options = { expectServer: { socketPath: ownership.socketPath, serverIdentity: ownership.serverIdentity }, restoreWindowSize: true }
    const sink = { onData: () => {}, onClose: () => {} }
    const first = await TmuxControlStream.open(myPane, { cols: 101, rows: 31 }, sink, false, options)
    const second = await TmuxControlStream.open(myPane, { cols: 111, rows: 33 }, sink, false, options)
    expect(first.state).toBe('succeeded')
    expect(second.state).toBe('succeeded')
    if (first.state !== 'succeeded' || second.state !== 'succeeded') return
    await first.value.close()
    expect(tmux('show-options', '-w', '-t', myPane, 'window-size')).not.toBe(before)
    await second.value.close()
    expect(tmux('show-options', '-w', '-t', myPane, 'window-size')).toBe(before)
    expect(alive(myPane)).toBe(true)
  })

  it('unenroll forgets the row and leaves the pane running', async () => {
    const removed = await controller.unenroll(enrolled.agentId)
    expect(removed.ok).toBe(true)
    expect(onRemoved).toHaveBeenCalledWith(enrolled.agentId)
    expect(rows).toHaveLength(0)
    expect(alive(myPane)).toBe(true)
    // Put it back for the restart case below.
    const listed = await controller.list()
    if (!listed.ok) throw new Error(listed.detail)
    const again = await controller.enroll(myPane, listed.server!.serverIdentity)
    if (!again.ok) throw new Error(again.detail)
    enrolled = again.agent
  })

  it('after a server restart that reuses the pane id, the stale row is never routed', async () => {
    const ownership = enrolled.ownership as ExternalTmuxOwnership
    tmux('kill-server')
    // Same socket, fresh server: `start_time` has one-second resolution, so wait out the second.
    await new Promise((resolve) => setTimeout(resolve, 1_100))
    startServer()
    const reused = tmux('list-panes', '-t', 'mywork', '-F', '#{pane_id}')
    expect(reused).toBe(ownership.paneId)

    const verified = await controller.verify(enrolled)
    expect(verified).toMatchObject({ ok: false, reason: 'TMUX_SERVER_RESTARTED' })
    expect(controller.status(enrolled.agentId)).toMatchObject({ available: false, reason: 'TMUX_SERVER_RESTARTED' })

    // The stream's own check, for the race where the server restarts after the caller verified.
    const typedBefore = tmux('capture-pane', '-p', '-t', reused)
    const opened = await TmuxControlStream.open(reused, { cols: 90, rows: 20 }, { onData: () => {}, onClose: () => {} }, false, {
      expectServer: { socketPath: ownership.socketPath, serverIdentity: ownership.serverIdentity }, restoreWindowSize: true,
    })
    expect(opened).toMatchObject({ state: 'failed', reason: 'TERMINAL_EXTERNAL_SERVER_CHANGED' })
    expect(tmux('display-message', '-p', '-t', reused, '#{window_width}x#{window_height}')).toBe('80x24')
    expect(tmux('capture-pane', '-p', '-t', reused)).toBe(typedBefore)

    // The listing shows the new pane as available, not as the stale enrollment.
    const listed = await controller.list()
    if (!listed.ok) throw new Error(listed.detail)
    expect(listed.panes.find((pane) => pane.paneId === reused)?.state).toBe('available')
    expect(rows).toHaveLength(1)
  })

  it('a pane that closed is reported gone, not recreated; the row stays until the person unenrolls', async () => {
    const listed = await controller.list()
    if (!listed.ok) throw new Error(listed.detail)
    const fresh = listed.panes.find((pane) => pane.sessionName === 'mywork')!
    const second = await controller.enroll(fresh.paneId, listed.server!.serverIdentity)
    if (!second.ok) throw new Error(second.detail)
    tmux('kill-session', '-t', 'mywork')
    const verified = await controller.verify(second.agent)
    expect(verified).toMatchObject({ ok: false, reason: 'TMUX_PANE_GONE' })
    await controller.refresh()
    expect(tmux('list-sessions', '-F', '#{session_name}').split('\n')).not.toContain('mywork')
    expect(rows.map((row) => row.agentId)).toContain(second.agent.agentId)
  })
})
