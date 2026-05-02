#!/usr/bin/env bash
# auto-commit.sh — bump the counter in README.md, append to commit-log.md,
# commit and push.
#
# Designed to run from BOTH GitHub Actions and local cron. The script
# detects which environment it's in and configures git accordingly.
#
# Local cron usage:
#   1) Clone the repo somewhere persistent:
#        git clone git@github.com:S-O-U-L-S-E-E-K-E-R/Auto-Commiter-Bot.git \
#            ~/.local/share/auto-commiter-bot
#   2) Add a cron line:
#        crontab -e
#        # daily at 14:13 UTC (give or take):
#        13 14 * * * cd ~/.local/share/auto-commiter-bot && ./auto-commit.sh \
#            >> ~/.local/share/auto-commiter-bot/cron.log 2>&1
#
# GitHub Actions usage: see .github/workflows/auto-commit.yml.
#
# Flags:
#   --dry-run         do everything except commit/push
#   --no-push         commit locally but don't push
#   --force           commit even if there are no changes (for testing)

set -euo pipefail

DRY_RUN=false
NO_PUSH=false
FORCE=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --no-push) NO_PUSH=true ;;
        --force)   FORCE=true ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

REPO_DIR="${REPO_DIR:-$(pwd)}"
README="$REPO_DIR/README.md"
LOG="$REPO_DIR/commit-log.md"
LOCK="$REPO_DIR/.commit-lock"

# ---- Locking: prevent concurrent runs (cron + manual collisions) ---------
exec 9>"$LOCK"
if ! flock -n 9; then
    echo "another auto-commit run holds the lock; exiting" >&2
    exit 0
fi

cd "$REPO_DIR"
[ -d .git ] || { echo "not a git repo: $REPO_DIR" >&2; exit 1; }
[ -f "$README" ] || { echo "missing $README" >&2; exit 1; }
[ -f "$LOG" ]    || { echo "missing $LOG" >&2; exit 1; }

# ---- Git author/committer identity ---------------------------------------
# In GitHub Actions, GITHUB_ACTIONS=true. We expect the workflow to provide
# AUTHOR_NAME / AUTHOR_EMAIL via env (set from secrets / vars there).
# Locally, fall back to user's global git config.
AUTHOR_NAME="${AUTHOR_NAME:-$(git config user.name 2>/dev/null || echo)}"
AUTHOR_EMAIL="${AUTHOR_EMAIL:-$(git config user.email 2>/dev/null || echo)}"
if [ -z "$AUTHOR_NAME" ] || [ -z "$AUTHOR_EMAIL" ]; then
    echo "AUTHOR_NAME and AUTHOR_EMAIL must be set (env or git config)" >&2
    exit 1
fi
git config user.name  "$AUTHOR_NAME"
git config user.email "$AUTHOR_EMAIL"

# ---- Pull latest before mutating ----------------------------------------
git fetch --quiet origin
DEFAULT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo main)"
git pull --quiet --rebase origin "$DEFAULT_BRANCH" || {
    echo "pull failed; aborting to avoid mid-flight conflicts" >&2
    exit 1
}

# ---- Read current count from README -------------------------------------
COUNT="$(grep -oE 'Count Commits:[[:space:]]*[0-9]+' "$README" | grep -oE '[0-9]+$' || echo 0)"
NEXT=$((COUNT + 1))
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---- Pick a commit message ----------------------------------------------
MESSAGES=(
    "Daily activity log"
    "Auto-bump counter"
    "Routine sync"
    "Scheduled tick"
    "Daily commit"
    "Activity update"
    "Counter increment"
    "Heartbeat commit"
    "Auto rotation"
    "Daily journal entry"
)
MSG="${MESSAGES[RANDOM % ${#MESSAGES[@]}]} #$NEXT"

# ---- Compute current streak (consecutive UTC days with a commit) --------
STREAK=1
LAST_COMMIT_DAY="$(git log -1 --format=%cs 2>/dev/null || true)"
TODAY="$(date -u +%Y-%m-%d)"
if [ -n "$LAST_COMMIT_DAY" ] && [ "$LAST_COMMIT_DAY" != "$TODAY" ]; then
    YESTERDAY="$(date -u -d 'yesterday' +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d)"
    if [ "$LAST_COMMIT_DAY" = "$YESTERDAY" ]; then
        # Count back through commit days to find streak length
        STREAK="$(git log --format=%cs | awk -v t="$TODAY" '
            NR==1 { last=$1; if (last==t) { c=1 } else { c=1; last=t } ; next }
            {
                cmd = "date -u -d \"" last " -1 day\" +%Y-%m-%d 2>/dev/null"
                cmd | getline prev; close(cmd)
                if ($1 == prev) { c++; last=prev } else { exit }
            }
            END { print c }
        ')"
        STREAK=$((STREAK + 1))
    fi
fi

# ---- Update README block ------------------------------------------------
TMP="$(mktemp)"
awk -v c="$NEXT" -v t="$NOW" -v m="$MSG" -v s="$STREAK" '
    /^Count Commits:/  { print "Count Commits: " c; next }
    /^Last Update:/    { print "Last Update:   " t; next }
    /^Last Message:/   { print "Last Message:  " m; next }
    /^Streak Day:/     { print "Streak Day:    " s; next }
    { print }
' "$README" > "$TMP" && mv "$TMP" "$README"

# ---- Append to commit-log.md (newest stays at top of table) -------------
# Insert a new row after the table header.
awk -v n="$NEXT" -v t="$NOW" -v m="$MSG" '
    !inserted && /^\|---/ { print; print "| " n " | " t " | " m " |"; inserted=1; next }
    { print }
' "$LOG" > "$TMP" && mv "$TMP" "$LOG"

# ---- Commit + push ------------------------------------------------------
if "$DRY_RUN"; then
    echo "DRY RUN — would commit:"
    echo "  count: $COUNT -> $NEXT"
    echo "  msg:   $MSG"
    echo "  streak: $STREAK"
    git --no-pager diff --stat
    exit 0
fi

git add README.md commit-log.md
if "$FORCE" || ! git diff --cached --quiet; then
    git commit --quiet -m "$MSG"
    if "$NO_PUSH"; then
        echo "committed locally (no push): $MSG"
    else
        git push --quiet origin "$DEFAULT_BRANCH"
        echo "pushed: $MSG (#$NEXT, streak $STREAK)"
    fi
else
    echo "no changes to commit (--force to override)"
fi
