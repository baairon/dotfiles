import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { USER_HOME, PLATFORM, SELF_DIR, looksLikeRepo, listCheckout, TABBY_DIR, NVIM_DIR, FONTS_DIR, FILE_EXTS_KEY, exists, isDir, safeTimestamp, backupPath, onPath, git, psQuote } from './environment.mjs';
import { fontRegistryName, fontSources, shellTargets, SHELL_LOCALS, readShellSource } from './deploy.mjs';
import { readManifest, expandEnv, matchesPattern, runCommandFor, startupApprovedBytes, startupApprovedEnabled, countFiles, folderBlocked } from './machine.mjs';

export function selftest() {
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
  check('every shell target is under USER_HOME', shellT.every((t) => t.dest.startsWith(USER_HOME + path.sep)));
  check('shell sources are bare filenames', shellT.every((t) => !t.src.includes('/') && !t.src.includes('\\')));
  check('shell targets are unique', new Set(shellT.map((t) => t.dest)).size === shellT.length);
  check('bashrc lands on a dotfile', shellT.some((t) => t.dest === path.join(USER_HOME, '.bashrc')));
  check('prompt lands on the Git for Windows hook path',
    shellT.some((t) => t.dest === path.join(USER_HOME, '.config', 'git', 'git-prompt.sh')));
  check('escape hatches are under USER_HOME', SHELL_LOCALS.every((l) => l.dest().startsWith(USER_HOME + path.sep)));
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
  const selfSrc = ['environment', 'deploy', 'machine', 'cli'].map((name) => fs.readFileSync(path.join(SELF_DIR, 'lib/install', name + '.mjs'), 'utf8')).join('\n');
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
      // The example is where the shape of a section is documented, so a section that exists only
      // in the untracked manifest is one a fresh clone has no way to learn about.
      check('example declares the file-association shape',
        (ex.fileAssociations?.handlers || []).length > 0);

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

    // File associations. Most of these keep the manifest comparable to the registry; the last
    // one keeps the step honest. Writing a UserChoice means forging a hash Windows validates and
    // silently rejects, so the installer would be reporting a default it had not set, and that
    // check is what a later "it would be easy to just automate this" edit has to argue with.
    const fa = mf.fileAssociations?.handlers || [];
    const exts = fa.flatMap((h) => h.extensions || []);
    check('every handler names an app and a ProgId',
      fa.every((h) => !!h.app && !!h.progId && typeof h.why === 'string' && h.why.length > 10));
    check('every handler declares extensions', fa.every((h) => (h.extensions || []).length > 0));
    // The comparison is a registry key lookup, so a missing dot or a stray capital is a key that
    // does not exist, and a key that does not exist reads as "no default set" rather than a typo.
    check('extensions are lowercase and keep their dot', exts.every((e) => /^\.[a-z0-9]+$/.test(e)));
    check('extensions are unique', new Set(exts).size === exts.length);
    // Held on its own line so the check does not match its own source text.
    const writeCall = "execFileSync('reg'";
    check('file associations are read, never written',
      selfSrc.split('\n').every((l) => !(l.includes('FILE_EXTS_KEY') && l.includes(writeCall))));
  }

  console.log(`selftest: ${pass} checks passed, ${fails.length} failed`);
  if (fails.length) {
    for (const f of fails) console.log(`  FAIL: ${f}`);
    process.exit(1);
  }
  console.log('selftest OK');
  process.exit(0);
}

