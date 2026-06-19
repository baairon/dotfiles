return {
  'nvim-treesitter/nvim-treesitter',
  branch = 'master',
  build = ':TSUpdate',
  event = { 'BufReadPost', 'BufNewFile' },
  config = function()
    require('nvim-treesitter.configs').setup({
      ensure_installed = { 'lua', 'vim', 'vimdoc', 'bash', 'markdown', 'markdown_inline', 'json', 'yaml' },
      auto_install = true,
      highlight = { enable = true },
      indent = { enable = true },
    })
  end,
}
