local M = {}

local quitting = false

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
        local has_devicons, devicons = pcall(require, 'nvim-web-devicons')
        if has_devicons then
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
    tries = tries + 1
    if gitstat.rail_win() then
      pcall(gitstat.open)
      pcall(gitstat.refresh)
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

-- --- diff panel --------------------------------------------------------------------------
-- One file's changes as a single unified panel, opened as an ordinary tab in the top panel,
-- so <A-w> closes it in one press like every other tab and the tree, the git rail and the
-- changes panel all stay where they are. Neither obvious tool fits that shape: diffview
-- claims a whole tabpage, and nvim's own diff mode needs a second window to diff against.
-- So the hunks are painted here, the way gitstat paints its rows.
local DIFF_PREFIX = 'git://diff/'
local diff_ns = vim.api.nvim_create_namespace('workspace_diff')
local diff_bufs = {}

local function git_diff_argv(relpath, is_new, root)
  if is_new then
    -- nothing in the index to compare against, so diff the file against the empty blob and
    -- every line reads as added
    return { 'git', '-C', root, 'diff', '--no-color', '--no-index', '--', '/dev/null', relpath }
  end
  return { 'git', '-C', root, 'diff', '--no-color', '--', relpath }
end

local function render_diff(buf, relpath, out)
  local body, spans = {}, {}
  local adds, dels = 0, 0
  local started = false
  local OFFSET = 2 -- the title line, and the blank one under it

  local function mark(hl, eol)
    spans[#spans + 1] = { #body - 1 + OFFSET, hl, eol }
  end

  -- git's file header (diff --git, index, ---, +++) says nothing a one-file view does not
  -- already say in its title, so the render starts at the first hunk marker
  for _, raw in ipairs(vim.split(out, '\n', { plain = true })) do
    local line = (raw:gsub('\r$', ''))
    if line:sub(1, 2) == '@@' then
      started = true
      body[#body + 1] = line
      mark('WorkspaceDiffHunk', false)
    elseif started then
      body[#body + 1] = line
      local c = line:sub(1, 1)
      if c == '+' then
        adds = adds + 1
        mark('WorkspaceDiffAddBg', true)
      elseif c == '-' then
        dels = dels + 1
        mark('WorkspaceDiffDelBg', true)
      elseif c == '\\' then
        mark('WorkspaceDiffDim', false) -- "\ No newline at end of file"
      end
    end
  end
  -- context lines always carry a leading space, so an empty entry can only be the trailing
  -- one split leaves behind, and it never owns a span
  while #body > 0 and body[#body] == '' do body[#body] = nil end

  if #body == 0 then
    body[1] = ' nothing to show, this file matches the index'
    spans[#spans + 1] = { OFFSET, 'WorkspaceDiffDim', false }
  end

  local segs = {
    { ' ' .. relpath, 'WorkspaceDiffDim' },
    { '   ' },
    { '+' .. adds, 'WorkspaceDiffAdd' },
    { ' ' },
    { '-' .. dels, 'WorkspaceDiffDel' },
  }
  local title, tspans, col = '', {}, 0
  for _, s in ipairs(segs) do
    if s[2] then tspans[#tspans + 1] = { col, col + #s[1], s[2] } end
    title = title .. s[1]
    col = col + #s[1]
  end

  local lines = { title, '' }
  for _, l in ipairs(body) do lines[#lines + 1] = l end
  -- a trailing line the render never marks, so a block on the last hunk line always has a
  -- row below it to extend its highlight into
  lines[#lines + 1] = ''

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)
  for _, t in ipairs(tspans) do
    pcall(vim.api.nvim_buf_set_extmark, buf, diff_ns, 0, t[1],
      { end_col = t[2], hl_group = t[3] })
  end
  for _, s in ipairs(spans) do
    local row, hl, eol = s[1], s[2], s[3]
    local opts
    if eol then
      -- an added or removed line reads as a block only if its colour runs the full width of
      -- the panel, which takes a highlight that crosses the end of the line
      opts = { end_row = row + 1, end_col = 0, hl_group = hl, hl_eol = true }
    else
      opts = { end_col = #(lines[row + 1] or ''), hl_group = hl }
    end
    pcall(vim.api.nvim_buf_set_extmark, buf, diff_ns, row, 0, opts)
  end
end

local function diff_buf(relpath, root, is_new)
  local b = diff_bufs[relpath]
  if not (b and vim.api.nvim_buf_is_valid(b)) then
    b = vim.api.nvim_create_buf(false, true)
    vim.bo[b].buftype = 'nofile'
    vim.bo[b].bufhidden = 'hide'
    vim.bo[b].swapfile = false
    -- the name is what build_winbar reads for the tab label and its devicon, so this shows
    -- up as an ordinary-looking file tab; workspace_panel is what files it under the panel
    pcall(vim.api.nvim_buf_set_name, b, DIFF_PREFIX .. relpath)
    vim.bo[b].filetype = 'diff'
    vim.b[b].workspace_panel = 'top'
    vim.keymap.set('n', 'q', function() require('config.layout')._close_tab() end,
      { buffer = b, desc = 'Close diff' })
    -- a markdown file's diff is still that file, so <A-p> keeps reaching the preview here
    if vim.filetype.match({ filename = relpath }) == 'markdown' then
      vim.keymap.set({ 'n', 'i' }, '<A-p>',
        function() require('config.layout').diff_markdown_preview() end,
        { buffer = b, desc = 'Toggle markdown preview' })
    end
    diff_bufs[relpath] = b
  end
  vim.b[b].workspace_diff = { rel = relpath, root = root, new = is_new }
  return b
end

function M.open_file_diff(relpath, is_new, root)
  if not relpath or relpath == '' then return end
  if not root or root == '' then root = vim.fn.getcwd() end
  local top = M.editor_winid()
  if top == 0 or not vim.api.nvim_win_is_valid(top) then
    top = vim.api.nvim_get_current_win()
  end

  vim.system(git_diff_argv(relpath, is_new, root), { text = true }, function(res)
    vim.schedule(function()
      if not vim.api.nvim_win_is_valid(top) then return end
      local out = res.stdout or ''
      -- --no-index exits 1 whenever the two files differ, which is every interesting case
      -- here, so the only status worth reporting is one that also produced no diff
      if out == '' and res.code ~= 0 then
        vim.notify(((res.stderr or 'git diff failed'):gsub('%s+$', '')), vim.log.levels.WARN)
        return
      end
      if out:find('\0', 1, true) then
        vim.notify(relpath .. ' is binary, nothing to show', vim.log.levels.INFO)
        return
      end
      local buf = diff_buf(relpath, root, is_new)
      render_diff(buf, relpath, out)
      vim.api.nvim_win_set_buf(top, buf)
      vim.api.nvim_set_current_win(top)
      refresh_winbars()
    end)
  end)
end

-- markdown-preview registers MarkdownPreview* as `command! -buffer` on markdown buffers only, so
-- the toggle cannot run from a diff of one. The file is loaded without ever being displayed and
-- the toggle runs inside it, so the panel keeps showing the diff and never grows a second tab
-- reading the same filename.
function M.diff_markdown_preview()
  local d = vim.b[vim.api.nvim_get_current_buf()].workspace_diff
  if not d then return end
  local path = vim.fs.normalize(d.root .. '/' .. d.rel)
  if vim.fn.filereadable(path) == 0 then
    vim.notify(d.rel .. ' is not in the work tree, nothing to preview', vim.log.levels.WARN)
    return
  end
  local fbuf = vim.fn.bufadd(path)
  vim.fn.bufload(fbuf)
  -- On a cold start the preview is not opened by the command: it is opened by the node server
  -- calling back once it is up, against whatever buffer is current by then, which here would be
  -- the diff. So hold the file current, pumping the event loop, until that call has landed on it.
  -- What it lands as is the plugin's per-buffer refresh autocmds, which stopping a preview leaves
  -- behind, so they are cleared first or a second open would read the first one's as its own.
  local group = 'MKDP_REFRESH_INIT' .. fbuf
  vim.api.nvim_buf_call(fbuf, function()
    -- the command is buffer-local and only exists once the plugin has loaded against a markdown
    -- buffer, so a build that never completed would otherwise surface as a stack trace
    if vim.fn.exists(':MarkdownPreviewToggle') == 0 then
      vim.notify('markdown-preview did not load, see :Lazy', vim.log.levels.WARN)
      return
    end
    vim.cmd('silent! autocmd! ' .. group)
    local was_on = vim.b[fbuf].MarkdownPreviewToggleBool == 1
    vim.cmd('MarkdownPreviewToggle')
    if was_on then return end
    vim.wait(3000, function() return vim.fn.exists('#' .. group .. '#CursorHold') == 1 end, 40)
  end)
end

-- Buffer line numbers on a unified diff are noise: the ones that mean anything are printed
-- in the hunk headers. Toggled on window entry rather than set once, because the diff shares
-- the top panel's window with ordinary file tabs.
vim.api.nvim_create_autocmd({ 'BufWinEnter', 'BufEnter' }, {
  callback = function(args)
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(win) ~= args.buf then return end
    if vim.b[args.buf].workspace_diff then
      vim.wo[win].number = false
      vim.wo[win].relativenumber = false
      vim.wo[win].signcolumn = 'no'
      vim.wo[win].cursorline = false
    elseif vim.bo[args.buf].buftype == '' then
      vim.wo[win].number = vim.o.number
      vim.wo[win].relativenumber = vim.o.relativenumber
      vim.wo[win].signcolumn = vim.o.signcolumn
      vim.wo[win].cursorline = vim.o.cursorline
    end
  end,
})

-- a panel left open while its file is edited would otherwise sit there showing hunks that
-- are no longer true
vim.api.nvim_create_autocmd('BufWritePost', {
  callback = function(args)
    local written = vim.api.nvim_buf_get_name(args.buf)
    if written == '' then return end
    written = vim.fs.normalize(written)
    for rel, b in pairs(diff_bufs) do
      local d = vim.api.nvim_buf_is_valid(b) and vim.b[b].workspace_diff or nil
      if d and vim.fs.normalize(d.root .. '/' .. rel) == written then
        vim.system(git_diff_argv(rel, d.new, d.root), { text = true }, function(res)
          vim.schedule(function()
            if vim.api.nvim_buf_is_valid(b) then render_diff(b, rel, res.stdout or '') end
          end)
        end)
      end
    end
  end,
})

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

local function add_term_to_panel()
  spawn_term(git_bash(), 'top')
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

-- boot into the splash on a bare `nvim` or `nvim <dir>`, never with file args
vim.api.nvim_create_autocmd('VimEnter', {
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
