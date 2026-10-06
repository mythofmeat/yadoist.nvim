if vim.g.loaded_yadoist then
  return
end
vim.g.loaded_yadoist = true

vim.api.nvim_create_user_command("Yadoist", function(cmd)
  require("yadoist").open(cmd.args ~= "" and cmd.args or nil)
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
    return vim.tbl_filter(function(name)
      return name:find(lead, 1, true) == 1
    end, require("yadoist.views").names())
  end,
  desc = "Open your Todoist tasks as a buffer (all|today|upcoming|overdue|inbox|project <name>)",
})

vim.api.nvim_create_user_command("YadoistRefresh", function()
  require("yadoist").refresh()
end, { desc = "Re-fetch tasks from Todoist" })
