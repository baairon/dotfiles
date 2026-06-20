local M = {}

local enabled = true

local BANNER = {
  [['|.   '|' '||''''|   ..|''||   '||'  '|' '||' '||    ||' ]],
  [[ |'|   |   ||  .    .|'    ||   '|.  .'   ||   |||  |||  ]],
  [[ | '|. |   ||''|    ||      ||   ||  |    ||   |'|..'||  ]],
  [[ |   |||   ||       '|.     ||    |||     ||   | '|' ||  ]],
  [[.|.   '|  .||.....|  ''|...|'      |     .||. .|. | .||. ]],
}

local PALETTE = { "#8bb8e0", "#a0c8ea", "#b4d6f2", "#c6e0f7", "#d6eafa", "#e4f0fc", "#f0f7fe", "#ffffff" }
local BG_FALLBACK = "#030509"
local function get_bg()
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = "Normal" })
  if ok and hl and hl.bg then return string.format("#%06x", hl.bg) end
  return BG_FALLBACK
end
local RAMP = " .`,:;!^+*coO0@#"
local STAR_RAMP = " .:-=+*coO0#@"

local IC = {
  play    = string.char(0xEF, 0x81, 0x8B),
  history = string.char(0xEF, 0x87, 0x9A),
  folder  = string.char(0xEF, 0x81, 0xBC),
  power   = string.char(0xEF, 0x80, 0x91),
  dir     = string.char(0xEF, 0x81, 0xBB),
  marker  = string.char(0xE2, 0x9D, 0xAF),
}

local MENU = {
  { icon = IC.play,    label = "Launch",       action = "launch", key = "l" },
  { icon = IC.history, label = "Last Session", action = "last",   key = "s" },
  { icon = IC.folder,  label = "New Session",  action = "new",    key = "n" },
  { icon = IC.power,   label = "Quit",         action = "quit",   key = "q" },
}

local P = { arms = 3, stars = 912, speed = 20, size = 55, twist = 0.39, noise = 0.35, glow = 0.32, twinkle = 0.55 }
local SPIN_S = 1.2
local IMPLODE_S = 2.25
local EXPLODE_S = 4.8
local FRAME = 50
local TAU = math.pi * 2
local STATE_FILE = vim.fn.stdpath("data") .. "/splash_last_dir"
local DEV_DIR = vim.fn.expand(vim.env.NVIM_DEV_DIR or "~/dev")

local function split_chars(s)
  local t = {}
  for c in s:gmatch("[\1-\127\194-\244][\128-\191]*") do t[#t + 1] = c end
  return t
end

local BANNER_C = {}
local BANNER_W = 0
for i = 1, #BANNER do
  BANNER_C[i] = split_chars(BANNER[i])
  if #BANNER_C[i] > BANNER_W then BANNER_W = #BANNER_C[i] end
end

local uv = vim.uv or vim.loop
local cols, rows = 0, 0
local chargrid, colgrid, acc = {}, {}, {}
local win, buf, ns, timer
local angle, clock, last = 0, 0, 0
local mode = "idle"
local warp_t0, warp_angle, warp_clock = 0, 0, 0
local on_done_cb, done = nil, false
local saved_guicursor
local gstars, wstars = {}, {}
local sel = 1
local chosen_dir = nil
local view = "menu"
local dev_dirs = {}
local dir_sel = 1
local animate = true
local committed = false

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

local function clear()
  for i = 1, rows * cols do chargrid[i] = " "; colgrid[i] = 0 end
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
  for i = 1, 8 do
    vim.api.nvim_set_hl(0, "SplashG" .. i, { fg = PALETTE[i], bg = BG })
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

local function render_spiral(rotation, tMs, bright)
  bright = bright or 1
  local cx, cy = cols / 2, rows / 2
  local maxR = math.min(cols * 0.5, rows) * (P.size / 100) * 0.96
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

local function seed_explosion()
  reseed(4242)
  local n = math.max(300, math.min(2000, P.stars))
  wstars = {}
  for i = 1, n do
    local a = rng() * TAU
    local rad = 0.25 + rng() * 0.75
    local z0 = 0.85 + rng() * 0.15
    local z = z0 - (rng() ^ 2.2) * (z0 - 0.08)
    wstars[i] = { x = math.cos(a) * rad, y = math.sin(a) * rad, z0 = z0, z = z, px = nil, py = nil }
  end
end

local function respawn(s)
  local a = rng() * TAU
  local rad = 0.25 + rng() * 0.75
  local z0 = 0.85 + rng() * 0.15
  s.x = math.cos(a) * rad
  s.y = math.sin(a) * rad
  s.z0 = z0
  s.z = z0
  s.px = nil
  s.py = nil
end

local function draw_streak(x1, y1, x0, y0, headCh, col)
  local dimcol = math.max(2, col - 2)
  local dx = math.abs(x1 - x0)
  local dy = math.abs(y1 - y0)
  local sx = x0 < x1 and 1 or -1
  local sy = y0 < y1 and 1 or -1
  local err = dx - dy
  local x, y, guard = x0, y0, 0
  while guard < 48 do
    guard = guard + 1
    if x == x1 and y == y1 then break end
    put(x, y, ":", dimcol)
    local e2 = 2 * err
    if e2 > -dy then err = err - dy; x = x + sx end
    if e2 < dx then err = err + dx; y = y + sy end
  end
  put(x1, y1, headCh, col)
end

local function render_warp(localT, dt)
  local cx, cy = cols / 2, rows / 2
  if localT < SPIN_S then
    local u = localT / SPIN_S
    warp_angle = warp_angle + dt * (P.speed * math.pi / 180) * (1 + 3 * u)
    warp_clock = warp_clock + dt
    render_spiral(warp_angle, warp_clock * 1000, 1)
  elseif localT < IMPLODE_S then
    local te = localT - SPIN_S
    local u = te / (IMPLODE_S - SPIN_S)
    local sizeScale = 1 - (u ^ 1.9) * 0.94
    local bright = 1 - (u ^ 3) * 0.4
    warp_angle = warp_angle + dt * (P.speed * math.pi / 180) * (4 + 4 * u * u)
    warp_clock = warp_clock + dt
    local saved = P.size
    P.size = saved * sizeScale
    render_spiral(warp_angle, warp_clock * 1000, bright)
    P.size = saved
  else
    local base = cols * 0.55
    local te = localT - IMPLODE_S
    local localE = math.min(1, te / (EXPLODE_S - IMPLODE_S))
    local speed = 0.28 + 1.5 * localE * localE
    local ep = math.min(1, te / 0.45)
    local expand = 1 - (1 - ep) * (1 - ep)
    local fieldScale = base * (0.04 + 0.96 * expand)
    local fadeIn = math.min(1, te / 0.25)
    local fadeOut = math.min(1, (EXPLODE_S - localT) / 0.5)
    local fade = math.min(fadeIn, fadeOut)
    local rlen = #STAR_RAMP
    for i = 1, #wstars do
      local s = wstars[i]
      s.z = s.z - speed * dt
      if s.z <= 0.06 then respawn(s) end
      local k = (1 / s.z - 1 / s.z0)
      local sx = math.floor(cx + s.x * k * fieldScale + 0.5)
      local sy = math.floor(cy + s.y * k * fieldScale * 0.5 + 0.5)
      local n = math.min(1, (1 - s.z) * 1.25) * fade
      if n <= 0.02 then
        s.px, s.py = sx, sy
      else
        local hi = math.min(rlen - 1, 1 + math.floor(n * (rlen - 1)))
        local headCh = STAR_RAMP:sub(hi + 1, hi + 1)
        local col = math.min(8, 2 + math.floor(n * 6))
        if s.px ~= nil and (s.px ~= sx or s.py ~= sy) then
          draw_streak(sx, sy, s.px, s.py, headCh, col)
        else
          put(sx, sy, headCh, col)
        end
        s.px, s.py = sx, sy
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

local function scan_dev_dirs()
  dev_dirs = {}
  if vim.fn.isdirectory(DEV_DIR) == 0 then return end
  local entries = vim.fn.readdir(DEV_DIR)
  table.sort(entries)
  for _, e in ipairs(entries) do
    if not e:match("^%.") and vim.fn.isdirectory(DEV_DIR .. "/" .. e) == 1 then
      dev_dirs[#dev_dirs + 1] = e
    end
  end
end

local function draw_banner()
  local left = math.floor((cols - BANNER_W) / 2)
  local top = math.max(1, math.floor((rows - 18) / 2))
  for r = 1, #BANNER_C do
    local line = BANNER_C[r]
    for c = 1, #line do
      local ch = line[c]
      if ch ~= " " then put(left + c - 1, top + r - 1, ch, 8) end
    end
  end
end

local function draw_menu()
  local menu_w = 26
  local left = math.floor((cols - menu_w) / 2)
  local btop = math.max(1, math.floor((rows - 18) / 2))
  local mtop = btop + #BANNER_C + 4
  for i = 1, #MENU do
    local r = mtop + (i - 1) * 2
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

local function draw_dirpicker()
  local menu_w = 26
  local left = math.floor((cols - menu_w) / 2)
  local btop = math.max(1, math.floor((rows - 18) / 2))
  local mtop = btop + #BANNER_C + 4
  local title = "~/dev"
  local tc = split_chars(title)
  local list_top = mtop + 2
  local max_vis = math.max(1, math.floor((rows - list_top - 1) / 2))
  max_vis = math.min(max_vis, #dev_dirs)
  local scroll = math.max(0, dir_sel - max_vis)
  
  local tp = left + 2
  for _, ch in ipairs(tc) do
    if ch ~= " " then put(tp, mtop, ch, 7) end
    tp = tp + 1
  end
  for i = 1, max_vis do
    local di = i + scroll
    if di > #dev_dirs then break end
    local r = list_top + (i - 1) * 2
    if r >= rows then break end
    local on = (di == dir_sel)
    if on then put(left, r, IC.marker, 8) end
    put(left + 2, r, IC.dir, on and 8 or 5)
    local nc = split_chars(dev_dirs[di])
    local cp = left + 5
    for j = 1, #nc do
      if nc[j] ~= " " then put(cp, r, nc[j], on and 8 or 5) end
      cp = cp + 1
    end
  end
end

local function flush()
  local lines, hls = {}, {}
  for r = 0, rows - 1 do
    local rowchars, bytepos = {}, 0
    local run_start, run_ci = 0, nil
    local b = r * cols
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
      bytepos = bytepos + #ch
    end
    if run_ci then hls[#hls + 1] = { r, run_start, bytepos, run_ci } end
    lines[r + 1] = table.concat(rowchars)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
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
    clear()
    if mode == "idle" then
      angle = angle + dt * (P.speed * math.pi / 180)
      clock = clock + dt
      draw_banner()
      if view == "menu" then
        draw_menu()
      else
        draw_dirpicker()
      end
    else
      local localT = t - warp_t0
      if localT >= EXPLODE_S then finish(); return end
      render_warp(localT, dt)
    end
    flush()
  end)
  if not ok then finish() end
end

local function start_warp()
  if mode == "warp" then
    warp_t0 = uv.hrtime() / 1e9 - (EXPLODE_S - 0.25)
    return
  end
  mode = "warp"
  warp_t0 = uv.hrtime() / 1e9
  warp_angle = angle
  warp_clock = clock
  seed_explosion()
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
  if mode ~= "idle" then return end
  if view == "menu" then
    sel = ((sel - 1 + d) % #MENU) + 1
  elseif #dev_dirs > 0 then
    dir_sel = ((dir_sel - 1 + d) % #dev_dirs) + 1
  end
end

local function commit()
  committed = true
  if animate then start_warp() else vim.schedule(finish) end
end

local function activate()
  if mode == "warp" then
    warp_t0 = uv.hrtime() / 1e9 - (EXPLODE_S - 0.25)
    return
  end
  if mode ~= "idle" then return end
  if view == "dirs" then
    if #dev_dirs > 0 and dir_sel >= 1 and dir_sel <= #dev_dirs then
      chosen_dir = DEV_DIR .. "/" .. dev_dirs[dir_sel]
      commit()
    end
    return
  end
  local item = MENU[sel]
  if item.action == "quit" then
    quit_nvim()
  elseif item.action == "launch" then
    commit()
  elseif item.action == "last" then
    local dir = load_last_dir()
    if dir then
      chosen_dir = dir
      commit()
    end
  elseif item.action == "new" then
    scan_dev_dirs()
    if #dev_dirs > 0 then
      view = "dirs"
      dir_sel = 1
    end
  end
end

local function go_back()
  if mode ~= "idle" then return end
  if view == "dirs" then
    view = "menu"
    return
  end
  finish()
end

local function shortcut(key)
  if mode ~= "idle" or view ~= "menu" then return end
  for i = 1, #MENU do
    if MENU[i].key == key then
      sel = i
      activate()
      return
    end
  end
end

function M.show(on_done, opts)
  if not enabled or #vim.api.nvim_list_uis() == 0 then
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
  animate = not (opts and opts.animate == false)
  mode = "idle"
  view = (opts and opts.view == "dirs" and #dev_dirs > 0) and "dirs" or "menu"
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
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
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
  kmap("s", function() shortcut("s") end)
  kmap("n", function() shortcut("n") end)
  pcall(vim.api.nvim_win_set_cursor, win, { rows, 0 })
  last = uv.hrtime() / 1e9
  timer = uv.new_timer()
  timer:start(0, FRAME, vim.schedule_wrap(tick))
end

return M
