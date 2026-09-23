-- User-facing configuration.
local M = {}

local defaults = {
  -- Todoist API token: a string, or a function returning one. Defaults to the
  -- environment so the token never has to live in a dotfile.
  token = function()
    return vim.env.TODOIST_API_TOKEN
  end,

  -- Deleting a line deletes the task for everyone the project is shared with,
  -- so ask first.
  confirm_delete = true,

  -- Todoist creates any label it has not seen, so a typo like @erand would
  -- quietly become a new label. By default :w refuses instead, the same way it
  -- refuses to invent projects. Set true to let new labels through.
  create_labels = false,

  -- Only show these projects, by name. nil shows every project.
  projects = nil,

  -- Re-fetch when the buffer regains focus, so a shared list does not sit
  -- stale on screen after someone else changes something.
  refresh_on_focus = true,

  -- Per-request timeout, in milliseconds.
  timeout = 15000,

  keymaps = {
    toggle = "<CR>", -- flip the checkbox under the cursor
    refresh = "R",
    close = "q",
  },
}

M.options = vim.deepcopy(defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

--- Resolve the token.
---@return string|nil token
---@return string|nil err
function M.token()
  local t = M.options.token
  if type(t) == "function" then
    local ok, res = pcall(t)
    if not ok then
      return nil, "token function errored: " .. tostring(res)
    end
    t = res
  end
  if type(t) ~= "string" or t == "" then
    return nil, "no Todoist API token — set $TODOIST_API_TOKEN, or pass token = ... to setup()"
  end
  return t
end

return M
