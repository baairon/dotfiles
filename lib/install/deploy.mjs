import { deployFile, deployDirectoryLink, sameContent } from './files.mjs';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { USER_HOME, PLATFORM, TABBY_DIR, TABBY_CONFIG, NVIM_DIR, FONTS_DIR, FONTS_REG_KEY, exists, isDir, backupPath, onPath, git, psQuote } from './environment.mjs';

export function fontRegistryName(file) {
  const ext = path.extname(file);
  const format = /^\.otf$/i.test(ext) ? 'OpenType' : 'TrueType';
  return `${path.basename(file, ext)} (${format})`;
}

// AddFontResourceW + a WM_FONTCHANGE broadcast make the font usable in the running
// session. Without it the registry entry only takes effect for apps started after the
// next logon, which would mean deploying a Tabby profile naming a font Tabby can't see.
export function activateFontsWindows(dests) {
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
export function fontSources(repoDir, opts) {
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

export function deployFonts(repoDir, opts) {
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

export function deployTabby(repoDir, opts) {
  const src = path.join(repoDir, 'tabby', 'config.yaml');
  if (!exists(src)) return { ok: false, msg: `repo has no tabby/config.yaml (${src})` };
  return deployFile(TABBY_CONFIG, fs.readFileSync(src), opts.dryRun);
}

export function deployNvim(repoDir, opts) {
  const src = path.resolve(repoDir, 'nvim');
  if (!isDir(src)) return { ok: false, msg: `repo has no nvim/ folder (${src})` };
  return deployDirectoryLink(src, NVIM_DIR, opts.dryRun);
}

// Shell layer: bash, readline, git.
// ---------------------------------------------------------------------------

// Repo file -> absolute destination, every one of them under $USER_HOME. The prompt is the odd
// entry: ~/.config/git/git-prompt.sh is the path Git for Windows itself looks for before
// building its own PS1, so deploying there is taking a documented hook rather than
// overriding anything. shell/git-prompt.sh explains what that hook has to do in return.
export function shellTargets() {
  return [
    { src: 'bashrc', dest: path.join(USER_HOME, '.bashrc') },
    { src: 'bash_profile', dest: path.join(USER_HOME, '.bash_profile') },
    { src: 'inputrc', dest: path.join(USER_HOME, '.inputrc') },
    { src: 'gitconfig', dest: path.join(USER_HOME, '.gitconfig') },
    { src: 'gitignore_global', dest: path.join(USER_HOME, '.gitignore_global') },
    { src: 'git-prompt.sh', dest: path.join(USER_HOME, '.config', 'git', 'git-prompt.sh') },
  ];
}

// Sourced or included last by the tracked files above, and never written over once they
// exist. These are what make a whole-file deploy safe: without somewhere local to put a
// machine-specific setting, the first one forces a choice between editing a tracked file
// and losing it on the next rollout.
export const SHELL_LOCALS = [
  {
    dest: () => path.join(USER_HOME, '.bashrc.local'),
    body: '# Machine-specific shell settings. Sourced at the end of ~/.bashrc, so anything\n'
      + '# here overrides the deployed file. Never tracked by the dotfiles repo.\n',
  },
  {
    dest: () => path.join(USER_HOME, '.gitconfig.local'),
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
export function readShellSource(file) {
  return fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
}

export function deployShell(repoDir, opts) {
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
      if (sameContent(t.dest, readShellSource(path.join(srcDir, t.src)))) return `      already current: ${t.dest}`;
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

