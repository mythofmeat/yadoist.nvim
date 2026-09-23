-- Work out what changed between the tasks we rendered and the text that is now
-- in the buffer.
--
-- Identity comes from extmarks, not line positions, so tasks can be reordered
-- and re-indented freely. A line that lost its mark (because its entire text
-- was replaced) is paired back up by content where possible, and anything left
-- over is a genuine deletion — which is what the confirmation prompt is for.
local model = require("yadoist.model")

local M = {}

local function labels_equal(a, b)
  if #a ~= #b then
    return false
  end
  local x, y = vim.deepcopy(a), vim.deepcopy(b)
  table.sort(x)
  table.sort(y)
  for i = 1, #x do
    if x[i] ~= y[i] then
      return false
    end
  end
  return true
end

--- In project views the headings say where a line lives.
local function resolve_by_project(ctx, e)
  e.project_id = ctx.project_ids[e.project]
  if not e.project_id then
    return ("no project named %q in Todoist — yadoist does not create projects"):format(e.project)
  end
  if e.section then
    local map = (ctx.section_ids or {})[e.project_id] or {}
    e.section_id = map[e.section]
    if not e.section_id then
      return ("no section named %q in %q — yadoist does not create sections"):format(e.section, e.project)
    end
  end
  return nil
end

--- Date views have day headings where project views have project headings, so
--- a line's project comes from somewhere else:
---
---   - An existing task stays in its project and section. Moving its line under
---     another day reschedules it, as dragging it does in Todoist, unless its
---     `<...>` was edited too, in which case the edit wins.
---   - A new top-level task goes to the Inbox, due on the day it was added under
---     unless it says otherwise. Adding one under Overdue needs a date.
---   - A new subtask goes wherever its parent is, which Todoist infers.
local function resolve_by_date(by_date, e)
  local key = by_date.headings[e.project]
  if key == nil then
    return ("%q is not one of this view's days — move the task under one of them"):format(e.project)
  end
  if e.section then
    return "date views have no sections; use `all` to move tasks between sections"
  end

  if e.task then
    e.project_id, e.section_id = e.task.project_id, e.task.section_id
    local was, own = by_date.placed[e.task.id], model.due_date(e.task)
    local moved_day = not e.parent_lnum and was and key ~= was and own
    if not moved_day or e.due_string ~= model.due_string(e.task) then
      return nil
    end
    if key == by_date.overdue then
      return "cannot reschedule a task into the past — give it a <date> instead"
    end
    if model.is_recurring(e.task) then
      return "moving a recurring task to another day would make it a one-off — edit its <...> instead"
    end
    local time = e.task.due.date:sub(11)
    if time ~= "" then
      -- A timed task keeps its time of day on the new date.
      e.reschedule = { due_datetime = key .. time }
    else
      e.reschedule = { due_date = key }
    end
  elseif not e.parent_lnum then
    e.project_id = by_date.inbox_id
    if not e.project_id then
      return "no Inbox project to add this to"
    end
    if not e.due_string then
      if key == by_date.overdue then
        return "a new task under Overdue needs a <date>"
      end
      e.due_date = key
    end
  end
  return nil
end

--- @param ctx table
---   entries      parsed buffer entries
---   resolve       fun(lnum): task|nil -- live extmark lookup
---   resolve_stale fun(lnum): task|nil -- invalidated extmark lookup
---   known        { [task_id] = task } -- everything we rendered
---   project_ids  { [name] = id }
---   section_ids  { [project_id] = { [name] = id } }
---   by_date      date views only: { headings, placed, overdue, inbox_id },
---                the first three from render (see resolve_by_date)
--- @return table[] ops, table[] errors
function M.compute(ctx)
  local entries, known = ctx.entries, ctx.known or {}
  local ops, errors = {}, {}

  -- 1. Identity from the live extmarks.
  local seen = {}
  local function claim(e, task)
    e.task = task
    seen[task.id] = true
  end

  for _, e in ipairs(entries) do
    local task = ctx.resolve(e.lnum)
    if task and not seen[task.id] then
      claim(e, task)
    end
  end

  -- 2. Rewriting a whole line (cc) drops its mark, but the dead mark stays on
  --    that row, so the rewritten line can reclaim it. Deleting a line (dd)
  --    also leaves a dead mark behind, except it lands on a row that already
  --    has a live mark of its own — and step 1 has already claimed that — so
  --    only genuine rewrites get this far.
  if ctx.resolve_stale then
    for _, e in ipairs(entries) do
      if not e.task then
        local task = ctx.resolve_stale(e.lnum)
        if task and not seen[task.id] and known[task.id] then
          claim(e, task)
        end
      end
    end
  end

  -- 3. Whatever is left: lines with no task, and tasks with no line.
  local creates, deletes = {}, {}
  for _, e in ipairs(entries) do
    if not e.task then
      table.insert(creates, e)
    end
  end
  for id, task in pairs(known) do
    if not seen[id] then
      table.insert(deletes, task)
    end
  end
  table.sort(deletes, function(a, b)
    return tostring(a.content) < tostring(b.content)
  end)

  -- 4. Last chance: a line that moved and lost its mark, but still reads the
  --    same, is the same task rather than a delete plus a create.
  local buckets = {}
  for i, task in ipairs(deletes) do
    buckets[task.content] = buckets[task.content] or {}
    table.insert(buckets[task.content], i)
  end
  local reclaimed = {}
  for _, e in ipairs(creates) do
    local bucket = buckets[e.content]
    if bucket and #bucket > 0 then
      local idx = table.remove(bucket, 1)
      claim(e, deletes[idx])
      reclaimed[idx] = true
    end
  end

  local still_creating = {}
  for _, e in ipairs(creates) do
    if not e.task then
      table.insert(still_creating, e)
    end
  end
  local still_deleting = {}
  for i, task in ipairs(deletes) do
    if not reclaimed[i] then
      table.insert(still_deleting, task)
    end
  end

  -- 5. Resolve each line's project, section and parent.
  local by_lnum = {}
  for _, e in ipairs(entries) do
    by_lnum[e.lnum] = e
  end

  for _, e in ipairs(entries) do
    local msg
    if ctx.by_date then
      msg = resolve_by_date(ctx.by_date, e)
    else
      msg = resolve_by_project(ctx, e)
    end
    if msg then
      table.insert(errors, { lnum = e.lnum, msg = msg })
    end

    if e.parent_lnum then
      local parent = by_lnum[e.parent_lnum]
      if parent and parent.task then
        e.parent_id = parent.task.id
      end
    end
  end

  if #errors > 0 then
    return {}, errors
  end

  -- 6. Creates, in buffer order so parents land before their children.
  for _, e in ipairs(still_creating) do
    table.insert(ops, {
      kind = "create",
      lnum = e.lnum,
      content = e.content,
      done = e.done,
      project_id = e.project_id,
      section_id = e.section_id,
      parent_id = e.parent_id,
      parent_lnum = e.parent_lnum,
      priority = model.ui_to_api_priority(e.priority),
      labels = e.labels,
      due_string = e.due_string,
      due_date = e.due_date,
    })
  end

  -- 7. Field updates and moves on tasks we already knew about.
  for _, e in ipairs(entries) do
    local task = e.task
    if task then
      local fields = {}

      if e.content ~= task.content then
        fields.content = e.content
      end

      local priority = model.ui_to_api_priority(e.priority)
      if priority ~= (tonumber(task.priority) or 1) then
        fields.priority = priority
      end

      if not labels_equal(e.labels, model.labels(task)) then
        fields.labels = e.labels
      end

      local due = model.due_string(task)
      if e.due_string ~= due then
        -- Todoist clears a due date when its natural-language parser is handed
        -- "no date", which is what its own UI sends.
        fields.due_string = e.due_string or "no date"
      elseif e.reschedule then
        for k, v in pairs(e.reschedule) do
          fields[k] = v
        end
      end

      if next(fields) then
        table.insert(ops, { kind = "update", id = task.id, content = task.content, fields = fields })
      end

      -- Moves. Todoist's move endpoint wants exactly one non-null
      -- destination, so promoting a subtask to top level is expressed as a
      -- move to its section or project rather than a null parent.
      local moved, pending_parent = nil, nil
      if ctx.by_date and not e.parent_lnum then
        -- A top-level line in a date view says nothing about where the task
        -- lives: subtasks are drawn there whenever their parent is under
        -- another day, so reading it as a promotion would be wrong. It is
        -- left where it is.
      elseif e.parent_lnum then
        if not e.parent_id then
          pending_parent = e.parent_lnum -- its parent is created by this same write
        end
        if e.parent_id ~= task.parent_id or pending_parent then
          moved = { parent_id = e.parent_id }
        end
      elseif task.parent_id then
        moved = e.section_id and { section_id = e.section_id } or { project_id = e.project_id }
      elseif e.section_id ~= task.section_id then
        moved = e.section_id and { section_id = e.section_id } or { project_id = e.project_id }
      elseif e.project_id ~= task.project_id then
        moved = { project_id = e.project_id }
      end
      if moved then
        table.insert(ops, {
          kind = "move",
          id = task.id,
          content = task.content,
          fields = moved,
          parent_lnum = pending_parent,
        })
      end

      if e.done ~= model.is_completed(task) then
        table.insert(ops, {
          kind = e.done and "close" or "reopen",
          id = task.id,
          content = task.content,
        })
      end
    end
  end

  -- 8. Deletions last, so a failed write leaves the data intact.
  for _, task in ipairs(still_deleting) do
    table.insert(ops, { kind = "delete", id = task.id, content = task.content })
  end

  return ops, errors
end

return M
