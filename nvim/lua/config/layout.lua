local M = {}

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

local function build_winbar(win)
  if not vim.api.nvim_win_is_valid(win) then return '' end
  local buf = vim.api.nvim_win_get_buf(win)
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
      label = ' ' .. label
    else
      local n = vim.api.nvim_buf_get_name(b)
      if n ~= '' then
        local basename = vim.fn.fnamemodify(n, ':t')
        local ext = vim.fn.fnamemodify(n, ':e')
        local icon = ''
        local ok, devicons = pcall(require, 'nvim-web-devicons')
        if ok then
          local ic = devicons.get_icon(basename, ext, { default = true })
          if ic then icon = ic .. ' ' end
        end
        label = icon .. basename
      else
        label = '[new]'
      end
    end
    local hl = (b == buf) and '%#TabLineSel#' or '%#TabLine#'
    parts[#parts + 1] = '%' .. b .. '@v:lua.WorkspaceTabClick@' .. hl .. ' ' .. label .. ' %X'
  end
  parts[#parts + 1] = '%#TabLineFill#'
  return table.concat(parts)
end

local function set_winbar(win)
  if not vim.api.nvim_win_is_valid(win) then return end
  local buf = vim.api.nvim_win_get_buf(win)
  local ok, panel = pcall(function() return vim.b[buf].workspace_panel end)
  if ok and panel then
    vim.wo[win].winbar = build_winbar(win)
  end
end

local function refresh_winbars()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    set_winbar(win)
  end
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

local function sane_cwd()
  local cwd = vim.fn.getcwd()
  local sys = vim.fs.normalize(vim.env.SystemRoot or 'C:/Windows'):lower()
  if vim.fs.normalize(cwd):lower():find(sys, 1, true) == 1 then
    return vim.fn.expand('~')
  end
  return cwd
end

local function spawn_term(cmd, kind)
  vim.cmd('enew')
  vim.fn.jobstart(cmd, {
    term = true,
    cwd = sane_cwd(),
    env = { PROMPT_COMMAND = OSC7_PROMPT, CHERE_INVOKING = '1' },
  })
  vim.b.workspace_term = kind
  vim.b.workspace_panel = kind
  vim.b.workspace_cmd = type(cmd) == 'table' and cmd[1] or cmd
  vim.api.nvim_win_set_var(0, 'workspace_winpanel', kind)
  vim.cmd('setlocal nonumber norelativenumber signcolumn=no nocursorline scrolloff=0')
  refresh_winbars()
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

  vim.cmd('belowright split')
  spawn_term(git_bash(), 'shell')
  vim.api.nvim_win_set_height(0, math.floor((vim.o.lines - 2) / 3))

  pcall(vim.cmd, 'Neotree show filesystem left')
  pcall(vim.cmd, 'Neotree show git_status right')

  local function focus_top()
    if vim.api.nvim_win_is_valid(top_win) then
      vim.api.nvim_set_current_win(top_win)
      vim.cmd('startinsert')
    end
  end

  local gitstat = require('config.gitstat')
  local function restore_shell_height()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local ok, wp = pcall(vim.api.nvim_win_get_var, w, 'workspace_winpanel')
      if ok and wp == 'shell' then
        pcall(vim.api.nvim_win_set_height, w, math.floor((vim.o.lines - 2) / 3))
        return
      end
    end
  end
  local tries = 0
  local function settle()
    tries = tries + 1
    if gitstat.rail_win() then
      pcall(gitstat.open)
      pcall(gitstat.refresh)
      restore_shell_height()
      focus_top()
    elseif tries < 25 then
      vim.defer_fn(settle, 30)
    else
      restore_shell_height()
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

function M.diff_close_to_file()
  pcall(vim.cmd, 'DiffviewClose')
  local win = M.editor_winid()
  if win ~= 0 and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end
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
  vim.notify('no ' .. kind .. ' terminal', vim.log.levels.INFO)
end

local function rotate_term()
  local wins = {}
  for _, kind in ipairs({ 'top', 'shell' }) do
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local ok, wp = pcall(vim.api.nvim_win_get_var, win, 'workspace_winpanel')
      if ok and wp == kind then wins[#wins + 1] = win end
    end
  end
  if #wins == 0 then return end
  local cur, idx = vim.api.nvim_get_current_win(), 0
  for i, w in ipairs(wins) do if w == cur then idx = i end end
  vim.api.nvim_set_current_win(wins[(idx % #wins) + 1])
end

local function add_term_to_panel()
  local panel = vim.b.workspace_panel
  if panel ~= 'top' and panel ~= 'shell' then panel = 'shell' end
  spawn_term(git_bash(), panel)
end

local function hop_or_close(win, panel, exclude)
  local others = {}
  for _, b in ipairs(panel_bufs(panel)) do if b ~= exclude then others[#others + 1] = b end end
  if #others > 0 then
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_set_buf(win, others[#others]) end
    return true
  end
  if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
  return false
end

local function close_tab()
  local panel = vim.b.workspace_panel
  if not panel then
    local ok, wp = pcall(vim.api.nvim_win_get_var, 0, 'workspace_winpanel')
    if ok and wp then
      panel = wp
      vim.b.workspace_panel = wp
    else
      return
    end
  end
  local cur = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  hop_or_close(win, panel, cur)
  if vim.bo[cur].buftype == 'terminal' then
    local okc, chan = pcall(function() return vim.bo[cur].channel end)
    if okc and chan and chan > 0 then pcall(vim.fn.jobstop, chan) end
  else
    pcall(vim.api.nvim_buf_delete, cur, { force = true })
  end
  refresh_winbars()
end

local function is_aux(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local ok, src = pcall(function() return vim.b[buf].neo_tree_source end)
  if ok and src == 'git_status' then return true end
  local ok2, gs = pcall(function() return vim.b[buf].workspace_gitstat end)
  return ok2 and gs == true
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
map('n', '<leader>1',  function() jump('top') end,   { desc = 'Go to top terminal' })
map('n', '<leader>2',  function() jump('shell') end, { desc = 'Go to bottom terminal' })
map('n', '<leader>tr', rotate_term, { desc = 'Rotate between panels' })

M._close_tab = close_tab
M._add_term = add_term_to_panel

map('n', '<leader>t', add_term_to_panel, { desc = 'New terminal tab (panel)' })
map('n', '<A-t>', add_term_to_panel, { desc = 'New terminal tab (panel)' })
map('t', '<A-t>', '<C-\\><C-n><cmd>lua require("config.layout")._add_term()<CR>', { desc = 'New terminal tab (panel)' })
map('n', '<A-w>', close_tab, { desc = 'Close tab (panel)' })
map('t', '<A-w>', '<C-\\><C-n><cmd>lua require("config.layout")._close_tab()<CR>', { desc = 'Close tab (panel)' })
map('n', '<A-o>', function() M.cycle_panes(1) end, { desc = 'Cycle panes (skip git rail/stats)' })
map('t', '<A-o>', '<C-\\><C-n><cmd>lua require("config.layout").cycle_panes(1)<CR>', { desc = 'Cycle panes (skip git rail/stats)' })

local function jump_to_tab(n)
  local ok, panel = pcall(vim.api.nvim_win_get_var, 0, 'workspace_winpanel')
  if not ok or not panel then return end
  local bufs = panel_bufs(panel)
  if n > #bufs then return end
  vim.api.nvim_win_set_buf(0, bufs[n])
end
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

vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter', 'TermOpen' }, {
  callback = function(args)
    local buf = args.buf
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then return end
      if vim.api.nvim_get_current_buf() ~= buf then return end
      if vim.bo[buf].buftype == 'terminal' then
        vim.cmd('startinsert')
      else
        vim.cmd('stopinsert')
      end
    end)
  end,
})

vim.api.nvim_create_autocmd('FocusGained', {
  callback = function()
    local buf = vim.api.nvim_get_current_buf()
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_get_current_buf() == buf
        and vim.bo[buf].buftype == 'terminal' then
        vim.cmd('startinsert')
      end
    end)
  end,
})

vim.api.nvim_create_autocmd('BufWinEnter', {
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



vim.api.nvim_create_autocmd({ 'ExitPre', 'VimLeavePre' }, {
  callback = function() quitting = true end,
})

vim.api.nvim_create_autocmd('TermClose', {
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
            splash.show(function(launched)
              if launched then M.build_layout() end
            end)
          else
            M.build_layout()
          end
        end)
      end
    end,
  })
end

return M
