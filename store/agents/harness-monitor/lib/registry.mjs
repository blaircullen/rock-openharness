/**
 * The daemon's own registry file, read directly.
 *
 * Two things the wire does not carry are in here: the path to each agent's transcript (a file path is
 * not something the daemon hands to clients, and rightly) and the hook timestamps it records at turn
 * boundaries. Both are needed to tell a five-day-old conversation from a busy one, so Harness Monitor reads the
 * file — never writes it. The registry is the daemon's; this is a reader with no lock and no repair.
 *
 * It is also the fallback when the daemon cannot be reached at all: a fleet you can still SEE when the
 * app is not running is worth more than an error, and pausing is pure tmux, so most of Harness Monitor keeps
 * working from this file alone.
 */

import { readFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join } from 'node:path'

export function registryPath(env = process.env) {
  return env.HPS_REGISTRY || join(env.HARNESS_HOME || join(homedir(), '.harness'), 'cli', 'data', 'registry.json')
}

/**
 * Whether Harness Monitor may treat a row as one of Harness's own panes. Only a legacy row (no
 * schemaVersion) or a v2 row with no ownership claim — or exactly `{kind:'managed'}` — qualifies.
 *
 * A row the daemon marks as borrowed is written as `schemaVersion: 3` with an `ownership` block
 * (cli/src/lib/agentOwnership.ts). Its `tmuxPane` names a pane on ANOTHER tmux server, so on this
 * machine's default server the same id is a stranger's pane — or one of Harness's own. Looking it up,
 * pausing it or typing a resume into it would act on the wrong pane. Fails closed: any other schema
 * version, or any ownership value that is not exactly managed, is skipped too.
 */
export function isManagedRegistryRow(row) {
  if (!row || typeof row !== 'object') return false
  if (Object.hasOwn(row, 'schemaVersion') && row.schemaVersion !== 2) return false
  if (!Object.hasOwn(row, 'ownership')) return true
  const own = row.ownership
  return !!own && typeof own === 'object' && !Array.isArray(own)
    && own.kind === 'managed' && Object.keys(own).length === 1
}

/** `{ byId, rows }`, or an empty pair when there is no registry to read (a machine that has never run
 *  an agent, or a daemon whose data lives somewhere this user cannot see). Borrowed rows are dropped
 *  here, before anything can look up or act on their pane (`isManagedRegistryRow`). */
export async function readRegistry(env = process.env) {
  let parsed
  try { parsed = JSON.parse(await readFile(registryPath(env), 'utf8')) }
  catch { return { byId: new Map(), rows: [] } }
  const rows = (Array.isArray(parsed) ? parsed : [])
    .filter((row) => row && typeof row.agentId === 'string' && isManagedRegistryRow(row))
  return { byId: new Map(rows.map((row) => [row.agentId, row])), rows }
}

/** The registry row in the shape `mergeRows` takes, for the no-daemon path. Deliberately lossy: no
 *  model, no branch, no verdict — the things only the daemon computes are absent rather than faked. */
export function registryAsFrames(rows) {
  // Filtered again: a caller that did not come through `readRegistry` must not get a borrowed pane id.
  return rows.filter(isManagedRegistryRow).map((row) => ({
    id: row.agentId,
    sessionId: row.sessionId ?? null,
    name: row.title || row.projectDir || row.agentId.slice(0, 8),
    title: row.title ?? null,
    status: row.active ? 'active' : 'offline',
    createdAt: new Date(row.registeredAt ?? Date.now()).toISOString(),
    updatedAt: new Date(row.lastHookAt ?? row.registeredAt ?? Date.now()).toISOString(),
    tmuxPane: row.tmuxPane ?? null,
    terminal: { available: true, primary: row.primaryRuntimeKey ?? '', runtimes: row.runtimes ?? [] },
    engine: row.engine,
    selectedModel: row.model ?? null,
    project: row.cwd ? { name: row.projectDir || '', cwd: row.cwd, root: null, remote: null, branch: null } : null,
    dsh: row.dsh?.id ?? null,
    dshName: null,
    verdict: null,
    codexHome: row.codexHome ?? null,
  }))
}
