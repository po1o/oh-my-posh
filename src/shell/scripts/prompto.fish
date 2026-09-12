# prompto integration for fish.
#
# Daemon-mode + vim-mode wiring (see src/daemon/ARCHITECTURE.md and
# docs/maintainers/daemon-shells.md):
#
#   - Mode detection: `_prompto_on_bind_mode_change --on-variable
#     fish_bind_mode` runs whenever fish updates the bind mode on ESC/i.
#   - --repaint wiring: the handler sets `_prompto_vim_mode_repaint 1` and
#     issues `commandline -f repaint`; `_prompto_daemon_render` reads the
#     flag and appends `--repaint` so the daemon takes the Soft-Cancel path.
#   - Daemon entry: `_prompto_daemon_render` is the single point that calls
#     the prompto binary; see `enable_prompto_daemon`.
#   - The USR1 signal handler (`_prompto_daemon_repaint --on-signal USR1`)
#     is a defensive repaint trigger; the daemon does not currently send it.

set --export --global PROMPTO_SHELL fish
set --export --global PROMPTO_SHELL_VERSION $FISH_VERSION
set --export --global POWERLINE_COMMAND prompto
set --export --global CONDA_PROMPT_MODIFIER false

set --global _prompto_tooltip_command ''
set --global _prompto_tooltip_active 0
set --global _prompto_tooltip_saved_rprompt ''
set --global _prompto_current_rprompt ''
set --global _prompto_transient 0
set --global _prompto_executable ::PROMPTO::
set --global _prompto_config ::CONFIG::
set --global _prompto_ftcs_marks 0
set --global _prompto_transient_prompt 0
set --global _prompto_prompt_mark 0

# disable all known python virtual environment prompts
set --global VIRTUAL_ENV_DISABLE_PROMPT 1
set --global PYENV_VIRTUALENV_DISABLE_PROMPT 1

# We use this to avoid unnecessary CLI calls for prompt repaint.
set --global _prompto_new_prompt 1

# template function for context loading
function set_promptocontext
    return
end

function _prompto_ensure_executable
    if not test -x "$_prompto_executable"
        set --local _prompto_new_exe (command -s prompto 2>/dev/null)
        if test -n "$_prompto_new_exe" -a -x "$_prompto_new_exe"
            set --global _prompto_executable $_prompto_new_exe
        end
    end
end

function _prompto_get_prompt
    _prompto_ensure_executable
    if test (count $argv) -eq 0
        return
    end
    set --local prompt_type $argv[1]
    set --local vim_mode_arg
    if test "$_prompto_vim_mode" = "1"
        set vim_mode_arg "--vim-mode="(_prompto_get_vim_mode)
    end
    $_prompto_executable render \
        --shell=fish \
        --shell-version=$FISH_VERSION \
        --status=$_prompto_status \
        --pipestatus="$_prompto_pipestatus" \
        --no-status=$_prompto_no_status \
        --execution-time=$_prompto_execution_time \
        --stack-count=$_prompto_stack_count \
        $vim_mode_arg \
        $argv[2..] | while read -l line
        if string match -q "$prompt_type:*" -- $line
            set --local text (string replace -r '^[^:]*:' '' -- $line)
            _prompto_decode_render_text "$text"
            break
        end
        if string match -q 'status:*' -- $line
            break
        end
    end
end

function _prompto_decode_render_text
    printf '%b' -- "$argv[1]"
end

function _prompto_expand_shell_clock
    set --local text "$argv[1]"
    if test -z "$text"
        echo -n "$text"
        return
    end

    while true
        set --local fmt (string match -r --groups-only '__PROMPTO_CLOCK\{([^}]*)\}__' -- "$text" | head -n1)
        if test -z "$fmt"
            break
        end

        set --local token "__PROMPTO_CLOCK{$fmt}__"
        set --local now (date +"$fmt")
        set text (string replace --all -- "$token" "$now" -- "$text")
    end

    echo -n "$text"
end

# NOTE: Input function calls via `commandline --function` are put into a queue and will not be executed until an outer regular function returns. See https://fishshell.com/docs/current/cmds/commandline.html.

function fish_prompt
    set --local prompto_status_temp $status
    set --local prompto_pipestatus_temp $pipestatus
    # clear from cursor to end of screen as
    # commandline --function repaint does not do this
    # see https://github.com/fish-shell/fish-shell/issues/8418
    printf \e\[0J
    if test "$_prompto_transient" = 1
        if test "$_prompto_daemon_mode" = "1"
            echo -n (_prompto_expand_shell_clock "$_prompto_current_transient")
        else
            _prompto_get_prompt transient | while read -l line
                _prompto_expand_shell_clock "$line"
                echo
            end
        end
        return
    end
    if test "$_prompto_new_prompt" = 0
        echo -n (_prompto_expand_shell_clock "$_prompto_current_prompt")
        return
    end
    set --global _prompto_status $prompto_status_temp
    set --global _prompto_pipestatus $prompto_pipestatus_temp
    set --global _prompto_no_status false
    set --global _prompto_execution_time "$CMD_DURATION$cmd_duration"
    set --global _prompto_stack_count (count $dirstack)

    # check if variable set, < 3.2 case
    if set --query _prompto_last_command && test -z "$_prompto_last_command"
        set _prompto_execution_time 0
        set _prompto_no_status true
    end

    # works with fish >=3.2
    if set --query _prompto_last_status_generation && test "$_prompto_last_status_generation" = "$status_generation"
        set _prompto_execution_time 0
        set _prompto_no_status true
    else if test -z "$_prompto_last_status_generation"
        # first execution - $status_generation is 0, $_prompto_last_status_generation is empty
        set _prompto_no_status true
    end

    if set --query status_generation
        set --global _prompto_last_status_generation $status_generation
    end

    set_promptocontext
    _prompto_apply_cursor_shape

    # validate if the user cleared the screen
    set --local prompto_cleared false
    set --local last_command (history search --max 1)

    if test "$last_command" = clear
        set prompto_cleared true
    end

    if test $_prompto_prompt_mark = 1
        iterm2_prompt_mark
    end

    # The prompt is saved for possible reuse, typically a repaint after clearing the screen buffer.
    set --global _prompto_current_prompt (_prompto_get_prompt primary --cleared=$prompto_cleared | string join \n | string collect)
    set --global _prompto_current_prompt (_prompto_expand_shell_clock "$_prompto_current_prompt")

    echo -n "$_prompto_current_prompt"
end

function fish_right_prompt
    if test "$_prompto_transient" = 1
        set --global _prompto_transient 0
        return
    end

    # Repaint an existing right prompt.
    if test "$_prompto_new_prompt" = 0
        echo -n (_prompto_expand_shell_clock "$_prompto_current_rprompt")
        return
    end

    set --global _prompto_new_prompt 0
    set --global _prompto_current_rprompt (_prompto_get_prompt right | string join '')
    set --global _prompto_current_rprompt (_prompto_expand_shell_clock "$_prompto_current_rprompt")

    echo -n "$_prompto_current_rprompt"
end

function _prompto_postexec --on-event fish_postexec
    # works with fish <3.2
    # pre and postexec not fired for empty command in fish >=3.2
    set --global _prompto_last_command $argv
end

function _prompto_preexec --on-event fish_preexec
    if test $_prompto_ftcs_marks = 1
        echo -ne "\e]133;C\a"
    end
end

# perform cleanup so a new initialization in current session works
if bind \r --user 2>/dev/null | string match -qe _prompto_enter_key_handler
    bind -e \r -M default
    bind -e \r -M insert
    bind -e \r -M visual
end

if bind \n --user 2>/dev/null | string match -qe _prompto_enter_key_handler
    bind -e \n -M default
    bind -e \n -M insert
    bind -e \n -M visual
end

if bind \cc --user 2>/dev/null | string match -qe _prompto_ctrl_c_key_handler
    bind -e \cc -M default
    bind -e \cc -M insert
    bind -e \cc -M visual
end

if bind \x20 --user 2>/dev/null | string match -qe _prompto_space_key_handler
    bind -e \x20 -M default
    bind -e \x20 -M insert
end

# tooltip

function _prompto_space_key_handler
    commandline --function expand-abbr
    commandline --insert ' '

    # Get the first word of command line as tip.
    set --local tooltip_command (commandline --current-buffer | string trim -l | string split --allow-empty -f1 ' ' | string collect)

    if test -z "$tooltip_command"
        _prompto_restore_tooltip_rprompt
        commandline --function repaint
        return
    end

    # Ignore repeated tooltip command.
    if test "$tooltip_command" = "$_prompto_tooltip_command"
        return
    end

    set --local config_arg
    if test -n "$_prompto_config"
        set config_arg "--config=$_prompto_config"
    end

    set --local tooltip_prompt (
        $_prompto_executable tooltip \
            $config_arg \
            --shell=fish \
            --shell-version=$FISH_VERSION \
            --pid=$fish_pid \
            --status=$_prompto_status \
            --pipestatus="$_prompto_pipestatus" \
            --no-status=$_prompto_no_status \
            --execution-time=$_prompto_execution_time \
            --stack-count=$_prompto_stack_count \
            --command=$tooltip_command \
            | string join ''
    )

    if test -z "$tooltip_prompt"
        _prompto_restore_tooltip_rprompt
        commandline --function repaint
        return
    end

    if test "$_prompto_tooltip_active" != "1"
        set --global _prompto_tooltip_saved_rprompt "$_prompto_current_rprompt"
    end

    set --global _prompto_tooltip_active 1
    set --global _prompto_tooltip_command "$tooltip_command"

    set _prompto_current_rprompt $tooltip_prompt
    set _prompto_current_rprompt (_prompto_expand_shell_clock "$_prompto_current_rprompt")
    commandline --function repaint
end

function _prompto_restore_tooltip_rprompt
    if test "$_prompto_tooltip_active" != "1"
        return
    end

    set --global _prompto_current_rprompt "$_prompto_tooltip_saved_rprompt"
    set --global _prompto_tooltip_saved_rprompt ''
    set --global _prompto_tooltip_command ''
    set --global _prompto_tooltip_active 0
end

function _prompto_tooltip_backspace_key_handler
    commandline --function backward-delete-char
    _prompto_restore_tooltip_rprompt
    commandline --function repaint
end

function _prompto_tooltip_delete_key_handler
    commandline --function delete-char
    _prompto_restore_tooltip_rprompt
    commandline --function repaint
end

function enable_prompto_tooltips
    bind \x20 _prompto_space_key_handler -M default
    bind \x20 _prompto_space_key_handler -M insert
    bind \x7f _prompto_tooltip_backspace_key_handler -M default
    bind \x7f _prompto_tooltip_backspace_key_handler -M insert
    bind \e\[3~ _prompto_tooltip_delete_key_handler -M default
    bind \e\[3~ _prompto_tooltip_delete_key_handler -M insert
end

# transient prompt

function _prompto_enter_key_handler
    if commandline --paging-mode
        commandline --function execute
        return
    end

    if commandline --is-valid || test -z (commandline --current-buffer | string trim -l | string collect)
        set --global _prompto_new_prompt 1
        set --global _prompto_tooltip_command ''

        if test $_prompto_transient_prompt = 1
            set --global _prompto_transient 1
            commandline --function repaint
        end
    end

    commandline --function execute
end

function _prompto_ctrl_c_key_handler
    if test -z (commandline --current-buffer | string collect)
        return
    end

    # Render a transient prompt on Ctrl-C with non-empty command line buffer.
    set --global _prompto_new_prompt 1
    set --global _prompto_tooltip_command ''

    if test $_prompto_transient_prompt = 1
        set --global _prompto_transient 1
        commandline --function repaint
    end

    commandline --function cancel-commandline
    commandline --function repaint
end

bind \r _prompto_enter_key_handler -M default
bind \r _prompto_enter_key_handler -M insert
bind \r _prompto_enter_key_handler -M visual
bind \n _prompto_enter_key_handler -M default
bind \n _prompto_enter_key_handler -M insert
bind \n _prompto_enter_key_handler -M visual
bind \cc _prompto_ctrl_c_key_handler -M default
bind \cc _prompto_ctrl_c_key_handler -M insert
bind \cc _prompto_ctrl_c_key_handler -M visual

# legacy functions
function enable_prompto_transient_prompt
    return
end

# This can be called by user whenever re-rendering is required.
function prompto_repaint_prompt
    set --global _prompto_new_prompt 1
    commandline --function repaint
end

# Vim mode variables
set --global _prompto_vim_mode 0
set --global _prompto_vim_mode_repaint 0
set --global _prompto_cursor_shape 0
set --global _prompto_cursor_blink 0

# Get current vim mode for segment template
function _prompto_get_vim_mode
    switch $fish_bind_mode
        case default
            echo "normal"
        case insert
            echo "insert"
        case replace replace_one
            echo "replace"
        case visual
            echo "visual"
        case '*'
            echo "insert"
    end
end

# Check if terminal handles cursor natively (Ghostty, Kitty)
function _prompto_should_change_cursor
    test -n "$GHOSTTY_RESOURCES_DIR" && return 1
    test -n "$KITTY_WINDOW_ID" && return 1
    return 0
end

# Mirrors config.IsConsole: PROMPTO_CONSOLE overrides, otherwise TERM.
function _prompto_is_console
    test "$PROMPTO_CONSOLE" = "1" && return 0
    test "$PROMPTO_CONSOLE" = "0" && return 1
    test "$TERM" = "linux"
end

function _prompto_apply_cursor_shape
    # Change cursor shape if enabled and terminal doesn't handle it natively
    if not test "$_prompto_cursor_shape" = "1"; or not _prompto_should_change_cursor
        return
    end

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
    if _prompto_is_console
        switch $fish_bind_mode
            case default visual
                printf '\e[?6c'  # Block for normal and visual mode
            case '*'
                printf '\e[?2c'  # Underline: the thinnest the console offers
        end
        return
    end

    set --local block_code 2
    set --local beam_code 6
    set --local underline_code 4
    if test "$_prompto_cursor_blink" = "1"
        set block_code 1
        set beam_code 5
        set underline_code 3
    end
    switch $fish_bind_mode
        case default
            printf '\e['$block_code' q'  # Block for normal mode
        case insert
            printf '\e['$beam_code' q'  # Beam for insert mode
        case replace_one replace
            printf '\e['$underline_code' q'  # Underline for replace mode
        case visual
            printf '\e['$block_code' q'  # Block for visual mode
        case '*'
            printf '\e['$beam_code' q'  # Beam for insert mode
    end
end

# Vim mode change handler - watches fish_bind_mode variable
function _prompto_on_bind_mode_change --on-variable fish_bind_mode
    # Only trigger if vim mode is enabled
    if test "$_prompto_vim_mode" != "1"
        return
    end

    _prompto_apply_cursor_shape

    # In daemon mode, trigger async repaint with new vim mode
    if test "$_prompto_daemon_mode" = "1"
        _prompto_daemon_render --repaint
    end

    # Trigger prompt repaint
    commandline -f repaint
end

function enable_prompto_vim_mode
    set --global _prompto_vim_mode 1
end

# Daemon mode functions
set --global _prompto_daemon_mode 0
set --global _prompto_daemon_prompt_file ""
set --global _prompto_current_transient ""
set --global _prompto_current_secondary ""

# Signal handler for async prompt updates
function _prompto_daemon_repaint --on-signal USR1
    if test -n "$_prompto_daemon_prompt_file" && test -f "$_prompto_daemon_prompt_file"
        # Read updated prompts from temp file
        while read -l line
            set --local parts (string split -m1 ':' -- $line)
            set --local type $parts[1]
            set --local text (_prompto_decode_render_text "$parts[2]")
            switch $type
                case primary
                    set --global _prompto_current_prompt (_prompto_expand_shell_clock "$text" | string collect)
                case right
                    set --global _prompto_current_rprompt (_prompto_expand_shell_clock "$text" | string collect)
                case transient
                    if test $_prompto_transient_prompt = 1
                        set --global _prompto_current_transient (_prompto_expand_shell_clock "$text" | string collect)
                    end
                case secondary
                    set --global _prompto_current_secondary (_prompto_expand_shell_clock "$text" | string collect)
            end
        end < $_prompto_daemon_prompt_file
    end
    # Small delay for stability (per fish-async-prompt)
    sleep 0.02
    commandline -f repaint >/dev/null 2>/dev/null
end

# The prompt file outlives each render so a late signal still finds the last
# batch, so the session has to clean it up on the way out.
function _prompto_daemon_cleanup --on-event fish_exit
    # No wildcard: fish aborts a command whose glob matches nothing, which is
    # the normal case. Each reader removes its own batch file.
    if test -n "$_prompto_daemon_prompt_file"
        rm -f $_prompto_daemon_prompt_file 2>/dev/null
    end
end

function enable_prompto_daemon
    set --global _prompto_daemon_mode 1
    set --global _prompto_daemon_prompt_file /tmp/prompto_fish_prompt_$fish_pid

    # Replace prompt functions with daemon versions
    functions --erase fish_prompt
    functions --copy _prompto_daemon_fish_prompt fish_prompt
    functions --erase fish_right_prompt
    functions --copy _prompto_daemon_fish_right_prompt fish_right_prompt
end

# Async daemon render - used by both prompt and vim mode changes
# Pass --repaint for vim mode toggles (soft cancel, reuse computations)
function _prompto_daemon_render
    set --local repaint_flag $argv[1]

    set --local vim_mode_arg ""
    if test "$_prompto_vim_mode" = "1"
        set vim_mode_arg "--vim-mode="(_prompto_get_vim_mode)
    end

    # Start the background reader. The prompt file is deliberately left alone:
    # it holds the last batch published, and the signal handler may still be on
    # its way to read it. The reader replaces it whole, per batch.
    #
    # A superseded reader is left running rather than killed. It can still
    # publish a batch that has gone stale over a newer one, which shows the
    # previous command's state for a single prompt; killing it would trade that
    # for signalling a pid that fish has already reaped and reused, on every
    # vim-mode keystroke. Closing the race properly needs a generation token the
    # reader re-reads before publishing, not a signal.
    _prompto_daemon_reader $_prompto_daemon_prompt_file $fish_pid $repaint_flag $vim_mode_arg &
    disown
end

# Background reader that streams daemon output
function _prompto_daemon_reader
    set --local prompt_file $argv[1]
    set --local parent_pid $argv[2]
    set --local repaint_flag $argv[3]
    set --local vim_mode_arg $argv[4]

    set --local config_arg
    if test -n "$_prompto_config"
        set config_arg "--config=$_prompto_config"
    end

    # Private to this reader, so a superseded one cannot write into the batch
    # this one is assembling. mktemp rather than a random suffix: fish seeds
    # `random` per process, so readers forked from a shell that has already
    # called it draw the same number and collide on the very file that is
    # supposed to keep them apart.
    set --local batch_file (mktemp "$prompt_file.XXXXXX")
    if test -z "$batch_file"
        # Without somewhere to assemble batches this reader can only publish
        # nothing at all, which leaves the prompt on its placeholders for good.
        return
    end

    _prompto_ensure_executable
    $_prompto_executable render \
        $config_arg \
        --shell=fish \
        --shell-version=$FISH_VERSION \
        --pid=$parent_pid \
        --status=$_prompto_status \
        --pipestatus="$_prompto_pipestatus" \
        --no-status=$_prompto_no_status \
        --execution-time=$_prompto_execution_time \
        --stack-count=$_prompto_stack_count \
        $vim_mode_arg \
        $repaint_flag \
        2>/dev/null | while read -l line
        set --local parts (string split -m1 ':' -- $line)
        set --local type $parts[1]

        # Collect the batch in a private file. The parent reads $prompt_file
        # whenever the signal reaches it, which is not necessarily before the
        # next line arrives, so a half-written batch must never be visible there.
        if test "$type" = "primary" || test "$type" = "right" || test "$type" = "secondary"
            echo $line >> $batch_file
        else if test "$type" = "transient" && test $_prompto_transient_prompt = 1
            echo $line >> $batch_file
        end

        # A status line closes a batch: publish it, then signal.
        if test "$type" = "status"
            # Publish by rename, so the parent always reads a whole batch, and
            # start the next one from empty. Truncating $prompt_file in place
            # instead loses the batch whenever the handler reads between the
            # signal and the next line — and since USR1 does not queue, a
            # coalesced pair of signals then leaves the prompt on its
            # placeholders for good.
            mv -f $batch_file $prompt_file 2>/dev/null
            kill -USR1 $parent_pid 2>/dev/null

            if test "$parts[2]" = "complete"
                break
            end
        end
    end

    # Only the private batch file is cleaned up. $prompt_file holds the final
    # prompt and is the parent's to read, including for a signal still in
    # flight; removing it here is what leaves the prompt showing placeholders.
    rm -f $batch_file 2>/dev/null
end

function _prompto_daemon_fish_prompt
    set --local prompto_status_temp $status
    set --local prompto_pipestatus_temp $pipestatus
    # clear from cursor to end of screen
    printf \e\[0J

    if test "$_prompto_transient" = 1
        echo -n (_prompto_expand_shell_clock "$_prompto_current_transient")
        return
    end

    if test "$_prompto_new_prompt" = 0
        echo -n (_prompto_expand_shell_clock "$_prompto_current_prompt")
        return
    end

    set --global _prompto_status $prompto_status_temp
    set --global _prompto_pipestatus $prompto_pipestatus_temp
    set --global _prompto_no_status false
    set --global _prompto_execution_time "$CMD_DURATION$cmd_duration"
    set --global _prompto_stack_count (count $dirstack)

    if set --query _prompto_last_command && test -z "$_prompto_last_command"
        set _prompto_execution_time 0
        set _prompto_no_status true
    end

    if set --query _prompto_last_status_generation && test "$_prompto_last_status_generation" = "$status_generation"
        set _prompto_execution_time 0
        set _prompto_no_status true
    else if test -z "$_prompto_last_status_generation"
        set _prompto_no_status true
    end

    if set --query status_generation
        set --global _prompto_last_status_generation $status_generation
    end

    set_promptocontext
    _prompto_apply_cursor_shape

    if test $_prompto_prompt_mark = 1
        iterm2_prompt_mark
    end

    _prompto_daemon_render

    # Return cached prompt immediately (will be updated via signal)
    echo -n (_prompto_expand_shell_clock "$_prompto_current_prompt")
end

function _prompto_daemon_fish_right_prompt
    if test "$_prompto_transient" = 1
        set --global _prompto_transient 0
        return
    end

    if test "$_prompto_new_prompt" = 0
        echo -n (_prompto_expand_shell_clock "$_prompto_current_rprompt")
        return
    end

    set --global _prompto_new_prompt 0
    echo -n (_prompto_expand_shell_clock "$_prompto_current_rprompt")
end
