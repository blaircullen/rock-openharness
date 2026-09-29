/**
 * Rock OpenHarness — the one place this tree says it is a fork of upstream Harness.
 *
 * A fork build must never be replaced by the stock release behind the person's back: the upstream
 * update manifest only ever carries upstream bytes, so "newer" there means "without the fork's
 * features". Automatic updates are therefore off, and `harness update` asks for `--force` before it
 * swaps a fork build for a published release.
 *
 * Kept in a file upstream does not have, so merging upstream never conflicts here; the hooks in
 * upstream files are one call each.
 */

export const ROCK_FORK_BUILD = true
export const ROCK_FORK_NAME = 'Rock OpenHarness'

/** Lines `harness update` prints before refusing, or null when it may go ahead. Only `--force`
 *  replaces a fork build with the published upstream release. */
export function forkUpdateRefusal(version: string, force: boolean, fork = ROCK_FORK_BUILD): string[] | null {
  if (!fork || force) return null
  return [
    `This is a ${ROCK_FORK_NAME} build (v${version}).`,
    'Updating would replace it with the stock upstream release and drop the fork\'s changes.',
    '  keep it:    rebuild with `make install-cli` from the fork checkout after you pull',
    '  replace it: harness update --force',
  ]
}
