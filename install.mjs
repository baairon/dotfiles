#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HOME = os.homedir();
const PLATFORM = process.platform;

const DOTFILES_REPO = 'https://github.com/baairon/dotfiles';

// Two rules for working here, neither of which belongs to any single line below.
//
//   1. Nothing tracked in this repo may name what is installed on a particular machine. It is
//      public. Comments and test fixtures use invented placeholders; the real manifest is
//      machine/machine.json and is gitignored, and machine/machine.example.json is the tracked
//      shape, carrying only the toolchain this repo itself needs.
//   2. Run `--dry-run` and `--selftest` before proposing a change.

// This file ships inside the repo it deploys, so `git clone && node install.mjs` has to
// work with no flags at all. The folders it looks for are the deploy sources, not just any
// directory: a copy of this script sitting somewhere else finds nothing and falls through
// to the clone path exactly as before.
const SELF_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_MARKERS = ['fonts', 'tabby', 'nvim', 'shell', 'machine'];

function looksLikeRepo(dir) {
  return REPO_MARKERS.some((d) => isDir(path.join(dir, d)));
}

// Which checkout the read-only commands (--list) should read. Deliberately never clones, and
// deliberately shared: when only resolveRepo knew about the self checkout, `--list` run from
// inside the repo answered "no machine/machine.json on disk" while standing in the repo,
// because it was still looking in the clone cache. One resolver, one answer.
function listCheckout(opts) {
  if (opts.repo && isDir(opts.repo)) return opts.repo;
  if (looksLikeRepo(SELF_DIR)) return SELF_DIR;
  return cacheRepoDir();
}

function tabbyConfigDir() {
  if (PLATFORM === 'win32') {
    const appData = process.env.APPDATA || path.join(HOME, 'AppData', 'Roaming');
    return path.join(appData, 'tabby');
  }
  if (PLATFORM === 'darwin') {
    return path.join(HOME, 'Library', 'Application Support', 'tabby');
  }
  const xdg = process.env.XDG_CONFIG_HOME || path.join(HOME, '.config');
  return path.join(xdg, 'tabby');
}

function nvimConfigDir() {
  if (PLATFORM === 'win32') {
    const localAppData = process.env.LOCALAPPDATA || path.join(HOME, 'AppData', 'Local');
    return path.join(localAppData, 'nvim');
  }
  const xdg = process.env.XDG_CONFIG_HOME || path.join(HOME, '.config');
  return path.join(xdg, 'nvim');
}

// Per-user font dir on every platform: none of these need elevation.
function fontsDir() {
  if (PLATFORM === 'win32') {
    const localAppData = process.env.LOCALAPPDATA || path.join(HOME, 'AppData', 'Local');
    return path.join(localAppData, 'Microsoft', 'Windows', 'Fonts');
  }
  if (PLATFORM === 'darwin') {
    return path.join(HOME, 'Library', 'Fonts');
  }
  const xdgData = process.env.XDG_DATA_HOME || path.join(HOME, '.local', 'share');
  return path.join(xdgData, 'fonts');
}

const TABBY_DIR = tabbyConfigDir();
const TABBY_CONFIG = path.join(TABBY_DIR, 'config.yaml');
const NVIM_DIR = nvimConfigDir();
const FONTS_DIR = fontsDir();
const FONTS_REG_KEY = 'HKCU\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts';
const RUN_KEY = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run';
const STARTUP_APPROVED_KEY = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run';
const USER_SHELL_FOLDERS_KEY = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders';

const exists = (p) => {
  try { fs.accessSync(p); return true; } catch { return false; }
};

const isDir = (p) => {
  try { return fs.statSync(p).isDirectory(); } catch { return false; }
};

function safeTimestamp() {
  return new Date().toISOString().replace(/[:.]/g, '-');
}

function backupPath(target) {
  return `${target}.bak-${safeTimestamp()}`;
}

function onPath(bin) {
  const exts = PLATFORM === 'win32' ? ['.exe', '.cmd', '.bat', ''] : [''];
  for (const dir of (process.env.PATH || '').split(path.delimiter)) {
    if (!dir) continue;
    for (const ext of exts) {
      if (exists(path.join(dir, bin + ext))) return true;
    }
  }
  return false;
}

function git(args) {
  return execFileSync('git', args, { stdio: 'pipe', encoding: 'utf8' });
}

function cacheRepoDir() {
  return PLATFORM === 'win32'
    ? path.join(process.env.LOCALAPPDATA || path.join(HOME, 'AppData', 'Local'), 'dotfiles-cache')
    : path.join(process.env.XDG_CACHE_HOME || path.join(HOME, '.cache'), 'dotfiles');
}

function resolveRepo(opts) {
  if (opts.repo) {
    if (!isDir(opts.repo)) throw new Error(`--repo path not found: ${opts.repo}`);
    if (!looksLikeRepo(opts.repo)) {
      throw new Error(`--repo has no ${REPO_MARKERS.map((d) => `${d}/`).join(', ')} folder: ${opts.repo}`);
    }
    return { dir: opts.repo, cloned: false };
  }
  // Running from inside a checkout: deploy that checkout. Cloning a second copy into the
  // cache would mean deploying something other than the files sitting right here, which is
  // the one behaviour nobody expects from a script they just cloned and ran.
  if (looksLikeRepo(SELF_DIR)) return { dir: SELF_DIR, cloned: false, self: true };
  if (!onPath('git')) {
    throw new Error('git not on PATH (needed to clone the dotfiles repo); install git or pass --repo <local checkout>');
  }
  const cacheRoot = cacheRepoDir();
  if (isDir(path.join(cacheRoot, '.git'))) {
    try { git(['-C', cacheRoot, 'pull', '--ff-only']); } catch { /* offline: reuse the cached checkout */ }
    return { dir: cacheRoot, cloned: false };
  }
  fs.mkdirSync(path.dirname(cacheRoot), { recursive: true });
  git(['clone', '--depth', '1', DOTFILES_REPO, cacheRoot]);
  return { dir: cacheRoot, cloned: true };
}

// Windows registers a font under its full name plus format. The vendored files are
// named after the family they register as (CozetteVector.ttf -> "CozetteVector"), so
// the base name is the value name and the name table never has to be parsed.
//
// The format suffix is not decorative: Windows keys on it, and an OpenType file
// registered as "(TrueType)" is the one way to get a value that looks correct in the
// registry while the font never appears in an application's font list.
function fontRegistryName(file) {
  const ext = path.extname(file);
  const format = /^\.otf$/i.test(ext) ? 'OpenType' : 'TrueType';
  return `${path.basename(file, ext)} (${format})`;
}

function psQuote(s) {
  return `'${String(s).replace(/'/g, "''")}'`;
}

// AddFontResourceW + a WM_FONTCHANGE broadcast make the font usable in the running
// session. Without it the registry entry only takes effect for apps started after the
// next logon, which would mean deploying a Tabby profile naming a font Tabby can't see.
function activateFontsWindows(dests) {
  const decl = '[DllImport("gdi32.dll", CharSet=CharSet.Unicode)] public static extern int AddFontResourceW(string p);'
    + ' [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint f, uint t, out IntPtr r);';
  const script = [
    `Add-Type -Name Fonts -Namespace Win32 -MemberDefinition '${decl}'`,
    `$paths = @(${dests.map(psQuote).join(',')})`,
    'foreach ($p in $paths) { [void][Win32.Fonts]::AddFontResourceW($p) }',
    '$r = [IntPtr]::Zero',
    // HWND_BROADCAST, WM_FONTCHANGE, SMTO_ABORTIFHUNG, 1s timeout
    '[void][Win32.Fonts]::SendMessageTimeout([IntPtr]0xffff, 0x1D, [IntPtr]::Zero, [IntPtr]::Zero, 2, 1000, [ref]$r)',
  ].join('\n');
  execFileSync('powershell', ['-NoProfile', '-NonInteractive', '-Command', script], { stdio: 'pipe' });
}

// fonts/ holds the one the terminal profile names, so it is always deployed. fonts/optional/
// holds faces that are kept here to travel with the machine but are not part of the setup, so
// they install only when asked for. Keeping them in a subfolder rather than behind a filename
// convention is what makes the default set impossible to widen by accident.
function fontSources(repoDir, opts) {
  const src = path.join(repoDir, 'fonts');
  if (!isDir(src)) return null;
  const pick = (dir, re) => (isDir(dir) ? fs.readdirSync(dir).filter((f) => re.test(f)).sort() : []);

  const rows = pick(src, /\.ttf$/i).map((name) => ({ name, from: path.join(src, name) }));
  if (opts.optionalFonts) {
    const optDir = path.join(src, 'optional');
    for (const name of pick(optDir, /\.(ttf|otf)$/i)) rows.push({ name, from: path.join(optDir, name) });
  }
  return rows;
}

function deployFonts(repoDir, opts) {
  const src = path.join(repoDir, 'fonts');
  const rows = fontSources(repoDir, opts);
  if (!rows) return { ok: false, msg: `repo has no fonts/ folder (${src})` };
  if (!rows.length) return { ok: false, msg: `no font files in ${src}` };
  const files = rows.map((r) => r.name);

  if (opts.dryRun) {
    return { ok: true, msg: `would install ${files.length} font(s) into ${FONTS_DIR}: ${files.join(', ')}` };
  }

  fs.mkdirSync(FONTS_DIR, { recursive: true });
  const dests = [];
  const written = [];
  const unchanged = [];
  let backup = null;

  for (const { name: f, from } of rows) {
    const dest = path.join(FONTS_DIR, f);
    dests.push(dest);
    // A registered font file is usually open, and rewriting identical bytes would
    // risk EBUSY for nothing, so only copy when the file actually differs.
    if (exists(dest) && fs.readFileSync(dest).equals(fs.readFileSync(from))) {
      unchanged.push(f);
      continue;
    }
    if (exists(dest)) {
      backup = backupPath(dest);
      fs.copyFileSync(dest, backup);
    }
    fs.copyFileSync(from, dest);
    written.push(f);
  }

  const notes = [];
  if (PLATFORM === 'win32') {
    for (const dest of dests) {
      // /f overwrites the same value name, so repeat runs re-point rather than duplicate
      execFileSync('reg', ['add', FONTS_REG_KEY, '/v', fontRegistryName(dest), '/t', 'REG_SZ', '/d', dest, '/f'], { stdio: 'pipe' });
    }
    try {
      activateFontsWindows(dests);
    } catch (err) {
      notes.push(`registered, but session activation failed (${err.code || err.message}); log out and back in to use them`);
    }
  } else if (PLATFORM !== 'darwin' && onPath('fc-cache')) {
    try {
      execFileSync('fc-cache', ['-f', FONTS_DIR], { stdio: 'pipe' });
    } catch (err) {
      notes.push(`fc-cache failed (${err.code || err.message}); run it by hand`);
    }
  }

  const summary = written.length
    ? `installed ${written.join(', ')} into ${FONTS_DIR}`
    : `already current in ${FONTS_DIR} (${unchanged.join(', ')})`;
  return { ok: true, backup, msg: notes.length ? `${summary}; ${notes.join('; ')}` : summary };
}

function deployTabby(repoDir, opts) {
  const src = path.join(repoDir, 'tabby', 'config.yaml');
  if (!exists(src)) return { ok: false, msg: `repo has no tabby/config.yaml (${src})` };
  if (opts.dryRun) {
    const action = exists(TABBY_CONFIG) ? `back up and overwrite ${TABBY_CONFIG}` : `create ${TABBY_CONFIG}`;
    return { ok: true, msg: `would ${action}` };
  }
  fs.mkdirSync(TABBY_DIR, { recursive: true });
  let backup = null;
  if (exists(TABBY_CONFIG)) {
    backup = backupPath(TABBY_CONFIG);
    fs.copyFileSync(TABBY_CONFIG, backup);
  }
  fs.copyFileSync(src, TABBY_CONFIG);
  return { ok: true, backup, msg: `deployed ${TABBY_CONFIG}` };
}

function deployNvim(repoDir, opts) {
  const src = path.resolve(path.join(repoDir, 'nvim'));
  if (!isDir(src)) return { ok: false, msg: `repo has no nvim/ folder (${src})` };
  if (opts.dryRun) {
    const verb = isDir(NVIM_DIR) ? 'back up and symlink' : 'symlink';
    return { ok: true, msg: `would ${verb} ${NVIM_DIR} -> ${src}` };
  }
  let backup = null;
  if (isDir(NVIM_DIR)) {
    // isDir follows junctions/symlinks, so renaming backs up a real dir or moves an
    // existing link aside without touching its target. Never recursive-delete: that
    // could wipe the repo through a junction.
    backup = backupPath(NVIM_DIR);
    fs.renameSync(NVIM_DIR, backup);
  }
  // Symlink so the editor always reads the repo directly (no cached copy to drift).
  // Windows junctions need no elevation; 'dir' symlinks cover macOS/Linux.
  try {
    fs.symlinkSync(src, NVIM_DIR, PLATFORM === 'win32' ? 'junction' : 'dir');
    return { ok: true, backup, msg: `linked ${NVIM_DIR} -> ${src}` };
  } catch (err) {
    // Rare: no symlink privilege. Fall back to a copy so a rollout never hard-fails.
    fs.cpSync(src, NVIM_DIR, { recursive: true });
    return { ok: true, backup, msg: `copied ${NVIM_DIR} (symlink unavailable: ${err.code || err.message})` };
  }
}

// ---------------------------------------------------------------------------
// Shell layer: bash, readline, git.
// ---------------------------------------------------------------------------

// Repo file -> absolute destination, every one of them under $HOME. The prompt is the odd
// entry: ~/.config/git/git-prompt.sh is the path Git for Windows itself looks for before
// building its own PS1, so deploying there is taking a documented hook rather than
// overriding anything. shell/git-prompt.sh explains what that hook has to do in return.
function shellTargets() {
  return [
    { src: 'bashrc', dest: path.join(HOME, '.bashrc') },
    { src: 'bash_profile', dest: path.join(HOME, '.bash_profile') },
    { src: 'inputrc', dest: path.join(HOME, '.inputrc') },
    { src: 'gitconfig', dest: path.join(HOME, '.gitconfig') },
    { src: 'gitignore_global', dest: path.join(HOME, '.gitignore_global') },
    { src: 'git-prompt.sh', dest: path.join(HOME, '.config', 'git', 'git-prompt.sh') },
  ];
}

// Sourced or included last by the tracked files above, and never written over once they
// exist. These are what make a whole-file deploy safe: without somewhere local to put a
// machine-specific setting, the first one forces a choice between editing a tracked file
// and losing it on the next rollout.
const SHELL_LOCALS = [
  {
    dest: () => path.join(HOME, '.bashrc.local'),
    body: '# Machine-specific shell settings. Sourced at the end of ~/.bashrc, so anything\n'
      + '# here overrides the deployed file. Never tracked by the dotfiles repo.\n',
  },
  {
    dest: () => path.join(HOME, '.gitconfig.local'),
    body: '# Machine-specific git settings. Included at the end of ~/.gitconfig, so anything\n'
      + '# here overrides the deployed file. Never tracked by the dotfiles repo.\n'
      + '#\n'
      + '# On Linux or macOS this is where autocrlf belongs:\n'
      + '#   [core]\n'
      + '#       autocrlf = input\n',
  },
];

// Bash refuses to run a script with CRLF line endings, so a checkout made without the
// repo's .gitattributes (a zip download, or a clone under a stray core.autocrlf) would
// otherwise deploy a .bashrc that greets every login with $'\r': command not found.
// Normalizing on write costs nothing and removes the whole failure class.
function readShellSource(file) {
  return fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
}

function deployShell(repoDir, opts) {
  const srcDir = path.join(repoDir, 'shell');
  if (!isDir(srcDir)) return { ok: false, msg: `repo has no shell/ folder (${srcDir})` };

  const targets = shellTargets();
  const missing = targets.filter((t) => !exists(path.join(srcDir, t.src)));
  if (missing.length === targets.length) {
    return { ok: false, msg: `repo's shell/ folder has none of the expected files (${srcDir})` };
  }

  if (opts.dryRun) {
    const lines = targets.map((t) => {
      if (!exists(path.join(srcDir, t.src))) return `      [skip] ${t.src} not in the repo`;
      const verb = exists(t.dest) ? 'back up and overwrite' : 'create';
      return `      would ${verb} ${t.dest}`;
    });
    for (const l of SHELL_LOCALS) {
      const d = l.dest();
      lines.push(exists(d) ? `      would leave ${d} alone (exists)` : `      would create ${d} (escape hatch, empty)`);
    }
    return { ok: true, msg: `shell layer:\n${lines.join('\n')}` };
  }

  const written = [];
  const unchanged = [];
  const backups = [];
  for (const t of targets) {
    const src = path.join(srcDir, t.src);
    if (!exists(src)) continue;
    const body = readShellSource(src);
    // Identical content is left alone, so a repeat rollout is a no-op instead of a fresh
    // pile of timestamped backups next to every dotfile.
    if (exists(t.dest) && fs.readFileSync(t.dest, 'utf8') === body) {
      unchanged.push(path.basename(t.dest));
      continue;
    }
    fs.mkdirSync(path.dirname(t.dest), { recursive: true });
    if (exists(t.dest)) {
      const backup = backupPath(t.dest);
      fs.copyFileSync(t.dest, backup);
      backups.push(path.basename(backup));
    }
    fs.writeFileSync(t.dest, body);
    written.push(path.basename(t.dest));
  }

  const created = [];
  for (const l of SHELL_LOCALS) {
    const dest = l.dest();
    if (exists(dest)) continue;
    fs.writeFileSync(dest, l.body);
    created.push(path.basename(dest));
  }

  const notes = [];
  if (written.length) notes.push(`deployed ${written.join(', ')}`);
  if (unchanged.length) notes.push(`already current: ${unchanged.join(', ')}`);
  if (created.length) notes.push(`created empty ${created.join(', ')}`);
  return {
    ok: true,
    backup: backups.length ? backups.join(', ') : null,
    msg: notes.join('; ') || 'nothing to do',
  };
}

// ---------------------------------------------------------------------------
// Machine layer: software, login startup, user folders, privacy.
// ---------------------------------------------------------------------------

function machineManifestPath(repoDir) {
  return path.join(repoDir, 'machine', 'machine.json');
}

function readManifest(repoDir) {
  const file = machineManifestPath(repoDir);
  if (!exists(file)) return null;
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

// machine.json is gitignored, so a fresh clone has none. The tracked example still carries the
// toolchain this repo needs, which is enough to answer "what should I install" even though it is
// never enough to APPLY: deploying generic entries to a real machine would be wrong. Read it only
// where the answer is an install hint.
function readExampleManifest(repoDir) {
  const file = path.join(repoDir, 'machine', 'machine.example.json');
  if (!exists(file)) return null;
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}

// Expand %VAR% against the environment. The name pattern deliberately requires a
// non-digit first character so URL escapes survive: some startup arguments carry a
// URL-encoded app name like "%20", and a looser pattern would eat it as a variable.
function expandEnv(s) {
  return String(s).replace(/%([A-Za-z_][A-Za-z0-9_()]*)%/g, (whole, name) => {
    const key = Object.keys(process.env).find((k) => k.toLowerCase() === name.toLowerCase());
    return key === undefined ? whole : process.env[key];
  });
}

// Startup entry names are matched by prefix when they end in '*', because Windows
// gives some of its own auto-launch entries a per-machine hex suffix that differs
// on every box.
function matchesPattern(pattern, name) {
  if (!pattern.endsWith('*')) return pattern === name;
  return name.startsWith(pattern.slice(0, -1));
}

// Most entries compose cleanly as "exe" arg arg. A few cannot: some installers register the
// exe UNQUOTED with an ms-protocol argument QUOTED, and that argument contains & and ?, so
// re-composing it in the usual shape would change how the shell parses it. Those entries
// carry an explicit `command` and are written through verbatim.
function runCommandFor(entry) {
  if (entry.command) return expandEnv(entry.command);
  const exe = expandEnv(entry.exe);
  const args = (entry.args || []).map(expandEnv);
  return args.length ? `"${exe}" ${args.join(' ')}` : `"${exe}"`;
}

function regQuery(key, value) {
  try {
    const out = execFileSync('reg', ['query', key, '/v', value], { stdio: 'pipe', encoding: 'utf8' });
    const m = out.match(/REG_(?:SZ|EXPAND_SZ)\s+(.*)$/m);
    return m ? m[1].trim() : null;
  } catch {
    return null;
  }
}

function regValueNames(key) {
  try {
    const out = execFileSync('reg', ['query', key], { stdio: 'pipe', encoding: 'utf8' });
    return out.split(/\r?\n/)
      .map((l) => l.match(/^\s{4}(\S.*?)\s{4,}REG_/))
      .filter(Boolean)
      .map((m) => m[1].trim());
  } catch {
    return [];
  }
}

// Task Manager's per-entry enable/disable flag: 12 bytes where bit 0 of byte 0 is the
// disabled bit. 02.. is enabled, 03.. is disabled. Writing this is what stops a Run
// value being present but silently switched off in the Startup tab.
function startupApprovedBytes(enabled) {
  return (enabled ? '02' : '03') + '00'.repeat(11);
}

function getStartupApproved(name) {
  try {
    const out = execFileSync('reg', ['query', STARTUP_APPROVED_KEY, '/v', name],
      { stdio: 'pipe', encoding: 'utf8' });
    const m = out.match(/REG_BINARY\s+([0-9A-Fa-f]+)/);
    return m ? m[1] : null;
  } catch {
    return null;
  }
}

// Only bit 0 of byte 0 carries the state. Bytes 4..11 are a FILETIME recording when the
// entry was last toggled, which Windows owns.
function startupApprovedEnabled(hex) {
  if (!hex || hex.length < 2) return null;
  return (parseInt(hex.slice(0, 2), 16) & 1) === 0;
}

// Write only when the state bit actually differs. Rewriting unconditionally would zero the
// timestamp bytes on every run, which turns an otherwise idempotent rollout into one that
// reports "no changes" while still dirtying the registry.
function setStartupApproved(name, enabled) {
  if (startupApprovedEnabled(getStartupApproved(name)) === enabled) return false;
  execFileSync('reg', ['add', STARTUP_APPROVED_KEY, '/v', name, '/t', 'REG_BINARY',
    '/d', startupApprovedBytes(enabled), '/f'], { stdio: 'pipe' });
  return true;
}

// The other three steps back their target up to a timestamped file before replacing it.
// Registry writes need the same, or the machine layer is the one unreversible step. One
// .reg file holding all three keys restores with a double-click or `reg import`.
function backupMachineRegistry() {
  const file = path.join(os.tmpdir(), `dotfiles-machine-backup-${safeTimestamp()}.reg`);
  const parts = [];
  for (const key of [RUN_KEY, STARTUP_APPROVED_KEY, USER_SHELL_FOLDERS_KEY]) {
    const tmp = path.join(os.tmpdir(), `dotfiles-regexp-${Math.random().toString(36).slice(2)}.reg`);
    try {
      execFileSync('reg', ['export', key, tmp, '/y'], { stdio: 'pipe' });
      // reg export writes UTF-16LE with a BOM and its own "Windows Registry Editor" header;
      // keep the first header and drop the repeats so the merged file stays importable.
      const text = fs.readFileSync(tmp, 'utf16le').replace(/^﻿/, '');
      parts.push(parts.length === 0 ? text : text.replace(/^Windows Registry Editor[^\r\n]*\r?\n/, ''));
    } catch { /* a key that does not exist yet has nothing to restore */ }
    finally { fs.rmSync(tmp, { force: true }); }
  }
  if (!parts.length) return null;
  fs.writeFileSync(file, '﻿' + parts.join(''), 'utf16le');
  return file;
}

function softwareStatus(manifest) {
  return (manifest.software || []).map((s) => {
    // Declared detection wins over winget, because winget only knows what winget installed.
    // detectOnPath covers the common case: node from the nodejs.org MSI and tree-sitter from
    // `npm i -g` are both absent from `winget list` while sitting right there on PATH, and
    // reporting those as MISSING would be the installer lying about the machine it is on.
    if (s.detectOnPath && onPath(s.detectOnPath)) return { ...s, installed: true };
    // detectPath is the same idea for something that is not on PATH at all, such as a
    // portable exe dropped straight into the Startup folder.
    if (s.detectPath && exists(expandEnv(s.detectPath))) return { ...s, installed: true };
    return { ...s, installed: wingetHas(s.winget) };
  });
}

// Substring-matching the whole `winget list` table does not work: packages winget cannot
// correlate to its catalog are listed under an ARP identifier (`ARP\User\X64\<name>`) rather
// than their catalog id, so they read as missing while installed. An exact per-id query is
// authoritative; exit 0 means installed.
const _wingetSeen = new Map(); // one subprocess per id per run, not per call site
function wingetHas(id) {
  if (!onPath('winget')) return null; // unknown rather than false
  if (_wingetSeen.has(id)) return _wingetSeen.get(id);
  let found;
  try {
    execFileSync('winget', ['list', '--id', id, '-e', '--disable-interactivity'], { stdio: 'pipe' });
    found = true;
  } catch {
    found = false;
  }
  _wingetSeen.set(id, found);
  return found;
}

function applyStartup(manifest, opts, lines) {
  const enabled = (manifest.startup?.enabled || []).filter((e) => e.scope === 'user');
  for (const entry of enabled) {
    if (!entry.exe) {
      lines.push(`    [ERROR  ] ${entry.name}: manifest entry has no 'exe' (needed to test whether it is installed)`);
      continue;
    }
    const exe = expandEnv(entry.exe);
    if (!exists(exe)) {
      lines.push(`    [skip   ] ${entry.name}: not installed (${exe})`);
      continue;
    }
    const want = runCommandFor(entry);
    const have = regQuery(RUN_KEY, entry.name);
    if (have === want) {
      lines.push(`    [ok     ] ${entry.name}`);
      if (!opts.dryRun) setStartupApproved(entry.name, true);
      continue;
    }
    if (opts.dryRun) {
      lines.push(`    [would  ] ${entry.name}: ${have === null ? 'add' : 'update'} -> ${want}`);
      continue;
    }
    execFileSync('reg', ['add', RUN_KEY, '/v', entry.name, '/t', 'REG_SZ', '/d', want, '/f'], { stdio: 'pipe' });
    setStartupApproved(entry.name, true);
    lines.push(`    [${have === null ? 'added  ' : 'updated'}] ${entry.name} -> ${want}`);
  }

  const present = regValueNames(RUN_KEY);
  for (const rule of (manifest.startup?.disabled || []).filter((d) => d.scope === 'user')) {
    for (const name of present.filter((n) => matchesPattern(rule.match, n))) {
      if (opts.dryRun) {
        if (startupApprovedEnabled(getStartupApproved(name)) !== false) lines.push(`    [would  ] disable ${name}`);
        continue;
      }
      lines.push(setStartupApproved(name, false) ? `    [off    ] ${name}` : `    [ok     ] ${name} (already off)`);
    }
  }
}

// How many files sit under a path, stopping as soon as we know it is non-empty. Only used
// to decide "does repointing this orphan anything", so an exact count past a few is waste.
function countFiles(dir, cap = 5000) {
  let n = 0;
  const walk = (d) => {
    if (n >= cap) return;
    let entries;
    try { entries = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      if (n >= cap) return;
      if (e.isDirectory()) walk(path.join(d, e.name));
      else n++;
    }
  };
  walk(dir);
  return n;
}

// A known folder that currently points somewhere else, at a location that still holds files,
// is the cloud-sync case: repointing it silently strands the data. Refuse rather than orphan.
function folderBlocked(current, resolved) {
  if (!current) return null;
  const cur = expandEnv(current);
  if (cur.toLowerCase().replace(/\\+$/, '') === resolved.toLowerCase().replace(/\\+$/, '')) return null;
  if (!isDir(cur)) return null;
  const files = countFiles(cur);
  return files > 0 ? { cur, files } : null;
}

function applyKnownFolders(manifest, opts, lines) {
  const shell = manifest.knownFolders?.shell || [];
  const all = shell.map((f) => ({ ...f, resolved: expandEnv(f.path) }));

  const targets = [];
  for (const f of all) {
    const current = regQuery(USER_SHELL_FOLDERS_KEY, f.regName || f.name);
    const blocked = opts.forceFolders ? null : folderBlocked(current, f.resolved);
    if (blocked) {
      lines.push(`    [BLOCKED] ${f.name}`);
      lines.push(`        current: ${blocked.cur}`);
      lines.push(`        holds  : ${blocked.files} file(s)`);
      lines.push('        move the data first, or pass --force-folders');
      continue;
    }
    targets.push(f);
  }

  for (const f of targets) {
    if (opts.dryRun) {
      lines.push(`    [would  ] ${f.name} -> ${f.resolved}`);
      continue;
    }
    fs.mkdirSync(f.resolved, { recursive: true });
  }
  if (!opts.dryRun && targets.length) {
    const decl = '[DllImport("shell32.dll", CharSet=CharSet.Unicode)] public static extern int '
      + 'SHSetKnownFolderPath(ref System.Guid rfid, uint dwFlags, System.IntPtr hToken, string pszPath);';
    const body = targets.map((f) =>
      `$g = [Guid]${psQuote(f.guid)}; $hr = [Win32.KF]::SHSetKnownFolderPath([ref]$g, 0, [IntPtr]::Zero, ${psQuote(f.resolved)}); `
      + `if ($hr -ne 0) { Write-Output ${psQuote('FAILED ' + f.name)} }`).join('\n');
    const script = [`Add-Type -Name KF -Namespace Win32 -MemberDefinition '${decl}'`, body].join('\n');
    const out = execFileSync('powershell', ['-NoProfile', '-NonInteractive', '-Command', script],
      { stdio: 'pipe', encoding: 'utf8' });
    for (const f of targets) {
      lines.push(out.includes('FAILED ' + f.name)
        ? `    [FAILED ] ${f.name}`
        : `    [ok     ] ${f.name} -> ${f.resolved}`);
    }
  }
  // The 'This PC' nodes are plain registry values; SHSetKnownFolderPath does not cover them,
  // and they are exactly the ones that quietly keep pointing at a removed cloud folder.
  for (const v of (manifest.knownFolders?.userShellFolderValues || [])) {
    const resolved = expandEnv(v.path);
    const blocked = opts.forceFolders ? null : folderBlocked(regQuery(USER_SHELL_FOLDERS_KEY, v.name), resolved);
    if (blocked) {
      lines.push(`    [BLOCKED] ${v.name}`);
      lines.push(`        current: ${blocked.cur}`);
      lines.push(`        holds  : ${blocked.files} file(s)`);
      lines.push('        move the data first, or pass --force-folders');
      continue;
    }
    if (opts.dryRun) {
      lines.push(`    [would  ] ${v.name} -> ${v.path}`);
      continue;
    }
    // REG_EXPAND_SZ with the placeholder left unexpanded, which is how Windows stores its own
    // shell-folder values. Writing a literal C:\Users\<name>\... would not follow a moved profile.
    execFileSync('reg', ['add', USER_SHELL_FOLDERS_KEY, '/v', v.name, '/t', 'REG_EXPAND_SZ',
      '/d', v.path, '/f'], { stdio: 'pipe' });
    lines.push(`    [ok     ] ${v.name} -> ${v.path}`);
  }
}

// Privacy changes need admin, so they are never applied inline: the installer writes a
// script for the user to read and run. That keeps the rollout itself elevation-free.
function writePrivacyScript(manifest) {
  const out = [];
  out.push('# Generated by dotfiles-setup. Review before running, then run as administrator.');
  out.push('# Source of truth: machine/machine.json');
  out.push('');
  for (const s of (manifest.privacy?.services || [])) {
    out.push(`# ${s.why}`);
    out.push(`Stop-Service -Name '${s.name}' -Force -ErrorAction SilentlyContinue`);
    out.push(`& sc.exe config '${s.name}' start= ${String(s.startMode).toLowerCase()}`);
    out.push('');
  }
  for (const t of (manifest.privacy?.scheduledTasks || [])) {
    out.push(`# ${t.why}`);
    out.push(`Disable-ScheduledTask -TaskPath '${t.path}' -TaskName '${t.name}' -ErrorAction SilentlyContinue | Out-Null`);
    out.push('');
  }
  for (const n of (manifest.privacy?.deliberatelyNotApplied || [])) {
    out.push(`# NOT changed on purpose - ${n.name}: ${n.why}`);
  }
  const file = path.join(os.tmpdir(), `dotfiles-privacy-${safeTimestamp()}.ps1`);
  fs.writeFileSync(file, out.join('\n') + '\n', 'utf8');
  return file;
}

function installSoftware(manifest, opts, lines) {
  for (const s of softwareStatus(manifest)) {
    if (s.installed) { lines.push(`    [present] ${s.name}`); continue; }
    if (s.installed === null) { lines.push(`    [unknown] ${s.name} (winget not on PATH)`); continue; }
    if (!opts.installSoftware) {
      lines.push(`    [MISSING] ${s.name}: winget install ${s.winget}`);
      continue;
    }
    if (opts.dryRun) { lines.push(`    [would  ] winget install ${s.winget}`); continue; }
    try {
      execFileSync('winget', ['install', '--id', s.winget, '-e', '--accept-package-agreements',
        '--accept-source-agreements', '--disable-interactivity'],
      { stdio: 'pipe', timeout: 15 * 60 * 1000 }); // a hung install must not wedge the rollout
      lines.push(`    [install] ${s.name}`);
    } catch (err) {
      lines.push(`    [FAILED ] ${s.name}: ${err.message.split('\n')[0]}`);
    }
  }
}

// Cloud-sync folder backups cannot be automated: adding one needs server-assigned IDs
// (VolumeId/ShareId/RootLinkId) that only the sync client can mint against its backend, and the
// mapping has to stay consistent with the client's local sync database. So the manifest carries
// them as a manual checklist and this prints the set to add by hand rather than applying anything.
function cloudSyncLines(manifest, indent) {
  const cs = manifest.cloudSync || {};
  const folders = cs.syncedFolders || [];
  if (!folders.length) return [`${indent}(none declared)`];
  const out = [`${indent}${cs.provider || 'cloud sync'}: add these folders by hand in the app (cannot be automated):`];
  for (const f of folders) {
    const missing = !isDir(expandEnv(f.path));
    out.push(`${indent}  [ ] ${f.path}${missing ? '  (local folder missing)' : ''}`);
  }
  return out;
}

function deployMachine(repoDir, opts) {
  const manifest = readManifest(repoDir);
  if (!manifest) {
    // The real manifest is per-machine and untracked, so a fresh clone genuinely has none.
    // Say what to do about it rather than reporting a bare absence.
    return { ok: false, msg: `no machine/machine.json (${machineManifestPath(repoDir)})\n  copy machine/machine.example.json to machine/machine.json and edit it for this machine` };
  }
  if (PLATFORM !== 'win32') return { ok: false, msg: `machine layer is Windows-only (running on ${PLATFORM})` };

  const lines = [];
  // Snapshot every key this step can touch, before the first write.
  const backup = opts.dryRun ? null : backupMachineRegistry();
  lines.push('  software:');
  installSoftware(manifest, opts, lines);
  lines.push('  startup:');
  applyStartup(manifest, opts, lines);
  lines.push('  user folders:');
  applyKnownFolders(manifest, opts, lines);
  lines.push('  cloud sync:');
  for (const l of cloudSyncLines(manifest, '    ')) lines.push(l);

  if (opts.privacy) {
    if (opts.dryRun) {
      lines.push('  privacy:');
      lines.push('    [would  ] write an elevated script for review');
    } else {
      const file = writePrivacyScript(manifest);
      lines.push('  privacy:');
      lines.push(`    script written: ${file}`);
      lines.push('    review it, then run as administrator (nothing was applied)');
    }
  } else {
    lines.push('  privacy: skipped (pass --privacy to emit the elevated script)');
  }

  return { ok: true, backup, msg: `applied machine/machine.json\n${lines.join('\n')}` };
}

function parseArgs(argv) {
  // machine defaults OFF. The other three write config files; the machine layer writes the
  // registry and repoints user folders, so it never rides along on the bare command.
  const opts = {
    dryRun: false, list: false, help: false, selftest: false,
    fonts: true, tabby: true, nvim: true, shell: true, machine: false,
    installSoftware: false, privacy: false, forceFolders: false, repo: null,
    optionalFonts: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--dry-run') opts.dryRun = true;
    else if (a === '--list') opts.list = true;
    else if (a === '--selftest') opts.selftest = true;
    else if (a === '--no-fonts') opts.fonts = false;
    else if (a === '--optional-fonts') opts.optionalFonts = true;
    else if (a === '--no-tabby') opts.tabby = false;
    else if (a === '--no-nvim') opts.nvim = false;
    else if (a === '--no-shell') opts.shell = false;
    else if (a === '--machine') opts.machine = true;
    else if (a === '--install-software') opts.installSoftware = true;
    else if (a === '--privacy') opts.privacy = true;
    else if (a === '--force-folders') opts.forceFolders = true;
    else if (a === '--repo') opts.repo = argv[++i];
    else if (a.startsWith('--repo=')) opts.repo = a.slice('--repo='.length);
    else if (a === '-h' || a === '--help') opts.help = true;
    else if (a.startsWith('-')) console.warn(`warning: unknown flag ${a} (ignored)`);
  }
  return opts;
}

const HELP = `
Personal dotfiles installer: rolls out terminal + editor + shell config from the repo.

Repo (single source of truth): ${DOTFILES_REPO}

Usage:
  node install.mjs [options]        (from a checkout: deploys the checkout it sits in)

Options:
  --repo <path>       Deploy from a local checkout instead of cloning.
  --dry-run           Report what would happen; write nothing to your configs.
  --list              List repo source, deploy targets, and prerequisites, then exit.
  --no-fonts          Skip the vendored terminal font.
  --optional-fonts    Also install fonts/optional/ (never installed otherwise).
  --no-tabby          Skip the terminal (Tabby) config.
  --no-nvim           Skip the editor (Neovim) config.
  --no-shell          Skip the shell layer (bash, readline, git).
  --machine           Also apply the machine layer (startup, user folders, software).
                      Off by default: it writes the registry, unlike the steps above.
  --install-software  Install missing software from the manifest (otherwise only reported).
  --privacy           Write the elevated privacy script for review (never auto-applied).
  --force-folders     Repoint a user folder even if its current location still holds files.
  --selftest          Run the installer's internal checks and exit.
  -h, --help          Show this help.

Each target is backed up to a timestamped .bak-... before it is replaced.
`;

function printList(opts) {
  console.log('Repo (source of truth):');
  if (opts.repo) console.log(`  local checkout : ${opts.repo}`);
  else if (looksLikeRepo(SELF_DIR)) console.log(`  this checkout  : ${SELF_DIR}`);
  else console.log(`  ${DOTFILES_REPO} (clone or fast-forward pull into a local cache)`);
  console.log('');
  console.log('Deploy targets:');
  console.log(`  [${isDir(FONTS_DIR) ? 'present' : 'absent '}] fonts : ${FONTS_DIR}`);
  for (const f of fontStatus(opts)) {
    const state = f.installed ? 'installed' : (f.optional ? 'not asked' : 'missing  ');
    console.log(`      [${state}] ${f.name}${f.optional ? '   (optional)' : ''}`);
  }
  console.log(`  [${exists(TABBY_CONFIG) ? 'present' : 'absent '}] tabby : ${TABBY_CONFIG}`);
  console.log(`  [${isDir(NVIM_DIR) ? 'present' : 'absent '}] nvim  : ${NVIM_DIR}`);
  for (const t of shellTargets()) {
    console.log(`  [${exists(t.dest) ? 'present' : 'absent '}] shell : ${t.dest}`);
  }
  console.log('');
  printMachineList(opts);
  printPrerequisites(opts);
}

// Prerequisites come from a manifest, never from string literals here. A package id written in
// code has nothing to be checked against, which is how `TreeSitter.TreeSitter` (a package that
// does not exist) sat in this function printing an install command that could only ever fail.
// The machine's own manifest wins; the tracked example is the fallback, so a fresh clone still
// prints real install commands instead of degrading to a bare present/missing list.
function printPrerequisites(opts) {
  const checkout = listCheckout(opts);
  let manifest = null;
  try { manifest = readManifest(checkout); } catch { /* unreadable: fall through */ }
  if (!manifest) manifest = readExampleManifest(checkout);
  const rows = (manifest?.software || []).filter((s) => s.prerequisite);

  console.log('Prerequisites (never auto-installed):');
  if (!rows.length) {
    // No checkout at all. Report what is here, but do not invent an install command: the ids
    // live in the checkout, and guessing one is the exact mistake this replaces.
    for (const bin of ['git', 'node', 'nvim']) {
      console.log(`  ${bin.padEnd(12)}: ${onPath(bin) ? 'present' : 'MISSING'}`);
    }
    console.log('  (clone the repo for the full list with install commands)');
    return;
  }
  for (const s of rows) {
    const bin = s.detectOnPath || '';
    const have = bin ? onPath(bin) : (wingetHas(s.winget) === true);
    const hint = PLATFORM === 'win32' ? ` (winget install ${s.winget})` : ` (${s.winget})`;
    console.log(`  ${(bin || s.name).padEnd(12)}: ${have ? 'present' : `MISSING${hint}`}`);
  }
}

// Same no-clone rule as fontStatus: read whatever checkout is already on disk. On a
// non-Windows box the machine layer is not applicable, so say so rather than listing rows.
function printMachineList(opts) {
  const checkout = listCheckout(opts);
  let manifest = null;
  try { manifest = readManifest(checkout); } catch { /* unreadable: treated as absent */ }
  if (!manifest) {
    console.log('Machine layer: no machine/machine.json in the checkout on disk');
    console.log('  (copy machine/machine.example.json to machine/machine.json to declare one)');
    console.log('');
    return;
  }
  if (PLATFORM !== 'win32') {
    console.log(`Machine layer: Windows-only (running on ${PLATFORM})`);
    console.log('');
    return;
  }
  console.log('Machine software:');
  for (const s of softwareStatus(manifest)) {
    const state = s.installed === null ? 'unknown' : (s.installed ? 'present' : 'MISSING');
    console.log(`  [${state.padEnd(7)}] ${s.name.padEnd(21)} ${s.winget}`);
  }
  console.log('');
  console.log('Machine startup (user scope, applied):');
  for (const e of (manifest.startup?.enabled || []).filter((x) => x.scope === 'user')) {
    const have = regQuery(RUN_KEY, e.name);
    const want = runCommandFor(e);
    const state = have === null ? 'absent ' : (have === want ? 'ok     ' : 'differs');
    console.log(`  [${state}] ${e.name}`);
  }
  // Recorded but never written: HKLM entries need admin, and the Startup folder is a file the
  // user drops in. Shown so the list reflects the whole login set, not just the managed part.
  const other = (manifest.startup?.enabled || []).filter((x) => x.scope !== 'user');
  if (other.length) {
    console.log('Machine startup (recorded only, not applied):');
    for (const e of other) {
      console.log(`  [${(exists(expandEnv(e.exe || '')) ? 'present' : 'absent ')}] ${e.name} (${e.scope})`);
    }
  }
  console.log('');
  console.log('Machine user folders:');
  for (const f of (manifest.knownFolders?.shell || [])) {
    const resolved = expandEnv(f.path);
    console.log(`  [${isDir(resolved) ? 'present' : 'absent '}] ${f.name.padEnd(12)} ${resolved}`);
  }
  console.log('');
  console.log('Machine cloud sync:');
  for (const l of cloudSyncLines(manifest, '  ')) console.log(l);
  console.log('');
}

// --list must not clone, so the font names come from whichever checkout is already on
// disk (an explicit --repo, else the cache). With neither, only the dir row is shown:
// the repo is what says which fonts belong, never the OS font dir's own contents.
// Reports both groups regardless of --optional-fonts, because the question --list answers is
// what is on the machine, not what this run would deploy. The optional rows are labelled so a
// missing one does not read as something the setup failed to do.
function fontStatus(opts) {
  const checkout = listCheckout(opts);
  const required = fontSources(checkout, { optionalFonts: false });
  if (!required) return [];
  const all = fontSources(checkout, { optionalFonts: true }) || [];
  const requiredNames = new Set(required.map((r) => r.name));
  return all.map((r) => ({
    name: r.name,
    optional: !requiredNames.has(r.name),
    installed: exists(path.join(FONTS_DIR, r.name)),
  }));
}

function selftest() {
  let pass = 0;
  const fails = [];
  const check = (name, cond) => { if (cond) pass++; else fails.push(name); };

  check('tabby dir ends in tabby', /[/\\]tabby$/.test(TABBY_DIR));
  check('nvim dir ends in nvim', /[/\\]nvim$/.test(NVIM_DIR));
  check('fonts dir is per-user, no elevation', PLATFORM === 'win32'
    ? /Microsoft[/\\]Windows[/\\]Fonts$/.test(FONTS_DIR)
    : /[/\\][Ff]onts$/.test(FONTS_DIR));
  check('fonts dir is absolute', path.isAbsolute(FONTS_DIR));

  // The whole point of fonts/optional/ is that a default run cannot reach it. Assert both
  // halves against the real checkout: the default set excludes it, and asking includes it.
  const fontCheckout = listCheckout({});
  if (isDir(path.join(fontCheckout, 'fonts', 'optional'))) {
    const req = fontSources(fontCheckout, { optionalFonts: false }) || [];
    const all = fontSources(fontCheckout, { optionalFonts: true }) || [];
    check('the default font set is only the top-level fonts/',
      req.every((r) => path.dirname(r.from).endsWith('fonts')));
    check('the default font set skips fonts/optional/', all.length > req.length);
    check('--optional-fonts picks up otf as well as ttf',
      all.some((r) => /\.otf$/i.test(r.name)));
    check('every optional font resolves to a file that exists', all.every((r) => exists(r.from)));
    check('no optional font shadows a required one',
      new Set(all.map((r) => r.name)).size === all.length);
  }
  check('registry value name is family + format', fontRegistryName('a/b/CozetteVector.ttf') === 'CozetteVector (TrueType)');
  // An .otf registered as (TrueType) writes a value that looks right and never shows up in a
  // font list, so the suffix is checked rather than assumed.
  check('an otf registers as OpenType', fontRegistryName('a/b/BruneaMono.otf') === 'BruneaMono (OpenType)');
  check('format check is extension-case insensitive', fontRegistryName('X.OTF') === 'X (OpenType)');
  check('a spaced filename keeps its spaces', fontRegistryName('a/b/Basic TM.ttf') === 'Basic TM (TrueType)');
  check('registry value name drops the dir', !fontRegistryName(path.join(FONTS_DIR, 'CozetteVectorBold.ttf')).includes(path.sep));
  check('psQuote wraps in single quotes', psQuote('C:\\a b\\f.ttf') === "'C:\\a b\\f.ttf'");
  check('psQuote doubles embedded quotes', psQuote("it's") === "'it''s'");
  check('timestamp has no colons', !safeTimestamp().includes(':'));
  check('backupPath appends .bak-', /\.bak-/.test(backupPath('a/b.yaml')));
  check('onPath finds node', onPath('node') === true);
  check('onPath rejects bogus', onPath('definitely-not-a-real-bin-xyz') === false);

  // Machine layer. The %20 case is the one that matters: a startup argument carrying a
  // URL escape must survive expansion, or a looser pattern silently corrupts the command.
  process.env.__DOTFILES_SELFTEST = 'XYZ';
  process.env.__DOTFILES_CMD__ = 'C:\\pf';
  check('expandEnv expands a known var', expandEnv('a/%__DOTFILES_SELFTEST%/b') === 'a/XYZ/b');
  check('expandEnv is case-insensitive', expandEnv('%__dotfiles_selftest%') === 'XYZ');
  check('expandEnv leaves unknown vars alone', expandEnv('%__NOT_A_REAL_VAR__%') === '%__NOT_A_REAL_VAR__%');
  check('expandEnv does not eat URL escapes', expandEnv('TaskId=Example%20App') === 'TaskId=Example%20App');
  check('expandEnv survives a mixed string',
    expandEnv('%__DOTFILES_SELFTEST%?a=b%20c') === 'XYZ?a=b%20c');
  delete process.env.__DOTFILES_SELFTEST;

  check('matchesPattern exact hit', matchesPattern('ExampleApp', 'ExampleApp') === true);
  check('matchesPattern exact miss', matchesPattern('ExampleApp', 'ExampleApp2') === false);
  check('matchesPattern prefix hit', matchesPattern('ExampleAutoLaunch_*', 'ExampleAutoLaunch_0A14') === true);
  check('matchesPattern prefix miss', matchesPattern('ExampleAutoLaunch_*', 'SomethingElse') === false);

  check('startupApproved enabled byte', startupApprovedBytes(true).startsWith('02'));
  check('startupApproved disabled byte', startupApprovedBytes(false).startsWith('03'));
  check('startupApproved is 12 bytes', startupApprovedBytes(true).length === 24);
  check('startupApprovedEnabled reads 02 as on', startupApprovedEnabled('02'.padEnd(24, '0')) === true);
  check('startupApprovedEnabled reads 03 as off', startupApprovedEnabled('03'.padEnd(24, '0')) === false);
  check('startupApprovedEnabled ignores timestamp bytes',
    startupApprovedEnabled('0200000097B1D2E4A1C6DB01') === true);
  check('startupApprovedEnabled reads a real disabled value',
    startupApprovedEnabled('0300000097B1D2E4A1C6DB01') === false);
  check('startupApprovedEnabled treats absent as unknown', startupApprovedEnabled(null) === null);

  check('runCommandFor quotes the exe', runCommandFor({ exe: 'C:\\a b\\x.exe', args: [] }) === '"C:\\a b\\x.exe"');
  check('runCommandFor appends args', runCommandFor({ exe: 'x.exe', args: ['--hidden'] }) === '"x.exe" --hidden');
  // Regression guard: a verbatim `command` must win over exe+args composition, or a launcher
  // registered exe-unquoted with a quoted argument gets rewritten into a shape that parses
  // differently.
  check('runCommandFor honours a verbatim command',
    runCommandFor({ exe: 'x.exe', args: ['--nope'], command: 'y.exe "a&b?c"' }) === 'y.exe "a&b?c"');
  check('runCommandFor expands vars inside a verbatim command',
    runCommandFor({ command: '%__DOTFILES_CMD__%\\z.exe "p%20q"' }) === 'C:\\pf\\z.exe "p%20q"');
  delete process.env.__DOTFILES_CMD__;

  // Drift detection. An empty or matching current path must never block; a different path
  // holding files always must, or the cloud-sync case orphans data silently.
  const dTmp = path.join(os.tmpdir(), `dotfiles-drift-${safeTimestamp()}`);
  try {
    const withData = path.join(dTmp, 'old');
    const emptyDir = path.join(dTmp, 'empty');
    const target = path.join(dTmp, 'new');
    fs.mkdirSync(withData, { recursive: true });
    fs.mkdirSync(emptyDir, { recursive: true });
    fs.mkdirSync(target, { recursive: true });
    fs.writeFileSync(path.join(withData, 'a.txt'), 'x');
    check('countFiles counts a file', countFiles(withData) === 1);
    check('countFiles on empty dir is 0', countFiles(emptyDir) === 0);
    check('drift blocks a different path holding files', folderBlocked(withData, target) !== null);
    check('drift reports the file count', folderBlocked(withData, target).files === 1);
    check('drift allows a different but empty path', folderBlocked(emptyDir, target) === null);
    check('drift allows the same path', folderBlocked(target, target) === null);
    check('drift is case and trailing-slash insensitive',
      folderBlocked(target.toUpperCase() + '\\', target) === null);
    check('drift allows an absent current value', folderBlocked(null, target) === null);
  } finally {
    fs.rmSync(dTmp, { recursive: true, force: true });
  }

  const tmp = path.join(os.tmpdir(), `dotfiles-selftest-${safeTimestamp()}`);
  try {
    const src = path.join(tmp, 'src');
    const dst = path.join(tmp, 'dst');
    fs.mkdirSync(path.join(src, 'lua'), { recursive: true });
    fs.writeFileSync(path.join(src, 'init.lua'), 'return 1\n');
    fs.writeFileSync(path.join(src, 'lua', 'a.lua'), 'return 2\n');
    fs.cpSync(src, dst, { recursive: true });
    check('recursive copy: nested file', exists(path.join(dst, 'lua', 'a.lua')));
    check('recursive copy: top file', fs.readFileSync(path.join(dst, 'init.lua'), 'utf8') === 'return 1\n');
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }

  // Shell layer. The CRLF check is the one that matters: bash will not run a script with
  // carriage returns, so a source file that slipped past .gitattributes must be normalized
  // on write rather than deployed verbatim.
  const shellT = shellTargets();
  check('shell deploys six files', shellT.length === 6);
  check('every shell target is under HOME', shellT.every((t) => t.dest.startsWith(HOME + path.sep)));
  check('shell sources are bare filenames', shellT.every((t) => !t.src.includes('/') && !t.src.includes('\\')));
  check('shell targets are unique', new Set(shellT.map((t) => t.dest)).size === shellT.length);
  check('bashrc lands on a dotfile', shellT.some((t) => t.dest === path.join(HOME, '.bashrc')));
  check('prompt lands on the Git for Windows hook path',
    shellT.some((t) => t.dest === path.join(HOME, '.config', 'git', 'git-prompt.sh')));
  check('escape hatches are under HOME', SHELL_LOCALS.every((l) => l.dest().startsWith(HOME + path.sep)));
  check('escape hatches are never a deploy target',
    SHELL_LOCALS.every((l) => !shellT.some((t) => t.dest === l.dest())));

  const shTmp = path.join(os.tmpdir(), `dotfiles-shell-${safeTimestamp()}`);
  try {
    fs.mkdirSync(shTmp, { recursive: true });
    const crlf = path.join(shTmp, 'crlf.sh');
    fs.writeFileSync(crlf, 'a\r\nb\r\n');
    check('readShellSource strips CR', !readShellSource(crlf).includes('\r'));
    check('readShellSource keeps the lines', readShellSource(crlf) === 'a\nb\n');
    const lf = path.join(shTmp, 'lf.sh');
    fs.writeFileSync(lf, 'a\nb\n');
    check('readShellSource leaves LF alone', readShellSource(lf) === 'a\nb\n');
    check('looksLikeRepo rejects an unrelated dir', looksLikeRepo(shTmp) === false);
    fs.mkdirSync(path.join(shTmp, 'shell'));
    check('looksLikeRepo accepts a shell-only checkout', looksLikeRepo(shTmp) === true);
  } finally {
    fs.rmSync(shTmp, { recursive: true, force: true });
  }

  // Package ids. The defect these guard against was a winget id written straight into this
  // file, where nothing could ever compare it to anything: it named a package that does not
  // exist and the installer printed it as an install command for as long as it was there.
  const selfSrc = fs.readFileSync(fileURLToPath(import.meta.url), 'utf8');
  check('no package id is hardcoded in this file',
    (selfSrc.match(/winget install (?!\$\{)[A-Za-z]/g) || []).length === 0);

  // The example is the only manifest this repo tracks, so it is the only one guaranteed to be
  // in a clone. If it stops parsing or drifts out of shape, a fresh machine has nothing to copy.
  const exampleFile = path.join(listCheckout({}), 'machine', 'machine.example.json');
  if (exists(exampleFile)) {
    let ex = null;
    try { ex = JSON.parse(fs.readFileSync(exampleFile, 'utf8')); } catch { /* reported below */ }
    check('machine.example.json parses', ex !== null);
    if (ex) {
      const exs = ex.software || [];
      check('example declares software', exs.length > 0);
      check('example ids have Publisher.Package shape',
        exs.every((s) => /^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+$/.test(s.winget || '')));
      check('example entries explain themselves', exs.every((s) => typeof s.why === 'string' && s.why.length > 10));
      check('example declares the two the installer cannot bootstrap',
        exs.some((s) => s.detectOnPath === 'node') && exs.some((s) => s.detectOnPath === 'git'));

      // bootstrap.ps1 may run before any checkout exists, so it carries two ids as constants.
      // That is the only place in the repo an id is written in code, and it is only safe while
      // it agrees with the manifest. Nothing else compares the two files, so this does.
      const bootstrapFile = path.join(listCheckout({}), 'bootstrap.ps1');
      if (exists(bootstrapFile)) {
        const ps = fs.readFileSync(bootstrapFile, 'utf8');
        const block = ps.match(/\$FallbackIds\s*=\s*@\{([^}]*)\}/);
        check('bootstrap.ps1 declares fallback ids', block !== null);
        if (block) {
          for (const bin of ['git', 'node']) {
            const hit = block[1].match(new RegExp(`${bin}\\s*=\\s*'([^']+)'`));
            const declared = exs.find((s) => s.detectOnPath === bin);
            check(`bootstrap ${bin} fallback matches the example manifest`,
              !!hit && !!declared && hit[1] === declared.winget);
          }
        }
      }
    }
  }

  let mf = null;
  try { mf = readManifest(listCheckout({})); } catch { /* no checkout: skip these */ }
  if (mf) {
    const sw = mf.software || [];
    check('manifest declares software', sw.length > 0);
    check('every entry carries a winget id', sw.every((s) => typeof s.winget === 'string' && s.winget));
    check('every id has Publisher.Package shape',
      sw.every((s) => /^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+$/.test(s.winget)));
    check('every entry explains itself', sw.every((s) => typeof s.why === 'string' && s.why.length > 10));
    check('ids are unique', new Set(sw.map((s) => s.winget)).size === sw.length);
    // The installer cannot run without these two, so their absence from the manifest is the
    // gap that left a bare machine with nothing to bootstrap from.
    check('node is declared', sw.some((s) => s.detectOnPath === 'node'));
    check('git is declared', sw.some((s) => s.detectOnPath === 'git'));
    const pre = sw.filter((s) => s.prerequisite);
    check('prerequisites are marked', pre.length >= 6);
    check('every prerequisite is detectable without winget', pre.every((s) => !!s.detectOnPath));
    // rg, not ripgrep: naming the package instead of the binary is a silent false MISSING.
    check('prerequisite detection names the binary, not the package',
      pre.every((s) => !s.detectOnPath.includes('.') && s.detectOnPath === s.detectOnPath.toLowerCase()));
  }

  console.log(`selftest: ${pass} checks passed, ${fails.length} failed`);
  if (fails.length) {
    for (const f of fails) console.log(`  FAIL: ${f}`);
    process.exit(1);
  }
  console.log('selftest OK');
  process.exit(0);
}

function deployStep(label, fn, repoDir, opts, state) {
  console.log(`* ${label}`);
  try {
    const r = fn(repoDir, opts);
    if (!r.ok) {
      console.log(`    skipped: ${r.msg}`);
    } else {
      console.log(`    ${r.msg}`);
      if (r.backup) console.log(`    backup: ${r.backup}`);
    }
  } catch (err) {
    state.hadError = true;
    console.log(`    ERROR: ${err.message || String(err)}`);
  }
  console.log('');
}

function main() {
  const opts = parseArgs(process.argv.slice(2));

  if (opts.help) { console.log(HELP); process.exit(0); }
  if (opts.selftest) { selftest(); return; }
  if (!opts.fonts && !opts.tabby && !opts.nvim && !opts.shell && !opts.machine) {
    console.error('error: --no-fonts, --no-tabby, --no-nvim and --no-shell leave nothing to do (add --machine for the machine layer)');
    process.exit(1);
  }

  const scope = [opts.fonts && 'fonts', opts.tabby && 'tabby', opts.nvim && 'nvim',
    opts.shell && 'shell', opts.machine && 'machine'].filter(Boolean).join(' + ');
  console.log(`Personal dotfiles installer ${opts.dryRun ? '(dry run) ' : ''}[${scope}]`);
  console.log('');

  if (opts.list) { printList(opts); process.exit(0); }

  let repo;
  try {
    repo = resolveRepo(opts);
  } catch (err) {
    console.error(`error: ${err.message}`);
    process.exit(1);
  }
  console.log(`* repo: ${repo.dir}${repo.cloned ? ' (cloned)' : ''}${repo.self ? ' (this checkout)' : ''}`);
  console.log('');

  const state = { hadError: false };
  // Fonts first: the Tabby profile names CozetteVector, so it has to exist by the time
  // that config lands, and nvim's splash/gitstat panels draw glyphs only Cozette carries.
  if (opts.fonts) deployStep(opts.optionalFonts ? 'Fonts (Cozette + optional)' : 'Font (Cozette)', deployFonts, repo.dir, opts, state);
  if (opts.tabby) deployStep('Terminal (Tabby)', deployTabby, repo.dir, opts, state);
  if (opts.nvim) deployStep('Editor (Neovim)', deployNvim, repo.dir, opts, state);
  // Shell after the editor, because ~/.bashrc exports EDITOR=nvim and the git config it
  // deploys is what the editor's git panels read.
  if (opts.shell) deployStep('Shell (bash + readline + git)', deployShell, repo.dir, opts, state);
  // Machine last: it can install software the earlier steps just configured, and its
  // startup entries point at executables those steps assume are already present.
  if (opts.machine) deployStep('Machine (startup + folders)', deployMachine, repo.dir, opts, state);

  if (state.hadError) {
    console.log('Completed with errors. See above.');
    process.exit(1);
  }
  if (opts.dryRun) {
    console.log('Dry run complete. No files were modified.');
  } else {
    console.log('Done.');
    if (opts.tabby) console.log('Tabby: fully quit (not just close the window) and relaunch to apply.');
    if (opts.nvim) console.log('Neovim: run `nvim`, let lazy.nvim sync plugins on first launch, then <leader>w.');
    if (opts.shell) console.log('Shell: open a new tab (or `exec bash -l`) to pick up the prompt and aliases.');
  }
  process.exit(0);
}

main();
