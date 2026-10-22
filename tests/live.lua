-- Live tests, against the real Todoist API and your account. From the repo
-- root, with $TODOIST_API_TOKEN set:
--   YADOIST_LIVE=1 nvim --headless -u NONE -i NONE -l tests/live.lua
--
-- The first part only reads: it draws every view from your account and checks
-- that :w would send nothing, without ever writing. The second part writes,
-- but only into two throwaway projects (and a throwaway label) that it makes
-- and deletes again at the end, whatever happens in between. Meanwhile
-- yadoist is set up to draw only those projects, and every request passes a
-- guard that refuses, before anything is sent, any command naming something
-- the test did not make. Never run in CI.
vim.opt.rtp:prepend(".")
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
vim.cmd("filetype plugin on | runtime plugin/yadoist.lua")

local function out(text)
  io.stdout:write(text, "\n")
end
if vim.env.YADOIST_LIVE ~= "1" then
  out("This talks to your Todoist account; set YADOIST_LIVE=1 to run it.")
  return
end

local api, buffer, store, model = require("yadoist.api"), require("yadoist.buffer"), require("yadoist.store"), require("yadoist.model")
local render = require("yadoist.render")

local STAMP = tostring(os.time())
local NAME = "yadoistLive" .. STAMP
local LABEL = "yadoist live " .. STAMP

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
  end
  out(("  %s %s%s"):format(ok and "ok  " or "FAIL", name, (not ok and detail) and ("\n       " .. tostring(detail)) or ""))
end

-------------------------------------------------------------------- the guard
-- Reading is always allowed. Writing: only commands about what the test made.
local reading_only = true
local ours = { projects = {}, sections = {}, tasks = {}, labels = {} }
local function owned(id)
  return type(id) == "string" and (id:match("^yadoist%-line%-") ~= nil or ours.tasks[id] == true)
end
local function allowed(cmd)
  local a, t = cmd.args or {}, cmd.type
  if t == "project_add" then return a.name == NAME end
  if t == "section_add" then return ours.projects[a.project_id] == true end
  if t == "label_add" then return a.name == LABEL end
  if t == "label_delete" then return ours.labels[a.id] == true end
  if t == "project_update" or t == "project_delete" then return ours.projects[a.id] == true end
  if t == "section_update" then return ours.sections[a.id] == true end
  if t:match("^item_") then
    if a.id ~= nil and not owned(a.id) then return false end
    if a.parent_id ~= nil and not owned(a.parent_id) then return false end
    if a.project_id ~= nil and not ours.projects[a.project_id] then return false end
    if a.section_id ~= nil and not ours.sections[a.section_id] then return false end
    for _, item in ipairs(a.items or {}) do
      if not owned(item.id) then return false end
    end
    for id in pairs(a.ids_to_orders or {}) do
      if not owned(id) then return false end
    end
    -- A new task with neither would land in the Inbox.
    return t ~= "item_add" or a.project_id ~= nil or a.parent_id ~= nil
  end
  return false
end

local real, sent = api.request, {}
api.request = function(method, path, body, cb)
  local writing = method ~= "GET" and not (path == "/sync" and not (body and body.commands))
  if writing then
    if reading_only then
      error("LIVE GUARD: the read-only part tried to write " .. method .. " " .. path)
    elseif path == "/sync" then
      for _, cmd in ipairs(body.commands) do
        if not allowed(cmd) then
          error("LIVE GUARD refused " .. cmd.type .. " " .. vim.inspect(cmd.args))
        end
        table.insert(sent, cmd.type)
      end
    elseif path == "/tasks/quick" and body.text:find("#" .. NAME, 1, true) then
      table.insert(sent, "quick_add")
    else
      error("LIVE GUARD refused " .. method .. " " .. path)
    end
  end
  return real(method, path, body, cb)
end

--- The commands sent since the last call.
local function take()
  local s = sent
  sent = {}
  return s
end

--- Everything in the throwaway projects is the test's to change.
local function adopt()
  for _, t in ipairs(store.snapshot().tasks) do
    if ours.projects[t.project_id] then
      ours.tasks[t.id] = true
    end
  end
end

---------------------------------------------------------------------- helpers
vim.notify = function() end
vim.fn.confirm = function()
  return 1 -- "Send": the guard has already looked at what would go
end

local function uuid()
  return vim.fn.sha256(tostring(math.random()) .. tostring(vim.uv.hrtime())):sub(1, 32)
end

--- Send commands straight to Todoist, as setup or as changes made elsewhere.
local function sync(commands)
  for _, c in ipairs(commands) do
    c.uuid = c.uuid or uuid()
  end
  local res, err
  store.sync(commands, function(r, e) res, err = r, e end)
  vim.wait(30000, function() return res ~= nil or err ~= nil end, 20)
  take()
  assert(not err, err)
  for _, c in ipairs(commands) do
    assert(res.sync_status[c.uuid] == "ok", c.type .. ": " .. vim.inspect(res.sync_status[c.uuid]))
  end
  adopt()
  return res
end

local function settle(b)
  return vim.wait(30000, function()
    local st = buffer._state[b]
    return st ~= nil and st.data ~= nil and not st.busy
  end, 20)
end
local function open(view)
  local b = buffer.open(view)
  settle(b)
  adopt()
  return b
end
local function lines(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end
local function find(b, text, from)
  return vim.fn.index(lines(b), text, from or 0)
end
local function write(b)
  vim.api.nvim_set_current_buf(b)
  vim.cmd("write")
  settle(b)
  adopt()
end
local function untouched(b, what)
  local ops, errors = buffer.compute(b)
  check(what .. ": untouched, it sends nothing", #ops == 0 and #errors == 0,
    vim.inspect({ errors = errors, ops = vim.tbl_map(function(o) return { o.kind, o.fields } end, ops) }))
end
--- The 0-based line of the heading drawn for a project or section, as drawn.
local function heading_of(b, id)
  for _, h in ipairs(buffer._state[b].heading_ids) do
    if h.id == id then
      return h.lnum - 1
    end
  end
end
--- Where a heading is now, edits included: from its mark.
local function heading_now(b, id)
  for mark, h in pairs(buffer._state[b].headings) do
    if h.id == id then
      return vim.api.nvim_buf_get_extmark_by_id(b, buffer._ns_ids, mark, {})[1]
    end
  end
end
local function task_named(content)
  for _, t in ipairs(store.snapshot().tasks) do
    if ours.projects[t.project_id] and model.content(t) == content then
      return t
    end
  end
end

-------------------------------------------------------- reading your account
out("\nyour account, read only")
require("yadoist").setup({ refresh_on_focus = false })
for _, view in ipairs({ "all", "today", "upcoming", "overdue", "inbox", "completed" }) do
  local b = open(view)
  local ops, errors = buffer.compute(b)
  check(("%s: drawn from your account, it would send nothing"):format(view), #ops == 0 and #errors == 0,
    vim.inspect({ errors = errors, ops = vim.tbl_map(function(o) return o.kind end, ops) }))
  vim.api.nvim_buf_delete(b, { force = true })
end

---------------------------------------------------- writing, in throwaway projects
local p1, p2, kitchen, dup1, dup2, label

local function run()
  reading_only = false
  out("\nsetup")
  local res = sync({
    { type = "project_add", temp_id = "proj1", args = { name = NAME } },
    { type = "project_add", temp_id = "proj2", args = { name = NAME } },
    { type = "label_add", temp_id = "label", args = { name = LABEL } },
  })
  p1, p2, label = res.temp_id_mapping.proj1, res.temp_id_mapping.proj2, res.temp_id_mapping.label
  ours.projects[p1], ours.projects[p2], ours.labels[label] = true, true, true
  res = sync({
    { type = "section_add", temp_id = "kitchen", args = { name = "Kitchen", project_id = p1 } },
    { type = "section_add", temp_id = "dup1", args = { name = "Dup", project_id = p1 } },
    { type = "section_add", temp_id = "dup2", args = { name = "Dup", project_id = p1 } },
  })
  kitchen, dup1, dup2 = res.temp_id_mapping.kitchen, res.temp_id_mapping.dup1, res.temp_id_mapping.dup2
  ours.sections[kitchen], ours.sections[dup1], ours.sections[dup2] = true, true, true
  out(("  made two projects called %s, three sections, and a label"):format(NAME))
  require("yadoist").setup({ projects = { NAME }, refresh_on_focus = false })

  out("\ntyped lines become tasks, exactly")
  local b = open("project " .. NAME)
  check("both projects of the same name are drawn", heading_of(b, p1) ~= nil and heading_of(b, p2) ~= nil, vim.inspect(lines(b)))
  untouched(b, "the empty project view")
  -- Under each heading, found by its identity, from the bottom up.
  local inserts = {
    { heading_of(b, p2), { "", "- [ ] In the twin project" } },
    { heading_of(b, kitchen), { "", "- [ ] Wipe" } },
    { heading_of(b, dup1), { "", "- [ ] In first Dup" } },
    { heading_of(b, dup2), { "", "- [ ] In second Dup" } },
    { heading_of(b, p1), {
      "",
      "- [ ] Style the \\<div>",
      "- [ ] Benchmark \\!p1 !p1",
      "- [ ] Reply to \\@john @{" .. LABEL .. "}",
      "- [ ] Checklist holder",
      "  Steps:",
      "  \\- [ ] one",
      "  \\- [x] two",
      "  \tindented with a tab",
      "- [ ] Parent",
      "  - [ ] Child",
      "  - [ ] Second child",
      "- [ ] Fixed time",
      "- [ ] Newline later",
    } },
  }
  table.sort(inserts, function(x, y) return x[1] > y[1] end)
  for _, ins in ipairs(inserts) do
    vim.api.nvim_buf_set_lines(b, ins[1] + 1, ins[1] + 1, false, ins[2])
  end
  write(b)
  local kinds = take()
  check("one write creates them all", #kinds == 13 and not vim.tbl_contains(kinds, "item_reorder"), vim.inspect(kinds))
  check("a title ending in <div> keeps it", task_named("Style the <div>") ~= nil and task_named("Style the <div>").due == nil)
  local bench = task_named("Benchmark !p1")
  check("a title ending in !p1 keeps it, and the real !p1 is the priority", bench ~= nil and bench.priority == 4)
  local reply = task_named("Reply to @john")
  check("a title ending in @john keeps it, and a label with a space is applied", reply ~= nil
    and vim.deep_equal(reply.labels, { LABEL }), vim.inspect(reply and reply.labels))
  local holder = task_named("Checklist holder")
  check("a checklist and a tab survive in a description", holder ~= nil
    and holder.description == "Steps:\n- [ ] one\n- [x] two\n\tindented with a tab", vim.inspect(holder and holder.description))
  local parent, child = task_named("Parent"), task_named("Child")
  check("a subtask is created under its new parent", parent ~= nil and child ~= nil and child.parent_id == parent.id)
  local twin, d1, d2 = task_named("In the twin project"), task_named("In first Dup"), task_named("In second Dup")
  check("tasks under same-named headings land in their own project and section",
    twin and twin.project_id == p2 and d1 and d1.section_id == dup1 and d2 and d2.section_id == dup2)
  untouched(b, "redrawn from Todoist's answer to the write")

  out("\nchanges made elsewhere")
  local tomorrow, two = model.date_after(1), model.date_after(2)
  local function local_nine(day)
    return os.time({ year = tonumber(day:sub(1, 4)), month = tonumber(day:sub(6, 7)), day = tonumber(day:sub(9, 10)), hour = 9 })
  end
  sync({
    -- Due at 09:00 tomorrow here, fixed to a time zone, so Todoist keeps it in UTC.
    { type = "item_update", args = { id = task_named("Fixed time").id,
      due = { date = os.date("!%Y-%m-%dT%H:%M:%SZ", local_nine(tomorrow)), timezone = "Australia/Sydney" } } },
    { type = "item_update", args = { id = task_named("Newline later").id, content = "line one\nline two" } },
    { type = "item_update", args = { id = parent.id, due = { date = tomorrow } } },
  })
  check("(Todoist keeps it in UTC, with the zone)", (task_named("Fixed time").due.date or ""):sub(-1) == "Z"
    and task_named("Fixed time").due.timezone == "Australia/Sydney", vim.inspect(task_named("Fixed time").due))
  local deadline = pcall(sync, { { type = "item_update", args = { id = holder.id, deadline = { date = "2099-03-01" } } } })
  out("  setting a deadline " .. (deadline and "worked" or "was refused (deadlines are a paid feature)"))
  vim.cmd("edit")
  settle(b)
  check("a fixed-timezone time is shown in local time", find(b, "- [ ] Fixed time <" .. tomorrow .. " 09:00>") >= 0,
    vim.inspect(vim.tbl_filter(function(l) return l:find("Fixed time", 1, true) end, lines(b))))
  check("a title with a line break is shown on one line", find(b, "- [ ] line one line two") >= 0)
  if deadline then
    local texts = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, vim.api.nvim_get_namespaces().yadoist_beside, 0, -1, { details = true })) do
      texts[m[2]] = table.concat(vim.tbl_map(function(c) return c[1] end, m[4].virt_text or {}))
    end
    check("a deadline is shown beside its line", texts[find(b, "- [ ] Checklist holder")] == "deadline 2099-03-01", vim.inspect(texts))
  end
  untouched(b, "with a fixed time and a line break")

  out("\norder")
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { find(b, "- [ ] Benchmark \\!p1 !p1") + 1, 0 })
  vim.cmd("move " .. (heading_of(b, p1) + 1)) -- to the top of the first project
  write(b)
  check(":move sends the list's new order", vim.deep_equal(take(), { "item_reorder" }))
  check("and it comes back in that order", lines(b)[heading_of(b, p1) + 3] == "- [ ] Benchmark \\!p1 !p1", vim.inspect(lines(b)))
  local at = find(b, "- [ ] Reply to \\@john @{" .. LABEL .. "}")
  vim.api.nvim_buf_set_lines(b, at, at, false, { "- [ ] Inserted above Reply" })
  write(b)
  check("a line typed mid-list is created there, through a temp id in the reorder",
    vim.deep_equal(take(), { "item_add", "item_reorder" })
      and find(b, "- [ ] Inserted above Reply") + 1 == find(b, "- [ ] Reply to \\@john @{" .. LABEL .. "}"), vim.inspect(lines(b)))
  untouched(b, "after reordering")

  out("\nmoves")
  local first_dup = find(b, "- [ ] In first Dup")
  vim.api.nvim_buf_set_lines(b, first_dup, first_dup + 1, false, {})
  local into = heading_now(b, dup2)
  vim.api.nvim_buf_set_lines(b, into + 2, into + 2, false, { "- [ ] In first Dup" }) -- above "In second Dup"
  local twin_line = find(b, "- [ ] In the twin project")
  vim.api.nvim_buf_set_lines(b, twin_line, twin_line + 1, false, {})
  local top = heading_now(b, p1)
  vim.api.nvim_buf_set_lines(b, top + 2, top + 2, false, { "- [ ] In the twin project" })
  write(b)
  kinds = take()
  table.sort(kinds)
  check("moving lines between same-named sections and projects moves the tasks, in place",
    vim.deep_equal(kinds, { "item_move", "item_move", "item_reorder", "item_reorder" }), vim.inspect(kinds))
  local moved_dup, moved_twin = task_named("In first Dup"), task_named("In the twin project")
  check("into the second of two sections with the same name", moved_dup and moved_dup.section_id == dup2)
  check("and into the other of two projects with the same name", moved_twin and moved_twin.project_id == p1 and moved_twin.section_id == nil)
  check("each drawn where it was put", lines(b)[heading_of(b, dup2) + 3] == "- [ ] In first Dup"
    and lines(b)[heading_of(b, p1) + 3] == "- [ ] In the twin project", vim.inspect(lines(b)))
  untouched(b, "after the moves")

  out("\ndate views")
  local u = open("upcoming")
  local day1 = find(u, "# " .. render.day_heading(tomorrow, 1))
  local fixed_line = find(u, "- [ ] Fixed time <" .. tomorrow .. " 09:00>")
  local parent_line = find(u, "- [ ] Parent <" .. tomorrow .. ">")
  check("upcoming shows both of tomorrow's tasks, the timed one after the other",
    day1 >= 0 and parent_line > day1 and fixed_line > parent_line, vim.inspect(lines(u)))
  untouched(u, "upcoming")
  vim.api.nvim_set_current_buf(u)
  vim.api.nvim_win_set_cursor(0, { fixed_line + 1, 0 })
  vim.cmd("move " .. (day1 + 1)) -- to the top of tomorrow
  write(u)
  local first_of_day = "- [ ] Fixed time <" .. tomorrow .. " 09:00>"
  check("moving a line within a day sends the day's order", vim.deep_equal(take(), { "item_update_day_orders" }))
  check("and it comes back in that order, though Todoist does not report it", lines(u)[day1 + 3] == first_of_day, vim.inspect(lines(u)))
  buffer.refresh(u)
  settle(u)
  check("a refresh keeps that order", lines(u)[day1 + 3] == first_of_day, vim.inspect(lines(u)))
  vim.cmd("edit")
  settle(u)
  check("and so does reading everything afresh", lines(u)[day1 + 3] == first_of_day, vim.inspect(lines(u)))
  untouched(u, "upcoming, after a new day order")
  local day2 = find(u, "# " .. render.day_heading(two, 2))
  vim.api.nvim_win_set_cursor(0, { find(u, first_of_day) + 1, 0 })
  vim.cmd("move " .. (day2 + 1))
  write(u)
  local moved = task_named("Fixed time").due
  local want = os.date("!%Y-%m-%dT%H:%M:%SZ", local_nine(two))
  check("moving a fixed-timezone task to another day keeps 09:00 here, and its zone",
    vim.tbl_contains(take(), "item_update") and moved and moved.date == want and moved.timezone == "Australia/Sydney",
    vim.inspect({ got = moved, want = want }))
  check("and it is drawn there", find(u, "- [ ] Fixed time <" .. two .. " 09:00>") > day2, vim.inspect(lines(u)))
  untouched(u, "upcoming, after rescheduling")

  out("\ncompleting and reopening")
  b = open("project " .. NAME)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { find(b, "- [ ] Wipe") + 1, 0 })
  buffer._toggle(b)
  write(b)
  check("ticking a task completes it", vim.deep_equal(take(), { "item_close" }))
  local c = open("completed")
  check("the completed view shows it", find(c, "- [x] Wipe") >= 0, vim.inspect(lines(c)))
  untouched(c, "completed")
  vim.api.nvim_set_current_buf(c)
  vim.api.nvim_win_set_cursor(0, { find(c, "- [x] Wipe") + 1, 0 })
  buffer._toggle(c)
  write(c)
  check("unticking it there reopens it", vim.deep_equal(take(), { "item_uncomplete" }) and task_named("Wipe") ~= nil)

  out("\nfilter and quick add")
  local f = open("filter #" .. NAME)
  check("a filter view shows what the filter matched", find(f, "- [ ] Wipe") >= 0 or find(f, "- [ ] Parent") >= 0, vim.inspect(lines(f)))
  untouched(f, "a filter view")
  require("yadoist").add("Quick live task #" .. NAME)
  vim.wait(30000, function()
    adopt()
    return task_named("Quick live task") ~= nil
  end, 50)
  check(":Yadoist add files the task in the named project", task_named("Quick live task") ~= nil
    and vim.deep_equal(take(), { "quick_add" }))

  out("\nrenames and deletes")
  b = open("project " .. NAME)
  at = find(b, "## Kitchen")
  vim.api.nvim_buf_set_text(b, at, 3, at, 10, { "Pantry" })
  write(b)
  local section
  for _, s in ipairs(store.snapshot().sections) do
    if s.id == kitchen then section = s.name end
  end
  check("editing a section heading renames the section", vim.deep_equal(take(), { "section_update" }) and section == "Pantry", section)
  at = find(b, "- [ ] Style the \\<div>")
  vim.api.nvim_buf_set_lines(b, at, at + 1, false, {})
  write(b)
  check("deleting a line deletes its task", vim.deep_equal(take(), { "item_delete" }) and task_named("Style the <div>") == nil)
  untouched(b, "after a rename and a delete")
  local first = heading_of(b, p1)
  vim.api.nvim_buf_set_text(b, first, 2, first, 2 + #NAME, { NAME .. "Renamed" })
  write(b)
  local project
  for _, p in ipairs(store.snapshot().projects) do
    if p.id == p1 then project = p.name end
  end
  check("editing a project heading renames the project", vim.deep_equal(take(), { "project_update" }) and project == NAME .. "Renamed",
    project)
end

local ok, err = pcall(run)
if not ok then
  failed = failed + 1
  out("  FAIL the run stopped: " .. tostring(err))
end

-------------------------------------------------------------------- cleanup
out("\ncleanup")
local commands = {}
for id in pairs(ours.projects) do
  table.insert(commands, { type = "project_delete", args = { id = id } })
end
for id in pairs(ours.labels) do
  table.insert(commands, { type = "label_delete", args = { id = id } })
end
if #commands > 0 then
  local cleaned, cerr = pcall(sync, commands)
  out(("  deleting %d throwaway projects and labels: %s"):format(#commands, cleaned and "ok" or tostring(cerr)))
end
store.reset()
local data
store.read(function(d) data = d end)
vim.wait(30000, function() return data ~= nil end, 20)
local left = 0
for _, p in ipairs(data and data.projects or {}) do
  if p.name:find(NAME, 1, true) and p.is_deleted ~= true then left = left + 1 end
end
for _, l in ipairs(data and data.labels or {}) do
  if l.name == LABEL then left = left + 1 end
end
check("nothing the test made is left in your account", data ~= nil and left == 0, left)

out(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
end
