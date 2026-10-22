-- Headless test suite: nvim --headless -l tests/run.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local parse = require("yadoist.parse")
local render = require("yadoist.render")
local model = require("yadoist.model")
local dapi = require("yadoist.api")
local sync = require("yadoist.sync")
local buffer = require("yadoist.buffer")
local store = require("yadoist.store")

-- Never the real token, and never the network: a test that needs Todoist
-- puts a fake in front of api.request itself.
require("yadoist.config").setup({ token = "test-token" })
local http = dapi.request
dapi.request = function(method, path)
  error(("a test reached the network: %s %s"):format(method, path))
end

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
    sections = { { id = "s1", project_id = "p2", name = "Kitchen", section_order = 1 } },
    labels = {
      { id = "l1", name = "errand" },
      { id = "l2", name = "house" },
      { id = "l3", name = "urgent" },
    },
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

--- Render into a real buffer through buffer.lua itself, identity marks and
--- all, and hand back the state the diff works from.
local function mount(data, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  buffer._state[buf] = { view = opts.view or "all", data = data }
  buffer.render(buf)
  return buf, buffer._state[buf], vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- What :w would send for the buffer as it now stands.
local function ops_for(buf)
  return buffer.compute(buf)
end

--- The ops other than new orders, for tests about something else: a line
--- typed or moved into a list also saves where it was put.
local function changes(ops)
  return vim.tbl_filter(function(o)
    return o.kind ~= "reorder" and o.kind ~= "day_order"
  end, ops or {})
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

--- An untouched buffer must round-trip exactly: render, parse and diff it, and
--- nothing at all may come out.
local function no_ops(name, data, opts)
  local ok, ops, errors = pcall(function()
    local buf, st = mount(data, opts)
    return ops_for(buf, st)
  end)
  check(name, ok and ops ~= nil and #ops == 0 and #(errors or {}) == 0,
    not ok and ops or vim.inspect((errors and #errors > 0) and errors or ops))
end

local function with(fn)
  local d = fixture()
  fn(d)
  return d
end

do
  no_ops("a checklist in a description stays a description",
    with(function(d) d.tasks[1].description = "Steps:\n- [ ] one\n- [x] two\n  - [X] nested\n\\- [ ] escaped" end))
  no_ops("a title ending in <...> keeps it", with(function(d) d.tasks[1].content = "Style the <div>"; d.tasks[1].due = nil end))
  no_ops("a title ending in !p1 keeps it", with(function(d) d.tasks[1].content = "Benchmark !p1"; d.tasks[1].priority = 1 end))
  no_ops("a title ending in @word keeps it", with(function(d) d.tasks[1].content = "Reply to @john" end))
  no_ops("a title ending in several of them keeps them all",
    with(function(d) d.tasks[1].content = "a @b !p2 <c> @{d e}"; d.tasks[1].labels = {}; d.tasks[1].due = nil end))
  no_ops("a title with a backslash where an escape would go keeps it",
    with(function(d) d.tasks[1].content = "path \\<div> and \\\\@x" end))
  no_ops("a label with a space survives", with(function(d) d.tasks[1].labels = { "waiting for" } end))
  no_ops("a label that looks like a braced one survives", with(function(d) d.tasks[1].labels = { "{x", "x}", "a@b" } end))
  no_ops("a tab on a later description line survives", with(function(d) d.tasks[1].description = "code:\n\tindented" end))
  no_ops("a newline in a title renders", with(function(d) d.tasks[1].content = "line one\nline two" end))
  no_ops("whitespace around a title is not an edit", with(function(d) d.tasks[1].content = "  Buy milk \r\n" end))
  no_ops("a newline in a project name renders", with(function(d) d.projects[2].name = "House\nChores" end))
  no_ops("two projects sharing a name keep their own tasks", with(function(d)
    table.insert(d.projects, { id = "p3", name = "House Chores", child_order = 3 })
    table.insert(d.tasks, task("t5", "In the other House Chores", { project_id = "p3" }))
  end))
  no_ops("two sections sharing a name keep their own tasks", with(function(d)
    table.insert(d.sections, { id = "s2", project_id = "p2", name = "Kitchen", section_order = 2 })
    table.insert(d.tasks, task("t6", "In the other Kitchen", { project_id = "p2", section_id = "s2" }))
  end))

  eq("a title that ends like a suffix is drawn escaped",
    render.build(with(function(d) d.tasks[1].content = "Style the <div>"; d.tasks[1].due = nil end))[3],
    "- [ ] Style the \\<div> @errand !p2")
  eq("a label with a space is drawn in braces",
    render.build(with(function(d) d.tasks[1].labels = { "waiting for" } end))[3],
    "- [ ] Buy milk @{waiting for} !p2 <2099-01-01>")
  eq("a description line that reads as a task is drawn escaped",
    render.build(with(function(d) d.tasks[1].description = "- [ ] one" end))[4], "  \\- [ ] one")

  local c, l = parse.split_suffixes("Plan @{waiting for} @errand")
  eq("a braced label is read back", { c, l }, { "Plan", { "waiting for", "errand" } })
  c, l = parse.split_suffixes("Ask \\@john @errand")
  eq("an escaped @ stays in the title", { c, l }, { "Ask @john", { "errand" } })
end

do
  -- Two projects called House Chores. The headings yadoist drew know which is
  -- which; one typed by hand cannot.
  local function twins()
    return with(function(d)
      table.insert(d.projects, { id = "p3", name = "House Chores", child_order = 3 })
      table.insert(d.tasks, task("t5", "In the other House Chores", { project_id = "p3" }))
    end)
  end
  local buf, st = mount(twins())
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "# House Chores", "", "- [ ] Under a third heading" })
  local ops, errors = ops_for(buf, st)
  check("a hand-typed heading that two projects share is refused",
    #ops == 0 and #errors == 1 and errors[1].msg:find("2 projects are called", 1, true) ~= nil, vim.inspect(errors))

  buf, st = mount(twins())
  vim.api.nvim_set_current_buf(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local second = vim.fn.index(lines, "# House Chores", vim.fn.index(lines, "# House Chores") + 1)
  vim.api.nvim_win_set_cursor(0, { second + 1, 0 })
  vim.cmd("normal! ddP") -- cut and paste the heading back where it was
  ops, errors = ops_for(buf, st)
  check("a heading cut and pasted back is still the project it was drawn for",
    #ops == 0 and #errors == 0, vim.inspect(errors) .. vim.inspect(ops))

  buf, st = mount(fixture())
  vim.api.nvim_buf_set_text(buf, 4, 2, 4, 7, { "Home" })
  ops = ops_for(buf, st)
  eq("editing a heading renames its project",
    vim.tbl_map(function(o) return { o.kind, o.target, o.id, o.name } end, ops), { { "rename", "project", "p2", "Home Chores" } })

  buf, st = mount(fixture())
  vim.api.nvim_buf_set_text(buf, 9, 3, 9, 10, { "Pantry" })
  ops = ops_for(buf, st)
  eq("and a section heading its section",
    vim.tbl_map(function(o) return { o.kind, o.target, o.id, o.name } end, ops), { { "rename", "section", "s1", "Pantry" } })

  buf, st = mount(fixture())
  vim.api.nvim_buf_set_text(buf, 4, 2, 4, 14, { "Inbox" })
  ops, errors = ops_for(buf, st)
  check("renaming a project to a name another one has is refused",
    #ops == 0 and #errors == 1 and errors[1].lnum == 5, vim.inspect(errors))

  eq("renames are sent as project and section updates",
    vim.tbl_map(function(c) return { c.command.type, c.command.args.id, c.command.args.name } end,
      sync._commands_for({ { kind = "rename", target = "project", id = "p2", name = "Home" },
        { kind = "rename", target = "section", id = "s1", name = "Pantry" } })),
    { { "project_update", "p2", "Home" }, { "section_update", "s1", "Pantry" } })
end

do
  -- The property every item above is a case of: whatever Todoist holds, an
  -- untouched buffer sends nothing. Random titles, descriptions, labels and
  -- names, built from the pieces most likely to be misread. Set
  -- YADOIST_FUZZ_ROUNDS and YADOIST_FUZZ_SEED to look harder.
  local rounds = tonumber(vim.env.YADOIST_FUZZ_ROUNDS) or 300
  math.randomseed(tonumber(vim.env.YADOIST_FUZZ_SEED) or 20261022)
  local function pick(list)
    return list[math.random(#list)]
  end
  local words = { "a", "Buy", "milk", "<div>", "<", ">", "<a @b>", "!p1", "!p4", "!p", "@john", "@", "@{x y}", "@{",
    "}", "{x}", "\\", "\\\\", "\\<x>", "\\@y", "- [ ]", "[x]", "#", "##", "bob@example.com", "\t", "\n", "\r\n", "  " }
  local function title()
    local parts = { pick({ "Task", "x", "#", "- [ ]", "<y>", "@z" }) }
    for _ = 1, math.random(0, 5) do
      table.insert(parts, pick(words))
    end
    return table.concat(parts, pick({ " ", " ", "", "  " }))
  end
  local lines = { "Steps:", "- [ ] one", "- [x] two", "  - [X] nested", "\\- [ ] escaped", "\\\\- [ ] twice",
    "\tTabbed", "\t- [ ] tabbed box", "# not a heading", "plain", "", "   ", "  indented", "trailing  ", "a\r", "@x !p1 <y>" }
  local function description()
    local out = {}
    for _ = 1, math.random(0, 6) do
      table.insert(out, pick(lines))
    end
    return table.concat(out, pick({ "\n", "\r\n" }))
  end
  local labels = { "errand", "waiting for", "a@b", "{x", "x}", "p1", "<x>", "!p2", "é", "two  spaces", "back\\slash" }
  local names = { "Inbox", "Work", "Work", "# Hashed", "## Two", "  padded  ", "multi\nline", "Kitchen", "Kitchen" }
  local dues = {
    false, { string = "tomorrow", date = "2099-01-02" }, { string = "x", date = "2099-01-02T15:00:00" },
    { string = "every day", date = "2099-01-02", is_recurring = true },
  }

  local failures = {}
  for round = 1, rounds do
    local data = { projects = {}, sections = {}, tasks = {}, labels = {} }
    for i = 1, math.random(1, 4) do
      table.insert(data.projects, { id = "p" .. i, name = i == 1 and "Inbox" or pick(names), inbox_project = i == 1 or nil,
        child_order = math.random(1, 3) })
      if math.random() < 0.5 then
        table.insert(data.sections, { id = "s" .. i, project_id = "p" .. i, name = pick(names), section_order = math.random(1, 3) })
      end
    end
    for i = 1, math.random(1, 8) do
      local project = pick(data.projects)
      local parent = (i > 1 and math.random() < 0.3) and data.tasks[math.random(i - 1)] or nil
      local section = nil
      for _, s in ipairs(data.sections) do
        if s.project_id == project.id and math.random() < 0.5 then
          section = s.id
        end
      end
      local due = pick(dues)
      local t = task("t" .. i, title(), {
        project_id = parent and parent.project_id or project.id,
        section_id = parent and parent.section_id or section,
        parent_id = parent and parent.id or nil,
        child_order = math.random(1, 4),
        priority = math.random(1, 4),
        labels = math.random() < 0.5 and { pick(labels), pick(labels) } or {},
        description = math.random() < 0.6 and description() or nil,
        due = due and vim.deepcopy(due) or nil,
      })
      if t.labels[1] == t.labels[2] then
        t.labels[2] = nil
      end
      if model.content(t) == "" then
        t.content = "x" .. t.content
      end
      table.insert(data.tasks, t)
    end
    local ok, ops, errors = pcall(function()
      local buf, st = mount(data)
      return ops_for(buf, st)
    end)
    if not ok or #ops > 0 or #errors > 0 then
      table.insert(failures, { round = round, err = not ok and ops or nil, ops = ok and ops or nil, errors = ok and errors or nil,
        lines = render.build(data) })
    end
  end
  check(rounds .. " random buffers round-trip without sending anything", #failures == 0,
    failures[1] and vim.inspect(failures[1]))
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
  -- Rewriting the whole line, the way `cc` does: the mark is zero-width, so
  -- it survives as long as the line itself does.
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
  local ops = changes(ops_for(buf, st))
  eq("dragging a task to another project is a move",
    #ops == 1 and { ops[1].kind, ops[1].id, ops[1].fields } or ops,
    { "move", "t1", { project_id = "p2" } })
end

do
  local buf, st = mount(fixture())
  vim.api.nvim_buf_set_lines(buf, 7, 8, false, { "- [ ] Get the wrench back from Dave" })
  local ops = changes(ops_for(buf, st))
  eq("un-indenting a subtask promotes it", #ops == 1 and { ops[1].kind, ops[1].id, ops[1].fields } or ops,
    { "move", "t3", { project_id = "p2" } })
end

do
  -- A deleted line leaves a dead mark on the row below it. It must never be
  -- read as belonging to whatever line now sits there.
  local function kinds(ops)
    return vim.tbl_map(function(o) return o.kind .. ":" .. tostring(o.id or o.content) end, ops or {})
  end
  local buf, st = mount(fixture())
  vim.api.nvim_buf_set_lines(buf, 3, 3, false, { "- [ ] Call mom" }) -- new line under t1
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, {})                   -- dd on t1
  eq("deleting a task above a new line is a delete, not a rename", kinds(ops_for(buf, st)),
    { "create:Call mom", "delete:t1" })

  buf, st = mount(fixture())
  vim.api.nvim_buf_set_lines(buf, 3, 3, false, { "- [ ] Call mom" })
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "- [x] Buy milk @errand !p2 <2099-01-01>" })
  eq("ticking a task above a new line closes it, not renames it", kinds(ops_for(buf, st)),
    { "create:Call mom", "close:t1" })

  buf, st = mount(fixture())
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 3, 3, false, { "- [ ] Call mom" })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  vim.cmd("normal! ddp") -- move Buy milk below the new line
  eq("moving a task below a new line with ddp keeps both, in their new order", kinds(ops_for(buf, st)),
    { "create:Call mom", "reorder:Inbox" })

  for _, keys in ipairs({ "S- [ ] Buy oat milk\27", "0D", ":s/milk/oat milk/\r" }) do
    buf, st = mount(fixture())
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    vim.api.nvim_feedkeys(keys, "x", false)
    local ops = ops_for(buf, st)
    local want = keys == "0D" and { "delete:t1" } or { "update:t1" }
    eq(("%q keeps or drops the task as it should"):format(keys), kinds(ops), want)
  end

  buf, st = mount(fixture())
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  require("yadoist.buffer")._toggle(buf)
  eq("<CR> ticks the task in place", kinds(ops_for(buf, st)), { "close:t1" })
  eq("and leaves its mark where it was",
    #vim.api.nvim_buf_get_extmarks(buf, buffer._ns_ids, { 2, 0 }, { 2, -1 }, {}), 1)
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

print("\nproject views")
do
  local views = require("yadoist.views")

  local function nested()
    return {
      projects = {
        { id = "p1", name = "Inbox", is_inbox_project = true, child_order = 1 },
        { id = "p2", name = "Work", child_order = 2 },
        { id = "p3", name = "Clients", parent_id = "p2", child_order = 3 },
        { id = "p4", name = "Home", child_order = 4 },
        { id = "p5", name = "Empty", child_order = 5 },
      },
      sections = {
        { id = "s1", project_id = "p2", name = "Meetings", section_order = 1 },
        { id = "s2", project_id = "p5", name = "Ideas", section_order = 1 },
      },
      tasks = {
        task("w1", "Ship it", { project_id = "p2" }),
        task("w2", "Call Acme", { project_id = "p3" }),
        task("h1", "Mow", { project_id = "p4" }),
        task("i1", "Inbox thing", {}),
      },
    }
  end

  eq("`project X` and `project/X` name the same view",
    { select(2, views.get("project Work")), select(2, views.get("project/Work")) },
    { "project/Work", "project/Work" })
  eq("a bare `project` is not a view", views.project_name("project"), nil)

  eq("a project view shows the project and its subprojects, nothing else",
    render.build(nested(), { view = "project/Work" }), {
      "# Work", "", "- [ ] Ship it", "", "## Meetings", "",
      "", "# Clients", "", "- [ ] Call Acme",
    })
  eq("project names match ignoring case",
    render.build(nested(), { view = "project work" }), render.build(nested(), { view = "project/Work" }))
  eq("an empty project still gets its heading and sections",
    render.build(nested(), { view = "project/Empty" }), { "# Empty", "", "", "## Ideas" })
  eq("an unknown project draws nothing",
    render.build(nested(), { view = "project/Nope" }), { "# (nothing in project Nope)" })
  eq("unknown names suggest close ones",
    views.suggest("work stuff", nested().projects), { "Work" })

  local buf, st = mount(nested(), { view = "project/Work" })
  local ops, errors = ops_for(buf, st)
  check("an untouched project view produces no operations", ops and #ops == 0,
    vim.inspect(errors or ops))

  buf, st = mount(nested(), { view = "project/Empty" })
  vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "- [ ] First idea" })
  ops = ops_for(buf, st)
  eq("a task added to an empty project view lands in that project",
    #ops == 1 and { ops[1].kind, ops[1].project_id } or ops, { "create", "p5" })
end

print("\ndescriptions")
do
  local function described(description)
    local data = fixture()
    data.tasks[1].description = description
    return data
  end

  local tricky = "2% from the corner shop\n\nsecond paragraph\n  # indented further\nnot a #heading"
  local lines = render.build(described(tricky))
  eq("a description is drawn under its task, indented", { unpack(lines, 3, 9) }, {
    "- [ ] Buy milk @errand !p2 <2099-01-01>",
    "  2% from the corner shop",
    "",
    "  second paragraph",
    "    # indented further",
    "  not a #heading",
    "",
  })

  local entries, errors = parse.buffer(lines)
  eq("a description reads back exactly, paragraphs and extra indent included",
    #errors == 0 and entries[1].description or errors, tricky)
  eq("a task without one reads back as empty", entries[2].description, "")

  local buf, st = mount(described(tricky))
  local ops, errs = ops_for(buf, st)
  check("an untouched description produces no operations", ops and #ops == 0, vim.inspect(errs or ops))

  buf, st = mount(described("\n\nleading and trailing junk  \r\n  \r\nmore\n\n  "))
  ops = ops_for(buf, st)
  check("line endings and trailing blanks are not edits", ops and #ops == 0, vim.inspect(ops))

  buf, st = mount(described("old"))
  vim.api.nvim_buf_set_lines(buf, 3, 4, false, { "  new", "  second line" })
  ops = ops_for(buf, st)
  eq("editing a description updates it",
    #ops == 1 and ops[1].fields or ops, { description = "new\nsecond line" })

  buf, st = mount(described("old"))
  vim.api.nvim_buf_set_lines(buf, 3, 4, false, {})
  ops = ops_for(buf, st)
  eq("deleting every description line clears it",
    #ops == 1 and ops[1].fields or ops, { description = "" })

  buf, st = mount(fixture())
  vim.api.nvim_buf_set_lines(buf, 3, 3, false, { "  added later" })
  ops = ops_for(buf, st)
  eq("adding a description to an existing task", #ops == 1 and ops[1].fields or ops, { description = "added later" })

  buf, st = mount(fixture())
  vim.api.nvim_buf_set_lines(buf, 2, 2, false, { "- [ ] New thing", "  with notes" })
  ops = changes(ops_for(buf, st))
  eq("a new task carries its description",
    #ops == 1 and { ops[1].kind, ops[1].description } or ops, { "create", "with notes" })
  local cmd = sync._commands_for(ops)[1].command
  eq("and sends it to Todoist", cmd.args.description, "with notes")

  local _, orphan = parse.buffer({ "# Inbox", "", "  floating" })
  eq("a description with no task above it is an error", orphan[1] and orphan[1].msg, "description has no task above it")

  local nested = fixture()
  nested.tasks[3].description = "the big one"
  eq("a subtask's description is indented past the subtask",
    render.build(nested)[9], "    the big one")

  buf, st = mount(fixture())
  vim.api.nvim_buf_set_lines(buf, 2, 2, false, { "- [ ] Parent", "  notes", "", "  - [ ] Child" })
  ops = changes(ops_for(buf, st))
  eq("a gap before a subtask is not part of the parent's description",
    #ops == 2 and { ops[1].description, ops[2].description } or ops, { "notes", nil })

  local _, unindented = parse.buffer({ "# Inbox", "", "- [ ] Task", "loose text" })
  check("unindented text is still an error", #unindented == 1, vim.inspect(unindented))

  local today = os.date("%Y-%m-%d")
  local dated = described("for today")
  dated.tasks[1].due = { string = today, date = today }
  local day = render.build(dated, { view = "today" })
  check("date views draw descriptions too", vim.tbl_contains(day, "  for today"), vim.inspect(day))
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
  ops = changes(ops_for(buf, st))
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
  ops = changes(ops_for(buf, st))
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
  ops = changes(ops_for(buf, st))
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
      { id = "s1", project_id = "p1", name = "Gone", section_order = 1, is_deleted = true },
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

print("\norder and placement")
do
  local d = fixture()
  d.sections = { -- v1 sections carry section_order, not child_order
    { id = "zz", project_id = "p2", name = "First", section_order = 1 },
    { id = "aa", project_id = "p2", name = "Second", section_order = 2 },
  }
  d.tasks[4].section_id = "zz"
  eq("sections are drawn in Todoist's section_order",
    vim.tbl_filter(function(l) return l:match("^## ") end, render.build(d)), { "## First", "## Second" })

  local tree = { sections = {}, tasks = {}, projects = {
    { id = "p1", name = "Inbox", inbox_project = true, child_order = 0 },
    { id = "a", name = "A", child_order = 1 }, { id = "b", name = "B", child_order = 2 },
    { id = "a1", name = "A1", parent_id = "a", child_order = 1 },
    { id = "a2", name = "A2", parent_id = "a", child_order = 2 },
    { id = "b1", name = "B1", parent_id = "b", child_order = 1 },
    { id = "b1x", name = "B1x", parent_id = "b1", child_order = 1 },
  } }
  local lines, _, _, meta = render.build(tree)
  eq("projects are drawn in sidebar (depth-first) order",
    vim.tbl_filter(function(l) return l:match("^# ") end, lines), { "# Inbox", "# A", "# A1", "# A2", "# B", "# B1", "# B1x" })
  local notes = {}
  for _, a in ipairs(meta.annotations) do
    notes[lines[a.lnum]] = a.text
  end
  eq("a nested project's heading says what it is nested in",
    { notes["# A1"], notes["# B1x"], notes["# A"] }, { "in A", "in B › B1", nil })

  eq("an empty Inbox still gets its heading in the inbox view", render.build({ sections = {}, tasks = {},
    projects = { { id = "p1", name = "Inbox", inbox_project = true, child_order = 0 } } }, { view = "inbox" }), { "# Inbox" })

  -- Todoist goes on returning a deleted project's tasks, not marked deleted,
  -- for minutes afterwards. They must not be drawn, or :w would move them.
  d = fixture()
  d.projects[2].is_deleted = true
  eq("a deleted project's tasks are not drawn", render.build(d), { "# Inbox", "", "- [ ] Buy milk @errand !p2 <2099-01-01>" })
end

print("\ndescriptions left behind")
do
  local function kinds(ops)
    return vim.tbl_map(function(o) return o.kind .. ":" .. tostring(o.id or o.content) end, ops or {})
  end
  local function under(lines, text)
    return vim.fn.index(lines, text)
  end

  local d = fixture()
  table.insert(d.tasks, task("t0", "Above", { child_order = 0 }))
  d.tasks[1].description = "notes\n\nmore notes"
  local buf, st = mount(d)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local row = under(lines, "- [ ] Buy milk @errand !p2 <2099-01-01>")
  vim.api.nvim_buf_set_lines(buf, row, row + 1, false, {}) -- dd on the task line only
  local ops, errors = ops_for(buf, st)
  eq("deleting a task line does not hand its description to the task above", kinds(ops), { "delete:t1" })

  d = fixture()
  d.tasks[1].description = "notes"
  buf, st = mount(d)
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, {}) -- the first task under its heading
  ops, errors = ops_for(buf, st)
  check("nor leaves an error behind when it was the first under its heading",
    #errors == 0 and vim.deep_equal(kinds(ops), { "delete:t1" }), vim.inspect(errors) .. vim.inspect(ops))

  d = fixture()
  table.insert(d.tasks, task("t0", "Above", { child_order = 0 }))
  d.tasks[1].description = "notes"
  buf, st = mount(d)
  vim.api.nvim_set_current_buf(buf)
  lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  row = under(lines, "- [ ] Buy milk @errand !p2 <2099-01-01>")
  vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
  vim.cmd("move 1") -- up above "Above", without its notes
  ops = ops_for(buf, st)
  eq("a task moved without its description keeps it", kinds(ops), { "reorder:Inbox" })

  d = fixture()
  d.tasks[1].description = "code:\n  indented"
  table.insert(d.tasks, task("t0", "Above", { child_order = 0 }))
  buf, st = mount(d)
  lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  row = under(lines, "- [ ] Buy milk @errand !p2 <2099-01-01>")
  vim.api.nvim_buf_set_text(buf, row, 0, row, 0, { "  " }) -- >> on the task line alone
  ops = changes(ops_for(buf, st))
  eq("indenting a task alone does not change its description", kinds(ops), { "move:t1" })

  buf, st = mount(fixture())
  vim.api.nvim_buf_set_lines(buf, 3, 3, false, { "  typed under Buy milk" })
  ops = ops_for(buf, st)
  eq("a line typed under a task is its description", #ops == 1 and ops[1].fields or ops, { description = "typed under Buy milk" })
end

print("\nsaving the order")
do
  local function abc()
    return {
      projects = { { id = "p1", name = "Inbox", inbox_project = true, child_order = 0 }, { id = "p2", name = "Work", child_order = 1 } },
      sections = {},
      tasks = {
        task("a", "A", { child_order = 1 }), task("b", "B", { child_order = 2 }), task("c", "C", { child_order = 3 }),
        task("w", "W", { project_id = "p2", child_order = 1 }),
      },
    }
  end
  local function orders(ops)
    return vim.tbl_map(function(o)
      if o.kind == "reorder" then
        return vim.tbl_map(function(i) return (i.id or ("line " .. i.lnum)) .. "=" .. i.child_order end, o.items)
      elseif o.kind == "day_order" then
        return o.ids
      end
      return o.kind
    end, ops)
  end

  local buf, st = mount(abc())
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  vim.cmd("move 2") -- C to the top
  eq(":move within a list saves the new order", orders(ops_for(buf, st)), { { "c=1", "a=2", "b=3" } })

  buf, st = mount(abc())
  vim.api.nvim_buf_set_lines(buf, 3, 3, false, { "- [ ] New" })
  eq("a new line between two others is put there", orders(ops_for(buf, st)), { "create", { "a=1", "line 4=2", "b=3", "c=4" } })

  buf, st = mount(abc())
  vim.api.nvim_buf_set_lines(buf, 5, 5, false, { "- [ ] New" })
  eq("one at the end needs no order, since that is where Todoist adds it", orders(ops_for(buf, st)), { "create" })

  buf, st = mount(abc())
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, {})
  vim.api.nvim_buf_set_lines(buf, 6, 6, false, { "- [ ] A" })
  eq("a task moved into a list is put where it was dropped", orders(ops_for(buf, st)), { "move", { "a=1", "w=2" } })

  -- In a filtered view a list may be only partly shown. K2 is not overdue,
  -- so overdue shows only K1 and K3 under their parent.
  local today = model.today()
  local yesterday = model.date_after(-1)
  local data = {
    projects = { { id = "p1", name = "Inbox", inbox_project = true, child_order = 0 } },
    sections = {},
    tasks = {
      task("p", "Parent"),
      task("k1", "K1", { parent_id = "p", child_order = 1, due = { date = yesterday, string = "x" } }),
      task("k2", "K2", { parent_id = "p", child_order = 2 }),
      task("k3", "K3", { parent_id = "p", child_order = 3, due = { date = yesterday, string = "x" } }),
    },
  }
  buf, st = mount(data, { view = "overdue" })
  eq("(overdue shows part of the list)", vim.api.nvim_buf_get_lines(buf, 0, -1, false),
    { "# Inbox", "", "- [ ] Parent", "  - [ ] K1 <" .. yesterday .. ">", "  - [ ] K3 <" .. yesterday .. ">" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  vim.cmd("move 3")
  eq("a task the view hides keeps its place after the one before it", orders(ops_for(buf, st)), { { "k3=1", "k1=2", "k2=3" } })

  -- Date views save the order within a day.
  data = {
    projects = { { id = "p1", name = "Inbox", inbox_project = true, child_order = 0 } },
    sections = {},
    tasks = {
      task("d1", "First", { child_order = 1, due = { date = today, string = "x" } }),
      task("d2", "Second", { child_order = 2, due = { date = today, string = "x" } }),
    },
  }
  buf, st = mount(data, { view = "today" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  vim.cmd("move 2")
  eq("moving a line within a day saves the day's order", orders(ops_for(buf, st)), { { "d2", "d1" } })

  eq("orders are sent as item_reorder and item_update_day_orders",
    vim.tbl_map(function(c) return { c.command.type, c.command.args } end, sync._commands_for({
      { kind = "reorder", items = { { id = "a", child_order = 1 }, { lnum = 7, child_order = 2 } } },
      { kind = "day_order", ids = { "d2", "d1" } },
    })),
    {
      { "item_reorder", { items = { { id = "a", child_order = 1 }, { id = "yadoist-line-7", child_order = 2 } } } },
      { "item_update_day_orders", { ids_to_orders = { d2 = 1, d1 = 2 } } },
    })
  eq("and counted as lists and days", sync.describe({ { kind = "reorder" }, { kind = "reorder" }, { kind = "day_order" } }),
    "2 lists reordered, 1 day reordered")
end

print("\npreview")
do
  local preview = require("yadoist.preview")
  local config = require("yadoist.config")
  local asked, answer = nil, 1
  local real_confirm = vim.fn.confirm
  vim.fn.confirm = function(msg, choices)
    asked = { msg = msg, choices = choices }
    return answer
  end
  local function ask(ops, info)
    asked = nil
    return preview.confirm(ops, info or {})
  end

  local buf, st = mount(fixture())
  vim.api.nvim_buf_set_text(buf, 2, 6, 2, 14, { "Buy oat milk" })
  local ops, _, info = ops_for(buf, st)
  ask(ops, info)
  check("an ordinary edit is sent without asking", asked == nil)
  config.options.confirm = "always"
  ask(ops, info)
  check("unless every write is to be asked about", asked ~= nil and asked.choices == "&Send\n&Cancel"
    and asked.msg:find('change    "Buy milk": title', 1, true) ~= nil, asked and asked.msg)
  config.options.confirm = true

  buf, st = mount(fixture())
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, {})
  ops, _, info = ops_for(buf, st)
  answer = 2
  local kept = ask(ops, info)
  check("a delete is asked about, and can be left out", asked ~= nil and #kept == 0
    and asked.msg:find("for everyone its project is shared with", 1, true) ~= nil, asked and asked.msg)
  answer = 3
  check("or the whole write cancelled", ask(ops, info) == nil)
  config.options.confirm = false
  answer = 1
  check("unless asking is turned off", ask(ops, info) == ops and asked == nil)
  config.setup({ token = "test-token", confirm_delete = false })
  check("as the old confirm_delete = false still does", config.options.confirm == false)
  config.setup({ token = "test-token" })

  -- Deleting a heading line drops its tasks under the heading above: the
  -- mass move that is easy to make by accident.
  buf, st = mount(with(function(d)
    d.sections, d.tasks[4] = {}, nil
  end))
  vim.api.nvim_buf_set_lines(buf, 4, 5, false, {}) -- "# House Chores"
  ops, _, info = ops_for(buf, st)
  ask(ops, info)
  check("moving tasks after deleting a heading is asked about", asked ~= nil and info.headings_removed == 1
    and asked.msg:find('move      "Fix the leaky sink" to Inbox', 1, true) ~= nil, asked and asked.msg)

  -- A parent drawn only because a subtask matched the view has subtasks the
  -- view hides, and Todoist completes or deletes them along with it.
  local yesterday = model.date_after(-1)
  local data = {
    projects = { { id = "p1", name = "Inbox", inbox_project = true, child_order = 0 } },
    sections = {},
    tasks = {
      task("o", "Before", { child_order = 0, due = { date = yesterday, string = "x" } }),
      task("p", "Parent", { child_order = 1 }),
      task("k1", "Late child", { parent_id = "p", child_order = 1, due = { date = yesterday, string = "x" } }),
      task("k2", "Hidden child", { parent_id = "p", child_order = 2 }),
    },
  }
  buf, st = mount(data, { view = "overdue" })
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local row = vim.fn.index(lines, "- [ ] Parent")
  vim.api.nvim_buf_set_text(buf, row, 3, row, 4, { "x" })
  ops, _, info = ops_for(buf, st)
  eq("ticking it names the subtasks it completes that the view hides",
    vim.tbl_map(function(o) return { o.kind, o.hidden } end, ops), { { "close", { "Hidden child" } } })
  ask(ops, info)
  check("and is asked about", asked ~= nil and asked.msg:find("with 1 subtask this view hides: Hidden child", 1, true) ~= nil,
    asked and asked.msg)

  buf, st = mount(data, { view = "overdue" })
  vim.api.nvim_buf_set_lines(buf, row, row + 2, false, {}) -- Parent and its shown subtask
  ops = ops_for(buf, st)
  local delete = vim.tbl_filter(function(o) return o.kind == "delete" and o.id == "p" end, ops)[1]
  eq("so is deleting it", delete and delete.hidden, { "Hidden child" })

  vim.fn.confirm = real_confirm
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
    return ops_for(buf, st)
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
  ops, errors = ops_for(buf, st)
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

  -- A fake Sync endpoint behind the HTTP layer, so the retries and the store
  -- run for real: it records requests, maps temp ids, and drops the first
  -- request the way a lost connection does.
  local real_request, real_backoff = dapi.request, dapi.backoff
  local requests, bodies, flaky = {}, {}, true
  dapi.backoff = function() return 0 end
  dapi.request = function(_, _, body, cb)
    table.insert(requests, vim.deepcopy(body.commands or {}))
    table.insert(bodies, vim.deepcopy(body))
    vim.schedule(function()
      if flaky then
        flaky = false
        return cb(nil, "curl failed (exit 28)", { retry = true })
      end
      local status, mapping = {}, {}
      for _, c in ipairs(body.commands or {}) do
        status[c.uuid] = c.args.content == "bad" and { error = "Invalid argument value" } or "ok"
        if c.temp_id then
          mapping[c.temp_id] = "real-" .. c.temp_id
        end
      end
      cb({ sync_status = status, temp_id_mapping = mapping, sync_token = "t" .. #requests }, nil, { status = 200 })
    end)
  end

  store.reset()
  local ops = {}
  for i = 1, 120 do
    table.insert(ops, { kind = "create", lnum = i, content = "task " .. i, priority = 1, labels = {} })
  end
  ops[120].parent_lnum = 1
  ops[50].content = "bad"
  local result
  sync.apply(ops, function(r) result = r end)
  vim.wait(2000, function() return result ~= nil end)
  dapi.request, dapi.backoff = real_request, real_backoff

  eq("120 commands go in two requests, the first one retried",
    vim.tbl_map(function(r) return #r end, requests), { 100, 100, 20 })
  eq("the retry resends the same uuids", requests[1][1].uuid, requests[2][1].uuid)
  eq("a later batch names an earlier batch's task by its real id",
    requests[3][20].args.parent_id, "real-yadoist-line-1")
  check("a failed command is reported and the rest counted",
    result and result.applied == 119 and #result.errors == 1
      and result.errors[1]:find("Invalid argument value", 1, true) ~= nil, vim.inspect(result and result.errors))
  check("and which op it was is known", result and result.failed[ops[50]] == "Invalid argument value")
  eq("each request reads back what changed, from the last token",
    { bodies[1].sync_token, bodies[3].sync_token, bodies[3].resource_types },
    { "*", "t2", { "items", "projects", "sections", "labels" } })
end

print("\nretries")
do
  local real_request, real_backoff = dapi.request, dapi.backoff
  dapi.backoff = function() return 0 end
  local function attempts(replies)
    local n = 0
    dapi.request = function(_, _, _, cb)
      n = n + 1
      local reply = replies[math.min(n, #replies)]
      vim.schedule(function()
        cb(reply.ok, reply.err, reply.info or {})
      end)
    end
    local outcome
    dapi.call("POST", "/sync", {}, function(res, err) outcome = { res = res, err = err } end)
    vim.wait(2000, function() return outcome ~= nil end)
    return n, outcome
  end
  local n, out = attempts({ { err = "curl failed (exit 7)", info = { retry = true } }, { ok = { fine = true } } })
  check("a dropped connection is tried again", n == 2 and out.res and out.res.fine, vim.inspect({ n, out }))
  n = attempts({ { err = "HTTP 503", info = { status = 503, retry = true } } })
  eq("a server error is tried twice more, then given up", n, 3)
  n = attempts({ { err = "HTTP 400: Invalid argument", info = { status = 400 } } })
  eq("a 400 is not tried again", n, 1)
  n = attempts({ { err = "HTTP 401", info = { status = 401 } } })
  eq("nor is a 401", n, 1)
  local waited
  dapi.backoff = function() return 0 end
  local real_defer = vim.defer_fn
  vim.defer_fn = function(fn, ms) waited = ms; return real_defer(fn, 0) end
  n = attempts({ { err = "HTTP 429", info = { status = 429, retry = true, retry_after = 2 } }, { ok = true } })
  vim.defer_fn = real_defer
  check("a 429 is tried again after the wait it asks for", n == 2 and waited == 2000, vim.inspect({ n, waited }))
  n, out = attempts({ { err = "HTTP 429", info = { status = 429, retry = true, retry_after = 600 } } })
  check("but not when it asks for longer than is worth waiting", n == 1 and out.err:find("wait 600s", 1, true) ~= nil,
    vim.inspect({ n, out }))
  dapi.request, dapi.backoff = real_request, real_backoff

  -- vim.system throws, rather than calling back, when curl cannot be run.
  local real_system = vim.system
  vim.system = function() error("ENOENT: no such file or directory (cmd): 'curl'") end
  local got
  http("GET", "/x", nil, function(res, err) got = { res = res, err = err } end)
  vim.system = real_system
  vim.wait(1000, function() return got ~= nil end)
  check("curl that cannot be run is reported, not thrown", got and got.res == nil and got.err:find("could not run curl", 1, true) ~= nil,
    vim.inspect(got))

  local body, status, after = dapi._split_status('{"error":"slow down"}\n429 30')
  eq("reads Retry-After after the status", { body, status, after }, { '{"error":"slow down"}', 429, 30 })
  _, status, after = dapi._split_status("\n200 %header{retry-after}")
  eq("and copes with a curl too old to fill it in", { status, after }, { 200, nil })
end

print("\nstore")
do
  local real_request = dapi.request
  local replies, sent = {}, {}
  dapi.request = function(_, _, body, cb)
    table.insert(sent, body)
    local reply = table.remove(replies, 1)
    vim.schedule(function() cb(reply, nil, { status = 200 }) end)
  end
  local function read()
    local data
    store.read(function(d) data = d end)
    vim.wait(1000, function() return data ~= nil end)
    return data
  end
  store.reset()
  replies = {
    { full_sync = true, sync_token = "a", items = { task("x1", "One"), task("x2", "Two") },
      projects = { { id = "p1", name = "Inbox", inbox_project = true } } },
    { full_sync = false, sync_token = "b", items = {
      task("x1", "One, renamed"),
      task("x2", "Two", { checked = true, completed_at = "2026-10-22T01:00:00Z" }),
      task("x3", "Three"),
    }, projects = {} },
    { full_sync = false, sync_token = "c", items = { task("x3", "Three", { is_deleted = true }) } },
  }
  local data = read()
  eq("the first read takes everything", vim.tbl_map(function(t) return t.id end, data.tasks), { "x1", "x2" })
  data = read()
  eq("a later one merges only what changed, and drops completed tasks",
    vim.tbl_map(function(t) return t.content end, data.tasks), { "One, renamed", "Three" })
  data = read()
  eq("and deleted ones", vim.tbl_map(function(t) return t.id end, data.tasks), { "x1" })
  eq("each from the token the last one gave", vim.tbl_map(function(b) return b.sync_token end, sent), { "*", "a", "b" })
  eq("and the projects are kept between reads", #data.projects, 1)

  -- Two reads in flight at once, answered out of order: the late, older
  -- answer must not undo the newer one.
  store.reset()
  local held = {}
  dapi.request = function(_, _, body, cb) table.insert(held, { body = body, cb = cb }) end
  local done = 0
  store.read(function() done = done + 1 end)
  store.read(function() done = done + 1 end)
  held[2].cb({ full_sync = true, sync_token = "new", items = { task("y1", "Newer") } }, nil, {})
  held[1].cb({ full_sync = true, sync_token = "old", items = { task("y1", "Older") } }, nil, {})
  eq("a reply that arrives after a newer one is not merged", store.snapshot().tasks[1].content, "Newer")
  dapi.request = real_request
  store.reset()
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
  eq("a recurring date keeps its words",
    shown({ string = "every saturday", date = "2026-09-26", is_recurring = true }), "every saturday")

  local buf, st = mount(fixture())
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "- [ ] Buy milk @errand !p2 <friday>" })
  local ops = ops_for(buf, st)
  eq("typing words in the <...> still sends them to Todoist's parser",
    #ops == 1 and ops[1].fields or ops, { due_string = "friday" })
end

------------------------------------------------------------------ time zones
print("\ntime zones")
do
  -- os.date reads the zone through the C library, which only looks at $TZ
  -- again after tzset(), so each zone below is really in force.
  local ffi = require("ffi")
  pcall(ffi.cdef, "void tzset(void);")
  local function in_zone(tz, fn)
    local saved = vim.env.TZ
    vim.env.TZ = tz
    ffi.C.tzset()
    local ok, err = pcall(fn)
    vim.env.TZ = saved
    ffi.C.tzset()
    if not ok then
      error(err, 0)
    end
  end
  local real_now = model.now
  local function at(y, m, d, h, mi)
    return function() return model.utc_time(y, m, d, h, mi, 0) end
  end

  -- 2026-10-22T22:00:00Z, as each zone sees it. Sydney is in daylight saving
  -- (UTC+11) by then; New York still is too (UTC-4).
  local want = {
    ["Australia/Sydney"] = { "2026-10-23 09:00", "2026-10-23" },
    ["America/New_York"] = { "2026-10-22 18:00", "2026-10-22" },
    ["UTC"] = { "2026-10-22 22:00", "2026-10-22" },
    ["Asia/Kolkata"] = { "2026-10-23 03:30", "2026-10-23" },
  }
  for tz, w in pairs(want) do
    in_zone(tz, function()
      local fixed = { due = { date = "2026-10-22T22:00:00Z", timezone = "Australia/Sydney", string = "x" } }
      eq(tz .. ": a fixed-timezone time is shown in local time", model.due_string(fixed), w[1])
      eq(tz .. ": and filed under its local day", model.due_date(fixed), w[2])
    end)
  end

  in_zone("Australia/Sydney", function()
    local winter = { due = { date = "2026-06-15T00:00:00Z", string = "x" } }
    local summer = { due = { date = "2026-12-15T00:00:00Z", string = "x" } }
    eq("standard time is UTC+10", model.due_string(winter), "2026-06-15 10:00")
    eq("daylight saving is UTC+11", model.due_string(summer), "2026-12-15 11:00")

    local nine = { due = { date = "2026-10-22T22:00:00Z", timezone = "Australia/Sydney", string = "x" } }
    eq("rescheduling a fixed-timezone task keeps its local time",
      model.reschedule(nine, "2026-10-25"), { due_datetime = "2026-10-24T22:00:00Z", due_timezone = "Australia/Sydney" })
    local before_dst_ends = { due = { date = "2027-04-02T22:00:00Z", timezone = "Australia/Sydney", string = "x" } }
    eq("even across the end of daylight saving",
      model.reschedule(before_dst_ends, "2027-04-05"), { due_datetime = "2027-04-04T23:00:00Z", due_timezone = "Australia/Sydney" })
    eq("a floating time is kept as written",
      model.reschedule({ due = { date = "2026-10-23T09:00:00" } }, "2026-10-25"), { due_datetime = "2026-10-25T09:00:00" })

    -- Noon on Oct 22 in Sydney. A task due at 08:00 tomorrow there is 21:00
    -- today in UTC, which is where it used to be filed.
    model.now = at(2026, 10, 22, 1, 0)
    local data = {
      projects = { { id = "p1", name = "Inbox", inbox_project = true, child_order = 1 } },
      sections = {},
      tasks = { task("z1", "Early tomorrow", { due = { date = "2026-10-22T21:00:00Z", timezone = "Australia/Sydney", string = "x" } }) },
    }
    eq("today is the local day", model.today(), "2026-10-22")
    eq("a task due early tomorrow is not in today", render.build(data, { view = "today" }), { "# Oct 22 · Today · Thursday" })
    local upcoming = render.build(data, { view = "upcoming" })
    eq("it is filed under tomorrow", { upcoming[4], upcoming[6] },
      { "# Oct 23 · Tomorrow · Friday", "- [ ] Early tomorrow <2026-10-23 08:00>" })

    local buf, st = mount(data, { view = "upcoming" })
    local ops = ops_for(buf, st)
    check("and an untouched view of it sends nothing", #ops == 0, vim.inspect(ops))
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    vim.cmd("move 1") -- under today's heading
    ops = ops_for(buf, st)
    eq("moving it to today keeps 08:00 local", #ops == 1 and ops[1].fields or ops,
      { due_datetime = "2026-10-21T21:00:00Z", due_timezone = "Australia/Sydney" })
    model.now = real_now
  end)
end

------------------------------------------------------------------ curl config
print("\ncurl config")
do
  local cfg = dapi._build_config("POST", "https://x/y", { content = 'say "hi"' }, "tok\\en")
  -- The body is JSON-escaped once, then escaped again for curl's config parser.
  local want = ('{"content":"say \\"hi\\""}'):gsub("\\", "\\\\"):gsub('"', '\\"')
  check("escapes the body for curl's config parser", cfg:find(want, 1, true) ~= nil, cfg .. "\n       want substring: " .. want)
  check("escapes backslashes in the token", cfg:find("Bearer tok\\\\en", 1, true) ~= nil, cfg)
  check("asks curl for the status code and Retry-After",
    cfg:find('write-out = "\\n%{http_code} %header{retry-after}"', 1, true) ~= nil, cfg)

  local body, status = dapi._split_status('{"id":"1"}\n200')
  eq("splits body from status", { body, status }, { '{"id":"1"}', 200 })
end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
end
