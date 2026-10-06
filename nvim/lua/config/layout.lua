local M = {}

local terminal = require('config.workspace.terminal')
local git_bash = terminal.git_bash
local panel_bufs = terminal.panel_bufs
local term_name = terminal.term_name
local spawn_term = terminal.spawn_term
local jump = terminal.jump
local add_term_to_panel = terminal.add_term_to_panel
local hop_or_close = terminal.hop_or_close
local close_tab = terminal.close_tab
local jump_to_tab = terminal.jump_to_tab

local quitting = false
local group = vim.api.nvim_create_augroup('WorkspaceLayout', { clear = true })
local function autocmd(events, opts)
  opts.group = group
  return vim.api.nvim_create_autocmd(events, opts)
end

-- every glyph is verified present in fonts/CozetteVector.ttf
local IC = {
  bar    = string.char(0xE2, 0x96, 0x8D), -- U+258D left three-eighths block
  vsep   = string.char(0xE2, 0x94, 0x82), -- U+2502 box drawings light vertical
  term   = string.char(0xEF, 0x92, 0x89), -- U+F489 terminal
  folder = string.char(0xEF, 0x81, 0xBC), -- U+F07C folder-open
  branch = string.char(0xEE, 0x82, 0xA0), -- U+E0A0 branch
}

local function build_winbar(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local ok, panel = pcall(function() return vim.b[buf].workspace_panel end)
  if not ok or not panel then return nil end
  local segs = {}
  local bufs = panel_bufs(panel)
  local termtotal, seen = {}, {}
  for _, b in ipairs(bufs) do
    if vim.bo[b].buftype == 'terminal' then
      local nm = term_name(b)
      termtotal[nm] = (termtotal[nm] or 0) + 1
    end
  end
  local prev_active = false
  for i, b in ipairs(bufs) do
    local active = (b == buf)
    local label, icon, icon_hl = nil, '', nil
    if vim.bo[b].buftype == 'terminal' then
      local nm = term_name(b)
      seen[nm] = (seen[nm] or 0) + 1
      label = (termtotal[nm] > 1) and (nm .. ' ' .. seen[nm]) or nm
      icon = IC.term .. ' '
    else
      local n = vim.api.nvim_buf_get_name(b)
      if n ~= '' then
        local basename = vim.fn.fnamemodify(n, ':t')
        local ext = vim.fn.fnamemodify(n, ':e')
        local has_devicons, devicons = pcall(require, 'nvim-web-devicons')
        if has_devicons then
          local ic, ihl = devicons.get_icon(basename, ext, { default = true })
          if ic then icon, icon_hl = ic .. ' ', ihl end
        end
        label = basename
      else
        -- the statusline names this buffer too, and the two rows should not disagree
        label = require('config.chrome').title(b) or 'Untitled'
      end
    end
    -- a divider only where two quiet tabs meet: beside the active tab its own accent bar is
    -- already the boundary, and a second mark there would read as clutter
    if i > 1 and not active and not prev_active then
      segs[#segs + 1] = { IC.vsep, 'WorkspaceTabRule' }
    end
    -- this panel has no title of its own, so its active tab is what carries the focus state;
    -- the quiet tabs are already at the dim end and do not move
    local chrome = require('config.chrome')
    local text_hl = active and chrome.lit('WorkspaceTabActive', win) or 'WorkspaceTabInactive'
    -- the click region wraps the whole cell, accent bar and icon included, so a tab stays
    -- clickable across everything that reads as part of it
    segs[#segs + 1] = { code = '%' .. b .. '@v:lua.WorkspaceTabClick@' }
    segs[#segs + 1] = active and { IC.bar, chrome.lit('WorkspaceTabAccent', win) } or { ' ' }
    -- the active tab carries its file type's own icon colour; the quiet ones stay one tone, so
    -- the strip reads as a single dim row with one thing lit in it
    segs[#segs + 1] = { icon, active and icon_hl or text_hl }
    segs[#segs + 1] = { label .. ' ', text_hl }
    segs[#segs + 1] = { code = '%X' }
    prev_active = active
  end
  return require('config.chrome').rule(win, segs)
end

-- Which header a window gets is decided by what its buffer already advertises, so nothing has
-- to be registered anywhere: the two trees are neo-tree's, the tab strip is the workspace's,
-- and the changes panel paints its own out of gitstat, which is where the counts live.
local function set_winbar(win)
  if not vim.api.nvim_win_is_valid(win) then return end
  local buf = vim.api.nvim_win_get_buf(win)
  local chrome = require('config.chrome')
  local ok, src = pcall(function() return vim.b[buf].neo_tree_source end)
  if ok and src == 'filesystem' then
    -- neo-tree hides the root node, so without this the working tree is nowhere named
    chrome.set(win, chrome.header(win, IC.folder, vim.fn.fnamemodify(vim.fn.getcwd(), ':t')))
  elseif ok and src == 'git_status' then
    local branch = require('config.gitstat').branch
    chrome.set(win, chrome.header(win, IC.branch, branch or 'git'))
  elseif vim.b[buf].workspace_gitstat then
    -- gitstat draws its own, because the counts on the right are its to know
    require('config.gitstat').redraw_header()
  else
    local wb = build_winbar(win)
    if wb then chrome.set(win, wb) end
  end
end

local headers_pending = false
local function refresh_winbars()
  if headers_pending or quitting then return end
  headers_pending = true
  vim.schedule(function()
    headers_pending = false
    if quitting then return end
    for _, win in ipairs(vim.api.nvim_list_wins()) do set_winbar(win) end
  end)
end
M.refresh_winbars = refresh_winbars

function _G.WorkspaceTabClick(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local ok, panel = pcall(function() return vim.b[bufnr].workspace_panel end)
  if not ok or not panel then return end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local wb = vim.api.nvim_win_get_buf(w)
    local okp, p = pcall(function() return vim.b[wb].workspace_panel end)
    if okp and p == panel then
      vim.api.nvim_win_set_buf(w, bufnr)
      vim.api.nvim_set_current_win(w)
      return
    end
  end
end

function M.editor_winid()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ok, v = pcall(vim.api.nvim_win_get_var, win, 'workspace_winpanel')
    if ok and v == 'top' and vim.api.nvim_win_is_valid(win) then return win end
  end
  return 0
end

function M.build_layout()
  spawn_term(git_bash(), 'top')
  local top_win = vim.api.nvim_get_current_win()

  pcall(vim.cmd, 'Neotree show filesystem left')
  pcall(vim.cmd, 'Neotree show git_status right')

  local function focus_top()
    if vim.api.nvim_win_is_valid(top_win) then
      vim.api.nvim_set_current_win(top_win)
      vim.cmd('startinsert')
    end
  end

  local gitstat = require('config.gitstat')
  local tries = 0
  local function settle()
    if quitting or not vim.api.nvim_win_is_valid(top_win) then return end
    tries = tries + 1
    if gitstat.rail_win() then
      pcall(gitstat.open)
      pcall(gitstat.refresh)
      -- neo-tree finishes drawing on its own schedule, so the trees' headers are painted here
      -- rather than left to whichever BufWinEnter happened to fire while they were still empty
      refresh_winbars()
      focus_top()
    elseif tries < 25 then
      vim.defer_fn(settle, 30)
    else
      focus_top()
    end
  end
  vim.defer_fn(settle, 30)
end

function M.lazygit_float()
  if vim.fn.executable('lazygit') == 0 then
    vim.notify('lazygit not on PATH (winget install JesseDuffield.lazygit)', vim.log.levels.WARN)
    return
  end
  local width  = math.floor(vim.o.columns * 0.9)
  local height = math.floor(vim.o.lines * 0.9)
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width, height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal', border = 'rounded', title = ' lazygit ',
  })
  vim.fn.jobstart({ 'lazygit' }, {
    term = true,
    on_exit = function()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end,
  })
  vim.cmd('startinsert')
end

local diff = require('config.workspace.diff')
M.open_file_diff = diff.open_file_diff
M.diff_markdown_preview = diff.diff_markdown_preview
M.diff_close_to_file = diff.diff_close_to_file

local function is_aux(win)
  -- Only the neo-tree git rail is skipped by <A-o>. The gitstat "changes" panel is
  -- intentionally cyclable so you can land on it and press <CR> to diff a file.
  local buf = vim.api.nvim_win_get_buf(win)
  local ok, src = pcall(function() return vim.b[buf].neo_tree_source end)
  return ok and src == 'git_status'
end

function M.cycle_panes(dir)
  dir = dir or 1
  local cur, wins = vim.api.nvim_get_current_win(), {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative == '' and not is_aux(w) then
      wins[#wins + 1] = w
    end
  end
  if #wins < 2 then return end
  local idx = 1
  for i, w in ipairs(wins) do if w == cur then idx = i end end
  vim.api.nvim_set_current_win(wins[((idx - 1 + dir) % #wins) + 1])
end

local map = vim.keymap.set
map('n', '<leader>gg', M.lazygit_float,  { desc = 'Lazygit (work tree)' })
map('n', '<leader>1',  function() jump('top') end,   { desc = 'Go to terminal' })
map('n', '<leader>tr', function() M.cycle_panes(1) end, { desc = 'Rotate between panels' })

M._close_tab = close_tab
M._add_term = add_term_to_panel

map('n', '<leader>t', add_term_to_panel, { desc = 'New terminal tab (panel)' })
map('n', '<A-t>', add_term_to_panel, { desc = 'New terminal tab (panel)' })
map('t', '<A-t>', '<C-\\><C-n><cmd>lua require("config.layout")._add_term()<CR>', { desc = 'New terminal tab (panel)' })
map('n', '<A-w>', close_tab, { desc = 'Close tab (panel)' })
map('t', '<A-w>', '<C-\\><C-n><cmd>lua require("config.layout")._close_tab()<CR>', { desc = 'Close tab (panel)' })
map('n', '<A-o>', function() M.cycle_panes(1) end, { desc = 'Cycle panes (skip git rail/stats)' })
map('t', '<A-o>', '<C-\\><C-n><cmd>lua require("config.layout").cycle_panes(1)<CR>', { desc = 'Cycle panes (skip git rail/stats)' })

M._jump_to_tab = jump_to_tab

for i = 1, 9 do
  local fn = function() jump_to_tab(i) end
  map('n', '<A-' .. i .. '>', fn, { desc = 'Tab ' .. i .. ' (panel)' })
  map('t', '<A-' .. i .. '>', '<C-\\><C-n><cmd>lua require("config.layout")._jump_to_tab(' .. i .. ')<CR>', { desc = 'Tab ' .. i .. ' (panel)' })
end

local function osc7_path(seq)
  local uri = seq:match('\27%]7;(file://[^\7\27]*)')
  if not uri then return nil end
  local path = uri:gsub('^file://[^/]*', '')
  path = (vim.uri_decode and vim.uri_decode(path)) or path
  path = path:gsub('^/(%a)/', function(d) return d:upper() .. ':/' end)
  return path
end

autocmd('TermRequest', {
  callback = function(args)
    local seq = type(args.data) == 'table' and args.data.sequence or args.data
    if type(seq) ~= 'string' then return end
    local path = osc7_path(seq)
    if not path or vim.fn.isdirectory(path) == 0 then return end
    if args.buf and args.buf ~= vim.api.nvim_get_current_buf() then return end
    if vim.fs.normalize(vim.fn.getcwd()) == vim.fs.normalize(path) then return end
    pcall(vim.cmd, 'cd ' .. vim.fn.fnameescape(path))
  end,
})

local mode_pending = false
local function sync_terminal_mode()
  if mode_pending or quitting then return end
  mode_pending = true
  vim.schedule(function()
    mode_pending = false
    if quitting then return end
    local mode = vim.api.nvim_get_mode().mode
    if vim.bo.buftype == 'terminal' then
      if mode ~= 't' then vim.cmd('startinsert') end
    elseif mode:match('^[it]') then
      vim.cmd('stopinsert')
    end
  end)
end

autocmd({ 'BufEnter', 'WinEnter', 'TermOpen' }, {
  callback = sync_terminal_mode,
})

autocmd('FocusGained', {
  callback = function()
    if vim.bo.buftype == 'terminal' then sync_terminal_mode() end
  end,
})

autocmd('BufWinEnter', {
  callback = function(args)
    local buf = args.buf
    if vim.bo[buf].buftype == '' and vim.api.nvim_buf_get_name(buf) ~= ''
      and not vim.b[buf].workspace_panel then
      local wp = vim.w.workspace_winpanel
      if wp then vim.b[buf].workspace_panel = wp end
    end
    refresh_winbars()
  end,
})

-- A header's rule is measured against its window, and the tree's title is the working tree's
-- name, so both go stale on their own without anything entering a buffer. FocusGained is here
-- because a branch switched in another terminal is the common way the git rail's title changes.
autocmd({ 'WinResized', 'VimResized', 'DirChanged', 'FocusGained' }, {
  callback = function() refresh_winbars() end,
})

-- A resize is not just new geometry: the pty reflows the frame it has already emitted, which
-- rewraps the previous draw into a staircase of stale cells. nvim repaints only what its own
-- model says changed, so those leftovers survive underneath the new frame. Forcing one
-- clear-and-repaint after the resizes stop is what Ctrl-L does by hand. Trailing edge,
-- because a settling tab fires several of these and a repaint mid-burst just ghosts again.
-- VimResized only: splits inside nvim never go through the pty.
local repaint = (vim.uv or vim.loop).new_timer()
autocmd('VimResized', {
  callback = function()
    if quitting or repaint:is_closing() then return end
    repaint:stop()
    repaint:start(80, 0, vim.schedule_wrap(function()
      if not quitting then pcall(vim.cmd, 'redraw!') end
    end))
  end,
})

-- Focus moves far more often than anything else here, and a full refresh walks every window
-- and, per panel, every buffer. Only two headers can change state on a window switch, so only
-- those two are repainted. set_winbar guards on validity, so a window closed since the last
-- switch is a no-op.
local last_win
autocmd('WinEnter', {
  callback = function()
    local cur = vim.api.nvim_get_current_win()
    if last_win and last_win ~= cur then set_winbar(last_win) end
    set_winbar(cur)
    last_win = cur
  end,
})



autocmd('VimLeavePre', {
  callback = function()
    quitting = true
    if not repaint:is_closing() then repaint:stop(); repaint:close() end
  end,
})

autocmd('TermClose', {
  callback = function(args)
    if quitting then return end
    local buf = args.buf
    vim.schedule(function()
      if quitting then return end
      local ok, panel = pcall(function() return vim.b[buf].workspace_panel end)
      if ok and panel then
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == buf then
            hop_or_close(w, panel, buf)
            break
          end
        end
      end
      if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
      refresh_winbars()
    end)
  end,
})

pcall(function() require('config.gitstat').setup() end)

-- boot into the splash on a bare `nvim` or `nvim <dir>`, never with file args
autocmd('VimEnter', {
  once = true,
  callback = function()
    if #vim.api.nvim_list_uis() == 0 then return end
    local a = vim.fn.argv()
    if #a > 1 or (#a == 1 and vim.fn.isdirectory(a[1]) == 0) then return end
    vim.schedule(function()
      local ok, splash = pcall(require, 'config.splash')
      if ok and splash and splash.show then
        splash.show(function(launched)
          if launched then M.build_layout() end
        end)
      else
        M.build_layout()
      end
    end)
  end,
})

return M
