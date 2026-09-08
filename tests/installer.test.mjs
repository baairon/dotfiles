import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { deployFile, deployDirectoryLink } from '../lib/install/files.mjs';
import { parseArgs } from '../lib/install/cli.mjs';
import { readShellSource } from '../lib/install/deploy.mjs';

function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dotfiles-test-'));
  t.after(() => {
    assert.equal(path.dirname(path.resolve(dir)), path.resolve(os.tmpdir()));
    assert.ok(path.basename(dir).startsWith('dotfiles-test-'));
    fs.rmSync(dir, { recursive: true, force: true });
  });
  return dir;
}

test('file rollout preserves identical files and backs up changed content', (t) => {
  const dir = fixture(t), target = path.join(dir, 'config');
  deployFile(target, 'first');
  const before = fs.statSync(target).mtimeMs;
  assert.match(deployFile(target, 'first').msg, /already current/);
  assert.equal(fs.statSync(target).mtimeMs, before);
  assert.deepEqual(fs.readdirSync(dir), ['config']);
  const changed = deployFile(target, 'second');
  assert.equal(fs.readFileSync(changed.backup, 'utf8'), 'first');
  assert.equal(fs.readFileSync(target, 'utf8'), 'second');
});

test('dry run does not create targets or backups and compares normalized shell content', (t) => {
  const dir = fixture(t), source = path.join(dir, 'source'), target = path.join(dir, 'target');
  fs.writeFileSync(source, 'one\r\ntwo\r\n');
  fs.writeFileSync(target, 'one\ntwo\n');
  assert.match(deployFile(target, readShellSource(source), true).msg, /already current/);
  deployFile(target, 'changed', true);
  deployDirectoryLink(source, path.join(dir, 'absent'), true);
  assert.deepEqual(fs.readdirSync(dir).sort(), ['source', 'target']);
  assert.equal(fs.readFileSync(target, 'utf8'), 'one\ntwo\n');
});

test('repeat Neovim deployment keeps the same junction and its source', (t) => {
  const dir = fixture(t), source = path.join(dir, 'source'), target = path.join(dir, 'target');
  fs.mkdirSync(source);
  fs.writeFileSync(path.join(source, 'init.lua'), 'return true');
  deployDirectoryLink(source, target);
  assert.ok(fs.lstatSync(target).isSymbolicLink());
  const before = fs.lstatSync(target).mtimeMs;
  assert.match(deployDirectoryLink(source, target).msg, /already linked/);
  assert.match(deployDirectoryLink(source, target, true).msg, /already linked/);
  assert.equal(fs.lstatSync(target).mtimeMs, before);
  assert.deepEqual(fs.readdirSync(dir).sort(), ['source', 'target']);
});

test('link failure falls back to a copy; copy failure restores the original directory', (t) => {
  const dir = fixture(t), source = path.join(dir, 'source'), target = path.join(dir, 'target');
  fs.mkdirSync(source);
  fs.mkdirSync(target);
  fs.writeFileSync(path.join(source, 'new'), 'new');
  fs.writeFileSync(path.join(target, 'old'), 'old');
  const noLink = { ...fs, symlinkSync() { throw Object.assign(new Error('no link'), { code: 'EPERM' }); } };
  const brokenCopy = { ...noLink, cpSync(_source, dest) {
    fs.mkdirSync(dest);
    fs.writeFileSync(path.join(dest, 'partial'), 'partial');
    throw new Error('copy failed');
  } };
  assert.throws(() => deployDirectoryLink(source, target, false, brokenCopy), /copy failed/);
  assert.equal(fs.readFileSync(path.join(target, 'old'), 'utf8'), 'old');
  assert.equal(fs.readFileSync(path.join(source, 'new'), 'utf8'), 'new');
  assert.match(deployDirectoryLink(source, target, false, noLink).msg, /copied/);
  assert.equal(fs.readFileSync(path.join(target, 'new'), 'utf8'), 'new');
});

test('invalid repo arguments fail before deployment; flags retain their defaults', () => {
  for (const argv of [['--repo'], ['--repo='], ['--repo', '--machine']]) {
    assert.throws(() => parseArgs(argv), /requires a path/);
  }
  assert.equal(parseArgs([]).machine, false);
  assert.equal(parseArgs(['--repo', 'some directory']).repo, 'some directory');
  assert.equal(parseArgs(['--repo=some directory']).repo, 'some directory');
});
