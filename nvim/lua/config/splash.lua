local M = {}

local RAMP = " .`,:;!^+*coO0@#"
local P = { arms = 3, stars = 600, speed = -38, size = 65, twist = 0.30, noise = 0.00, glow = 0.00, twinkle = 0.35 }
local TAU = math.pi * 2
local SPIRAL_H = 13

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

local function rstate_new(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return s
end
local rstate = 1
local function rng()
  rstate = (rstate * 16807) % 2147483647
  return rstate / 2147483647
end
local function reseed(seed) rstate = rstate_new(seed) end

local MENU_GAP = 4
local MENU_ROW_STEP = 2
local CONTENT_H = SPIRAL_H + MENU_GAP + (#MENU - 1) * MENU_ROW_STEP + 1

local function content_top(rows)
  return math.max(1, math.floor((rows - CONTENT_H) / 2))
end

local uv = vim.uv or vim.loop
local cols, rows = 0, 0
local chargrid, colgrid = {}, {}
local rowbg = {}
local acc = {}
local gstars = {}
local angle, clock, last = 0, 0, 0
local win, buf, ns, timer
local on_done_cb, done = nil, false
local saved_guicursor
local sel = 1
local chosen_dir = nil
local view = "menu"
local dev_dirs = {}
local dir_items = {}
local dir_sel = 1
local committed = false

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

local function setup_hl()
  local BG = get_bg()
  vim.api.nvim_set_hl(0, "SplashBase", { fg = PALETTE[2], bg = BG })
  vim.api.nvim_set_hl(0, "SplashCursor", { fg = BG, bg = BG })
  vim.api.nvim_set_hl(0, "SplashSel", { bg = "#0e141d" })
  for i = 1, 8 do
    vim.api.nvim_set_hl(0, "SplashG" .. i, { fg = PALETTE[i] })
  end
end

local function seed_stars()
  reseed(1337)
  gstars = {}
  for i = 0, P.stars - 1 do
    gstars[#gstars + 1] = {
      arm = i % P.arms,
      rt = rng() ^ 0.55,
      ja = rng() * 2 - 1,
      jr = rng() * 2 - 1,
      tw = rng() * TAU,
      along = rng(),
      field = rng() < 0.12,
    }
  end
end

local function render_spiral(cx, cy, maxR, rotation, tMs, bright)
  bright = bright or 1
  local twistTurns = 0.3 + P.twist * 3.0
  local glow = P.glow
  local n_cells = rows * cols
  for i = 1, n_cells do acc[i] = 0 end
  for s = 1, #gstars do
    local st = gstars[s]
    local ang, r
    if st.field then
      ang = st.along * TAU + rotation * 0.25
      r = (0.15 + st.rt * 0.95) * maxR
    else
      ang = st.arm * TAU / P.arms + st.rt * twistTurns * TAU + rotation + st.ja * P.noise * 0.5
      r = (st.rt + st.jr * P.noise * 0.05) * maxR
    end
    local x = math.floor(cx + math.cos(ang) * r + 0.5)
    local y = math.floor(cy + math.sin(ang) * r * 0.5 + 0.5)
    if x >= 0 and x < cols and y >= 0 and y < rows then
      local core = math.exp(-st.rt * (3.2 - glow * 2.4))
      local twk = 1 - P.twinkle * 0.55 * (0.5 + 0.5 * math.sin(tMs * 0.004 + st.tw))
      local idx = y * cols + x + 1
      acc[idx] = acc[idx] + core * twk * (st.field and 0.45 or 1)
    end
  end
  local rlen = #RAMP
  for r2 = 0, rows - 1 do
    local b = r2 * cols
    for c = 0, cols - 1 do
      local v = acc[b + c + 1]
      if v > 0.02 then
        local n = math.min(1, (v ^ 0.7) * (1 + glow * 0.5)) * bright
        if n > 0.03 then
          local ci = math.min(rlen - 1, 1 + math.floor(n * (rlen - 1)))
          local ch = RAMP:sub(ci + 1, ci + 1)
          if ch ~= " " then
            put(c, r2, ch, math.min(8, 2 + math.floor(n * 6)))
          end
        end
      end
    end
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

local function draw_spiral()
  local top = content_top(rows)
  local cx = cols / 2
  local cy = top + (SPIRAL_H - 1) / 2
  local maxR = SPIRAL_H * 1.28
  render_spiral(cx, cy, maxR, angle, clock * 1000, 1)
end

local function draw_menu()
  local menu_w = 26
  local left = math.floor((cols - menu_w) / 2)
  local btop = content_top(rows)
  local mtop = btop + SPIRAL_H + MENU_GAP
  for i = 1, #MENU do
    local r = mtop + (i - 1) * MENU_ROW_STEP
    if r >= rows then break end
    local on = (i == sel)
    if on then put(left, r, IC.marker, 8) end
    put(left + 2, r, MENU[i].icon, on and 8 or 5)
    local lc = split_chars(MENU[i].label)
    local cp = left + 5
    for j = 1, #lc do
      if lc[j] ~= " " then put(cp, r, lc[j], on and 8 or 5) end
      cp = cp + 1
    end
    put(left + menu_w - 1, r, MENU[i].key, on and 7 or 3)
  end
end

local ARROW_UP = "\226\150\178"
local ARROW_DOWN = "\226\150\188"

local function draw_dirpicker()
  local menu_w = 26
  local left = math.floor((cols - menu_w) / 2)
  local count = #dir_items
  local avail = rows - 2
  local max_vis = math.max(1, math.floor((avail - 2) / MENU_ROW_STEP))
  max_vis = math.min(max_vis, count)
  local scroll = math.max(0, dir_sel - max_vis)
  local vis = math.min(max_vis, count - scroll)
  local block_h = 2 + (vis - 1) * MENU_ROW_STEP + 1
  local top = math.max(1, math.floor((rows - block_h) / 2))
  local title_row = top
  local list_top = top + 2

  local tc = split_chars("~/dev")
  local tp = left + 2
  for _, ch in ipairs(tc) do
    if ch ~= " " then put(tp, title_row, ch, 7) end
    tp = tp + 1
  end

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
      put(left, r, IC.marker, 8)
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
      if ci >= 3 then
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
    vim.api.nvim_buf_set_extmark(buf, ns, h[1], h[2], { end_col = h[3], hl_group = "SplashG" .. h[4] })
  end
end

local function finish()
  if done then return end
  done = true
  if timer then
    timer:stop()
    if not timer:is_closing() then timer:close() end
    timer = nil
  end
  if saved_guicursor ~= nil then
    vim.o.guicursor = ''
    vim.o.guicursor = saved_guicursor
    saved_guicursor = nil
  end
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
      draw_spiral()
      draw_menu()
    else
      draw_dirpicker()
    end
    draw_footer()
    flush()
  end)
  if not ok then finish() end
end

local function tick()
  if done then return end
  if not (win and vim.api.nvim_win_is_valid(win) and buf and vim.api.nvim_buf_is_valid(buf)) then
    finish()
    return
  end
  local ok = pcall(function()
    local t = uv.hrtime() / 1e9
    local dt = t - last
    if dt > 0.1 then dt = 0.1 end
    last = t
    angle = angle + dt * (P.speed * math.pi / 180)
    clock = clock + dt
    render()
  end)
  if not ok then finish() end
end

local function quit_nvim()
  if timer then
    timer:stop()
    if not timer:is_closing() then timer:close() end
    timer = nil
  end
  if saved_guicursor ~= nil then
    vim.o.guicursor = ''
    vim.o.guicursor = saved_guicursor
    saved_guicursor = nil
  end
  done = true
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
  if cols < 40 or rows < 16 then
    return on_done()
  end
  setup_hl()
  seed_stars()
  scan_dev_dirs()
  done = false
  committed = false
  view = "menu"
  sel = 1
  dir_sel = 1
  chosen_dir = nil
  angle, clock = 0, 0
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
  ns = vim.api.nvim_create_namespace("splash")
  if saved_guicursor == nil then saved_guicursor = vim.o.guicursor end
  vim.o.guicursor = "a:SplashCursor"
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
  pcall(vim.api.nvim_win_set_cursor, win, { rows, 0 })
  render()
  last = uv.hrtime() / 1e9
  timer = uv.new_timer()
  timer:start(0, 50, vim.schedule_wrap(tick))
end

return M
