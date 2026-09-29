# Terminal workspace design system

Use the [product terminology](../../docs/terminology.md): a swarm groups harnesses;
a harness is one running agent session.

Harness should feel like a terminal workspace, from its tab bar to its welcome
page, dialogs, and contextual controls. **Text first. Keyboard first. Fixed
cells.** Use this document for new workspace surfaces and visual reviews.

The [terminal dialog rules](terminal-dialogs.md) specify row and column geometry,
selection, input, and preview behavior. The [workspace status bar rules](workspace-status-bar.md)
specify tabs, pane headers, focused context, and model selection. Those documents
are the detailed implementation references for this system.

## Text is the interface

Use meaningful names and familiar terminal punctuation. Menu actions such as
`New Harness` use plain text and the same row highlight as other choices.
Standalone actions can use brackets, such as `[ Customize Harness ]`, instead
of rounded buttons with pictograms. A checkbox is
`[x]` or `[ ]`. Harness search has no prefix; `#` selects projects and `>` selects
commands as editable text. `@`, `:`, and `*` scope machines, models, and Store
inside the same picker. The top row keeps swarms, `+`, a plain search icon, the
notification bell, and the rounded Harness Store button. The bottom row holds focused
machine/repo/branch/PR links on the left and the model selector on the right.
Keep descriptive tooltips and accessible names. Search and bell are deliberate
icon exceptions; the bell shows a count only when there is something to see.
Store restores its colorful polymath mark and a quiet filled pill. The bottom
context has no separate background or divider.

There is no broadly understood ASCII pencil. Keep `[ Customize Harness ]` after
customization as well as before it. The same action should retain its name and
location; a saved background must not silently replace it with an unlabeled icon.
Over artwork, a flat backing may protect text contrast. Do not add a pill,
bordered button well, logo, emoji, or ornamental icon to workspace controls.
User content and embedded viewers retain their own visual language.

## Keyboard is the primary path

Every workspace action needs an existing command or a clear keyboard interaction.
Cmd-S opens the Store tab, Cmd-M opens Machines (`@`), and Cmd-I opens Models (`:`).
History remains available from its menu without a default shortcut. Cmd-Y and Cmd-U
have no default workspace action. On macOS, Minimize remains available from the
yellow window button and the Window menu; Cmd-M belongs to Machines inside Harness.
Resolve shortcut hints from the live keymap. Cmd-N creates a harness, Cmd-O opens projects (`#`), Cmd-P searches harnesses, and Cmd-Shift-P opens
commands (`>`) in the shared picker. Cmd-I opens models with `:` already entered;
typing Shift is unnecessary. From a live harness pane, Enter uses a served or
downloaded model for that pane, starting installed weights when necessary; Tab
switches between the list and controls. In Cmd-N, Tab switches between fields
and their choices. Up/Down navigates the active pane and Enter activates.
Cmd-P's model scope uses the same behavior. Cmd-T opens a swarm, Cmd-W closes a swarm, and
Cmd-Shift-W closes the focused pane view. Cmd-Q quits the app. Enter activates,
Space toggles, and Escape backs out or dismisses.

Closing a pane removes its view immediately, without a minimize animation.

Keep mouse access useful without adding duplicate floating controls. Clickable
text shows a hand cursor and bold text on hover, press, and keyboard focus.
Preserve the underlying colors, including filled status segments. Reserve both
text weights during layout so emphasis never shifts neighboring controls.
Resting controls stay unboxed, except the optional Share action: its flat
primary accent fill makes collaboration visible in the bottom row, before the model.
Settings → Experimental → Share button enables it; it is off by default.
Tooltips describe the
action, not merely the text. Omit a tooltip that repeats the visible name;
show the full name when truncated, or a different underlying name. A model
selector says `Switch model · Subscription or local models`; include its full
model name only when shortened or temporarily replaced by a switching label. Disabled controls must not advertise an available
action or receive keyboard activation. Preserve accessibility names and focus
restoration; terminal styling is not permission to replace real controls with
inaccessible painted text.

## Use a real character grid

Measure columns and rows through `terminalCellSizeOf(context)` for dialogs and
welcome content. Text, margins, choices, and scrolling follow those dimensions.
Dialog selection highlights exactly one text row. Keep fixed font metrics when space
gets tight; truncate long values or reduce the number of visible columns.

Persistent tab, status, and pane bars use `workspaceBarTextStyle()` and
`workspaceBarCellSizeOf(context)`: 13 pt SF Mono regular on macOS and the platform
monospace stack on Linux, independent of terminal zoom. Every bar control uses
same minimum click height: `workspaceBarControlHeight()` (28 pt). The active tab
fills the entire bar height with the workspace background color, joining the
content below; selection keeps regular text and adds no `*` marker. Hovering a
tab uses bold text like other bar controls. No rounded corners, ripple, or
separate model-label well. Dialogs and welcome
actions use `terminalContentStyle()` and follow the terminal font preference.

## Keep surfaces quiet

First launch uses the same New Swarm page as every later visit: “Harness like a
boss.” followed by five clickable shortcuts: Start a harness, Manage all your
harnesses, Deploy a local model, Manage all your machines, and Build beyond code.
Resolve the shortcut hints from the live keymap; unbound actions remain clickable.
Keep this page independent of onboarding progress; no checklist or automatic dialog.

![Shared first-launch and New Swarm welcome](images/workspace-welcome.png)

Use terminal foreground, background, muted text, and selection colors. Workspace
dialogs use the same thin frame as a focused pane. Avoid raised cards, shadows,
rounded action pills, and redundant headings. Tabs use concise text labels, with
selection conveyed by background rather than bold type.

The selected pane stays at full contrast; other panes receive a 30% neutral-gray
veil (`#9D9D9D`) over their header and content, lifting dark backgrounds while
softening text. In the default Graphite palette, inactive backgrounds render as
`#404040` (RGB 64, 64, 64). Selection follows the existing click and keyboard
focus actions. Keep the current pane clear while a menu or the tab strip
temporarily owns keyboard focus. A single or zoomed pane stays clear.
Waiting-question borders paint above the veil, at full strength.
This is a paint treatment: retain terminal state and let the first click reach
the pane underneath.

![Selected center pane at full contrast, with synthetic terminal content](images/workspace-pane-focus.png)

Status layouts and terminal palettes are separate choices. **Plain** always uses
the terminal foreground for context text. PR state icons keep their distinct
green/purple/red/gray colors when Color is on, including in Plain. In Powerline
layouts, that state color fills the final joined block, with contrasting icon
and number inside. Shell layouts use the terminal's
ANSI colors. The named Pastel Powerline, Catppuccin Powerline, Tokyo Night, and
Gruvbox Rainbow presets carry their own status-only colors, resolved in the
shared status formatter for both Flutter and AppKit. Color off makes any preset
monochrome. Branch symbols and separators are drawn vectors so users can keep
their normal monospace font. Do not invent runtime facts, Git dirtiness, exit
status, or progress to decorate a theme.

## Make context useful

Show the focused pane's model, machine, compact project name, branch, and PR in the
bottom status bar. A dependent viewer uses its owner's context. Keep internal
worktree paths and machinery out of everyday labels.

Machine opens the shared picker scoped to that machine. Project opens its harnesses across
known checkouts and machines. With session Git context, Branch opens Branches and pull requests: checked-out and recorded branches,
with PR history. Temporary checkout paths stay out of these labels and details.
Older daemons keep exact-branch project search. Hide detached commit hashes from
the bar. Multiple branches or unavailable Git data use plain context text, without a
branch symbol. These are navigation actions; they do not check out a branch.
The PR label opens that PR. Each field gets its own accessible link, tooltip, and
the shared hover treatment, including in joined Agnoster segments.

## Review in context

Check keyboard-only operation, hover, focus, disabled state, narrow windows,
long names, missing Git data, a dependent viewer, light and dark palettes, and
terminal font changes. Opening or dismissing controls must not send input to an
agent or recreate its terminal. Use synthetic data for screenshots.

Start with `TerminalTextAction`, `WorkspaceBarControl`, `WorkspaceStatusLine`, and
the Cmd-N/Cmd-O reference implementations. Native macOS controls must match the
Flutter fallback in behavior and appearance.
