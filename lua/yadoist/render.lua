-- Task data -> buffer text. The inverse of parse.lua.
--
-- Highlight spans are produced here rather than by a syntax file, so they can
-- be driven by the data: an overdue date is coloured differently from a future
-- one because we know the date, not because of how it is spelled.
local model = require("yadoist.model")
local views = require("yadoist.views")

local M = {}

local function today()
  return os.date("%Y-%m-%d")
end

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

--- Build the whole buffer.
---@param data table { projects, sections, tasks }
---@param opts table|nil { projects = string[], view = string }
---@return string[] lines, table[] tasks, table[] highlights
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

  local present = {}
  for _, task in ipairs(data.tasks or {}) do
    local visible = task.is_deleted ~= true
      and live_projects[task.project_id]
      and (task.section_id == nil or live_sections[task.section_id])
      and (included == nil or included[task.id])
    if visible then
      present[task.id] = task
    end
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

  return lines, tasks, highlights
end

return M
