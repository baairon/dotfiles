local M = {}

M.files = {}
M.changed = {}
M.totals = { files = 0, a = 0, d = 0 }
M.ns = vim.api.nvim_create_namespace('gitstat')

function M.is_changed(path)
  return path ~= nil and M.changed[vim.fs.normalize(path)] == true
end

local IC = {
  changes = string.char(0xEF, 0x90, 0x9D),
  check   = string.char(0xEF, 0x80, 0x8C),
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
  if t.files == 0 then
    vim.wo[win].winbar = '%#WorkspaceDiffDim# ' .. IC.changes .. ' changes %*'
  else
    vim.wo[win].winbar = '%#WorkspaceDiffDim# ' .. IC.changes .. ' changes  '
      .. '%#WorkspaceDiffAdd#+' .. t.a .. ' %#WorkspaceDiffDel#-' .. t.d .. '%*'
  end
end

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
  vim.wo[win].cursorline = false
  vim.wo[win].winfixheight = true
  vim.wo[win].winhighlight = 'Normal:NeoTreeNormal,EndOfBuffer:NeoTreeEndOfBuffer'
  if prev and vim.api.nvim_win_is_valid(prev) then vim.api.nvim_set_current_win(prev) end

  subscribe_git_event()
  render_bottom()
  return true
end

function M.refresh()
  local cwd = vim.fn.getcwd()
  local function run_numstat()
    local root = root_cache[cwd]
    if not root or root == '' then root = cwd end

    local list, changed, ta, td = {}, {}, 0, 0

    local function add_row(path, na, nd, is_new)
      local name = path:match('[^/]+$') or path
      local parent = path:sub(1, #path - #name):gsub('/$', ''):match('[^/]+$') or ''
      list[#list + 1] = { rel = path, pdir = parent, name = name, a = na or 0, d = nd or 0, bin = (na == nil), new = is_new or nil }
      changed[vim.fs.normalize(root .. '/' .. path)] = true
      ta, td = ta + (na or 0), td + (nd or 0)
    end

    local function finalize()
      table.sort(list, function(x, y) return x.rel < y.rel end)
      M.files = list
      M.changed = changed
      M.totals = { files = #list, a = ta, d = td }
      render_bottom()
    end

    -- pass 1: tracked files with unstaged working-tree changes
    vim.system({ 'git', 'diff', '--numstat' }, { cwd = cwd, text = true }, function(res)
      vim.schedule(function()
        if res.code == 0 and res.stdout and res.stdout ~= '' then
          for line in res.stdout:gmatch('[^\r\n]+') do
            local a, d, path = line:match('^(%S+)\t(%S+)\t(.+)$')
            if a and path then add_row(path, tonumber(a), tonumber(d), false) end
          end
        end

        -- pass 2: untracked / brand-new files, counted as all-added lines
        vim.system({ 'git', 'ls-files', '--others', '--exclude-standard' }, { cwd = cwd, text = true }, function(ures)
          vim.schedule(function()
            local others = {}
            if ures.code == 0 and ures.stdout and ures.stdout ~= '' then
              for p in ures.stdout:gmatch('[^\r\n]+') do others[#others + 1] = p end
            end
            if #others == 0 then return finalize() end

            -- guard: past the cap, list new files without counts rather than spawn unbounded gits
            local CAP = 200
            for i = CAP + 1, #others do add_row(others[i], 0, 0, true) end

            local pending = math.min(#others, CAP)
            for i = 1, pending do
              local path = others[i]
              -- diff the file against the empty blob so git counts every line as added (and flags binary)
              vim.system({ 'git', 'diff', '--no-index', '--numstat', '/dev/null', path }, { cwd = cwd, text = true }, function(dres)
                vim.schedule(function()
                  local na = 0
                  if dres.stdout and dres.stdout ~= '' then
                    na = tonumber(dres.stdout:match('^(%S+)\t') or '0')  -- nil => binary
                  end
                  add_row(path, na, 0, true)
                  pending = pending - 1
                  if pending == 0 then finalize() end
                end)
              end)
            end
          end)
        end)
      end)
    end)
  end

  if root_cache[cwd] ~= nil then
    run_numstat()
    return
  end
  vim.system({ 'git', 'rev-parse', '--show-toplevel' }, { cwd = cwd, text = true }, function(rp)
    root_cache[cwd] = (rp.code == 0 and rp.stdout or ''):gsub('%s+$', '')
    run_numstat()
  end)
end

function M.setup()
  vim.api.nvim_create_autocmd({ 'BufWritePost', 'DirChanged', 'FocusGained' }, {
    callback = function(args)
      if args.event == 'DirChanged' then root_cache = {} end
      pcall(function() require('neo-tree.sources.manager').refresh('git_status') end)
      M.refresh()
    end,
  })
end

return M
