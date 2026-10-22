-- Work out what changed between the tasks we rendered and the text that is now
-- in the buffer.
--
-- Identity comes from extmarks, not line positions, so tasks can be reordered
-- and re-indented freely. A mark is lost only when its line is deleted, so a
-- line without one is new, unless it reads exactly like a task that went
-- missing (a line cut and pasted elsewhere). Anything left over is a genuine
-- deletion — which is what the confirmation prompt is for.
local model = require("yadoist.model")
local order = require("yadoist.order")
local parse = require("yadoist.parse")

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

local function kind_of(heading)
  return heading.level == 1 and "project" or "section"
end

--- Work out which project or section each heading line stands for.
---
--- A heading yadoist drew carries a mark saying which, and that is what keeps
--- two projects of the same name apart. One that was cut and pasted lost its
--- mark, but if it reads exactly like a heading that went missing it is that
--- one. Anything else was typed by hand and is looked up by name later.
---@return table by_lnum  heading lines by line number, each with .drawn set
---   to the { kind, id, project_id?, name } it was drawn for, if any
---@return integer removed  how many drawn headings no longer have a line
local function resolve_headings(ctx)
  local by_lnum, claimed = {}, {}
  for _, h in ipairs(ctx.headings or {}) do
    by_lnum[h.lnum] = h
    local drawn = ctx.heading and ctx.heading(h.lnum)
    if drawn and drawn.kind == kind_of(h) and not claimed[drawn] then
      h.drawn, claimed[drawn] = drawn, true
    end
  end

  local project
  for _, h in ipairs(ctx.headings or {}) do
    if h.level == 1 then
      project = h
    end
    if not h.drawn then
      for _, drawn in ipairs(ctx.heading_ids or {}) do
        local here = drawn.kind == "project"
          or (project and project.drawn and project.drawn.id == drawn.project_id)
        if not claimed[drawn] and drawn.kind == kind_of(h) and drawn.name == h.name and here then
          h.drawn, claimed[drawn] = drawn, true
          break
        end
      end
    end
  end

  local removed = 0
  for _, drawn in ipairs(ctx.heading_ids or {}) do
    if not claimed[drawn] then
      removed = removed + 1
    end
  end
  return by_lnum, removed
end

--- The one id a name typed by hand stands for, or an error saying why not.
local function by_name(ids, what, name, where)
  if not ids or #ids == 0 then
    return nil, ("no %s named %q%s — yadoist does not create %ss"):format(what, name, where or " in Todoist", what)
  end
  if #ids > 1 then
    return nil, ("%d %ss are called %q, so a heading typed by hand cannot say which — move the task under the heading yadoist drew for it")
      :format(#ids, what, name)
  end
  return ids[1]
end

--- In project views the headings say where a line lives.
local function resolve_by_project(ctx, heads, e)
  local msg
  local ph = heads[e.project_lnum]
  if ph and ph.drawn then
    e.project_id = ph.drawn.id
  else
    e.project_id, msg = by_name(ctx.project_ids[e.project], "project", e.project)
    if msg then
      return msg
    end
  end
  if e.section then
    local sh = heads[e.section_lnum]
    if sh and sh.drawn and sh.drawn.project_id == e.project_id then
      e.section_id = sh.drawn.id
    else
      local names = (ctx.section_ids or {})[e.project_id] or {}
      e.section_id, msg = by_name(names[e.section], "section", e.section, (" in %q"):format(e.project))
      if msg then
        return msg
      end
    end
  end
  return nil
end

--- A drawn heading whose text was edited renames its project or section,
--- unless another one there already has the new name: two of a name is
--- allowed, but it is far more likely to be a mistake, or an attempt to move
--- tasks, than a wish.
local function renames(ctx, heads, ops, errors)
  for _, h in pairs(heads) do
    local drawn = h.drawn
    if drawn and h.name ~= drawn.name then
      local others = drawn.kind == "project" and ctx.project_ids[h.name]
        or ((ctx.section_ids or {})[drawn.project_id] or {})[h.name]
      local taken = false
      for _, id in ipairs(others or {}) do
        taken = taken or id ~= drawn.id
      end
      if taken then
        table.insert(errors, { lnum = h.lnum, msg = ("there is already a %s called %q — to move tasks there, move their lines under its heading")
          :format(drawn.kind, h.name) })
      else
        table.insert(ops, { kind = "rename", target = drawn.kind, id = drawn.id, name = h.name, content = drawn.name, lnum = h.lnum })
      end
    end
  end
  table.sort(ops, function(a, b)
    return a.lnum < b.lnum
  end)
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
    e.reschedule = model.reschedule(e.task, key)
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
---   headings     parsed heading lines
---   resolve      fun(lnum): task|nil -- the task whose live mark is on that line
---   heading      fun(lnum): table|nil -- what the heading on that line was
---                drawn for, from its live mark: { kind, id, project_id?, name }
---   heading_ids  every { kind, id, project_id?, name } that was drawn
---   owner        fun(lnum): table|nil -- for a description line, the task it
---                was drawn under and the indent it was drawn with: { id, indent }
---   orphans      description lines with no task above them, as
---                { lnum, line }, each one drawn under some task
---   known        { [task_id] = task } -- everything we rendered
---   tasks        every task fetched, rendered or not: what a list holds
---                besides what this view shows
---   project_ids  { [name] = id[] }, every live project by name
---   section_ids  { [project_id] = { [name] = id[] } }
---   label_names  { [name] = true } labels that already exist, or nil to let
---                any label through
---   by_date      date views only: { headings, placed, overdue, inbox_id },
---                the first three from render (see resolve_by_date)
--- @return table[] ops, table[] errors, table info
---   Each op that comes from a task line has that line's entry as op.entry.
---   info.headings_removed: how many drawn headings no longer have a line
function M.compute(ctx)
  local entries, known = ctx.entries, ctx.known or {}
  local ops, errors = {}, {}
  local heads, removed = resolve_headings(ctx)
  renames(ctx, heads, ops, errors)

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

  -- 2. Whatever is left: lines with no task, and tasks with no line.
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

  -- 3. Last chance: a line that was cut and pasted lost its mark, but if it
  --    still reads the same it is the same task rather than a delete plus a
  --    create.
  local buckets = {}
  for i, task in ipairs(deletes) do
    local content = model.content(task)
    buckets[content] = buckets[content] or {}
    table.insert(buckets[content], i)
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

  -- 4. A description line belongs to the task it was drawn under, wherever
  --    that task's line has gone. Deleting a task's line leaves its
  --    description under the task above, but it is not that task's; it goes
  --    with its own task, and with it if it was deleted. Its text is read at
  --    the indent it was drawn with, so re-indenting the task alone does not
  --    change it. Lines typed or pasted in belong to the task above them.
  if ctx.owner then
    local home, items = {}, {}
    for _, e in ipairs(entries) do
      if e.task then
        home[e.task.id] = e
      end
    end
    local function file(e, item)
      items[e] = items[e] or {}
      table.insert(items[e], item)
    end
    local function place(item, under)
      local drawn = ctx.owner(item.lnum)
      if not drawn then
        if under then
          file(under, item)
        end
      elseif home[drawn.id] then
        file(home[drawn.id], { lnum = item.lnum, line = item.line, text = parse.description_text(item.line, drawn.indent) })
      end
    end
    for _, e in ipairs(entries) do
      for _, item in ipairs(e.lines) do
        place(item, e)
      end
    end
    for _, item in ipairs(ctx.orphans or {}) do
      place(item, nil)
    end
    for _, e in ipairs(entries) do
      e.lines = items[e] or {}
      table.sort(e.lines, function(a, b)
        return a.lnum < b.lnum
      end)
      e.description = parse.join_description(e.lines)
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
      msg = resolve_by_project(ctx, heads, e)
    end
    if msg then
      table.insert(errors, { lnum = e.lnum, msg = msg })
    end

    if ctx.label_names then
      local had = {}
      for _, l in ipairs(e.task and model.labels(e.task) or {}) do
        had[l] = true
      end
      for _, l in ipairs(e.labels) do
        if not ctx.label_names[l] and not had[l] then
          table.insert(errors, {
            lnum = e.lnum,
            msg = ("no label named %q — yadoist does not create labels (add it in Todoist, or set create_labels = true)")
              :format(l),
          })
        end
      end
    end

    if e.parent_lnum then
      local parent = by_lnum[e.parent_lnum]
      if parent and parent.task then
        e.parent_id = parent.task.id
      end
    end
  end

  local info = { headings_removed = removed }
  if #errors > 0 then
    table.sort(errors, function(a, b)
      return a.lnum < b.lnum
    end)
    return {}, errors, info
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
      description = e.description ~= "" and e.description or nil,
      entry = e,
    })
  end

  -- 7. Field updates and moves on tasks we already knew about.
  for _, e in ipairs(entries) do
    local task = e.task
    if task then
      local fields = {}

      if e.content ~= model.content(task) then
        fields.content = e.content
      end

      if e.description ~= nil and e.description ~= model.description(task) then
        fields.description = e.description
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
        -- "no date" is what Todoist's own UI sends to clear one.
        fields.due_string = e.due_string or "no date"
      elseif e.reschedule then
        for k, v in pairs(e.reschedule) do
          fields[k] = v
        end
      end

      if next(fields) then
        table.insert(ops, { kind = "update", id = task.id, content = task.content, fields = fields, entry = e })
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
      elseif task.parent_id and known[task.parent_id] then
        -- Un-indented from under a parent that is on screen: a promotion. A
        -- subtask whose parent was never drawn is shown at the top level
        -- without that meaning anything, so it only moves if its project or
        -- section line changed, below.
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
          entry = e,
        })
      end

      if e.done ~= model.is_completed(task) then
        table.insert(ops, {
          kind = e.done and "close" or "reopen",
          id = task.id,
          content = task.content,
          entry = e,
        })
      end
    end
  end

  -- 8. The order lines are in, now that it is known what moves where.
  local moving, leaving = {}, {}
  for _, op in ipairs(ops) do
    if op.kind == "move" then
      moving[op.id] = true
    elseif op.kind == "close" then
      leaving[op.id] = true
    end
  end
  for _, task in ipairs(still_deleting) do
    leaving[task.id] = true
  end
  vim.list_extend(ops, order.compute({
    entries = entries,
    moving = moving,
    leaving = leaving,
    tasks = ctx.tasks,
    by_date = ctx.by_date,
  }))

  -- 9. Deletions last, so a failed write leaves the data intact.
  for _, task in ipairs(still_deleting) do
    table.insert(ops, { kind = "delete", id = task.id, content = task.content })
  end

  return ops, errors, info
end

return M
