-- Apply a set of diff operations to Todoist through its Sync API.
--
-- Every change goes in one request (Todoist takes up to 100 commands at a
-- time), so a big edit is one round trip rather than dozens. A new task gets a
-- temp_id that its subtasks can name as their parent inside the same request.
-- Each command carries a uuid, and Todoist applies a uuid at most once, which
-- is what makes it safe to resend a request whose reply never arrived.
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

local BATCH = 100

local function uuid()
  return vim.fn.sha256(tostring(math.random()) .. tostring(vim.uv.hrtime())):sub(1, 32)
end

local function temp_id(lnum)
  return "yadoist-line-" .. lnum
end

--- The diff speaks in REST-style field names; the Sync API wants a `due`
--- object instead, and null to clear it.
local function due_of(fields)
  if fields.due_string == "no date" then
    return vim.NIL
  elseif fields.due_string then
    return { string = fields.due_string }
  elseif fields.due_datetime or fields.due_date then
    return { date = fields.due_datetime or fields.due_date }
  end
  return nil
end

--- Turn each op into its Sync commands, remembering which op each came from.
local function commands_for(ops)
  local out = {}
  local function add(op, type, args, tmp)
    table.insert(out, { op = op, command = { type = type, uuid = uuid(), temp_id = tmp, args = args } })
  end

  for _, op in ipairs(ops) do
    if op.kind == "create" then
      local tmp = temp_id(op.lnum)
      add(op, "item_add", {
        content = op.content,
        project_id = op.project_id,
        section_id = op.section_id,
        parent_id = op.parent_id or (op.parent_lnum and temp_id(op.parent_lnum)) or nil,
        priority = op.priority,
        labels = op.labels,
        due = due_of(op),
      }, tmp)
      if op.done then
        add(op, "item_close", { id = tmp })
      end
    elseif op.kind == "update" then
      local args = { id = op.id }
      for _, key in ipairs({ "content", "priority", "labels" }) do
        args[key] = op.fields[key]
      end
      args.due = due_of(op.fields)
      add(op, "item_update", args)
    elseif op.kind == "move" then
      local args = vim.tbl_extend("force", { id = op.id }, op.fields)
      if op.parent_lnum then
        args.parent_id = temp_id(op.parent_lnum)
      end
      add(op, "item_move", args)
    elseif op.kind == "close" then
      add(op, "item_close", { id = op.id })
    elseif op.kind == "reopen" then
      add(op, "item_uncomplete", { id = op.id })
    elseif op.kind == "delete" then
      add(op, "item_delete", { id = op.id })
    end
  end
  return out
end

--- Send one batch, resending it once if the request itself failed. The uuids
--- make the resend harmless if the first attempt did in fact land.
local function send(commands, cb)
  api.sync(commands, function(res, err)
    if not err then
      return cb(res)
    end
    api.sync(commands, cb)
  end)
end

local function describe_error(status)
  if type(status) == "table" then
    return tostring(status.error or status.error_tag or vim.inspect(status))
  end
  return tostring(status)
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

  local pending = commands_for(ops)
  local ids, failed, errors = {}, {}, {}

  local function fail(op, msg)
    if not failed[op] then
      failed[op] = true
      table.insert(errors, ("%s %q: %s"):format(op.kind, tostring(op.content), msg))
    end
  end

  local function finish()
    local applied = 0
    for _, op in ipairs(ops) do
      if not failed[op] then
        applied = applied + 1
      end
    end
    done({ applied = applied, errors = errors })
  end

  local index = 1
  local function next_batch()
    if index > #pending then
      return finish()
    end
    local batch, commands = {}, {}
    for i = index, math.min(index + BATCH - 1, #pending) do
      local item = pending[i]
      -- A temp_id only means something inside the request that created it, so
      -- anything a previous batch created is named by its real id.
      for _, key in ipairs({ "id", "parent_id" }) do
        local v = item.command.args[key]
        if v and ids[v] then
          item.command.args[key] = ids[v]
        end
      end
      table.insert(batch, item)
      table.insert(commands, item.command)
    end
    index = index + #batch

    send(commands, function(res, err)
      if err then
        for _, item in ipairs(batch) do
          fail(item.op, err)
        end
        return next_batch()
      end
      for tmp, id in pairs(type(res.temp_id_mapping) == "table" and res.temp_id_mapping or {}) do
        ids[tmp] = id
      end
      local status = type(res.sync_status) == "table" and res.sync_status or {}
      for _, item in ipairs(batch) do
        local s = status[item.command.uuid]
        if s ~= "ok" then
          fail(item.op, s == nil and "Todoist did not report on it" or describe_error(s))
        end
      end
      next_batch()
    end)
  end

  next_batch()
end

-- Exposed for the tests.
M._commands_for = commands_for

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
