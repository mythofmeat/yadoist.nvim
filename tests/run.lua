-- Headless test suite: nvim --headless -l tests/run.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local parse = require("yadoist.parse")
local render = require("yadoist.render")
local diff = require("yadoist.diff")
local model = require("yadoist.model")
local dapi = require("yadoist.api")
local sync = require("yadoist.sync")

local passed, failed = 0, 0

local function check(name, ok, detail)
  if ok then
    passed = passed + 1
    print(("  ok   %s"):format(name))
  else
    failed = failed + 1
    print(("  FAIL %s%s"):format(name, detail and ("\n       " .. tostring(detail)) or ""))
  end
end

local function eq(name, got, want)
  local same = vim.deep_equal(got, want)
  check(name, same, not same and ("got:  " .. vim.inspect(got) .. "\n       want: " .. vim.inspect(want)) or nil)
end

--------------------------------------------------------------------- fixtures
local function task(id, content, opts)
  return vim.tbl_extend("force", {
    id = id,
    content = content,
    project_id = "p1",
    labels = {},
    priority = 1,
    child_order = 1,
  }, opts or {})
end

local function fixture()
  return {
    projects = {
      { id = "p1", name = "Inbox", is_inbox_project = true, child_order = 1 },
      { id = "p2", name = "House Chores", child_order = 2 },
    },
    sections = { { id = "s1", project_id = "p2", name = "Kitchen", child_order = 1 } },
    tasks = {
      task("t1", "Buy milk", {
        labels = { "errand" }, priority = 3,
        due = { string = "tomorrow", date = "2099-01-01" },
      }),
      task("t2", "Fix the leaky sink", { project_id = "p2", labels = { "house" } }),
      task("t3", "Get the wrench back from Dave", { project_id = "p2", parent_id = "t2" }),
      task("t4", "Wipe the counters", { project_id = "p2", section_id = "s1" }),
    },
  }
end

--- Recreate what buffer.lua does: render into a real buffer with identity
--- extmarks, then hand back everything the diff needs.
local ns = vim.api.nvim_create_namespace("yadoist_test_ids")

local function mount(data, opts)
  local lines, tasks, _, meta = render.build(data, opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local st = { marks = {}, known = {}, project_ids = {}, section_ids = {} }
  for _, entry in ipairs(tasks) do
    local row = entry.lnum - 1
    local mark = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
      end_row = row,
      end_col = #lines[entry.lnum],
      invalidate = true,
    })
    st.marks[mark] = entry.task
    st.known[entry.task.id] = entry.task
  end
  for _, p in ipairs(data.projects) do
    st.project_ids[p.name] = p.id
  end
  for _, s in ipairs(data.sections) do
    st.section_ids[s.project_id] = st.section_ids[s.project_id] or {}
    st.section_ids[s.project_id][s.name] = s.id
  end
  if meta.headings then
    st.by_date = { headings = meta.headings, placed = meta.placed, overdue = render.OVERDUE }
    for _, p in ipairs(data.projects) do
      if model.is_inbox(p) then
        st.by_date.inbox_id = p.id
      end
    end
  end
  return buf, st, lines
end

local function resolvers(buf, st)
  local live, dead, claimed = {}, {}, {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local id, row, details = m[1], m[2], m[4]
    local bucket = (details and details.invalid) and dead or live
    bucket[row] = bucket[row] or {}
    table.insert(bucket[row], id)
  end
  local function lookup(bucket)
    return function(lnum)
      for _, id in ipairs(bucket[lnum - 1] or {}) do
        if not claimed[id] and st.marks[id] then
          claimed[id] = true
          return st.marks[id]
        end
      end
      return nil
    end
  end
  return lookup(live), lookup(dead)
end

local function ops_for(buf, st)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local entries, errors = parse.buffer(lines)
  if #errors > 0 then
    return nil, errors
  end
  local resolve, resolve_stale = resolvers(buf, st)
  return diff.compute({
    entries = entries,
    resolve = resolve,
    resolve_stale = resolve_stale,
    known = st.known,
    project_ids = st.project_ids,
    section_ids = st.section_ids,
    by_date = st.by_date,
  })
end

------------------------------------------------------------- suffix splitting
print("\nsplit_suffixes")
do
  local c, l, p, d = parse.split_suffixes("Fix the leaky sink @house !p1 <friday>")
  eq("pulls all three suffixes", { c, l, p, d }, { "Fix the leaky sink", { "house" }, 1, "friday" })

  c, l = parse.split_suffixes("email bob@example.com")
  eq("leaves an email address alone", { c, l }, { "email bob@example.com", {} })

  c, l = parse.split_suffixes("Task @a @b")
  eq("keeps multiple labels in order", { c, l }, { "Task", { "a", "b" } })

  c, _, _, d = parse.split_suffixes("Ship it <every 2nd tuesday>")
  eq("keeps spaces inside a due string", { c, d }, { "Ship it", "every 2nd tuesday" })

  c = parse.split_suffixes("Fix <div> rendering")
  eq("ignores angle brackets that are not at the end", c, "Fix <div> rendering")
end

-------------------------------------------------------------------- rendering
print("\nrender")
do
  local lines = render.build(fixture())
  eq("produces the expected buffer", lines, {
    "# Inbox",
    "",
    "- [ ] Buy milk @errand !p2 <2099-01-01>",
    "",
    "# House Chores",
    "",
    "- [ ] Fix the leaky sink @house",
    "  - [ ] Get the wrench back from Dave",
    "",
    "## Kitchen",
    "",
    "- [ ] Wipe the counters",
  })
end

------------------------------------------------------------------ round trips
print("\nround trip")
do
  local buf, st = mount(fixture())
  local ops, errors = ops_for(buf, st)
  check("an untouched buffer produces no operations", ops and #ops == 0,
    errors and vim.inspect(errors) or (ops and vim.inspect(ops)))
end

--------------------------------------------------------------- detecting edits
print("\ndiff")
do
  -- Editing part of a line, the way `cw` does: the mark survives.
  local buf, st = mount(fixture())
  vim.api.nvim_buf_set_text(buf, 2, 6, 2, 14, { "Buy oat milk" })
  local ops = ops_for(buf, st)
  eq("an edited title is one update", #ops == 1 and { ops[1].kind, ops[1].id, ops[1].fields } or ops,
    { "update", "t1", { content = "Buy oat milk" } })
end

do
  -- Rewriting the whole line, the way `cc` does: the mark is invalidated, and
  -- the dead mark left on that row is what keeps the task's identity.
  local buf, st, lines = mount(fixture())
  vim.api.nvim_buf_set_text(buf, 2, 0, 2, #lines[3], { "- [ ] Buy oat milk" })
  local ops = ops_for(buf, st)
  eq("a wholly rewritten line keeps its identity",
    #ops == 1 and { ops[1].kind, ops[1].id, ops[1].fields } or ops,
    { "update", "t1", { content = "Buy oat milk", labels = {}, due_string = "no date", priority = 1 } })
end

do
  -- The same thing through real keystrokes, to be sure the API calls above are
  -- not flattering us.
  local buf, st = mount(fixture())
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes("cc- [ ] Buy oat milk<Esc>", true, false, true), "x", false)
  local ops = ops_for(buf, st)
  eq("real cc keystrokes keep the task identity",
    #ops == 1 and { ops[1].kind, ops[1].id } or ops, { "update", "t1" })
end

do
  local buf, st = mount(fixture())
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "- [x] Buy milk @errand !p2 <2099-01-01>" })
  local ops = ops_for(buf, st)
  eq("a ticked box is a completion", #ops == 1 and { ops[1].kind, ops[1].id } or ops, { "close", "t1" })
end

do
  local buf, st = mount(fixture())
  vim.api.nvim_buf_set_lines(buf, 3, 3, false, { "- [ ] Buy bread" })
  local ops = ops_for(buf, st)
  check("a new line is a create", #ops == 1 and ops[1].kind == "create"
    and ops[1].content == "Buy bread" and ops[1].project_id == "p1", vim.inspect(ops))
end

do
  local buf, st = mount(fixture())
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, {})
  local ops = ops_for(buf, st)
  eq("a removed line is a delete", #ops == 1 and { ops[1].kind, ops[1].id } or ops, { "delete", "t1" })
end

do
  local buf, st = mount(fixture())
  -- Retyping a whole line drops its extmark; content matching must rescue it
  -- rather than turning one task into a delete plus a create.
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "- [ ] Buy milk @errand @urgent !p2 <2099-01-01>" })
  local ops = ops_for(buf, st)
  eq("a retyped line stays the same task", #ops == 1 and { ops[1].kind, ops[1].id, ops[1].fields } or ops,
    { "update", "t1", { labels = { "errand", "urgent" } } })
end

do
  local buf, st = mount(fixture())
  -- Move "Buy milk" from Inbox into House Chores.
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, {})
  vim.api.nvim_buf_set_lines(buf, 5, 5, false, { "- [ ] Buy milk @errand !p2 <2099-01-01>" })
  local ops = ops_for(buf, st)
  eq("dragging a task to another project is a move",
    #ops == 1 and { ops[1].kind, ops[1].id, ops[1].fields } or ops,
    { "move", "t1", { project_id = "p2" } })
end

do
  local buf, st = mount(fixture())
  vim.api.nvim_buf_set_lines(buf, 7, 8, false, { "- [ ] Get the wrench back from Dave" })
  local ops = ops_for(buf, st)
  eq("un-indenting a subtask promotes it", #ops == 1 and { ops[1].kind, ops[1].id, ops[1].fields } or ops,
    { "move", "t3", { project_id = "p2" } })
end

do
  local buf, st = mount(fixture())
  vim.api.nvim_buf_set_lines(buf, 3, 3, false, { "- [ ] Plan the party", "  - [ ] Book a venue" })
  local ops = ops_for(buf, st)
  check("a new subtask under a new parent defers its parent id",
    #ops == 2 and ops[1].kind == "create" and ops[2].kind == "create"
      and ops[2].parent_lnum == ops[1].lnum and ops[2].parent_id == nil, vim.inspect(ops))
end

--------------------------------------------------------------- parse failures
print("\nparse errors")
do
  local _, errors = parse.buffer({ "# Inbox", "", "just some prose" })
  check("rejects a line that is not a task", #errors == 1 and errors[1].lnum == 3, vim.inspect(errors))

  local _, e2 = parse.buffer({ "- [ ] orphan" })
  check("rejects a task with no project heading", #e2 == 1, vim.inspect(e2))

  local _, e3 = parse.buffer({ "# Inbox", "    - [ ] too deep" })
  check("rejects an over-indented task", #e3 == 1, vim.inspect(e3))

  local entries, e4 = parse.buffer({ "# Inbox", "- [ ] Above", "", "# Work", "", "  - [ ] Indented first" })
  check("indentation never nests under a task from another heading",
    #e4 == 1 and e4[1].lnum == 6 and entries[2].parent_lnum == nil, vim.inspect(e4))

  local _, e5 = parse.buffer({ "# Work", "- [ ] Above", "## Kitchen", "  - [ ] Indented first" })
  check("nor from above a section heading", #e5 == 1 and e5[1].lnum == 4, vim.inspect(e5))
end

do
  local buf, st = mount(fixture())
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "# Nonexistent Project" })
  local ops, errors = ops_for(buf, st)
  check("refuses to invent a project", ops and #ops == 0 and errors and #errors > 0,
    vim.inspect(errors or ops))
end

------------------------------------------------------------------------ views
print("\nviews")
do
  local today = os.date("%Y-%m-%d")
  local yesterday = os.date("%Y-%m-%d", os.time() - 86400)
  local later = os.date("%Y-%m-%d", os.time() + 10 * 86400)

  local function dated()
    return {
      projects = {
        { id = "p1", name = "Inbox", is_inbox_project = true, child_order = 1 },
        { id = "p2", name = "House Chores", child_order = 2 },
        { id = "p3", name = "Someday", child_order = 3 },
      },
      sections = {},
      tasks = {
        task("d1", "Due today", { due = { string = today, date = today } }),
        task("d2", "Overdue", { due = { string = yesterday, date = yesterday } }),
        task("d3", "Later", { due = { string = later, date = later } }),
        task("d4", "No date at all", {}),
        task("d5", "Chore parent", { project_id = "p2" }),
        task("d6", "Chore child", { project_id = "p2", parent_id = "d5",
          due = { string = today, date = today } }),
        task("d7", "Someday maybe", { project_id = "p3" }),
      },
    }
  end

  local today_heading = "# " .. render.day_heading(today, 0)
  eq("today is grouped by day, overdue first",
    render.build(dated(), { view = "today" }), {
      "# Overdue",
      "",
      "- [ ] Overdue <" .. yesterday .. ">",
      "",
      today_heading,
      "",
      "- [ ] Due today <" .. today .. ">",
      "- [ ] Chore child <" .. today .. ">",
    })

  local _, _, _, meta = render.build(dated(), { view = "today" })
  local notes = {}
  for _, a in ipairs(meta.annotations) do
    notes[a.lnum] = a.text
  end
  eq("a subtask drawn without its parent says where it lives", notes[8], "House Chores › Chore parent")
  eq("a top-level task says which project it is in", notes[7], "Inbox")

  local overdue = render.build(dated(), { view = "overdue" })
  eq("overdue is today's list minus today", overdue, {
    "# Inbox", "", "- [ ] Overdue <" .. yesterday .. ">",
  })

  local upcoming = render.build(dated(), { view = "upcoming" })
  check("upcoming excludes something ten days out",
    not vim.tbl_contains(upcoming, "- [ ] Later <" .. later .. ">"), vim.inspect(upcoming))

  local inbox = render.build(dated(), { view = "inbox" })
  check("inbox is only the inbox project",
    #vim.tbl_filter(function(l) return l:match("^# ") end, inbox) == 1
      and inbox[1] == "# Inbox", vim.inspect(inbox))

  local all = render.build(dated(), { view = "all" })
  check("all keeps empty projects as somewhere to add tasks",
    vim.tbl_contains(all, "# Someday"), vim.inspect(all))
  check("a filtered view drops empty projects",
    not vim.tbl_contains(render.build(dated(), { view = "overdue" }), "# Someday"))

  -- The important safety property: tasks a view hides must not read as deleted.
  local buf, st = mount(dated(), { view = "today" })
  local ops, errors = ops_for(buf, st)
  check("an untouched filtered view produces no operations", ops and #ops == 0,
    vim.inspect(errors or ops))

  buf, st = mount(dated(), { view = "today" })
  vim.api.nvim_buf_set_text(buf, 6, 6, 6, 15, { "Due today!" })
  ops = ops_for(buf, st)
  eq("editing inside a filtered view still updates the right task",
    #ops == 1 and { ops[1].kind, ops[1].id } or ops, { "update", "d1" })
end

print("\ndate views")
do
  local today = model.today()
  local tomorrow = model.date_after(1)
  local yesterday = model.date_after(-1)
  local next_week = model.date_after(20)

  local function family()
    return {
      projects = {
        { id = "p1", name = "Inbox", is_inbox_project = true, child_order = 1 },
        { id = "p2", name = "Work", child_order = 2 },
      },
      sections = {},
      tasks = {
        task("f1", "Parent due today", { project_id = "p2", due = { string = "today", date = today } }),
        task("f2", "Undated child", { project_id = "p2", parent_id = "f1", child_order = 1 }),
        task("f3", "Child due later", { project_id = "p2", parent_id = "f1", child_order = 2,
          due = { string = "later", date = next_week } }),
        task("f4", "Grandchild", { project_id = "p2", parent_id = "f2" }),
        task("f5", "Tomorrow's task", { due = { string = "tomorrow", date = tomorrow } }),
        task("f6", "Weekly", { due = { string = "every day", date = yesterday, is_recurring = true } }),
      },
    }
  end

  local lines = render.build(family(), { view = "today" })
  eq("a task due today brings every subtask with it", lines, {
    "# Overdue",
    "",
    "- [ ] Weekly <every day>",
    "",
    "# " .. render.day_heading(today, 0),
    "",
    "- [ ] Parent due today <" .. today .. ">",
    "  - [ ] Undated child",
    "    - [ ] Grandchild",
    "  - [ ] Child due later <" .. next_week .. ">",
  })

  local upcoming = render.build(family(), { view = "upcoming" })
  local headings = vim.tbl_filter(function(l) return l:match("^# ") end, upcoming)
  eq("upcoming has overdue and then every day of the week", #headings, 9)
  eq("upcoming headings are days", headings[3], "# " .. render.day_heading(tomorrow, 1))
  check("tomorrow's task sits under tomorrow",
    upcoming[vim.fn.index(upcoming, headings[3]) + 3] == "- [ ] Tomorrow's task <" .. tomorrow .. ">", vim.inspect(upcoming))

  local buf, st = mount(family(), { view = "upcoming" })
  local ops, errors = ops_for(buf, st)
  check("an untouched date view produces no operations", ops and #ops == 0, vim.inspect(errors or ops))

  -- Drag "Tomorrow's task" up under today.
  buf, st = mount(family(), { view = "upcoming" })
  local cur = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local from = vim.fn.index(cur, "- [ ] Tomorrow's task <" .. tomorrow .. ">")
  vim.api.nvim_buf_set_lines(buf, from, from + 1, false, {})
  vim.api.nvim_buf_set_lines(buf, 6, 6, false, { "- [ ] Tomorrow's task <" .. tomorrow .. ">" })
  ops = ops_for(buf, st)
  eq("moving a line to another day reschedules it",
    #ops == 1 and { ops[1].kind, ops[1].id, ops[1].fields } or ops,
    { "update", "f5", { due_date = today } })

  local timed = family()
  timed.tasks[5].due = { string = "tomorrow 3pm", date = tomorrow .. "T15:00:00" }
  buf, st = mount(timed, { view = "upcoming" })
  cur = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  from = vim.fn.index(cur, "- [ ] Tomorrow's task <" .. tomorrow .. " 15:00>")
  vim.api.nvim_buf_set_lines(buf, from, from + 1, false, {})
  vim.api.nvim_buf_set_lines(buf, 6, 6, false, { "- [ ] Tomorrow's task <" .. tomorrow .. " 15:00>" })
  ops = ops_for(buf, st)
  eq("rescheduling a timed task keeps its time",
    #ops == 1 and ops[1].fields or ops, { due_datetime = today .. "T15:00:00" })

  buf, st = mount(family(), { view = "upcoming" })
  cur = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local at = vim.fn.index(cur, headings[3]) + 1
  vim.api.nvim_buf_set_lines(buf, at, at, false, { "- [ ] Brand new" })
  ops = ops_for(buf, st)
  check("a new line under a day is created in the Inbox, due that day",
    #ops == 1 and ops[1].kind == "create" and ops[1].project_id == "p1"
      and ops[1].due_date == tomorrow and ops[1].due_string == nil, vim.inspect(ops))

  buf, st = mount(family(), { view = "today" })
  vim.api.nvim_buf_set_lines(buf, 8, 8, false, { "    - [ ] New grandchild" })
  ops = ops_for(buf, st)
  check("a new subtask in a date view follows its parent",
    #ops == 1 and ops[1].kind == "create" and ops[1].parent_id == "f2"
      and ops[1].project_id == nil and ops[1].due_date == nil, vim.inspect(ops))

  buf, st = mount(family(), { view = "today" })
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, {})
  vim.api.nvim_buf_set_lines(buf, 5, 5, false, { "- [ ] Weekly <every day>" })
  _, errors = ops_for(buf, st)
  check("a recurring task cannot be dragged to another day", errors and #errors == 1, vim.inspect(errors))

  buf, st = mount(family(), { view = "today" })
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "# Someday" })
  _, errors = ops_for(buf, st)
  check("a heading that is not one of the view's days is an error", errors and #errors == 1, vim.inspect(errors))
end

do
  -- A subtask whose parent has been completed is not returned by the API, so it
  -- must still be drawn rather than silently vanishing.
  local orphaned = {
    projects = { { id = "p1", name = "Inbox", is_inbox_project = true, child_order = 1 } },
    sections = {},
    tasks = { task("o1", "Child of a finished task", { parent_id = "gone" }) },
  }
  eq("an orphaned subtask is drawn at the top level", render.build(orphaned),
    { "# Inbox", "", "- [ ] Child of a finished task" })

  local buf, st = mount(orphaned)
  local ops, errors = ops_for(buf, st)
  check("and is not promoted just by saving", ops and #ops == 0, vim.inspect(errors or ops))
end

do
  -- The live API spells this `inbox_project`; the Python SDK spells it
  -- `is_inbox_project`. Both must work, or the inbox view silently empties.
  local function with(flag)
    return {
      projects = {
        { id = "p2", name = "Zzz Later", child_order = 2 },
        vim.tbl_extend("force", { id = "p1", name = "Inbox", child_order = 9 }, flag),
      },
      sections = {},
      tasks = { task("i1", "Inbox task"), task("i2", "Other task", { project_id = "p2" }) },
    }
  end

  for _, flag in ipairs({ { inbox_project = true }, { is_inbox_project = true } }) do
    local key = next(flag)
    local lines = render.build(with(flag))
    check("inbox sorts first with " .. key, lines[1] == "# Inbox", vim.inspect(lines))
    local only = render.build(with(flag), { view = "inbox" })
    eq("inbox view works with " .. key, only, { "# Inbox", "", "- [ ] Inbox task" })
  end
end

do
  local hidden = {
    projects = {
      { id = "p1", name = "Inbox", inbox_project = true, child_order = 1 },
      { id = "p2", name = "Archived", child_order = 2, is_archived = true },
      { id = "p3", name = "Deleted", child_order = 3, is_deleted = true },
    },
    sections = {
      { id = "s1", project_id = "p1", name = "Gone", child_order = 1, is_deleted = true },
    },
    tasks = {
      task("h1", "Still here"),
      task("h2", "Removed", { is_deleted = true }),
      task("h3", "In a dead section", { section_id = "s1" }),
    },
  }
  -- A task in a dead section is left out too: drawing it at the top level
  -- would make the diff read it as a move the user never asked for.
  eq("archived and deleted things are left out", render.build(hidden),
    { "# Inbox", "", "- [ ] Still here" })
end

--------------------------------------------------------------------- priority
print("\npriority mapping")
do
  eq("api 4 is p1 (urgent)", model.api_to_ui_priority(4), 1)
  eq("api 1 is p4 (none)", model.api_to_ui_priority(1), 4)
  eq("p1 round trips", model.ui_to_api_priority(model.api_to_ui_priority(4)), 4)
end

----------------------------------------------------------------------- labels
print("\nlabels")
do
  local function labelled(line)
    local buf, st = mount(fixture())
    st.label_names = { errand = true, house = true, shared = true }
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, { line })
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local entries = parse.buffer(lines)
    local resolve, resolve_stale = resolvers(buf, st)
    return diff.compute({
      entries = entries, resolve = resolve, resolve_stale = resolve_stale, known = st.known,
      project_ids = st.project_ids, section_ids = st.section_ids, label_names = st.label_names,
    })
  end

  local ops, errors = labelled("- [ ] Buy milk @erand !p2 <2099-01-01>")
  check("a label that does not exist is refused", #ops == 0 and #errors == 1
    and errors[1].msg:find('"erand"', 1, true) ~= nil, vim.inspect(errors))

  ops, errors = labelled("- [ ] Buy milk @errand @shared !p2 <2099-01-01>")
  check("an existing label is fine", #errors == 0 and #ops == 1, vim.inspect(errors))

  local buf, st = mount(fixture())
  st.label_names = {}
  -- t1 already carries @errand even though it is not in the list: a shared
  -- project's label, say. Leaving it alone must not be an error.
  vim.api.nvim_buf_set_text(buf, 2, 6, 2, 14, { "Buy oat milk" })
  local entries = parse.buffer(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  local resolve, resolve_stale = resolvers(buf, st)
  ops, errors = diff.compute({
    entries = entries, resolve = resolve, resolve_stale = resolve_stale, known = st.known,
    project_ids = st.project_ids, section_ids = st.section_ids, label_names = st.label_names,
  })
  check("a label the task already had is kept", #errors == 0 and #ops == 1, vim.inspect(errors))
end

------------------------------------------------------------------------- sync
print("\nsync")
do
  local cmds = sync._commands_for({
    { kind = "create", lnum = 3, content = "Parent", project_id = "p1", priority = 1, labels = {},
      due_date = "2026-09-24", done = true },
    { kind = "create", lnum = 4, content = "Child", parent_lnum = 3, priority = 1, labels = {} },
    { kind = "update", id = "t1", fields = { due_string = "no date" } },
    { kind = "update", id = "t2", fields = { due_datetime = "2026-09-24T15:00:00", content = "x" } },
    { kind = "move", id = "t3", fields = {}, parent_lnum = 3 },
    { kind = "reopen", id = "t4" },
  })
  local shape = vim.tbl_map(function(c)
    return { c.command.type, c.command.temp_id, c.command.args.id, c.command.args.parent_id, c.command.args.due }
  end, cmds)
  eq("ops become sync commands linked by temp_id", shape, {
    { "item_add", "yadoist-line-3", nil, nil, { date = "2026-09-24" } },
    { "item_close", nil, "yadoist-line-3" },
    { "item_add", "yadoist-line-4", nil, "yadoist-line-3" },
    { "item_update", nil, "t1", nil, vim.NIL },
    { "item_update", nil, "t2", nil, { date = "2026-09-24T15:00:00" } },
    { "item_move", nil, "t3", "yadoist-line-3" },
    { "item_uncomplete", nil, "t4" },
  })

  -- A fake Sync endpoint: records requests, maps temp ids, fails on demand.
  local real, requests = dapi.sync, {}
  local flaky = true
  dapi.sync = function(commands, cb)
    table.insert(requests, vim.deepcopy(commands))
    if flaky then
      flaky = false
      return cb(nil, "curl failed (exit 28)")
    end
    local status, mapping = {}, {}
    for _, c in ipairs(commands) do
      status[c.uuid] = c.args.content == "bad" and { error = "Invalid argument value" } or "ok"
      if c.temp_id then
        mapping[c.temp_id] = "real-" .. c.temp_id
      end
    end
    cb({ sync_status = status, temp_id_mapping = mapping })
  end

  local ops = {}
  for i = 1, 120 do
    table.insert(ops, { kind = "create", lnum = i, content = "task " .. i, priority = 1, labels = {} })
  end
  ops[120].parent_lnum = 1
  ops[50].content = "bad"
  local result
  sync.apply(ops, function(r) result = r end)
  dapi.sync = real

  eq("120 commands go in two requests, the first one retried",
    vim.tbl_map(function(r) return #r end, requests), { 100, 100, 20 })
  eq("the retry resends the same uuids", requests[1][1].uuid, requests[2][1].uuid)
  eq("a later batch names an earlier batch's task by its real id",
    requests[3][20].args.parent_id, "real-yadoist-line-1")
  check("a failed command is reported and the rest counted",
    result and result.applied == 119 and #result.errors == 1
      and result.errors[1]:find("Invalid argument value", 1, true) ~= nil, vim.inspect(result))
end

----------------------------------------------------------------- due display
print("\ndue display")
do
  local function shown(due)
    return model.due_string({ due = due })
  end
  eq("a one-off date shows as the date", shown({ string = "tomorrow", date = "2026-09-24" }), "2026-09-24")
  eq("a timed one adds the time", shown({ string = "26 Sep 3:00 PM", date = "2026-09-26T15:00:00" }),
    "2026-09-26 15:00")
  local utc = os.time({ year = 2026, month = 9, day = 26, hour = 15 }) + (os.time() - os.time(os.date("!*t")))
  eq("a fixed-timezone time is shown in local time", shown({ string = "3pm", date = "2026-09-26T15:00:00Z" }),
    os.date("%Y-%m-%d %H:%M", utc))
  eq("a recurring date keeps its words",
    shown({ string = "every saturday", date = "2026-09-26", is_recurring = true }), "every saturday")

  local buf, st = mount(fixture())
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "- [ ] Buy milk @errand !p2 <friday>" })
  local ops = ops_for(buf, st)
  eq("typing words in the <...> still sends them to Todoist's parser",
    #ops == 1 and ops[1].fields or ops, { due_string = "friday" })
end

------------------------------------------------------------------ curl config
print("\ncurl config")
do
  local cfg = dapi._build_config("POST", "https://x/y", { content = 'say "hi"' }, "tok\\en")
  -- The body is JSON-escaped once, then escaped again for curl's config parser.
  local want = ('{"content":"say \\"hi\\""}'):gsub("\\", "\\\\"):gsub('"', '\\"')
  check("escapes the body for curl's config parser", cfg:find(want, 1, true) ~= nil, cfg .. "\n       want substring: " .. want)
  check("escapes backslashes in the token", cfg:find("Bearer tok\\\\en", 1, true) ~= nil, cfg)
  check("asks curl for the status code", cfg:find('write%-out = "\\n%%{http_code}"') ~= nil, cfg)

  local body, status = dapi._split_status('{"id":"1"}\n200')
  eq("splits body from status", { body, status }, { '{"id":"1"}', 200 })
end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
end
