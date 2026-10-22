if vim.g.loaded_yadoist then
  return
end
vim.g.loaded_yadoist = true

vim.api.nvim_create_user_command("Yadoist", function(cmd)
  local args = vim.trim(cmd.args)
  local text = args:match("^add%s+(.+)$")
  if text then
    return require("yadoist").add(text)
  elseif args == "add" then
    return vim.notify("yadoist: add what? — :Yadoist add Call the plumber #House tomorrow p2", vim.log.levels.ERROR)
  end
  require("yadoist").open(args ~= "" and args or nil)
end, {
  nargs = "?",
  complete = function(lead, line)
    -- After `project `, complete project names. A name can have spaces in it,
    -- and only the last word is being replaced, so hand back the rest of the
    -- name from where that word starts.
    local typed = line:match("^%S*%s+project%s+(.*)$")
    if typed then
      local from = #typed - #lead + 1
      local out = {}
      for _, name in ipairs(require("yadoist.buffer").project_names()) do
        if name:lower():find(typed:lower(), 1, true) == 1 then
          table.insert(out, name:sub(from))
        end
      end
      table.sort(out)
      return out
    end
    if line:match("^%S*%s+%S+%s") then
      return {} -- a filter query or a task to add: nothing to offer
    end
    return vim.tbl_filter(function(name)
      return name:find(lead, 1, true) == 1
    end, vim.list_extend(require("yadoist.views").names(), { "add" }))
  end,
  desc = "Open your Todoist tasks as a buffer (all|today|upcoming|overdue|inbox|completed|project <name>|filter <query>), "
    .. "or add one (add <text>)",
})

vim.api.nvim_create_user_command("YadoistRefresh", function()
  require("yadoist").refresh()
end, { desc = "Re-fetch tasks from Todoist" })

-- A task buffer is loaded from its name, so :e, :e! and restored sessions
-- fetch it from Todoist rather than reading a file that does not exist.
vim.api.nvim_create_autocmd("BufReadCmd", {
  group = vim.api.nvim_create_augroup("Yadoist", { clear = true }),
  pattern = "yadoist://*",
  desc = "Load a yadoist task buffer from Todoist",
  callback = function(ev)
    require("yadoist.buffer").load(ev.buf)
  end,
})
