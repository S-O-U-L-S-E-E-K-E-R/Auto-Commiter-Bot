#!/usr/bin/env bash
# auto-commit.sh — bump the counter in README.md, append to commit-log.md,
# commit and push. Cadence and behavior are driven by bot.conf (sourced if
# present) and can be overridden via environment.
#
# Local cron usage:
#   1) Clone the repo somewhere persistent.
#   2) Add a cron line, e.g.:
#        13 14 * * * cd ~/Auto-Commiter-Bot && ./auto-commit.sh \
#                    >> ~/Auto-Commiter-Bot/cron.log 2>&1
#
# GitHub Actions usage: see .github/workflows/auto-commit.yml.
#
# Flags:
#   --dry-run         report what would happen, touch nothing
#   --no-push         commit locally but don't push
#   --force           commit even if there are no diffs (testing)
#   --commits N       override COMMITS_PER_RUN for this invocation
#   --no-jitter       skip START_JITTER_SECS for this invocation

set -euo pipefail

DRY_RUN=false
NO_PUSH=false
FORCE=false
NO_JITTER=false
COMMITS_OVERRIDE=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)    DRY_RUN=true ;;
        --no-push)    NO_PUSH=true ;;
        --force)      FORCE=true ;;
        --no-jitter)  NO_JITTER=true ;;
        --commits)    COMMITS_OVERRIDE="$2"; shift ;;
        --commits=*)  COMMITS_OVERRIDE="${1#*=}" ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
    shift
done

REPO_DIR="${REPO_DIR:-$(pwd)}"
README="$REPO_DIR/README.md"
LOG="$REPO_DIR/commit-log.md"
LOCK="$REPO_DIR/.commit-lock"
CONF="$REPO_DIR/bot.conf"

# ---- Load config (env overrides bot.conf, defaults are last resort) ----
# 1. Snapshot any opsec-relevant env vars set BEFORE we touched anything
declare -A _env_set
for v in COMMITS_PER_RUN INTER_COMMIT_DELAY START_JITTER_SECS \
         SKIP_DAYS ALLOW_HOURS DAILY_CAP; do
    [ -n "${!v+set}" ] && _env_set["$v"]="${!v}"
done

# 2. Load conf
COMMIT_MESSAGES=()
[ -f "$CONF" ] && { # shellcheck disable=SC1090
    source "$CONF"
}

# 3. Re-apply env-set overrides on top of conf
for k in "${!_env_set[@]}"; do
    eval "$k=\${_env_set[\"$k\"]}"
done

# 4. CLI flag override is highest priority
[ -n "$COMMITS_OVERRIDE" ] && COMMITS_PER_RUN="$COMMITS_OVERRIDE"

# 5. Final defaults if nothing else set them
COMMITS_PER_RUN="${COMMITS_PER_RUN:-1}"
INTER_COMMIT_DELAY="${INTER_COMMIT_DELAY:-20-180}"
START_JITTER_SECS="${START_JITTER_SECS:-0}"
SKIP_DAYS="${SKIP_DAYS:-}"
ALLOW_HOURS="${ALLOW_HOURS:-}"
DAILY_CAP="${DAILY_CAP:-0}"

if [ "${#COMMIT_MESSAGES[@]}" -eq 0 ]; then
    COMMIT_MESSAGES=(
        "Daily activity log" "Auto-bump counter" "Routine sync"
        "Scheduled tick" "Daily commit" "Activity update"
    )
fi
unset _env_set v k

# ---- Helpers ------------------------------------------------------------
# Resolve "N" or "MIN-MAX" to a single integer (random if range)
resolve_range() {
    local val="${1:-0}"
    if [[ "$val" =~ ^[0-9]+$ ]]; then
        echo "$val"
    elif [[ "$val" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local lo="${BASH_REMATCH[1]}" hi="${BASH_REMATCH[2]}"
        if [ "$hi" -le "$lo" ]; then echo "$lo"
        else echo $((lo + RANDOM % (hi - lo + 1))); fi
    else
        echo 0
    fi
}

# ---- Lock --------------------------------------------------------------
exec 9>"$LOCK"
flock -n 9 || { echo "another auto-commit run holds the lock; exiting"; exit 0; }

cd "$REPO_DIR"
[ -d .git ] || { echo "not a git repo: $REPO_DIR" >&2; exit 1; }
[ -f "$README" ] || { echo "missing $README" >&2; exit 1; }
[ -f "$LOG" ]    || { echo "missing $LOG" >&2; exit 1; }

# ---- Identity ----------------------------------------------------------
AUTHOR_NAME="${AUTHOR_NAME:-$(git config user.name 2>/dev/null || echo)}"
AUTHOR_EMAIL="${AUTHOR_EMAIL:-$(git config user.email 2>/dev/null || echo)}"
if [ -z "$AUTHOR_NAME" ] || [ -z "$AUTHOR_EMAIL" ]; then
    echo "AUTHOR_NAME and AUTHOR_EMAIL must be set (env or git config)" >&2
    exit 1
fi
git config user.name  "$AUTHOR_NAME"
git config user.email "$AUTHOR_EMAIL"

# ---- Skip-day / allow-hour gates --------------------------------------
NOW_DOW="$(date -u +%a | tr 'A-Z' 'a-z')"
NOW_H="$(date -u +%-H)"
TODAY="$(date -u +%Y-%m-%d)"

if [ -n "$SKIP_DAYS" ]; then
    IFS=',' read -ra _skip <<<"$SKIP_DAYS"
    for d in "${_skip[@]}"; do
        d="$(echo "$d" | tr 'A-Z' 'a-z' | xargs)"
        if [ "$d" = "$NOW_DOW" ]; then
            echo "skip: today is $NOW_DOW (in SKIP_DAYS=$SKIP_DAYS)"
            exit 0
        fi
    done
fi

if [ -n "$ALLOW_HOURS" ] && [[ "$ALLOW_HOURS" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    h_lo="${BASH_REMATCH[1]}"
    h_hi="${BASH_REMATCH[2]}"
    if [ "$NOW_H" -lt "$h_lo" ] || [ "$NOW_H" -gt "$h_hi" ]; then
        echo "skip: hour $NOW_H UTC outside ALLOW_HOURS=$ALLOW_HOURS"
        exit 0
    fi
fi

# ---- Daily cap check --------------------------------------------------
count_today_commits() {
    git log --since="${TODAY}T00:00:00Z" --until="${TODAY}T23:59:59Z" \
        --format=%H --author="$AUTHOR_EMAIL" 2>/dev/null | wc -l
}

if [ "${DAILY_CAP:-0}" != "0" ]; then
    today_count="$(count_today_commits)"
    if [ "$today_count" -ge "$DAILY_CAP" ]; then
        echo "skip: daily cap reached ($today_count >= $DAILY_CAP)"
        exit 0
    fi
fi

# ---- Pull latest before mutating --------------------------------------
DEFAULT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo main)"
if ! "$DRY_RUN" && git remote get-url origin >/dev/null 2>&1; then
    git fetch --quiet origin || true
    if git rev-parse --verify --quiet "origin/$DEFAULT_BRANCH" >/dev/null; then
        # Only the files we'll mutate need to be clean for the rebase.
        if ! git diff-index --quiet HEAD -- README.md commit-log.md; then
            echo "README.md or commit-log.md has uncommitted changes; refusing to pull/rebase" >&2
            git status --short README.md commit-log.md >&2
            exit 1
        fi
        git pull --quiet --rebase --autostash origin "$DEFAULT_BRANCH" || {
            echo "pull failed; aborting" >&2
            exit 1
        }
    fi
fi

# ---- Resolve cadence numbers ------------------------------------------
N_COMMITS="$(resolve_range "$COMMITS_PER_RUN")"
[ "$N_COMMITS" -lt 1 ] && N_COMMITS=1

# Honor remaining headroom under DAILY_CAP
if [ "${DAILY_CAP:-0}" != "0" ]; then
    today_count="$(count_today_commits)"
    headroom=$((DAILY_CAP - today_count))
    if [ "$N_COMMITS" -gt "$headroom" ]; then
        echo "trimming commits this run: $N_COMMITS -> $headroom (DAILY_CAP=$DAILY_CAP)"
        N_COMMITS="$headroom"
    fi
fi

[ "$N_COMMITS" -lt 1 ] && { echo "nothing to do (cap or zero)"; exit 0; }

# ---- Optional start jitter -------------------------------------------
if ! "$NO_JITTER" && [ "${START_JITTER_SECS:-0}" != "0" ]; then
    j="$(resolve_range "$START_JITTER_SECS")"
    if [ "$j" -gt 0 ]; then
        echo "start jitter: sleeping ${j}s"
        "$DRY_RUN" || sleep "$j"
    fi
fi

# ---- Streak (UTC days, before the new commits land) ------------------
DAYS_WITH_COMMITS="$(
    git log --format=%cI 2>/dev/null | while IFS= read -r iso; do
        [ -n "$iso" ] && date -u -d "$iso" +%Y-%m-%d 2>/dev/null
    done | sort -u
)"
STREAK=1
day="$TODAY"
while true; do
    prev="$(date -u -d "$day -1 day" +%Y-%m-%d 2>/dev/null \
            || date -u -v-1d -j -f '%Y-%m-%d' "$day" +%Y-%m-%d 2>/dev/null)"
    [ -z "$prev" ] && break
    if echo "$DAYS_WITH_COMMITS" | grep -qx "$prev"; then
        STREAK=$((STREAK + 1)); day="$prev"
    else
        break
    fi
done

# ---- One-commit operation (called N times) ---------------------------
make_one_commit() {
    local count next now msg tmp
    count="$(grep -oE 'Count Commits:[[:space:]]*[0-9]+' "$README" \
              | grep -oE '[0-9]+$' || echo 0)"
    next=$((count + 1))
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    msg="${COMMIT_MESSAGES[RANDOM % ${#COMMIT_MESSAGES[@]}]} #$next"

    if "$DRY_RUN"; then
        printf "  [dry] %d -> %d  %s\n" "$count" "$next" "$msg"
        return
    fi

    tmp="$(mktemp)"
    awk -v c="$next" -v t="$now" -v m="$msg" -v s="$STREAK" '
        /^Count Commits:/ { print "Count Commits: " c; next }
        /^Last Update:/   { print "Last Update:   " t; next }
        /^Last Message:/  { print "Last Message:  " m; next }
        /^Streak Day:/    { print "Streak Day:    " s; next }
        { print }
    ' "$README" > "$tmp" && mv "$tmp" "$README"

    awk -v n="$next" -v t="$now" -v m="$msg" '
        !ins && /^\|---/ { print; print "| " n " | " t " | " m " |"; ins=1; next }
        { print }
    ' "$LOG" > "$tmp" && mv "$tmp" "$LOG"

    git add README.md commit-log.md
    if "$FORCE" || ! git diff --cached --quiet; then
        git commit --quiet -m "$msg"
        if "$NO_PUSH"; then
            echo "  committed (no push): $msg"
        else
            git push --quiet origin "$DEFAULT_BRANCH"
            echo "  pushed: $msg"
        fi
    else
        echo "  no changes (skip)"
    fi
}

# ---- Run ------------------------------------------------------------
echo "auto-commit: $N_COMMITS commit(s) this run, streak entering at $STREAK"

if "$DRY_RUN"; then
    echo "DRY RUN — would make $N_COMMITS commit(s):"
fi

for i in $(seq 1 "$N_COMMITS"); do
    make_one_commit
    if [ "$i" -lt "$N_COMMITS" ]; then
        d="$(resolve_range "$INTER_COMMIT_DELAY")"
        echo "  ...sleeping ${d}s before next commit ($i/$N_COMMITS done)"
        "$DRY_RUN" || sleep "$d"
    fi
done

if ! "$DRY_RUN"; then
    final_count="$(count_today_commits)"
    echo "done. $N_COMMITS commit(s) this run; $final_count total today."
fi
