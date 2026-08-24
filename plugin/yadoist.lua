if vim.g.loaded_yadoist then
  return
end
vim.g.loaded_yadoist = true

vim.api.nvim_create_user_command("Yadoist", function(cmd)
  require("yadoist").open(cmd.args ~= "" and cmd.args or nil)
end, {
  nargs = "?",
  complete = function(lead)
    return vim.tbl_filter(function(name)
      return name:find(lead, 1, true) == 1
    end, require("yadoist.views").names())
  end,
  desc = "Open your Todoist tasks as a buffer (all|today|upcoming|overdue|inbox)",
})

vim.api.nvim_create_user_command("YadoistRefresh", function()
  require("yadoist").refresh()
end, { desc = "Re-fetch tasks from Todoist" })
