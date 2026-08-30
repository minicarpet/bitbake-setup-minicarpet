#!/bin/bash

# Must be sourced, not executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: this script must be sourced. Use: source $0 $*"
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE="$SCRIPT_DIR/../raspberry.conf.json"
DEFAULT_CONFIG_NAME="raspberry-pi-4"

# Parse --prepare-host and --fix-layers flags before other arguments.
PREPARE_HOST=0
FIX_LAYERS=0
ARGS=()
for arg in "$@"; do
    if [ "$arg" = "--prepare-host" ]; then
        PREPARE_HOST=1
    elif [ "$arg" = "--fix-layers" ]; then
        FIX_LAYERS=1
    else
        ARGS+=("$arg")
    fi
done
set -- "${ARGS[@]+${ARGS[@]}}"

if [ "$PREPARE_HOST" = "1" ]; then
    bash "$SCRIPT_DIR/prepare_host.sh" || return $?
fi

mapfile -t VALID_CONFIGS < <(jq -r '."bitbake-setup".configurations[].name' "$CONFIG_FILE")

# When sourced, shell positional args can leak in from the caller. Only accept
# an argument if it is explicitly valid, otherwise use the default.
CONFIG_NAME="$DEFAULT_CONFIG_NAME"
if [ "$1" = "--config" ]; then
    if [ -z "$2" ]; then
        echo "Error: missing value for --config"
        return 1
    fi
    CONFIG_NAME="$2"
elif [ $# -gt 0 ]; then
    if printf '%s\n' "${VALID_CONFIGS[@]}" | grep -Fxq "$1"; then
        CONFIG_NAME="$1"
    else
        echo "Info: ignoring inherited shell positional argument '$1'; using default configuration '$DEFAULT_CONFIG_NAME'."
    fi
fi

SETUP_DIR=$(jq -r \
    '.["bitbake-setup"].configurations[]
     | select(.name == "'"$CONFIG_NAME"'")
     | .["setup-dir-name"]' \
    "$CONFIG_FILE")

if [ -z "$SETUP_DIR" ] || [ "$SETUP_DIR" = "null" ]; then
    echo "Error: unknown configuration '$CONFIG_NAME'"
    echo "Available configurations: ${VALID_CONFIGS[*]}"
    return 1
fi


SETUP_DIR_PREFIX="${BITBAKE_TOP_DIR_PREFIX:-$(realpath "${SCRIPT_DIR}/../../")}"
SETUP_DIR_FULL="$SETUP_DIR_PREFIX/bitbake-builds/$SETUP_DIR"

has_dirty_layer_repos() {
    local layers_dir="$1"
    local repo

    [ -d "$layers_dir" ] || return 1

    for repo in "$layers_dir"/*; do
        [ -d "$repo/.git" ] || continue
        if [ -n "$(git -C "$repo" status --porcelain --untracked-files=normal 2>/dev/null)" ]; then
            echo "Local changes detected in layer repository: $repo"
            return 0
        fi
    done

    return 1
}

verify_layer_revisions() {
    local setup_dir="$1"
    local sources_json="$setup_dir/config/sources-fixed-revisions.json"
    local mismatch=0

    [ -f "$sources_json" ] || return 0

    while IFS=$'\t' read -r repo_path expected_rev; do
        [ -z "$repo_path" ] || [ -z "$expected_rev" ] && continue
        local repo_dir="$setup_dir/layers/$repo_path"
        [ -d "$repo_dir/.git" ] || continue
        local actual
        actual=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null)
        if [ "$actual" != "$expected_rev" ]; then
            echo "Error: layer '$repo_path' is at $actual but expected $expected_rev after update."
            echo "Re-run with --fix-layers to attempt an automatic reset."
            mismatch=1
        fi
    done < <(_iter_layer_revisions "$sources_json")

    return $mismatch
}

fix_layer_revisions() {
    local setup_dir="$1"
    local sources_json="$setup_dir/config/sources-fixed-revisions.json"
    local failed=0

    [ -f "$sources_json" ] || return 0

    while IFS=$'\t' read -r repo_path expected_rev; do
        [ -z "$repo_path" ] || [ -z "$expected_rev" ] && continue
        local repo_dir="$setup_dir/layers/$repo_path"
        [ -d "$repo_dir/.git" ] || continue
        local actual
        actual=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null)
        if [ "$actual" != "$expected_rev" ]; then
            # Check for any local work (tracked changes or untracked files) before resetting
            if [ -n "$(git -C "$repo_dir" status --porcelain 2>/dev/null)" ]; then
                echo "Error: layer '$repo_path' is at $actual but expected $expected_rev and has local changes; will not reset."
                failed=1
            elif ! git -C "$repo_dir" reset --hard "$expected_rev" 2>/dev/null; then
                echo "Error: could not reset '$repo_path' to $expected_rev."
                echo "Check fetch logs in $setup_dir/layers/logs/ for details."
                failed=1
            else
                echo "Warning: layer '$repo_path' was at $actual; reset to $expected_rev."
            fi
        fi
    done < <(_iter_layer_revisions "$sources_json")

    return $failed
}

if [ ! -f "$SETUP_DIR_FULL/build/init-build-env" ]; then
    echo "Bitbake setup not found or not initialized. Initializing now..."
    "$SCRIPT_DIR/../bitbake/bin/bitbake-setup" \
        --setting default top-dir-prefix "$SETUP_DIR_PREFIX" \
        init --non-interactive \
        "$SCRIPT_DIR/../raspberry.conf.json" \
        "$CONFIG_NAME" || return $?
else
    echo "Bitbake setup already initialized, putting back the setup."
    if has_dirty_layer_repos "$SETUP_DIR_FULL/layers"; then
        echo "Skipping bitbake-setup update because local layer changes were found."
        echo "Run 'bitbake-setup update --setup-dir $SETUP_DIR_FULL --rebase-conflicts-strategy=backup'"
        echo "if you want to back up local repositories and re-clone from upstream."
    else
        "$SCRIPT_DIR/../bitbake/bin/bitbake-setup" update --setup-dir "$SETUP_DIR_FULL" --update-bb-conf yes --rebase-conflicts-strategy backup || return 1
        if [ "$FIX_LAYERS" = "1" ]; then
            fix_layer_revisions "$SETUP_DIR_FULL" || return 1
        else
            verify_layer_revisions "$SETUP_DIR_FULL" || return 1
        fi
    fi
fi

. "$SETUP_DIR_FULL/build/init-build-env" || return 1
