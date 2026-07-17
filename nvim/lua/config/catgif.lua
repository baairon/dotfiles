-- Animated pixel-art sprite drawn in the bottom-right of the gitstat panel.
-- Tabby (xterm.js) has no image protocols, so frames are half-block cell art:
-- fg = top pixel, bg = bottom pixel, animated by swapping extmarks on a timer.
-- The sprite is virtual-text overlays inside the panel window (no float), so
-- transparent pixels truly show the changes list underneath.
local M = {}

local ns = vim.api.nvim_create_namespace('catgif')
-- size knobs: cells wide = round(px * scale); below 1 drops pixels nearest-neighbor,
-- so pixel art stays crispest at 1; 0.5 is the clean half step
local CORNER_SCALE = 1
local SPLASH_SCALE = 1
local RIGHT_INSET = 1
local BG_FALLBACK = '#030509'
local HALF = '\226\150\128' -- U+2580 upper half block
local STATE_FILE = vim.fn.stdpath('data') .. '/catgif-current'

local data -- catgif_frames module (nil = disabled)
local models = {} -- per gif+scale cache: { w_cells, h_cells, vruns[frame], cellgrids }
local pair_list, pair_key = {}, {} -- shared (top, bottom) color pairs -> CatGifP<i> groups
local timer
local gif_idx, frame_idx = 1, 1
local active = false -- whether the panel overlay should be drawn/animated
local stopped = false
local did_setup = false

local function usable()
  return data ~= nil and #vim.api.nvim_list_uis() > 0
end

-- the gitstat split tags its buffer, which is how the overlay finds its home
local function find_panel()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) then
      local b = vim.api.nvim_win_get_buf(w)
      if vim.b[b].workspace_gitstat then return w, b end
    end
  end
end

local function live_bg()
  local hl = vim.api.nvim_get_hl(0, { name = 'Normal' })
  if hl.bg then return string.format('#%06x', hl.bg) end
  return BG_FALLBACK
end

local function setup_hl()
  local bg = live_bg()
  for i, pair in ipairs(pair_list) do
    vim.api.nvim_set_hl(0, 'CatGifP' .. i, {
      fg = pair[1] ~= '' and ('#' .. pair[1]) or bg,
      bg = pair[2] ~= '' and ('#' .. pair[2]) or bg,
    })
  end
end

-- scale the pixel grid, pair pixel rows into half-block cells, dedupe (top,
-- bottom) color pairs into the shared CatGifP<i> highlight groups, and coalesce
-- each frame's opaque cells into virt_text run chunks (transparent cells emit
-- nothing); rounding guards keep fractional scales on integer cell counts
local function build_model(gi, scale)
  local mkey = gi .. '|' .. scale
  if models[mkey] then return models[mkey] end
  local gif = data.gifs[gi]
  local pal = gif.palette
  local w_cells = math.floor(gif.width * scale + 0.5)
  local scaled_h = math.floor(gif.height * scale + 0.5)
  local h_cells = math.ceil(scaled_h / 2)
  local vruns, cellgrids = {}, {}
  for f, grid in ipairs(gif.frames) do
    local fruns, cgrid = {}, {}
    for cr = 0, h_cells - 1 do
      local row_top = grid[math.min(gif.height, math.floor(cr * 2 / scale) + 1)]
      local bot_i = math.floor((cr * 2 + 1) / scale) + 1
      local row_bot = (cr * 2 + 1 < scaled_h) and grid[math.min(gif.height, bot_i)] or nil
      local crow = {}
      local run_start, run_ci
      local function flush_run(endcol)
        if run_start and run_ci then
          fruns[#fruns + 1] = {
            row = cr,
            col = run_start,
            text = string.rep(HALF, endcol - run_start),
            hl = 'CatGifP' .. run_ci,
          }
        end
        run_start, run_ci = nil, nil
      end
      for cx = 0, w_cells - 1 do
        local sx = math.min(gif.width, math.floor(cx / scale) + 1)
        local top = pal[row_top[sx]] or ''
        local bottom = row_bot and (pal[row_bot[sx]] or '') or ''
        local ci
        if not (top == '' and bottom == '') then
          local key = top .. '|' .. bottom
          ci = pair_key[key]
          if not ci then
            pair_list[#pair_list + 1] = { top, bottom }
            ci = #pair_list
            pair_key[key] = ci
          end
        end
        crow[cx + 1] = ci and ('CatGifP' .. ci) or false
        if ci ~= run_ci then
          flush_run(cx)
          if ci then run_start, run_ci = cx, ci end
        end
      end
      flush_run(w_cells)
      cgrid[cr + 1] = crow
    end
    vruns[f] = fruns
    cellgrids[f] = cgrid
  end
  models[mkey] = { w_cells = w_cells, h_cells = h_cells, vruns = vruns, cellgrids = cellgrids }
  return models[mkey]
end

local function clear_marks(pbuf)
  pcall(vim.api.nvim_buf_clear_namespace, pbuf, ns, 0, -1)
end

local function draw()
  local pwin, pbuf = find_panel()
  if not pwin then return end
  local model = build_model(gif_idx, CORNER_SCALE)
  local wh = vim.api.nvim_win_get_height(pwin)
  local ww = vim.api.nvim_win_get_width(pwin)
  -- the winbar takes one window row; skip when the sprite would not fit
  if wh - 1 < model.h_cells or ww < model.w_cells + RIGHT_INSET then
    clear_marks(pbuf)
    return
  end
  -- pad the buffer with empty lines so the sprite has rows to anchor to at the
  -- window bottom (gitstat rewrites the lines on refresh; the next tick re-pads)
  local lc = vim.api.nvim_buf_line_count(pbuf)
  if lc < wh then
    local pad = {}
    for i = 1, wh - lc do pad[i] = '' end
    vim.bo[pbuf].modifiable = true
    vim.api.nvim_buf_set_lines(pbuf, lc, lc, false, pad)
    vim.bo[pbuf].modifiable = false
  end
  local wlast = vim.api.nvim_win_call(pwin, function() return vim.fn.line('w$') end)
  local base_row = wlast - model.h_cells -- 0-based first sprite row
  if base_row < 0 then return end
  local base_col = ww - model.w_cells - RIGHT_INSET
  clear_marks(pbuf)
  for _, r in ipairs(model.vruns[frame_idx]) do
    pcall(vim.api.nvim_buf_set_extmark, pbuf, ns, base_row + r.row, 0, {
      virt_text = { { r.text, r.hl } },
      virt_text_win_col = base_col + r.col,
      priority = 100,
    })
  end
end

local function arm()
  if not timer then return end
  timer:start(data.gifs[gif_idx].delays[frame_idx] or 200, 0, function()
    vim.schedule(function()
      if stopped or not active then return end
      frame_idx = (frame_idx % #data.gifs[gif_idx].frames) + 1
      draw()
      arm()
    end)
  end)
end

local function start()
  if stopped then return end
  if not timer then timer = vim.uv.new_timer() end
  arm()
end

function M.stop()
  stopped = true
  if timer then
    pcall(function()
      timer:stop()
      timer:close()
    end)
    timer = nil
  end
end

function M.setup()
  if did_setup then return end
  did_setup = true
  local ok, d = pcall(require, 'config.catgif_frames')
  if not ok or type(d) ~= 'table' or type(d.gifs) ~= 'table' or #d.gifs == 0 then return end
  data = d

  local okr, saved = pcall(vim.fn.readfile, STATE_FILE)
  if okr and saved and saved[1] then
    for i, g in ipairs(data.gifs) do
      if g.name == saved[1] then
        gif_idx = i
        break
      end
    end
  end

  local aug = vim.api.nvim_create_augroup('CatGif', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', { group = aug, callback = setup_hl })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = aug, callback = M.stop })
  vim.api.nvim_create_autocmd('FocusLost', {
    group = aug,
    callback = function()
      if timer then timer:stop() end
    end,
  })
  vim.api.nvim_create_autocmd('FocusGained', {
    group = aug,
    callback = function()
      if not stopped and active then
        draw()
        arm()
      end
    end,
  })
end

-- cell-level view of the current gif for other renderers (the splash draws it
-- into its own grid): grids[frame][row][col] = highlight group name or false
function M.sprite()
  if not did_setup then M.setup() end
  if not data then return nil end
  local model = build_model(gif_idx, SPLASH_SCALE)
  setup_hl()
  return {
    w_cells = model.w_cells,
    h_cells = model.h_cells,
    delays = data.gifs[gif_idx].delays,
    grids = model.cellgrids,
  }
end

function M.show()
  if stopped then return end
  if not did_setup then M.setup() end
  if not usable() then return end
  active = true
  build_model(gif_idx, CORNER_SCALE)
  setup_hl()
  frame_idx = math.min(frame_idx, #data.gifs[gif_idx].frames)
  draw()
  start()
end

function M.hide()
  active = false
  if timer then timer:stop() end
  local _, pbuf = find_panel()
  if pbuf then clear_marks(pbuf) end
end

function M.next()
  if not did_setup then M.setup() end
  if not usable() then return end
  gif_idx = (gif_idx % #data.gifs) + 1
  frame_idx = 1
  build_model(gif_idx, CORNER_SCALE)
  setup_hl()
  pcall(vim.fn.writefile, { data.gifs[gif_idx].name }, STATE_FILE)
  if active then
    draw()
    if timer then timer:stop() end
    start()
  end
end

return M
