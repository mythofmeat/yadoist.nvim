-- yadoist.nvim — edit your Todoist tasks as plain text.
local config = require("yadoist.config")

local M = {}

function M.setup(opts)
  config.setup(opts)
  require("yadoist.highlight").setup()
end

--- Open the task buffer in a view: "all", "today", "upcoming", "overdue" or
--- "inbox". Defaults to "all".
function M.open(view)
  return require("yadoist.buffer").open(view)
end

--- The views that can be passed to open().
function M.views()
  return require("yadoist.views").names()
end

--- Re-fetch from Todoist, discarding nothing unless the buffer is unmodified.
function M.refresh()
  local buffer = require("yadoist.buffer")
  local bufnr = buffer.current()
  if not bufnr then
    return vim.notify("yadoist: no task buffer open", vim.log.levels.WARN)
  end
  buffer.refresh(bufnr, { force = true, announce = true })
end

return M
