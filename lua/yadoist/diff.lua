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

--- @param ctx table
---   entries      parsed buffer entries
---   resolve       fun(lnum): task|nil -- live extmark lookup
---   resolve_stale fun(lnum): task|nil -- invalidated extmark lookup
---   known        { [task_id] = task } -- everything we rendered
---   project_ids  { [name] = id }
---   section_ids  { [project_id] = { [name] = id } }
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
    e.project_id = ctx.project_ids[e.project]
    if not e.project_id then
      table.insert(errors, {
        lnum = e.lnum,
        msg = ("no project named %q in Todoist — yadoist does not create projects"):format(e.project),
      })
    elseif e.section then
      local map = (ctx.section_ids or {})[e.project_id] or {}
      e.section_id = map[e.section]
      if not e.section_id then
        table.insert(errors, {
          lnum = e.lnum,
          msg = ("no section named %q in %q — yadoist does not create sections"):format(e.section, e.project),
        })
      end
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
      end

      if next(fields) then
        table.insert(ops, { kind = "update", id = task.id, content = task.content, fields = fields })
      end

      -- Moves. Todoist's move endpoint wants exactly one non-null
      -- destination, so promoting a subtask to top level is expressed as a
      -- move to its section or project rather than a null parent.
      local moved, pending_parent = nil, nil
      if e.parent_lnum then
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
