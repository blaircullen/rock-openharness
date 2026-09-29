/**
 * The tmux session-name convention for agent panes this daemon itself creates via `agent_create`
 * (`createAgentPane.ts`).
 *
 * Discovery uses `isHarnessSession` as a whitelist (`TmuxBackend.inventory()`): a tmux pane whose
 * session isn't named this way is invisible to the daemon, whether it's a session the user opened
 * by hand or one an agent spawned itself with a nested `tmux new-session` — neither went through
 * `agent_create`, so neither should ever appear as a discovered agent (issue autonomous-harness-desktop#6).
 */
export const HARNESS_SESSION_PREFIX = 'harness-'

export function buildHarnessSessionLabel(engine: string, now: number = Date.now()): string {
  return `${HARNESS_SESSION_PREFIX}${engine}-${now}`.replace(/[^A-Za-z0-9_-]/g, '-')
}

export function isHarnessSession(sessionName: string): boolean {
  return sessionName.startsWith(HARNESS_SESSION_PREFIX)
}

/** Whether a harness session was created FOR this engine — `harness-<engine>-<ts>` — rather than another. */
export function isHarnessSessionFor(sessionName: string, engine: string): boolean {
  return sessionName.startsWith(`${HARNESS_SESSION_PREFIX}${engine}-`)
}

/**
 * The label a build before the prefix (2026-08-29, `80a354e4`) gave the very same sessions:
 * `<engine>-<ms>`. A pane under one of these came through `agent_create` like any other, yet is
 * invisible to `isHarnessSession` — the daemon renames it on startup (`adoptLegacyHarnessSessions`)
 * rather than teaching discovery a second convention. The 13-digit millisecond stamp is what keeps
 * a user's own `work` or `claude-notes` session from matching.
 */
export function isLegacyHarnessSession(sessionName: string): boolean {
  return !isHarnessSession(sessionName) && /^[a-z][a-z0-9]*-\d{13}$/.test(sessionName)
}

/**
 * The throwaway tmux session a stream onto a BORROWED pane attaches through (tmuxStream.ts,
 * `createBorrowedView`): `harness_view-<daemon pid>-<n>-<random>`, grouped with the person's own
 * session so it shares their windows but keeps its own current window. Attaching there instead of to
 * the pane leaves the person's current window and active pane exactly as they were.
 *
 * Deliberately NOT under `harness-`: nothing in one is an agent, and its panes are the person's, so
 * managed discovery (`isHarnessSession`) must never see it. Every full pane listing skips it too —
 * `list-panes -a` lists a grouped session's panes a second time under its name.
 */
export const BORROWED_VIEW_SESSION_PREFIX = 'harness_view-'
const BORROWED_VIEW_RE = /^harness_view-(\d{1,10})-\d{1,12}-[0-9a-f]{8}$/

export function isBorrowedViewSession(sessionName: string): boolean {
  return BORROWED_VIEW_RE.test(sessionName)
}

/** The pid of the daemon that made a view session; null for any other name. */
export function borrowedViewOwnerPid(sessionName: string): number | null {
  const match = BORROWED_VIEW_RE.exec(sessionName)
  return match ? Number(match[1]) : null
}
