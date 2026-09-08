import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { PLATFORM, DOTFILES_REPO, SELF_DIR, looksLikeRepo, listCheckout, TABBY_CONFIG, NVIM_DIR, FONTS_DIR, RUN_KEY, exists, isDir, onPath, git, resolveRepo } from './environment.mjs';
import { fontSources, deployFonts, deployTabby, deployNvim, shellTargets, deployShell } from './deploy.mjs';
import { readManifest, readExampleManifest, expandEnv, runCommandFor, regQuery, softwareStatus, wingetHas, installSoftware, cloudSyncLines, fileAssociationLines, deployMachine } from './machine.mjs';
import { selftest } from './selftest.mjs';

export function parseArgs(argv) {
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
    else if (a === '--repo' || a.startsWith('--repo=')) {
      const value = a === '--repo' ? argv[++i] : a.slice('--repo='.length);
      if (!value || value.startsWith('-')) throw new Error('--repo requires a path');
      opts.repo = value;
    }
    else if (a === '-h' || a === '--help') opts.help = true;
    else if (a.startsWith('-')) console.warn(`warning: unknown flag ${a} (ignored)`);
  }
  return opts;
}

export const HELP = `
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

export function printList(opts) {
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
export function printPrerequisites(opts) {
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
export function printMachineList(opts) {
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
  console.log('Machine file associations:');
  for (const l of fileAssociationLines(manifest, '  ')) console.log(l);
  console.log('');
}

// --list must not clone, so the font names come from whichever checkout is already on
// disk (an explicit --repo, else the cache). With neither, only the dir row is shown:
// the repo is what says which fonts belong, never the OS font dir's own contents.
// Reports both groups regardless of --optional-fonts, because the question --list answers is
// what is on the machine, not what this run would deploy. The optional rows are labelled so a
// missing one does not read as something the setup failed to do.
export function fontStatus(opts) {
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

export function deployStep(label, fn, repoDir, opts, state) {
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

export function main() {
  let opts;
  try { opts = parseArgs(process.argv.slice(2)); }
  catch (err) { console.error(`error: ${err.message}`); process.exit(1); }

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
    if (opts.nvim) console.log('Neovim: run `nvim`, let lazy.nvim sync plugins on first launch, then choose Launch in the splash.');
    if (opts.shell) console.log('Shell: open a new tab (or `exec bash -l`) to pick up the prompt and aliases.');
  }
  process.exit(0);
}
