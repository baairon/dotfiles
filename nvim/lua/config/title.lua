-- Tabby labels a tab with the terminal title, and bash only sets that from \w when it draws a
-- prompt, so a session opened from the splash left the tab naming the folder nvim was started
-- in. nvim owns the title while it runs and keeps it on its working directory, written the way
-- \w writes it: ~ for home, forward slashes. The next prompt takes it back when nvim exits.
local M = {}

function M.text(dir)
  local text = vim.fn.fnamemodify(dir, ':~')
  if vim.fn.has('win32') == 1 then text = text:gsub('\\', '/') end
  return text
end

-- 'titlestring' is parsed like a statusline, where a lone % starts an item, so a folder with
-- one in its name would raise an error on every cd into it.
local function apply()
  local title = M.text(vim.fn.getcwd()):gsub('%%', '%%%%')
  if vim.o.titlestring ~= title then vim.o.titlestring = title end
end

function M.setup()
  vim.o.title = true
  apply()
  vim.api.nvim_create_autocmd('DirChanged', {
    group = vim.api.nvim_create_augroup('WorkspaceTitle', { clear = true }),
    callback = apply,
  })
end

return M
