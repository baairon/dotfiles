return {
  'sindrets/diffview.nvim',
  cmd = { 'DiffviewOpen', 'DiffviewClose', 'DiffviewFileHistory', 'DiffviewToggleFiles' },
  dependencies = { 'nvim-lua/plenary.nvim' },
  opts = {
    enhanced_diff_hl = true,
    keymaps = {
      view = { { 'n', 'q', '<cmd>lua require("config.layout").diff_close_to_file()<cr>', { desc = 'Close diff, keep position' } } },
      file_panel = { { 'n', 'q', '<cmd>lua require("config.layout").diff_close_to_file()<cr>', { desc = 'Close diff, keep position' } } },
    },
  },
}
