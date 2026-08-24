# yadoist.nvim

Your Todoist tasks as a Neovim buffer you edit like any other text. Type a line
to add a task, change a line to rename one, tick a box to complete one, delete a
line to delete one — then `:w` sends it all to Todoist.

```markdown
# Inbox

- [ ] Buy milk @errand !p2 <tomorrow>
- [ ] Fix the leaky sink @house
  - [ ] Get the wrench back from Dave

# House Chores

## Kitchen

- [x] Wipe the counters @chores <every saturday>
```

There are no local files and nothing to sync. Opening the buffer fetches from
Todoist, `:w` diffs what you typed against what was fetched and pushes only what
changed. Todoist stays the only source of truth, so nothing can drift and there
are no conflicts to resolve — the trade is that it needs a network connection.

## Install

With lazy.nvim:

```lua
{ "you/yadoist.nvim", cmd = "Yadoist", opts = {} }
```

Then create an API token at Todoist → Settings → Integrations → Developer, and
put it in your environment:

```sh
export TODOIST_API_TOKEN="..."      # bash / zsh
set -Ux TODOIST_API_TOKEN "..."     # fish, persists across sessions
```

Run `:Yadoist`.

## Views

`:Yadoist <view>` opens one of these, tab-completable:

| view | shows |
|---|---|
| `all` (the default) | every task, grouped by project |
| `today` | due today, plus anything overdue |
| `upcoming` | due within the next seven days, plus anything overdue |
| `overdue` | past its due date and still open |
| `inbox` | the Inbox project on its own |

A view is only a filter. The buffer grammar never changes, `# Project` always
means a project, and every edit works the same way whichever view you are
looking at, so you can complete and retitle things straight from `today`. A
matching task always brings its parent along, so a subtask is never shown
without the task it belongs to.

Each view gets its own buffer (`yadoist://today` and so on), so switching
between them keeps whatever you had unsaved in the other. Tasks a view hides are
never mistaken for deleted ones.

Two things follow from views being filters. Filtered views leave out projects
with nothing in them, so `all` is where you go to add a task to an empty
project. And a task you add in `today` without a due date is created correctly
but disappears at the next refresh, because it no longer matches the filter.

## The syntax

| you write | it means |
|---|---|
| `# Name` | a project |
| `## Name` | a section within the project above it |
| `- [ ]` / `- [x]` | an open / completed task |
| two spaces of indent | a subtask of the line above |
| `@errand` | a label |
| `!p1` … `!p4` | priority, matching the names Todoist shows |
| `<tomorrow>` | a due date |

Anything inside `<...>` is handed to Todoist's own natural-language date parser
untouched, so `<friday at 5pm>`, `<every 2nd tuesday>` and `<in 3 days>` all
work, and recurring tasks keep recurring. Removing the `<...>` clears the due
date.

Labels, priorities and dates are only recognised at the end of a line, so a task
like `email bob@example.com` keeps its address instead of growing a label.

### Recurring tasks

Because the buffer shows Todoist's own due *string* rather than the date it
resolved to, a recurring task round-trips as `<every monday>` and stays
recurring. Rendering the resolved date instead would silently flatten every
recurrence into a one-off the first time you saved.

Ticking a recurring task completes the current occurrence, which is Todoist's
behaviour rather than ours: the task comes back on the next refresh, unticked,
with its due date moved on. A one-off task ticked the same way disappears, since
Todoist stops returning it.

## Keymaps, inside the buffer

| key | does |
|---|---|
| `<CR>` | tick or untick the task under the cursor |
| `R` | re-fetch from Todoist |
| `q` | close the buffer |

Nothing is sent until you `:w`.

## Configuration

These are the defaults:

```lua
require("yadoist").setup({
  -- A string, or a function returning one.
  token = function() return vim.env.TODOIST_API_TOKEN end,

  -- Deleting a line deletes the task for everyone the project is shared with,
  -- so :w asks first and lists exactly what is about to go.
  confirm_delete = true,

  -- Show only these projects, by name. nil shows all of them.
  projects = nil,

  -- Re-fetch when the buffer regains focus, so a shared list does not sit
  -- stale on screen after someone else changes something.
  refresh_on_focus = true,

  timeout = 15000,

  keymaps = { toggle = "<CR>", refresh = "R", close = "q" },
})
```

Every highlight group links to a standard one, so the buffer follows your
colourscheme without configuration. Override any of `YadoistProject`,
`YadoistSection`, `YadoistCheckboxOpen`, `YadoistCheckboxDone`, `YadoistContent`,
`YadoistContentDone`, `YadoistLabel`, `YadoistPriority1`–`3`, `YadoistDue`, `YadoistDueToday`
or `YadoistDueOverdue` to taste. Highlighting is applied from the task data rather
than by matching text, which is why an overdue date is coloured differently from
one that is merely set.

## How identity survives editing

Each task line carries an invisible extmark holding its Todoist id. Nothing
appears in the buffer text, and because identity comes from the mark rather than
from a line number you can reorder, re-indent and re-nest freely — a moved line
is a move, not a delete and a create.

Replacing an entire line at once, which `cc` does, invalidates that mark. The
dead mark stays on the row, so the rewritten line reclaims it and stays the same
task. A line that no longer resolves to any mark, and whose text does not match
anything that went missing, is treated as a deletion — and that is what the
confirmation prompt is for.

## Things it deliberately does not do

- **Create projects or sections.** A `#` heading that does not match a project
  in Todoist is an error on the line rather than a new project, so a typo can
  never quietly scatter your tasks into somewhere new.
- **Work offline.** There is no local copy by design.
- **Show completed tasks.** Todoist only returns active ones. A task you tick
  stays visible until the next refresh, then disappears.
- **Show archived projects and sections, or anything inside them.** A task whose
  section has been archived is left out rather than drawn at the top level,
  which would otherwise read as a move you never asked for.

## Tests

```sh
nvim --headless -l tests/run.lua
```

Covers the parser, the renderer, the render-parse round trip, and every
operation the diff can produce, including identity survival through real `cc`
and `dd` keystrokes.
