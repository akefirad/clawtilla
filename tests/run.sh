#!/usr/bin/env bash
# Clawtilla verification orchestrator.
#
# Phases (run in order):
#   static   — parse compose/Dockerfile/hcl/scripts; no docker run needed
#   build    — docker compose build both images
#   runtime  — bring the stack up and exercise it end-to-end
#
# Collision safety: the harness runs under a fixed, test-scoped project name
# (PROJECT, default clawtilla-verify) and stamps every resource it creates with
# an ownership label. Before bring-up it demands a CLEAN SLATE: a same-named
# project it did NOT create (no label) is refused outright; its own leftover is
# refused unless --down authorizes wiping it. By default it tears the stack down
# after runtime (clean in, clean out); --keep retains it for inspection.
#
# Usage:
#   ./run.sh                 # static + build + runtime (full suite); tears down at end
#   ./run.sh static          # one phase
#   ./run.sh static runtime  # several phases
#   ./run.sh --list          # list all test scripts
#   ./run.sh --manual-approve runtime   # require human enrollment approval
#   ./run.sh --keep          # leave the stack running after runtime (skip teardown)
#   ./run.sh --down          # wipe a pre-existing harness stack at startup, then run
#   ./run.sh --teardown      # just tear the harness stack down and exit (== make down)
#
# Exit code is non-zero if any check failed.
set -uo pipefail
VERIFY_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$VERIFY_DIR/lib/common.sh"
. "$VERIFY_DIR/lib/docker.sh"

MANUAL=""; KEEP=0; WIPE=0
PHASES=""
for a in "$@"; do
  case "$a" in
    --manual-approve) MANUAL="--manual-approve" ;;
    --down)  WIPE=1 ;;
    --keep)  KEEP=1 ;;
    --teardown) PHASES="__teardown__" ;;
    --list)  PHASES="__list__" ;;
    static|build|runtime) PHASES="$PHASES $a" ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) die "unknown arg: $a (try --help)" ;;
  esac
done
[ -n "${PHASES// /}" ] || PHASES="static build runtime"

if [ "$PHASES" = "__teardown__" ]; then
  require_tools docker
  info "tearing down verification project '$PROJECT' ..."
  safe_down
  exit 0
fi

scripts_for() {  # phase
  find "$VERIFY_DIR/$1" -maxdepth 1 -name '*.sh' 2>/dev/null | sort
}

if [ "$PHASES" = "__list__" ]; then
  for p in static build runtime; do
    section "$p"
    scripts_for "$p" | sed "s#$VERIFY_DIR/##"
  done
  exit 0
fi

require_tools docker

# --- per-execution logging --------------------------------------------------
# One fresh log file + result ledger per run, under verify/logs (never outside).
# Old logs are kept in place — nothing here deletes them.
RUN_ID="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/verify-$RUN_ID.log"
export RESULTS_TSV="$LOG_DIR/results-$RUN_ID.tsv"
export LOG_DIR
: >"$RESULTS_TSV"
# Mirror everything (this script + all child scripts) to the run log.
if have tee; then exec > >(tee -a "$LOG_FILE") 2>&1; fi
info "run id: $RUN_ID"
info "log:    $LOG_FILE"

OVERALL=0
run_phase() {  # phase  [extra-args...]
  local phase="$1"; shift
  local s
  printf '\n%s########## PHASE: %s ##########%s\n' "$C_BLD" "$phase" "$C_RST"
  for s in $(scripts_for "$phase"); do
    printf '\n%s>>> %s%s\n' "$C_BLU" "$(basename "$s")" "$C_RST"
    bash "$s" "$@" || OVERALL=1
  done
}

for p in $PHASES; do
  case "$p" in
    static)  run_phase static ;;
    build)   run_phase build ;;
    runtime) preflight_clean_slate "$WIPE"
             run_phase runtime "$MANUAL"
             if [ "$KEEP" = "1" ]; then
               info "stack left running (--keep). Tear down with: make down (or ./run.sh --teardown)"
             else
               info "tearing the stack down (default; pass --keep to retain) ..."
               safe_down >/dev/null 2>&1 || true
             fi ;;
  esac
done

# --- aggregate report -------------------------------------------------------
section "AGGREGATE RESULTS"
if [ -s "$RESULTS_TSV" ]; then
  total=$(wc -l <"$RESULTS_TSV" | tr -d ' ')
  # grep -c prints "0" *and* exits 1 on no matches; keep the count, not the exit.
  np=$(grep -c '^PASS' "$RESULTS_TSV" 2>/dev/null) || np=0
  nf=$(grep -c '^FAIL' "$RESULTS_TSV" 2>/dev/null) || nf=0
  ns=$(grep -c '^SKIP' "$RESULTS_TSV" 2>/dev/null) || ns=0
  nx=$(grep -c '^XFAIL' "$RESULTS_TSV" 2>/dev/null) || nx=0
  printf '  total %s   %sPASS %s%s   %sFAIL %s%s   %sSKIP %s%s   %sXFAIL %s%s\n' \
    "$total" "$C_GRN" "$np" "$C_RST" "$C_RED" "$nf" "$C_RST" "$C_YEL" "$ns" "$C_RST" "$C_YEL" "$nx" "$C_RST"
  if [ "$nf" -gt 0 ]; then
    printf '\n%sFailures:%s\n' "$C_RED" "$C_RST"
    grep '^FAIL' "$RESULTS_TSV" | awk -F'\t' '{printf "  [%s] %s  (%s)  %s\n",$2,$3,$4,$5}'
  fi
  if [ "$nx" -gt 0 ]; then
    printf '\n%sKnown gaps (XFAIL — reported, do not fail the run):%s\n' "$C_YEL" "$C_RST"
    grep '^XFAIL' "$RESULTS_TSV" | awk -F'\t' '{printf "  [%s] %s  (%s)  %s\n",$2,$3,$4,$5}'
  fi
  printf '\nLedger: %s\n' "$RESULTS_TSV"
  printf 'Log:    %s\n' "$LOG_FILE"
fi

exit "$OVERALL"
