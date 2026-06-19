vim.o.background = 'dark'
pcall(vim.cmd.colorscheme, 'default')

local BG = '#030509'

local function paint()
  local set = vim.api.nvim_set_hl
  set(0, 'Normal',          { bg = BG })
  set(0, 'NormalNC',        { bg = BG })
  set(0, 'NormalFloat',     { bg = BG })
  set(0, 'SignColumn',      { bg = BG })
  set(0, 'LineNr',          { bg = BG })
  set(0, 'EndOfBuffer',     { bg = BG })
  set(0, 'WinSeparator',    { fg = '#1f2430', bg = BG })
  set(0, 'StatusLine',      { fg = '#d6dbe5', bg = '#0b0f17' })
  set(0, 'NeoTreeNormal',   { bg = BG })
  set(0, 'NeoTreeNormalNC', { bg = BG })
  set(0, 'NeoTreeEndOfBuffer', { bg = BG })
end

paint()
vim.api.nvim_create_autocmd('ColorScheme', { callback = paint })
