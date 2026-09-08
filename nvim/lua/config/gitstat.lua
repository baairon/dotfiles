local M = {}

M.files = {}
M.changed = {}
M.totals = { files = 0, a = 0, d = 0 }
-- the checked-out branch, read here because this module is already the one running git on a
-- schedule; the git rail's panel header is what puts it on screen
M.branch = nil
M.ns = vim.api.nvim_create_namespace('gitstat')

function M.is_changed(path)
  return path ~= nil and M.changed[vim.fs.normalize(path)] == true
end

-- both verified present in fonts/CozetteVector.ttf
local IC = {
  changes = string.char(0xEF, 0x84, 0xA6), -- U+F126 code-fork
  check   = string.char(0xEF, 0x80, 0x8C), -- U+F00C check
}

local buf, win
local root_cache = {}
local subscribed = false
local WIDTH = 30

local function devicon(name)
  local ok, devicons = pcall(require, 'nvim-web-devicons')
  if not ok then return nil, nil end
  local ext = name:match('%.([^.]+)$') or ''
  return devicons.get_icon(name, ext, { default = true })
end

function M.rail_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) then
      local b = vim.api.nvim_win_get_buf(w)
      local ok, src = pcall(function() return vim.b[b].neo_tree_source end)
      if ok and src == 'git_status' then return w end
    end
  end
  return nil
end

local function set_winbar()
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  local t = M.totals
  local right
  if t.files > 0 then
    right = {
      { '+' .. t.a, 'WorkspaceDiffAdd' },
      { ' ' },
      { '-' .. t.d, 'WorkspaceDiffDel' },
    }
  end
  require('config.chrome').set(win, require('config.chrome').header(win, IC.changes, 'changes', right))
end

-- layout's header dispatcher hands this panel back to us, because the counts are ours to know
M.redraw_header = set_winbar

local function render_bottom()
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  set_winbar()
  local lines, marks = {}, {}
  local function emit(segs)
    local s, col = '', 0
    for _, seg in ipairs(segs) do
      if seg.hl and seg.text ~= '' then
        marks[#marks + 1] = { #lines, col, col + #seg.text, seg.hl }
      end
      s = s .. seg.text
      col = col + #seg.text
    end
    lines[#lines + 1] = s
  end

  if M.totals.files == 0 then
    emit({ { text = ' ' .. IC.check .. ' clean', hl = 'WorkspaceDiffDim' } })
  else
    for _, f in ipairs(M.files) do
      local icon, icon_hl = devicon(f.name)
      icon = icon and (icon .. ' ') or ''
      local adds = (not f.bin and f.a > 0) and ('+' .. f.a) or (f.bin and 'bin' or '')
      local dels = (not f.bin and f.d > 0) and ('-' .. f.d) or ''
      local tag = f.new and 'new ' or ''
      local sep = (adds ~= '' and dels ~= '') and ' ' or ''
      local rightw = vim.api.nvim_strwidth(tag) + vim.api.nvim_strwidth(adds) + #sep + vim.api.nvim_strwidth(dels)
      local iconw = vim.api.nvim_strwidth(icon)
      local avail = WIDTH - 1 - iconw - rightw - 1
      local dir = (f.pdir ~= '') and (f.pdir .. '/') or ''
      local name = f.name
      if vim.api.nvim_strwidth(dir .. name) > avail then
        dir = ''
        if vim.api.nvim_strwidth(name) > avail then name = '…' .. name:sub(-(avail - 1)) end
      end
      local pad = WIDTH - 1 - iconw - vim.api.nvim_strwidth(dir) - vim.api.nvim_strwidth(name) - rightw
      if pad < 1 then pad = 1 end
      emit({
        { text = ' ' },
        { text = icon, hl = icon_hl },
        { text = dir, hl = 'WorkspaceDiffDim' },
        { text = name },
        { text = string.rep(' ', pad) },
        { text = tag, hl = 'WorkspaceDiffDim' },
        { text = adds, hl = f.bin and 'WorkspaceDiffDim' or 'WorkspaceDiffAdd' },
        { text = sep },
        { text = dels, hl = 'WorkspaceDiffDel' },
      })
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  for _, m in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
end

local function subscribe_git_event()
  if subscribed then return end
  local ok, events = pcall(require, 'neo-tree.events')
  if ok and events and events.subscribe then
    pcall(events.subscribe, { event = events.GIT_EVENT, handler = function() M.refresh() end })
    subscribed = true
  end
end

function M.open()
  local rail = M.rail_win()
  if not rail then return false end
  if win and vim.api.nvim_win_is_valid(win) then return true end
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'hide'
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = 'gitstat'
    vim.b[buf].workspace_gitstat = true

    local function open_under_cursor()
      if M.totals.files == 0 then return end
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local f = M.files[line]
      if not f then return end
      if f.bin then
        vim.notify(f.rel .. ' is binary, nothing to show side by side', vim.log.levels.INFO)
        return
      end
      local root = M.root or vim.fn.getcwd()
      require('config.layout').open_file_diff(f.rel, f.new, root)
    end
    vim.keymap.set('n', '<CR>', open_under_cursor, { buffer = buf, desc = 'Diff file (side by side)' })
    vim.keymap.set('n', '<2-LeftMouse>', open_under_cursor, { buffer = buf, desc = 'Diff file (side by side)' })
  end

  local prev = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(rail)
  local total_h = vim.api.nvim_win_get_height(rail)
  vim.cmd('belowright split')
  win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_height(win, math.max(6, math.floor(total_h / 2)))
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].cursorline = true
  vim.wo[win].winfixheight = true
  vim.wo[win].winhighlight = 'Normal:NeoTreeNormal,EndOfBuffer:NeoTreeEndOfBuffer'
  if prev and vim.api.nvim_win_is_valid(prev) then vim.api.nvim_set_current_win(prev) end

  subscribe_git_event()
  render_bottom()
  return true
end

-- Every process callback enters the main loop before touching editor state.
local function git(args, cwd, callback)
  local ok, err = pcall(vim.system, args, { cwd = cwd, text = false }, function(result)
    vim.schedule(function() callback(result) end)
  end)
  if not ok then callback({ code = -1, stderr = tostring(err) }) end
end

local refresh
local tree_dirty = false
local function collect(valid, finish)
  local cwd = vim.fn.getcwd()
  if tree_dirty then
    tree_dirty = false
    pcall(function() require('neo-tree.sources.manager').refresh('git_status') end)
  end
  local function publish(root, branch, files, changed, adds, dels)
    if valid() then
      table.sort(files, function(a, b) return a.rel < b.rel end)
      local dirty = M.root ~= root or M.branch ~= branch or not vim.deep_equal(M.files, files)
      M.root, M.branch, M.files, M.changed = root, branch, files, changed
      M.totals = { files = #files, a = adds, d = dels }
      if dirty then
        render_bottom()
        require('config.layout').refresh_winbars()
      end
    end
    finish()
  end
  local function scan(root)
    if not valid() then return finish() end
    if root == '' then return publish(nil, nil, {}, {}, 0, 0) end
    git({ 'git', 'rev-parse', '--abbrev-ref', 'HEAD' }, root, function(branch_result)
      if not valid() then return finish() end
      local branch = (branch_result.stdout or ''):gsub('%s+$', '')
      if branch == '' then branch = nil end
      git({ 'git', 'diff', '--numstat', '-z' }, root, function(result)
        if not valid() or result.code ~= 0 then return finish() end
        local files, changed, adds, dels = {}, {}, 0, 0
        local function add(path, na, nd, is_new)
          local name = path:match('[^/]+$') or path
          local parent = path:sub(1, #path - #name):gsub('/$', ''):match('[^/]+$') or ''
          files[#files + 1] = { rel = path, pdir = parent, name = name,
            a = na or 0, d = nd or 0, bin = na == nil, new = is_new or nil }
          changed[vim.fs.normalize(root .. '/' .. path)] = true
          adds, dels = adds + (na or 0), dels + (nd or 0)
        end
        local records = vim.split(result.stdout or '', '\0', { plain = true, trimempty = false })
        local i = 1
        while i <= #records do
          local na, nd, path = records[i]:match('^(%S+)\t(%S+)\t(.*)$')
          if path == '' then
            -- With -z, a rename carries old and new paths as separate records.
            path = records[i + 2]
            i = i + 2
          end
          if path then add(path, tonumber(na), tonumber(nd), false) end
          i = i + 1
        end
        git({ 'git', 'ls-files', '--others', '--exclude-standard', '-z' }, root, function(untracked)
          if not valid() or untracked.code ~= 0 then return finish() end
          local paths = vim.split(untracked.stdout or '', '\0', { plain = true, trimempty = true })
          local limit = math.min(#paths, 200)
          for j = limit + 1, #paths do add(paths[j], 0, 0, true) end
          local next_index, active, completed, failed = 1, 0, 0, false
          local pump
          pump = function()
            if not valid() or failed then
              if active == 0 then finish() end
              return
            end
            if completed == limit then return publish(root, branch, files, changed, adds, dels) end
            while active < 4 and next_index <= limit do
              local path = paths[next_index]
              next_index, active = next_index + 1, active + 1
              git({ 'git', 'diff', '--no-index', '--numstat', '-z', '--', '/dev/null', path }, root, function(count)
                active, completed = active - 1, completed + 1
                if count.code ~= 0 and count.code ~= 1 then failed = true end
                local na = tonumber((count.stdout or ''):match('^(%S+)\t') or '0')
                add(path, na, 0, true)
                pump()
              end)
            end
          end
          pump()
        end)
      end)
    end)
  end
  if root_cache[cwd] ~= nil then return scan(root_cache[cwd]) end
  git({ 'git', 'rev-parse', '--show-toplevel' }, cwd, function(result)
    if not valid() then return finish() end
    local root = (result.code == 0 and result.stdout or ''):gsub('%s+$', '')
    root_cache[cwd] = root
    scan(root)
  end)
end

function M.refresh()
  if not refresh then refresh = require('config.workspace.refresh').new(100, collect) end
  refresh.request()
end

function M.setup()
  if refresh then refresh.stop(); refresh = nil end
  local group = vim.api.nvim_create_augroup('WorkspaceGitstat', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufWritePost', 'DirChanged', 'FocusGained' }, {
    group = group,
    callback = function(args)
      if args.event == 'DirChanged' then root_cache = {} end
      tree_dirty = true
      M.refresh()
    end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function() if refresh then refresh.stop() end end,
  })
end

return M
