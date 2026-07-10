return {
  'nvim-treesitter/nvim-treesitter',
  branch = 'main',
  lazy = false,
  build = ':TSUpdate',
  config = function()
    -- the tree-sitter CLI builds through rust's cc crate, which on windows
    -- looks for msvc's cl.exe; this machine compiles parsers with gcc instead
    vim.env.CC = vim.env.CC or 'gcc'

    require('nvim-treesitter').install({
      'bash', 'css', 'html', 'javascript', 'json', 'lua', 'markdown', 'markdown_inline',
      'python', 'rust', 'toml', 'tsx', 'typescript', 'vim', 'vimdoc', 'xml', 'yaml',
    })

    vim.api.nvim_create_autocmd('FileType', {
      group = vim.api.nvim_create_augroup('treesitter.start', { clear = true }),
      callback = function(ev)
        -- starts only when a parser exists for the buffer's language
        if pcall(vim.treesitter.start, ev.buf) then
          vim.bo[ev.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
        end
      end,
    })
  end,
}
