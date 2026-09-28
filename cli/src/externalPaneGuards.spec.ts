import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

/**
 * Restart, retarget and fork are closures inside `runForeground`, wired to tmux, the reconciler and
 * the registry, so they cannot be called without a daemon. What makes them safe for a borrowed
 * (external) pane is ORDER: the refusal has to come before the first thing that holds, reads, kills,
 * respawns or writes. A later edit that adds a side effect above the guard would type-check and pass
 * every unit test. So the order is asserted on the source, as startupOrder.spec.ts does for boot.
 *
 * The kill/respawn layer has its own gate (`managedOnlySwapDeps`, tested in restartAgent.spec.ts);
 * the last two tests pin that cli.ts actually routes every pane swap through it.
 */
const SOURCE = readFileSync(join(import.meta.dirname, 'cli.ts'), 'utf-8')

/** From `start` to its closing line at `runForeground`'s own two-space indent (`}` or `})`, possibly
 *  followed by more arguments), inclusive of that line. */
function handler(start: string): string {
  const from = SOURCE.indexOf(start)
  expect(from, `cli.ts still defines ${start}`).toBeGreaterThan(-1)
  const close = /\n {2}\}[^\n]*/g
  close.lastIndex = from + start.length
  const end = close.exec(SOURCE)
  return SOURCE.slice(from, end ? end.index + end[0].length : SOURCE.length)
}

/** Calls that hold, read, signal, respawn or write something. `!tmuxBackend` alone is not one. */
const SIDE_EFFECTS = [
  'tmuxBackend.', 'restartJobs.run(', 'restartAgent(', 'paneSwapDeps(', 'captureTerminal(',
  'acquireTerminalControl(', 'holdRoute(', 'clearEnv(', 'setOpencodeSessionModel(', 'relaunchOverrides(',
  'statSync(', 'prepareSessionResume(', 'backend.create(', 'onCreateAgent',
]

function firstSideEffect(body: string): { token: string; at: number } {
  const hits = SIDE_EFFECTS.map((token) => ({ token, at: body.indexOf(token) })).filter((hit) => hit.at >= 0)
  expect(hits.length, 'the handler still does something the guard has to precede').toBeGreaterThan(0)
  return hits.reduce((a, b) => (b.at < a.at ? b : a))
}

describe('external rows are refused before any side effect', () => {
  it.each([
    ['backend.onRestartAgent = '],
    ['backend.onRetargetAgent = '],
    ['backend.onForkAgent = '],
  ])('%s', (start) => {
    const body = handler(start)
    const guard = body.indexOf('isExternallyOwned(')
    const refusal = body.indexOf('externalPaneRefused')
    const first = firstSideEffect(body)
    expect(guard, `${start} checks ownership`).toBeGreaterThan(-1)
    expect(refusal, `${start} answers with the external refusal`).toBeGreaterThan(guard)
    expect(refusal, `${start}: ${first.token} runs before the refusal`).toBeLessThan(first.at)
  })

  it('retarget re-checks ownership after its awaits and before any pane mutation', () => {
    const body = handler('backend.onRetargetAgent = ')
    const recheck = body.indexOf('isExternallyOwned(registry.byAgent(session.agentId))')
    expect(recheck).toBeGreaterThan(body.indexOf('relaunchOverrides('))
    for (const mutation of ['holdRoute(', 'setOpencodeSessionModel(', 'clearEnv(', 'restartAgent(']) {
      expect(recheck, `${mutation} precedes the re-check`).toBeLessThan(body.indexOf(mutation))
    }
  })

  it('every pane swap goes through the kill/respawn gate', () => {
    const deps = handler('const paneSwapDeps = ')
    expect(deps).toMatch(/: RestartAgentDeps => managedOnlySwapDeps\(\{/)
    expect(deps).toContain('}, () => !isExternallyOwned(registry.byAgent(session.agentId)))')
  })

  it('an external row is never the same restart target', () => {
    expect(handler('const sameRestartTarget = ')).toContain('!isExternallyOwned(current)')
  })
})
