-- The views you can open the task buffer in.
--
-- A view is only a filter over the same rendering: the buffer grammar never
-- changes, so `# Project` always means a project and every edit works the same
-- way whichever view you are looking at. Tasks that do not match are simply not
-- drawn, and a task's ancestors are always drawn with it so nesting survives.
--
-- The exception is the date views (`group_by = "date"`), which follow Todoist's
-- own Today and Upcoming: headings are days rather than projects, overdue work
-- is pinned to the top, and a task's subtasks come along with it instead of its
-- ancestors. Their grammar is described in render.lua and diff.lua.
local model = require("yadoist.model")

local M = {}

local today, days_from_now = model.today, model.date_after

M.list = {
  all = {
    label = "all tasks",
    description = "every task, grouped by project",
  },
  today = {
    label = "today",
    description = "due today, plus anything overdue, by day",
    group_by = "date",
    days = 0,
    matches = function(task)
      local due = model.due_date(task)
      return due ~= nil and due <= today()
    end,
  },
  upcoming = {
    label = "upcoming",
    description = "due within the next seven days, plus anything overdue, by day",
    group_by = "date",
    days = 7,
    matches = function(task)
      local due = model.due_date(task)
      return due ~= nil and due <= days_from_now(7)
    end,
  },
  overdue = {
    label = "overdue",
    description = "past its due date and still open",
    prune_empty = true,
    matches = function(task)
      local due = model.due_date(task)
      return due ~= nil and due < today()
    end,
  },
  -- Scoped like a project view rather than pruned, so an empty Inbox still
  -- has its heading to add a task under.
  inbox = {
    label = "inbox",
    description = "the Inbox project on its own",
    inbox = true,
    matches = function(task, ctx)
      return ctx.inbox_id ~= nil and task.project_id == ctx.inbox_id
    end,
  },
  -- Todoist returns only open tasks, so these are fetched separately (see
  -- buffer.lua). Unticking one reopens it.
  completed = {
    label = "recently completed",
    description = "tasks completed in the last week, to reopen one ticked by mistake",
    completed = true,
    prune_empty = true,
    matches = function(task)
      return model.is_completed(task)
    end,
  },
}

--- Order they are offered in for completion and in the help text. `project`
--- and `filter` take something after them, so they are built on demand rather
--- than listed above.
M.order = { "all", "today", "upcoming", "overdue", "inbox", "completed", "project", "filter" }

--- The project a `project <name>` (or `project/<name>`) view is for, or nil.
function M.project_name(name)
  local project = type(name) == "string" and name:match("^project[/%s]+(.-)%s*$")
  return project ~= "" and project or nil
end

--- A view onto one project and its subprojects. Which projects those are is
--- only known once data has been fetched, so it is worked out by scope().
local function project_view(project)
  return {
    label = "project " .. project,
    description = "one project and its subprojects",
    project = project,
    matches = function(task, ctx)
      return ctx.scope ~= nil and ctx.scope[task.project_id] == true
    end,
  }
end

--- The query a `filter <query>` (or `filter/<query>`) view is for, or nil.
function M.filter_query(name)
  local query = type(name) == "string" and name:match("^filter[/%s]+(.-)%s*$")
  return query ~= "" and query or nil
end

--- The tasks a Todoist filter matches, such as `today & #Work` or `@errand`,
--- with Todoist's whole filter language. Which ones match is asked of Todoist
--- (see buffer.lua); like `overdue`, they are grouped by project, with their
--- parents.
local function filter_view(query)
  return {
    label = "filter " .. query,
    description = "the tasks a Todoist filter matches",
    query = query,
    prune_empty = true,
    matches = function(task, ctx)
      return ctx.filter_ids ~= nil and ctx.filter_ids[task.id] == true
    end,
  }
end

function M.get(name)
  name = name or "all"
  local project = M.project_name(name)
  if project then
    return project_view(project), "project/" .. project
  end
  local query = M.filter_query(name)
  if query then
    return filter_view(query), "filter/" .. query
  end
  return M.list[name], name
end

function M.names()
  return vim.deepcopy(M.order)
end

--- The live projects whose name is `name`, ignoring case. Usually one, but
--- Todoist allows two projects to share a name.
function M.find_projects(name, projects)
  local want, found = name:lower(), {}
  for _, project in ipairs(projects or {}) do
    if project.is_deleted ~= true and project.is_archived ~= true and project.name:lower() == want then
      table.insert(found, project)
    end
  end
  return found
end

--- Which project ids a project view covers: the named project and every
--- project nested under it, the way Todoist's own project view includes its
--- subprojects. The inbox view covers the Inbox.
---@return table<string, boolean>|nil  nil for views not tied to a project
function M.scope(view, data)
  if view.inbox then
    for _, project in ipairs(data.projects or {}) do
      if model.is_inbox(project) then
        return { [project.id] = true }
      end
    end
    return {}
  end
  if not view.project then
    return nil
  end
  local children = {}
  for _, project in ipairs(data.projects or {}) do
    if project.parent_id then
      children[project.parent_id] = children[project.parent_id] or {}
      table.insert(children[project.parent_id], project)
    end
  end
  local scope = {}
  local function add(project)
    if not scope[project.id] then
      scope[project.id] = true
      for _, kid in ipairs(children[project.id] or {}) do
        add(kid)
      end
    end
  end
  for _, project in ipairs(M.find_projects(view.project, data.projects)) do
    add(project)
  end
  return scope
end

--- Project names close to one that matched nothing, for the error message:
--- those containing it, or contained in it, ignoring case.
function M.suggest(name, projects)
  local want, out = name:lower(), {}
  for _, project in ipairs(projects or {}) do
    if project.is_deleted ~= true and project.is_archived ~= true then
      local have = project.name:lower()
      if have:find(want, 1, true) or want:find(have, 1, true) then
        table.insert(out, project.name)
      end
    end
  end
  return out
end

--- Which task ids a view shows. Project views pull in every matching task's
--- ancestors so a subtask is never drawn without its parent; date views pull in
--- its descendants instead, the way Todoist shows a task due today with all of
--- its subtasks.
---@param extra table|nil what a view fetched besides the tasks: filter_ids
---@return table<string, boolean>|nil  nil means "everything"
function M.included(view, data, extra)
  if not view.matches then
    return nil
  end

  local by_id, children, inbox_id = {}, {}, nil
  for _, task in ipairs(data.tasks or {}) do
    by_id[task.id] = task
    if task.parent_id then
      children[task.parent_id] = children[task.parent_id] or {}
      table.insert(children[task.parent_id], task)
    end
  end
  for _, project in ipairs(data.projects or {}) do
    if model.is_inbox(project) then
      inbox_id = project.id
    end
  end

  local ctx = { inbox_id = inbox_id, scope = M.scope(view, data), filter_ids = extra and extra.filter_ids }
  local included = {}

  local function descend(task)
    for _, kid in ipairs(children[task.id] or {}) do
      if not included[kid.id] then
        included[kid.id] = true
        descend(kid)
      end
    end
  end

  for _, task in ipairs(data.tasks or {}) do
    if view.matches(task, ctx) then
      if view.group_by == "date" then
        included[task.id] = true
        descend(task)
      else
        local cur = task
        while cur and not included[cur.id] do
          included[cur.id] = true
          cur = cur.parent_id and by_id[cur.parent_id] or nil
        end
      end
    end
  end
  return included
end

return M
