-- Buffer text -> task descriptions. The inverse of render.lua.
local model = require("yadoist.model")

local M = {}

local TASK = "^(%s*)%- %[([ xX])%]%s*(.*)$"
local HEADING = "^(#+)%s+(.*)$"
-- Indented text that is not a task: a line of the description of the task
-- above it.
local DESCRIPTION = "^(%s+)(%S.*)$"

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
  -- The task that description lines belong to: the last one parsed, until a
  -- heading or an unreadable line comes between. Blank lines are held back
  -- until more of its description follows, so a description can have
  -- paragraphs without the gap after it counting.
  local last, blanks = nil, 0

  for lnum, line in ipairs(lines) do
    local hashes, name = line:match(HEADING)
    local indent, described = nil, nil
    if not line:match(TASK) then
      indent, described = line:match(DESCRIPTION)
    end

    if line:match("^%s*$") then
      blanks = blanks + 1
    elseif described then
      if last then
        if #last.description_lines > 0 then
          for _ = 1, blanks do
            table.insert(last.description_lines, "")
          end
        end
        -- The indent it is drawn with is the buffer's; any past that is the text's.
        local own = math.max(0, #indent - (last.depth + 1) * 2)
        table.insert(last.description_lines, indent:sub(1, own) .. described)
      else
        table.insert(errors, { lnum = lnum, msg = "description has no task above it" })
      end
    elseif hashes then
      last = nil
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
      last = nil
      if not indent then
        table.insert(errors, { lnum = lnum,
          msg = "not a task, a project (#) or a section (##) — indent it to make it the description of the task above" })
      elseif not project then
        table.insert(errors, { lnum = lnum, msg = "task appears before any project heading" })
      elseif #indent % 2 ~= 0 then
        table.insert(errors, { lnum = lnum, msg = "indent must be a multiple of two spaces" })
      else
        local content, labels, priority, due = M.split_suffixes(text)
        if content == "" then
          table.insert(errors, { lnum = lnum, msg = "task has no text" })
        else
          last = {
            lnum = lnum,
            depth = #indent / 2,
            done = box ~= " ",
            content = content,
            labels = labels,
            priority = priority or 4,
            due_string = due,
            project = project,
            section = section,
            description_lines = {},
          }
          table.insert(entries, last)
        end
      end
    end
    if not line:match("^%s*$") then
      blanks = 0
    end
  end

  for _, e in ipairs(entries) do
    e.description = model.description({ description = table.concat(e.description_lines, "\n") })
    e.description_lines = nil
  end

  -- Resolve subtask parents from indentation. A heading starts afresh, so an
  -- indented first line can never reach back to a task under the heading above.
  local stack, under = {}, nil
  for _, e in ipairs(entries) do
    local here = tostring(e.project) .. "\0" .. tostring(e.section)
    if here ~= under then
      stack, under = {}, here
    end
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
