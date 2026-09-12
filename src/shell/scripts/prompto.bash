# prompto integration for Bash.
#
# Daemon-mode + vim-mode wiring (see src/daemon/ARCHITECTURE.md and
# docs/maintainers/daemon-shells.md):
#
#   - Mode detection: requires ble.sh. We register a keymap-change hook
#     via `_prompto_ble_keymap_change` (only when $BLE_SESSION_ID is set).
#     Native Bash readline does not expose mode-change hooks, so vim-mode
#     repaint is silently a no-op without ble.sh sourced first.
#   - --repaint wiring: the keymap hook sets `_prompto_vim_mode_repaint=1`;
#     `_prompto_daemon_render` reads it and appends `--repaint` to the
#     `prompto render` invocation. The daemon then takes the Soft-Cancel
#     path (preserves in-flight segment computations).
#   - Daemon entry: `_prompto_daemon_render` is the single point that calls
#     the prompto binary; see `enable_prompto_daemon`.

export PROMPTO_SHELL='bash'
export PROMPTO_SHELL_VERSION=$BASH_VERSION
export POWERLINE_COMMAND='prompto'
export CONDA_PROMPT_MODIFIER=false
export OSTYPE=$OSTYPE

# disable all known python virtual environment prompts
export VIRTUAL_ENV_DISABLE_PROMPT=1
export PYENV_VIRTUALENV_DISABLE_PROMPT=1

# global variables
_prompto_start_time=''
_prompto_stack_count=0
_prompto_execution_time=-1
_prompto_no_status=true
_prompto_status=0
_prompto_pipestatus=0
_prompto_executable=::PROMPTO::

# switches to enable/disable features
_prompto_cursor_positioning=0
_prompto_ftcs_marks=0

# start timer on command start
PS0='${_prompto_start_time:0:$((_prompto_start_time="$(_prompto_start_timer)",0))}$(_prompto_ftcs_command_start)'

_prompto_secondary_prompt='> '

function _prompto_ensure_executable() {
    if [[ ! -x "$_prompto_executable" ]]; then
        local _prompto_new_exe
        _prompto_new_exe=$(type -P prompto 2>/dev/null || command -v prompto 2>/dev/null)
        if [[ -n "$_prompto_new_exe" && -x "$_prompto_new_exe" ]]; then
            _prompto_executable=$_prompto_new_exe
        fi
    fi
}

function _prompto_render_type() {
    _prompto_ensure_executable
    local prompt_type="$1"
    shift

    while IFS= read -r line; do
        case "$line" in
            "$prompt_type":*)
                _prompto_decode_render_text "${line#*:}"
                return 0
                ;;
            status:*)
                return 0
                ;;
        esac
    done < <("$_prompto_executable" render "$@")
}

function _prompto_decode_render_text() {
    printf '%b' "$1"
}

function _prompto_set_cursor_position() {
    # not supported in Midnight Commander
    # see https://github.com/po1o/prompto/issues/3415
    if [[ $_prompto_cursor_positioning == 0 ]] || [[ -v MC_SID ]]; then
        return
    fi

    local oldstty=$(stty -g)
    stty raw -echo min 0

    local COL
    local ROW
    IFS=';' read -rsdR -p $'
[6n' ROW COL

    stty "$oldstty"

    export PROMPTO_CURSOR_LINE=${ROW#*[}
    export PROMPTO_CURSOR_COLUMN=${COL}
}

function _prompto_start_timer() {
    if [[ -n ${EPOCHREALTIME-} ]]; then
        local prompto_epoch_seconds=${EPOCHREALTIME%%.*}
        local prompto_epoch_fraction=${EPOCHREALTIME#*.}
        prompto_epoch_fraction="${prompto_epoch_fraction}000"
        printf '%s%s\n' "$prompto_epoch_seconds" "${prompto_epoch_fraction:0:3}"
        return
    fi

    printf '%(%s)T000\n' -1
}

function _prompto_ftcs_command_start() {
    if [[ $_prompto_ftcs_marks == 1 ]]; then
        printf '\e]133;C\a'
    fi
}

# template function for context loading
function set_promptocontext() {
    return
}

function _prompto_get_primary() {
    # Avoid unexpected expansions when we're generating the prompt below.
    shopt -u promptvars
    trap 'shopt -s promptvars' RETURN

    local vim_mode_arg=""
    if [[ $_prompto_vim_mode == 1 ]]; then
        vim_mode_arg="--vim-mode=$(_prompto_get_vim_mode)"
    fi

    local prompt
    if shopt -oq posix; then
        # Disable in POSIX mode.
        prompt='[NOTICE: Prompto prompt is not supported in POSIX mode]\n\u@\h:\w\$ '
    else
        prompt=$(
            _prompto_render_type primary \
                --shell=bash \
                --shell-version="$BASH_VERSION" \
                --status="$_prompto_status" \
                --pipestatus="${_prompto_pipestatus[*]}" \
                --no-status="$_prompto_no_status" \
                --execution-time="$_prompto_execution_time" \
                --stack-count="$_prompto_stack_count" \
                --terminal-width="${COLUMNS-0}" \
                $vim_mode_arg |
                tr -d '\0'
        )
    fi
    echo "${prompt@P}"
}

function _prompto_get_secondary() {
    # Avoid unexpected expansions when we're generating the prompt below.
    shopt -u promptvars
    trap 'shopt -s promptvars' RETURN

    if shopt -oq posix; then
        # Disable in POSIX mode.
        echo '> '
    else
        if [[ "$_prompto_secondary_prompt" == '> ' ]]; then
            _prompto_secondary_prompt=$(_prompto_render_type secondary --shell=bash --shell-version="$BASH_VERSION")
        fi
        echo "${_prompto_secondary_prompt@P}"
    fi
}

function _prompto_hook() {
    _prompto_status=$? _prompto_pipestatus=("${PIPESTATUS[@]}")

    if [[ -v BP_PIPESTATUS && ${#BP_PIPESTATUS[@]} -ge ${#_prompto_pipestatus[@]} ]]; then
        _prompto_pipestatus=("${BP_PIPESTATUS[@]}")
    fi

    _prompto_stack_count=$((${#DIRSTACK[@]} - 1))

    _prompto_execution_time=-1
    if [[ $_prompto_start_time ]]; then
        local prompto_now=$(_prompto_start_timer)
        _prompto_execution_time=$((prompto_now - _prompto_start_time))
        _prompto_no_status=false
    fi
    _prompto_start_time=''

    if [[ ${_prompto_pipestatus[-1]} != "$_prompto_status" ]]; then
        _prompto_pipestatus=("$_prompto_status")
    fi

    set_promptocontext
    _prompto_apply_cursor_shape
    _prompto_set_cursor_position

    PS1='$(_prompto_get_primary)'
    PS2='$(_prompto_get_secondary)'

    # Ensure that command substitution works in a prompt string.
    shopt -s promptvars

    return $_prompto_status
}

function _prompto_install_hook() {
    local cmd
    local prompt_command

    for cmd in "${PROMPT_COMMAND[@]}"; do
        # skip initializing when we're already initialized
        if [[ $cmd = _prompto_hook ]]; then
            return
        fi

        # check if the command starts with source, if so, do not add it again
        # this is done to avoid issues with sourcing the same file multiple times
        if [[ $cmd = source* ]]; then
            continue
        fi

        prompt_command+=("$cmd")
    done

    PROMPT_COMMAND=("${prompt_command[@]}" _prompto_hook)
}

_prompto_install_hook

# Daemon mode variables
_prompto_daemon_mode=0
_prompto_config=::CONFIG::
_prompto_transient_prompt=''
_prompto_transient_enabled=0

# Vim mode variables
_prompto_vim_mode=0
_prompto_vim_mode_repaint=0
_prompto_cursor_shape=0
_prompto_cursor_blink=0

# Get current vim mode for segment template
function _prompto_get_vim_mode() {
    if [[ -n "$BLE_VERSION" ]]; then
        case "$_ble_decode_keymap" in
            vi_nmap) echo "normal" ;;
            vi_imap) echo "insert" ;;
            vi_xmap|vi_smap) echo "visual" ;;
            vi_omap) echo "operator" ;;
            vi_cmap) echo "command" ;;
            *) echo "insert" ;;
        esac
    else
        echo "insert"
    fi
}

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
        case "$(_prompto_get_vim_mode)" in
            normal|visual|operator|command)
                printf '\e[?6c'  # Block for normal/visual/operator/command mode
                ;;
            insert|*)
                printf '\e[?2c'  # Underline: the thinnest the console offers
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
    case "$(_prompto_get_vim_mode)" in
        normal|visual|operator|command)
            printf '\e[%s q' "$block_code"  # Block for normal/visual/operator/command mode
            ;;
        insert|*)
            printf '\e[%s q' "$beam_code"  # Beam for insert mode
            ;;
    esac
}

# Vim mode change handler for ble.sh
function _prompto_ble_keymap_change() {
    _prompto_apply_cursor_shape

    # In daemon mode, trigger async repaint with new vim mode
    if [[ $_prompto_daemon_mode == 1 ]]; then
        _prompto_daemon_render --repaint
    fi
}

function _prompto_daemon_parse_line() {
    local line="$1"
    local type="${line%%:*}"
    local text
    text=$(_prompto_decode_render_text "${line#*:}")

    case "$type" in
        primary)
            PS1="$text"
            ;;
        right)
            bleopt prompt_rps1="$text"
            ;;
        secondary)
            PS2="$text"
            ;;
        transient)
            if [[ $_prompto_transient_enabled == 1 ]]; then
                _prompto_transient_prompt="$text"
            fi
            ;;
    esac
}

function _prompto_daemon_job() {
    local line
    local batch_complete=0
    while true; do
        batch_complete=0
        while IFS= read -r line; do
            _prompto_daemon_parse_line "$line"
            if [[ $line == status:* ]]; then
                batch_complete=1
                ble/textarea#render
                if [[ $line == "status:complete" ]]; then
                    return
                fi
                break
            fi
        done
        if [[ $batch_complete -eq 0 ]]; then
            return
        fi
    done
}

# Async daemon render - used by both prompt hook and vim mode changes
# Pass --repaint for vim mode toggles (soft cancel, reuse computations)
function _prompto_daemon_render() {
    local repaint_flag="$1"

    local -a render_args=(
        render
        --shell=bash
        "--shell-version=$BASH_VERSION"
        "--pwd=$PWD"
        "--pid=$$"
        "--status=$_prompto_status"
        "--pipestatus=${_prompto_pipestatus[*]}"
        "--no-status=$_prompto_no_status"
        "--execution-time=$_prompto_execution_time"
        "--stack-count=$_prompto_stack_count"
        "--terminal-width=${COLUMNS-0}"
        --escape=false
    )

    if [[ -n "$_prompto_config" ]]; then
        render_args+=("--config=$_prompto_config")
    fi

    if [[ $_prompto_vim_mode == 1 ]]; then
        render_args+=("--vim-mode=$(_prompto_get_vim_mode)")
    fi

    if [[ -n "$repaint_flag" ]]; then
        render_args+=("$repaint_flag")
    fi

    # ble/util/job.start takes a command *string* and parses it, so every value
    # interpolated into it has to survive being read as shell source. Quoting
    # them by hand is not enough: $BASH_VERSION always contains "(1)", which is
    # a syntax error that aborts the whole command, so the render never runs and
    # the prompt keeps the placeholders the first batch delivered. And $PWD is
    # expanded twice, so a directory named '$(...)' — one arriving from a clone
    # or an unpacked archive — would execute on every prompt.
    #
    # %q quotes each value for exactly this round trip.
    _prompto_ensure_executable
    local render_command
    printf -v render_command '%q ' "$_prompto_executable" "${render_args[@]}"

    # _prompto_daemon_job is the second argument: the callback that consumes the
    # job's output. Losing the line continuation before it makes it a separate
    # command instead, so nothing reads the stream and the prompt keeps its
    # placeholders.
    ble/util/job.start "$render_command" _prompto_daemon_job
}

function _prompto_daemon_hook() {
    _prompto_status=$? _prompto_pipestatus=("${PIPESTATUS[@]}")

    if [[ -v BP_PIPESTATUS && ${#BP_PIPESTATUS[@]} -ge ${#_prompto_pipestatus[@]} ]]; then
        _prompto_pipestatus=("${BP_PIPESTATUS[@]}")
    fi

    _prompto_stack_count=$((${#DIRSTACK[@]} - 1))

    _prompto_execution_time=-1
    if [[ $_prompto_start_time ]]; then
        local prompto_now=$(_prompto_start_timer)
        _prompto_execution_time=$((prompto_now - _prompto_start_time))
        _prompto_no_status=false
    fi
    _prompto_start_time=''

    if [[ ${_prompto_pipestatus[-1]} != "$_prompto_status" ]]; then
        _prompto_pipestatus=("$_prompto_status")
    fi

    set_promptocontext
    _prompto_apply_cursor_shape
    _prompto_set_cursor_position

    _prompto_daemon_render
}

function enable_prompto_daemon() {
    # Check for ble.sh
    if [[ -z "$BLE_VERSION" ]]; then
        return
    fi

    _prompto_daemon_mode=1

    # Remove standard hook and add daemon hook using blehook if possible, or PROMPT_COMMAND
    blehook PROMPT_COMMAND-=_prompto_hook
    blehook PROMPT_COMMAND+=_prompto_daemon_hook

    # Register vim mode keymap change hook
    blehook keymap_vi_load+=_prompto_register_vim_hooks

    # Transient prompt configuration
    if [[ $_prompto_transient_enabled == 1 ]] && [[ -n "$_prompto_transient_prompt" ]]; then
        bleopt prompt_ps1_transient=always
        bleopt prompt_ps1_final='$_prompto_transient_prompt'
    fi
}

function _prompto_register_vim_hooks() {
    # Hook into ble.sh keymap changes
    ble/function#try ble/keymap:vi/invoke-hook keymap_enter _prompto_ble_keymap_change
}

function enable_prompto_vim_mode() {
    _prompto_vim_mode=1

    # Register vim mode hooks if ble.sh is available
    if [[ -n "$BLE_VERSION" ]]; then
        blehook keymap_vi_load+=_prompto_register_vim_hooks
    fi
}
