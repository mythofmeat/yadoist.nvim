-- Buffer lifecycle tests: windows, folding, and the buffer the way a user meets
-- it. From the repo root:
--   nvim --headless -u NONE -i NONE -l tests/lifecycle.lua
vim.opt.rtp:prepend(".")
package.path = "./lua/?.lua;./lua/?/init.lua;./tests/?.lua;" .. package.path
vim.cmd("filetype plugin on | runtime plugin/yadoist.lua")

local api = require("yadoist.api")
local buffer = require("yadoist.buffer")
local store = require("yadoist.store")
local fake = require("fake_todoist")

-- The real request, kept for the test that needs it to fail before it
-- reaches the network; everything else talks to a fake Todoist.
local http = api.request
api.backoff = function()
  return 1
end

local notes, answer = {}, 2
vim.notify = function(msg)
  table.insert(notes, msg)
end
vim.fn.confirm = function()
  return answer
end
require("yadoist").setup({ token = "test-token", refresh_on_focus = true })

local function seed()
  local function t(id, content, o)
    return vim.tbl_extend("force", { id = id, content = content, project_id = "p1", labels = {}, priority = 1, child_order = 1 }, o or {})
  end
  return {
    projects = { { id = "p1", name = "Inbox", inbox_project = true, child_order = 0 }, { id = "p2", name = "Work", child_order = 1 } },
    sections = {},
    labels = {},
    tasks = { t("a", "Alpha", { child_order = 1 }), t("b", "Bravo", { child_order = 2 }) },
  }
end

local server

local function settled(b)
  return vim.wait(2000, function()
    local st = buffer._state[b]
    return st ~= nil and st.data ~= nil and not st.busy
  end, 5)
end

--- A fresh fake Todoist, and a view of it opened the way :Yadoist does.
local function fresh(view, data)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):find("^yadoist://") then
      vim.api.nvim_buf_delete(b, { force = true })
    end
  end
  vim.cmd("silent! only")
  store.reset()
  server = fake.install(api, data or seed())
  answer = 2
  local b = buffer.open(view or "all")
  settled(b)
  notes = {}
  server.take()
  return b
end

local function lines(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

-- Straight to stdout: print() goes through Neovim's message area, which
-- after a redraw or keys fed in can run one line into the next.
local function print(text)
  io.stdout:write(tostring(text), "\n")
end

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
  vim.cmd("silent! only")
end

print("\nopening")
do
  local b = fresh()
  check("opens with the tasks drawn", vim.deep_equal(lines(b), { "# Inbox", "", "- [ ] Alpha", "- [ ] Bravo", "", "# Work" }),
    vim.inspect(lines(b)))
  check("after :Yadoist the window folds with the plugin's foldexpr", vim.wo.foldmethod == "expr",
    "foldmethod=" .. vim.wo.foldmethod)
  check("one request read everything", #server.log == 1 and server.log[1].path == "/sync"
    and server.log[1].body.sync_token == "*", vim.inspect(server.log))

  vim.api.nvim_feedkeys("q", "x", false) -- the plugin's close mapping (:bdelete)
  b = buffer.open("all")
  settled(b)
  local maps = vim.tbl_map(function(m) return m.lhs end, vim.api.nvim_buf_get_keymap(b, "n"))
  check("q then :Yadoist gives a working buffer", vim.bo[b].filetype == "yadoist" and vim.bo[b].buftype == "acwrite"
    and vim.tbl_contains(maps, "gr") and vim.tbl_contains(lines(b), "- [ ] Alpha"),
    ("filetype=%q buftype=%q maps=%s"):format(vim.bo[b].filetype, vim.bo[b].buftype, vim.inspect(maps)))
  check("and asks only for what changed", server.log[#server.log].body.sync_token ~= "*")

  server.edit("items", "a", { content = "Alpha, renamed elsewhere" })
  vim.cmd("edit")
  settled(b)
  check(":e fetches again", vim.tbl_contains(lines(b), "- [ ] Alpha, renamed elsewhere"), vim.inspect(lines(b)))
  vim.api.nvim_buf_set_lines(b, 2, 2, false, { "- [ ] unsaved" })
  check(":e refuses while there are unsaved edits", not pcall(vim.cmd, "edit"))
  vim.cmd("edit!")
  settled(b)
  check(":e! throws them away and fetches again", not vim.tbl_contains(lines(b), "- [ ] unsaved") and not vim.bo[b].modified,
    vim.inspect(lines(b)))

  vim.api.nvim_buf_set_lines(b, 2, 2, false, { "- [ ] unsaved" })
  answer = 2 -- Cancel
  vim.api.nvim_feedkeys("gr", "x", false)
  settled(b)
  check("gr with unsaved edits asks first, and Cancel keeps them", vim.tbl_contains(lines(b), "- [ ] unsaved"))
  answer = 1 -- Reload
  vim.api.nvim_feedkeys("gr", "x", false)
  settled(b)
  check("and Reload throws them away", not vim.tbl_contains(lines(b), "- [ ] unsaved"), vim.inspect(lines(b)))
end

print("\nediting while Todoist is busy")
do
  -- 2a. A background refresh must not wipe what was typed while it was out.
  local b = fresh()
  server.holding = true
  vim.api.nvim_exec_autocmds("FocusGained", { buffer = b })
  vim.api.nvim_buf_set_lines(b, 4, 4, false, { "- [ ] typed during the fetch" })
  server.holding = false
  server.release()
  settled(b)
  check("typing during a background refresh survives it", vim.tbl_contains(lines(b), "- [ ] typed during the fetch"))
  check("and is still unsaved", vim.bo[b].modified)

  -- A refresh in flight when :w comes is waited for rather than refused.
  b = fresh()
  server.delay = 30
  vim.api.nvim_exec_autocmds("FocusGained", { buffer = b })
  vim.api.nvim_buf_set_lines(b, 4, 4, false, { "- [ ] Charlie" })
  vim.cmd("write")
  server.delay = 0
  check(":w during a refresh waits for it, then writes", vim.deep_equal(server.take(), { "item_add" }) and not vim.bo[b].modified,
    vim.inspect(notes))

  -- 2b. A write that lands is never sent again, however what follows goes.
  b = fresh()
  vim.api.nvim_buf_set_lines(b, 4, 4, false, { "- [ ] Charlie" })
  server.failures = { { lost = true } } -- it lands, but the reply is lost
  vim.cmd("write")
  check("a write whose reply was lost is resent, and lands once", vim.deep_equal(server.take(), { "item_add" }),
    vim.inspect(server.log[#server.log]))
  for _ = 1, 10 do
    table.insert(server.failures, { transport = true })
  end
  vim.cmd("write")
  vim.cmd("write")
  check("and a later :w does not create it again", #server.take() == 0 and not vim.bo[b].modified)
  server.failures = {}

  -- Lost so often that the write gives up: it may have landed or not.
  b = fresh()
  vim.api.nvim_buf_set_lines(b, 4, 4, false, { "- [ ] Delta" })
  server.failures = { { lost = true }, { transport = true }, { transport = true } }
  vim.cmd("write")
  check("a write that never hears back stays unsaved", vim.bo[b].modified and vim.deep_equal(server.take(), { "item_add" }))
  vim.cmd("write")
  local adds = 0
  for _, item in pairs(server.data.items) do
    adds = adds + ((item.content == "Delta" and not item.is_deleted) and 1 or 0)
  end
  check("and writing it again does not create it twice", adds == 1 and not vim.bo[b].modified, adds)

  -- 2c. Undo must not walk back past the content that was loaded.
  b = fresh()
  vim.cmd("silent! normal! uuu")
  check("undo cannot empty the buffer", vim.tbl_contains(lines(b), "- [ ] Alpha"), vim.inspect(lines(b)))
  vim.api.nvim_buf_set_text(b, 2, 6, 2, 11, { "Alpha!" })
  vim.cmd("write")
  vim.cmd("silent! normal! uu")
  check("nor back past a write", vim.tbl_contains(lines(b), "- [ ] Alpha!") and not vim.bo[b].modified, vim.inspect(lines(b)))

  -- 2d. :wq needs the write to be finished when BufWriteCmd returns.
  b = fresh()
  vim.api.nvim_buf_set_text(b, 2, 6, 2, 11, { "Alpha!" })
  server.delay = 50
  vim.cmd("write")
  server.delay = 0
  check("the buffer is saved once :w returns", not vim.bo[b].modified)
  vim.cmd("split")
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_text(b, 2, 6, 2, 12, { "Alpha?" })
  local before = #vim.api.nvim_tabpage_list_wins(0)
  server.delay = 50
  vim.cmd("wq")
  server.delay = 0
  check(":wq closes the window once the write lands", #vim.api.nvim_tabpage_list_wins(0) == before - 1)

  -- A write Todoist takes too long to answer goes on in the background, and
  -- the buffer stays read-only until it is answered.
  b = fresh()
  local patience = buffer.patience
  buffer.patience = function() return 30 end
  server.holding = true
  vim.api.nvim_buf_set_text(b, 2, 6, 2, 11, { "Alpha!" })
  vim.cmd("write")
  check("a write still out leaves the buffer read-only", not vim.bo[b].modifiable)
  server.holding = false
  server.release()
  vim.wait(1000, function() return vim.bo[b].modifiable end)
  check("until Todoist answers", vim.bo[b].modifiable and not vim.bo[b].modified)
  buffer.patience = patience
end

print("\nwhen a write partly fails")
do
  local b = fresh()
  server.reject = function(cmd)
    return cmd.type == "item_add" and cmd.args.content == "Bad" and "Invalid argument value" or nil
  end
  vim.api.nvim_buf_set_lines(b, 4, 4, false, { "- [ ] Good", "- [ ] Bad" })
  vim.api.nvim_buf_set_text(b, 2, 6, 2, 11, { "Alpha!" })
  vim.cmd("write")
  check("the buffer is left as typed", vim.deep_equal({ lines(b)[3], lines(b)[5], lines(b)[6] }, { "- [ ] Alpha!", "- [ ] Good", "- [ ] Bad" })
    and vim.bo[b].modified, vim.inspect(lines(b)))
  local diags = vim.diagnostic.get(b)
  check("with the failure on its line", #diags == 1 and diags[1].lnum == 5 and diags[1].message == "Invalid argument value",
    vim.inspect(diags))
  check("and what landed reported", (notes[#notes] or ""):find("1 added, 1 updated, but 1 failed", 1, true) ~= nil, notes[#notes])
  server.take()
  server.reject = nil
  vim.api.nvim_buf_set_text(b, 5, 6, 5, 9, { "Better" })
  vim.cmd("write")
  check("the next :w sends only what failed", vim.deep_equal(server.take(), { "item_add" }) and not vim.bo[b].modified,
    vim.inspect(server.log[#server.log].body.commands))
  check("and draws what Todoist has", vim.tbl_contains(lines(b), "- [ ] Better") and vim.tbl_contains(lines(b), "- [ ] Good"))
end

print("\nfailures")
do
  local b = fresh()
  server.failures = { { status = 503 } }
  vim.api.nvim_buf_set_text(b, 2, 6, 2, 11, { "Alpha!" })
  vim.cmd("write")
  check("a 503 is tried again, and the write lands", vim.deep_equal(server.take(), { "item_update" }) and not vim.bo[b].modified)

  server.failures = { { status = 400 } }
  vim.api.nvim_buf_set_text(b, 2, 6, 2, 12, { "Alpha?" })
  local sent = #server.log
  vim.cmd("write")
  check("a 400 is not, and the edit stays unsaved", #server.log == sent + 1 and vim.bo[b].modified, #server.log - sent)
  vim.cmd("write")
  check("until the next :w", vim.deep_equal(server.take(), { "item_update" }) and not vim.bo[b].modified)

  -- vim.system throws when curl cannot run; that must not leave the buffer
  -- busy for good, refusing every :w after.
  local fake_request, system = api.request, vim.system
  api.request, vim.system = http, function() error("ENOENT: no such file or directory (cmd): 'curl'") end
  vim.api.nvim_feedkeys("gr", "x", false)
  vim.wait(500, function() return not buffer._state[b].busy end)
  api.request, vim.system = fake_request, system
  check("a fetch that cannot start does not leave the buffer busy", not buffer._state[b].busy)
  check("and says why", (notes[#notes] or ""):find("could not run curl", 1, true) ~= nil, notes[#notes])
  vim.api.nvim_buf_set_text(b, 2, 6, 2, 12, { "Alpha." })
  vim.cmd("write")
  check("so :w works after it", vim.deep_equal(server.take(), { "item_update" }), vim.inspect(notes))
end

print("\norder")
do
  local b = fresh()
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  vim.cmd("move 2") -- Bravo above Alpha
  vim.cmd("write")
  check("a list's new order is saved", vim.deep_equal(server.take(), { "item_reorder" }))
  check("and comes back drawn that way", vim.deep_equal({ lines(b)[3], lines(b)[4] }, { "- [ ] Bravo", "- [ ] Alpha" }),
    vim.inspect(lines(b)))

  local today = require("yadoist.model").today()
  local data = seed()
  data.tasks[1].due = { date = today, string = "today" }
  data.tasks[2].due = { date = today, string = "today" }
  b = fresh("today", data)
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  vim.cmd("move 2")
  vim.cmd("write")
  check("so is a day's", vim.deep_equal(server.take(), { "item_update_day_orders" }))
  check("and it too comes back drawn that way", lines(b)[3]:find("Bravo", 1, true) ~= nil, vim.inspect(lines(b)))
end

print("\nfilter, completed and quick add")
do
  local data = seed()
  data.tasks[1].labels = { "errand" }
  local query = "@errand & !#Work"
  local b = fresh("filter " .. query, data)
  server.filters[query] = function(item)
    return vim.tbl_contains(item.labels or {}, "errand")
  end
  vim.cmd("edit") -- the filter is defined now; ask again
  settled(b)
  check("a filter view shows what Todoist's filter matched", vim.deep_equal(lines(b), { "# Inbox", "", "- [ ] Alpha @errand" }),
    vim.inspect(lines(b)))
  check("and the query reaches Todoist intact", server.log[#server.log].path:find("query=%40errand%20%26%20%21%23Work", 1, true) ~= nil,
    server.log[#server.log].path)
  vim.api.nvim_buf_set_lines(b, 3, 3, false, { "- [ ] Second errand @errand" })
  vim.cmd("write")
  settled(b)
  check("a task added there is created in the heading's project", vim.deep_equal(server.take(), { "item_add" })
    and vim.tbl_contains(lines(b), "- [ ] Second errand @errand"), vim.inspect(lines(b)))

  b = fresh("filter nonsense ((")
  vim.cmd("edit")
  settled(b)
  check("a filter Todoist rejects says so, and shows nothing", (notes[#notes] or ""):find("Invalid filter", 1, true) ~= nil
    and vim.deep_equal(lines(b), { "# (nothing in filter nonsense (()" }), vim.inspect({ notes, lines(b) }))

  data = seed()
  data.tasks[2].checked, data.tasks[2].completed_at = true, "2026-10-21T08:00:00Z"
  b = fresh("completed", data)
  check("the completed view shows what was completed", vim.deep_equal(lines(b), { "# Inbox", "", "- [x] Bravo" }), vim.inspect(lines(b)))
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  vim.cmd("write")
  settled(b)
  check("unticking one there reopens it", vim.deep_equal(server.take(), { "item_uncomplete" }) and server.data.items.b.checked == false)
  check("and it leaves the view", not vim.tbl_contains(lines(b), "- [x] Bravo") and not vim.tbl_contains(lines(b), "- [ ] Bravo"),
    vim.inspect(lines(b)))

  b = fresh()
  vim.cmd("Yadoist add Buy bread")
  vim.wait(1000, function() return vim.tbl_contains(lines(b), "- [ ] Buy bread") end)
  check(":Yadoist add adds a task through quick add", vim.deep_equal(server.take(), { "quick_add" })
    and (notes[1] or ""):find('added "Buy bread" to Inbox', 1, true) ~= nil, vim.inspect(notes))
  check("and open task buffers catch up", vim.tbl_contains(lines(b), "- [ ] Buy bread"), vim.inspect(lines(b)))
end

print("\ncompletion, colour and the text beside a line")
do
  local data = seed()
  data.tasks[1].labels = { "errand" }
  data.tasks[2].deadline = { date = "2099-02-01" }
  data.labels = { { id = "l1", name = "waiting for" } }
  data.sections = { { id = "s1", project_id = "p2", name = "Meetings", section_order = 1 } }
  local b = fresh("all", data)
  local complete = require("yadoist.complete")
  -- Completion happens in Insert mode, with the cursor after what was typed;
  -- this lets the cursor sit there in Normal mode too.
  vim.o.virtualedit = "onemore"
  local function at_end(text)
    vim.api.nvim_buf_set_lines(b, -1, -1, false, { text })
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(b), #text })
    local start = complete.omnifunc(1, "")
    if start < 0 then
      return start, {}
    end
    return start, vim.tbl_map(function(i) return i.word end, complete.omnifunc(0, text:sub(start + 1)))
  end
  local start, words = at_end("## M") -- the last heading is # Work
  check("section names complete under their project's heading", start == 3 and vim.deep_equal(words, { "Meetings" }),
    vim.inspect({ start, words }))
  start, words = at_end("- [ ] Ask @wa")
  check("labels complete after @, braced when they need to be", start == 10 and vim.deep_equal(words, { "@{waiting for}" }),
    vim.inspect({ start, words }))
  _, words = at_end("- [ ] Ask @")
  check("every label is offered after a bare @", vim.deep_equal(words, { "@errand", "@{waiting for}" }), vim.inspect(words))
  start, words = at_end("# Wo")
  check("project names complete in a heading", start == 2 and vim.deep_equal(words, { "Work" }), vim.inspect({ start, words }))
  start = at_end("- [ ] nothing to complete")
  check("and elsewhere nothing is offered", start == -3, start)
  check("it is the buffer's omnifunc", vim.bo[b].omnifunc == "v:lua.require'yadoist.complete'.omnifunc")
  vim.o.virtualedit = ""

  -- Colour comes from the text as it is drawn, so a typed line is coloured
  -- like one yadoist drew: its label like Alpha's.
  b = fresh("all", data)
  vim.api.nvim_set_hl(0, "YadoistLabel", { fg = "#00ff00" })
  vim.api.nvim_set_hl(0, "YadoistDueOverdue", { fg = "#ff0000" })
  vim.api.nvim_set_hl(0, "YadoistContent", { fg = "#0000ff" })
  vim.api.nvim_buf_set_lines(b, 4, 4, false, { "- [ ] Typed @errand <2000-01-01>" })
  vim.cmd("redraw!")
  local function attr(lnum, text)
    return vim.fn.screenattr(lnum, (vim.fn.getline(lnum):find(text, 1, true)))
  end
  local drawn, typed = attr(3, "@errand"), attr(5, "@errand")
  check("a typed line's label is coloured like a drawn one's", typed ~= 0 and typed == drawn, ("%d vs %d"):format(typed, drawn))
  local date, title = attr(5, "<2000"), attr(5, "Typed")
  check("and its date and title in their own colours", date ~= 0 and title ~= 0 and date ~= typed and title ~= date,
    vim.inspect({ date, title, typed }))

  local marks = vim.api.nvim_buf_get_extmarks(b, vim.api.nvim_get_namespaces().yadoist_beside, 0, -1, { details = true })
  local texts = {}
  for _, m in ipairs(marks) do
    texts[m[2] + 1] = table.concat(vim.tbl_map(function(c) return c[1] end, m[4].virt_text or {}))
  end
  check("a deadline is shown beside its line", texts[4] == "deadline 2099-02-01", vim.inspect(texts))
end

print("\nhealth")
do
  vim.cmd("silent checkhealth yadoist")
  local report = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  check(":checkhealth yadoist checks Neovim, curl and the token",
    report:find("OK Neovim", 1, true) ~= nil and report:find("curl", 1, true) ~= nil
      and report:find("OK a Todoist API token is set", 1, true) ~= nil, report)
  check("and never shows the token", not report:find("test-token", 1, true), report)
  vim.cmd("silent! bwipeout!")
end

print("\nreporting")
do
  local b = fresh()
  vim.api.nvim_buf_set_text(b, 2, 6, 2, 11, { "Alpha!" }) -- rename Alpha
  vim.api.nvim_buf_set_lines(b, 3, 4, false, {})          -- delete Bravo
  answer = 2                                              -- "Skip the deletes, apply the rest"
  vim.cmd("write")
  check("'skip the deletes' does not report a delete", not (notes[1] or ""):find("deleted"), notes[1])
  check("and does not delete", vim.deep_equal(server.take(), { "item_update" }) and vim.tbl_contains(lines(b), "- [ ] Bravo"),
    vim.inspect(lines(b)))
end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
end
