-- Buffer text -> task descriptions. The inverse of render.lua.
local model = require("yadoist.model")

local M = {}

local TASK = "^(%s*)%- %[([ xX])%]%s*(.*)$"
local HEADING = "^(#+)%s+(.*)$"
-- Indented text that is not a task: a line of the description of the task
-- above it.
local DESCRIPTION = "^(%s+)(%S.*)$"

--- Where a token that could be peeled off the end of `text` would start: the
--- < of a due date, the ! of a priority, the @ of a label. Each kind can start
--- in at most one place, except a braced label, which can start at any @{
--- after the last } but one. Returned last first.
local function token_starts(text)
  local found = {}
  for _, pattern in ipairs({ "()<[^<>]*>$", "()!p[1-4]$", "()@[^%s@{][^%s@]*$" }) do
    local at = text:match(pattern)
    if at then
      found[at] = true
    end
  end
  if text:sub(-1) == "}" then
    local from = (text:sub(1, -2):match(".*()}") or 0) + 1
    for at in text:sub(from, -2):gmatch("()@{") do
      found[from + at - 1] = true
    end
  end
  local starts = vim.tbl_keys(found)
  table.sort(starts, function(a, b)
    return a > b
  end)
  return starts
end

--- Make a title read back as itself. A token at the end of a title, like the
--- `<div>` in "Style the <div>", would be peeled off as a suffix, so each one
--- with whitespace before it gets a backslash in front: `Style the \<div>`.
--- One that already had backslashes there gets one more, and unescape() takes
--- exactly one away, so the scheme reverses exactly.
function M.escape(text)
  for _, at in ipairs(token_starts(text)) do
    if text:sub(1, at - 1):match("%s\\*$") then
      text = text:sub(1, at - 1) .. "\\" .. text:sub(at)
    end
  end
  return text
end

local function unescape(text)
  for _, at in ipairs(token_starts(text)) do
    if text:sub(1, at - 1):match("%s\\+$") then
      text = text:sub(1, at - 2) .. text:sub(at)
    end
  end
  return text
end

--- How a label is written: @name, or @{name} for a name a bare @ cannot carry,
--- such as one with a space in it.
---
--- A bare name has no spaces or @ in it and does not start with {, which is
--- what opens a braced one. A braced name has no } in it, nor a space followed
--- by @, either of which would end it early. A name that fits neither, such as
--- one with both a space and a }, cannot be written at all; Todoist would
--- allow one, but it seems never to happen.
function M.label_token(name)
  if name:match("^[^%s@{][^%s@]*$") then
    return "@" .. name
  end
  return "@{" .. name .. "}"
end

--- A description line that would read as a task gets a backslash in front of
--- its checkbox, and one that already had backslashes there gets one more, so
--- that, too, reverses exactly.
function M.escape_description(line)
  local ws, rest = line:match("^(%s*)(\\*%- %[[ xX]%].*)$")
  if ws then
    return ws .. "\\" .. rest
  end
  return line
end

local function unescape_description(line)
  local ws, rest = line:match("^(%s*)\\(\\*%- %[[ xX]%].*)$")
  if ws then
    return ws .. rest
  end
  return line
end

--- Peel the trailing @label / !pN / <due> tokens off a task's text, and say
--- where each one was.
---
--- Each pattern demands whitespace before its marker, so an address like
--- "email bob@example.com" keeps its @ instead of losing a fake label.
local function peel(text)
  local labels, priority, due, spans = {}, nil, nil, {}
  local changed = true

  local function took(kind, body, token)
    table.insert(spans, { kind = kind, from = #text - #token, to = #text })
    text, changed = body, true
  end

  while changed do
    changed = false
    text = text:gsub("%s+$", "")

    if due == nil then
      local body, d = text:match("^(.-)%s+<([^<>]*)>$")
      if body then
        due = d
        took("due", body, "<" .. d .. ">")
      end
    end

    if priority == nil then
      local body, p = text:match("^(.-)%s+!p([1-4])$")
      if body then
        priority = tonumber(p)
        took("priority", body, "!p" .. p)
      end
    end

    -- A bare @label first: one ending in } must not close a @{ further back.
    -- Then a braced one, from the last @{ so that one left open in the title
    -- cannot swallow it.
    local body, l = text:match("^(.-)%s+@([^%s@{][^%s@]*)$")
    local token = body and ("@" .. l)
    if not body then
      body, l = text:match("^(.*)%s+@{([^}]+)}$")
      token = body and ("@{" .. l .. "}")
    end
    if body then
      table.insert(labels, 1, l)
      took("label", body, token)
    end
  end

  local content = text:gsub("%s+$", "")
  return unescape(content), labels, priority, due, spans, #content
end

--- Peel the trailing @label / !pN / <due> tokens off a task's text.
---@return string content, string[] labels, integer|nil priority, string|nil due
function M.split_suffixes(text)
  local content, labels, priority, due = peel(vim.trim(text))
  return content, labels, priority, due
end

--- A task's description from its lines. Blank lines between them are kept as
--- paragraph breaks, and the result is normalised the way model.description
--- normalises what Todoist sends, so the two compare equal.
---@param items { lnum: integer, text: string }[]
function M.join_description(items)
  local texts = {}
  for _, item in ipairs(items) do
    table.insert(texts, item.text)
  end
  return model.description({ description = table.concat(texts, "\n") })
end

--- Parse a whole buffer.
---
--- Each entry is one task line. Besides what the line says, it records the
--- lines of the heading it sits under (project_lnum, section_lnum), so the
--- diff can tell which project those headings were drawn for, and its
--- description lines with their line numbers.
---@param lines string[]
---@return table[] entries, table[] errors, table[] headings  { lnum, level, name }
function M.buffer(lines)
  local entries, errors, headings = {}, {}, {}
  local project, section = nil, nil
  -- The task that description lines belong to: the last one parsed, until a
  -- heading or an unreadable line comes between. Blank lines are held back
  -- until more of its description follows, so a description can have
  -- paragraphs without the gap after it counting.
  local last, held = nil, {}

  for lnum, line in ipairs(lines) do
    local hashes, name = line:match(HEADING)
    local indent, described = nil, nil
    if not line:match(TASK) then
      indent, described = line:match(DESCRIPTION)
    end

    if line:match("^%s*$") then
      table.insert(held, lnum)
    elseif described then
      if last then
        if #last.lines > 0 then
          for _, blank in ipairs(held) do
            table.insert(last.lines, { lnum = blank, text = "" })
          end
        end
        -- The indent it is drawn with is the buffer's; whatever follows that,
        -- tabs included, is the text's own.
        local own = indent:sub((last.depth + 1) * 2 + 1)
        table.insert(last.lines, { lnum = lnum, text = unescape_description(own .. described) })
      else
        table.insert(errors, { lnum = lnum, msg = "description has no task above it" })
      end
    elseif hashes then
      last = nil
      name = vim.trim(name or "")
      if name == "" then
        table.insert(errors, { lnum = lnum, msg = "heading has no name" })
      elseif #hashes == 1 then
        project, section = { lnum = lnum, level = 1, name = name }, nil
        table.insert(headings, project)
      elseif #hashes == 2 then
        if not project then
          table.insert(errors, { lnum = lnum, msg = "section appears before any project heading" })
        end
        section = { lnum = lnum, level = 2, name = name }
        table.insert(headings, section)
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
            project = project.name,
            project_lnum = project.lnum,
            section = section and section.name,
            section_lnum = section and section.lnum,
            lines = {},
          }
          table.insert(entries, last)
        end
      end
    end
    if not line:match("^%s*$") then
      held = {}
    end
  end

  for _, e in ipairs(entries) do
    e.description = M.join_description(e.lines)
  end

  -- Resolve subtask parents from indentation. A heading starts afresh, so an
  -- indented first line can never reach back to a task under the heading above.
  local stack, under = {}, nil
  for _, e in ipairs(entries) do
    local here = tostring(e.project_lnum) .. "\0" .. tostring(e.section_lnum)
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
  return entries, errors, headings
end

--- Where the parts of a line are, for highlighting it as it is typed: a list
--- of { kind, from, to } with 0-based byte columns, `to` exclusive. Kinds are
--- "project", "section", "description", "checkbox", "content", "label",
--- "priority" and "due"; a task line also says whether it is ticked, and gives
--- its due text and priority.
function M.line_spans(line)
  local hashes = line:match("^(#+)%s+%S")
  if hashes then
    return { { kind = #hashes == 1 and "project" or "section", from = 0, to = #line } }, { name = vim.trim(line:sub(#hashes + 1)) }
  end
  local indent, box, rest = line:match("^(%s*)%- %[([ xX])%](.*)$")
  if indent then
    local text_from = #line - #rest + #rest:match("^%s*")
    local content, _, priority, due, spans, content_len = peel(line:sub(text_from + 1))
    local out = {
      { kind = "checkbox", from = #indent, to = #indent + 5 },
      { kind = "content", from = text_from, to = text_from + content_len },
    }
    for _, s in ipairs(spans) do
      table.insert(out, { kind = s.kind, from = text_from + s.from, to = text_from + s.to })
    end
    return out, { done = box ~= " ", due = due, priority = priority, content = content }
  end
  local lead = line:match("^(%s+)%S")
  if lead then
    return { { kind = "description", from = #lead, to = #line } }, {}
  end
  return {}, {}
end

return M
