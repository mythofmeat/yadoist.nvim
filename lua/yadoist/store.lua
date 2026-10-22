-- The Todoist data every task buffer draws from, kept up to date through the
-- Sync API.
--
-- The first read asks for everything, and each one after it only for what has
-- changed since, so refreshing whenever a buffer is looked at costs next to
-- nothing. A write goes in the same request as a read, so its reply brings the
-- write's own results back with it: there is no gap between a write landing
-- and the data showing it, for a failure to fall into.
local api = require("yadoist.api")
local config = require("yadoist.config")

local M = {}

-- Collaborators and the user are for showing who a task is assigned to.
M.RESOURCES = { "items", "projects", "sections", "labels", "collaborators", "user" }

-- Each Sync resource that is a list, and the name the rest of yadoist knows
-- it by.
local KINDS = {
  items = "tasks", projects = "projects", sections = "sections", labels = "labels", collaborators = "collaborators",
}

local cache

--- Forget everything, so the next request reads it all afresh.
function M.reset()
  cache = { token = "*", sent = 0, merged = 0 }
  for _, kind in pairs(KINDS) do
    cache[kind] = {}
  end
end
M.reset()

--- A completed task drops out, the way the first read would never have
--- returned it, and so does anything deleted.
local function gone(kind, x)
  return x.is_deleted == true or (kind == "tasks" and (x.checked == true or x.completed_at ~= nil))
end

local function merge(res, seq)
  -- A reply to an earlier request that arrives after a later one's has nothing
  -- the later one did not, and may have older versions of things.
  if seq <= cache.merged then
    return
  end
  cache.merged = seq
  if res.full_sync == true then
    for _, kind in pairs(KINDS) do
      cache[kind] = {}
    end
  end
  for resource, kind in pairs(KINDS) do
    for _, x in ipairs(type(res[resource]) == "table" and res[resource] or {}) do
      if x.id ~= nil then
        if gone(kind, x) then
          cache[kind][x.id] = nil
        else
          cache[kind][x.id] = x
        end
      end
    end
  end
  if type(res.user) == "table" then
    cache.user = res.user
  end
  if type(res.sync_token) == "string" then
    cache.token = res.sync_token
  end
end

--- Send commands, or none for a plain read, along with a read of everything
--- that changed since the last one.
---@param commands table[]|nil
---@param cb fun(res: table|nil, err: string|nil, info: table|nil)
function M.sync(commands, cb)
  -- Another token is another account, whose data this is not.
  local account = config.token()
  if account ~= cache.account then
    M.reset()
    cache.account = account
  end
  cache.sent = cache.sent + 1
  local seq = cache.sent
  api.sync({ sync_token = cache.token, resource_types = M.RESOURCES, commands = commands }, function(res, err, info)
    if err then
      return cb(nil, err, info)
    end
    if type(res) ~= "table" then
      return cb(nil, "Todoist's reply was not a sync response", info)
    end
    merge(res, seq)
    cb(res, nil, info)
  end)
end

--- Everything fetched so far, as lists the renderer can draw from.
function M.snapshot()
  local out = {}
  for _, kind in pairs(KINDS) do
    local list = vim.tbl_values(cache[kind])
    table.sort(list, function(a, b)
      return tostring(a.id) < tostring(b.id)
    end)
    out[kind] = list
  end
  out.user = cache.user
  return out
end

--- Bring everything up to date, then hand it back.
---@param cb fun(data: table|nil, err: string|nil)
function M.read(cb)
  M.sync(nil, function(_, err)
    if err then
      return cb(nil, err)
    end
    cb(M.snapshot())
  end)
end

--- Whether anything has been read yet.
function M.loaded()
  return cache.merged > 0
end

return M
