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
  local indent = line:match("^(%s*)%- %[[ xX]%]")
  if indent then
    return tostring(3 + #indent / 2)
  end
  return "="
end

vim.wo.foldmethod = "expr"
vim.wo.foldexpr = "v:lua.YadoistFold(v:lnum)"
vim.wo.foldlevel = 99
