-- Small helpers for reading Todoist's task shape, kept in one place because the
-- API is inconsistent about a few field names across versions.
local M = {}

--- The clock everything date-related reads, so the tests can pin "now".
M.now = os.time

--- Todoist stores 4 = urgent down to 1 = none. Its UI, and therefore our
--- buffer, calls those p1..p4.
function M.api_to_ui_priority(p)
  p = tonumber(p) or 1
  return 5 - math.max(1, math.min(4, p))
end

function M.ui_to_api_priority(p)
  p = tonumber(p) or 4
  return 5 - math.max(1, math.min(4, p))
end

--- v1 signals completion with a completed_at timestamp; older responses used a
--- boolean under one of two names. Accept all three.
function M.is_completed(task)
  return task.completed_at ~= nil or task.checked == true or task.is_completed == true
end

--- Position among siblings: child_order for tasks and projects, section_order
--- for sections (v1 does not set their child_order), or the plain order older
--- responses used.
function M.order(x)
  return tonumber(x.child_order) or tonumber(x.section_order) or tonumber(x.order) or 0
end

--- Siblings in the order Todoist shows them; the id settles ties, so the
--- order is the same every time.
function M.by_order(a, b)
  local oa, ob = M.order(a), M.order(b)
  if oa ~= ob then
    return oa < ob
  end
  return tostring(a.id) < tostring(b.id)
end

--- Within a day, Todoist's own manual day order first, then priority, then the
--- task's place in its project.
function M.by_day(a, b)
  local function day_order(t)
    local n = tonumber(t.day_order)
    return (n and n >= 0) and n or math.huge
  end
  local da, db = day_order(a), day_order(b)
  if da ~= db then
    return da < db
  end
  local pa, pb = tonumber(a.priority) or 1, tonumber(b.priority) or 1
  if pa ~= pb then
    return pa > pb
  end
  return M.by_order(a, b)
end

--- Seconds since the epoch for a UTC calendar time. os.time() reads its table
--- as local time, and correcting that by the offset from UTC in force now is
--- an hour out for any date across a daylight-saving change, so this does the
--- arithmetic itself (days from civil, after Howard Hinnant).
function M.utc_time(y, m, d, h, min, s)
  y = m <= 2 and y - 1 or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return (era * 146097 + doe - 719468) * 86400 + (h or 0) * 3600 + (min or 0) * 60 + (s or 0)
end

--- Split a due date into the day and time of day it falls on here. Todoist
--- sends a date-only due as YYYY-MM-DD, a floating time as
--- YYYY-MM-DDTHH:MM:SS, which means that clock time wherever you are, and a
--- fixed-timezone time in UTC with a trailing Z, which is converted to local
--- time so it is shown, sorted and filed under the day it falls on here.
---@return string|nil day YYYY-MM-DD
---@return string|nil time HH:MM:SS, or nil for a date-only due
---@return boolean fixed whether it was a fixed-timezone time
local function local_parts(date)
  local y, m, d, rest = date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)(.*)$")
  if not y then
    return nil, nil, false
  end
  local h, min, s, z = rest:match("^T(%d%d):(%d%d):(%d%d)[%.%d]*(Z?)")
  if not h then
    return ("%s-%s-%s"):format(y, m, d), nil, false
  end
  if z == "Z" then
    local at = M.utc_time(tonumber(y), tonumber(m), tonumber(d), tonumber(h), tonumber(min), tonumber(s))
    return os.date("%Y-%m-%d", at), os.date("%H:%M:%S", at), true
  end
  return ("%s-%s-%s"):format(y, m, d), ("%s:%s:%s"):format(h, min, s), false
end

--- A resolved due date as `YYYY-MM-DD`, or `YYYY-MM-DD HH:MM` when it has a
--- time, in local time.
local function format_date(date)
  local day, time = local_parts(date)
  if not day then
    return date:sub(1, 10)
  end
  return time and (day .. " " .. time:sub(1, 5)) or day
end

--- What goes between the `<...>`. One-off dates are shown as the date they
--- resolved to, so every one reads the same whether it was typed as `tomorrow`
--- or `26 Sep 3pm`. Recurring ones keep the string Todoist parsed them from
--- ("every saturday"), because saving a plain date back would turn them into
--- one-offs.
function M.due_string(task)
  local due = task.due
  if type(due) ~= "table" then
    return nil
  end
  local has_date = type(due.date) == "string" and due.date ~= ""
  if has_date and due.is_recurring ~= true then
    return format_date(due.date)
  end
  if type(due.string) == "string" and due.string ~= "" then
    return M.one_line(due.string)
  end
  if has_date then
    return format_date(due.date)
  end
  return nil
end

--- The local YYYY-MM-DD a task is due on: what decides whether it is
--- overdue, and which day a date view files it under.
function M.due_date(task)
  local due = task.due
  if type(due) ~= "table" or type(due.date) ~= "string" then
    return nil
  end
  return local_parts(due.date) or due.date:sub(1, 10)
end

--- The due fields that move a task to another day, as dragging it does in
--- Todoist: a timed task keeps its time of day. A fixed-timezone one keeps its
--- local clock time, sent back in UTC, and its time zone.
---@param day string YYYY-MM-DD, local
---@return table fields { due_date } or { due_datetime, due_timezone? }
function M.reschedule(task, day)
  local _, time, fixed = local_parts(task.due.date)
  if not time then
    return { due_date = day }
  end
  if not fixed then
    return { due_datetime = day .. "T" .. time }
  end
  local y, m, d = day:match("^(%d+)-(%d+)-(%d+)$")
  local h, min, s = time:match("^(%d+):(%d+):(%d+)$")
  local at = os.time({
    year = tonumber(y), month = tonumber(m), day = tonumber(d),
    hour = tonumber(h), min = tonumber(min), sec = tonumber(s),
  })
  return { due_datetime = os.date("!%Y-%m-%dT%H:%M:%SZ", at), due_timezone = task.due.timezone }
end

--- Whether the due date repeats. Rescheduling one of these by date would flatten
--- it into a one-off, so the date views refuse to.
function M.is_recurring(task)
  return type(task.due) == "table" and task.due.is_recurring == true
end

function M.today()
  return os.date("%Y-%m-%d", M.now())
end

--- YYYY-MM-DD n days from today. Stepping the day field at noon, rather than
--- adding n * 86400 seconds, keeps a daylight-saving change from skipping or
--- repeating a day.
function M.date_after(n)
  local now = os.date("*t", M.now())
  return os.date("%Y-%m-%d", os.time({ year = now.year, month = now.month, day = now.day + n, hour = 12 }))
end

--- The API returns this as `inbox_project`; some responses and SDKs spell it
--- `is_inbox_project`. Accept either.
function M.is_inbox(project)
  return project.inbox_project == true or project.is_inbox_project == true
end

--- Text the buffer draws on a single line: a title, a label, a project or
--- section name. Todoist will store a line break in any of them, which no
--- buffer line can hold, so each becomes a space, and the ends are trimmed.
function M.one_line(s)
  local text = tostring(s or ""):gsub("\r\n?", "\n"):gsub("\n", " ")
  return vim.trim(text)
end

--- A task's title as the buffer shows it. Comparing this rather than the raw
--- title keeps a line break that was drawn as a space from reading as an edit.
function M.content(task)
  return M.one_line(task.content)
end

--- The description as the buffer shows it: Unix line endings, no blank lines
--- at either end, no trailing whitespace on any line, and whitespace-only
--- lines left empty. Comparing these rather than the raw strings keeps
--- differences the buffer cannot show from reading as edits.
function M.description(task)
  local d = type(task.description) == "string" and task.description or ""
  d = d:gsub("\r\n?", "\n"):gsub("[ \t]+\n", "\n"):gsub("^%s*\n", ""):gsub("%s+$", "")
  return d
end

function M.labels(task)
  local out = {}
  for _, l in ipairs(task.labels or {}) do
    table.insert(out, M.one_line(l))
  end
  return out
end

return M
