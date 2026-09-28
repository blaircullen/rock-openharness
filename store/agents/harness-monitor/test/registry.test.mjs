import assert from 'node:assert/strict'
import { test } from 'node:test'
import { writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { isManagedRegistryRow, readRegistry, registryAsFrames } from '../lib/registry.mjs'
import { mergeRows } from '../lib/inventory.mjs'
import { pane, table } from './fixtures.mjs'

const managed = {
  schemaVersion: 2, agentId: 'm1', sessionId: 's1', engine: 'claude', active: true, tmuxPane: '%1',
  runtimes: [{ backend: 'tmux', paneId: '%1' }], primaryRuntimeKey: 'tmux/%1', registeredAt: 1,
}
// Borrowed from another tmux server. Its `%7` means nothing on this machine's default server.
const external = {
  schemaVersion: 3, agentId: 'x1', sessionId: '', engine: 'terminal', active: true, tmuxPane: '%7',
  runtimes: [{ backend: 'tmux', paneId: '%7' }], primaryRuntimeKey: 'tmux/%7', registeredAt: 1,
  ownership: { kind: 'external', backend: 'tmux', socketPath: '/tmp/other.sock', serverIdentity: 'pid:9', paneId: '%7' },
}

test('only legacy and plain v2 rows are managed; v3 and any ownership claim are skipped', () => {
  assert.equal(isManagedRegistryRow(managed), true)
  assert.equal(isManagedRegistryRow({ ...managed, ownership: { kind: 'managed' } }), true)
  const { schemaVersion: _v, ...legacy } = managed
  assert.equal(isManagedRegistryRow(legacy), true)
  assert.equal(isManagedRegistryRow(external), false)
  // Fails closed on shapes a newer daemon might write, or a hand edit.
  assert.equal(isManagedRegistryRow({ ...external, schemaVersion: 2 }), false)
  assert.equal(isManagedRegistryRow({ ...managed, schemaVersion: 3 }), false)
  assert.equal(isManagedRegistryRow({ ...managed, schemaVersion: 4 }), false)
  assert.equal(isManagedRegistryRow({ ...managed, ownership: null }), false)
  assert.equal(isManagedRegistryRow({ ...managed, ownership: { kind: 'managed', extra: 1 } }), false)
})

test('daemon-down fallback never looks up or reports a borrowed pane', async () => {
  const file = join(process.env.HARNESS_MONITOR_TEST_ROOT, 'registry.json')
  writeFileSync(file, JSON.stringify([managed, external]))
  const registry = await readRegistry({ HPS_REGISTRY: file })
  assert.deepEqual(registry.rows.map((row) => row.agentId), ['m1'])
  assert.equal(registry.byId.has('x1'), false)

  // Even with a live `%7` on this machine's tmux, the offline inventory has no row for it.
  const paneRows = new Map([['%1', pane()], ['%7', pane({ pane: '%7', session: 'someone-else' })]])
  const rows = mergeRows(registryAsFrames(registry.rows), { paneRows, table: table(), machine: null, local: true, registry: registry.byId })
  assert.deepEqual(rows.map((row) => row.id), ['m1'])
  assert.ok(rows.every((row) => row.pane !== '%7'))

  // A caller that skips `readRegistry` is filtered too.
  assert.deepEqual(registryAsFrames([managed, external]).map((frame) => frame.id), ['m1'])
})
