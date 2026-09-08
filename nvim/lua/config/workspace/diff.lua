local M = {}
local group = vim.api.nvim_create_augroup('WorkspaceDiff', { clear = true })
local function autocmd(events, opts)
  opts.group = group
  return vim.api.nvim_create_autocmd(events, opts)
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
local requests = {}
local revisions = {}
local stopping = false

local function diff_key(root, relpath)
  local normalized = vim.fs.normalize(root)
  if vim.fn.has('win32') == 1 then normalized = normalized:lower() end
  return normalized .. '/' .. relpath
end

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
  local key = diff_key(root, relpath)
  local b = diff_bufs[key]
  if not (b and vim.api.nvim_buf_is_valid(b)) then
    b = vim.api.nvim_create_buf(false, true)
    vim.bo[b].buftype = 'nofile'
    vim.bo[b].bufhidden = 'hide'
    vim.bo[b].swapfile = false
    -- the name is what build_winbar reads for the tab label and its devicon, so this shows
    -- up as an ordinary-looking file tab; workspace_panel is what files it under the panel
    vim.api.nvim_buf_set_name(b, DIFF_PREFIX .. key)
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
    diff_bufs[key] = b
  end
  vim.b[b].workspace_diff = { rel = relpath, root = root, new = is_new }
  return b
end

function M.open_file_diff(relpath, is_new, root)
  if not relpath or relpath == '' then return end
  if not root or root == '' then root = vim.fn.getcwd() end
  local top = require('config.layout').editor_winid()
  if top == 0 or not vim.api.nvim_win_is_valid(top) then
    top = vim.api.nvim_get_current_win()
  end

  local request = {}
  requests[top] = request
  local origin_win = vim.api.nvim_get_current_win()
  local original_buf = vim.api.nvim_win_get_buf(top)
  local key = diff_key(root, relpath)
  local revision = {}
  revisions[key] = revision

  vim.system(git_diff_argv(relpath, is_new, root), { text = true }, function(res)
    vim.schedule(function()
      if stopping or requests[top] ~= request or revisions[key] ~= revision
        or not vim.api.nvim_win_is_valid(top)
        or vim.api.nvim_win_get_buf(top) ~= original_buf then return end
      requests[top] = nil
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
      -- A slow diff must not steal focus from a pane entered while it was loading.
      if vim.api.nvim_get_current_win() == origin_win then vim.api.nvim_set_current_win(top) end
      require('config.layout').refresh_winbars()
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
autocmd({ 'BufWinEnter', 'BufEnter' }, {
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
autocmd('BufWritePost', {
  callback = function(args)
    local written = vim.api.nvim_buf_get_name(args.buf)
    if written == '' then return end
    written = vim.fs.normalize(written)
    for key, b in pairs(diff_bufs) do
      local d = vim.api.nvim_buf_is_valid(b) and vim.b[b].workspace_diff or nil
      if d and vim.fs.normalize(d.root .. '/' .. d.rel) == written then
        local revision = {}
        revisions[key] = revision
        vim.system(git_diff_argv(d.rel, d.new, d.root), { text = true }, function(res)
          vim.schedule(function()
            if not stopping and revisions[key] == revision and vim.api.nvim_buf_is_valid(b)
              and (res.code == 0 or (d.new and res.code == 1)) then
              render_diff(b, d.rel, res.stdout or '')
            end
          end)
        end)
      end
    end
  end,
})

function M.diff_close_to_file()
  pcall(vim.cmd, 'DiffviewClose')
  local win = require('config.layout').editor_winid()
  if win ~= 0 and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end
end

autocmd('BufWipeout', {
  callback = function(args)
    for key, buf in pairs(diff_bufs) do
      if buf == args.buf then diff_bufs[key], revisions[key] = nil, nil end
    end
  end,
})
autocmd('WinClosed', { callback = function(args) requests[tonumber(args.match)] = nil end })
autocmd('VimLeavePre', { callback = function() stopping = true end })


return M
