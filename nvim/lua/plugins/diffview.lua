return {
  'sindrets/diffview.nvim',
  cmd = { 'DiffviewOpen', 'DiffviewClose', 'DiffviewFileHistory', 'DiffviewToggleFiles' },
  dependencies = { 'nvim-lua/plenary.nvim' },
  opts = {
    enhanced_diff_hl = true,
  },
}
