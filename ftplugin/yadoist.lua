-- Buffer-local settings for the task buffer.
local bufnr = vim.api.nvim_get_current_buf()

vim.bo.commentstring = ""
vim.bo.expandtab = true
vim.bo.shiftwidth = 2
vim.bo.tabstop = 2
-- <C-x><C-o> completes @labels, and project and section names in headings.
vim.bo.omnifunc = "v:lua.require'yadoist.complete'.omnifunc"

-- Fold projects, then sections, then each task along with its description and
-- subtasks. Every task line starts a fold of its own, so zc on a task folds
-- just that task; one with nothing under it is too short to fold at all.
function _G.YadoistFold(lnum)
  local line = vim.fn.getline(lnum)
  local hashes = line:match("^(#+)%s")
  if hashes then
    return ">" .. math.min(#hashes, 2)
  end
  local task = line:match("^(%s*)%- %[[ xX]%]")
  if task then
    return ">" .. (3 + math.floor(#task / 2))
  end
  -- A description line folds one level inside its task.
  local indent = line:match("^(%s+)%S")
  if indent then
    return tostring(3 + math.floor(#indent / 2))
  end
  return "="
end

-- Window options belong to the window showing the buffer, and the buffer can
-- be given its filetype before it is shown in one, so they are set again
-- whenever it is. Setting them locally keeps them with this buffer instead of
-- following the window into whatever is opened in it next.
local function window_options()
  vim.opt_local.wrap = false
  vim.opt_local.foldmethod = "expr"
  vim.opt_local.foldexpr = "v:lua.YadoistFold(v:lnum)"
  vim.opt_local.foldlevel = 99
end

window_options()
local group = vim.api.nvim_create_augroup("YadoistWindow" .. bufnr, { clear = true })
vim.api.nvim_create_autocmd("BufWinEnter", {
  group = group,
  buffer = bufnr,
  desc = "Set yadoist's window options in each window showing the buffer",
  callback = window_options,
})

vim.b.undo_ftplugin = table.concat({
  "setlocal commentstring< expandtab< shiftwidth< tabstop< omnifunc<",
  "setlocal wrap< foldmethod< foldexpr< foldlevel<",
  "silent! autocmd! YadoistWindow" .. bufnr,
}, " | ")
