-- Capture actual splash buffers and highlights using synthetic directory data.
vim.opt.rtp:prepend(vim.fn.getcwd() .. '/nvim')
local source = assert(arg[1], 'splash source required')
local output = assert(arg[2], 'capture path required')
local data = vim.fn.tempname()
vim.fn.mkdir(data, 'p')
local stdpath = vim.fn.stdpath
vim.fn.stdpath = function(kind) return kind == 'data' and data or stdpath(kind) end
vim.api.nvim_list_uis = function() return { {} } end
vim.fn.getcwd = function() return 'C:/example' end
vim.fn.isdirectory = function() return 1 end
vim.fn.readdir = function() return { 'alpha', 'beta', 'project-with-a-long-name', '.hidden' } end
vim.env.NVIM_DEV_DIR = 'C:/projects'
local captures = {}
local function capture(label)
  local buf = vim.api.nvim_get_current_buf()
  local marks = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace('splash'), 0, -1, { details = true })
  for _, mark in ipairs(marks) do mark[1] = 0 end
  captures[#captures + 1] = { label, vim.api.nvim_buf_get_lines(buf, 0, -1, false), marks }
end
local function key(lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, 'n')) do
    if map.lhs == lhs then map.callback(); return end
  end
  error('missing splash key ' .. lhs)
end
for _, size in ipairs({ { 120, 40 }, { 60, 20 }, { 40, 11 } }) do
  vim.o.columns, vim.o.lines = size[1], size[2]
  local splash = dofile(source)
  splash.show(function() end)
  capture('menu ' .. size[1])
  key('j')
  capture('selection ' .. size[1])
  key('n')
  capture('picker ' .. size[1])
  for _, width in ipairs({ 80, 55, size[1] }) do
    vim.o.columns = width
    vim.api.nvim_exec_autocmds('VimResized', {})
  end
  vim.wait(200, function() return false end)
  capture('resized ' .. size[1])
  key('<Esc>')
  key('l')
  vim.wait(20, function() return vim.bo.buftype ~= 'nofile' end)
end

vim.fn.writefile({ vim.json.encode(captures) }, output)
vim.fn.delete(data, 'd')
