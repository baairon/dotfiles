vim.o.background = 'dark'

-- catppuccin owns every standard group; this file only paints the workspace's own.
-- init.lua requires it before lazy runs, so the palette is unavailable on the first
-- pass and these literals stand in until the ColorScheme event repaints.
local FALLBACK = {
  base = '#1e1e2e', text = '#cdd6f4', rosewater = '#f5e0dc',
  green = '#a6e3a1', red = '#f38ba8', overlay0 = '#6c7086', blue = '#89b4fa',
  surface0 = '#313244', surface1 = '#45475a',
  subtext0 = '#a6adc8', overlay1 = '#7f849c', lavender = '#b4befe',
}

local function palette()
  local ok, p = pcall(function() return require('catppuccin.palettes').get_palette('mocha') end)
  return (ok and p) or FALLBACK
end

-- catppuccin runs transparent, so it draws no background of its own and the diff groups it
-- ships come through as bare foreground tints. A side-by-side diff has to read as blocks,
-- which means painting real backgrounds here. Nothing can sample what the terminal actually
-- draws, so the mix target has to be named rather than measured: Tabby's background is
-- mocha's own base, so blending against base mixes these bands into the colour genuinely
-- behind them instead of into a stand-in for it.
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
  set(0, 'WorkspaceDiffAddBg', { bg = blend(P.green, P.base, 0.26) })
  set(0, 'WorkspaceDiffDelBg', { bg = blend(P.red, P.base, 0.26) })
  set(0, 'WorkspaceDiffHunk',  { fg = P.blue })

  -- nvim's native diff mode, which gitsigns' <leader>hd and diffview both render through.
  -- DiffChange bands the whole line that changed and DiffText marks the span inside it that
  -- actually differs, so DiffText has to sit clearly above its own line. No bold anywhere:
  -- CozetteVector has no bold face and fakes it by smearing.
  set(0, 'DiffAdd',    { bg = blend(P.green, P.base, 0.26) })
  set(0, 'DiffDelete', { bg = blend(P.red, P.base, 0.26), fg = P.overlay0 })
  set(0, 'DiffChange', { bg = blend(P.overlay0, P.base, 0.18) })
  set(0, 'DiffText',   { bg = blend(P.blue, P.base, 0.40) })
  -- Use the same rosewater cursor in every pane.
  set(0, 'Cursor',     { fg = P.rosewater, bg = P.rosewater })
  set(0, 'lCursor',    { fg = P.rosewater, bg = P.rosewater })
  set(0, 'TermCursor', { fg = P.rosewater, bg = P.rosewater })

  -- catppuccin's Visual only kept a bold style, which this config strips, and its
  -- CursorLine is darkened toward base until it vanishes on mocha. Real bands here.
  set(0, 'Visual',     { bg = P.surface1 })
  set(0, 'VisualNOS',  { bg = P.surface1 })
  set(0, 'CursorLine', { bg = P.surface0 })

  -- Panel chrome. Every panel's top edge is a rule this config draws in its winbar, and the
  -- sides are the grid nvim draws between splits, so both are painted the same colour here
  -- rather than left to drift apart. Backgrounds on none of them: catppuccin runs transparent
  -- so Tabby's vibrancy shows through, and a filled header would seal that off one row at a
  -- time. No bold either, per CozetteVector.
  set(0, 'WinSeparator',       { fg = P.surface1 })
  set(0, 'WorkspacePanelRule', { fg = P.surface1 })
  set(0, 'WorkspacePanelTitle',{ fg = P.subtext0 })
  set(0, 'WorkspacePanelIcon', { fg = P.lavender })

  -- Exactly one panel is lit at a time, which is what makes four labelled boxes read as a
  -- cockpit rather than as four things all asking for attention. The rule keeps its weight in
  -- both states: it is structure, not focus.
  set(0, 'WorkspacePanelTitleNC', { fg = P.overlay0 })
  set(0, 'WorkspacePanelIconNC',  { fg = P.overlay0 })

  -- neo-tree paints its own "(n hidden items)" line italic, which catppuccin's no_italic never
  -- reaches because neo-tree defines the group itself. xterm.js keeps the italic flag in the
  -- cell's background word, so with Tabby's vibrancy an italic cell draws a background rect out
  -- of a fully transparent colour and forces it opaque: a black box exactly the width of the
  -- text. Same reason nothing else here carries a style. The foreground goes with it: neo-tree
  -- derives that one by fading Normal against an assumed black background, which lands far
  -- below anything else in the panel.
  set(0, 'NeoTreeMessage', { fg = P.overlay0 })

  -- The panel's tab strip. The active tab is marked by an accent bar rather than by a filled
  -- background, which is the only way it can stand out on a transparent ground, and the quiet
  -- tabs are separated from each other by a divider the same weight as the rule.
  set(0, 'WorkspaceTabActive',   { fg = P.text })
  set(0, 'WorkspaceTabAccent',   { fg = P.lavender })
  set(0, 'WorkspaceTabInactive', { fg = P.overlay1 })
  set(0, 'WorkspaceTabRule',     { fg = P.surface1 })
  -- the terminal panel has no title, only tabs, so its active tab is what dims when the panel
  -- loses focus; the bar stays drawn either way, so which tab it is on is still readable
  set(0, 'WorkspaceTabActiveNC', { fg = P.overlay1 })
  set(0, 'WorkspaceTabAccentNC', { fg = P.overlay0 })
end

paint()
vim.api.nvim_create_autocmd('ColorScheme', {
  group = vim.api.nvim_create_augroup('WorkspaceTheme', { clear = true }),
  callback = paint,
})
-- smear and catppuccin load after this file; paint again once the session is up
-- so Cursor / TermCursor stay rosewater instead of catppuccin's base-on-base bar.
vim.api.nvim_create_autocmd('VimEnter', {
  callback = function()
    vim.schedule(paint)
  end,
})
