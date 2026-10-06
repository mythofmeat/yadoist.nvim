-- Buffer-local settings for the task buffer.
vim.bo.commentstring = ""
vim.bo.expandtab = true
vim.bo.shiftwidth = 2
vim.bo.tabstop = 2
vim.wo.wrap = false

-- Fold projects, then sections, then subtasks under their parent.
function _G.YadoistFold(lnum)
  local line = vim.fn.getline(lnum)
  local hashes = line:match("^(#+)%s")
  if hashes then
    return ">" .. math.min(#hashes, 2)
  end
  -- A description line folds at its task's subtask level, so closing the fold
  -- on a task tucks its description away with its subtasks.
  local indent = line:match("^(%s*)%- %[[ xX]%]") or line:match("^(%s+)%S")
  if indent then
    return tostring(3 + math.floor(#indent / 2))
  end
  return "="
end

vim.wo.foldmethod = "expr"
vim.wo.foldexpr = "v:lua.YadoistFold(v:lnum)"
vim.wo.foldlevel = 99
