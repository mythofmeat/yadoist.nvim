-- An in-memory Todoist behind yadoist.api.request, for the lifecycle tests.
--
-- It applies Sync commands, answers reads incrementally from a sync token the
-- way the real one does, applies each command uuid at most once, and can be
-- told to fail, stall or lose a reply.
local M = {}

local KINDS = { "items", "projects", "sections", "labels" }

local function strip(x)
  local out = vim.deepcopy(x)
  out._v = nil
  return out
end

--- A due object from what a command sends: { string } is parsed as far as a
--- fake can (a date, a date and time, or "every ..."), { date } kept as is.
local function due_from(due)
  if due == nil or due == vim.NIL then
    return nil
  end
  if due.date then
    return { date = due.date, timezone = due.timezone, string = due.date }
  end
  local s = due.string or ""
  local day, time = s:match("^(%d%d%d%d%-%d%d%-%d%d)[ T]?(%d?%d?:?%d?%d?)")
  if s:match("^every") then
    return { string = s, date = "2099-01-01", is_recurring = true }
  elseif day and time ~= "" then
    return { string = s, date = day .. "T" .. time .. ":00" }
  elseif day then
    return { string = s, date = day }
  end
  return { string = s }
end

---@param seed table { projects, sections, tasks, labels }
function M.new(seed)
  local server = {
    version = 0,
    data = { items = {}, projects = {}, sections = {}, labels = {} },
    log = {}, -- every request: { method, path, body }
    applied = {}, -- every command applied, in order
    failures = {}, -- for the next requests, in turn: { transport }, { status, retry_after }, { lost }
    delay = 0, -- ms before each reply
    holding = false, -- keep replies back until release()
    held = {},
    reject = nil, -- fun(command): an error message to fail that command with
    filters = {}, -- query -> fun(item): boolean
    uuids = {},
    temps = {},
    ids = 0,
  }

  local function touch(kind, x)
    server.version = server.version + 1
    x._v = server.version
    server.data[kind][x.id] = x
  end

  for _, kind in ipairs(KINDS) do
    for _, x in ipairs(seed[kind == "items" and "tasks" or kind] or {}) do
      touch(kind, vim.deepcopy(x))
    end
  end

  local items = server.data.items
  local function resolve(id)
    return server.temps[id] or id
  end
  local function inbox()
    for id, p in pairs(server.data.projects) do
      if p.inbox_project then
        return id
      end
    end
  end
  local function descendants(id, out)
    out = out or {}
    for _, item in pairs(items) do
      if item.parent_id == id and not item.is_deleted then
        table.insert(out, item)
        descendants(item.id, out)
      end
    end
    return out
  end
  local function last_order(item)
    local n = 0
    for _, other in pairs(items) do
      if other ~= item and not other.is_deleted and other.parent_id == item.parent_id
        and other.project_id == item.project_id and other.section_id == item.section_id then
        n = math.max(n, tonumber(other.child_order) or 0)
      end
    end
    return n + 1
  end

  local commands = {}
  function commands.item_add(a, cmd, mapping)
    server.ids = server.ids + 1
    local item = {
      id = "new" .. server.ids,
      content = a.content,
      description = a.description or "",
      project_id = a.project_id or inbox(),
      section_id = a.section_id,
      parent_id = a.parent_id and resolve(a.parent_id),
      priority = a.priority or 1,
      labels = a.labels or {},
      due = due_from(a.due),
      checked = false,
    }
    if item.parent_id then
      local parent = items[item.parent_id]
      if not parent then
        return "parent not found"
      end
      item.project_id, item.section_id = parent.project_id, parent.section_id
    end
    item.child_order = last_order(item)
    touch("items", item)
    if cmd.temp_id then
      mapping[cmd.temp_id] = item.id
      server.temps[cmd.temp_id] = item.id
    end
  end
  function commands.item_update(a)
    local item = items[resolve(a.id)]
    if not item then
      return "item not found"
    end
    for _, key in ipairs({ "content", "description", "priority", "labels" }) do
      if a[key] ~= nil then
        item[key] = a[key]
      end
    end
    if a.due ~= nil then
      item.due = due_from(a.due)
    end
    touch("items", item)
  end
  function commands.item_move(a)
    local item = items[resolve(a.id)]
    if not item then
      return "item not found"
    end
    if a.parent_id then
      local parent = items[resolve(a.parent_id)]
      item.parent_id, item.project_id, item.section_id = parent.id, parent.project_id, parent.section_id
    elseif a.section_id then
      item.parent_id, item.section_id = nil, a.section_id
      item.project_id = server.data.sections[a.section_id].project_id
    else
      item.parent_id, item.section_id, item.project_id = nil, nil, a.project_id
    end
    item.child_order = last_order(item)
    touch("items", item)
    for _, kid in ipairs(descendants(item.id)) do
      kid.project_id, kid.section_id = item.project_id, item.section_id
      touch("items", kid)
    end
  end
  function commands.item_close(a)
    local item = items[resolve(a.id)]
    if not item then
      return "item not found"
    end
    for _, x in ipairs(vim.list_extend({ item }, descendants(item.id))) do
      x.checked, x.completed_at = true, "2026-10-22T00:00:00Z"
      touch("items", x)
    end
  end
  function commands.item_uncomplete(a)
    local item = items[resolve(a.id)]
    item.checked, item.completed_at = false, nil
    touch("items", item)
  end
  function commands.item_delete(a)
    local item = items[resolve(a.id)]
    if not item then
      return "item not found"
    end
    for _, x in ipairs(vim.list_extend({ item }, descendants(item.id))) do
      x.is_deleted = true
      touch("items", x)
    end
  end
  function commands.item_reorder(a)
    for _, entry in ipairs(a.items) do
      local item = items[resolve(entry.id)]
      item.child_order = entry.child_order
      touch("items", item)
    end
  end
  function commands.item_update_day_orders(a)
    for id, order in pairs(a.ids_to_orders) do
      local item = items[resolve(id)]
      item.day_order = order
      touch("items", item)
    end
  end
  function commands.project_update(a)
    local project = server.data.projects[a.id]
    project.name = a.name
    touch("projects", project)
  end
  function commands.section_update(a)
    local section = server.data.sections[a.id]
    section.name = a.name
    touch("sections", section)
  end

  local function sync(body)
    local status, mapping = {}, {}
    for _, cmd in ipairs(body.commands or {}) do
      if server.uuids[cmd.uuid] ~= nil then
        status[cmd.uuid] = server.uuids[cmd.uuid]
        if cmd.temp_id and server.temps[cmd.temp_id] then
          mapping[cmd.temp_id] = server.temps[cmd.temp_id]
        end
      else
        local err = server.reject and server.reject(cmd) or nil
        if not err then
          local apply = commands[cmd.type]
          err = apply and apply(cmd.args, cmd, mapping) or (not apply and ("unknown command " .. cmd.type)) or nil
        end
        status[cmd.uuid] = err and { error = err } or "ok"
        server.uuids[cmd.uuid] = status[cmd.uuid]
        if not err then
          table.insert(server.applied, cmd.type)
        end
      end
    end

    local version = tostring(body.sync_token):match("^v(%d+)$")
    local since = version and tonumber(version)
    local reply = { sync_token = "v" .. server.version, full_sync = since == nil, sync_status = status, temp_id_mapping = mapping }
    for _, kind in ipairs(KINDS) do
      reply[kind] = {}
      for _, x in pairs(server.data[kind]) do
        local live = not x.is_deleted and not (kind == "items" and x.checked)
        if (since == nil and live) or (since ~= nil and x._v > since) then
          table.insert(reply[kind], strip(x))
        end
      end
    end
    return reply
  end

  local function rest(method, path, body)
    local query = path:match("^/tasks/filter%?query=([^&]*)")
    if query then
      local match = server.filters[vim.uri_decode(query)]
      if not match then
        error("400 Invalid filter")
      end
      local out = {}
      for _, item in pairs(items) do
        if not item.is_deleted and not item.checked and match(item) then
          table.insert(out, strip(item))
        end
      end
      return { results = out, next_cursor = vim.NIL }
    end
    if path:match("^/tasks/completed/by_completion_date") then
      local out = {}
      for _, item in pairs(items) do
        if item.checked and not item.is_deleted then
          table.insert(out, strip(item))
        end
      end
      return { items = out, next_cursor = vim.NIL }
    end
    if method == "POST" and path == "/tasks/quick" then
      local mapping = {}
      commands.item_add({ content = body.text }, {}, mapping)
      local id = "new" .. server.ids
      table.insert(server.applied, "quick_add")
      return strip(items[id])
    end
    error("404 no fake for " .. method .. " " .. path)
  end

  local function deliver(reply)
    if server.holding then
      table.insert(server.held, reply)
    elseif server.delay > 0 then
      vim.defer_fn(reply, server.delay)
    else
      vim.schedule(reply)
    end
  end

  function server.request(method, path, body, cb)
    table.insert(server.log, { method = method, path = path, body = vim.deepcopy(body) })
    local failure = table.remove(server.failures, 1) or {}
    if failure.transport then
      return deliver(function() cb(nil, "curl failed (exit 28): timed out", { retry = true }) end)
    end
    if failure.status then
      return deliver(function()
        cb(nil, ("HTTP %d on %s %s"):format(failure.status, method, path), {
          status = failure.status,
          retry = failure.status == 429 or failure.status >= 500,
          retry_after = failure.retry_after,
        })
      end)
    end
    local ok, res = pcall(path == "/sync" and sync or rest, path == "/sync" and body or method, path, body)
    if failure.lost then
      -- It landed, but the reply never arrived.
      return deliver(function() cb(nil, "curl failed (exit 56): connection reset", { retry = true }) end)
    end
    if not ok then
      local status = tonumber(tostring(res):match("(%d%d%d)")) or 500
      return deliver(function() cb(nil, "HTTP " .. tostring(res), { status = status }) end)
    end
    deliver(function() cb(vim.deepcopy(res), nil, { status = 200 }) end)
  end

  function server.release()
    local held = server.held
    server.held = {}
    for _, reply in ipairs(held) do
      vim.schedule(reply)
    end
  end

  --- Change something the way another device would.
  function server.edit(kind, id, fields)
    local x = server.data[kind][id]
    for k, v in pairs(fields) do
      x[k] = v
    end
    touch(kind, x)
  end

  --- The command types applied since the last call.
  function server.take()
    local out = server.applied
    server.applied = {}
    return out
  end

  return server
end

--- A fake Todoist answering every request yadoist makes.
function M.install(api, seed)
  local server = M.new(seed)
  api.request = function(...)
    return server.request(...)
  end
  return server
end

return M
