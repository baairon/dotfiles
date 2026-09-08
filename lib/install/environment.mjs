import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const USER_HOME = os.homedir();
export const PLATFORM = process.platform;

export const DOTFILES_REPO = 'https://github.com/baairon/dotfiles';

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
export const SELF_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const REPO_MARKERS = ['fonts', 'tabby', 'nvim', 'shell', 'machine'];

export function looksLikeRepo(dir) {
  return REPO_MARKERS.some((d) => isDir(path.join(dir, d)));
}

// Which checkout the read-only commands (--list) should read. Deliberately never clones, and
// deliberately shared: when only resolveRepo knew about the self checkout, `--list` run from
// inside the repo answered "no machine/machine.json on disk" while standing in the repo,
// because it was still looking in the clone cache. One resolver, one answer.
export function listCheckout(opts) {
  if (opts.repo && isDir(opts.repo)) return opts.repo;
  if (looksLikeRepo(SELF_DIR)) return SELF_DIR;
  return cacheRepoDir();
}

export function tabbyConfigDir() {
  if (PLATFORM === 'win32') {
    const appData = process.env.APPDATA || path.join(USER_HOME, 'AppData', 'Roaming');
    return path.join(appData, 'tabby');
  }
  if (PLATFORM === 'darwin') {
    return path.join(USER_HOME, 'Library', 'Application Support', 'tabby');
  }
  const xdg = process.env.XDG_CONFIG_HOME || path.join(USER_HOME, '.config');
  return path.join(xdg, 'tabby');
}

export function nvimConfigDir() {
  if (PLATFORM === 'win32') {
    const localAppData = process.env.LOCALAPPDATA || path.join(USER_HOME, 'AppData', 'Local');
    return path.join(localAppData, 'nvim');
  }
  const xdg = process.env.XDG_CONFIG_HOME || path.join(USER_HOME, '.config');
  return path.join(xdg, 'nvim');
}

// Per-user font dir on every platform: none of these need elevation.
export function fontsDir() {
  if (PLATFORM === 'win32') {
    const localAppData = process.env.LOCALAPPDATA || path.join(USER_HOME, 'AppData', 'Local');
    return path.join(localAppData, 'Microsoft', 'Windows', 'Fonts');
  }
  if (PLATFORM === 'darwin') {
    return path.join(USER_HOME, 'Library', 'Fonts');
  }
  const xdgData = process.env.XDG_DATA_HOME || path.join(USER_HOME, '.local', 'share');
  return path.join(xdgData, 'fonts');
}

export const TABBY_DIR = tabbyConfigDir();
export const TABBY_CONFIG = path.join(TABBY_DIR, 'config.yaml');
export const NVIM_DIR = nvimConfigDir();
export const FONTS_DIR = fontsDir();
export const FONTS_REG_KEY = 'HKCU\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts';
export const RUN_KEY = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run';
export const STARTUP_APPROVED_KEY = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run';
export const USER_SHELL_FOLDERS_KEY = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders';
// Read-only, unlike the three above. See fileAssociationLines for why it can never be written.
export const FILE_EXTS_KEY = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FileExts';

export const exists = (p) => {
  try { fs.accessSync(p); return true; } catch { return false; }
};

export const isDir = (p) => {
  try { return fs.statSync(p).isDirectory(); } catch { return false; }
};

export function safeTimestamp() {
  return new Date().toISOString().replace(/[:.]/g, '-');
}

export function backupPath(target) {
  return `${target}.bak-${safeTimestamp()}`;
}

export function onPath(bin) {
  const exts = PLATFORM === 'win32' ? ['.exe', '.cmd', '.bat', ''] : [''];
  for (const dir of (process.env.PATH || '').split(path.delimiter)) {
    if (!dir) continue;
    for (const ext of exts) {
      if (exists(path.join(dir, bin + ext))) return true;
    }
  }
  return false;
}

export function git(args) {
  return execFileSync('git', args, { stdio: 'pipe', encoding: 'utf8' });
}

export function cacheRepoDir() {
  return PLATFORM === 'win32'
    ? path.join(process.env.LOCALAPPDATA || path.join(USER_HOME, 'AppData', 'Local'), 'dotfiles-cache')
    : path.join(process.env.XDG_CACHE_HOME || path.join(USER_HOME, '.cache'), 'dotfiles');
}

export function resolveRepo(opts) {
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
export function psQuote(s) {
  return `'${String(s).replace(/'/g, "''")}'`;
}
