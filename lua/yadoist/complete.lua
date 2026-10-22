-- Insert-mode completion for the names a typo would otherwise turn into an
-- error on :w: labels after @, and projects and sections in headings. It is
-- the task buffer's 'omnifunc', so <C-x><C-o> offers them, as does any
-- completion plugin with an omni source.
local model = require("yadoist.model")
local parse = require("yadoist.parse")

local M = {}

local function data_for(bufnr)
  local st = require("yadoist.buffer")._state[bufnr]
  if st and st.data then
    return st.data
  end
  return require("yadoist.store").snapshot()
end

local function live(x)
  return x.is_deleted ~= true and x.is_archived ~= true
end

--- Every label that exists: your own, and any on a task, which may be a
--- shared project's.
local function labels(data)
  local seen, out = {}, {}
  local function add(name)
    if name ~= "" and not seen[name] then
      seen[name] = true
      table.insert(out, name)
    end
  end
  for _, label in ipairs(data.labels or {}) do
    if label.is_deleted ~= true then
      add(model.one_line(label.name))
    end
  end
  for _, task in ipairs(data.tasks or {}) do
    for _, l in ipairs(model.labels(task)) do
      add(l)
    end
  end
  table.sort(out, function(a, b)
    return a:lower() < b:lower()
  end)
  return out
end

--- The name in the nearest project heading above line `lnum`.
local function project_above(bufnr, lnum)
  for l = lnum - 1, 1, -1 do
    local name = vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1]:match("^#%s+(.-)%s*$")
    if name then
      return name
    end
  end
end

function M.omnifunc(findstart, base)
  local line = vim.api.nvim_get_current_line()
  local cursor = vim.api.nvim_win_get_cursor(0)
  if findstart == 1 then
    local before = line:sub(1, cursor[2])
    local hashes, gap = before:match("^(#+)(%s+)")
    if hashes and #hashes <= 2 then
      return #hashes + #gap
    end
    local at = before:match(".*()@{[^}]*$") or before:match(".*()@[^%s@{]*$")
    if at then
      return at - 1
    end
    return -3
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local data = data_for(bufnr)
  local items = {}
  local function offer(name, word, menu, typed)
    if name:lower():find(typed:lower(), 1, true) == 1 then
      table.insert(items, { word = word, abbr = name, menu = menu })
    end
  end

  if base:sub(1, 1) == "@" then
    local typed = base:gsub("^@{?", "")
    for _, name in ipairs(labels(data)) do
      offer(name, parse.label_token(name), "[label]", typed)
    end
  elseif line:match("^##%s") then
    local project, ids = project_above(bufnr, cursor[1]), {}
    for _, p in ipairs(data.projects or {}) do
      if live(p) and model.one_line(p.name) == project then
        ids[p.id] = true
      end
    end
    for _, s in ipairs(data.sections or {}) do
      if live(s) and ids[s.project_id] then
        local name = model.one_line(s.name)
        offer(name, name, "[section]", base)
      end
    end
  elseif line:match("^#%s") then
    for _, p in ipairs(data.projects or {}) do
      if live(p) then
        local name = model.one_line(p.name)
        offer(name, name, "[project]", base)
      end
    end
  end
  return items
end

return M
