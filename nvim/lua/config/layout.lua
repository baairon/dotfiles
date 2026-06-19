local M = {}

local rebuilding = false
local closing = false
local quitting = false

local AUTO_BOOT = true

local function git_bash()
  local candidates = {}
  local function add(p) if p and p ~= '' then candidates[#candidates + 1] = p end end
  add((vim.env.ProgramFiles or 'C:\\Program Files') .. '\\Git\\bin\\bash.exe')
  add((vim.env['ProgramFiles(x86)'] or 'C:\\Program Files (x86)') .. '\\Git\\bin\\bash.exe')
  if vim.env.LOCALAPPDATA then add(vim.env.LOCALAPPDATA .. '\\Programs\\Git\\bin\\bash.exe') end
  add(vim.fn.exepath('bash'))
  for _, p in ipairs(candidates) do
    if vim.fn.executable(p) == 1 then
      return { p, '--login', '-i' }
    end
  end
  return vim.o.shell
end

local OSC7_PROMPT = [[printf '\033]7;file://%s%s\007' "$HOSTNAME" "$PWD"]]

local function panel_bufs(panel)
  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local ok, p = pcall(function() return vim.b[b].workspace_panel end)
      if ok and p == panel then out[#out + 1] = b end
    end
  end
  table.sort(out)
  return out
end

local function term_name(b)
  local ok, cmd = pcall(function() return vim.b[b].workspace_cmd end)
  return (ok and cmd) and vim.fn.fnamemodify(cmd, ':t:r') or 'term'
end

function _G.WorkspaceWinbar()
  local win = vim.g.statusline_winid
  local buf = (win and win ~= 0 and vim.api.nvim_win_is_valid(win))
    and vim.api.nvim_win_get_buf(win) or vim.api.nvim_get_current_buf()
  local ok, panel = pcall(function() return vim.b[buf].workspace_panel end)
  if not ok or not panel then return '' end
  local parts = {}
  local bufs = panel_bufs(panel)
  local termtotal, seen = {}, {}
  for _, b in ipairs(bufs) do
    if vim.bo[b].buftype == 'terminal' then
      local nm = term_name(b)
      termtotal[nm] = (termtotal[nm] or 0) + 1
    end
  end
  for _, b in ipairs(bufs) do
    local label
    if vim.bo[b].buftype == 'terminal' then
      local nm = term_name(b)
      seen[nm] = (seen[nm] or 0) + 1
      label = (termtotal[nm] > 1) and (nm .. ' ' .. seen[nm]) or nm
    else
      local n = vim.api.nvim_buf_get_name(b)
      label = (n ~= '' and vim.fn.fnamemodify(n, ':t')) or '[new]'
    end
    local hl = (b == buf) and '%#TabLineSel#' or '%#TabLine#'
    parts[#parts + 1] = '%' .. b .. '@v:lua.WorkspaceTabClick@' .. hl .. ' ' .. label .. ' %X'
  end
  parts[#parts + 1] = '%#TabLineFill#'
  return table.concat(parts)
end

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

local WINBAR = '%{%v:lua.WorkspaceWinbar()%}'

local function spawn_term(cmd, kind)
  vim.cmd('enew')
  vim.fn.jobstart(cmd, { term = true, env = { PROMPT_COMMAND = OSC7_PROMPT } })
  vim.b.workspace_term = kind
  vim.b.workspace_panel = kind
  vim.b.workspace_cmd = type(cmd) == 'table' and cmd[1] or cmd
  vim.api.nvim_win_set_var(0, 'workspace_winpanel', kind)
  vim.cmd('setlocal nonumber norelativenumber signcolumn=no')
  vim.wo.winbar = WINBAR
end

local function cleanup()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local ok, val = pcall(vim.api.nvim_buf_get_var, buf, 'workspace_term')
    if ok and val and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  pcall(vim.cmd, 'Neotree close')
end

function M.editor_winid()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ok, v = pcall(vim.api.nvim_win_get_var, win, 'workspace_winpanel')
    if ok and v == 'top' and vim.api.nvim_win_is_valid(win) then return win end
  end
  return 0
end

function M.open_workspace()
  rebuilding = true
  cleanup()
  vim.cmd('only')

  spawn_term(git_bash(), 'top')
  local top_win = vim.api.nvim_get_current_win()

  vim.cmd('belowright split')
  spawn_term(git_bash(), 'shell')
  vim.api.nvim_win_set_height(0, math.floor((vim.o.lines - 2) / 3))

  pcall(vim.cmd, 'Neotree show filesystem left')

  local function focus_top()
    if vim.api.nvim_win_is_valid(top_win) then
      vim.api.nvim_set_current_win(top_win)
      vim.cmd('startinsert')
    end
  end
  vim.schedule(function()
    rebuilding = false
    vim.cmd('redraw!')
    focus_top()
  end)
  vim.defer_fn(focus_top, 50)
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

local function jump(kind)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ok, wp = pcall(vim.api.nvim_win_get_var, win, 'workspace_winpanel')
    if ok and wp == kind then
      vim.api.nvim_set_current_win(win)
      if vim.b[vim.api.nvim_win_get_buf(win)].workspace_term ~= kind then
        for _, b in ipairs(panel_bufs(kind)) do
          if vim.b[b].workspace_term == kind then
            vim.api.nvim_win_set_buf(win, b)
            break
          end
        end
      end
      return
    end
  end
  vim.notify('no ' .. kind .. ' terminal (run <leader>w first)', vim.log.levels.INFO)
end

local function rotate_term()
  local wins = {}
  for _, kind in ipairs({ 'top', 'shell' }) do
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local ok, wp = pcall(vim.api.nvim_win_get_var, win, 'workspace_winpanel')
      if ok and wp == kind then wins[#wins + 1] = win end
    end
  end
  if #wins == 0 then
    vim.notify('no workspace terminals (run <leader>w)', vim.log.levels.INFO)
    return
  end
  local cur, idx = vim.api.nvim_get_current_win(), 0
  for i, w in ipairs(wins) do if w == cur then idx = i end end
  vim.api.nvim_set_current_win(wins[(idx % #wins) + 1])
end

local function add_term_to_panel()
  local panel = vim.b.workspace_panel
  if panel ~= 'top' and panel ~= 'shell' then panel = 'shell' end
  spawn_term(git_bash(), panel)
end

local function close_tab()
  local panel = vim.b.workspace_panel
  if not panel then return end
  local cur = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local force = vim.bo[cur].buftype == 'terminal'
  local others = {}
  for _, b in ipairs(panel_bufs(panel)) do if b ~= cur then others[#others + 1] = b end end
  closing = true
  if #others > 0 then
    vim.api.nvim_win_set_buf(win, others[#others])
    local ok, err = pcall(vim.api.nvim_buf_delete, cur, { force = force })
    if not ok then vim.notify(err, vim.log.levels.ERROR) end
  else
    local ok, err = pcall(vim.api.nvim_buf_delete, cur, { force = force })
    if not ok then vim.notify(err, vim.log.levels.ERROR) end
    if ok and vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
  end
  closing = false
end

local map = vim.keymap.set
map('n', '<leader>w',  function()
  require('config.splash').show(function(launched)
    if launched then M.open_workspace() end
  end, { animate = false })
end, { desc = 'Workspace main menu' })
map('n', '<leader>W',  function()
  require('config.splash').show(function(launched)
    if launched then M.open_workspace() end
  end, { view = 'dirs', animate = false })
end, { desc = 'Switch workspace (~/dev picker)' })
map('n', '<leader>gg', M.lazygit_float,  { desc = 'Lazygit (work tree)' })
map('n', '<leader>1',  function() jump('top') end,   { desc = 'Go to top terminal' })
map('n', '<leader>2',  function() jump('shell') end, { desc = 'Go to bottom terminal' })
map('n', '<leader>tr', rotate_term, { desc = 'Rotate between panels' })

local function from_term(fn)
  return function()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-\\><C-n>', true, false, true), 'nx', false)
    fn()
  end
end
map('n', '<leader>t', add_term_to_panel, { desc = 'New terminal tab (panel)' })
map('n', '<A-t>', add_term_to_panel, { desc = 'New terminal tab (panel)' })
map('t', '<A-t>', from_term(add_term_to_panel), { desc = 'New terminal tab (panel)' })
map('n', '<A-w>', close_tab, { desc = 'Close tab (panel)' })
map('t', '<A-w>', from_term(close_tab), { desc = 'Close tab (panel)' })

local function jump_to_tab(n)
  local ok, panel = pcall(vim.api.nvim_win_get_var, 0, 'workspace_winpanel')
  if not ok or not panel then return end
  local bufs = panel_bufs(panel)
  if n > #bufs then return end
  vim.api.nvim_win_set_buf(0, bufs[n])
end

for i = 1, 9 do
  local fn = function() jump_to_tab(i) end
  map('n', '<A-' .. i .. '>', fn, { desc = 'Tab ' .. i .. ' (panel)' })
  map('t', '<A-' .. i .. '>', from_term(fn), { desc = 'Tab ' .. i .. ' (panel)' })
end

local function osc7_path(seq)
  local uri = seq:match('\27%]7;(file://[^\7\27]*)')
  if not uri then return nil end
  local path = uri:gsub('^file://[^/]*', '')
  path = (vim.uri_decode and vim.uri_decode(path)) or path
  path = path:gsub('^/(%a)/', function(d) return d:upper() .. ':/' end)
  return path
end

vim.api.nvim_create_autocmd('TermRequest', {
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

vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter' }, {
  callback = function(args)
    if vim.bo[args.buf].buftype ~= 'terminal' then
      vim.schedule(function() vim.cmd('stopinsert') end)
    end
  end,
})

vim.api.nvim_create_autocmd('BufWinEnter', {
  callback = function(args)
    local buf = args.buf
    if vim.bo[buf].buftype ~= '' or vim.api.nvim_buf_get_name(buf) == '' then return end
    if not vim.b[buf].workspace_panel then
      vim.b[buf].workspace_panel = vim.w.workspace_winpanel or 'top'
    end
    vim.wo.winbar = WINBAR
  end,
})

vim.api.nvim_create_autocmd('WinLeave', {
  callback = function()
    if vim.bo.buftype ~= 'terminal' then return end
    local win = vim.api.nvim_get_current_win()
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(win) then
        local b = vim.api.nvim_win_get_buf(win)
        pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(b), 0 })
      end
    end)
  end,
})

vim.api.nvim_create_autocmd({ 'ExitPre', 'VimLeavePre' }, {
  callback = function() quitting = true end,
})

vim.api.nvim_create_autocmd('TermClose', {
  callback = function(args)
    if rebuilding or closing or quitting then return end
    local buf = args.buf
    local ok, panel = pcall(function() return vim.b[buf].workspace_panel end)
    if not ok or (panel ~= 'top' and panel ~= 'shell') then return end
    vim.schedule(function()
      if quitting then return end
      local win
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == buf then win = w; break end
      end
      local others = {}
      for _, b in ipairs(panel_bufs(panel)) do
        if b ~= buf then others[#others + 1] = b end
      end
      if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
        if #others > 0 then
          vim.api.nvim_win_set_buf(win, others[#others])
        else
          spawn_term(git_bash(), panel)
        end
      end
      if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
    end)
  end,
})

if AUTO_BOOT then
  vim.api.nvim_create_autocmd('VimEnter', {
    once = true,
    callback = function()
      if #vim.api.nvim_list_uis() == 0 then return end
      local a = vim.fn.argv()
      local boot = (#a == 0) or (#a == 1 and vim.fn.isdirectory(a[1]) == 1)
      if boot then
        vim.schedule(function()
          local ok, splash = pcall(require, 'config.splash')
          if ok and splash and splash.show then
            splash.show(M.open_workspace)
          else
            M.open_workspace()
          end
        end)
      end
    end,
  })
end

return M
