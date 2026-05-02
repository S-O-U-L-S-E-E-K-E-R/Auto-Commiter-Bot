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

DEFAULT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo main)"

# ---- Pull latest before mutating (skip in dry-run; skip if no remote) ---
if ! "$DRY_RUN" && git remote get-url origin >/dev/null 2>&1; then
    git fetch --quiet origin || true
    if git rev-parse --verify --quiet "origin/$DEFAULT_BRANCH" >/dev/null; then
        # Refuse to pull if the working tree is dirty — would break --rebase.
        # Ignore the script itself being modified (common during dev).
        if ! git diff-index --quiet HEAD -- ':!auto-commit.sh'; then
            echo "working tree has uncommitted changes; refusing to pull/rebase" >&2
            git status --short >&2
            exit 1
        fi
        git pull --quiet --rebase origin "$DEFAULT_BRANCH" || {
            echo "pull failed; aborting to avoid mid-flight conflicts" >&2
            exit 1
        }
    fi
fi

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

# ---- Compute streak: today's commit + consecutive previous UTC days ----
# GitHub's contribution graph uses UTC day boundaries, so convert each commit's
# ISO timestamp to its UTC calendar day before counting.
TODAY="$(date -u +%Y-%m-%d)"
STREAK=1
DAYS_WITH_COMMITS="$(
    git log --format=%cI 2>/dev/null | while IFS= read -r iso; do
        [ -n "$iso" ] && date -u -d "$iso" +%Y-%m-%d 2>/dev/null
    done | sort -u
)"
day="$TODAY"
while true; do
    prev="$(date -u -d "$day -1 day" +%Y-%m-%d 2>/dev/null \
            || date -u -v-1d -j -f '%Y-%m-%d' "$day" +%Y-%m-%d 2>/dev/null)"
    [ -z "$prev" ] && break
    if echo "$DAYS_WITH_COMMITS" | grep -qx "$prev"; then
        STREAK=$((STREAK + 1))
        day="$prev"
    else
        break
    fi
done

# ---- Dry-run reports without touching disk -----------------------------
if "$DRY_RUN"; then
    echo "DRY RUN — would commit:"
    echo "  count:  $COUNT -> $NEXT"
    echo "  msg:    $MSG"
    echo "  streak: $STREAK"
    echo "  ts:     $NOW"
    exit 0
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
awk -v n="$NEXT" -v t="$NOW" -v m="$MSG" '
    !inserted && /^\|---/ { print; print "| " n " | " t " | " m " |"; inserted=1; next }
    { print }
' "$LOG" > "$TMP" && mv "$TMP" "$LOG"

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
