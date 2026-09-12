# prompto integration for Zsh.
#
# Daemon-mode + vim-mode wiring (see src/daemon/ARCHITECTURE.md and
# docs/maintainers/daemon-shells.md):
#
#   - Mode detection: `_prompto_zle-keymap-select` is decorated onto ZLE's
#     `zle-keymap-select` widget via `_prompto_create_widget` and fires on
#     every $KEYMAP change (vicmd ↔ main).
#   - --repaint wiring: the keymap hook sets `_prompto_vim_mode_repaint=1`
#     and calls `zle reset-prompt`; `_prompto_daemon_render` reads the flag
#     and appends `--repaint` to the prompto invocation, so the daemon
#     takes the Soft-Cancel path.
#   - Daemon entry: `_prompto_daemon_render` is the single point that calls
#     the prompto binary; see `enable_prompto_daemon`.

export PROMPTO_SHELL='zsh'
export PROMPTO_SHELL_VERSION=$ZSH_VERSION
export POWERLINE_COMMAND='prompto'
export CONDA_PROMPT_MODIFIER=false
export ZLE_RPROMPT_INDENT=0
export OSTYPE=$OSTYPE

# disable all known python virtual environment prompts
export VIRTUAL_ENV_DISABLE_PROMPT=1
export PYENV_VIRTUALENV_DISABLE_PROMPT=1

_prompto_executable=::PROMPTO::
_prompto_config=::CONFIG::
_prompto_tooltip_command=''
_prompto_tooltip_active=0
_prompto_tooltip_rprompt=''

# switches to enable/disable features
_prompto_cursor_positioning=0
_prompto_ftcs_marks=0

# set secondary prompt
_prompto_secondary_prompt=''

function _prompto_set_cursor_position() {
  # not supported in Midnight Commander
  # see https://github.com/po1o/prompto/issues/3415
  if [[ $_prompto_cursor_positioning == 0 ]] || [[ -v MC_SID ]]; then
    return
  fi

  local oldstty=$(stty -g)
  stty raw -echo min 0

  local pos
  echo -en '\033[6n' >/dev/tty
  read -r -d R pos
  pos=${pos:2} # strip off the esc-[
  local parts=(${(s:;:)pos})

  stty $oldstty

  export PROMPTO_CURSOR_LINE=${parts[1]}
  export PROMPTO_CURSOR_COLUMN=${parts[2]}
}

# template function for context loading
function set_promptocontext() {
  return
}

function _prompto_millis() {
  zmodload zsh/datetime 2>/dev/null
  if [[ -n ${EPOCHREALTIME-} ]]; then
    printf '%d\n' $(( EPOCHREALTIME * 1000 ))
    return
  fi

  printf '%(%s)T000\n' -1
}

function _prompto_decode_render_text() {
  printf '%b' "$1"
}

function _prompto_preexec() {
  if [[ $_prompto_ftcs_marks == 1 ]]; then
    printf '\033]133;C\007'
  fi

  _prompto_start_time=$(_prompto_millis)
}

function _prompto_precmd() {
  if [[ -z $_prompto_secondary_prompt ]]; then
    _prompto_secondary_prompt=$(_prompto_get_prompt secondary)
  fi

  _prompto_status=$?
  _prompto_pipestatus=(${pipestatus[@]})
  _prompto_job_count=${#jobstates}
  _prompto_stack_count=${#dirstack[@]}
  _prompto_execution_time=-1
  _prompto_no_status=true
  _prompto_tooltip_command=''
  _prompto_tooltip_active=0
  _prompto_tooltip_rprompt=''

  if [ $_prompto_start_time ]; then
    local prompto_now=$(_prompto_millis)
    _prompto_execution_time=$(($prompto_now - $_prompto_start_time))
    _prompto_no_status=false
  fi

  if [[ ${_prompto_pipestatus[-1]} != "$_prompto_status" ]]; then
    _prompto_pipestatus=("$_prompto_status")
  fi

  set_promptocontext
  _prompto_apply_cursor_shape
  _prompto_set_cursor_position

  # We do this to avoid unexpected expansions in a prompt string.
  unsetopt PROMPT_SUBST
  unsetopt PROMPT_BANG

  # Ensure that escape sequences work in a prompt string.
  setopt PROMPT_PERCENT

  PS2=$_prompto_secondary_prompt
  eval "$(_prompto_get_prompt primary --eval)"

  unset _prompto_start_time
}

# add hook functions
autoload -Uz add-zsh-hook
add-zsh-hook precmd _prompto_precmd
add-zsh-hook preexec _prompto_preexec

# Prevent incorrect behaviors when the initialization is executed twice in current session.
function _prompto_cleanup() {
  local prompto_widgets=(
    self-insert
    zle-line-init
  )
  local widget
  for widget in "${prompto_widgets[@]}"; do
    if [[ ${widgets[._prompto_original::$widget]} ]]; then
      # Restore the original widget.
      zle -A ._prompto_original::$widget $widget
    elif [[ ${widgets[$widget]} = user:_prompto_* ]]; then
      # Delete the OMP-defined widget.
      zle -D $widget
    fi
  done
}
_prompto_cleanup
unset -f _prompto_cleanup

function _prompto_ensure_executable() {
  if [[ ! -x "$_prompto_executable" ]]; then
    local _prompto_new_exe
    _prompto_new_exe=$(whence -p prompto 2>/dev/null || which prompto 2>/dev/null || command -v prompto 2>/dev/null)
    if [[ -n "$_prompto_new_exe" && -x "$_prompto_new_exe" ]]; then
      _prompto_executable=$_prompto_new_exe
    fi
  fi
}

function _prompto_get_prompt() {
  _prompto_ensure_executable
  local type=$1
  local args=("${@[2,-1]}")
  local vim_mode_arg=""
  if [[ $_prompto_vim_mode == 1 ]]; then
    vim_mode_arg="--vim-mode=$(_prompto_get_vim_mode)"
  fi
  $_prompto_executable render \
    --shell=zsh \
    --shell-version=$ZSH_VERSION \
    --status=$_prompto_status \
    --pipestatus="${_prompto_pipestatus[*]}" \
    --no-status=$_prompto_no_status \
    --execution-time=$_prompto_execution_time \
    --job-count=$_prompto_job_count \
    --stack-count=$_prompto_stack_count \
    --terminal-width="${COLUMNS-0}" \
    $vim_mode_arg \
    ${args[@]} | while IFS= read -r line; do
      case "$line" in
      "$type":*)
        _prompto_decode_render_text "${line#*:}"
        return 0
        ;;
      status:*)
        return 0
        ;;
      esac
    done
}

function _prompto_render_tooltip() {
  if [[ $KEYS != ' ' ]]; then
    return
  fi

  setopt local_options no_shwordsplit

  # Get the first word of command line as tip.
  local tooltip_command=${${(MS)BUFFER##[[:graph:]]*}%%[[:space:]]*}

  if [[ -z $tooltip_command ]]; then
    _prompto_restore_tooltip_rprompt
    _prompto_reset_prompt_if_zle
    return
  fi

  # Ignore repeated tooltip command.
  if [[ $tooltip_command = "$_prompto_tooltip_command" ]]; then
    return
  fi

  local config_arg=""
  if [[ -n $_prompto_config ]]; then
    config_arg="--config=$_prompto_config"
  fi

  _prompto_ensure_executable
  local tooltip=$($_prompto_executable tooltip \
    $config_arg \
    --shell=zsh \
    --shell-version=$ZSH_VERSION \
    --pid=$$ \
    --status=$_prompto_status \
    --pipestatus="${_prompto_pipestatus[*]}" \
    --no-status=$_prompto_no_status \
    --execution-time=$_prompto_execution_time \
    --job-count=$_prompto_job_count \
    --stack-count=$_prompto_stack_count \
    --terminal-width="${COLUMNS-0}" \
    --command="$tooltip_command")

  if [[ -z $tooltip ]]; then
    _prompto_restore_tooltip_rprompt
    _prompto_reset_prompt_if_zle
    return
  fi

  if [[ $_prompto_tooltip_active == 0 ]]; then
    _prompto_tooltip_rprompt=$RPROMPT
  fi

  _prompto_tooltip_active=1
  _prompto_tooltip_command="$tooltip_command"
  RPROMPT=$tooltip
  zle .reset-prompt
}

function _prompto_restore_tooltip_rprompt() {
  if [[ $_prompto_tooltip_active == 0 ]]; then
    return
  fi

  RPROMPT=$_prompto_tooltip_rprompt
  _prompto_tooltip_active=0
  _prompto_tooltip_command=''
}

function _prompto_restore_tooltip_on_delete() {
  _prompto_restore_tooltip_rprompt
  zle .reset-prompt
}

function _prompto_zle-line-init() {
  [[ $CONTEXT == start ]] || return 0

  # Start regular line editor.
  (( $+zle_bracketed_paste )) && print -r -n - $zle_bracketed_paste[1]
  zle .recursive-edit
  local -i ret=$?
  (( $+zle_bracketed_paste )) && print -r -n - $zle_bracketed_paste[2]

  if [[ $_prompto_daemon_mode == 1 ]]; then
    # Only apply transient prompt when configured and non-empty.
    # If no transient segment is configured, keep the current primary prompt.
    if [[ $_prompto_transient_enabled == 1 ]] && [[ -n ${_prompto_transient_prompt-}${_prompto_transient_rprompt-} ]]; then
      PS1=$_prompto_transient_prompt
      RPROMPT=${_prompto_transient_rprompt-}
    fi
  else
    # We need this workaround because when the `filler` is set,
    # there will be a redundant blank line below the transient prompt if the input is empty.
    local terminal_width_option
    if [[ -z $BUFFER ]]; then
      terminal_width_option="--terminal-width=$((${COLUMNS-0} - 1))"
    fi
    PS1=$(_prompto_get_prompt transient $terminal_width_option)
    RPROMPT=$(_prompto_get_prompt rtransient $terminal_width_option)
  fi
  zle .reset-prompt

  if ((ret)); then
    # TODO (fix): this is not equal to sending a SIGINT, since the status code ($?) is set to 1 instead of 130.
    zle .send-break
  fi

  # Exit the shell if we receive EOT.
  if [[ $KEYS == $'\4' ]]; then
    exit
  fi

  zle .accept-line
  return $ret
}

# Helper function for calling a widget before the specified OMP function.
function _prompto_call_widget() {
  # The name of the OMP function.
  local prompto_func=$1
  # The remainder are the widget to call and potential arguments.
  shift

  zle "$@" && shift 2 && $prompto_func "$@"
}

# Create a widget with the specified OMP function.
# An existing widget will be preserved and decorated with the function.
function _prompto_create_widget() {
  # The name of the widget to create/decorate.
  local widget=$1
  # The name of the OMP function.
  local prompto_func=$2

  case ${widgets[$widget]:-''} in
  # Already decorated: do nothing.
  user:_prompto_decorated_*) ;;

  # Non-existent: just create it.
  '')
    zle -N $widget $prompto_func
    ;;

  # User-defined or builtin: backup and decorate it.
  *)
    # Back up the original widget. The leading dot in widget name is to work around bugs when used with zsh-syntax-highlighting in Zsh v5.8 or lower.
    zle -A $widget ._prompto_original::$widget
    eval "_prompto_decorated_${(q)widget}() { _prompto_call_widget ${(q)prompto_func} ._prompto_original::${(q)widget} -- \"\$@\" }"
    zle -N $widget _prompto_decorated_$widget
    ;;
  esac
}

# Daemon mode variables
_prompto_daemon_mode=0
_prompto_daemon_fd=
_prompto_transient_prompt=
_prompto_transient_rprompt=
_prompto_transient_enabled=0
_prompto_last_primary_prompt=

# Vim mode variables
_prompto_vim_mode=0
_prompto_vim_mode_repaint=0
_prompto_cursor_shape=0
_prompto_cursor_blink=0

# Check if terminal handles cursor natively (Ghostty, Kitty)
function _prompto_should_change_cursor() {
  [[ -n "$GHOSTTY_RESOURCES_DIR" ]] && return 1
  [[ -n "$KITTY_WINDOW_ID" ]] && return 1
  return 0
}

# Mirrors config.IsConsole: PROMPTO_CONSOLE overrides, otherwise TERM.
function _prompto_is_console() {
  [[ "$PROMPTO_CONSOLE" == "1" ]] && return 0
  [[ "$PROMPTO_CONSOLE" == "0" ]] && return 1
  [[ "$TERM" == "linux" ]]
}

# Get current vim mode for segment template
function _prompto_get_vim_mode() {
  case $KEYMAP in
    vicmd) echo "normal" ;;
    viins|main) echo "insert" ;;
    visual) echo "visual" ;;
    viopp) echo "operator" ;;
    *) echo "insert" ;;
  esac
}

function _prompto_apply_cursor_shape() {
  # Change cursor shape if enabled and terminal doesn't handle it natively
  if [[ "$_prompto_cursor_shape" != "1" ]] || ! _prompto_should_change_cursor; then
    return
  fi

  # The Linux console ignores DECSCUSR, so the cursor stayed a block in every
  # mode. It has its own interface -- ESC[?size;xor;and c, the VGA softcursor --
  # where size is the kernel's CUR_* value: 2 underline, 6 block.
  #
  # The cursor blinks and that cannot be fixed while keeping the shapes. Adding
  # 16 (CUR_SW) stops the blink but also sets `enable && !use_sw` in bitblit.c,
  # which stops the cursor being drawn at all; a software cursor is rendered by
  # recolouring the whole cell through the xor/set masks instead, so it has no
  # shape. Shaped-and-blinking or unshaped-and-steady are the only two options,
  # and the blink-interval escape clamps at 50ms so it cannot be zeroed either.
  #
  # There is no beam. The console cursor is a horizontal slab of scanlines
  # spanning the whole cell with no width control, so an underline is the
  # thinnest shape there is.
  #
  # The console check is not cosmetic: on a VT-style terminal ESC[?...c is a
  # Device Attributes query, and the terminal's reply would land in the user's
  # input line as stray text.
  if _prompto_is_console; then
    case $KEYMAP in
      vicmd)
        print -n "\e[?6c"  # Block for normal mode
        ;;
      viins|main|*)
        print -n "\e[?2c"  # Underline: the thinnest the console offers
        ;;
    esac
    return
  fi

  local block_code=2
  local beam_code=6
  if [[ "$_prompto_cursor_blink" == "1" ]]; then
    block_code=1
    beam_code=5
  fi
  case $KEYMAP in
    vicmd)
      print -n "\e[${block_code} q"  # Block for normal mode
      ;;
    viins|main|*)
      print -n "\e[${beam_code} q"  # Beam for insert mode
      ;;
  esac
}

# Vim mode keymap change handler
function _prompto_zle-keymap-select() {
  _prompto_apply_cursor_shape

  # In daemon mode, trigger async repaint with new vim mode
  if [[ $_prompto_daemon_mode == 1 ]]; then
    _prompto_daemon_render --repaint
  fi

  # Trigger prompt repaint
  zle .reset-prompt
}

function _prompto_daemon_precmd() {
  _prompto_status=$?
  _prompto_pipestatus=(${pipestatus[@]})
  _prompto_job_count=${#jobstates}
  _prompto_stack_count=${#dirstack[@]}
  _prompto_execution_time=-1
  _prompto_no_status=true
  _prompto_tooltip_command=''

  if [ $_prompto_start_time ]; then
    local prompto_now=$(_prompto_millis)
    _prompto_execution_time=$(($prompto_now - $_prompto_start_time))
    _prompto_no_status=false
  fi

  if [[ ${_prompto_pipestatus[-1]} != "$_prompto_status" ]]; then
    _prompto_pipestatus=("$_prompto_status")
  fi

  set_promptocontext
  _prompto_apply_cursor_shape
  _prompto_set_cursor_position

  unsetopt PROMPT_SUBST
  unsetopt PROMPT_BANG
  setopt PROMPT_PERCENT

  PS2=$_prompto_secondary_prompt

  _prompto_daemon_render
  unset _prompto_start_time
}

# Async daemon render - used by both precmd and vim mode changes
# Pass --repaint for vim mode toggles (soft cancel, reuse computations)
function _prompto_daemon_render() {
  local repaint_flag=$1
  local config_arg=""
  if [[ -n $_prompto_config ]]; then
    config_arg="--config=$_prompto_config"
  fi

  if [[ $repaint_flag != "--repaint" ]]; then
    _prompto_transient_prompt=
    _prompto_transient_rprompt=
  fi

  # Clean up any existing fd handler from previous render
  if [[ -n $_prompto_daemon_fd ]]; then
    zle -F $_prompto_daemon_fd
    exec {_prompto_daemon_fd}<&-
    _prompto_daemon_fd=
  fi

  local vim_mode_arg=""
  if [[ $_prompto_vim_mode == 1 ]]; then
    vim_mode_arg="--vim-mode=$(_prompto_get_vim_mode)"
  fi

  _prompto_ensure_executable

  local fd
  exec {fd}< <($_prompto_executable render \
    $config_arg \
    --shell=zsh \
    --shell-version=$ZSH_VERSION \
    --pwd="$PWD" \
    --pid=$$ \
    --status=$_prompto_status \
    --pipestatus="${_prompto_pipestatus[*]}" \
    --no-status=$_prompto_no_status \
    --execution-time=$_prompto_execution_time \
    --job-count=$_prompto_job_count \
    --stack-count=$_prompto_stack_count \
    --terminal-width="${COLUMNS-0}" \
    $vim_mode_arg \
    $repaint_flag \
    2>/dev/null)

  # Read first batch synchronously (partial results after daemon timeout)
  local line batch_complete=0
  while [[ $batch_complete -eq 0 ]] && IFS= read -r line <&$fd; do
    _prompto_daemon_parse_line "$line"
    if [[ $line == status:* ]]; then
      batch_complete=1
      if [[ $line == "status:complete" ]]; then
        # All done, close fd
        exec {fd}<&-
        return
      fi
    fi
  done

  if [[ $batch_complete -eq 0 ]]; then
    exec {fd}<&-
    if [[ -n ${_prompto_last_primary_prompt-} ]]; then
      PS1=$_prompto_last_primary_prompt
      _prompto_reset_prompt_if_zle
    fi
    return
  fi

  # Drain any immediately buffered lines before handing off to the async watcher.
  # Fast renders can emit the final completion batch right after the initial update batch,
  # and relying only on zle -F can miss that already-buffered completion.
  while IFS= read -t 0 -r line <&$fd; do
    _prompto_daemon_parse_line "$line"
    if [[ $line != status:* ]]; then
      continue
    fi

    _prompto_reset_prompt_if_zle
    if [[ $line == "status:complete" ]]; then
      exec {fd}<&-
      return
    fi
  done

  # More updates may come - register fd handler for async streaming
  _prompto_daemon_fd=$fd
  zle -F $fd _prompto_daemon_handler
}

function _prompto_daemon_parse_line() {
  local line=$1
  local type=${line%%:*}
  local text=$(_prompto_decode_render_text "${line#*:}")

  case $type in
    primary)
      PS1=$text
      _prompto_last_primary_prompt=$text
      ;;
    right)
      RPROMPT=$text
      ;;
    secondary)
      PS2=$text
      ;;
    transient)
      _prompto_transient_prompt=$text
      ;;
    rtransient)
      _prompto_transient_rprompt=$text
      ;;
  esac
}

function _prompto_reset_prompt_if_zle() {
  if zle; then
    zle .reset-prompt
  fi
}

function _prompto_daemon_handler() {
  local fd=$1
  local line batch_complete=0

  # Read until we see a status line (daemon always ends a batch with status:*).
  while [[ $batch_complete -eq 0 ]] && IFS= read -r line <&$fd; do
    _prompto_daemon_parse_line "$line"
    if [[ $line == status:* ]]; then
      batch_complete=1
    fi
  done

  # If we read at least one status line, repaint
  if [[ $batch_complete -eq 1 ]]; then
    _prompto_reset_prompt_if_zle
  fi

  # If the stream ended or we saw the final status, clean up the fd.
  if [[ $batch_complete -eq 0 ]] || [[ $line == "status:complete" ]]; then
    zle -F $fd
    exec {fd}<&-
    _prompto_daemon_fd=
  fi
}

function enable_prompto_daemon() {
  # Replace precmd with daemon version
  _prompto_daemon_mode=1
  add-zsh-hook -d precmd _prompto_precmd
  add-zsh-hook precmd _prompto_daemon_precmd
}

function enable_prompto_tooltips() {
  local widget=${$(bindkey ' '):2}

  if [[ -z $widget ]]; then
    widget=self-insert
  fi

  _prompto_create_widget $widget _prompto_render_tooltip
  _prompto_create_widget backward-delete-char _prompto_restore_tooltip_on_delete
  _prompto_create_widget delete-char _prompto_restore_tooltip_on_delete
}

# Set up vim mode keybindings (oh-my-zsh style)
function _prompto_setup_vim_keybindings() {
  # Reduce mode switching delay (default is 40 = 400ms)
  KEYTIMEOUT=15

  # Insert mode: restore common emacs-style keybindings
  bindkey -M viins '^P' up-line-or-history
  bindkey -M viins '^N' down-line-or-history
  bindkey -M viins '^W' backward-kill-word
  bindkey -M viins '^H' backward-delete-char
  bindkey -M viins '^?' backward-delete-char
  bindkey -M viins '^A' beginning-of-line
  bindkey -M viins '^E' end-of-line
  bindkey -M viins '^R' history-incremental-search-backward
  bindkey -M viins '^S' history-incremental-search-forward

  # Normal mode: edit command line in $EDITOR
  autoload -Uz edit-command-line
  zle -N edit-command-line
  bindkey -M vicmd 'vv' edit-command-line
}

# legacy functions
function enable_prompto_transient_prompt() {}

_prompto_custom_dir=${PROMPTO_CUSTOM:-}
if [[ -z $_prompto_custom_dir ]]; then
  # Avoid double-sourcing if oh-my-zsh is managing ZSH_CUSTOM.
  if [[ -n $ZSH ]] && [[ -f $ZSH/oh-my-zsh.sh ]]; then
    _prompto_custom_dir=
  else
    _prompto_custom_dir=$ZSH_CUSTOM
  fi
fi

if [[ -n $_prompto_custom_dir ]] && [[ -d $_prompto_custom_dir ]]; then
  for script in $_prompto_custom_dir/*.zsh(N); do
    source $script
  done
fi
