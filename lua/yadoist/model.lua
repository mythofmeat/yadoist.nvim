-- Small helpers for reading Todoist's task shape, kept in one place because the
-- API is inconsistent about a few field names across versions.
local M = {}

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

function M.order(task)
  return tonumber(task.child_order) or tonumber(task.order) or 0
end

--- A resolved due date as `YYYY-MM-DD`, or `YYYY-MM-DD HH:MM` when it has a
--- time. Todoist sends a floating time as-is and a fixed-timezone one in UTC
--- with a trailing Z, which is shown in local time.
local function format_date(date)
  local day, h, min, utc = date:match("^(%d+%-%d+%-%d+)T(%d+):(%d+):[%d.]+(Z?)")
  if not day then
    return date:sub(1, 10)
  end
  if utc == "Z" then
    local y, m, d = day:match("(%d+)-(%d+)-(%d+)")
    local stamp = os.time({ year = y, month = m, day = d, hour = h, min = min })
    -- os.time read that as local time; shift by the local offset from UTC.
    local offset = os.time() - os.time(os.date("!*t"))
    return os.date("%Y-%m-%d %H:%M", stamp + offset)
  end
  return ("%s %s:%s"):format(day, h, min)
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
    return due.string
  end
  if has_date then
    return format_date(due.date)
  end
  return nil
end

--- The resolved YYYY-MM-DD, used only to decide whether something is overdue.
function M.due_date(task)
  local due = task.due
  if type(due) ~= "table" or type(due.date) ~= "string" then
    return nil
  end
  return due.date:sub(1, 10)
end

--- Whether the due date repeats. Rescheduling one of these by date would flatten
--- it into a one-off, so the date views refuse to.
function M.is_recurring(task)
  return type(task.due) == "table" and task.due.is_recurring == true
end

function M.today()
  return os.date("%Y-%m-%d")
end

--- YYYY-MM-DD n days from today. Stepping the day field at noon, rather than
--- adding n * 86400 seconds, keeps a daylight-saving change from skipping or
--- repeating a day.
function M.date_after(n)
  local now = os.date("*t")
  return os.date("%Y-%m-%d", os.time({ year = now.year, month = now.month, day = now.day + n, hour = 12 }))
end

--- The API returns this as `inbox_project`; some responses and SDKs spell it
--- `is_inbox_project`. Accept either.
function M.is_inbox(project)
  return project.inbox_project == true or project.is_inbox_project == true
end

function M.labels(task)
  local out = {}
  for _, l in ipairs(task.labels or {}) do
    table.insert(out, l)
  end
  return out
end

return M
