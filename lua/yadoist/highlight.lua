-- Highlight groups. Everything links to a standard group by default, so the
-- buffer follows whatever colourscheme is loaded without any configuration.
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

function M.setup()
  M.apply()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("YadoistHighlight", { clear = true }),
    desc = "Re-resolve yadoist's highlight groups after a colourscheme change",
    callback = M.apply,
  })
end

return M
