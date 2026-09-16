#!/usr/bin/env bash
#
# close-update-window.sh — sourced by install.sh. Closes the Terminal window
# that Settings → Account → "Check for Updates" opened, once the install has
# succeeded, so an update needs no keypress.
#
# It lives in the repo (not in the app's generated .command) on purpose: the
# .command is written by the app version you are updating FROM, so a fix there
# only reaches users one update later. install.sh is pulled first, so this runs
# at the newest version every time.
#
# Only acts when install.sh's parent is a `skylark-update-*.command` running in
# Terminal. A manual `Scripts/install.sh` never closes anything.

close_update_window_if_launched_by_app() {
    local parent_cmd window_id
    parent_cmd="$(ps -o command= -p "$PPID" 2>/dev/null || true)"
    [[ "$parent_cmd" == *skylark-update-*.command* ]] || return 0
    [[ "${TERM_PROGRAM:-}" == "Apple_Terminal" ]] || return 0

    # THIS window: the busy tab on our tty. A finished window can reuse the
    # same tty name, so tty alone would also close an unrelated window.
    window_id="$(/usr/bin/osascript -e "tell application \"Terminal\" to get id of first window whose (tty of selected tab is \"$(tty)\") and (busy of selected tab is true)" 2>/dev/null || true)"
    [[ "$window_id" =~ ^[0-9]+$ ]] || return 0

    echo ""
    echo "✓ Update complete. This window will close by itself."

    # Delayed and detached so every shell in the window has exited first;
    # closing a window with a live process makes Terminal ask to terminate it.
    nohup /usr/bin/osascript -e 'delay 2' \
        -e "tell application \"Terminal\" to close (every window whose id is $window_id)" \
        </dev/null >/dev/null 2>&1 &

    # End the wrapper script now. Older app versions wrote a wrapper that waits
    # for a keypress after install.sh returns; stopping it here means those
    # updates close on their own too. It is our own generated script, and the
    # install is already finished.
    kill "$PPID" 2>/dev/null || true
}
