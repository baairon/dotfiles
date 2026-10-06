-- Files handed over by bin/edit.lua, the $EDITOR of every terminal this nvim runs. A program in
-- one of them (git commit, Claude Code's /plan open) would otherwise start a second nvim inside
-- that pane, where this one still takes Esc Esc and the Alt chords for itself. The files open as
-- tabs in the top panel instead, where the program is usually running, and it is let go once none
-- of them is on screen any more.
local M = {}

local function on_screen(bufs)
  for _, b in ipairs(bufs) do
    if vim.api.nvim_buf_is_valid(b) and #vim.fn.win_findbuf(b) > 0 then return true end
  end
  return false
end

-- client is the channel the shim is waiting on; line comes last because it is optional, and a nil
-- in the middle of an RPC argument list would cut the list short.
function M.open(client, paths, line)
  local win = require('config.layout').editor_winid()
  local back
  if win ~= 0 and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    back = vim.api.nvim_win_get_buf(win)
  else
    -- no workspace around this terminal, so the files get a tabpage of their own
    vim.cmd('tab split')
    win = vim.api.nvim_get_current_win()
  end
  local ok, panel = pcall(vim.api.nvim_win_get_var, win, 'workspace_winpanel')
  local bufs = {}
  -- last to first, so the first file is the one left showing
  for i = #paths, 1, -1 do
    vim.cmd('edit ' .. vim.fn.fnameescape(paths[i]))
    local buf = vim.api.nvim_get_current_buf()
    if ok and panel then vim.b[buf].workspace_panel = panel end
    table.insert(bufs, 1, buf)
  end
  if line then pcall(vim.api.nvim_win_set_cursor, win, { line, 0 }) end

  local group = vim.api.nvim_create_augroup('WorkspaceHandoff' .. client, { clear = true })
  local settled = false
  local function settle()
    if settled or on_screen(bufs) then return end
    settled = true
    pcall(vim.api.nvim_del_augroup_by_id, group)
    pcall(vim.rpcnotify, client, 'nvim_set_var', 'workspace_handoff_done', true)
    -- Closed rather than switched away from: the panel goes back to what it showed before, the
    -- terminal the program is waiting in, instead of whichever tab close_tab hopped to.
    for _, b in ipairs(bufs) do
      if vim.api.nvim_buf_is_loaded(b) then return end
    end
    if back and vim.api.nvim_buf_is_valid(back) and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_buf(win, back)
    end
  end
  for _, buf in ipairs(bufs) do
    vim.api.nvim_create_autocmd({ 'BufHidden', 'BufUnload', 'BufDelete' }, {
      group = group,
      buffer = buf,
      callback = function() vim.schedule(settle) end,
    })
  end
end

-- A Claude Code background session runs under a daemon, outside every terminal here, and its $NVIM
-- still names whichever nvim the daemon was started from. The nvim with focus is the one the
-- session is being watched in, so it keeps its address here for bin/edit.lua to fall back to.
local function focus_file() return vim.fn.stdpath('state') .. '/focused-server' end

local function focused()
  local ok, lines = pcall(vim.fn.readfile, focus_file())
  return ok and lines[1] or nil
end

function M.record()
  if vim.v.servername == '' or focused() == vim.v.servername then return end
  vim.fn.mkdir(vim.fn.stdpath('state'), 'p')
  vim.fn.writefile({ vim.v.servername }, focus_file())
end

-- only its own entry, since another nvim may have taken focus first
function M.forget()
  if focused() == vim.v.servername then vim.fn.delete(focus_file()) end
end

function M.setup()
  local group = vim.api.nvim_create_augroup('WorkspaceHandoffFocus', { clear = true })
  -- TermEnter too, because a freshly started nvim hears no FocusGained until focus moves
  vim.api.nvim_create_autocmd({ 'FocusGained', 'TermEnter' }, {
    group = group,
    callback = function()
      if #vim.api.nvim_list_uis() > 0 then M.record() end
    end,
  })
  vim.api.nvim_create_autocmd({ 'FocusLost', 'VimLeavePre' }, {
    group = group,
    callback = function() M.forget() end,
  })
end

return M
