-- Buffer text -> task descriptions. The inverse of render.lua.
local M = {}

local TASK = "^(%s*)%- %[([ xX])%]%s*(.*)$"
local HEADING = "^(#+)%s+(.*)$"

--- Peel the trailing @label / !pN / <due> tokens off a task's text.
---
--- Each pattern demands whitespace before its marker, so an address like
--- "email bob@example.com" keeps its @ instead of losing a fake label.
---@return string content, string[] labels, integer|nil priority, string|nil due
function M.split_suffixes(text)
  local labels, priority, due = {}, nil, nil
  local changed = true

  while changed do
    changed = false
    text = text:gsub("%s+$", "")

    if due == nil then
      local body, d = text:match("^(.-)%s+<([^<>]*)>$")
      if body then
        text, due, changed = body, d, true
      end
    end

    if priority == nil then
      local body, p = text:match("^(.-)%s+!p([1-4])$")
      if body then
        text, priority, changed = body, tonumber(p), true
      end
    end

    local body, l = text:match("^(.-)%s+@([^%s@]+)$")
    if body then
      text = body
      table.insert(labels, 1, l)
      changed = true
    end
  end

  return vim.trim(text), labels, priority, due
end

--- Parse a whole buffer.
---@param lines string[]
---@return table[] entries, table[] errors
function M.buffer(lines)
  local entries, errors = {}, {}
  local project, section = nil, nil

  for lnum, line in ipairs(lines) do
    local hashes, name = line:match(HEADING)

    if line:match("^%s*$") then -- blank, ignored
    elseif hashes then
      name = vim.trim(name or "")
      if name == "" then
        table.insert(errors, { lnum = lnum, msg = "heading has no name" })
      elseif #hashes == 1 then
        project, section = name, nil
      elseif #hashes == 2 then
        if not project then
          table.insert(errors, { lnum = lnum, msg = "section appears before any project heading" })
        end
        section = name
      else
        table.insert(errors, { lnum = lnum, msg = "only # (project) and ## (section) headings are understood" })
      end
    else
      local indent, box, text = line:match(TASK)
      if not indent then
        table.insert(errors, { lnum = lnum, msg = "not a task, a project (#) or a section (##)" })
      elseif not project then
        table.insert(errors, { lnum = lnum, msg = "task appears before any project heading" })
      elseif #indent % 2 ~= 0 then
        table.insert(errors, { lnum = lnum, msg = "indent must be a multiple of two spaces" })
      else
        local content, labels, priority, due = M.split_suffixes(text)
        if content == "" then
          table.insert(errors, { lnum = lnum, msg = "task has no text" })
        else
          table.insert(entries, {
            lnum = lnum,
            depth = #indent / 2,
            done = box ~= " ",
            content = content,
            labels = labels,
            priority = priority or 4,
            due_string = due,
            project = project,
            section = section,
          })
        end
      end
    end
  end

  -- Resolve subtask parents from indentation.
  local stack = {}
  for _, e in ipairs(entries) do
    for d = #stack, e.depth + 1, -1 do
      stack[d] = nil
    end
    if e.depth > #stack then
      table.insert(errors, { lnum = e.lnum, msg = "indented past its parent — there is no task directly above it to nest under" })
      e.depth = #stack
    end
    e.parent_lnum = e.depth > 0 and stack[e.depth] or nil
    stack[e.depth + 1] = e.lnum
  end

  table.sort(errors, function(a, b)
    return a.lnum < b.lnum
  end)
  return entries, errors
end

return M
