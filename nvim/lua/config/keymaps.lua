local map = vim.keymap.set

map('n', '<leader>e', '<cmd>Neotree toggle filesystem left<cr>', { desc = 'Toggle file tree' })
map('n', '<leader>gs', '<cmd>Neotree toggle git_status right<cr>', { desc = 'Toggle source-control rail' })
map('n', '<leader>gr', '<cmd>Neotree focus git_status right<cr>', { desc = 'Focus source-control rail' })

map('n', '<leader>ff', '<cmd>Telescope find_files<cr>', { desc = 'Find files' })
map('n', '<leader>fg', '<cmd>Telescope live_grep<cr>', { desc = 'Live grep' })
map('n', '<leader>fb', '<cmd>Telescope buffers<cr>', { desc = 'Buffers' })

map('n', '<leader>gd', '<cmd>DiffviewOpen<cr>', { desc = 'Diffview open' })
map('n', '<leader>gD', function() require('config.layout').diff_close_to_file() end, { desc = 'Diffview close (keep position)' })

for _, k in ipairs({ 'h', 'j', 'k', 'l' }) do
  map('n', '<A-' .. k .. '>', '<C-w>' .. k, { desc = 'Window ' .. k })
  map('t', '<A-' .. k .. '>', '<C-\\><C-n><C-w>' .. k, { desc = 'Window ' .. k .. ' (from terminal)' })
end

map('t', '<Esc><Esc>', '<C-\\><C-n>', { desc = 'Leave terminal insert mode' })

map('n', '<Esc>', '<cmd>nohlsearch<cr>', { desc = 'Clear highlight' })

map('n', '<leader>q', '<cmd>q<cr>', { desc = 'Close window' })
map('n', '<C-s>', '<cmd>write<cr>', { desc = 'Save file' })

map('n', '<leader>v', '<cmd>MarkdownPreviewToggle<cr>', { desc = 'Toggle markdown preview' })
map({ 'n', 'i' }, '<A-v>', '<cmd>MarkdownPreviewToggle<cr>', { desc = 'Toggle markdown preview' })
map({ 'n', 'i' }, '<A-V>', '<cmd>MarkdownPreviewToggle<cr>', { desc = 'Toggle markdown preview' })

-- Global: open the current file in the default browser. Markdown buffers get a
-- buffer-local <A-p> below (MarkdownPreview) which takes precedence, so READMEs
-- keep their preview while every other file type opens in the browser.
map({ 'n', 'i' }, '<A-p>', function()
  require('config.browser').open_current_in_browser()
end, { desc = 'Open file in default browser' })

vim.api.nvim_create_autocmd('FileType', {
  pattern = 'markdown',
  callback = function(args)
    map({ 'n', 'i' }, '<A-p>', '<cmd>MarkdownPreviewToggle<cr>', { buffer = args.buf, desc = 'Toggle markdown preview' })
  end,
})
