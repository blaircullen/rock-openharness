/**
 * Who owns the terminal behind a registry row.
 *
 * Every row so far is MANAGED: Harness created its pane (or discovered it inside a session Harness
 * named) and may kill, respawn, recreate, archive and retire it. A future picker will let a person
 * borrow a pane Harness did not create. That row is EXTERNAL, and the whole point of the field is
 * the list of things Harness must then never do to it: stop it, restart it, resume over it,
 * recreate it after a reboot, retire it on a discovery miss, or turn it into an engine agent.
 *
 * Absent means managed — every row written before this field existed is one. A present value that is
 * not exactly one of the shapes below is never read as managed: the registry refuses to load or
 * overwrite a file carrying one (`strictPersistedRow`), and `isExternallyOwned` answers true for it.
 *
 * ⚠️ **Quarantined, not routable.** Every terminal route this daemon has (`terminalRouteKey`, the
 * registry's runtime index, stream placements and control leases) is a bare pane id on the ONE default
 * tmux server. An external claim names a socket and a server incarnation that namespace cannot express,
 * so an external row is held out of all of it: it is never indexed by route, process or session, never
 * streamed, typed into, renamed or leased, and a managed pane that reuses its pane id is unaffected.
 * Endpoint-aware routing has to exist before any of that may change.
 *
 * ⚠️ **Downgrade guard, and its floor.** An external row is persisted as `schemaVersion: 3`
 * (`EXTERNAL_ROW_SCHEMA_VERSION`). Builds that have the v2 registry but not this field — from commit
 * d04c6a8b (2026-08-16) up to this one — rebuild each v2 row from an explicit field list and would
 * silently drop `ownership`, reading the borrowed pane as a managed one they may kill or respawn.
 * Those builds refuse any row whose schemaVersion is present and not 2 (`hasUnknownRowSchema` blocks
 * the whole registry file read-only; the stopped-agent archive reader, which exists from 7908ee37,
 * returns nothing), so a downgrade to one of them fails closed. Managed and legacy rows stay v2.
 *
 * NOT covered: builds from before d04c6a8b have no schema check at all. Their loader reads every row,
 * ignores `schemaVersion`, and maps an engine it does not know (`terminal`) to `claude`, so an external
 * row would load there as a managed agent. That commit is the compatibility floor; a rollback below it
 * (reinstalling an older release by hand, for instance) is outside what this version bump can guard.
 */
import { isTerminalEngine, type AgentEngine } from '../engines/types.js'
import type { TerminalRuntimeRef } from './terminalTypes.js'

/**
 * A tmux pane Harness borrowed rather than created. Enough to prove, later, that a pane is still the
 * one that was borrowed: a pane id is only unique within one tmux server, and a restarted server
 * hands the same ids out again.
 */
export interface ExternalTmuxOwnership {
  kind: 'external'
  backend: 'tmux'
  /** Absolute path of the tmux server socket the pane was enrolled from, as configured. */
  socketPath: string
  /** Identity of that server's incarnation (for example its pid and start time) at enrollment. */
  serverIdentity: string
  /** The exact pane id at enrollment. Must equal the row's one tmux runtime. */
  paneId: string
}

export type AgentOwnership = { kind: 'managed' } | ExternalTmuxOwnership

/** Every managed (and explicitly `{kind:'managed'}`) row. */
export const MANAGED_ROW_SCHEMA_VERSION = 2
/** Only an external row, so a build that cannot read `ownership` refuses it — see the ⚠️ above. */
export const EXTERNAL_ROW_SCHEMA_VERSION = 3

/** The schemaVersion a row must be persisted with. */
export function persistedSchemaVersion(row: { ownership?: unknown }): 2 | 3 {
  return isExternallyOwned(row) ? EXTERNAL_ROW_SCHEMA_VERSION : MANAGED_ROW_SCHEMA_VERSION
}

export const EXTERNAL_PANE = 'EXTERNAL_PANE'
export const EXTERNAL_PANE_DETAIL = 'This terminal belongs to a tmux session Harness did not create. Harness will not open, type into, rename, stop, restart, resume or relaunch it.'

/** `terminal_error` code for a `terminal_open` naming an external row: it has no routable terminal. */
export const EXTERNAL_TERMINAL_UNAVAILABLE = 'TERMINAL_EXTERNAL_UNAVAILABLE'

/** The refusal every lifecycle entry point answers an external row with, before any side effect. */
export const externalPaneRefused = { ok: false, error: EXTERNAL_PANE, detail: EXTERNAL_PANE_DETAIL } as const

/** Thrown by entry points whose contract is a rejected promise (stop/delete). */
export class ExternalPaneError extends Error {
  readonly code = EXTERNAL_PANE
  constructor() { super(EXTERNAL_PANE_DETAIL) }
}

const PANE_RE = /^%\d+$/
const MAX_PART = 1024

function boundedPart(value: unknown, max = MAX_PART): value is string {
  return typeof value === 'string' && value.length > 0 && value.length <= max && !/[\u0000-\u001f\u007f]/.test(value)
}

/** Exactly one of the persisted shapes, with no extra keys. Anything else is malformed. */
export function validOwnership(value: unknown): value is AgentOwnership {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false
  const keys = Object.keys(value).sort().join(',')
  const v = value as Record<string, unknown>
  if (v.kind === 'managed') return keys === 'kind'
  return v.kind === 'external'
    && keys === 'backend,kind,paneId,serverIdentity,socketPath'
    && v.backend === 'tmux'
    && boundedPart(v.socketPath) && v.socketPath.startsWith('/')
    && boundedPart(v.serverIdentity, 200)
    && typeof v.paneId === 'string' && PANE_RE.test(v.paneId)
}

/**
 * Whether a row's ownership fits the row. External is only valid on a terminal whose one tmux
 * runtime is the enrolled pane: an engine row cannot be borrowed, and a row whose route drifted from
 * the pane it was enrolled for is no longer describing that pane. It carries no engine session and no
 * process identity either: both are indexes an external row is kept out of.
 */
export function ownershipFitsRow(
  ownership: unknown,
  row: { engine: AgentEngine; runtimes: readonly TerminalRuntimeRef[]; sessionId?: unknown; processIdentity?: unknown },
): boolean {
  if (!validOwnership(ownership)) return false
  if (ownership.kind === 'managed') return true
  return isTerminalEngine(row.engine)
    && row.runtimes.length === 1
    && row.runtimes[0].backend === 'tmux'
    && row.runtimes[0].paneId === ownership.paneId
    && (row.sessionId === undefined || row.sessionId === '')
    && (row.processIdentity === undefined || row.processIdentity === null)
}

/** The endpoint an external claim names: unique among external rows, and never a managed route. */
export function externalEndpointKey(ownership: ExternalTmuxOwnership): string {
  return JSON.stringify([ownership.socketPath, ownership.serverIdentity, ownership.paneId])
}

/** Key-order-independent JSON: objects by sorted key, recursively. For comparing, never for writing. */
function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`
  if (value && typeof value === 'object') {
    const entries = Object.keys(value).sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson((value as Record<string, unknown>)[key])}`)
    return `{${entries.join(',')}}`
  }
  return JSON.stringify(value) ?? 'undefined'
}

/**
 * Whether two stored ownership values make the same claim. Semantic, not textual: key order never
 * matters (another writer may serialize the same claim in a different order), and an absent field is
 * the same claim as an explicit `{kind:'managed'}`. A malformed value is compared structurally, so it
 * only ever equals itself — never a valid claim.
 */
export function sameOwnership(a: unknown, b: unknown): boolean {
  const normal = (value: unknown): unknown => value === undefined ? { kind: 'managed' } : value
  return canonicalJson(normal(a)) === canonicalJson(normal(b))
}

/** A copy of a valid ownership, so a persisted object is never shared with the in-memory row. */
export function copyOwnership(ownership: AgentOwnership): AgentOwnership {
  return ownership.kind === 'managed' ? { kind: 'managed' } : { ...ownership }
}

/**
 * True for anything that is not managed. Fails closed: a present value that is not `{kind:'managed'}`
 * — external, or malformed — is treated as not Harness's to act on.
 */
export function isExternallyOwned(row: { ownership?: unknown } | null | undefined): boolean {
  if (!row || row.ownership === undefined) return false
  return !(validOwnership(row.ownership) && row.ownership.kind === 'managed')
}

type RowRoutes = { ownership?: unknown; engine: AgentEngine; runtimes: readonly TerminalRuntimeRef[] }

/** Pane id → engine for every MANAGED row's tmux runtime. What startup may rename a legacy session for. */
export function managedTmuxPaneEngines(rows: readonly RowRoutes[]): Map<string, AgentEngine> {
  return new Map(rows.filter((row) => !isExternallyOwned(row)).flatMap((row) => row.runtimes
    .flatMap((runtime) => runtime.backend === 'tmux' ? [[runtime.paneId, row.engine] as const] : [])))
}

/**
 * Pane ids an external row claims and no managed row holds. Discovery must not mutate such a pane
 * (`mouse on`): it may be the borrowed pane itself. A managed row on the same id wins — that id on
 * the default server is Harness's own pane, which the bare id cannot tell apart from the borrowed one.
 */
export function externalOnlyTmuxPanes(rows: readonly RowRoutes[]): Set<string> {
  const managed = managedTmuxPaneEngines(rows)
  return new Set(rows.filter((row) => isExternallyOwned(row)).flatMap((row) => row.runtimes
    .flatMap((runtime) => runtime.backend === 'tmux' && !managed.has(runtime.paneId) ? [runtime.paneId] : [])))
}
