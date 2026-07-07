vim.g.loaded_python3_provider = 0
vim.g.loaded_ruby_provider = 0
vim.g.loaded_node_provider = 0
vim.g.loaded_perl_provider = 0

local o = vim.opt

o.number = true
o.relativenumber = true
o.signcolumn = 'yes'
o.cursorline = true

o.splitright = true
o.splitbelow = true

o.termguicolors = true
o.mouse = 'a'
o.clipboard = 'unnamedplus'

o.ignorecase = true
o.smartcase = true

o.expandtab = true
o.shiftwidth = 2
o.tabstop = 2
o.smartindent = true

o.undofile = true
o.swapfile = false
o.wrap = false
o.scrolloff = 6
o.updatetime = 250
o.timeoutlen = 400
o.ttimeoutlen = 50
o.showmode = false
o.guicursor:append('a:blinkon0')
o.shortmess:append('I')
o.fillchars:append({ eob = ' ', diff = ' ' })

o.laststatus = 3

if vim.fn.has('win32') == 1 and vim.fn.executable('cmd.exe') == 1 then
  o.shell = 'cmd.exe'
  o.shellcmdflag = '/s /c'
  o.shellxquote = '"'
  o.shellquote = ''
  o.shellredir = '>%s 2>&1'
  o.shellpipe = '>%s 2>&1'
  o.shelltemp = true
end
