-- Apply a set of diff operations to Todoist, one at a time.
--
-- Serial rather than concurrent, because creates have to land before the
-- subtasks that point at them, and because a shared list is not the place to
-- race a rate limiter.
local api = require("yadoist.api")
local config = require("yadoist.config")

local M = {}

--- Ask before deleting anything.
---@return table[]|nil ops  nil means the write was cancelled
local function confirm_deletes(ops)
  local deletes = {}
  for _, op in ipairs(ops) do
    if op.kind == "delete" then
      table.insert(deletes, op)
    end
  end
  if #deletes == 0 or not config.options.confirm_delete then
    return ops
  end

  local names = {}
  for i, op in ipairs(deletes) do
    names[i] = "  - " .. tostring(op.content)
  end
  local msg = ("Delete %d task%s from Todoist?\nThis removes %s for everyone the project is shared with.\n\n%s")
    :format(#deletes, #deletes == 1 and "" or "s", #deletes == 1 and "it" or "them", table.concat(names, "\n"))

  local choice = vim.fn.confirm(msg, "&Delete\nSkip the deletes, apply the &rest\n&Cancel the write", 3, "Question")
  if choice == 1 then
    return ops
  end
  if choice == 2 then
    local kept = {}
    for _, op in ipairs(ops) do
      if op.kind ~= "delete" then
        table.insert(kept, op)
      end
    end
    return kept
  end
  return nil
end

---@param ops table[]
---@param done fun(result: table|nil, err: string|nil)
function M.apply(ops, done)
  ops = confirm_deletes(ops)
  if not ops then
    return done(nil, "write cancelled")
  end
  if #ops == 0 then
    return done({ applied = 0, errors = {} })
  end

  local new_ids, errors, applied = {}, {}, 0
  local index = 0

  local function step()
    index = index + 1
    local op = ops[index]
    if not op then
      return done({ applied = applied, errors = errors })
    end

    local function fail(err)
      table.insert(errors, ("%s %q: %s"):format(op.kind, tostring(op.content), err))
      step()
    end

    local function finish(_, err)
      if err then
        return fail(err)
      end
      applied = applied + 1
      step()
    end

    if op.kind == "create" then
      local parent_id = op.parent_id
      if not parent_id and op.parent_lnum then
        parent_id = new_ids[op.parent_lnum]
        if not parent_id then
          return fail("its parent task was not created, so it has nothing to nest under")
        end
      end

      api.create({
        content = op.content,
        project_id = op.project_id,
        section_id = op.section_id,
        parent_id = parent_id,
        priority = op.priority,
        labels = op.labels,
        due_string = op.due_string,
        due_date = op.due_date,
      }, function(res, err)
        if err then
          return fail(err)
        end
        applied = applied + 1
        local id = type(res) == "table" and res.id or nil
        if id then
          new_ids[op.lnum] = id
        end
        if op.done and id then
          api.close(id, function(_, close_err)
            if close_err then
              table.insert(errors, ("complete %q: %s"):format(op.content, close_err))
            end
            step()
          end)
        else
          step()
        end
      end)
    elseif op.kind == "move" then
      local fields = vim.deepcopy(op.fields)
      if op.parent_lnum then
        fields.parent_id = new_ids[op.parent_lnum]
        if not fields.parent_id then
          return fail("its new parent task was not created")
        end
      end
      api.move(op.id, fields, finish)
    elseif op.kind == "update" then
      api.update(op.id, op.fields, finish)
    elseif op.kind == "close" then
      api.close(op.id, finish)
    elseif op.kind == "reopen" then
      api.reopen(op.id, finish)
    elseif op.kind == "delete" then
      api.delete(op.id, finish)
    else
      step()
    end
  end

  step()
end

--- One-line summary of what a write is about to do, for the message area.
function M.describe(ops)
  local counts, order = {}, { "create", "update", "move", "close", "reopen", "delete" }
  local words = {
    create = "added", update = "updated", move = "moved",
    close = "completed", reopen = "reopened", delete = "deleted",
  }
  for _, op in ipairs(ops) do
    counts[op.kind] = (counts[op.kind] or 0) + 1
  end
  local parts = {}
  for _, kind in ipairs(order) do
    if counts[kind] then
      table.insert(parts, ("%d %s"):format(counts[kind], words[kind]))
    end
  end
  return table.concat(parts, ", ")
end

return M
