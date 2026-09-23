-- Todoist unified API v1 client. Everything is async; callbacks run on the main
-- loop, so they can touch buffers directly.
local config = require("yadoist.config")

local M = {}

local BASE = "https://api.todoist.com/api/v1"

--- curl's config format takes backslash escapes inside double-quoted values.
local function esc(s)
  return (tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"'))
end

--- Build a curl config file. We hand this to curl on stdin rather than passing
--- arguments, so the API token never appears in the process list.
local function build_config(method, url, body, token)
  local lines = {
    "silent",
    "show-error",
    "location",
    ("max-time = %d"):format(math.max(1, math.floor(config.options.timeout / 1000))),
    ('request = "%s"'):format(esc(method)),
    ('url = "%s"'):format(esc(url)),
    ('header = "Authorization: Bearer %s"'):format(esc(token)),
    'write-out = "\\n%{http_code}"',
  }
  if body ~= nil then
    table.insert(lines, 'header = "Content-Type: application/json"')
    table.insert(lines, ('data-binary = "%s"'):format(esc(vim.json.encode(body))))
  end
  return table.concat(lines, "\n") .. "\n"
end

--- Split curl's output into the response body and the trailing status code.
local function split_status(out)
  out = out or ""
  local nl = out:find("\n[^\n]*$")
  if not nl then
    return "", tonumber(out)
  end
  return out:sub(1, nl - 1), tonumber(out:sub(nl + 1))
end

---@param cb fun(result: any|nil, err: string|nil)
local function request(method, path, body, cb)
  local token, err = config.token()
  if not token then
    return vim.schedule(function()
      cb(nil, err)
    end)
  end

  local cfg = build_config(method, BASE .. path, body, token)

  vim.system({ "curl", "--config", "-" }, { text = true, stdin = cfg }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        return cb(nil, ("curl failed (exit %d): %s"):format(res.code, vim.trim(res.stderr or "")))
      end

      local payload, status = split_status(res.stdout)
      if not status then
        return cb(nil, "could not read an HTTP status from curl")
      end
      if status < 200 or status >= 300 then
        local detail = vim.trim(payload)
        if #detail > 300 then
          detail = detail:sub(1, 300) .. "..."
        end
        return cb(nil, ("HTTP %d on %s %s%s"):format(status, method, path,
          detail ~= "" and (": " .. detail) or ""))
      end
      if vim.trim(payload) == "" then
        return cb(true)
      end

      local ok, decoded = pcall(vim.json.decode, payload, {
        luanil = { object = true, array = true },
      })
      if not ok then
        return cb(nil, "could not decode the response: " .. tostring(decoded))
      end
      cb(decoded)
    end)
  end)
end

--- Follow v1's cursor pagination to the end and hand back one flat list.
local function get_all(path, cb)
  local items = {}
  local function page(cursor)
    local url = path .. (path:find("%?") and "&" or "?") .. "limit=200"
    if cursor then
      url = url .. "&cursor=" .. vim.uri_encode(cursor)
    end
    request("GET", url, nil, function(res, err)
      if err then
        return cb(nil, err)
      end
      -- v1 wraps lists in { results, next_cursor }; tolerate a bare array too.
      local batch, next_cursor = res, nil
      if type(res) == "table" and res.results ~= nil then
        batch, next_cursor = res.results, res.next_cursor
      end
      for _, item in ipairs(batch or {}) do
        table.insert(items, item)
      end
      if type(next_cursor) == "string" and next_cursor ~= "" then
        page(next_cursor)
      else
        cb(items)
      end
    end)
  end
  page(nil)
end

--- Fetch projects, sections, labels and active tasks together.
---@param cb fun(data: table|nil, err: string|nil)
function M.fetch(cb)
  local out, pending, failed = {}, 4, false
  local function collect(key)
    return function(items, err)
      if failed then
        return
      end
      if err then
        failed = true
        return cb(nil, err)
      end
      out[key] = items
      pending = pending - 1
      if pending == 0 then
        cb(out)
      end
    end
  end
  get_all("/projects", collect("projects"))
  get_all("/sections", collect("sections"))
  get_all("/tasks", collect("tasks"))
  get_all("/labels", collect("labels"))
end

--- Send a list of Sync API commands in one request.
---@param cb fun(result: table|nil, err: string|nil)
function M.sync(commands, cb)
  request("POST", "/sync", { commands = commands }, cb)
end

-- Exposed for the tests.
M._request = request
M._build_config = build_config
M._split_status = split_status

return M
