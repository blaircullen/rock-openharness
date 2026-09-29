import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { ROCK_FORK_BUILD, forkUpdateRefusal } from './fork.js'

const cliSource = readFileSync(join(import.meta.dirname, 'cli.ts'), 'utf8')

describe('Rock OpenHarness fork build', () => {
  it('is a fork build', () => {
    expect(ROCK_FORK_BUILD).toBe(true)
  })

  it('the daemon never starts the background self-updater in a fork build', () => {
    const call = cliSource.indexOf('startSelfUpdater({')
    const gate = cliSource.lastIndexOf('\n  if (', call)
    expect(cliSource.slice(gate, call)).toContain('if (!ROCK_FORK_BUILD && isInstalledCopy && !env.ADAPTER_UPDATE_DISABLE)')
  })

  it('`harness update` refuses a fork build without --force and goes ahead with it', () => {
    const lines = forkUpdateRefusal('1.2.27-dev.abc1234', false)
    expect(lines?.join('\n')).toContain('Rock OpenHarness')
    expect(lines?.join('\n')).toContain('harness update --force')
    expect(forkUpdateRefusal('1.2.27-dev.abc1234', true)).toBeNull()
    expect(forkUpdateRefusal('1.2.27', false, false)).toBeNull()
  })

  it('updateCommand asks the fork rule before anything is fetched', () => {
    const start = cliSource.indexOf('async function updateCommand(')
    const refusal = cliSource.indexOf('forkUpdateRefusal(VERSION, force)', start)
    const fetch = cliSource.indexOf('fetchManifest(', start)
    expect(refusal).toBeGreaterThan(start)
    expect(refusal).toBeLessThan(fetch)
  })
})
