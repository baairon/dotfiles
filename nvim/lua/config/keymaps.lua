local map = vim.keymap.set

map('n', '<leader>e', '<cmd>Neotree toggle filesystem left<cr>', { desc = 'Toggle file tree' })
map('n', '<leader>gs', '<cmd>Neotree toggle git_status left<cr>', { desc = 'Git work-tree view' })

map('n', '<leader>ff', '<cmd>Telescope find_files<cr>', { desc = 'Find files' })
map('n', '<leader>fg', '<cmd>Telescope live_grep<cr>', { desc = 'Live grep' })
map('n', '<leader>fb', '<cmd>Telescope buffers<cr>', { desc = 'Buffers' })

map('n', '<leader>gd', '<cmd>DiffviewOpen<cr>', { desc = 'Diffview open' })
map('n', '<leader>gD', '<cmd>DiffviewClose<cr>', { desc = 'Diffview close' })

for _, k in ipairs({ 'h', 'j', 'k', 'l' }) do
  map('n', '<A-' .. k .. '>', '<C-w>' .. k, { desc = 'Window ' .. k })
  map('t', '<A-' .. k .. '>', '<C-\\><C-n><C-w>' .. k, { desc = 'Window ' .. k .. ' (from terminal)' })
end

map('t', '<Esc><Esc>', '<C-\\><C-n>', { desc = 'Leave terminal insert mode' })

map('n', '<A-o>', '<C-w>w', { desc = 'Cycle to next pane' })
map('t', '<A-o>', '<C-\\><C-n><C-w>w', { desc = 'Cycle to next pane (from terminal)' })

map('n', '<Esc>', '<cmd>nohlsearch<cr>', { desc = 'Clear highlight' })

map('n', '<leader>q', '<cmd>q<cr>', { desc = 'Close window' })
map('n', '<C-s>', '<cmd>write<cr>', { desc = 'Save file' })
