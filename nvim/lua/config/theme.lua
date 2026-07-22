vim.o.background = 'dark'

-- catppuccin owns every standard group; this file only paints the workspace's own.
-- init.lua requires it before lazy runs, so the palette is unavailable on the first
-- pass and these literals stand in until the ColorScheme event repaints.
local FALLBACK = {
  base = '#1e1e2e', text = '#cdd6f4',
  green = '#a6e3a1', red = '#f38ba8', overlay0 = '#6c7086',
}

local function palette()
  local ok, p = pcall(function() return require('catppuccin.palettes').get_palette('mocha') end)
  return (ok and p) or FALLBACK
end

local function paint()
  local P = palette()
  local set = vim.api.nvim_set_hl
  set(0, 'WorkspaceDiffAdd', { fg = P.green })
  set(0, 'WorkspaceDiffDel', { fg = P.red })
  set(0, 'WorkspaceDiffDim', { fg = P.overlay0 })
  set(0, 'Cursor',     { fg = P.base, bg = P.text })
  set(0, 'lCursor',    { fg = P.base, bg = P.text })
  set(0, 'TermCursor', { fg = P.base, bg = P.text })
end

paint()
vim.api.nvim_create_autocmd('ColorScheme', { callback = paint })
