-- What :w is about to send, shown before anything goes when the write could
-- surprise you: it deletes something, renames a project or section, takes
-- along subtasks the view does not show, or moves tasks after a heading line
-- was deleted (which usually means they fell under the heading above).
local config = require("yadoist.config")

local M = {}

local VERBS = {
  rename = "rename", create = "add", update = "change", move = "move", close = "complete",
  reopen = "reopen", delete = "delete", reorder = "reorder", day_order = "reorder",
}

local FIELDS = { content = "title", description = "description", priority = "priority", labels = "labels" }

--- What changes about a task, in words.
local function changed(fields)
  local out = {}
  for key, word in pairs(FIELDS) do
    if fields[key] ~= nil then
      table.insert(out, word)
    end
  end
  if fields.due_string or fields.due_date or fields.due_datetime then
    table.insert(out, "date")
  end
  table.sort(out)
  return table.concat(out, ", ")
end

--- One line for one op.
function M.line(op)
  local text
  if op.kind == "rename" then
    text = ("%s %q to %q"):format(op.target, op.content, op.name)
  elseif op.kind == "reorder" or op.kind == "day_order" then
    text = tostring(op.content)
  else
    text = ("%q"):format(tostring(op.content))
    if op.kind == "update" then
      text = text .. ": " .. changed(op.fields)
    elseif op.kind == "move" and op.where then
      text = text .. " to " .. op.where
    end
  end
  if op.hidden then
    text = text .. (", with %d subtask%s this view hides: %s"):format(#op.hidden, #op.hidden == 1 and "" or "s",
      table.concat(op.hidden, ", "))
  end
  return ("  %-9s %s"):format(VERBS[op.kind] or op.kind, text)
end

--- Why this write needs asking about, or nil.
function M.risky(ops, info)
  for _, op in ipairs(ops) do
    if op.kind == "delete" or op.kind == "rename" or op.hidden then
      return true
    end
    if op.kind == "move" and (info and info.headings_removed or 0) > 0 then
      return true
    end
  end
  return false
end

local LIMIT = 20

--- Ask before sending, when the write calls for it.
---@return table[]|nil ops  what to send, or nil if the write was cancelled
function M.confirm(ops, info)
  local mode = config.options.confirm
  if mode == false or (mode ~= "always" and not M.risky(ops, info)) then
    return ops
  end

  local lines, deletes = {}, 0
  for i, op in ipairs(ops) do
    if i <= LIMIT then
      table.insert(lines, M.line(op))
    end
    if op.kind == "delete" then
      deletes = deletes + 1
    end
  end
  if #ops > LIMIT then
    table.insert(lines, ("  … and %d more"):format(#ops - LIMIT))
  end
  local notes = {}
  if deletes > 0 then
    table.insert(notes, "Deleting a task removes it for everyone its project is shared with.")
  end
  if (info and info.headings_removed or 0) > 0 then
    table.insert(notes, "A heading line was deleted, so the tasks under it now sit under the heading above it.")
  end

  local msg = ("Send %d change%s to Todoist?\n\n%s%s"):format(#ops, #ops == 1 and "" or "s",
    table.concat(lines, "\n"), #notes > 0 and ("\n\n" .. table.concat(notes, "\n")) or "")
  if deletes == 0 then
    return vim.fn.confirm(msg, "&Send\n&Cancel", 2, "Question") == 1 and ops or nil
  end
  local choice = vim.fn.confirm(msg, "&Send\nSend all but the &deletes\n&Cancel", 3, "Question")
  if choice == 1 then
    return ops
  elseif choice == 2 then
    return vim.tbl_filter(function(op)
      return op.kind ~= "delete"
    end, ops)
  end
  return nil
end

return M
