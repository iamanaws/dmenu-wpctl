#!/usr/bin/env bash
set -euo pipefail

script=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/dmenu-wpctl
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
export TEST_CAPTURE="$test_dir/menu" TEST_CALLS="$test_dir/calls" TEST_STEPS="$test_dir/steps"

# Exported functions intercept every device/menu command; no real audio changes.
wpctl() {
    printf '%s\n' "$*" >> "$TEST_CALLS"
    case "$*" in
        status) printf '%s\n' "$WPCTL_STATUS" ;;
        'get-volume 42'|'get-volume @DEFAULT_AUDIO_SINK@') printf 'Volume: 0.50\n' ;;
        'get-volume 43'|'get-volume @DEFAULT_AUDIO_SOURCE@') printf 'Volume: 0.25\n' ;;
        'set-mute 42 toggle'|'set-mute 43 toggle') ;;
        *) return 1 ;;
    esac
}

rofi() {
    local menu step=0
    menu=$(cat)
    printf '%s\n' "$menu" >> "$TEST_CAPTURE"
    if [[ -f "$TEST_STEPS" ]]; then read -r step < "$TEST_STEPS"; fi
    step=$((step + 1))
    printf '%s\n' "$step" > "$TEST_STEPS"
    if [[ "$step" == 1 && "$TEST_PICK" != Exit ]]; then
        printf '%s\n' "$menu" | grep -F "$TEST_PICK" | head -1
    elif [[ "$step" == 2 && "${TEST_MUTE:-0}" == 1 ]]; then
        printf 'Mute: Unmuted\n'
    else
        printf 'Exit\n'
    fi
}
export -f wpctl rofi

status_fixture() {
    printf '%s\n' \
        Audio \
        ' ├─ Sinks:' "$1" \
        ' ├─ Sources:' "$2" \
        ' └─ Streams:' \
        '    99. Playback stream' \
        Video \
        ' └─ Sources:' \
        '    * 77. Camera' \
        Settings
}

run_menu() {
    export TEST_PICK="${1:-Exit}" TEST_MUTE="${2:-0}"
    : > "$TEST_CAPTURE"
    : > "$TEST_CALLS"
    printf '0\n' > "$TEST_STEPS"
    MENU_PROGRAM=rofi bash "$script" "${3:---audio}"
}

assert_contains() {
    if ! grep -Fq -- "$2" "$1"; then
        printf 'Missing expected text: %s\n' "$2" >&2
        exit 1
    fi
}

assert_absent() {
    if grep -Fq -- "$2" "$1"; then
        printf 'Unexpected text: %s\n' "$2" >&2
        exit 1
    fi
}

speaker=' │  * 42. Speaker [vol: 0.50]'
microphone=' │  * 43. Microphone [vol: 0.25]'
export WPCTL_STATUS

# Missing output must not pick the microphone or open its controls.
WPCTL_STATUS=$(status_fixture '' "$microphone")
run_menu 'Output:' 1
assert_contains "$TEST_CAPTURE" 'Output: No default device'
assert_contains "$TEST_CAPTURE" 'Input: Microphone (25%, Unmuted)'
assert_absent "$TEST_CAPTURE" 'Output Devices:'
assert_absent "$TEST_CAPTURE" 'Volume: +5%'
assert_absent "$TEST_CALLS" 'set-mute'

# Missing input must not pick a stream/video device or open empty-ID controls.
WPCTL_STATUS=$(status_fixture "$speaker" '')
run_menu 'Input:' 1
assert_contains "$TEST_CAPTURE" 'Input: No default device'
assert_contains "$TEST_CAPTURE" 'Output: Speaker (50%, Unmuted)'
assert_absent "$TEST_CAPTURE" 'Input Devices:'
assert_absent "$TEST_CAPTURE" 'Volume: +5%'
assert_absent "$TEST_CALLS" 'set-mute'

WPCTL_STATUS=$(status_fixture '' '')
run_menu
assert_contains "$TEST_CAPTURE" 'Output: No default device'
assert_contains "$TEST_CAPTURE" 'Input: No default device'
assert_absent "$TEST_CALLS" 'get-volume'

# A device can exist without being default; keep it selectable in the list.
WPCTL_STATUS=$(status_fixture "${speaker/\*/ }" "$microphone")
run_menu 'Output:'
assert_contains "$TEST_CAPTURE" 'Output: No default device'
assert_contains "$TEST_CAPTURE" '[42] Speaker (50%)'
assert_absent "$TEST_CAPTURE" 'Volume: +5%'
run_menu '[42]' 1
assert_contains "$TEST_CALLS" 'set-mute 42 toggle'
assert_absent "$TEST_CALLS" 'set-mute 43'

WPCTL_STATUS=$(status_fixture "$speaker" "${microphone/\*/ }")
run_menu 'Input:' 1
assert_contains "$TEST_CAPTURE" 'Input: No default device'
assert_absent "$TEST_CAPTURE" 'Volume: +5%'
run_menu '[43]' 1
assert_contains "$TEST_CAPTURE" 'Set as Default Input'
assert_absent "$TEST_CAPTURE" 'Set as Default Output'
assert_contains "$TEST_CALLS" 'set-mute 43 toggle'
assert_absent "$TEST_CALLS" 'set-mute 42'

# Normal output/input shortcuts and list selections must retain their targets.
WPCTL_STATUS=$(status_fixture "$speaker" "$microphone")
run_menu
assert_contains "$TEST_CAPTURE" 'Output: Speaker (50%, Unmuted)'
assert_contains "$TEST_CAPTURE" 'Input: Microphone (25%, Unmuted)'
menu=$(<"$TEST_CAPTURE")
[[ "$menu" == *$'Output Devices:\n  [42] Speaker (50%)\n\nInput Devices:\n  [43] Microphone (25%)\n\nBack\nExit'* ]]
for selection in 'Output:' '[42]'; do
    run_menu "$selection" 1
    assert_contains "$TEST_CALLS" 'set-mute 42 toggle'
    assert_absent "$TEST_CALLS" 'set-mute 43'
done
for selection in 'Input:' '[43]'; do
    run_menu "$selection" 1
    assert_contains "$TEST_CALLS" 'set-mute 43 toggle'
    assert_absent "$TEST_CALLS" 'set-mute 42'
done

# Names containing numbered punctuation should not be truncated.
WPCTL_STATUS=$(status_fixture ' │  * 42. Speaker 2. Left [vol: 0.50]' "$microphone")
run_menu
assert_contains "$TEST_CAPTURE" 'Output: Speaker 2. Left (50%, Unmuted)'
assert_contains "$TEST_CAPTURE" '[42] Speaker 2. Left (50%)'

# Defaults beyond the old 50-line window must still resolve.
many_sinks=''
for ((id = 100; id < 160; id++)); do
    many_sinks+=" │    $id. Other speaker [vol: 0.50]"$'\n'
done
WPCTL_STATUS=$(status_fixture "$many_sinks$speaker" "$microphone")
run_menu
assert_contains "$TEST_CAPTURE" 'Output: Speaker (50%, Unmuted)'

# The final tree section can use a different branch glyph.
WPCTL_STATUS=$(status_fixture "$speaker" "$microphone")
WPCTL_STATUS=${WPCTL_STATUS/' ├─ Sources:'/' └─ Sources:'}
run_menu
assert_contains "$TEST_CAPTURE" '[43] Microphone (25%)'

# The shared parser must also preserve the video menu and its section boundary.
run_menu Exit 0 --video
assert_contains "$TEST_CAPTURE" 'Default: Camera'
assert_contains "$TEST_CAPTURE" '[77] Camera'
assert_absent "$TEST_CAPTURE" 'Microphone'

printf 'Audio menu regression tests passed.\n'
