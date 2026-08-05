# Shell setup

The shell half of the machine: bash, readline, and git. The terminal profile in `tabby/` decides what
the shell *looks* like; these files decide how it *behaves*.

Tabby's default profile is `local:git-bash`, so bash is the shell that actually gets used here and it is
the only one this folder configures. See [What is deliberately not here](#what-is-deliberately-not-here).

## What lands where

| Repo file            | Deployed to                    | What it is                                  |
|----------------------|--------------------------------|---------------------------------------------|
| `bashrc`             | `~/.bashrc`                    | History, shell options, PATH, aliases       |
| `bash_profile`       | `~/.bash_profile`              | Login shells, sources `~/.bashrc`           |
| `inputrc`            | `~/.inputrc`                   | Readline: completion and history search     |
| `git-prompt.sh`      | `~/.config/git/git-prompt.sh`  | The prompt                                  |
| `gitconfig`          | `~/.gitconfig`                 | Git identity and behaviour                  |
| `gitignore_global`   | `~/.gitignore_global`          | Ignored in every repo on the machine        |

## The escape hatch

Every one of these is a whole-file deploy: the installer backs up what is there and writes the repo's
version over it. That only works if there is somewhere for machine-specific settings to live, or the
first genuinely local setting forces a choice between editing a tracked file and losing the deploy.

So three files are sourced or included last, and none of them is tracked:

```
~/.bashrc.local      sourced at the end of ~/.bashrc
~/.gitconfig.local   included at the end of ~/.gitconfig
~/.profile           sourced by ~/.bash_profile before ~/.bashrc
```

Last wins in both bash and git, so anything in those files overrides everything the repo deploys. A work
identity, a `safe.directory` entry for one odd checkout, an experimental PATH entry: all of it belongs
there, and a redeploy cannot touch it.

## Prompt

Two lines. Path on the first, branch beside it, and the mark alone on the second so a long path never
pushes the cursor to a different column:

```
~/dev/dotfiles   main *

❯
```

The mark is warm off-white when the last command succeeded and soft red when it did not, which is a
status report that costs no space at all. `*` after the branch means unstaged changes, `+` means staged.

Colours are ANSI palette indices rather than hex escapes, so the prompt follows whatever scheme the
terminal is set to instead of pinning its own. The actual values live in `tabby/config.yaml`.

`user@host` and `MSYSTEM` are deliberately gone. Git for Windows shows both by default, which is the
right call for a shell that might be anywhere; on a single-user machine they are two fixed strings
printed a hundred times a day.

### It is a hook, not an override

`/etc/profile.d/git-prompt.sh` ships with Git for Windows and checks for `~/.config/git/git-prompt.sh`
before doing anything else. If that file exists it is sourced and the shipped block is skipped entirely.
That is a supported extension point, which is why the prompt lives at that path rather than being
assigned in `.bashrc` and fighting whatever ran before it.

The catch is that the skipped block does more than build a `PS1`: it also sources `git-completion.bash`
and `git-prompt.sh` from git's own completion directory. Take the hook without sourcing those and the
prompt loses its branch segment and the shell loses git completion, with nothing reporting an error.
`git-prompt.sh` in this folder sources both, locating them relative to `git --exec-path` rather than a
fixed path so it survives a different install layout.

On any machine that is not Git for Windows nothing reads that path at all, so `.bashrc` sources it
directly, guarded by `__DOTFILES_PROMPT` so it is never sourced twice.

### A branch name is untrusted text

`promptvars` is on by default in bash, which means `PS1` gets a parameter and command expansion pass
*after* its backslash escapes are decoded. The branch name is substituted into `PS1` as text, so on that
default a repo with a branch named `$(...)` would run it once per prompt, just from being in the
directory. `git-prompt.sh` turns `promptvars` off, which costs nothing here because the prompt it builds
uses only backslash escapes and never a `$variable`.

### The cost

`GIT_PS1_SHOWDIRTYSTATE` runs a diff on every prompt. On a normal repo this is invisible; on a very
large one it is not. It is on because the dirty marker is worth it, and the per-repo opt-out is
`git config bash.showDirtyState false` inside that one repo, which needs no change here.

Untracked-file scanning stays off, since it is the expensive one and `gs` answers the same question on
demand.

## Two gotchas worth writing down

**`~/.inputrc` replaces `/etc/inputrc`, it does not extend it.** Readline reads one file, not both, so a
personal inputrc that does not start with `$include /etc/inputrc` silently drops every distribution
default it did not restate. That is the usual explanation for Home and End breaking the moment someone
adds a single completion setting.

**Line endings would break this whole folder without `.gitattributes`.** Bash refuses to run a script
with CRLF line endings, and `core.autocrlf` is `true` on this machine, so a checkout would hand the
installer a `.bashrc` full of `\r` and every login would open on a wall of `$'\r': command not found`.
The repo root's `.gitattributes` pins `* text=auto eol=lf`, which is what makes shell files safe to
track here at all.

## What is deliberately not here

Recorded so nobody adds them later thinking they were forgotten:

- **`~/.npmrc`** holds an npm auth token. It is a credential, not configuration, and it is never tracked
  in a public repo. Secrets on this machine live in the OS keychain.
- **zsh and PowerShell.** Tabby's default profile is `local:git-bash` and that is where the work
  happens. A `.zshrc` exists on this machine carrying one tool's completion line, and PowerShell gets
  used for the occasional Windows-only command; neither is a configured environment, and tracking a file
  that is only ever one line is how a dotfiles repo starts drifting from what is actually true.
- **A `safe.directory` entry.** The old `~/.gitconfig` carried one pointing at `Downloads/package`, a
  path that no longer exists. Dead machine-specific state is exactly what `~/.gitconfig.local` is for.
