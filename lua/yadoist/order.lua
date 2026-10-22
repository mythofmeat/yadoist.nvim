-- Saving the order lines are in.
--
-- Todoist gives each task a child_order among its siblings: the other tasks
-- in the same project and section, or under the same parent. Moving lines
-- within one of those lists, or into one, is sent as that list's new order.
-- The date views show Todoist's own order within each day instead, its
-- day_order, and moving lines within a day is sent as new day orders.
--
-- A view may show only some of a list. The tasks it hides keep their place
-- after whichever shown task came before them, so they are not shuffled by an
-- order they could not be seen in.
local model = require("yadoist.model")

local M = {}

--- The list a task is in now, in Todoist.
local function list_of(task)
  if task.parent_id then
    return "parent:" .. task.parent_id
  end
  return ("list:%s:%s"):format(task.project_id, task.section_id or "")
end

local function same(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i].id ~= b[i].id or a[i].lnum ~= b[i].lnum then
      return false
    end
  end
  return true
end

---@param ctx table
---   entries  the parsed lines, as diff.compute resolved them
---   moving   { [task_id] = true } for tasks this write moves to another list
---   leaving  { [task_id] = true } for tasks it deletes or completes
---   tasks    every task fetched, shown or not
---   by_date  date views only, as for diff.compute
---@return table[] ops  { kind = "reorder", items = { id|lnum, child_order }[] }
---   and { kind = "day_order", ids = id[] }, each with a content naming it
function M.compute(ctx)
  local by_lnum = {}
  for _, e in ipairs(ctx.entries) do
    by_lnum[e.lnum] = e
  end

  -- Which list each line's task will be in once the write lands, and which
  -- day, in a date view. A completed task has no place in either, and one
  -- being reopened goes back to the place it had.
  local lists, list_keys, days, day_keys = {}, {}, {}, {}
  local function into(map, keys, key, e)
    if not map[key] then
      map[key] = {}
      table.insert(keys, key)
    end
    table.insert(map[key], e)
  end
  for _, e in ipairs(ctx.entries) do
    if not e.done and not (e.task and model.is_completed(e.task)) then
      if e.parent_lnum then
        local parent = by_lnum[e.parent_lnum]
        into(lists, list_keys, "parent:" .. (parent.task and parent.task.id or ("line:" .. parent.lnum)), e)
      elseif ctx.by_date then
        -- Day orders name tasks by id, so a new one takes Todoist's default.
        if e.task then
          into(days, day_keys, ctx.by_date.headings[e.project], e)
        end
      elseif not (e.task and e.task.parent_id and not ctx.moving[e.task.id]) then
        -- (A subtask drawn at the top level because its parent is not on
        -- screen is still in its parent's list, whose order is not shown.)
        into(lists, list_keys, ("list:%s:%s"):format(e.project_id, e.section_id or ""), e)
      end
    end
  end

  local ops = {}
  for _, key in ipairs(list_keys) do
    local shown = lists[key]
    local here = {}
    for _, e in ipairs(shown) do
      if e.task then
        here[e.task.id] = true
      end
    end
    local old = {}
    for _, task in ipairs(ctx.tasks or {}) do
      if list_of(task) == key and not model.is_completed(task) then
        table.insert(old, task)
      end
    end
    table.sort(old, model.by_order)

    -- Each task staying in the list without a line in it follows the shown
    -- task that came before it.
    local after, anchor = { [""] = {} }, ""
    for _, task in ipairs(old) do
      if here[task.id] then
        anchor = task.id
      elseif not ctx.leaving[task.id] and not ctx.moving[task.id] then
        after[anchor] = after[anchor] or {}
        table.insert(after[anchor], task)
      end
    end
    local wanted = {}
    for _, task in ipairs(after[""]) do
      table.insert(wanted, { id = task.id })
    end
    for _, e in ipairs(shown) do
      table.insert(wanted, e.task and { id = e.task.id } or { lnum = e.lnum })
      for _, task in ipairs(e.task and after[e.task.id] or {}) do
        table.insert(wanted, { id = task.id })
      end
    end

    -- What Todoist will have without being told: the same order, with what
    -- is new added at the end. Where a moved task lands is less certain, so
    -- a list with one moved into it is always sent.
    local default, was_here, moved_in = {}, {}, false
    for _, task in ipairs(old) do
      was_here[task.id] = true
      if not ctx.leaving[task.id] and not ctx.moving[task.id] then
        table.insert(default, { id = task.id })
      end
    end
    for _, e in ipairs(shown) do
      if not e.task then
        table.insert(default, { lnum = e.lnum })
      elseif not was_here[e.task.id] then
        table.insert(default, { id = e.task.id })
        moved_in = true
      end
    end

    if moved_in or not same(wanted, default) then
      local items = {}
      for i, x in ipairs(wanted) do
        items[i] = { id = x.id, lnum = x.lnum, child_order = i }
      end
      local first = shown[1]
      local parent = first.parent_lnum and by_lnum[first.parent_lnum]
      table.insert(ops, {
        kind = "reorder",
        items = items,
        content = parent and ("under " .. parent.content)
          or (first.section and (first.project .. " › " .. first.section) or first.project),
      })
    end
  end

  for _, key in ipairs(day_keys) do
    local shown = days[key]
    local sorted = {}
    for i, e in ipairs(shown) do
      sorted[i] = e.task
    end
    table.sort(sorted, model.by_day)
    local changed = false
    for i, e in ipairs(shown) do
      changed = changed or sorted[i] ~= e.task
    end
    if changed then
      table.insert(ops, {
        kind = "day_order",
        ids = vim.tbl_map(function(e) return e.task.id end, shown),
        content = shown[1].project,
      })
    end
  end
  return ops
end

return M
