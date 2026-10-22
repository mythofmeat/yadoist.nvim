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
    -- The status, then how long a 429 asks us to wait. curl before 7.84 does
    -- not know %header{} and prints it as it is, which reads as no wait.
    'write-out = "\\n%{http_code} %header{retry-after}"',
  }
  if body ~= nil then
    table.insert(lines, 'header = "Content-Type: application/json"')
    table.insert(lines, ('data-binary = "%s"'):format(esc(vim.json.encode(body))))
  end
  return table.concat(lines, "\n") .. "\n"
end

--- Split curl's output into the response body, the status code, and the
--- Retry-After seconds if there were any.
local function split_status(out)
  out = out or ""
  local nl = out:find("\n[^\n]*$")
  local body, last = "", out
  if nl then
    body, last = out:sub(1, nl - 1), out:sub(nl + 1)
  end
  local status, after = last:match("^(%d+)%s*(.-)%s*$")
  return body, tonumber(status), tonumber(after)
end

-- curl exit codes worth trying again after: no connection, or no answer in
-- time. Anything else (a bad URL, a certificate problem) will not pass.
local TRANSIENT = { [5] = true, [6] = true, [7] = true, [28] = true, [35] = true, [52] = true, [55] = true, [56] = true }

local function finish(method, path, res, cb)
  if res.code ~= 0 then
    return cb(nil, ("curl failed (exit %d): %s"):format(res.code, vim.trim(res.stderr or "")),
      { retry = TRANSIENT[res.code] == true })
  end

  local payload, status, after = split_status(res.stdout)
  if not status then
    return cb(nil, "could not read an HTTP status from curl", {})
  end
  local decoded, ok = nil, false
  if vim.trim(payload) ~= "" then
    ok, decoded = pcall(vim.json.decode, payload, { luanil = { object = true, array = true } })
  end

  if status < 200 or status >= 300 then
    local detail = vim.trim(payload)
    if #detail > 300 then
      detail = detail:sub(1, 300) .. "..."
    end
    if not after and ok and type(decoded) == "table" and type(decoded.error_extra) == "table" then
      after = tonumber(decoded.error_extra.retry_after)
    end
    return cb(nil, ("HTTP %d on %s %s%s"):format(status, method, path, detail ~= "" and (": " .. detail) or ""), {
      status = status,
      retry = status == 429 or status >= 500,
      retry_after = after,
    })
  end
  if vim.trim(payload) == "" then
    return cb(true, nil, { status = status })
  end
  if not ok then
    return cb(nil, "could not decode the response: " .. tostring(decoded), { status = status })
  end
  cb(decoded, nil, { status = status })
end

--- One HTTP request to Todoist. The tests replace this with a fake Todoist.
---@param cb fun(result: any|nil, err: string|nil, info: table)
---  info.status is the HTTP status, if one came back; info.retry says whether
---  trying again could succeed, and info.retry_after how long Todoist asked
---  for, in seconds.
function M.request(method, path, body, cb)
  local token, err = config.token()
  if not token then
    return vim.schedule(function()
      cb(nil, err, {})
    end)
  end

  local cfg = build_config(method, BASE .. path, body, token)
  local ok, spawn_err = pcall(vim.system, { "curl", "--config", "-" }, { text = true, stdin = cfg }, function(res)
    vim.schedule(function()
      finish(method, path, res, cb)
    end)
  end)
  if not ok then
    -- vim.system throws, rather than calling back, when curl cannot be run at
    -- all: not installed, say. The caller still has to hear about it.
    vim.schedule(function()
      cb(nil, "could not run curl: " .. tostring(spawn_err), {})
    end)
  end
end

--- How many more times a request is tried when it failed in a way that may
--- pass, how long to wait before each, in ms, and the longest Retry-After
--- worth waiting out, in seconds. The tests shorten these.
M.retries = 2
M.backoff = function(attempt)
  return 1000 * 2 ^ (attempt - 1)
end
M.max_wait = 10

--- A request, tried again after a pause when it failed in a way that may
--- pass: no connection, a timeout, a 5xx, or a 429 asking for a short wait.
--- Anything else, a 400 or a 401, is final at once. Resending Sync commands
--- is harmless, because Todoist applies each uuid at most once.
function M.call(method, path, body, cb)
  local attempt = 0
  local function try()
    attempt = attempt + 1
    M.request(method, path, body, function(res, err, info)
      info = info or {}
      if not err or not info.retry or attempt > M.retries then
        return cb(res, err, info)
      end
      local wait = M.backoff(attempt)
      if info.retry_after then
        if info.retry_after > M.max_wait then
          return cb(nil, ("%s — Todoist asks to wait %ds before trying again"):format(err, info.retry_after), info)
        end
        wait = math.max(wait, info.retry_after * 1000)
      end
      vim.defer_fn(try, wait)
    end)
  end
  try()
end

--- Follow v1's cursor pagination to the end and hand back one flat list. A
--- page comes as { [key] = items, next_cursor }.
local function get_all(path, key, cb)
  local items = {}
  local function page(cursor)
    local url = path .. (path:find("%?") and "&" or "?") .. "limit=200"
    if cursor then
      url = url .. "&cursor=" .. vim.uri_encode(cursor)
    end
    M.call("GET", url, nil, function(res, err)
      if err then
        return cb(nil, err)
      end
      local batch, next_cursor = res, nil
      if type(res) == "table" and res[key] ~= nil then
        batch, next_cursor = res[key], res.next_cursor
      end
      for _, item in ipairs(type(batch) == "table" and batch or {}) do
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

--- One Sync API request: commands to apply, and resources to read, in any
--- mix. See store.lua.
---@param cb fun(result: table|nil, err: string|nil, info: table)
function M.sync(body, cb)
  M.call("POST", "/sync", body, cb)
end

-- Exposed for the tests.
M._get_all = get_all
M._build_config = build_config
M._split_status = split_status
M._finish = finish

return M
