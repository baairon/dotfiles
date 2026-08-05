# Prompt definition.
#
# On Git for Windows this file is a documented hook, not an override: the shipped
# /etc/profile.d/git-prompt.sh checks for ~/.config/git/git-prompt.sh and hands over to it
# INSTEAD of building its own PS1. Taking that hook means the rest of the shipped block is
# skipped too, and that block is what sources git's completion and __git_ps1, so this file
# has to source them itself. Miss that and the prompt silently loses its branch segment.
#
# Colours are ANSI palette indices, never hex escapes, so the prompt follows whatever
# scheme the terminal is set to. The real values live in tabby/config.yaml.
#   94  soft periwinkle  (#a5c7ff)   path
#   95  soft violet      (#ddaaff)   git
#   37  warm off-white   (#dedacf)   prompt mark, last command succeeded
#   91  soft red         (#f58c80)   prompt mark, last command failed

__DOTFILES_PROMPT=1

# git's own completion and __git_ps1, found relative to the git binary rather than a fixed
# path, so this works on any install layout.
if [ -z "$WINELOADERNOEXEC" ] && ! declare -F __git_ps1 >/dev/null 2>&1; then
  __dotfiles_completion_path="$(git --exec-path 2>/dev/null)"
  __dotfiles_completion_path="${__dotfiles_completion_path%/libexec/git-core}"
  __dotfiles_completion_path="${__dotfiles_completion_path%/lib/git-core}"
  __dotfiles_completion_path="$__dotfiles_completion_path/share/git/completion"
  if [ -f "$__dotfiles_completion_path/git-prompt.sh" ]; then
    . "$__dotfiles_completion_path/git-completion.bash"
    . "$__dotfiles_completion_path/git-prompt.sh"
  fi
  unset __dotfiles_completion_path
fi

# * for unstaged, + for staged. This costs a diff on every prompt, which is invisible on a
# normal repo and is not on a huge one; `git config bash.showDirtyState false` inside that
# one repo turns it off without touching this file. Untracked-file scanning stays off,
# since it is the expensive one and `gs` answers it on demand.
GIT_PS1_SHOWDIRTYSTATE=1
GIT_PS1_SHOWUPSTREAM=auto
GIT_PS1_SHOWCONFLICTSTATE=yes
GIT_PS1_HIDE_IF_PWD_IGNORED=1

# U+E0A0, the Powerline branch glyph. Verified present in fonts/CozetteVector.ttf, which
# is the font tabby/config.yaml names, so this can never render as a box on a machine this
# repo provisioned.
__DOTFILES_BRANCH_GLYPH=$''

# A branch name reaches PS1 as text, and with promptvars on (the bash default) PS1 gets a
# parameter and command expansion pass after its backslash escapes are decoded. That means
# checking out a branch named $(something) would RUN it, once per prompt, just by being in
# the directory. Turning promptvars off closes that without costing anything here: the PS1
# built below uses only backslash escapes and never a $variable, and the OSC 7 hook in
# PROMPT_COMMAND is an ordinary command rather than part of PS1.
shopt -u promptvars

# PS1 is rebuilt every prompt rather than written once, because the mark's colour depends
# on the exit status of the command that just ran. Backslash escapes are decoded when the
# prompt is printed, so \[ \] still delimit non-printing runs correctly from here.
__dotfiles_prompt() {
  local rc=$?
  local git=''

  if declare -F __git_ps1 >/dev/null 2>&1; then
    git="$(__git_ps1 "  ${__DOTFILES_BRANCH_GLYPH} %s")"
    # SHOWUPSTREAM marks the upstream relationship: < behind, > ahead, <> diverged, and =
    # in sync. The first three are worth a character; the fourth is true almost all of the
    # time, so it is dropped and "no marker" reads as in sync.
    git="${git%=}"
  fi

  local mark
  if [ "$rc" -eq 0 ]; then
    mark='\[\033[37m\]'
  else
    mark='\[\033[91m\]'
  fi

  # \[\033]0;\w\007\] is the window title, which Tabby reads for the tab label.
  PS1='\[\033]0;\w\007\]'
  PS1="$PS1"'\n\[\033[94m\]\w'
  PS1="$PS1"'\[\033[95m\]'"${git}"
  PS1="$PS1"'\n'"${mark}"$'❯''\[\033[0m\] '

  # Hand the status back untouched: this function runs first in PROMPT_COMMAND, and
  # anything chained after it would otherwise read this function's own exit status where it
  # meant to read the command the user just ran.
  return "$rc"
}

# Prepend, never replace: something else may already own PROMPT_COMMAND, and this has to
# run first regardless or $? is whatever that other hook returned rather than the command
# the user actually ran.
case ";${PROMPT_COMMAND};" in
  *";__dotfiles_prompt;"*) ;;
  *) PROMPT_COMMAND="__dotfiles_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
esac
