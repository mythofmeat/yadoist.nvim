-- Task data -> buffer text. The inverse of parse.lua.
--
-- Highlight spans are produced here rather than by a syntax file, so they can
-- be driven by the data: an overdue date is coloured differently from a future
-- one because we know the date, not because of how it is spelled.
local model = require("yadoist.model")
local views = require("yadoist.views")

local M = {}

local today = model.today

--- Render one task, returning the line and its highlight spans as
--- { group, start_col, end_col } byte offsets.
function M.task_line(task, depth)
  local done = model.is_completed(task)
  local spans = {}
  local line = string.rep("  ", depth)

  local at = #line
  line = line .. "- [" .. (done and "x" or " ") .. "] "
  table.insert(spans, { done and "YadoistCheckboxDone" or "YadoistCheckboxOpen", at, #line })

  at = #line
  line = line .. task.content
  table.insert(spans, { done and "YadoistContentDone" or "YadoistContent", at, #line })

  for _, label in ipairs(model.labels(task)) do
    line = line .. " "
    at = #line
    line = line .. "@" .. label
    table.insert(spans, { "YadoistLabel", at, #line })
  end

  local priority = model.api_to_ui_priority(task.priority)
  if priority < 4 then
    line = line .. " "
    at = #line
    line = line .. "!p" .. priority
    table.insert(spans, { "YadoistPriority" .. priority, at, #line })
  end

  local due = model.due_string(task)
  if due then
    line = line .. " "
    at = #line
    line = line .. "<" .. due .. ">"
    local group = "YadoistDue"
    local date = model.due_date(task)
    if date then
      local now = today()
      if date < now then
        group = "YadoistDueOverdue"
      elseif date == now then
        group = "YadoistDueToday"
      end
    end
    table.insert(spans, { group, at, #line })
  end

  return line, spans
end

local function by_order(a, b)
  local oa, ob = model.order(a), model.order(b)
  if oa ~= ob then
    return oa < ob
  end
  return tostring(a.id) < tostring(b.id)
end

--- The heading for one day, spelled the way Todoist spells it:
--- "Sep 24 · Tomorrow · Thursday".
function M.day_heading(date, offset)
  local y, m, d = date:match("^(%d+)-(%d+)-(%d+)$")
  local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
  local parts = { os.date("%b", t) .. " " .. tonumber(d) }
  if offset == 0 then
    table.insert(parts, "Today")
  elseif offset == 1 then
    table.insert(parts, "Tomorrow")
  end
  table.insert(parts, os.date("%A", t))
  return table.concat(parts, " · ")
end

M.OVERDUE = "Overdue"

-- Within a day, Todoist's own manual day order first, then priority, then the
-- task's place in its project.
local function by_day(a, b)
  local function day_order(t)
    local n = tonumber(t.day_order)
    return (n and n >= 0) and n or math.huge
  end
  local da, db = day_order(a), day_order(b)
  if da ~= db then
    return da < db
  end
  local pa, pb = tonumber(a.priority) or 1, tonumber(b.priority) or 1
  if pa ~= pb then
    return pa > pb
  end
  return by_order(a, b)
end

--- The date views: `# Overdue` first when there is anything overdue, then one
--- heading per day, every day drawn even when empty so there is somewhere to
--- add a task for it.
---
--- A task sits under its own due date when it matches the view on its own, and
--- under its parent otherwise — so a subtask due today whose parent is due next
--- week still shows up today, and an undated subtask follows its parent. A task
--- is nested under its parent only when both land under the same heading.
local function build_by_date(data, view, present, project_names)
  local now = today()
  local by_id = {}
  for _, task in ipairs(data.tasks or {}) do
    by_id[task.id] = task
  end

  local placed = {}
  local function bucket(task)
    if placed[task.id] == nil then
      local key = false
      if view.matches(task, {}) then
        local date = model.due_date(task)
        key = date < now and M.OVERDUE or date
      else
        local parent = task.parent_id and present[task.parent_id] or nil
        key = parent and bucket(parent) or false
      end
      placed[task.id] = key
    end
    return placed[task.id]
  end

  local children, roots = {}, {}
  for _, task in pairs(present) do
    local key = bucket(task)
    if key then
      local parent = task.parent_id and present[task.parent_id] or nil
      if parent and bucket(parent) == key then
        children[parent.id] = children[parent.id] or {}
        table.insert(children[parent.id], task)
      else
        roots[key] = roots[key] or {}
        table.insert(roots[key], task)
      end
    end
  end

  local lines, tasks, highlights = {}, {}, {}
  local meta = { headings = {}, placed = {}, annotations = {} }

  local function push(text)
    table.insert(lines, text)
    return #lines
  end

  local function emit(task, depth, key)
    local text, spans = M.task_line(task, depth)
    local lnum = push(text)
    table.insert(tasks, { lnum = lnum, task = task })
    meta.placed[task.id] = key
    for _, span in ipairs(spans) do
      table.insert(highlights, { lnum = lnum, group = span[1], from = span[2], to = span[3] })
    end
    if depth == 0 then
      -- Where the task lives, since the headings no longer say. Virtual text,
      -- so it is never read back as part of the task.
      local where = project_names[task.project_id] or "?"
      local parent = task.parent_id and by_id[task.parent_id] or nil
      if parent then
        where = where .. " › " .. tostring(parent.content)
      end
      table.insert(meta.annotations, { lnum = lnum, text = where })
    end
    local kids = children[task.id]
    if kids then
      table.sort(kids, by_order)
      for _, kid in ipairs(kids) do
        emit(kid, depth + 1, key)
      end
    end
  end

  local function heading(key, text)
    if #lines > 0 then
      push("")
    end
    local lnum = push("# " .. text)
    meta.headings[text] = key
    table.insert(highlights, {
      lnum = lnum,
      group = key == M.OVERDUE and "YadoistDueOverdue" or "YadoistProject",
      from = 0,
      to = #lines[lnum],
    })
    push("")
    local list = roots[key] or {}
    table.sort(list, by_day)
    for _, task in ipairs(list) do
      emit(task, 0, key)
    end
  end

  if roots[M.OVERDUE] then
    heading(M.OVERDUE, M.OVERDUE)
  end
  for offset = 0, view.days or 0 do
    local date = model.date_after(offset)
    heading(date, M.day_heading(date, offset))
  end

  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  return lines, tasks, highlights, meta
end

--- Build the whole buffer.
---@param data table { projects, sections, tasks }
---@param opts table|nil { projects = string[], view = string }
---@return string[] lines, table[] tasks, table[] highlights, table meta
---   meta, for date views only: headings { [text] = date|"Overdue" },
---   placed { [task_id] = the heading key it was drawn under },
---   annotations { lnum, text }[] to show beside a line
function M.build(data, opts)
  opts = opts or {}
  local view = views.get(opts.view)
  local included = views.included(view, data)

  local allow
  if opts.projects then
    allow = {}
    for _, name in ipairs(opts.projects) do
      allow[name] = true
    end
  end

  -- Only live projects and sections are drawn, and only the tasks that belong
  -- to them. Rendering a task whose section is archived would show it at the
  -- top level, which the diff would then read as a deliberate move.
  local live_projects, live_sections = {}, {}

  local sections = {}
  for _, section in ipairs(data.sections or {}) do
    if section.is_deleted ~= true and section.is_archived ~= true then
      live_sections[section.id] = true
      sections[section.project_id] = sections[section.project_id] or {}
      table.insert(sections[section.project_id], section)
    end
  end

  local projects = {}
  for _, project in ipairs(data.projects or {}) do
    if project.is_deleted ~= true and project.is_archived ~= true then
      live_projects[project.id] = true
      table.insert(projects, vim.deepcopy(project))
    end
  end

  local project_names = {}
  for _, project in ipairs(projects) do
    project_names[project.id] = project.name
  end

  local present = {}
  for _, task in ipairs(data.tasks or {}) do
    local visible = task.is_deleted ~= true
      and live_projects[task.project_id]
      and (task.section_id == nil or live_sections[task.section_id])
      and (included == nil or included[task.id])
      and (allow == nil or allow[project_names[task.project_id]])
    if visible then
      present[task.id] = task
    end
  end

  if view.group_by == "date" then
    return build_by_date(data, view, present, project_names)
  end

  local children, roots = {}, {}
  for _, task in pairs(present) do
    -- A task whose parent is not here — filtered out, or completed and so not
    -- returned by the API at all — is drawn at the top level rather than lost.
    local parent = task.parent_id and present[task.parent_id] or nil
    if parent then
      children[parent.id] = children[parent.id] or {}
      table.insert(children[parent.id], task)
    else
      local key = tostring(task.project_id) .. "\0" .. tostring(task.section_id or "")
      roots[key] = roots[key] or {}
      table.insert(roots[key], task)
    end
  end
  table.sort(projects, function(a, b)
    local ia, ib = model.is_inbox(a), model.is_inbox(b)
    if ia ~= ib then
      return ia
    end
    return by_order(a, b)
  end)

  local lines, tasks, highlights = {}, {}, {}

  local function push(text)
    table.insert(lines, text)
    return #lines
  end

  local function group(project_id, section_id)
    return roots[tostring(project_id) .. "\0" .. tostring(section_id or "")]
  end

  local function emit(task, depth)
    local text, spans = M.task_line(task, depth)
    local lnum = push(text)
    table.insert(tasks, { lnum = lnum, task = task })
    for _, span in ipairs(spans) do
      table.insert(highlights, { lnum = lnum, group = span[1], from = span[2], to = span[3] })
    end
    local kids = children[task.id]
    if kids then
      table.sort(kids, by_order)
      for _, kid in ipairs(kids) do
        emit(kid, depth + 1)
      end
    end
  end

  local function emit_group(project_id, section_id)
    local list = group(project_id, section_id)
    if not list then
      return
    end
    table.sort(list, by_order)
    for _, task in ipairs(list) do
      emit(task, 0)
    end
  end

  local function has_tasks(project)
    if group(project.id, nil) then
      return true
    end
    for _, section in ipairs(sections[project.id] or {}) do
      if group(project.id, section.id) then
        return true
      end
    end
    return false
  end

  for _, project in ipairs(projects) do
    local skip = (allow and not allow[project.name]) or (view.prune_empty and not has_tasks(project))
    if not skip then
      if #lines > 0 then
        push("")
      end
      local lnum = push("# " .. project.name)
      table.insert(highlights, { lnum = lnum, group = "YadoistProject", from = 0, to = #lines[lnum] })
      push("")
      emit_group(project.id, nil)

      local list = sections[project.id] or {}
      table.sort(list, by_order)
      for _, section in ipairs(list) do
        if not (view.prune_empty and not group(project.id, section.id)) then
          push("")
          local slnum = push("## " .. section.name)
          table.insert(highlights, { lnum = slnum, group = "YadoistSection", from = 0, to = #lines[slnum] })
          push("")
          emit_group(project.id, section.id)
        end
      end
    end
  end

  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  if #lines == 0 then
    lines = { ("# (nothing in %s)"):format(view.label) }
  end

  return lines, tasks, highlights, {}
end

return M
