#!/bin/bash
#
# Install this working tree as the night-watchman plugin, live, so ordinary
# work exercises hooks, providers and ${CLAUDE_PLUGIN_ROOT} before a release.
#
# WHY. The offline selftests (docs/testing-philosophy.md) stub every seam that
# reaches outside the process, including the exec into a provider
# implementation. NWM-171 leaked a temp file on exactly that seam and no
# assertion could have seen it; a dev build in use would have piled the
# evidence into TMPDIR within minutes. A stub harness proves what a test
# enumerates. Running it for real exercises what nobody enumerated.
#
# HOW. A marketplace whose entry's source is RELATIVE to its own root (an
# absolute path is refused), holding a symlink to this checkout. The plugin is
# then installed, and its cache directory replaced by a symlink to the
# checkout, so an edit is live with no reinstall.
#
# Usage:
#   dev-install.sh [--marketplace-dir DIR] [--name NAME] [--dry-run]
#   dev-install.sh --status
#   dev-install.sh --uninstall [--marketplace-dir DIR] [--name NAME]
#   dev-install.sh --help
#
# --status prints what is installed and whether it is live.
# --uninstall removes the plugin and the dev marketplace, never the checkout.
# --dry-run prints every command it would run and changes nothing.
#
# It honours $CLAUDE_CONFIG_DIR, so a scratch directory isolates a trial run
# from the real configuration. The marketplace lives OUTSIDE this repo by
# default, because a plugin repo carries plugin.json and no marketplace.json.
#
# NEVER run `claude plugin update` against this: it is a no-op when the
# version matches, so it prints success and leaves the old copy. --refresh
# below does the uninstall/install pair that actually replaces it, and is
# only needed when the cache is a real directory rather than a symlink.
#
# Exit codes: 0 done, 1 a step failed, 2 a precondition could not be met.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/kit.sh
. "$HERE/lib/kit.sh"

stop2() { echo "Error: $*" >&2; exit 2; }

MARKETPLACE_DIR="${NW_DEV_MARKETPLACE_DIR:-$(dirname "$REPO")/.night-watchman-dev-marketplace}"
MARKETPLACE_NAME="nw-dev"
PLUGIN_NAME="night-watchman"
ACTION=install
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) show_help ;;
        --marketplace-dir)
            [ $# -ge 2 ] || stop2 "--marketplace-dir needs a path"
            MARKETPLACE_DIR="$2"; shift 2 ;;
        --name)
            [ $# -ge 2 ] || stop2 "--name needs a marketplace name"
            MARKETPLACE_NAME="$2"; shift 2 ;;
        --status) ACTION=status; shift ;;
        --uninstall) ACTION=uninstall; shift ;;
        --refresh) ACTION=refresh; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) stop2 "unknown option: $1 (see --help)" ;;
    esac
done

need claude python3
PLUGIN_ID="$PLUGIN_NAME@$MARKETPLACE_NAME"

# run CMD... — obey --dry-run uniformly, so no path mutates under it.
run() {
    if [ "$DRY_RUN" = 1 ]; then
        echo "  would run: $*"
        return 0
    fi
    "$@"
}

plugin_field() {
    claude plugin list --json 2>/dev/null | python3 -c '
import json, sys
want, field = sys.argv[1], sys.argv[2]
try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for p in rows if isinstance(rows, list) else rows.get("plugins", []):
    if p.get("id") == want:
        v = p.get(field)
        print("" if v is None else v)
        break
' "$PLUGIN_ID" "$1"
}

plugin_version() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' \
        "$REPO/.claude-plugin/plugin.json" 2>/dev/null
}

# is_live PATH — 0 when the install path is a symlink resolving to this
# checkout, which is what makes an edit visible with no reinstall.
is_live() {
    [ -n "$1" ] || return 1
    [ -L "$1" ] || return 1
    [ "$(cd "$1" 2>/dev/null && pwd -P)" = "$(cd "$REPO" && pwd -P)" ]
}

print_status() {
    local path
    path="$(plugin_field installPath)"
    if [ -z "$path" ]; then
        echo "$PLUGIN_ID: not installed"
        return 0
    fi
    echo "$PLUGIN_ID"
    echo "  version : $(plugin_field version)"
    echo "  enabled : $(plugin_field enabled)"
    echo "  path    : $path"
    if is_live "$path"; then
        echo "  live    : yes — a symlink to $REPO, so an edit here is live with no reinstall"
    else
        echo "  live    : NO — a copy. An edit here is NOT what runs; re-run dev-install.sh"
        echo "            ('claude plugin update' will not help: it is a no-op at the same version)"
    fi
    [ -n "${CLAUDE_CONFIG_DIR:-}" ] && echo "  config  : \$CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR"
    return 0
}

write_marketplace() {
    run mkdir -p "$MARKETPLACE_DIR/.claude-plugin" || stop2 "cannot create $MARKETPLACE_DIR"
    # The entry's source must be RELATIVE to the marketplace root; an absolute
    # path is refused with "source: Invalid input". Hence the symlink.
    if [ ! -L "$MARKETPLACE_DIR/$PLUGIN_NAME" ]; then
        run ln -s "$REPO" "$MARKETPLACE_DIR/$PLUGIN_NAME" \
            || stop2 "cannot link $MARKETPLACE_DIR/$PLUGIN_NAME -> $REPO"
    fi
    if [ "$DRY_RUN" = 1 ]; then
        echo "  would write: $MARKETPLACE_DIR/.claude-plugin/marketplace.json"
        return 0
    fi
    cat > "$MARKETPLACE_DIR/.claude-plugin/marketplace.json" <<JSON
{
  "name": "$MARKETPLACE_NAME",
  "description": "Local dev marketplace: runs a night-watchman checkout as the installed plugin. Not for publishing.",
  "owner": { "name": "local dev" },
  "plugins": [
    {
      "name": "$PLUGIN_NAME",
      "description": "Working-tree checkout, for exercising hooks and providers before a release.",
      "source": "./$PLUGIN_NAME"
    }
  ]
}
JSON
}

# make_live — replace the installed COPY with a symlink to the checkout. The
# guard is not ceremony: without it a later --uninstall would delete through
# the symlink and take the repository with it.
make_live() {
    local cache="$1"
    case "$cache" in
        "$REPO"|"$REPO"/*) stop2 "refusing to touch '$cache': it is inside the checkout" ;;
        */plugins/cache/*) ;;
        *) stop2 "refusing to touch '$cache': not under a plugins/cache directory" ;;
    esac
    if [ -L "$cache" ]; then
        run rm -f "$cache" || stop2 "cannot replace the existing link at $cache"
    elif [ -d "$cache" ]; then
        run rm -rf "$cache" || stop2 "cannot remove the installed copy at $cache"
    fi
    run ln -s "$REPO" "$cache" || stop2 "cannot link $cache -> $REPO"
}

case "$ACTION" in
    status) print_status ;;

    uninstall)
        echo "Removing $PLUGIN_ID and its dev marketplace..."
        # Order matters: drop the symlink BEFORE uninstalling, so nothing the
        # CLI does can follow it into the checkout.
        CACHE="$(plugin_field installPath)"
        if [ -L "$CACHE" ]; then
            echo "  unlinking the live install at $CACHE (the checkout itself is untouched)"
            run rm -f "$CACHE"
        fi
        run claude plugin uninstall "$PLUGIN_ID" >/dev/null 2>&1
        run claude plugin marketplace remove "$MARKETPLACE_NAME" >/dev/null 2>&1
        if [ -L "$MARKETPLACE_DIR/$PLUGIN_NAME" ]; then
            run rm -f "$MARKETPLACE_DIR/$PLUGIN_NAME"
        fi
        if [ -f "$MARKETPLACE_DIR/.claude-plugin/marketplace.json" ]; then
            run rm -f "$MARKETPLACE_DIR/.claude-plugin/marketplace.json"
            run rmdir "$MARKETPLACE_DIR/.claude-plugin" 2>/dev/null
            run rmdir "$MARKETPLACE_DIR" 2>/dev/null
        fi
        [ "$DRY_RUN" = 1 ] || echo "removed. The checkout at $REPO is untouched."
        ;;

    install|refresh)
        VERSION="$(plugin_version)"
        [ -n "$VERSION" ] || stop2 "cannot read .claude-plugin/plugin.json's version in $REPO"
        echo "Installing $REPO as $PLUGIN_ID (version $VERSION)..."
        write_marketplace
        run claude plugin marketplace remove "$MARKETPLACE_NAME" >/dev/null 2>&1
        run claude plugin marketplace add "$MARKETPLACE_DIR" >/dev/null 2>&1 \
            || stop2 "'claude plugin marketplace add $MARKETPLACE_DIR' failed"
        run claude plugin uninstall "$PLUGIN_ID" >/dev/null 2>&1
        run claude plugin install "$PLUGIN_ID" --scope user >/dev/null 2>&1 \
            || stop2 "'claude plugin install $PLUGIN_ID' failed"

        if [ "$DRY_RUN" = 1 ]; then
            echo "  would then replace the installed copy with a symlink to $REPO"
            echo "--dry-run: nothing was changed."
            exit 0
        fi

        CACHE="$(plugin_field installPath)"
        [ -n "$CACHE" ] || stop2 "the plugin installed but 'claude plugin list' reports no installPath for $PLUGIN_ID"
        make_live "$CACHE"

        echo
        print_status
        echo
        echo "Now use it. A hook firing, a provider dispatching or anything reached"
        echo "through \${CLAUDE_PLUGIN_ROOT} runs THIS tree from here on."
        ;;
esac
