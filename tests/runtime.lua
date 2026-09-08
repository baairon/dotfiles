vim.opt.rtp:prepend(vim.fn.getcwd() .. '/nvim')
local checks = 0
local function check(ok, label) assert(ok, label); checks = checks + 1 end
local function wait(predicate) check(vim.wait(2000, predicate, 5), 'asynchronous work completed') end

-- Burst requests become one job; newer requests invalidate old results immediately.
local jobs = {}
local refresh = require('config.workspace.refresh').new(10, function(valid, done)
  jobs[#jobs + 1] = { valid = valid, done = done }
end)
for _ = 1, 20 do refresh.request() end
wait(function() return #jobs == 1 end)
check(jobs[1].valid(), 'current job can publish')
refresh.request()
check(not jobs[1].valid(), 'new request invalidates running job')
vim.wait(25, function() return false end)
check(#jobs == 1, 'jobs never overlap')
jobs[1].done()
check(#jobs == 2, 'one pending job runs after completion')
refresh.stop()
check(not jobs[2].valid(), 'shutdown invalidates callbacks')
jobs[2].done()
refresh.request()
check(#jobs == 2, 'shutdown prevents new work')

-- Controlled process completions exercise the real gitstat collection pipeline.
local system = vim.system
local processes, redraws = {}, 0
vim.system = function(argv, opts, callback)
  processes[#processes + 1] = { argv = argv, cwd = opts.cwd, callback = callback }
end
package.loaded['config.layout'] = { refresh_winbars = function() redraws = redraws + 1 end }
local stats = require('config.gitstat')
stats.setup()
local count = #vim.api.nvim_get_autocmds({ group = 'WorkspaceGitstat' })
stats.setup()
check(#vim.api.nvim_get_autocmds({ group = 'WorkspaceGitstat' }) == count, 'setup does not duplicate events')
for _ = 1, 20 do stats.refresh() end
wait(function() return #processes == 1 end)
local function respond(index, stdout, code)
  processes[index].callback({ stdout = stdout, code = code or 0 })
  vim.wait(10, function() return false end)
end
respond(1, 'C:/fixture\n')
respond(2, 'example\n')
respond(3, '2\t1\ttracked.txt\0')
local names = {}
for i = 1, 205 do names[i] = 'new-' .. i .. '.txt' end
respond(4, table.concat(names, '\0') .. '\0')
check(#processes == 8, 'only four untracked counters start')
for i = 5, 204 do
  check(#processes - i + 1 <= 4, 'counter concurrency stays bounded')
  respond(i, '3\t0\tnew.txt\0', 1)
end
check(stats.totals.files == 206 and stats.totals.a == 602 and stats.totals.d == 1, 'counts preserve the 200-file cap')
check(stats.root == 'C:/fixture' and stats.branch == 'example', 'root and branch publish with rows')
check(redraws == 1, 'one completed snapshot requests one header repaint')

-- Invalidated work cannot overwrite the displayed snapshot.
stats.refresh()
wait(function() return #processes == 205 end)
stats.refresh()
respond(205, 'obsolete\n')
check(stats.branch == 'example', 'obsolete branch is discarded')
vim.api.nvim_exec_autocmds('VimLeavePre', { group = 'WorkspaceGitstat' })
vim.system = system

-- Real buffers and windows catch cross-repository aliasing and late result delivery.
processes = {}
vim.system = function(argv, opts, callback) processes[#processes + 1] = { callback = callback } end
local top = vim.api.nvim_get_current_win()
package.loaded['config.layout'].editor_winid = function() return top end
local diff = require('config.workspace.diff')
local patch = '@@ -1 +1 @@\n-before\n+after\n'
diff.open_file_diff('shared.txt', false, 'C:/one')
respond(1, patch)
local first = vim.api.nvim_get_current_buf()
diff.open_file_diff('shared.txt', false, 'C:/two')
respond(2, patch)
local second = vim.api.nvim_get_current_buf()
check(first ~= second, 'same path in different repos has separate buffers')
check(vim.b[first].workspace_diff.root == 'C:/one', 'first diff keeps its repository')
diff.open_file_diff('old.txt', false, 'C:/one')
diff.open_file_diff('latest.txt', false, 'C:/one')
respond(4, patch)
local latest = vim.api.nvim_get_current_buf()
respond(3, patch)
check(vim.api.nvim_get_current_buf() == latest, 'late request cannot replace newer diff')
diff.open_file_diff('away.txt', false, 'C:/one')
vim.cmd('enew')
local away = vim.api.nvim_get_current_buf()
respond(5, patch)
check(vim.api.nvim_get_current_buf() == away, 'late request cannot replace a newly selected buffer')
vim.api.nvim_buf_delete(first, { force = true })
diff.open_file_diff('shared.txt', false, 'C:/one')
respond(6, patch)
check(vim.api.nvim_get_current_buf() ~= first, 'wiped diff can be reopened')
vim.system = system

local spec = dofile('nvim/lua/plugins/smear-cursor.lua')
check(not spec.opts.smear_terminal_mode and not spec.opts.smear_insert_mode, 'native cursor in terminal and insert modes')
check(vim.tbl_contains(spec.opts.filetypes_disabled, 'splash'), 'splash excluded from animation')
check(spec.opts.cursor_color == '#f5e0dc' and spec.opts.normal_bg == '#1e1e2e', 'smear names mocha cursor and ground')
check(type(spec.config) == 'function', 'smear config strips the hideable cursor')

dofile('nvim/lua/config/options.lua')
check(vim.o.guicursor:find('t:block%-TermCursor', 1, false) and vim.o.guicursor:find('i%-ci%-ve:block%-Cursor', 1, false), 'insert and terminal use a block cursor')
check(not vim.o.guicursor:find('SmearCursorHideable', 1, true), 'guicursor is not hideable before smear loads')

dofile('nvim/lua/config/theme.lua')
local function hex(n) return n and string.format('#%06x', n) or nil end
local cursor = vim.api.nvim_get_hl(0, { name = 'Cursor', link = false })
check(hex(cursor.fg) == '#f5e0dc' and hex(cursor.bg) == '#f5e0dc', 'Cursor is rosewater on both sides')
local visual = vim.api.nvim_get_hl(0, { name = 'Visual', link = false })
check(hex(visual.bg) == '#45475a', 'Visual has an opaque surface band')

-- The statusline names panels away from their own headers, so every marker a panel
-- advertises has to keep resolving to the label the bottom row shows.
local chrome = require('config.chrome')
local scratch = vim.api.nvim_create_buf(false, true)
check(chrome.title(scratch) == 'Untitled', 'an unnamed buffer is Untitled')
vim.b[scratch].neo_tree_source = 'filesystem'
check(chrome.title(scratch) == 'Explorer', 'the file tree is Explorer')
vim.b[scratch].neo_tree_source = 'git_status'
check(chrome.title(scratch) == 'Source Control', 'the git rail is Source Control')
vim.b[scratch].neo_tree_source = nil
vim.b[scratch].workspace_gitstat = true
check(chrome.title(scratch) == 'Changes', 'the gitstat panel is Changes')
vim.b[scratch].workspace_gitstat = nil
vim.b[scratch].workspace_diff = { rel = 'nvim/lua/config/splash.lua', root = 'C:/one', new = false }
check(chrome.title(scratch) == 'splash.lua (working tree)', 'a diff is named for its file')
vim.b[scratch].workspace_diff = { rel = 'lua/chrome.lua', root = 'C:/one', new = true }
check(chrome.title(scratch) == 'chrome.lua (untracked)', 'a new file diff says untracked')
vim.b[scratch].workspace_diff = nil
vim.bo[scratch].filetype = 'splash'
check(chrome.title(scratch) == 'Welcome', 'the splash is Welcome')
vim.bo[scratch].filetype = ''
local named = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(named, 'C:/one/thing.lua')
check(chrome.title(named) == nil, 'an ordinary file keeps its own path')
check(chrome.title(999999) == nil, 'a wiped buffer names nothing')
print('runtime: ' .. checks .. ' checks passed')
