vim.o.background = 'dark'

-- catppuccin owns every standard group; this file only paints the workspace's own.
-- init.lua requires it before lazy runs, so the palette is unavailable on the first
-- pass and these literals stand in until the ColorScheme event repaints.
local FALLBACK = {
  base = '#1e1e2e', text = '#cdd6f4',
  green = '#a6e3a1', red = '#f38ba8', overlay0 = '#6c7086', blue = '#89b4fa',
  crust = '#11111b',
}

local function palette()
  local ok, p = pcall(function() return require('catppuccin.palettes').get_palette('mocha') end)
  return (ok and p) or FALLBACK
end

-- catppuccin runs transparent, so it draws no background of its own and the diff groups it
-- ships come through as bare foreground tints. A side-by-side diff has to read as blocks,
-- which means painting real backgrounds here. The mix target is crust rather than base:
-- nothing can sample what the terminal actually draws, and crust is the palette entry
-- nearest Tabby's #030509, so the blend keeps its own hue instead of being pulled grey by a
-- surface colour that is never on screen.
local function blend(fg, bg, alpha)
  local function rgb(h) return tonumber(h:sub(2, 3), 16), tonumber(h:sub(4, 5), 16), tonumber(h:sub(6, 7), 16) end
  local fr, fg_, fb = rgb(fg)
  local br, bg_, bb = rgb(bg)
  local function mix(a, b) return math.floor(a * alpha + b * (1 - alpha) + 0.5) end
  return string.format('#%02x%02x%02x', mix(fr, br), mix(fg_, bg_), mix(fb, bb))
end

local function paint()
  local P = palette()
  local set = vim.api.nvim_set_hl
  set(0, 'WorkspaceDiffAdd', { fg = P.green })
  set(0, 'WorkspaceDiffDel', { fg = P.red })
  set(0, 'WorkspaceDiffDim', { fg = P.overlay0 })

  -- The workspace's own diff panel: full-width bands behind added and removed lines, and a
  -- quieter accent on the @@ hunk headers that separate them. Background only, so the diff
  -- syntax's own foreground still comes through on top of them.
  set(0, 'WorkspaceDiffAddBg', { bg = blend(P.green, P.crust, 0.26) })
  set(0, 'WorkspaceDiffDelBg', { bg = blend(P.red, P.crust, 0.26) })
  set(0, 'WorkspaceDiffHunk',  { fg = P.blue })

  -- nvim's native diff mode, which gitsigns' <leader>hd and diffview both render through.
  -- DiffChange bands the whole line that changed and DiffText marks the span inside it that
  -- actually differs, so DiffText has to sit clearly above its own line. No bold anywhere:
  -- CozetteVector has no bold face and fakes it by smearing.
  set(0, 'DiffAdd',    { bg = blend(P.green, P.crust, 0.26) })
  set(0, 'DiffDelete', { bg = blend(P.red, P.crust, 0.26), fg = P.overlay0 })
  set(0, 'DiffChange', { bg = blend(P.overlay0, P.crust, 0.18) })
  set(0, 'DiffText',   { bg = blend(P.blue, P.crust, 0.40) })
  set(0, 'Cursor',     { fg = P.base, bg = P.text })
  set(0, 'lCursor',    { fg = P.base, bg = P.text })
  set(0, 'TermCursor', { fg = P.base, bg = P.text })
end

paint()
vim.api.nvim_create_autocmd('ColorScheme', { callback = paint })
