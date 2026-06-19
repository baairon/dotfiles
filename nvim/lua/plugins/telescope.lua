return {
  'nvim-telescope/telescope.nvim',
  branch = '0.1.x',
  cmd = 'Telescope',
  dependencies = { 'nvim-lua/plenary.nvim' },
  opts = {
    defaults = {
      layout_strategy = 'flex',
      sorting_strategy = 'ascending',
      layout_config = { prompt_position = 'top' },
      get_selection_window = function()
        return require('config.layout').editor_winid()
      end,
    },
  },
}
