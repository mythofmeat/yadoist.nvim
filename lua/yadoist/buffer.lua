-- The task buffer itself: loading, rendering, identity marks, and turning :w
-- into a set of API calls.
local api = require("yadoist.api")
local config = require("yadoist.config")
local diff = require("yadoist.diff")
local highlight = require("yadoist.highlight")
local model = require("yadoist.model")
local parse = require("yadoist.parse")
local render = require("yadoist.render")
local store = require("yadoist.store")
local sync = require("yadoist.sync")
local views = require("yadoist.views")

local M = {}

--- Each view gets its own buffer, so switching between them keeps whatever
--- you had unsaved in the other. Its name says which view it is, which is all
--- loading it needs: :e, :e! and a restored session all go through load().
M.PREFIX = "yadoist://"

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

--- Map buffer lines back to the tasks, headings and descriptions they were
--- rendered from, using the extmarks rather than line numbers so reordering
--- is free. Only live marks count: a mark dies only when its line is deleted,
--- so a dead one says nothing about the line that now sits where it was.
---@return fun(lnum: integer): table|nil task
---@return fun(lnum: integer): table|nil heading
---@return fun(lnum: integer): table|nil owner
local function resolvers(bufnr, st)
  local rows, claimed = {}, {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns_ids, 0, -1, { details = true })) do
    local id, row, details = mark[1], mark[2], mark[4]
    if not (details and details.invalid) then
      rows[row] = rows[row] or {}
      table.insert(rows[row], id)
    end
  end

  local function task(lnum)
    for _, id in ipairs(rows[lnum - 1] or {}) do
      if not claimed[id] and st.marks[id] then
        claimed[id] = true
        return st.marks[id]
      end
    end
    return nil
  end

  local function find(map)
    return function(lnum)
      for _, id in ipairs(rows[lnum - 1] or {}) do
        if map[id] then
          return map[id]
        end
      end
      return nil
    end
  end

  return task, find(st.headings), find(st.owners)
end

--- Zero-width, so editing anything within a line (cc, S, :s) keeps its mark,
--- and only deleting the line itself invalidates it.
local function mark(bufnr, lnum)
  return vim.api.nvim_buf_set_extmark(bufnr, ns_ids, lnum - 1, 0, { invalidate = true })
end

--- Replace the buffer's text without leaving an undo step behind, the way
--- :edit starts a fresh history. Undoing past a redraw would otherwise strip
--- the buffer back to what it held before, or to nothing, and :w would read
--- that as deleting every task.
local function set_text(bufnr, lines)
  local levels = vim.bo[bufnr].undolevels
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].undolevels = -1
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].undolevels = levels
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

  set_text(bufnr, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_ids, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_hl, 0, -1)
  vim.diagnostic.reset(ns_diag, bufnr)

  st.marks, st.known, st.headings, st.heading_ids, st.owners = {}, {}, {}, meta.heading_ids or {}, {}
  for _, entry in ipairs(tasks) do
    st.marks[mark(bufnr, entry.lnum)] = entry.task
    st.known[entry.task.id] = entry.task
  end
  for _, heading in ipairs(st.heading_ids) do
    st.headings[mark(bufnr, heading.lnum)] = heading
  end
  for _, note in ipairs(meta.notes or {}) do
    st.owners[mark(bufnr, note.lnum)] = { id = note.task_id, indent = note.indent }
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

  -- Every live project and section by name, as lists: Todoist lets two share
  -- a name, and a heading typed by hand cannot say which of them it means.
  st.project_ids, st.section_ids, st.by_date = {}, {}, nil
  local function add(map, name, id)
    name = model.one_line(name)
    map[name] = map[name] or {}
    table.insert(map[name], id)
  end
  for _, project in ipairs(st.data.projects or {}) do
    if project.is_deleted ~= true and project.is_archived ~= true then
      add(st.project_ids, project.name, project.id)
    end
  end
  for _, section in ipairs(st.data.sections or {}) do
    if section.is_deleted ~= true and section.is_archived ~= true then
      st.section_ids[section.project_id] = st.section_ids[section.project_id] or {}
      add(st.section_ids[section.project_id], section.name, section.id)
    end
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

  vim.bo[bufnr].modified = false

  if cursor and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_set_cursor, win, { math.min(cursor[1], #lines), cursor[2] })
  end
end

--- Re-fetch and redraw.
---@param opts table|nil
---  force    redraw even over unsaved edits
---  announce say how many tasks there are once drawn
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
  -- What the buffer held when the fetch went out. The changedtick is enough
  -- to see it is untouched, usually, but Neovim also bumps it on its own, as
  -- it does after a BufReadCmd, so when it has moved the text decides.
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local text = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  store.read(function(data, err)
    st.busy = false
    if err then
      return notify(err, vim.log.levels.ERROR)
    end
    if state[bufnr] ~= st or not vim.api.nvim_buf_is_loaded(bufnr) then
      return -- reloaded or closed meanwhile
    end
    if vim.api.nvim_buf_get_changedtick(bufnr) ~= tick
      and not vim.deep_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), text) then
      -- Typed into while the fetch was out. Redrawing now would throw that
      -- away; what was fetched is kept, and shows on the next redraw.
      return
    end
    st.data = data
    M.render(bufnr)
    local view = views.get(st.view)
    if view.project and #views.find_projects(view.project, data.projects) == 0 then
      local close = views.suggest(view.project, data.projects)
      return notify(("no project called %q%s"):format(view.project,
        #close > 0 and (" — did you mean " .. table.concat(close, ", ") .. "?") or ""), vim.log.levels.ERROR)
    end
    if opts.announce then
      local shown = 0
      for _ in pairs(st.known or {}) do
        shown = shown + 1
      end
      notify(("%s: %d tasks"):format(view.label, shown))
    end
  end)
end

--- Re-fetch and redraw, asking first if that would throw away unsaved edits.
function M.reload(bufnr)
  if vim.bo[bufnr].modified then
    local choice = vim.fn.confirm("Throw away your unsaved edits and reload from Todoist?", "&Reload\n&Cancel", 2, "Question")
    if choice ~= 1 then
      return
    end
  end
  M.refresh(bufnr, { force = true, announce = true })
end

--- Parse the buffer and work out what :w would send.
---@return table[] ops, table[] errors, table info
function M.compute(bufnr)
  local st = state[bufnr]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local entries, errors, headings = parse.buffer(lines)
  local task, heading, owner = resolvers(bufnr, st)

  -- A description line with no task above it is an error, unless it was
  -- drawn under a task: then its task's line was deleted or moved away, and
  -- the line goes wherever that task went.
  local orphans, rest = {}, {}
  for _, err in ipairs(errors) do
    if err.orphan and owner(err.lnum) then
      table.insert(orphans, { lnum = err.lnum, line = lines[err.lnum] })
    else
      table.insert(rest, err)
    end
  end
  if #rest > 0 then
    return {}, rest, {}
  end

  return diff.compute({
    entries = entries,
    headings = headings,
    resolve = task,
    heading = heading,
    owner = owner,
    orphans = orphans,
    heading_ids = st.heading_ids,
    known = st.known,
    project_ids = st.project_ids or {},
    section_ids = st.section_ids or {},
    by_date = st.by_date,
    label_names = st.label_names,
  })
end

--- The task as a line now describes it, for once a write of that line has
--- landed: diffing the line against this finds nothing more to send.
local function as_drawn(e, id, ops, result)
  local old = e.task or {}
  local task = vim.deepcopy(old)
  local function real(lnum)
    return lnum and result.ids[sync.temp_id(lnum)]
  end
  task.id = id
  task.content = e.content
  task.description = e.description
  task.labels = vim.deepcopy(e.labels)
  task.priority = model.ui_to_api_priority(e.priority)
  if e.due_string ~= model.due_string(old) or e.reschedule or e.due_date then
    task.due = e.due_string and { string = e.due_string } or nil
  end
  if not e.task then
    task.project_id, task.section_id = e.project_id, e.section_id
    task.parent_id = e.parent_id or real(e.parent_lnum)
  end
  for _, op in ipairs(ops) do
    if op.kind == "move" then
      local to = op.fields
      if to.parent_id or op.parent_lnum then
        task.parent_id = to.parent_id or real(op.parent_lnum)
        task.project_id, task.section_id = e.project_id or task.project_id, e.section_id
      elseif to.section_id then
        task.project_id, task.section_id, task.parent_id = e.project_id, to.section_id, nil
      else
        task.project_id, task.section_id, task.parent_id = to.project_id, nil, nil
      end
    end
  end
  task.checked, task.completed_at, task.is_completed = e.done or nil, nil, nil
  return task
end

--- After a write where some changes failed, the buffer is left as it is, so
--- they can be put right and written again, with a diagnostic on each line
--- whose change failed. What did land is folded into what the buffer knows: a
--- line whose changes all landed is known by what it now says, and a created
--- one gets its new task's mark, so the next :w sends only what failed.
local function fold(bufnr, st, result)
  local landed, mine = {}, {}
  for _, op in ipairs(result.ops) do
    local e = op.entry
    if e then
      mine[e] = mine[e] or {}
      table.insert(mine[e], op)
      landed[e] = landed[e] ~= false and not result.failed[op]
    elseif not result.failed[op] then
      if op.kind == "delete" then
        st.known[op.id] = nil
      elseif op.kind == "rename" then
        for _, drawn in ipairs(st.heading_ids) do
          if drawn.kind == op.target and drawn.id == op.id then
            drawn.name = op.name
          end
        end
      end
    end
  end

  for e, ok in pairs(landed) do
    local id = e.task and e.task.id or result.ids[sync.temp_id(e.lnum)]
    if ok and id then
      for m, task in pairs(st.marks) do
        if task.id == id then
          st.marks[m] = nil
        end
      end
      local task = as_drawn(e, id, mine[e], result)
      st.marks[mark(bufnr, e.lnum)] = task
      st.known[id] = task
      if not e.task then
        for _, item in ipairs(e.lines) do
          st.owners[mark(bufnr, item.lnum)] = { id = id, indent = (e.depth + 1) * 2 }
        end
      end
    end
  end

  local items = {}
  for _, op in ipairs(result.ops) do
    local lnum = op.entry and op.entry.lnum or op.lnum
    if result.failed[op] and lnum then
      table.insert(items, {
        lnum = lnum - 1,
        col = 0,
        severity = vim.diagnostic.severity.ERROR,
        message = result.failed[op],
        source = "yadoist",
      })
    end
  end
  vim.diagnostic.set(ns_diag, bufnr, items)
end

--- Take in Todoist's answer to a write.
local function finish(bufnr, st, outcome)
  st.busy, st.waited_out = false, nil
  if state[bufnr] ~= st or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  vim.bo[bufnr].modifiable = true
  local result, err = outcome.result, outcome.err
  if err then
    return notify(err, vim.log.levels.WARN) -- nothing was sent; the edits stay
  end
  if #result.ops == 0 then
    return notify("nothing was sent", vim.log.levels.WARN)
  end
  if #result.errors == 0 then
    -- The reply carried everything that changed, so draw from that.
    st.data = store.snapshot()
    M.render(bufnr)
    return notify(sync.describe(result.ops))
  end
  fold(bufnr, st, result)
  local sent = vim.tbl_filter(function(op)
    return not result.failed[op]
  end, result.ops)
  notify(("%s%d failed:\n%s"):format(#sent > 0 and (sync.describe(sent) .. ", but ") or "",
    #result.errors, table.concat(result.errors, "\n")), vim.log.levels.ERROR)
end

--- How long :w waits for Todoist before leaving a write to finish in the
--- background: long enough for every batch to be tried again.
function M.patience(commands)
  return math.ceil(math.max(commands, 1) / 100) * (api.retries + 1) * (config.options.timeout + 2000) + 5000
end

local function write(bufnr)
  local st = state[bufnr]
  if not st then
    return
  end
  if st.waited_out then
    return notify("Todoist has not answered the last write yet — try again once it has", vim.log.levels.WARN)
  end
  -- A refresh in flight will not redraw over edits, so let it land rather
  -- than refuse the write.
  if st.busy then
    vim.wait(config.options.timeout + 1000, function()
      return not st.busy
    end, 10)
    if st.busy then
      return notify("still talking to Todoist — try again in a moment", vim.log.levels.WARN)
    end
  end
  if not st.data then
    -- Nothing was ever fetched, so we have no project ids to write against and
    -- no idea which tasks already exist.
    return notify("tasks have not loaded yet — :e to try again", vim.log.levels.WARN)
  end

  if st.by_date and st.drawn_on ~= model.today() then
    -- The headings still say which day was "Today" when they were drawn, so a
    -- task moved under one would land on yesterday's date.
    return notify(("this view's days were drawn on %s — :e! redraws them, which drops unsaved edits, so yank them first")
      :format(st.drawn_on), vim.log.levels.WARN)
  end

  local ops, errors = M.compute(bufnr)
  if #errors > 0 then
    return report(bufnr, errors)
  end

  vim.diagnostic.reset(ns_diag, bufnr)

  if #ops == 0 then
    vim.bo[bufnr].modified = false
    return notify("no changes")
  end

  -- The reply is matched back to lines by their numbers, so the buffer is
  -- held still until it comes.
  st.busy = true
  vim.bo[bufnr].modifiable = false
  local outcome
  sync.apply(ops, function(result, err)
    outcome = { result = result, err = err }
    if st.waited_out then
      finish(bufnr, st, outcome)
    end
  end)
  -- Waiting here rather than finishing later is what lets :wq, :x and ZZ
  -- quit: they look at 'modified' as soon as this autocommand returns.
  vim.wait(M.patience(#ops * 2), function()
    return outcome ~= nil
  end, 10)
  if outcome then
    finish(bufnr, st, outcome)
  else
    st.waited_out = true
    notify("Todoist has not answered yet — the buffer stays read-only until it does", vim.log.levels.WARN)
  end
end

local function toggle(bufnr)
  if not vim.bo[bufnr].modifiable then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  if not line then
    return
  end
  local indent, box = line:match("^(%s*)%- %[([ xX])%]")
  if indent then
    -- Change just that character: replacing the whole line would delete it,
    -- and its identity mark with it.
    local col = #indent + 3
    vim.api.nvim_buf_set_text(bufnr, lnum - 1, col, lnum - 1, col + 1, { box == " " and "x" or " " })
  end
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

  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = group,
    buffer = bufnr,
    desc = "Forget an unloaded task buffer; loading it again starts afresh",
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
  map(maps.refresh, function() M.reload(bufnr) end, "yadoist: re-fetch from Todoist")
  map(maps.close, function() vim.cmd("bdelete") end, "yadoist: close")
end

--- Set up a task buffer from its name and fetch into it. This is what
--- BufReadCmd runs, so it happens on first opening, on :e and :e!, after the
--- buffer was closed with :bdelete, and when a session brings it back.
function M.load(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local view, view_name = views.get(name:sub(#M.PREFIX + 1))
  if not view then
    state[bufnr] = nil
    vim.bo[bufnr].buftype = "nofile"
    set_text(bufnr, {})
    vim.bo[bufnr].modified = false
    return notify(("%q is not a view — try one of: %s"):format(name, table.concat(views.names(), ", ")),
      vim.log.levels.ERROR)
  end

  highlight.setup()
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].buflisted = true
  vim.b[bufnr].yadoist_view = view_name
  state[bufnr] = { view = view_name, marks = {}, known = {}, headings = {}, heading_ids = {}, owners = {} }
  attach(bufnr)
  if vim.bo[bufnr].filetype ~= "yadoist" then
    vim.bo[bufnr].filetype = "yadoist"
  end
  set_text(bufnr, { "# loading " .. view.label .. "..." })
  vim.bo[bufnr].modified = false
  M.refresh(bufnr, { force = true })
end

--- Route every yadoist:// buffer through load(). plugin/yadoist.lua does the
--- same at startup; this covers being required without it.
function M.setup_autocmds()
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = vim.api.nvim_create_augroup("Yadoist", { clear = true }),
    pattern = M.PREFIX .. "*",
    desc = "Load a yadoist task buffer from Todoist",
    callback = function(ev)
      M.load(ev.buf)
    end,
  })
end

--- Project names from whatever has been fetched so far, for completion. Empty
--- until a task buffer has loaded once.
function M.project_names()
  local names = {}
  for _, project in ipairs(store.snapshot().projects) do
    if project.is_deleted ~= true and project.is_archived ~= true then
      table.insert(names, project.name)
    end
  end
  return names
end

--- Spell a project view's name the way Todoist does when that is already
--- known, so `project work` and `project Work` share a buffer.
local function canonical(name)
  local project = views.project_name(name)
  if not project then
    return name
  end
  for _, have in ipairs(M.project_names()) do
    if have:lower() == project:lower() then
      return "project/" .. have
    end
  end
  return name
end

function M.open(name)
  if name and name:match("^project%s*$") then
    return notify("which project? — :Yadoist project <name>", vim.log.levels.ERROR)
  end
  local view, view_name = views.get(canonical(name))
  if not view then
    return notify(("no view called %q — try one of: %s"):format(
      tostring(name), table.concat(views.names(), ", ")), vim.log.levels.ERROR)
  end

  M.setup_autocmds()
  local bufnr = vim.fn.bufadd(M.PREFIX .. view_name)
  local loaded = vim.api.nvim_buf_is_loaded(bufnr)
  vim.api.nvim_set_current_buf(bufnr) -- loading it runs load() through BufReadCmd
  if not state[bufnr] then
    M.load(bufnr) -- it was loaded some other way, without a fetch
  elseif loaded then
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
    if vim.api.nvim_buf_is_loaded(other) then
      return other
    end
  end
  return nil
end

-- Exposed for the tests.
M._state = state
M._ns_ids = ns_ids
M._toggle = toggle

return M
