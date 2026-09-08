-- A real attached Neovim UI catches viewport bugs that buffer snapshots cannot.
local stdin, stdout, stderr = vim.uv.new_pipe(), vim.uv.new_pipe(), vim.uv.new_pipe()
local responses, sequence, diagnostics = {}, 0, ''
local unpacker = vim.mpack.Unpacker()
local child = assert(vim.uv.spawn(vim.v.progpath, {
  args = { '--embed', '--headless', '-u', 'NONE', '-i', 'NONE' },
  stdio = { stdin, stdout, stderr },
}, function() end))
stdout:read_start(function(error, chunk)
  assert(not error, error)
  if not chunk then return end
  local offset = 1
  while offset <= #chunk do
    local message
    message, offset = unpacker(chunk, offset)
    if message and message[1] == 1 then responses[message[2]] = message end
  end
end)
stderr:read_start(function(_, chunk) diagnostics = diagnostics .. (chunk or '') end)
local function call(method, ...)
  sequence = sequence + 1
  local id = sequence
  stdin:write(vim.mpack.encode({ 0, id, method, { ... } }))
  assert(vim.wait(3000, function() return responses[id] ~= nil end, 5), method .. ': ' .. diagnostics)
  local response = responses[id]
  responses[id] = nil
  assert(response[3] == vim.NIL, vim.inspect(response[3]))
  return response[4]
end
local function lua(code, ...) return call('nvim_exec_lua', code, { ... }) end

local checks = 0
local function check(ok, label) assert(ok, label); checks = checks + 1 end

local ok, err = pcall(function()
  call('nvim_ui_attach', 120, 40, { rgb = true, ext_linegrid = true })
  lua([[local root = ...; vim.opt.rtp:prepend(root .. '/nvim'); require('config.options')
    vim.env.NVIM_DEV_DIR = root .. '/tests'
    require('config.splash').show(function() end)]], vim.fn.getcwd())

  local function snapshot()
    lua([[vim.cmd('redraw')]])
    return lua([[return { columns = vim.o.columns, lines = vim.o.lines,
      width = vim.api.nvim_win_get_width(0), height = vim.api.nvim_win_get_height(0),
      view = vim.fn.winsaveview(), winbar = vim.wo.winbar, scrolloff = vim.wo.scrolloff,
      rows = vim.api.nvim_buf_line_count(0), filetype = vim.bo.filetype }]])
  end

  -- nvim_ui_try_resize is asynchronous, so wait on the grid the child actually settled on
  -- rather than on a fixed sleep that a loaded runner can outlast.
  local function resize(w, h)
    call('nvim_ui_try_resize', w, h)
    local settled = false
    for _ = 1, 60 do
      local grid = lua([[return { vim.o.columns, vim.o.lines }]])
      if grid[1] == w and grid[2] == h then settled = true break end
      vim.wait(25, function() return false end)
    end
    check(settled, 'grid settles at ' .. w .. 'x' .. h)
  end

  -- The splash reads keys through buffer-local mappings, so input has to be remapped ('m')
  -- and the typeahead flushed before the call returns ('x') or the next snapshot races the
  -- redraw the mapping triggers.
  local function press(keys)
    lua([[vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(..., true, false, true), 'mx', false)]], keys)
  end

  -- The splash is a screen, not a document. At every size the float covers the whole grid,
  -- the buffer is exactly as long as the float is tall, and the viewport sits at the top;
  -- the buffer outliving a shrink is what used to scroll the menu away on the next key.
  local function anchored(label)
    local s = snapshot()
    check(s.width == s.columns and s.height == s.lines - 1, label .. ': float covers the grid')
    check(s.rows == s.height, label .. ': buffer length tracks the window')
    check(s.view.topline == 1 and s.view.leftcol == 0, label .. ': viewport stays anchored')
    check(s.scrolloff == 0 and s.winbar == '', label .. ': window options stay locked')
    check(s.filetype == 'splash', label .. ': splash keeps its filetype')
  end

  -- Which view is drawn is not exposed, so read it off the screen: the menu carries its own
  -- row labels and the picker replaces them with a title and a help line of its own.
  local function shows(text)
    return lua([[local needle = ...
      local screen = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
      return screen:find(needle, 1, true) ~= nil]], text)
  end

  -- A full wrap of the four-row menu and one step back. The reported symptom was the menu
  -- creeping upward on the keypress after a resize, so every size navigates before moving on.
  local function navigate(label)
    for i = 1, 4 do
      press('j')
      anchored(label .. ' down ' .. i)
    end
    press('k')
    anchored(label .. ' up')
  end

  anchored('initial 120x40')
  navigate('initial 120x40')

  resize(75, 24)
  anchored('shrunk 75x24')
  navigate('shrunk 75x24')

  -- MIN_COLS and MIN_ROWS: the smallest grid the splash agrees to open on at all
  resize(40, 11)
  anchored('minimum 40x11')
  navigate('minimum 40x11')

  -- Under the minimum M.show would have stepped aside, but render() carries no such guard,
  -- so the splash has to survive a terminal dragged smaller rather than trip its own pcall.
  resize(30, 8)
  anchored('below minimum 30x8')
  navigate('below minimum 30x8')

  -- Growing back is its own path: the buffer has to lengthen again, not keep a short screen.
  resize(100, 30)
  anchored('grown 100x30')
  navigate('grown 100x30')

  resize(120, 40)
  anchored('restored 120x40')

  -- The picker centres its own block and pins a help line at rows - 3, so it needs the same
  -- treatment. Esc returns to the menu from here; from the menu it would close the splash.
  check(shows('Launch'), 'the menu is what the resizes were drawn on')
  press('n')
  check(shows('~/dev'), 'n opens the directory picker')
  anchored('picker 120x40')
  resize(48, 14)
  anchored('picker 48x14')
  navigate('picker 48x14')
  press('<Esc>')
  check(shows('Launch'), 'esc returns to the menu')
  anchored('menu after picker')
end)
child:kill('sigterm')
for _, handle in ipairs({ stdin, stdout, stderr, child }) do if not handle:is_closing() then handle:close() end end
assert(ok, err)
print('ui: ' .. checks .. ' checks passed')
