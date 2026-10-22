# yadoist.nvim

Your Todoist tasks as a Neovim buffer you edit like any other text. Type a line
to add a task, change a line to rename one, tick a box to complete one, delete a
line to delete one — then `:w` sends it all to Todoist.

```markdown
# Inbox

- [ ] Buy milk @errand !p2 <2026-09-24>
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

Needs Neovim 0.10 or later, and curl (7.84 or later lets a rate limit's
Retry-After be read). With lazy.nvim:

```lua
{ "you/yadoist.nvim", cmd = { "Yadoist", "YadoistRefresh" }, opts = {} }
```

Then create an API token at Todoist → Settings → Integrations → Developer, and
put it in your environment:

```sh
export TODOIST_API_TOKEN="..."      # bash / zsh
set -Ux TODOIST_API_TOKEN "..."     # fish, persists across sessions
```

Run `:Yadoist`. `:checkhealth yadoist` checks Neovim, curl and the token, and
`:help yadoist` has everything below.

## Views

`:Yadoist <view>` opens one of these, tab-completable:

| view | shows |
|---|---|
| `all` (the default) | every task, grouped by project |
| `today` | overdue, then due today, grouped by day |
| `upcoming` | overdue, then each of the next seven days |
| `overdue` | past its due date and still open |
| `inbox` | the Inbox project on its own |
| `project <name>` | one project and its subprojects |
| `filter <query>` | what a Todoist filter matches: `filter today & #Work`, `filter @errand` |
| `completed` | tasks completed in the last week, to untick one ticked by mistake |

`:Yadoist add <text>` adds a task without opening a buffer, through Todoist's
own quick-add parser, so `:Yadoist add Call the plumber #House tomorrow p2`
lands in House, due tomorrow, at priority 2. Being Todoist's parser, it
creates any `@label` it has not seen. Open task buffers catch up at once.

A view is only a filter. The buffer grammar never changes, and every edit works
the same way whichever view you are looking at, so you can complete and retitle
things straight from `today`. Each view gets its own buffer (`yadoist://today`
and so on), so switching between them keeps whatever you had unsaved in the
other. Tasks a view hides are never mistaken for deleted ones.

### Project views

`all`, `overdue`, `inbox`, `project`, `filter` and `completed` are grouped by
project, with `# Project` headings, in the order Todoist's sidebar has them:
each project is followed by the ones nested in it, whose headings say what
they are nested in. A matching task always brings its parent along, so a
subtask is never shown without the task it belongs to. `overdue`, `filter` and
`completed` leave out projects with nothing in them, so use `all` or `project
<name>` to add a task to an empty project; `inbox` always shows the Inbox,
empty or not.

`filter` takes Todoist's whole filter language and asks Todoist which tasks
match; label views come with it (`filter @errand`). A task added in a filter
view goes into the project of the heading it is under, and stays in sight
until the view is next refreshed, whether the filter matches it or not.

`completed` shows what was completed in the last `completed_days` days, open
parents included. Unticking a line there reopens it.

`:Yadoist project Work` shows `Work` and every project nested under it. Names
are matched ignoring case and may contain spaces (`:Yadoist project House
Chores`). Project names tab-complete once any task buffer has loaded. Every
project the view covers is drawn even when empty, sections included, so there
is always a heading to add a task under.

### Date views

`today` and `upcoming` work the way Todoist's own Today and Upcoming do:

```markdown
# Overdue

- [ ] Call the plumber <yesterday>                  Inbox

# Sep 23 · Today · Wednesday

- [ ] Ship the report !p1 <today>                   Work
  - [ ] Proofread it
- [ ] Get the wrench back from Dave <today>         House Chores › Fix the leaky sink

# Sep 24 · Tomorrow · Thursday
```

- **Headings are days.** `# Overdue` is always first when anything is overdue,
  then one heading per day. Every day is drawn even when it is empty, so there
  is always somewhere to add a task for it.
- **A task brings its subtasks.** Everything under a task due today shows up in
  `today`, whatever its own date. A subtask that is due in its own right sits
  under its own day instead, at the top level.
- **The project is shown beside each line** in dim virtual text, with the
  parent's name when a subtask is drawn apart from it. It is not part of the
  text, so it is never read back.

Editing follows from the headings being days rather than projects:

- **Moving a line under another day reschedules it**, as dragging it does in
  Todoist. A timed task keeps its local time of day. Recurring tasks refuse,
  since a fixed date would turn them into one-offs — edit their `<...>`
  instead.
- **A new line under a day** goes to the Inbox, due that day unless you give it
  a `<date>` of its own. Under `# Overdue` it needs one.
- **A new subtask** goes wherever its parent is.
- **Tasks never change project here.** Use `all` for that; `##` sections are not
  understood in date views.

A date view left open past midnight redraws its days as soon as you come back
to it, provided nothing is unsaved. If something is, `:w` refuses rather than
file your edits under yesterday's days.

## The syntax

| you write | it means |
|---|---|
| `# Name` | a project (a day, in the date views) |
| `## Name` | a section within the project above it |
| `- [ ]` / `- [x]` | an open / completed task |
| two spaces of indent | a subtask of the line above |
| `@errand` | a label |
| `@{waiting for}` | a label with a space in its name |
| `!p1` … `!p4` | priority, matching the names Todoist shows |
| `<tomorrow>` | a due date |
| indented text under a task | its description |
| `\` | before a trailing `<`, `!p1` or `@`: part of the title, not a suffix |

Anything inside `<...>` is handed to Todoist's own natural-language date parser
untouched, so `<friday at 5pm>`, `<every 2nd tuesday>` and `<in 3 days>` all
work, and recurring tasks keep recurring. Removing the `<...>` clears the due
date.

However a one-off date was typed, it is shown as the date it resolved to —
`<2026-09-24>`, or `<2026-09-24 15:00>` with a time — so every date in the
buffer reads the same way. A time fixed to a time zone is shown in your local
time, daylight saving included, and a date view files it under the day it
falls on where you are.

Labels, priorities and dates are only recognised at the end of a line, so a task
like `email bob@example.com` keeps its address instead of growing a label.

A title that itself ends in something that looks like one, such as `Style the
<div>` or `Reply to @john`, is drawn with a backslash in front of it — `Style
the \<div>` — so it reads back as part of the title. Type it the same way to
end a title in one. The backslash is not part of the title, and a title that
really has one there is drawn with one more.

Every untouched buffer reads back exactly as it was drawn, so `:w` with no
edits never sends anything, whatever the titles, labels and descriptions hold.

### Descriptions

A task's description is drawn under it, indented one step past the task:

```markdown
- [ ] Buy milk @errand
  2% from the corner shop, not the big one

  the one by the station closes at 6
  - [ ] Check the fridge first
```

Edit those lines to change it, add some under any task to give it one, and
delete them all to clear it. Any indented line that is not a `- [ ]` belongs to
the task directly above it, and blank lines between its lines are kept as
paragraph breaks. Tabs and extra indentation in a description are kept.

A line starting with `- [ ]` is a subtask, so a checklist inside a description
is drawn with a backslash in front of each box — `\- [ ] one` — and a line you
type that way stays in the description. Closing a task's fold (`zc`) hides its
description along with its subtasks.

Description lines remember the task they were drawn under. Deleting a task's
line deletes its description with it, even though the lines stay on screen
until the next refresh, rather than adding them to the task above; and moving a
task's line without its description leaves its description unchanged.

### Order

Lines are in Todoist's order, and moving them — `:m`, `ddp`, a visual block
cut and put — saves the new order of the list you moved them within or into:
a project's or section's tasks, or a task's subtasks. A new line is put where
you typed it. In `today` and `upcoming`, moving lines within a day saves that
day's order, the one Todoist's own Today and Upcoming use.

A view that shows only part of a list, as `overdue` does, leaves the tasks it
hides where they were relative to the ones around them.

### Recurring tasks

Recurring tasks are the exception to showing the date: the buffer shows
Todoist's own due *string* for them, so they round-trip as `<every monday>` and
stay recurring. Rendering the resolved date would silently flatten every
recurrence into a one-off the first time you saved.

Ticking a recurring task completes the current occurrence, which is Todoist's
behaviour rather than ours: the task comes back on the next refresh, unticked,
with its due date moved on. A one-off task ticked the same way disappears, since
Todoist stops returning it.

## Keymaps, inside the buffer

| key | does |
|---|---|
| `<CR>` | tick or untick the task under the cursor |
| `gr` | re-fetch from Todoist, asking first if there are unsaved edits |
| `q` | close the buffer |

In Insert mode, `<C-x><C-o>` completes `@labels` (in braces when the name needs
them), project names in `#` headings, and section names in `##` headings,
since a typo in any of them is refused on `:w`. It is the buffer's
`omnifunc`, so completion plugins with an omni source offer the same.

`:e` re-fetches too, and refuses while there are unsaved edits; `:e!` throws
them away and re-fetches. Undo stops at the last time the buffer was drawn,
the way it does after `:e`, so it never walks back into an older list.

## Writing

Before a write that could surprise you, `:w` lists everything it is about to
send, the way oil.nvim does, and asks:

```
Send 3 changes to Todoist?

  change    "Buy milk": date, labels, title
  complete  "Plan the move", with 2 subtasks this view hides: Book a van, Pack
  delete    "Old task"

Deleting a task removes it for everyone its project is shared with.
[S]end, Send all but the [d]eletes, [C]ancel:
```

It asks when the write deletes a task, renames a project or section, deletes
or completes subtasks the view does not show (in Todoist a task takes its
subtasks with it, and a parent drawn in `overdue` only for context may have
others), or moves tasks after a heading line was deleted, which drops them
under the heading above. Set `confirm = "always"` to see the list before every
write, or `false` never to be asked.

Nothing is sent until you `:w`, and then everything goes in one request
through Todoist's Sync API. The same request reads back whatever has changed,
so the buffer is redrawn from Todoist's answer to the write itself. `:w` waits
for that answer, which is what lets `:wq`, `:x` and `ZZ` quit; the buffer is
read-only meanwhile, and if Todoist is slow to answer, `:w` hands the write over
to the background and the buffer stays read-only until it lands.

Each change carries its own id that Todoist applies at most once. A request
that gets no answer, or a server error, is retried a couple of times with a
pause between; one that got no answer even then keeps its ids, so writing it
again later still cannot apply anything twice. A rate limit is waited out when
it asks for a short wait; anything else Todoist refuses is not retried.

If part of a write fails — an unparseable date, say — the buffer is left as you
typed it, with the reason on the line that failed, and the parts that landed
are not sent again on the next `:w`.

Refreshing, whether on focus or with `gr`, never redraws over unsaved edits,
including ones typed while the fetch was on its way.

## Configuration

These are the defaults:

```lua
require("yadoist").setup({
  -- A string, or a function returning one.
  token = function() return vim.env.TODOIST_API_TOKEN end,

  -- Before a write that could surprise you, :w lists everything it is about
  -- to send and asks first: see "Writing". "always" asks before every write,
  -- false never asks. (confirm_delete = false, from older versions, still
  -- means false.)
  confirm = true,

  -- Todoist creates any label it has not seen, so :w refuses a label that does
  -- not exist yet rather than turning a typo like @erand into a new one.
  create_labels = false,

  -- Show only these projects, by name. nil shows all of them.
  projects = nil,

  -- Re-fetch when the buffer regains focus, so a shared list does not sit
  -- stale on screen after someone else changes something. After the first
  -- fetch, each one asks only for what changed, so this is cheap.
  refresh_on_focus = true,

  -- How many days back the `completed` view looks.
  completed_days = 7,

  -- Per-request timeout, in milliseconds.
  timeout = 15000,

  keymaps = { toggle = "<CR>", refresh = "gr", close = "q" },
})
```

Every highlight group links to a standard one, so the buffer follows your
colourscheme without configuration. Override any of `YadoistProject`,
`YadoistSection`, `YadoistCheckboxOpen`, `YadoistCheckboxDone`, `YadoistContent`,
`YadoistContentDone`, `YadoistLabel`, `YadoistPriority1`–`3`, `YadoistDue`,
`YadoistDueToday`, `YadoistDueOverdue`, `YadoistDescription`, `YadoistDeadline`,
`YadoistAssignee` or `YadoistAnnotation` (the text beside a line) to taste.

Lines are coloured as they are drawn on screen, from their text, so a line you
type is coloured like one yadoist drew. A date is coloured from the task data
while the line still shows the date that was fetched, so a recurring task
reads `<every day>` but is coloured as overdue when it is.

Beside a line, in dim text that is never read back, yadoist shows a task's
deadline and who it is assigned to (`→ you` when it is you), and in the date
views which project it is in.

## How identity survives editing

Each task line carries an invisible extmark holding its Todoist id. Nothing
appears in the buffer text, and because identity comes from the mark rather than
from a line number you can reorder, re-indent and re-nest freely — a moved line
is a move, not a delete and a create.

The mark is zero-width, at the start of the line, so it survives any edit
within the line — `cc`, `S`, `:s`, `>>` — and is lost only when the line itself
is deleted. A line cut and pasted elsewhere (`ddp`) arrives without a mark, but
if it still reads exactly like the task that went missing it is that task, moved.
A task whose line is gone and was not pasted back is treated as a deletion — and
that is what the confirmation prompt is for.

Headings carry the same kind of mark, so a heading knows which project or
section it was drawn for. Todoist lets two projects, or two sections of one
project, share a name; their tasks never get mixed up, because neither heading
is looked up by name. Only a heading you type yourself is, and if two projects
answer to that name, `:w` says so rather than guess.

## Things it deliberately does not do

- **Create projects or sections.** A `#` heading that does not match a project
  in Todoist is an error on the line rather than a new project, so a typo can
  never quietly scatter your tasks into somewhere new. Labels get the same
  treatment unless you set `create_labels = true`. Editing the text of a
  heading yadoist drew renames that project or section instead, unless another
  one there already has the new name.
- **Work offline.** There is no local copy by design.
- **Show completed tasks**, outside the `completed` view. A task you tick
  stays visible until the next refresh, then disappears from every other view.
- **Show archived projects and sections, or anything inside them.** A task whose
  section has been archived is left out rather than drawn at the top level,
  which would otherwise read as a move you never asked for.

## Tests

```sh
nvim --headless -u NONE -i NONE -l tests/run.lua
nvim --headless -u NONE -i NONE -l tests/lifecycle.lua
```

`run.lua` covers the parser, the renderer, the render-parse round trip (with a
randomised test of it), every operation the diff can produce, including
identity surviving real `cc`, `dd` and `ddp` keystrokes, and due dates in
several time zones. `lifecycle.lua` drives real buffers against a fake Todoist
(`tests/fake_todoist.lua`): opening, `:e`, undo, writing and `:wq`, edits made
while a request is out, retries, lost replies, partial failures, folding,
completion and colour. CI runs both on Neovim 0.10, stable and nightly.

`tests/live.lua` runs against the real API, with your token, and only when
asked:

```sh
YADOIST_LIVE=1 nvim --headless -u NONE -i NONE -l tests/live.lua
```

It first draws every view from your account and checks that `:w` would send
nothing, without writing. Then it writes, but only in two throwaway projects
it makes and deletes again, behind a guard that refuses any request naming
anything else.
