import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { PLATFORM, RUN_KEY, STARTUP_APPROVED_KEY, USER_SHELL_FOLDERS_KEY, FILE_EXTS_KEY, exists, isDir, safeTimestamp, onPath, psQuote } from './environment.mjs';

export function machineManifestPath(repoDir) {
  return path.join(repoDir, 'machine', 'machine.json');
}

export function readManifest(repoDir) {
  const file = machineManifestPath(repoDir);
  if (!exists(file)) return null;
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

// machine.json is gitignored, so a fresh clone has none. The tracked example still carries the
// toolchain this repo needs, which is enough to answer "what should I install" even though it is
// never enough to APPLY: deploying generic entries to a real machine would be wrong. Read it only
// where the answer is an install hint.
export function readExampleManifest(repoDir) {
  const file = path.join(repoDir, 'machine', 'machine.example.json');
  if (!exists(file)) return null;
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}

// Expand %VAR% against the environment. The name pattern deliberately requires a
// non-digit first character so URL escapes survive: some startup arguments carry a
// URL-encoded app name like "%20", and a looser pattern would eat it as a variable.
export function expandEnv(s) {
  return String(s).replace(/%([A-Za-z_][A-Za-z0-9_()]*)%/g, (whole, name) => {
    const key = Object.keys(process.env).find((k) => k.toLowerCase() === name.toLowerCase());
    return key === undefined ? whole : process.env[key];
  });
}

// Startup entry names are matched by prefix when they end in '*', because Windows
// gives some of its own auto-launch entries a per-machine hex suffix that differs
// on every box.
export function matchesPattern(pattern, name) {
  if (!pattern.endsWith('*')) return pattern === name;
  return name.startsWith(pattern.slice(0, -1));
}

// Most entries compose cleanly as "exe" arg arg. A few cannot: some installers register the
// exe UNQUOTED with an ms-protocol argument QUOTED, and that argument contains & and ?, so
// re-composing it in the usual shape would change how the shell parses it. Those entries
// carry an explicit `command` and are written through verbatim.
export function runCommandFor(entry) {
  if (entry.command) return expandEnv(entry.command);
  const exe = expandEnv(entry.exe);
  const args = (entry.args || []).map(expandEnv);
  return args.length ? `"${exe}" ${args.join(' ')}` : `"${exe}"`;
}

export function regQuery(key, value) {
  try {
    const out = execFileSync('reg', ['query', key, '/v', value], { stdio: 'pipe', encoding: 'utf8' });
    const m = out.match(/REG_(?:SZ|EXPAND_SZ)\s+(.*)$/m);
    return m ? m[1].trim() : null;
  } catch {
    return null;
  }
}

export function regValueNames(key) {
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
export function startupApprovedBytes(enabled) {
  return (enabled ? '02' : '03') + '00'.repeat(11);
}

export function getStartupApproved(name) {
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
export function startupApprovedEnabled(hex) {
  if (!hex || hex.length < 2) return null;
  return (parseInt(hex.slice(0, 2), 16) & 1) === 0;
}

// Write only when the state bit actually differs. Rewriting unconditionally would zero the
// timestamp bytes on every run, which turns an otherwise idempotent rollout into one that
// reports "no changes" while still dirtying the registry.
export function setStartupApproved(name, enabled) {
  if (startupApprovedEnabled(getStartupApproved(name)) === enabled) return false;
  execFileSync('reg', ['add', STARTUP_APPROVED_KEY, '/v', name, '/t', 'REG_BINARY',
    '/d', startupApprovedBytes(enabled), '/f'], { stdio: 'pipe' });
  return true;
}

// The other three steps back their target up to a timestamped file before replacing it.
// Registry writes need the same, or the machine layer is the one unreversible step. One
// .reg file holding all three keys restores with a double-click or `reg import`.
export function backupMachineRegistry() {
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

export function softwareStatus(manifest) {
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
export const _wingetSeen = new Map(); // one subprocess per id per run, not per call site
export function wingetHas(id) {
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

export function applyStartup(manifest, opts, lines) {
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
export function countFiles(dir, cap = 5000) {
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
export function folderBlocked(current, resolved) {
  if (!current) return null;
  const cur = expandEnv(current);
  if (cur.toLowerCase().replace(/\\+$/, '') === resolved.toLowerCase().replace(/\\+$/, '')) return null;
  if (!isDir(cur)) return null;
  const files = countFiles(cur);
  return files > 0 ? { cur, files } : null;
}

export function applyKnownFolders(manifest, opts, lines) {
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
export function writePrivacyScript(manifest) {
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

export function installSoftware(manifest, opts, lines) {
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
export function cloudSyncLines(manifest, indent) {
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

// Which app opens which extension, reported and never written. Not for want of elevation, which
// is the reason the privacy section is only ever emitted as a script: this one is unwritable at
// any privilege level. The choice lives in FILE_EXTS_KEY\<ext>\UserChoice beside a Hash that
// Windows computes over the extension, the user's SID and the ProgId, and validates on read. An
// entry whose hash does not match is not an error either: Windows discards it and keeps the
// previous app. So a script writing here would print a default it had not actually set, which is
// the one failure this installer is built to avoid. Windows writes a correct hash itself when the
// choice is made in Settings or the "Open with" dialog, which leaves exactly two things worth
// automating, and both are here: saying which extensions are still wrong, and where to fix them.
export function fileAssociationLines(manifest, indent) {
  const handlers = manifest.fileAssociations?.handlers || [];
  if (!handlers.length) return [`${indent}(none declared)`];
  const out = [];
  for (const h of handlers) {
    // The courtesy applyStartup gives a Run entry whose exe is absent: a handler naming a
    // program this machine does not have is a declaration to skip, not a difference to fix.
    if (h.verifyPath && !exists(expandEnv(h.verifyPath))) {
      out.push(`${indent}[skip   ] ${h.app}: not installed (${expandEnv(h.verifyPath)})`);
      continue;
    }
    const extensions = h.extensions || [];
    const outstanding = [];
    for (const ext of extensions) {
      const have = regQuery(`${FILE_EXTS_KEY}\\${ext}\\UserChoice`, 'ProgId');
      if (have === h.progId) {
        out.push(`${indent}[ok     ] ${ext}`);
        continue;
      }
      // 'unset' means no UserChoice at all, which is not the same as wrong: Windows then falls
      // back to the system-wide handler. Reported as outstanding anyway, because a fallback is
      // whatever the last installer to touch the extension left behind, not a choice.
      out.push(`${indent}[MANUAL ] ${ext}: ${have || 'unset'} -> ${h.progId}`);
      outstanding.push(ext);
    }
    if (outstanding.length) {
      out.push(`${indent}${outstanding.length} of ${extensions.length} to set by hand in Settings > Default apps:`);
      out.push(`${indent}  ${h.settingsLink || 'ms-settings:defaultapps'}`);
    }
  }
  return out;
}

export function deployMachine(repoDir, opts) {
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
  // No --dry-run branch below, and none inside: the step only reads. That is the whole design.
  lines.push('  file associations:');
  for (const l of fileAssociationLines(manifest, '    ')) lines.push(l);

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

