-- Buffer lifecycle tests: windows, folding, and the buffer the way a user meets
-- it. From the repo root:
--   nvim --headless -u NONE -i NONE -l tests/lifecycle.lua
vim.opt.rtp:prepend(".")
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
vim.cmd("filetype plugin on | runtime plugin/yadoist.lua")

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then
    passed = passed + 1
    print(("  ok   %s"):format(name))
  else
    failed = failed + 1
    print(("  FAIL %s%s"):format(name, detail and ("\n       " .. tostring(detail)) or ""))
  end
end

--- A scratch buffer holding `lines`, shown in the current window and given
--- the yadoist filetype there.
local function scratch(lines)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "yadoist"
  return buf
end

print("\nfolding")
do
  scratch({ "# Inbox", "", "- [ ] A", "  notes on A", "  - [ ] A1", "- [ ] B", "- [ ] C" })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  vim.cmd("normal! zc")
  check("zc on a task folds only that task and its children", vim.fn.foldclosedend(3) == 5,
    ("folded %d..%d"):format(vim.fn.foldclosed(3), vim.fn.foldclosedend(3)))
  vim.cmd("normal! zo")
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  vim.cmd("normal! zc")
  check("a task with nothing under it does not fold", vim.fn.foldclosed(6) == -1,
    ("folded %d..%d"):format(vim.fn.foldclosed(6), vim.fn.foldclosedend(6)))

  vim.cmd("enew")
  check("the task buffer's fold settings do not leak into the next buffer",
    vim.wo.foldexpr ~= "v:lua.YadoistFold(v:lnum)" and vim.wo.foldmethod ~= "expr" and vim.wo.wrap,
    ("foldmethod=%s foldexpr=%s wrap=%s"):format(vim.wo.foldmethod, vim.wo.foldexpr, tostring(vim.wo.wrap)))

  -- Given its filetype while hidden, the way a buffer is when it is set up
  -- before it is shown: the ftplugin runs in a window that is thrown away.
  local hidden = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(hidden, 0, -1, false, { "# Inbox", "", "- [ ] A" })
  vim.bo[hidden].filetype = "yadoist"
  vim.api.nvim_set_current_buf(hidden)
  check("a buffer given its filetype while hidden folds once it is shown",
    vim.wo.foldmethod == "expr" and vim.wo.foldexpr == "v:lua.YadoistFold(v:lnum)" and not vim.wo.wrap,
    ("foldmethod=%s foldexpr=%s wrap=%s"):format(vim.wo.foldmethod, vim.wo.foldexpr, tostring(vim.wo.wrap)))
  vim.cmd("split | enew")
  check("and so does a second window showing it", (function()
    vim.api.nvim_set_current_buf(hidden)
    return vim.wo.foldmethod == "expr"
  end)(), "foldmethod=" .. vim.wo.foldmethod)
  vim.cmd("only")
end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
end
