-- The views you can open the task buffer in.
--
-- A view is only a filter over the same rendering: the buffer grammar never
-- changes, so `# Project` always means a project and every edit works the same
-- way whichever view you are looking at. Tasks that do not match are simply not
-- drawn, and a task's ancestors are always drawn with it so nesting survives.
local model = require("yadoist.model")

local M = {}

local function today()
  return os.date("%Y-%m-%d")
end

local function days_from_now(n)
  return os.date("%Y-%m-%d", os.time() + n * 86400)
end

M.list = {
  all = {
    label = "all tasks",
    description = "every task, grouped by project",
  },
  today = {
    label = "today",
    description = "due today, plus anything overdue",
    prune_empty = true,
    matches = function(task)
      local due = model.due_date(task)
      return due ~= nil and due <= today()
    end,
  },
  upcoming = {
    label = "upcoming",
    description = "due within the next seven days, plus anything overdue",
    prune_empty = true,
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
  inbox = {
    label = "inbox",
    description = "the Inbox project on its own",
    prune_empty = true,
    matches = function(task, ctx)
      return ctx.inbox_id ~= nil and task.project_id == ctx.inbox_id
    end,
  },
}

--- Order they are offered in for completion and in the help text.
M.order = { "all", "today", "upcoming", "overdue", "inbox" }

function M.get(name)
  return M.list[name or "all"], (name or "all")
end

function M.names()
  return vim.deepcopy(M.order)
end

--- Which task ids a view shows, with every matching task's ancestors pulled in
--- so a subtask is never drawn without its parent.
---@return table<string, boolean>|nil  nil means "everything"
function M.included(view, data)
  if not view.matches then
    return nil
  end

  local by_id, inbox_id = {}, nil
  for _, task in ipairs(data.tasks or {}) do
    by_id[task.id] = task
  end
  for _, project in ipairs(data.projects or {}) do
    if model.is_inbox(project) then
      inbox_id = project.id
    end
  end

  local ctx = { inbox_id = inbox_id }
  local included = {}
  for _, task in ipairs(data.tasks or {}) do
    if view.matches(task, ctx) then
      local cur = task
      while cur and not included[cur.id] do
        included[cur.id] = true
        cur = cur.parent_id and by_id[cur.parent_id] or nil
      end
    end
  end
  return included
end

return M
