-- Highlight groups, and the colouring of task buffers.
--
-- Every group links to a standard one by default, so the buffer follows
-- whatever colourscheme is loaded without any configuration.
--
-- Lines are coloured as they are drawn on screen, from their text, so a line
-- you type is coloured the same as one yadoist drew. Dates are coloured from
-- the task data where the line still shows the date that was fetched: a
-- recurring task reads <every day>, but is overdue all the same.
local model = require("yadoist.model")
local parse = require("yadoist.parse")

local M = {}

local links = {
  YadoistProject = "Title",
  YadoistSection = "Directory",
  YadoistCheckboxOpen = "Delimiter",
  YadoistCheckboxDone = "Comment",
  YadoistContent = "Normal",
  YadoistLabel = "Identifier",
  YadoistPriority1 = "DiagnosticError",
  YadoistPriority2 = "DiagnosticWarn",
  YadoistPriority3 = "DiagnosticInfo",
  YadoistDue = "Constant",
  YadoistDueToday = "DiagnosticWarn",
  YadoistDueOverdue = "DiagnosticError",
  YadoistAnnotation = "Comment",
  YadoistDescription = "Comment",
  YadoistDeadline = "YadoistDue",
  YadoistAssignee = "YadoistAnnotation",
}

function M.apply()
  for name, target in pairs(links) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end

  -- Completed tasks get Comment's colour plus a strikethrough, which needs the
  -- colour resolved rather than linked.
  local ok, comment = pcall(vim.api.nvim_get_hl, 0, { name = "Comment", link = false })
  vim.api.nvim_set_hl(0, "YadoistContentDone", {
    default = true,
    fg = ok and comment.fg or nil,
    strikethrough = true,
  })
end

local GROUPS = {
  project = "YadoistProject",
  section = "YadoistSection",
  description = "YadoistDescription",
  label = "YadoistLabel",
}

--- The highlights for one line, as { group, from, to } with 0-based byte
--- columns.
---@param task table|nil the task this line was drawn for, if it still is
---@param ctx table { today = YYYY-MM-DD, overdue = the heading text of a date view's overdue day, if any }
function M.groups(line, task, ctx)
  local spans, info = parse.line_spans(line)
  local out = {}
  for _, s in ipairs(spans) do
    local group = GROUPS[s.kind]
    if s.kind == "checkbox" then
      group = info.done and "YadoistCheckboxDone" or "YadoistCheckboxOpen"
    elseif s.kind == "content" then
      group = info.done and "YadoistContentDone" or "YadoistContent"
    elseif s.kind == "priority" then
      group = info.priority and info.priority < 4 and ("YadoistPriority" .. info.priority) or nil
    elseif s.kind == "due" then
      local date
      if task and info.due == model.due_string(task) then
        date = model.due_date(task)
      else
        date = info.due and info.due:match("^(%d%d%d%d%-%d%d%-%d%d)")
      end
      group = (date and date < ctx.today) and "YadoistDueOverdue" or (date == ctx.today and "YadoistDueToday") or "YadoistDue"
    elseif s.kind == "project" and ctx.overdue and info.name == ctx.overdue then
      group = "YadoistDueOverdue"
    end
    if group and s.to > s.from then
      table.insert(out, { group, s.from, s.to })
    end
  end
  return out
end

local ns = vim.api.nvim_create_namespace("yadoist_syntax")
-- What each window being redrawn needs to know, for the lines that follow.
local drawing = {}

local function on_win(_, win, bufnr, top, bottom)
  if vim.bo[bufnr].filetype ~= "yadoist" then
    return false
  end
  local buffer = package.loaded["yadoist.buffer"]
  drawing[win] = {
    today = model.today(),
    tasks = buffer and buffer.tasks_on(bufnr, top, bottom) or {},
    overdue = buffer and buffer.overdue_heading(bufnr) or nil,
  }
end

local function on_line(_, win, bufnr, row)
  local ctx = drawing[win]
  local line = ctx and vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if not line then
    return
  end
  for _, h in ipairs(M.groups(line, ctx.tasks[row], ctx)) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, row, h[2], { end_col = h[3], hl_group = h[1], ephemeral = true })
  end
end

function M.setup()
  M.apply()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("YadoistHighlight", { clear = true }),
    desc = "Re-resolve yadoist's highlight groups after a colourscheme change",
    callback = M.apply,
  })
  vim.api.nvim_set_decoration_provider(ns, { on_win = on_win, on_line = on_line })
end

return M
