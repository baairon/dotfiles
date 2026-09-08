local M = {}

-- boot picker: a static menu over a full-window scratch buffer; only the rows it
-- actually draws get built, then flush as lines plus highlight extmarks

-- mocha tones, with literals standing in if catppuccin is somehow absent
local FALLBACK = {
  overlay0 = "#6c7086", subtext0 = "#a6adc8", subtext1 = "#bac2de",
  text = "#cdd6f4", lavender = "#b4befe", peach = "#fab387",
  surface1 = "#45475a",
}

local function palette()
  local ok, p = pcall(function() return require("catppuccin.palettes").get_palette("mocha") end)
  return (ok and p) or FALLBACK
end

-- every glyph is verified present in fonts/CozetteVector.ttf; Cozette carries only
-- 503 of Nerd Font's private-use glyphs, so a swap here needs checking, not guessing
local IC = {
  play    = string.char(0xEF, 0x81, 0x8B), -- U+F04B play
  history = string.char(0xEF, 0x80, 0x97), -- U+F017 clock
  folder  = string.char(0xEF, 0x81, 0xBC), -- U+F07C folder-open
  power   = string.char(0xEF, 0x80, 0x8D), -- U+F00D times
  dir     = string.char(0xEF, 0x81, 0xBB), -- U+F07B folder
  back    = string.char(0xEF, 0x81, 0x93), -- U+F053 chevron-left
  marker  = string.char(0xE2, 0x9D, 0xAF), -- U+276F heavy right angle quote
}

local MENU = {
  { icon = IC.play,    label = "Launch",          action = "launch",  key = "l" },
  { icon = IC.history, label = "Restore Session", action = "restore", key = "r" },
  { icon = IC.folder,  label = "New Session",     action = "new",     key = "n" },
  { icon = IC.power,   label = "Quit",            action = "quit",    key = "q" },
}

local HIST_FILE = vim.fn.stdpath("data") .. "/splash_recent_dirs"
local HIST_MAX = 10
local DEV_DIR = vim.fn.expand(vim.env.NVIM_DEV_DIR or "~/dev")

-- layout constants: each view centers its own block; under the minima the splash
-- steps aside entirely
local MENU_ROW_STEP = 2
local MENU_W = 23
local MIN_COLS = 40 -- menu block plus breathing room
local MENU_SPAN = (#MENU - 1) * MENU_ROW_STEP + 1
local MIN_ROWS = MENU_SPAN + 3 -- menu block plus the footer row
local DIRS_CHROME = 4 -- the picker's help line at rows - 3, footer at rows - 1

local function content_top(rows)
  local top = math.floor((rows - MENU_SPAN) / 2)
  local max_top = rows - 2 - MENU_SPAN
  if top > max_top then top = max_top end
  return math.max(1, top)
end

-- the picker centers its own height (title, blank, then the visible list) rather
-- than the menu's, and resolves max-visible against the same band in one pass
local function dirs_layout(rows, count)
  local band = rows - DIRS_CHROME
  local max_vis = math.min(count, math.max(1, math.floor((band - 3) / MENU_ROW_STEP) + 1))
  local block = 3 + (max_vis - 1) * MENU_ROW_STEP
  return math.max(1, math.floor((band - block) / 2)), max_vis
end

local cols, rows = 0, 0
local win, buf, ns, group
local on_done_cb, done = nil, false
local sel = 1
local chosen_dir = nil
local restore_target = nil
local view = "menu"
local dev_dirs = {}
local dir_items = {}
local dir_sel = 1
local committed = false
local busy = nil
local status = nil

-- one output row, built left to right: `cells` tracks display columns for
-- positioning, `bytes` tracks byte offsets because that is what extmarks want
local Row = {}
Row.__index = Row

local function row_new()
  return setmetatable({ cells = 0, bytes = 0, buf = {}, spans = {} }, Row)
end

function Row:at(col, text, hl)
  if col < self.cells then return self end -- never overlap what is already placed
  local pad = col - self.cells
  if pad > 0 then
    self.buf[#self.buf + 1] = string.rep(" ", pad)
    self.bytes = self.bytes + pad
  end
  local start = self.bytes
  self.buf[#self.buf + 1] = text
  self.bytes = self.bytes + #text
  self.cells = col + vim.api.nvim_strwidth(text)
  if hl and #text > 0 then self.spans[#self.spans + 1] = { start, self.bytes, hl } end
  return self
end

-- span from a recorded byte offset to wherever the row now ends
function Row:mark(from, hl, prio)
  self.spans[#self.spans + 1] = { from, self.bytes, hl, prio }
end

function Row:line() return table.concat(self.buf) end

local function setup_hl()
  local P = palette()
  local set = vim.api.nvim_set_hl
  -- no bg: the splash inherits the transparent base like every other window
  set(0, "SplashBase",  { fg = P.subtext0 })
  set(0, "SplashDim",   { fg = P.overlay0 })
  set(0, "SplashItem",  { fg = P.subtext1 })
  set(0, "SplashMsg",   { fg = P.peach })
  set(0, "SplashTitle", { fg = P.lavender })
  set(0, "SplashOn",    { fg = P.text })
  set(0, "SplashAccent", { link = "Directory" })
  -- own band: CursorLine was darkened toward mocha base and disappeared on the picker
  set(0, "SplashSel",    { bg = P.surface1 })
end

local IS_WIN = vim.fn.has("win32") == 1

-- windows paths differ only by case, so every comparison goes through this
local function dir_key(dir)
  return IS_WIN and dir:lower() or dir
end

-- the visited-directory history, newest first: one path per line, so the file
-- stays readable and hand-editable. reads prune anything that no longer exists
local function load_recent()
  local f = io.open(HIST_FILE, "r")
  if not f then return {} end
  local out, seen = {}, {}
  for line in f:lines() do
    local dir = vim.fs.normalize((line:gsub("%s+$", "")))
    local key = dir_key(dir)
    if dir ~= "" and not seen[key] and vim.fn.isdirectory(dir) == 1 then
      seen[key] = true
      out[#out + 1] = dir
      if #out >= HIST_MAX then break end
    end
  end
  f:close()
  return out
end

local function write_recent(list)
  local f = io.open(HIST_FILE, "w")
  if not f then return end
  for i = 1, math.min(#list, HIST_MAX) do f:write(list[i], "\n") end
  f:close()
end

-- the visited directory leaves its old slot and comes back at the top, so the file
-- stays newest-first and carries no duplicate
local function push_recent(dir)
  dir = vim.fs.normalize(dir)
  if dir == "" or vim.fn.isdirectory(dir) ~= 1 then return end
  local out, key = { dir }, dir_key(dir)
  for _, d in ipairs(load_recent()) do
    if dir_key(d) ~= key then out[#out + 1] = d end
  end
  write_recent(out)
end

local function build_dir_items()
  dir_items = {
    { kind = "back", icon = IC.back, label = "Back", hl = "SplashDim" },
  }
  for _, name in ipairs(dev_dirs) do
    dir_items[#dir_items + 1] = { kind = "dir", icon = IC.dir, label = name, hl = "SplashItem", name = name }
  end
end

-- One read of the history file, for the restore target that falls out of it. Nothing outside
-- the splash writes that file while the splash is up, so this runs once on show rather than
-- once per keypress.
local function reload_recent()
  restore_target = load_recent()[1]
end

local function scan_dev_dirs()
  dev_dirs = {}
  if vim.fn.isdirectory(DEV_DIR) == 1 then
    local entries = vim.fn.readdir(DEV_DIR)
    table.sort(entries)
    for _, e in ipairs(entries) do
      if not e:match("^%.") and vim.fn.isdirectory(DEV_DIR .. "/" .. e) == 1 then
        dev_dirs[#dev_dirs + 1] = e
      end
    end
  end
  build_dir_items()
end

-- every view places the same shape: marker, icon, label. the label is clipped to
-- the block so a long name cannot drag the selection background past it, and
-- paths clip from the left because the tail is the part worth reading
local function clip(label, budget, from_left)
  local len = vim.fn.strchars(label)
  if budget <= 1 or len <= budget then return label end
  if from_left then return "…" .. vim.fn.strcharpart(label, len - budget + 1) end
  return vim.fn.strcharpart(label, 0, budget - 1) .. "…"
end

local function draw_entry(row, left, w, icon, label, hl, selected)
  if selected then row:at(left, IC.marker, "SplashAccent") end
  row:at(left + 2, icon, hl)
  row:at(left + 5, clip(label, w - 5), hl)
end

local function draw_menu(row)
  local left = math.floor((cols - MENU_W) / 2)
  local top = content_top(rows)
  for i = 1, #MENU do
    local on = (i == sel)
    local r = row(top + (i - 1) * MENU_ROW_STEP)
    draw_entry(r, left, MENU_W, MENU[i].icon, MENU[i].label, on and "SplashOn" or "SplashItem", on)
    r:at(left + MENU_W - 1, MENU[i].key, on and "SplashAccent" or "SplashDim")
  end
end

local ARROW_UP = "\226\150\178"
local ARROW_DOWN = "\226\150\188"

local HELP_DIRS = "↵ open   e dev   c clone   d delete   esc back"

local function draw_picker(row)
  local w = MENU_W
  local left = math.floor((cols - w) / 2)
  local count = #dir_items
  local title_row, max_vis = dirs_layout(rows, count)
  local list_top = title_row + 2
  local scroll = math.max(0, dir_sel - max_vis)

  local head = "~/dev"
  local title = row(title_row):at(left + 2, head, "SplashTitle")
  local msg = busy or status
  if msg then title:at(left + 3 + vim.api.nvim_strwidth(head), msg, "SplashMsg") end

  if scroll > 0 then
    row(list_top - 1):at(left + math.floor(w / 2), ARROW_UP, "SplashDim")
  end

  local last_r = list_top
  for i = 1, max_vis do
    local di = i + scroll
    if di > count then break end
    last_r = list_top + (i - 1) * MENU_ROW_STEP
    local it = dir_items[di]
    local r = row(last_r)
    if di == dir_sel then
      local bg = r:at(left, "").bytes
      draw_entry(r, left, w, it.icon, it.label, "SplashOn", true)
      r:at(left + w, "")
      r:mark(bg, "SplashSel", 1)
    else
      draw_entry(r, left, w, it.icon, it.label, it.hl, false)
    end
  end

  if scroll + max_vis < count then
    row(last_r + 1):at(left + math.floor(w / 2), ARROW_DOWN, "SplashDim")
  end

  local hw = vim.api.nvim_strwidth(HELP_DIRS)
  row(rows - 3):at(math.max(0, math.floor((cols - hw) / 2)), HELP_DIRS, "SplashDim")
end

-- The menu has no room for a status line of its own, so the footer carries it: it is one row
-- that is already there, and the cwd it usually shows is the least urgent of the things that
-- can want it.
local function draw_footer(row)
  local r = row(rows - 1)
  if view == "menu" and status then
    local w = vim.api.nvim_strwidth(status)
    r:at(math.max(0, math.floor((cols - w) / 2)), status, "SplashMsg")
    return
  end
  -- with Restore selected the footer says what it would restore, so the answer is on screen
  -- exactly while it is the question being asked
  if view == "menu" and MENU[sel].action == "restore" and restore_target then
    local target = clip(vim.fn.fnamemodify(restore_target, ":~"), cols - 6, true)
    local left = math.max(0, math.floor((cols - (2 + vim.api.nvim_strwidth(target))) / 2))
    r:at(left, IC.dir, "SplashDim"):at(left + 2, target, "SplashItem")
    return
  end
  local cwd = clip(vim.fn.fnamemodify(vim.fn.getcwd(), ":~"), cols - 6, true)
  local left = math.max(0, math.floor((cols - (2 + vim.api.nvim_strwidth(cwd))) / 2))
  r:at(left, IC.dir, "SplashDim"):at(left + 2, cwd, "SplashDim")
end

local function finish()
  if done then return end
  done = true
  if group then vim.api.nvim_del_augroup_by_id(group); group = nil end
  if win and vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
  if buf and vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  win, buf = nil, nil
  if chosen_dir then pcall(vim.cmd, "cd " .. vim.fn.fnameescape(chosen_dir)) end
  push_recent(vim.fn.getcwd())
  if on_done_cb then
    local cb = on_done_cb
    on_done_cb = nil
    vim.schedule(function() cb(committed) end)
  end
end

local function render()
  if done then return end
  if not (win and vim.api.nvim_win_is_valid(win) and buf and vim.api.nvim_buf_is_valid(buf)) then
    finish()
    return
  end
  local ok = pcall(function()
    -- The terminal can settle on a new size after VimEnter. Use the live grid on
    -- every draw, including keys pressed before the resize event is delivered.
    cols, rows = vim.o.columns, math.max(1, vim.o.lines - 1)
    if vim.api.nvim_win_get_width(win) ~= cols or vim.api.nvim_win_get_height(win) ~= rows then
      vim.api.nvim_win_set_config(win, { relative = "editor", row = 0, col = 0, width = cols, height = rows })
    end
    local out = {}
    -- rows are sparse; anything off-screen lands in a throwaway and is dropped
    local function row(r)
      if r < 0 or r >= rows then return row_new() end
      out[r] = out[r] or row_new()
      return out[r]
    end

    if view == "menu" then draw_menu(row) else draw_picker(row) end
    draw_footer(row)

    local lines, marks = {}, {}
    for r = 0, rows - 1 do
      local rw = out[r]
      lines[r + 1] = rw and rw:line() or ""
      if rw then
        for _, s in ipairs(rw.spans) do marks[#marks + 1] = { r, s } end
      end
    end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, m in ipairs(marks) do
      local s = m[2]
      vim.api.nvim_buf_set_extmark(buf, ns, m[1], s[1], {
        end_col = s[2], hl_group = s[3], priority = s[4],
      })
    end
  end)
  if not ok then finish(); return end
  vim.api.nvim_win_set_cursor(win, { rows, 0 })
  -- This is a screen, not a scrolling document. A shrink can otherwise retain
  -- the old bottom cursor row and scroll the menu upwards on the next key.
  vim.api.nvim_win_call(win, function() vim.fn.winrestview({ topline = 1, leftcol = 0, skipcol = 0 }) end)
end

local function quit_nvim()
  done = true
  vim.schedule(function() pcall(vim.cmd, "qa") end)
end

local function move_sel(d)
  if committed then return end
  status = nil
  if view == "menu" then
    sel = ((sel - 1 + d) % #MENU) + 1
  else
    dir_sel = ((dir_sel - 1 + d) % #dir_items) + 1
  end
end

local function commit()
  committed = true
  vim.schedule(finish)
end

local function activate()
  if committed then return end
  if view ~= "menu" then
    local it = dir_items[dir_sel]
    if not it then return end
    if it.kind == "back" then
      view = "menu"
    elseif it.kind == "dir" then
      chosen_dir = DEV_DIR .. "/" .. it.name
      commit()
    end
    return
  end
  local item = MENU[sel]
  if item.action == "quit" then
    quit_nvim()
  elseif item.action == "launch" then
    commit()
  elseif item.action == "restore" then
    -- load_recent prunes directories that no longer exist, so the target is always openable
    if restore_target then
      chosen_dir = restore_target
      commit()
    else
      status = "no history yet"
    end
  elseif item.action == "new" then
    if vim.fn.isdirectory(DEV_DIR) == 0 then pcall(vim.fn.mkdir, DEV_DIR, "p") end
    scan_dev_dirs()
    busy, status = nil, nil
    view = "dirs"
    dir_sel = (#dev_dirs > 0) and 2 or 1
  end
end

local function go_back()
  if committed then return end
  if view ~= "menu" then
    view = "menu"
    return
  end
  finish()
end

local function shortcut(key)
  if committed or view ~= "menu" then return end
  for i = 1, #MENU do
    if MENU[i].key == key then
      sel = i
      activate()
      return
    end
  end
end

local function repo_name_from_url(url)
  url = url:gsub("%s+$", ""):gsub("/+$", "")
  local name = url:match("([^/]+)$") or ""
  return (name:gsub("%.git$", ""))
end

local function select_dir_by_name(name)
  for i, it in ipairs(dir_items) do
    if it.kind == "dir" and it.name == name then dir_sel = i; return end
  end
end

local function clone_repo()
  if committed or busy or view ~= "dirs" then return end
  status = nil
  local ok, url = pcall(vim.fn.input, "git clone: ")
  vim.cmd("redraw")
  if not ok or not url or url:gsub("%s", "") == "" then return end
  url = url:gsub("^%s+", ""):gsub("%s+$", "")
  if url:match("^[%w_.-]+/[%w_.-]+$") then url = "https://github.com/" .. url end
  local name = repo_name_from_url(url)
  if name == "" then
    status = "invalid url"
    return
  end
  local dest = DEV_DIR .. "/" .. name
  if vim.fn.isdirectory(dest) == 1 then
    status = name .. " exists"
    return
  end
  busy = "cloning " .. name .. "…"
  render()
  vim.system({ "git", "clone", url, dest }, { text = true }, function(res)
    vim.schedule(function()
      busy = nil
      if res.code == 0 then
        scan_dev_dirs()
        select_dir_by_name(name)
      else
        local err = (res.stderr or ""):match("[^\r\n]*$")
        status = "clone failed" .. (err ~= "" and (": " .. err) or "")
      end
      render()
    end)
  end)
end

local function open_in_os(path)
  if type(vim.ui.open) == "function" then
    pcall(vim.ui.open, path)
    return
  end
  local cmd
  if vim.fn.has("win32") == 1 then
    cmd = { "cmd.exe", "/c", "start", "", path }
  elseif vim.fn.has("macunix") == 1 then
    cmd = { "open", path }
  else
    cmd = { "xdg-open", path }
  end
  pcall(vim.fn.jobstart, cmd, { detach = true })
end

local function open_dev()
  if committed or busy or view ~= "dirs" then return end
  open_in_os(DEV_DIR)
end

local function delete_dir()
  if committed or busy or view ~= "dirs" then return end
  local it = dir_items[dir_sel]
  if not it or it.kind ~= "dir" then return end
  status = nil
  local choice = vim.fn.confirm("Delete " .. it.name .. "?", "&Yes\n&No", 2)
  if choice ~= 1 then return end
  local dest = DEV_DIR .. "/" .. it.name
  -- Windows cannot remove a directory that is the process cwd; step out first
  local tgt = dir_key(vim.fs.normalize(dest))
  local cwd = dir_key(vim.fs.normalize(vim.fn.getcwd()))
  if cwd == tgt or cwd:sub(1, #tgt + 1) == tgt .. "/" then
    pcall(vim.cmd, "cd " .. vim.fn.fnameescape(DEV_DIR))
  end
  busy = "deleting " .. it.name .. "…"
  render()
  local cmd = IS_WIN
    and { "cmd", "/d", "/c", "rd", "/s", "/q", (dest:gsub("/", "\\")) }
    or { "rm", "-rf", dest }
  vim.system(cmd, { cwd = DEV_DIR }, function()
    vim.schedule(function()
      busy = nil
      if vim.fn.isdirectory(dest) == 1 then status = "delete failed" end
      scan_dev_dirs()
      if dir_sel > #dir_items then dir_sel = #dir_items end
      render()
    end)
  end)
end

function M.show(on_done)
  if #vim.api.nvim_list_uis() == 0 then
    return on_done()
  end
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_set_current_win, win)
    return
  end
  cols = vim.o.columns
  rows = math.max(1, vim.o.lines - 1)
  if cols < MIN_COLS or rows < MIN_ROWS then
    return on_done()
  end
  setup_hl()
  scan_dev_dirs()
  reload_recent()
  done = false
  committed = false
  view = "menu"
  sel = 1
  dir_sel = 1
  busy, status = nil, nil
  chosen_dir = nil
  on_done_cb = on_done
  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "splash"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = 0,
    col = 0,
    width = cols,
    height = rows,
    style = "minimal",
    focusable = true,
    zindex = 200,
  })
  vim.api.nvim_set_option_value("winhighlight", "Normal:SplashBase,NormalFloat:SplashBase,EndOfBuffer:SplashBase", { win = win })
  vim.api.nvim_set_option_value("wrap", false, { win = win })
  vim.api.nvim_set_option_value("cursorline", false, { win = win })
  vim.api.nvim_set_option_value("number", false, { win = win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = win })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = win })
  vim.api.nvim_set_option_value("statuscolumn", "", { win = win })
  local function lock_win_opts()
    if win and vim.api.nvim_win_is_valid(win) then
      vim.wo[win].number         = false
      vim.wo[win].relativenumber = false
      vim.wo[win].signcolumn     = "no"
      vim.wo[win].statuscolumn   = ""
      vim.wo[win].winbar         = ""
      vim.wo[win].scrolloff      = 0
      vim.wo[win].sidescrolloff  = 0
      vim.wo[win].scrollbind     = false
      vim.wo[win].cursorbind     = false
    end
  end
  lock_win_opts()
  group = vim.api.nvim_create_augroup("WorkspaceSplash", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group    = group,
    buffer   = buf,
    callback = lock_win_opts,
  })
  vim.api.nvim_create_autocmd("VimResized", { group = group, callback = render })
  ns = vim.api.nvim_create_namespace("splash")
  local function kmap(lhs, fn)
    vim.keymap.set("n", lhs, function()
      fn()
      if not done then render() end
    end, { buffer = buf, nowait = true, silent = true })
  end
  kmap("<CR>", activate)
  kmap("j", function() move_sel(1) end)
  kmap("<Down>", function() move_sel(1) end)
  kmap("k", function() move_sel(-1) end)
  kmap("<Up>", function() move_sel(-1) end)
  kmap("<Esc>", go_back)
  kmap("q", function()
    if view ~= "menu" then view = "menu" else shortcut("q") end
  end)
  kmap("l", function() shortcut("l") end)
  kmap("r", function() shortcut("r") end)
  kmap("n", function() shortcut("n") end)
  kmap("c", clone_repo)
  kmap("d", delete_dir)
  kmap("e", open_dev)
  render()
  pcall(vim.api.nvim_win_set_cursor, win, { rows, 0 })
end

return M
