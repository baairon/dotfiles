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


local function sane_cwd()
  local cwd = vim.fn.getcwd()
  local sys = vim.fs.normalize(vim.env.SystemRoot or 'C:/Windows'):lower()
  local normalized = vim.fs.normalize(cwd):lower()
  if normalized == sys or normalized:sub(1, #sys + 1) == sys .. '/' then
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
  require('config.layout').refresh_winbars()
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

-- The panes a tab can be opened from, named by the marker each one's buffer already advertises:
-- neo-tree's source for the explorer and the git rail, gitstat's flag for the changes panel. A
-- tab keeps the name rather than a window, because toggling a tree replaces its window.
local function pane_of(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local ok, src = pcall(function() return vim.b[buf].neo_tree_source end)
  if ok and src then return src end
  local okg, stat = pcall(function() return vim.b[buf].workspace_gitstat end)
  if okg and stat then return 'gitstat' end
  return nil
end

-- this tabpage only, since focusing a window in another one would switch tabpages as well
local function pane_win(name)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if pane_of(w) == name then return w end
  end
  return nil
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
  -- read first, because the buffer's variables are wiped along with it
  local origin = vim.b[cur].workspace_origin
  hop_or_close(win, panel, cur)
  if vim.bo[cur].buftype == 'terminal' then
    local okc, chan = pcall(function() return vim.bo[cur].channel end)
    if okc and chan and chan > 0 then pcall(vim.fn.jobstop, chan) end
  else
    pcall(vim.api.nvim_buf_delete, cur, { force = true })
  end
  -- A tab opened from a pane hands focus back to it, so working through a tree is open, read,
  -- close, and the next file is one keystroke away. It happens here rather than scheduled:
  -- neo-tree's follow fires a beat later and stands down while the tree has focus, so the
  -- tree's cursor stays on the file that just closed instead of chasing the tab the panel moved
  -- on to. A pane closed since is left closed.
  local back = origin and pane_win(origin)
  if back then vim.api.nvim_set_current_win(back) end
  require('config.layout').refresh_winbars()
end


local function jump_to_tab(n)
  local ok, panel = pcall(vim.api.nvim_win_get_var, 0, 'workspace_winpanel')
  if not ok or not panel then return end
  local bufs = panel_bufs(panel)
  if n > #bufs then return end
  vim.api.nvim_win_set_buf(0, bufs[n])
end

return {
  git_bash = git_bash, panel_bufs = panel_bufs, term_name = term_name,
  spawn_term = spawn_term, jump = jump, add_term_to_panel = add_term_to_panel,
  hop_or_close = hop_or_close, close_tab = close_tab, jump_to_tab = jump_to_tab,
  pane_of = pane_of,
}
