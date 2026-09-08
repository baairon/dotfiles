import fs from 'node:fs';
import path from 'node:path';
import { backupPath, PLATFORM } from './environment.mjs';

function stat(file, io) {
  try { return io.lstatSync(file); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}

export function sameContent(file, body, io = fs) {
  try { return io.readFileSync(file).equals(Buffer.isBuffer(body) ? body : Buffer.from(body)); }
  catch (error) { if (error.code === 'ENOENT') return false; throw error; }
}

// A changed file is backed up; an identical file keeps its inode and timestamp.
export function deployFile(target, body, dryRun = false, io = fs) {
  if (sameContent(target, body, io)) return { ok: true, msg: `already current: ${target}` };
  const present = stat(target, io);
  if (dryRun) return { ok: true, msg: `would ${present ? 'back up and overwrite' : 'create'} ${target}` };
  io.mkdirSync(path.dirname(target), { recursive: true });
  const backup = present ? backupPath(target) : null;
  if (backup) io.copyFileSync(target, backup);
  io.writeFileSync(target, body);
  return { ok: true, backup, msg: `deployed ${target}` };
}

export function deployDirectoryLink(source, target, dryRun = false, io = fs) {
  source = path.resolve(source);
  const present = stat(target, io);
  if (present?.isSymbolicLink()) {
    const normalize = (p) => PLATFORM === 'win32' ? p.toLowerCase() : p;
    try {
      if (normalize(io.realpathSync(target)) === normalize(io.realpathSync(source))) {
        return { ok: true, msg: `already linked: ${target} -> ${source}` };
      }
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  if (dryRun) return { ok: true, msg: `would ${present ? 'back up and symlink' : 'symlink'} ${target} -> ${source}` };
  io.mkdirSync(path.dirname(target), { recursive: true });
  const backup = present ? backupPath(target) : null;
  if (backup) io.renameSync(target, backup);
  try {
    io.symlinkSync(source, target, PLATFORM === 'win32' ? 'junction' : 'dir');
    return { ok: true, backup, msg: `linked ${target} -> ${source}` };
  } catch (linkError) {
    try {
      io.cpSync(source, target, { recursive: true });
      return { ok: true, backup, msg: `copied ${target} (symlink unavailable: ${linkError.code || linkError.message})` };
    } catch (copyError) {
      // Preserve a partial copy for inspection without recursively deleting any target.
      const partial = stat(target, io) ? backupPath(target) + '.partial' : null;
      if (partial) io.renameSync(target, partial);
      if (backup) io.renameSync(backup, target);
      throw new Error(`Neovim deployment failed: ${copyError.message}${partial ? `; partial copy: ${partial}` : ''}`, { cause: copyError });
    }
  }
}
