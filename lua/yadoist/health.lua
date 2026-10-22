-- :checkhealth yadoist
local M = {}

function M.check()
  local health = vim.health
  health.start("yadoist")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.10 or later is needed, for vim.system and for extmarks that know when their line was deleted")
  end

  if vim.fn.executable("curl") == 1 then
    local version = vim.fn.system({ "curl", "--version" }):match("^curl (%d+%.%d+%.?%d*)")
    if version and vim.version.lt(version, "7.84.0") then
      health.warn(("curl %s: a rate limit's Retry-After needs curl 7.84 or later to be read, so it is retried on a fixed backoff instead")
        :format(version))
    else
      health.ok("curl " .. (version or "(version unknown)"))
    end
  else
    health.error("curl is not on your PATH, and yadoist talks to Todoist through it")
  end

  local token, err = require("yadoist.config").token()
  if token then
    health.ok("a Todoist API token is set")
  else
    health.error(err, { "Create one at Todoist → Settings → Integrations → Developer, then export TODOIST_API_TOKEN" })
  end
end

return M
