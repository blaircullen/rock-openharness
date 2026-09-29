/**
 * Borrowed tmux panes: discover, enroll, verify, unenroll.
 *
 * A person can hand Harness a pane it did not create — a session they opened by hand on this
 * machine's DEFAULT tmux server — and use it from the desktop like any terminal. What Harness may do
 * to it is the short list agentOwnership.ts keeps: open a stream onto it (read, type, resize while
 * attached), close that stream, and forget the enrollment. Never kill, respawn, rename, recreate or
 * adopt an engine into it.
 *
 * ⚠️ **Identity.** A pane id (`%N`) is only unique within ONE server incarnation: a restarted tmux
 * server hands `%0`, `%1`, … out again. So an enrollment is (socketPath, serverIdentity, paneId), and
 * every open re-reads the live default server and compares all three before a stream exists
 * (`verify`). A stale row — a restarted server, a pane that is gone — is reported unavailable and
 * never routed, recreated or matched to whatever reuses its id. The stream then checks the server
 * again through its own control client (tmuxStream.ts, `expectServer`), which closes the race
 * between this check and the attach.
 *
 * ⚠️ **Sockets are the daemon's, not the client's.** Only the default server this daemon's own
 * `tmux` reaches is ever read; no request carries a socket. The enrolled `socketPath` is what that
 * server reported (`#{socket_path}`), kept to notice the daemon's environment pointing elsewhere.
 *
 * ⚠️ **Failure is not absence.** A listing that times out, is refused, or does not parse is an ERROR:
 * the row is left enrolled and reported unavailable with the reason, never treated as a vanished
 * pane. Only an answer from tmux that the server is not running, or a well-formed listing without
 * the pane, says the pane is gone — and even then nothing is removed; the person unenrolls.
 *
 * Managed discovery is untouched: panes in `harness-*` (or a pre-prefix `<engine>-<ms>`) session, or
 * held by any managed registry row, are refused here — they are Harness's own already.
 */
import { execFile } from 'node:child_process'
import { isHarnessSession, isLegacyHarnessSession } from './harnessSessionLabel.js'
import { isNoTmuxServerError } from './tmuxAgentDiscovery.js'
import { isExternallyOwned, managedTmuxPaneEngines, type ExternalTmuxOwnership } from './agentOwnership.js'
import type { RegisteredSession } from './registry.js'

/** The default server's incarnation as tmux reports it. */
export interface TmuxServerIdentity {
  socketPath: string
  /** `<server pid>:<server start time>` — changes when the server restarts, even on the same socket. */
  serverIdentity: string
}

export interface TmuxInventoryPane {
  paneId: string
  sessionName: string
  windowIndex: number
  paneIndex: number
  windowPanes: number
  windowName: string
  command: string
  cwd: string
}

export type FullTmuxInventory =
  | { ok: true; server: TmuxServerIdentity | null; panes: TmuxInventoryPane[] }
  | { ok: false; error: string }

/** Printable and never produced by tmux's own formats; free-text fields come last (see parse). */
const SEP = '|^|'
const FIELDS = [
  '#{pid}', '#{start_time}', '#{socket_path}', '#{pane_id}', '#{window_panes}', '#{window_index}', '#{pane_index}',
  '#{session_name}', '#{window_name}', '#{pane_current_command}', '#{pane_current_path}',
]
export const FULL_INVENTORY_FORMAT = FIELDS.join(SEP)
const TEXT_MAX = 200
const INVENTORY_TIMEOUT_MS = 2_000

function positiveInt(text: string, min: number): number | null {
  if (!/^\d{1,12}$/.test(text)) return null
  const value = Number(text)
  return Number.isSafeInteger(value) && value >= min ? value : null
}

function displayText(value: string): string {
  // eslint-disable-next-line no-control-regex
  return value.replace(/[\u0000-\u001f\u007f]/g, ' ').slice(0, TEXT_MAX)
}

/**
 * Parse `list-panes -a -F FULL_INVENTORY_FORMAT`. Strict: ANY line that does not parse, or a server
 * field that differs between lines, makes the whole answer an error — a half-read inventory would
 * report the panes it could not read as gone.
 */
export function parseFullInventory(stdout: string): FullTmuxInventory {
  let server: TmuxServerIdentity | null = null
  const panes: TmuxInventoryPane[] = []
  const seen = new Set<string>()
  for (const line of stdout.split('\n')) {
    if (!line) continue
    const parts = line.split(SEP)
    if (parts.length < FIELDS.length) return { ok: false, error: 'malformed tmux inventory line' }
    // The path is last and may itself contain the separator; everything before it may not.
    const cwd = parts.slice(FIELDS.length - 1).join(SEP)
    const [pid, start, socketPath, paneId, windowPanes, windowIndex, paneIndex, sessionName, windowName, command] = parts
    const counts = [positiveInt(pid, 1), positiveInt(start, 1), positiveInt(windowPanes, 1), positiveInt(windowIndex, 0), positiveInt(paneIndex, 0)]
    if (counts.some((value) => value === null)
      || !socketPath.startsWith('/') || socketPath.length > 1024
      || !/^%\d+$/.test(paneId) || seen.has(paneId)
      || !sessionName) {
      return { ok: false, error: 'malformed tmux inventory line' }
    }
    const identity = { socketPath, serverIdentity: `${pid}:${start}` }
    if (server && (server.socketPath !== identity.socketPath || server.serverIdentity !== identity.serverIdentity)) {
      return { ok: false, error: 'tmux inventory spans more than one server' }
    }
    server = identity
    seen.add(paneId)
    panes.push({
      paneId,
      sessionName: displayText(sessionName),
      windowIndex: counts[3]!,
      paneIndex: counts[4]!,
      windowPanes: counts[2]!,
      windowName: displayText(windowName),
      command: displayText(command),
      cwd: cwd.slice(0, 4096),
    })
  }
  return { ok: true, server, panes }
}

/**
 * tmux's answer when the default socket (or its `tmux-<uid>` directory) does not exist: nothing has
 * ever started a server there, which is "not running", not a failure to look. Permission and every
 * other connect error stay errors.
 */
const NO_SOCKET_RE = /error connecting to \S+ \(No such file or directory\)/

/** One bounded, read-only listing of every pane on the default server. */
export function readFullTmuxInventory(): Promise<FullTmuxInventory> {
  return new Promise((resolve) => {
    execFile('tmux', ['list-panes', '-a', '-F', FULL_INVENTORY_FORMAT], { timeout: INVENTORY_TIMEOUT_MS, maxBuffer: 4 * 1024 * 1024 },
      (error, stdout, stderr) => {
        if (error) {
          const message = `${String(stderr ?? '').trim()} ${error.message}`.trim()
          // tmux itself answering that no server runs is an answer, not a failure: no panes.
          if (isNoTmuxServerError(message) || NO_SOCKET_RE.test(message)) { resolve({ ok: true, server: null, panes: [] }); return }
          const code = (error as NodeJS.ErrnoException).code
          const killed = (error as { killed?: boolean }).killed
          resolve({ ok: false, error: code === 'ENOENT' ? 'tmux is not installed' : killed ? 'tmux did not answer in time' : message.slice(0, 200) })
          return
        }
        resolve(parseFullInventory(String(stdout)))
      })
  })
}

export type ExternalPaneState = 'available' | 'enrolled' | 'managed' | 'shared_window'

export interface ExternalPaneCandidate extends TmuxInventoryPane {
  state: ExternalPaneState
  /** The enrolled row, when `state === 'enrolled'`. */
  agentId?: string
}

/** Why an enrolled pane cannot be opened right now; null when it can. */
export type ExternalUnavailableReason =
  | 'TMUX_INVENTORY_FAILED'
  | 'TMUX_SERVER_NOT_RUNNING'
  | 'TMUX_SOCKET_CHANGED'
  | 'TMUX_SERVER_RESTARTED'
  | 'TMUX_PANE_GONE'
  | 'TMUX_PANE_MANAGED'
  | 'TMUX_PANE_SHARED_WINDOW'
  | 'NOT_CHECKED'

export interface ExternalPaneStatus {
  available: boolean
  reason: ExternalUnavailableReason | null
  /** What the pane is, as last seen live; absent until it has been. */
  sessionName?: string
  windowIndex?: number
  paneIndex?: number
  windowName?: string
  command?: string
}

const REASON_TEXT: Record<ExternalUnavailableReason, string> = {
  TMUX_INVENTORY_FAILED: 'tmux could not be read on this machine',
  TMUX_SERVER_NOT_RUNNING: 'the tmux server is not running',
  TMUX_SOCKET_CHANGED: 'the daemon now reaches a different tmux server',
  TMUX_SERVER_RESTARTED: 'the tmux server restarted since this pane was added',
  TMUX_PANE_GONE: 'the pane has closed',
  TMUX_PANE_MANAGED: 'the pane now belongs to a Harness session',
  TMUX_PANE_SHARED_WINDOW: 'the pane shares its window with other panes',
  NOT_CHECKED: 'not checked yet',
}

export function externalReasonText(reason: ExternalUnavailableReason | null): string | null {
  return reason ? REASON_TEXT[reason] : null
}

function ownershipOf(row: RegisteredSession): ExternalTmuxOwnership | null {
  return isExternallyOwned(row) && row.ownership?.kind === 'external' ? row.ownership : null
}

function isManagedName(sessionName: string): boolean {
  return isHarnessSession(sessionName) || isLegacyHarnessSession(sessionName)
}

/** Whether a live pane is Harness's own: its session is named as one, or a managed row holds its id. */
function managedPane(pane: TmuxInventoryPane, managedIds: ReadonlySet<string>): boolean {
  return isManagedName(pane.sessionName) || managedIds.has(pane.paneId)
}

/** A row's status against one inventory read. Pure, so every rule is testable without tmux. */
export function statusAgainst(
  ownership: ExternalTmuxOwnership,
  inventory: FullTmuxInventory,
  managedIds: ReadonlySet<string>,
): ExternalPaneStatus {
  if (!inventory.ok) return { available: false, reason: 'TMUX_INVENTORY_FAILED' }
  if (!inventory.server) return { available: false, reason: 'TMUX_SERVER_NOT_RUNNING' }
  if (inventory.server.socketPath !== ownership.socketPath) return { available: false, reason: 'TMUX_SOCKET_CHANGED' }
  // Checked before the pane: on a restarted server `%N` may exist again and be someone else's.
  if (inventory.server.serverIdentity !== ownership.serverIdentity) return { available: false, reason: 'TMUX_SERVER_RESTARTED' }
  const pane = inventory.panes.find((candidate) => candidate.paneId === ownership.paneId)
  if (!pane) return { available: false, reason: 'TMUX_PANE_GONE' }
  const seen = {
    sessionName: pane.sessionName, windowIndex: pane.windowIndex, paneIndex: pane.paneIndex,
    windowName: pane.windowName, command: pane.command,
  }
  if (managedPane(pane, managedIds)) return { available: false, reason: 'TMUX_PANE_MANAGED', ...seen }
  if (pane.windowPanes !== 1) return { available: false, reason: 'TMUX_PANE_SHARED_WINDOW', ...seen }
  return { available: true, reason: null, ...seen }
}

/** Every live pane with what Harness may do with it. */
export function classifyPanes(
  inventory: Extract<FullTmuxInventory, { ok: true }>,
  rows: readonly RegisteredSession[],
): ExternalPaneCandidate[] {
  const managedIds = new Set(managedTmuxPaneEngines(rows).keys())
  const enrolled = new Map<string, string>()
  if (inventory.server) {
    for (const row of rows) {
      const ownership = ownershipOf(row)
      if (ownership && ownership.socketPath === inventory.server.socketPath
        && ownership.serverIdentity === inventory.server.serverIdentity) enrolled.set(ownership.paneId, row.agentId)
    }
  }
  return inventory.panes.map((pane) => {
    if (managedPane(pane, managedIds)) return { ...pane, state: 'managed' as const }
    const agentId = enrolled.get(pane.paneId)
    if (agentId) return { ...pane, state: 'enrolled' as const, agentId }
    if (pane.windowPanes !== 1) return { ...pane, state: 'shared_window' as const }
    return { ...pane, state: 'available' as const }
  })
}

export interface ExternalRegistry {
  list(): RegisteredSession[]
  byAgent(agentId: string): RegisteredSession | undefined
  enrollExternal(input: { ownership: ExternalTmuxOwnership; cwd: string | null; name: string }): RegisteredSession | null
  unenrollExternal(agentId: string): boolean
}

export interface ExternalTmuxControllerDeps {
  registry: ExternalRegistry
  readInventory?: () => Promise<FullTmuxInventory>
  /** A row's status changed (or it was just enrolled): push its frame. */
  onChanged: (row: RegisteredSession) => void
  /** A row was unenrolled: close its streams, tell clients it is gone. Never touches tmux. */
  onRemoved: (agentId: string) => Promise<void> | void
  log?: (message: string) => void
}

export type ExternalRefusal = { ok: false; error: string; detail: string }
export type ExternalListResult =
  | { ok: true; server: TmuxServerIdentity | null; panes: ExternalPaneCandidate[] }
  | ExternalRefusal
export type ExternalEnrollResult = { ok: true; agent: RegisteredSession; alreadyEnrolled: boolean } | ExternalRefusal
export type ExternalVerifyResult = { ok: true } | { ok: false; reason: ExternalUnavailableReason; detail: string }

const PANE_RE = /^%\d+$/
const IDENTITY_RE = /^\d{1,12}:\d{1,12}$/

export class ExternalTmuxController {
  private readonly statuses = new Map<string, ExternalPaneStatus>()
  private readonly readInventory: () => Promise<FullTmuxInventory>
  /** Enroll and unenroll run one at a time, so two clicks never race to two rows for one pane. */
  private tail: Promise<unknown> = Promise.resolve()

  constructor(private readonly deps: ExternalTmuxControllerDeps) {
    this.readInventory = deps.readInventory ?? readFullTmuxInventory
  }

  private serial<T>(operation: () => Promise<T>): Promise<T> {
    const next = this.tail.then(operation, operation)
    this.tail = next.catch(() => undefined)
    return next
  }

  /** The last known status; a row not yet checked is unavailable, never assumed openable. */
  status(agentId: string): ExternalPaneStatus {
    return this.statuses.get(agentId) ?? { available: false, reason: 'NOT_CHECKED' }
  }

  rows(): RegisteredSession[] {
    return this.deps.registry.list().filter((row) => ownershipOf(row) !== null)
  }

  /** Re-derive every enrolled row's status from one inventory read; push the ones that changed. */
  private apply(inventory: FullTmuxInventory): void {
    const rows = this.deps.registry.list()
    const managedIds = new Set(managedTmuxPaneEngines(rows).keys())
    for (const row of rows) {
      const ownership = ownershipOf(row)
      if (!ownership) continue
      const previous = this.statuses.get(row.agentId)
      const next = statusAgainst(ownership, inventory, managedIds)
      // An inventory error keeps what was last seen of the pane (it did not change; it went unread).
      const merged = next.reason === 'TMUX_INVENTORY_FAILED' && previous
        ? { ...previous, available: false, reason: next.reason }
        : next
      this.statuses.set(row.agentId, merged)
      if (!previous || JSON.stringify(previous) !== JSON.stringify(merged)) this.deps.onChanged(row)
    }
    for (const agentId of [...this.statuses.keys()]) {
      const row = this.deps.registry.byAgent(agentId)
      if (!row || !ownershipOf(row)) this.statuses.delete(agentId)
    }
  }

  /** Boot and on demand: statuses only. Never recreates, renames or removes anything. */
  async refresh(): Promise<void> {
    if (!this.rows().length) return
    const inventory = await this.readInventory()
    if (!inventory.ok) this.deps.log?.(`[external-tmux] inventory failed: ${inventory.error}`)
    this.apply(inventory)
  }

  async list(): Promise<ExternalListResult> {
    const inventory = await this.readInventory()
    this.apply(inventory)
    if (!inventory.ok) return { ok: false, error: 'TMUX_INVENTORY_FAILED', detail: inventory.error }
    return { ok: true, server: inventory.server, panes: classifyPanes(inventory, this.deps.registry.list()) }
  }

  /**
   * Enroll one pane. `serverIdentity` is the one the client's listing showed: a server that
   * restarted between the listing and this click is refused, so a reused `%N` is never enrolled in
   * the listed pane's place.
   */
  enroll(paneId: unknown, serverIdentity: unknown): Promise<ExternalEnrollResult> {
    return this.serial(async () => {
      if (typeof paneId !== 'string' || !PANE_RE.test(paneId)
        || typeof serverIdentity !== 'string' || !IDENTITY_RE.test(serverIdentity)) {
        return { ok: false, error: 'INVALID_PANE', detail: 'tmux_pane_enroll needs paneId (%N) and serverIdentity from tmux_panes_list' }
      }
      const inventory = await this.readInventory()
      this.apply(inventory)
      if (!inventory.ok) return { ok: false, error: 'TMUX_INVENTORY_FAILED', detail: inventory.error }
      if (!inventory.server) return { ok: false, error: 'TMUX_SERVER_NOT_RUNNING', detail: REASON_TEXT.TMUX_SERVER_NOT_RUNNING }
      if (inventory.server.serverIdentity !== serverIdentity) {
        return { ok: false, error: 'TMUX_SERVER_CHANGED', detail: 'The tmux server restarted since the list was read. List the panes again.' }
      }
      const candidate = classifyPanes(inventory, this.deps.registry.list()).find((pane) => pane.paneId === paneId)
      if (!candidate) return { ok: false, error: 'TMUX_PANE_NOT_FOUND', detail: `${paneId} is not open on this machine's tmux server` }
      if (candidate.state === 'managed') {
        return { ok: false, error: 'TMUX_PANE_MANAGED', detail: `${paneId} is already a Harness terminal` }
      }
      if (candidate.state === 'shared_window') {
        return { ok: false, error: 'TMUX_PANE_SHARED_WINDOW', detail: `${paneId} shares its window with other panes; Harness can only open a pane that has its window to itself` }
      }
      if (candidate.state === 'enrolled') {
        const existing = this.deps.registry.byAgent(candidate.agentId!)
        if (existing) return { ok: true, agent: existing, alreadyEnrolled: true }
      }
      const agent = this.deps.registry.enrollExternal({
        ownership: { kind: 'external', backend: 'tmux', socketPath: inventory.server.socketPath, serverIdentity: inventory.server.serverIdentity, paneId },
        cwd: candidate.cwd || null,
        name: `${candidate.sessionName}:${candidate.windowIndex}.${candidate.paneIndex}`,
      })
      if (!agent) return { ok: false, error: 'ENROLL_REFUSED', detail: 'The registry refused the enrollment (it is read-only, or the pane is already held).' }
      this.apply(inventory)
      return { ok: true, agent, alreadyEnrolled: false }
    })
  }

  /** Forget an enrollment. Closes Harness's own views of it; the pane and its processes are untouched. */
  unenroll(agentId: unknown): Promise<{ ok: true } | ExternalRefusal> {
    return this.serial(async () => {
      const row = typeof agentId === 'string' ? this.deps.registry.byAgent(agentId) : undefined
      if (!row) return { ok: false, error: 'AGENT_NOT_FOUND', detail: 'No such terminal on this machine.' }
      if (!ownershipOf(row)) return { ok: false, error: 'NOT_EXTERNAL', detail: 'Only a tmux pane added from this machine can be removed this way.' }
      if (!this.deps.registry.unenrollExternal(row.agentId)) {
        return { ok: false, error: 'UNENROLL_REFUSED', detail: 'The registry refused the change (it is read-only).' }
      }
      this.statuses.delete(row.agentId)
      await this.deps.onRemoved(row.agentId)
      return { ok: true }
    })
  }

  /**
   * Before a stream opens: the live default server is the enrolled incarnation, the pane is on it,
   * it is not Harness's own, and it has its window to itself. A failed read is a refusal too.
   */
  async verify(row: RegisteredSession): Promise<ExternalVerifyResult> {
    const ownership = ownershipOf(row)
    if (!ownership) return { ok: false, reason: 'TMUX_PANE_GONE', detail: 'not an enrolled tmux pane' }
    const inventory = await this.readInventory()
    this.apply(inventory)
    const status = statusAgainst(ownership, inventory, new Set(managedTmuxPaneEngines(this.deps.registry.list()).keys()))
    if (status.available) return { ok: true }
    const reason = status.reason ?? 'TMUX_PANE_GONE'
    return { ok: false, reason, detail: REASON_TEXT[reason] }
  }
}
