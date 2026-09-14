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

-- The battery block has to pick its glyph and colour from the reading alone, and a statusline
-- that repaints constantly must not query the system on every draw.
local function fresh_battery()
  package.loaded['config.battery'] = nil
  return require('config.battery')
end
local battery = fresh_battery()
local glyph = function(s) return battery.format(s):match('^(.-) ') end
check(glyph({ percent = 5 }) == string.char(0xEF, 0x89, 0x84), 'nearly flat shows empty')
check(glyph({ percent = 30 }) == string.char(0xEF, 0x89, 0x83), 'low shows a quarter')
check(glyph({ percent = 55 }) == string.char(0xEF, 0x89, 0x82), 'middle shows half')
check(glyph({ percent = 80 }) == string.char(0xEF, 0x89, 0x81), 'high shows three quarters')
check(glyph({ percent = 100 }) == string.char(0xEF, 0x89, 0x80), 'charged shows full')
check(battery.format({ percent = 42, plugged = true, charging = true }) == string.char(0xEF, 0x83, 0xA7) .. ' 42%', 'charging shows the bolt')
check(glyph({ percent = 100, plugged = true }) == string.char(0xF3, 0xB0, 0x9A, 0xA5), 'plugged in but not charging shows the plug')
check(battery.format(nil) == '', 'no battery formats to nothing')
-- each band's last percent keeps its glyph and the next one moves on
for _, edge in ipairs({ { 10, 0x84 }, { 11, 0x83 }, { 35, 0x83 }, { 36, 0x82 }, { 60, 0x82 }, { 61, 0x81 }, { 85, 0x81 }, { 86, 0x80 } }) do
  check(glyph({ percent = edge[1] }) == string.char(0xEF, 0x89, edge[2]), edge[1] .. '% sits in its band')
end
check(battery.highlight({ percent = 20 }) == 'WorkspaceDiffDel', '20% on battery is already red')
check(battery.highlight({ percent = 21 }) == 'WorkspacePanelTitle', '21% on battery is not red yet')
check(battery.highlight({ percent = 15 }) == 'WorkspaceDiffDel', 'low on battery is red')
check(battery.highlight({ percent = 15, plugged = true, charging = true }) == 'WorkspaceDiffAdd', 'charging is green')
check(battery.highlight({ percent = 15, plugged = true }) == 'WorkspacePanelTitle', 'low but held on mains is not an alarm')
check(battery.highlight({ percent = 70 }) == 'WorkspacePanelTitle', 'ordinary charge keeps the title tone')

-- A desktop never shows the block, including one whose UPS reports itself as a battery.
check(battery.system_battery({ SystemBatteriesPresent = 1, BatteriesAreShortTerm = 0 }), 'a system battery is a laptop')
check(not battery.system_battery({ SystemBatteriesPresent = 0, BatteriesAreShortTerm = 0 }), 'no battery is a PC')
check(not battery.system_battery({ SystemBatteriesPresent = 1, BatteriesAreShortTerm = 1 }), 'a UPS is a PC')

-- Windows packs "no battery" and "unknown" into the same flag byte, and unknown carries the
-- charging bit, so neither may reach the block as a reading.
local function power(flag, percent, line)
  return battery.from_power_status({ BatteryFlag = flag, BatteryLifePercent = percent, ACLineStatus = line })
end
check(power(128, 100, 1) == nil, 'no system battery is no reading')
check(power(255, 42, 1) == nil, 'an unknown flag is not read as charging')
check(power(1, 255, 0) == nil, 'an unknown percent is no reading')
local topping_up = power(8 + 1, 70, 1)
check(topping_up.charging and topping_up.plugged and topping_up.percent == 70, 'the charging bit on mains is charging')
local draining = power(1, 70, 0)
check(not draining.charging and not draining.plugged, 'on battery is neither charging nor plugged')
check(not power(0, 50, 255).plugged, 'an unknown line status is not mains')

battery = fresh_battery()
local detects, samples = 0, 0
battery.detect = function() detects = detects + 1; return false end
battery.sample = function() samples = samples + 1; return { percent = 50 } end
for _ = 1, 5 do battery.read() end
check(detects == 1 and samples == 0 and battery.read() == nil, 'a PC is detected once and never polled')

-- A reader that raises would trip lualine's error limit and stop the whole statusline.
battery = fresh_battery()
detects = 0
battery.detect = function() detects = detects + 1; error('no power api') end
local hidden = true
for _ = 1, 5 do hidden = hidden and battery.read() == nil end
check(hidden and detects == 1, 'a failed detection hides the block and is not retried')
battery = fresh_battery()
battery.detect = function() return true end
battery.sample = function() error('read failed') end
check(battery.status() == nil, 'a failed sample is no reading rather than an error')

-- Plugging in has to show up once the short hold lapses, without polling on every draw.
local now, uv_now = 0, vim.uv.now
vim.uv.now = function() return now end
battery = fresh_battery()
battery.detect = function() return true end
local reading = { percent = 50, plugged = false, charging = false }
samples = 0
battery.sample = function() samples = samples + 1; return reading end
for _ = 1, 50 do battery.status() end
check(samples == 1, 'repeated draws share one reading')
reading = { percent = 50, plugged = true, charging = true }
now = 1999
check(not battery.status().plugged, 'a reading is held inside the window')
now = 2000
check(battery.status().charging and samples == 2, 'plugging in is picked up after the window')

-- The component's text goes through nvim's statusline parser, where a bare '%' blanks the line.
reading = { percent = 42, plugged = false, charging = false }
now = 10000
local lualine_opts
package.loaded['lualine'] = { setup = function(opts) lualine_opts = opts end }
package.loaded['config.battery'] = battery
dofile('nvim/lua/plugins/lualine.lua').config()
local block = lualine_opts.sections.lualine_y[2]
check(block.cond(), 'the block shows on a laptop')
check(lualine_opts.sections.lualine_y[1].cond(), 'the divider shows with the block')
local rendered = vim.api.nvim_eval_statusline(block[1](), {}).str
check(rendered:find('42%', 1, true) ~= nil, 'the percentage renders through the statusline parser')
local desktop = fresh_battery()
desktop.detect = function() return false end
dofile('nvim/lua/plugins/lualine.lua').config()
local y = lualine_opts.sections.lualine_y
check(not y[1].cond() and not y[2].cond(), 'a PC drops the block and its divider')
vim.uv.now = uv_now
package.loaded['lualine'] = nil
print('runtime: ' .. checks .. ' checks passed')
