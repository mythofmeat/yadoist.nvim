-- The task buffer itself: fetching, rendering, identity marks, and turning :w
-- into a set of API calls.
local api = require("yadoist.api")
local config = require("yadoist.config")
local diff = require("yadoist.diff")
local highlight = require("yadoist.highlight")
local model = require("yadoist.model")
local parse = require("yadoist.parse")
local render = require("yadoist.render")
local sync = require("yadoist.sync")
local views = require("yadoist.views")

local M = {}

--- Each view gets its own buffer, so switching between them keeps whatever
--- you had unsaved in the other.
local function buffer_name(view)
  return "yadoist://" .. view
end
local ns_ids = vim.api.nvim_create_namespace("yadoist_ids")
local ns_hl = vim.api.nvim_create_namespace("yadoist_highlights")
local ns_diag = vim.api.nvim_create_namespace("yadoist_diagnostics")

---@type table<integer, table>
local state = {}

local function notify(msg, level)
  vim.notify("yadoist: " .. msg, level or vim.log.levels.INFO)
end

--- Surface parse and resolution problems as diagnostics on the offending
--- lines, and refuse to send anything.
local function report(bufnr, errors)
  local items = {}
  for _, e in ipairs(errors) do
    table.insert(items, {
      lnum = math.max(0, (e.lnum or 1) - 1),
      col = 0,
      severity = vim.diagnostic.severity.ERROR,
      message = e.msg,
      source = "yadoist",
    })
  end
  vim.diagnostic.set(ns_diag, bufnr, items)
  local summary = errors[1] and ("line %d: %s"):format(errors[1].lnum or 0, errors[1].msg) or ""
  if #errors > 1 then
    summary = summary .. ("\n(and %d more)"):format(#errors - 1)
  end
  notify("nothing was sent to Todoist — " .. summary, vim.log.levels.ERROR)
end

--- Map buffer lines back to the tasks they were rendered from, using the
--- extmarks rather than line numbers so reordering is free.
---
--- Returns two lookups: one over marks that are still live, and one over marks
--- that were invalidated because their whole line was replaced. They share a
--- claim set, so no task can be matched twice.
local function resolvers(bufnr, st)
  local live, dead, claimed = {}, {}, {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns_ids, 0, -1, { details = true })) do
    local id, row, details = mark[1], mark[2], mark[4]
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

function M.render(bufnr)
  local st = state[bufnr]
  if not st or not st.data then
    return
  end

  local cursor
  local win = vim.fn.bufwinid(bufnr)
  if win ~= -1 then
    cursor = vim.api.nvim_win_get_cursor(win)
  end

  local lines, tasks, highlights, meta = render.build(st.data, {
    projects = config.options.projects,
    view = st.view,
  })

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_ids, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_hl, 0, -1)
  vim.diagnostic.reset(ns_diag, bufnr)

  st.marks, st.known = {}, {}
  for _, entry in ipairs(tasks) do
    local row = entry.lnum - 1
    local mark = vim.api.nvim_buf_set_extmark(bufnr, ns_ids, row, 0, {
      end_row = row,
      end_col = #lines[entry.lnum],
      invalidate = true,
    })
    st.marks[mark] = entry.task
    st.known[entry.task.id] = entry.task
  end

  for _, h in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(bufnr, ns_hl, h.lnum - 1, h.from, {
      end_col = h.to,
      hl_group = h.group,
    })
  end
  for _, a in ipairs(meta.annotations or {}) do
    vim.api.nvim_buf_set_extmark(bufnr, ns_hl, a.lnum - 1, 0, {
      virt_text = { { a.text, "YadoistAnnotation" } },
      virt_text_pos = "eol",
    })
  end

  -- Labels on any task count as existing, not just personal ones: a shared
  -- project's tasks can carry labels that are not in your own list.
  st.label_names = nil
  if not config.options.create_labels then
    st.label_names = {}
    for _, label in ipairs(st.data.labels or {}) do
      st.label_names[label.name] = true
    end
    for _, task in ipairs(st.data.tasks or {}) do
      for _, l in ipairs(model.labels(task)) do
        st.label_names[l] = true
      end
    end
  end

  st.project_ids, st.section_ids, st.by_date = {}, {}, nil
  for _, project in ipairs(st.data.projects or {}) do
    st.project_ids[project.name] = project.id
  end
  st.drawn_on = model.today()
  if meta.headings then
    st.by_date = { headings = meta.headings, placed = meta.placed, overdue = render.OVERDUE }
    for _, project in ipairs(st.data.projects or {}) do
      if model.is_inbox(project) then
        st.by_date.inbox_id = project.id
      end
    end
  end
  for _, section in ipairs(st.data.sections or {}) do
    st.section_ids[section.project_id] = st.section_ids[section.project_id] or {}
    st.section_ids[section.project_id][section.name] = section.id
  end

  vim.bo[bufnr].modified = false

  if cursor and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_set_cursor, win, { math.min(cursor[1], #lines), cursor[2] })
  end
end

function M.refresh(bufnr, opts)
  opts = opts or {}
  local st = state[bufnr]
  if not st or st.busy then
    return
  end
  if vim.bo[bufnr].modified and not opts.force then
    return -- never clobber unsaved edits
  end

  st.busy = true
  api.fetch(function(data, err)
    st.busy = false
    if err then
      return notify(err, vim.log.levels.ERROR)
    end
    st.data = data
    M.render(bufnr)
    if opts.announce then
      local shown = 0
      for _ in pairs(st.known or {}) do
        shown = shown + 1
      end
      notify(("%s: %d tasks"):format(views.get(st.view).label, shown))
    end
  end)
end

local function write(bufnr)
  local st = state[bufnr]
  if not st then
    return
  end
  if st.busy then
    return notify("still talking to Todoist — try again in a moment", vim.log.levels.WARN)
  end
  if not st.data then
    -- Nothing was ever fetched, so we have no project ids to write against and
    -- no idea which tasks already exist.
    return notify("tasks have not loaded yet — press R (or :YadoistRefresh) first", vim.log.levels.WARN)
  end

  if st.by_date and st.drawn_on ~= model.today() then
    -- The headings still say which day was "Today" when they were drawn, so a
    -- task moved under one would land on yesterday's date.
    return notify(("this view's days were drawn on %s — press R to redraw them before saving (it drops unsaved edits, so yank them first)")
      :format(st.drawn_on), vim.log.levels.WARN)
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local entries, errors = parse.buffer(lines)
  if #errors > 0 then
    return report(bufnr, errors)
  end

  local resolve, resolve_stale = resolvers(bufnr, st)
  local ops, resolve_errors = diff.compute({
    entries = entries,
    resolve = resolve,
    resolve_stale = resolve_stale,
    known = st.known,
    project_ids = st.project_ids or {},
    section_ids = st.section_ids or {},
    by_date = st.by_date,
    label_names = st.label_names,
  })
  if #resolve_errors > 0 then
    return report(bufnr, resolve_errors)
  end

  vim.diagnostic.reset(ns_diag, bufnr)

  if #ops == 0 then
    vim.bo[bufnr].modified = false
    return notify("no changes")
  end

  st.busy = true
  sync.apply(ops, function(result, err)
    st.busy = false
    if err then
      return notify(err, vim.log.levels.WARN)
    end
    if #result.errors > 0 then
      notify(("%s, but %d failed:\n%s"):format(
        sync.describe(ops), #result.errors, table.concat(result.errors, "\n")), vim.log.levels.ERROR)
    else
      notify(sync.describe(ops))
    end
    M.refresh(bufnr, { force = true })
  end)
end

local function toggle(bufnr)
  local win = vim.api.nvim_get_current_win()
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  if not line then
    return
  end
  local flipped = line:gsub("^(%s*%- %[)([ xX])(%])", function(open, mark, close)
    return open .. (mark == " " and "x" or " ") .. close
  end, 1)
  if flipped ~= line then
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { flipped })
  end
end

local function find_existing(name)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == name then
      return bufnr
    end
  end
  return nil
end

local function attach(bufnr)
  local group = vim.api.nvim_create_augroup("YadoistBuffer" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = bufnr,
    desc = "Send buffer edits to Todoist",
    callback = function()
      write(bufnr)
    end,
  })

  if config.options.refresh_on_focus then
    vim.api.nvim_create_autocmd({ "BufEnter", "FocusGained" }, {
      group = group,
      buffer = bufnr,
      desc = "Re-fetch so a shared list does not sit stale on screen",
      callback = function()
        M.refresh(bufnr)
      end,
    })
  end

  -- A date view left open past midnight would keep showing yesterday as
  -- "Today". Nothing needs fetching to fix that, only redrawing, so do it as
  -- soon as the buffer is looked at again, as long as it has no unsaved edits.
  vim.api.nvim_create_autocmd({ "BufEnter", "FocusGained", "CursorHold" }, {
    group = group,
    buffer = bufnr,
    desc = "Redraw a date view whose days have gone stale",
    callback = function()
      local st = state[bufnr]
      if st and st.by_date and st.drawn_on ~= model.today() and not vim.bo[bufnr].modified then
        M.render(bufnr)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      state[bufnr] = nil
    end,
  })

  local maps = config.options.keymaps or {}
  local function map(lhs, fn, desc)
    if lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, fn, { buffer = bufnr, desc = desc, nowait = true })
    end
  end
  map(maps.toggle, function() toggle(bufnr) end, "yadoist: toggle the task under the cursor")
  map(maps.refresh, function() M.refresh(bufnr, { force = true, announce = true }) end, "yadoist: re-fetch from Todoist")
  map(maps.close, function() vim.cmd("bdelete") end, "yadoist: close")
end

function M.open(name)
  local view, view_name = views.get(name)
  if not view then
    return notify(("no view called %q — try one of: %s"):format(
      tostring(name), table.concat(views.names(), ", ")), vim.log.levels.ERROR)
  end

  highlight.setup()

  local buffer = buffer_name(view_name)
  local bufnr = find_existing(buffer)
  local fresh = bufnr == nil
  if fresh then
    bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(bufnr, buffer)
    vim.bo[bufnr].buftype = "acwrite"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].filetype = "yadoist"
    vim.b[bufnr].yadoist_view = view_name
    state[bufnr] = { marks = {}, known = {}, view = view_name }
    attach(bufnr)
  end

  vim.api.nvim_set_current_buf(bufnr)
  if fresh or not state[bufnr].data then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "# loading " .. view.label .. "..." })
    vim.bo[bufnr].modified = false
    M.refresh(bufnr, { force = true })
  else
    M.refresh(bufnr)
  end
  return bufnr
end

--- The task buffer to act on: the current one if it is a task buffer, else any
--- task buffer that happens to be open.
function M.current()
  local bufnr = vim.api.nvim_get_current_buf()
  if state[bufnr] then
    return bufnr
  end
  for other in pairs(state) do
    if vim.api.nvim_buf_is_valid(other) then
      return other
    end
  end
  return nil
end

-- Exposed for the tests.
M._state = state
M._ns_ids = ns_ids
M._resolvers = resolvers

return M
