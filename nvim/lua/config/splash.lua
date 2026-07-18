local M = {}

-- the art is the animated catgif sprite (half-block cells, fg+bg per cell),
-- shared with the corner cat via config.catgif's sprite() export
local HALF = "\226\150\128" -- U+2580 upper half block
local sprite = nil
local cat_frame = 1
local cat_timer = nil

local function art_h()
  return sprite and sprite.h_cells or 0
end

local PALETTE = { "#8bb8e0", "#a0c8ea", "#b4d6f2", "#c6e0f7", "#d6eafa", "#e4f0fc", "#f0f7fe", "#ffffff" }
local BG_FALLBACK = "#030509"
local function get_bg()
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = "Normal" })
  if ok and hl and hl.bg then return string.format("#%06x", hl.bg) end
  return BG_FALLBACK
end

local IC = {
  play    = string.char(0xEF, 0x81, 0x8B),
  history = string.char(0xEF, 0x87, 0x9A),
  folder  = string.char(0xEF, 0x81, 0xBC),
  power   = string.char(0xEF, 0x80, 0x91),
  dir     = string.char(0xEF, 0x81, 0xBB),
  back    = string.char(0xEF, 0x81, 0xA0),
  marker  = string.char(0xE2, 0x9D, 0xAF),
}

local MENU = {
  { icon = IC.play,    label = "Launch",          action = "launch",  key = "l" },
  { icon = IC.history, label = "Restore Session", action = "restore", key = "r" },
  { icon = IC.folder,  label = "New Session",     action = "new",     key = "n" },
  { icon = IC.power,   label = "Quit",            action = "quit",    key = "q" },
}

local STATE_FILE = vim.fn.stdpath("data") .. "/splash_last_dir"
local DEV_DIR = vim.fn.expand(vim.env.NVIM_DEV_DIR or "~/dev")

local function split_chars(s)
  local t = {}
  for c in s:gmatch("[\1-\127\194-\244][\128-\191]*") do t[#t + 1] = c end
  return t
end

-- layout constants: the art sits upper-center (biased above the true middle)
-- and the menu hangs below it; on short windows the gap compresses toward
-- MENU_GAP_MIN so every item plus the footer still fits, and below the minima
-- the splash steps aside entirely
local MENU_ROW_STEP = 2
local MENU_W = 23
local TOP_BIAS = 0.38
local MENU_GAP_MIN, MENU_GAP_MAX = 2, 3
local MIN_COLS = 40 -- menu block plus breathing room; the art is narrower

-- largest gap that keeps the last menu row at or above row rows - 3
local function menu_gap(rows)
  return math.max(MENU_GAP_MIN, math.min(MENU_GAP_MAX, rows - 10 - art_h()))
end

-- exact-fit height at MENU_GAP_MIN for the current art
local function min_rows()
  return art_h() + 10 + MENU_GAP_MIN
end

local function content_top(rows)
  local menu_span = menu_gap(rows) + (#MENU - 1) * MENU_ROW_STEP + 1
  local top = math.floor((rows - art_h()) * TOP_BIAS)
  local max_top = rows - 2 - art_h() - menu_span
  if top > max_top then top = max_top end
  return math.max(1, top)
end

local cols, rows = 0, 0
local chargrid, colgrid = {}, {}
local rowbg = {}
local win, buf, ns
local on_done_cb, done = nil, false
local sel = 1
local chosen_dir = nil
local view = "menu"
local dev_dirs = {}
local dir_items = {}
local dir_sel = 1
local committed = false
local busy = nil
local status = nil

local function clear()
  for i = 1, rows * cols do chargrid[i] = " "; colgrid[i] = 0 end
  for k in pairs(rowbg) do rowbg[k] = nil end
end

local function put(c, r, ch, ci)
  if c < 0 or c >= cols or r < 0 or r >= rows then return end
  local idx = r * cols + c + 1
  chargrid[idx] = ch
  colgrid[idx] = ci
end

local function put_str(left, r, s, ci)
  local cs = split_chars(s)
  for i, ch in ipairs(cs) do
    if ch ~= " " then put(left + i - 1, r, ch, ci) end
  end
end

local function put_center(r, s, ci)
  local cs = split_chars(s)
  put_str(math.max(0, math.floor((cols - #cs) / 2)), r, s, ci)
end

local function setup_hl()
  local BG = get_bg()
  vim.api.nvim_set_hl(0, "SplashBase", { fg = PALETTE[2], bg = BG })
  vim.api.nvim_set_hl(0, "SplashSel", { bg = "#131631" })
  vim.api.nvim_set_hl(0, "SplashAccent", { fg = "#8f9ae0" })
  for i = 1, 8 do
    vim.api.nvim_set_hl(0, "SplashG" .. i, { fg = PALETTE[i] })
  end
end

local function save_last_dir()
  local f = io.open(STATE_FILE, "w")
  if f then
    f:write(vim.fn.getcwd())
    f:close()
  end
end

local function load_last_dir()
  local f = io.open(STATE_FILE, "r")
  if not f then return nil end
  local dir = f:read("*a")
  f:close()
  dir = (dir or ""):gsub("%s+$", "")
  if dir ~= "" and vim.fn.isdirectory(dir) == 1 then return dir end
  return nil
end

local function build_dir_items()
  dir_items = {
    { kind = "back", icon = IC.back, label = "Back", off = 3 },
  }
  for _, name in ipairs(dev_dirs) do
    dir_items[#dir_items + 1] = { kind = "dir", icon = IC.dir, label = name, off = 5, name = name }
  end
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

local function draw_art()
  if not sprite then return end
  local top = content_top(rows)
  local c1, c2 = sprite.c1, sprite.c2
  local left = math.floor((cols - (c2 - c1 + 1)) / 2) - (c1 - 1)
  local grid = sprite.grids[cat_frame] or sprite.grids[1]
  for gr = 1, sprite.h_cells do
    local r = top + gr - 1
    if r >= rows then break end
    local row = grid[gr]
    for gc = 1, sprite.w_cells do
      if row[gc] then put(left + gc - 1, r, HALF, row[gc]) end
    end
  end
end

local function draw_menu()
  local menu_w = MENU_W
  local left = math.floor((cols - menu_w) / 2)
  local btop = content_top(rows)
  local mtop = btop + art_h() + menu_gap(rows)
  for i = 1, #MENU do
    local r = mtop + (i - 1) * MENU_ROW_STEP
    if r >= rows then break end
    local on = (i == sel)
    if on then put(left, r, IC.marker, "SplashAccent") end
    put(left + 2, r, MENU[i].icon, on and 8 or 5)
    local lc = split_chars(MENU[i].label)
    local cp = left + 5
    for j = 1, #lc do
      if lc[j] ~= " " then put(cp, r, lc[j], on and 8 or 5) end
      cp = cp + 1
    end
    put(left + menu_w - 1, r, MENU[i].key, on and "SplashAccent" or 3)
  end
end

local ARROW_UP = "\226\150\178"
local ARROW_DOWN = "\226\150\188"

local function draw_dirpicker()
  local menu_w = MENU_W
  local left = math.floor((cols - menu_w) / 2)
  local count = #dir_items
  -- share the menu view's ceiling so switching views never jumps; the list
  -- may run down to rows - 5 (help line at rows - 3, footer at rows - 1)
  local title_row = content_top(rows)
  local list_top = title_row + 2
  local max_vis = math.max(1, math.floor((rows - 5 - list_top) / MENU_ROW_STEP) + 1)
  max_vis = math.min(max_vis, count)
  local scroll = math.max(0, dir_sel - max_vis)

  put_str(left + 2, title_row, "~/dev", 7)
  local msg = busy or status
  if msg then put_str(left + 8, title_row, msg, 6) end

  if scroll > 0 then put(left + math.floor(menu_w / 2), list_top - 1, ARROW_UP, 3) end

  local last_r = list_top
  for i = 1, max_vis do
    local di = i + scroll
    if di > count then break end
    local r = list_top + (i - 1) * MENU_ROW_STEP
    if r >= rows - 1 then break end
    last_r = r
    local on = (di == dir_sel)
    local it = dir_items[di]
    local icon, label, off = it.icon, it.label, it.off
    if on then
      rowbg[r] = { c1 = left, c2 = left + menu_w }
      put(left, r, IC.marker, "SplashAccent")
    end
    put(left + 2, r, icon, on and 8 or off)
    local nc = split_chars(label)
    local cp = left + 5
    for j = 1, #nc do
      if nc[j] ~= " " then put(cp, r, nc[j], on and 8 or off) end
      cp = cp + 1
    end
  end

  if scroll + max_vis < count then
    put(left + math.floor(menu_w / 2), last_r + 1, ARROW_DOWN, 3)
  end

  put_center(rows - 3, "↵ open   e dev   c clone   d delete   esc back", 3)
end

local function draw_footer()
  local cwd = split_chars(vim.fn.fnamemodify(vim.fn.getcwd(), ":~"))
  local maxw = cols - 6
  if maxw > 1 and #cwd > maxw then
    local trimmed = { "…" }
    for i = #cwd - maxw + 2, #cwd do trimmed[#trimmed + 1] = cwd[i] end
    cwd = trimmed
  end
  local r = rows - 1
  local left = math.max(0, math.floor((cols - (2 + #cwd)) / 2))
  put(left, r, IC.dir, 3)
  for i, ch in ipairs(cwd) do
    if ch ~= " " then put(left + 2 + i - 1, r, ch, 3) end
  end
end

local function flush()
  local lines, hls, bgmarks = {}, {}, {}
  for r = 0, rows - 1 do
    local rowchars, bytepos = {}, 0
    local run_start, run_ci = 0, nil
    local b = r * cols
    local bg = rowbg[r]
    local bg_s, bg_e = nil, nil
    for c = 0, cols - 1 do
      local idx = b + c + 1
      local ch = chargrid[idx]
      local ci = colgrid[idx]
      rowchars[c + 1] = ch
      -- string entries are ready-made highlight group names (the cat's fg+bg cells)
      if type(ci) == "string" or ci >= 3 then
        if run_ci ~= ci then
          if run_ci then hls[#hls + 1] = { r, run_start, bytepos, run_ci } end
          run_start, run_ci = bytepos, ci
        end
      elseif run_ci then
        hls[#hls + 1] = { r, run_start, bytepos, run_ci }
        run_ci = nil
      end
      if bg then
        if c == bg.c1 then bg_s = bytepos end
        if c == bg.c2 then bg_e = bytepos end
      end
      bytepos = bytepos + #ch
    end
    if run_ci then hls[#hls + 1] = { r, run_start, bytepos, run_ci } end
    if bg and bg_s then bgmarks[#bgmarks + 1] = { r, bg_s, bg_e or bytepos } end
    lines[r + 1] = table.concat(rowchars)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i = 1, #bgmarks do
    local m = bgmarks[i]
    vim.api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_col = m[3], hl_group = "SplashSel", priority = 1 })
  end
  for i = 1, #hls do
    local h = hls[i]
    local g = h[4]
    if type(g) ~= "string" then g = "SplashG" .. g end
    vim.api.nvim_buf_set_extmark(buf, ns, h[1], h[2], { end_col = h[3], hl_group = g })
  end
end

local function stop_cat()
  if cat_timer then
    pcall(function()
      cat_timer:stop()
      cat_timer:close()
    end)
    cat_timer = nil
  end
end


local function finish()
  if done then return end
  done = true
  stop_cat()
  if win and vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
  if buf and vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  win, buf = nil, nil
  if chosen_dir then pcall(vim.cmd, "cd " .. vim.fn.fnameescape(chosen_dir)) end
  save_last_dir()
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
    clear()
    if view == "menu" then
      draw_art()
      draw_menu()
    else
      draw_dirpicker()
    end
    draw_footer()
    flush()
  end)
  if not ok then finish() end
  pcall(vim.api.nvim_win_set_cursor, win, { rows, 0 })
end

local function start_cat()
  if not sprite or #sprite.grids < 2 then return end
  stop_cat()
  cat_timer = vim.uv.new_timer()
  local function arm()
    if not cat_timer then return end
    cat_timer:start(sprite.delays[cat_frame] or 200, 0, function()
      vim.schedule(function()
        if done or not cat_timer then return end
        cat_frame = (cat_frame % #sprite.grids) + 1
        if view == "menu" then render() end
        arm()
      end)
    end)
  end
  arm()
end

local function quit_nvim()
  done = true
  stop_cat()
  vim.schedule(function() pcall(vim.cmd, "qa") end)
end

local function move_sel(d)
  if committed then return end
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
  if view == "dirs" then
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
    local dir = load_last_dir()
    if dir then
      chosen_dir = dir
      commit()
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
  if view == "dirs" then
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
  local is_win = vim.fn.has("win32") == 1
  -- Windows cannot remove a directory that is the process cwd; step out first
  local tgt = vim.fs.normalize(dest)
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  if is_win then tgt, cwd = tgt:lower(), cwd:lower() end
  if cwd == tgt or cwd:sub(1, #tgt + 1) == tgt .. "/" then
    pcall(vim.cmd, "cd " .. vim.fn.fnameescape(DEV_DIR))
  end
  busy = "deleting " .. it.name .. "…"
  render()
  local cmd = is_win
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
  do
    local ok, cg = pcall(require, "config.catgif")
    sprite = ok and cg.sprite() or nil
    cat_frame = 1
    if sprite then
      -- transparent margins baked into the gif can sit lopsided, so record the
      -- opaque column bounds and center the visible art rather than the box
      local c1, c2 = sprite.w_cells, 1
      for _, grid in ipairs(sprite.grids) do
        for r = 1, sprite.h_cells do
          local row = grid[r]
          for c = 1, sprite.w_cells do
            if row[c] then
              if c < c1 then c1 = c end
              if c > c2 then c2 = c end
            end
          end
        end
      end
      if c2 < c1 then c1, c2 = 1, sprite.w_cells end
      sprite.c1, sprite.c2 = c1, c2
    end
  end
  if cols < MIN_COLS or rows < min_rows() then
    return on_done()
  end
  setup_hl()
  scan_dev_dirs()
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
    end
  end
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    buffer   = buf,
    callback = lock_win_opts,
  })
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
    if view == "dirs" then view = "menu" else shortcut("q") end
  end)
  kmap("l", function() shortcut("l") end)
  kmap("r", function() shortcut("r") end)
  kmap("n", function() shortcut("n") end)
  kmap("c", clone_repo)
  kmap("d", delete_dir)
  kmap("e", open_dev)
  render()
  start_cat()
  pcall(vim.api.nvim_win_set_cursor, win, { rows, 0 })
end

return M
