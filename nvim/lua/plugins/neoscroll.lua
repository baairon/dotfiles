return {
  'karb94/neoscroll.nvim',
  event = 'VeryLazy',
  opts = {
    mappings = { '<C-u>', '<C-d>', '<C-e>', '<C-y>', 'zt', 'zz', 'zb' },
  },
  config = function(_, opts)
    local neoscroll = require('neoscroll')
    neoscroll.setup(opts)
    local h = function() return vim.api.nvim_win_get_height(0) end
    vim.keymap.set({ 'n', 'v', 'x' }, '<PageUp>',   function() neoscroll.scroll(-h(), { move_cursor = true, duration = 250 }) end)
    vim.keymap.set({ 'n', 'v', 'x' }, '<PageDown>', function() neoscroll.scroll( h(), { move_cursor = true, duration = 250 }) end)
  end,
}
