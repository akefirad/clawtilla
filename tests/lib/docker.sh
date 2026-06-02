# shellcheck shell=bash
# Clawtilla verification — docker / compose helpers.
# Requires common.sh to be sourced first (for COMPOSE_FILE, PROJECT, svc names).

# Run docker compose against the verification project/file. The explicit
# `-p "$PROJECT"` pins every command to the test-scoped namespace, so the
# harness never touches a real deployment of the same stack (the compose
# file's own `name:` is overridden by -p, which takes precedence). The test
# stack's random dashboard port comes from the stack's own
# CLAWTILLA_DASH_PORT env knob (exported by runtime/00_bringup.sh).
# The verify.override.yaml overlay (when present) stamps an ownership label on
# every resource so the harness can prove the project is its own before reusing
# or destroying it (see the guard helpers below).
dc() {
  if [ -n "${OVERRIDE_FILE:-}" ] && [ -f "${OVERRIDE_FILE:-}" ]; then
    docker compose -p "$PROJECT" -f "$COMPOSE_FILE" -f "$OVERRIDE_FILE" "$@"
  else
    docker compose -p "$PROJECT" -f "$COMPOSE_FILE" "$@"
  fi
}

# --- ownership / collision guard -------------------------------------------
# Name-based namespacing (PROJECT) can't tell OUR leftover stack apart from a
# real deployment that happens to share the name. So everything the harness
# creates is stamped with HARNESS_LABEL (via verify.override.yaml); a same-named
# project whose resources LACK it is "foreign" and is NEVER adopted or wiped.
HARNESS_LABEL="com.akefirad.clawtilla.harness=verify"
_PROJECT_LABEL="com.docker.compose.project=$PROJECT"

# Total resources (containers + volumes + networks) matching the given label
# filters (ANDed). Resilient to docker being unreachable (counts as 0).
_resource_count() {  # label-filter...
  local args=() f c v n
  for f in "$@"; do args+=(--filter "label=$f"); done
  c=$(docker ps -aq "${args[@]}" 2>/dev/null | grep -c . || true)
  v=$(docker volume ls -q "${args[@]}" 2>/dev/null | grep -c . || true)
  n=$(docker network ls -q "${args[@]}" 2>/dev/null | grep -c . || true)
  echo $(( c + v + n ))
}

# All resources Docker attributes to this compose project (ours OR foreign).
project_total() { _resource_count "$_PROJECT_LABEL"; }
# The subset we can PROVE the harness created (carries the ownership label).
project_ours()  { _resource_count "$_PROJECT_LABEL" "$HARNESS_LABEL"; }
# Foreign: a project of this name exists with resources we can't prove are ours.
project_has_foreign() { [ "$(project_total)" -gt "$(project_ours)" ]; }

# Refuse to proceed unless the project namespace is a clean slate. A foreign
# same-named project is fatal regardless of flags; our own leftover is fatal
# unless $1 ("may wipe", from --down) authorizes wiping it first.
preflight_clean_slate() {  # may_wipe(0|1)
  local may_wipe="${1:-0}"
  if project_has_foreign; then
    die "a Docker Compose project named '$PROJECT' already exists that this harness did NOT create (its resources lack the '$HARNESS_LABEL' label). Refusing to reuse or destroy it. If that is a real deployment, run the harness under a different name: PROJECT=clawtilla-verify-$$ bash run.sh"
  fi
  local total; total="$(project_total)"
  if [ "$total" -gt 0 ]; then
    if [ "$may_wipe" = "1" ]; then
      info "existing verification stack found under '$PROJECT' ($total resources); --down given — wiping for a clean slate ..."
      safe_down >/dev/null 2>&1 || true
    else
      die "a previous verification stack exists under project '$PROJECT' ($total resources). The harness expects a clean slate. Re-run with --down to wipe it first, or 'make down'."
    fi
  fi
}

# Destructive teardown that refuses to reap a project it didn't create.
safe_down() {
  if project_has_foreign; then
    die "refusing 'down -v' on project '$PROJECT': it holds resources not created by this harness (missing '$HARNESS_LABEL'). Remove it manually if you are certain."
  fi
  dc down -v
  rm -f "$LOG_DIR/.dash_port" 2>/dev/null || true
}

# Container id for a compose service (empty if not running).
cid() { dc ps -q "$1" 2>/dev/null; }

# Is a service running?
svc_running() {
  local id; id="$(cid "$1")"
  [ -n "$id" ] && [ "$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null)" = "true" ]
}

# docker inspect a service container with a Go-template format.
inspect() {  # service  go-template
  local id; id="$(cid "$1")" || return 1
  [ -n "$id" ] || return 1
  docker inspect -f "$2" "$id"
}

# Exec a shell command inside a service (no TTY). Stdout/stderr pass through.
xsh() {  # service  cmd...
  local svc="$1"; shift
  dc exec -T "$svc" sh -c "$*"
}

# Exec inside a service via the baked `run` wrapper (eval clawpatrol env; exec).
xrun() {  # service  cmd...
  local svc="$1"; shift
  dc exec -T "$svc" run "$@"
}

# HTTP status of a curl issued from inside a TBot (via the run wrapper).
# Retries ONLY on transient connection failures (code 000 / empty) — the
# client<->gateway link can flap — but returns a real HTTP status (2xx/4xx/5xx)
# immediately, so policy assertions (e.g. expecting 403) stay exact.
tbot_http_code() {  # svc  curl-args...
  local svc="$1"; shift
  local code="" i=0
  while [ "$i" -lt "$RETRY_ATTEMPTS" ]; do
    code="$(dc exec -T "$svc" run curl -s -o /dev/null -w '%{http_code}' \
              --max-time "$CURL_MAX_TIME" "$@" 2>/dev/null)"
    case "$code" in
      000|"") ;;                       # could not connect -> retry
      *) printf '%s' "$code"; return 0 ;;
    esac
    i=$((i+1)); [ "$i" -lt "$RETRY_ATTEMPTS" ] && sleep "$RETRY_DELAY"
  done
  printf '%s' "${code:-000}"
}

# Response BODY of a curl from inside a TBot (via the run wrapper), retried until
# non-empty (or attempts exhausted). For reflected-header / JSON checks.
tbot_body() {  # svc  curl-args...
  local svc="$1"; shift
  local out="" i=0
  while [ "$i" -lt "$RETRY_ATTEMPTS" ]; do
    out="$(dc exec -T "$svc" run curl -s --max-time "$CURL_MAX_TIME" "$@" 2>/dev/null)"
    [ -n "$out" ] && { printf '%s' "$out"; return 0; }
    i=$((i+1)); [ "$i" -lt "$RETRY_ATTEMPTS" ] && sleep "$RETRY_DELAY"
  done
  printf '%s' "$out"; return 1
}

# Resolve the real docker network name for a compose network (e.g. clawcage-net).
# Strictly project-scoped: we only ever match "<PROJECT>_<shortname>" exactly, so
# a co-resident deployment of the same stack (e.g. a real `clawtilla` stack
# with an identically-suffixed clawtilla_clawcage-net) can NEVER be selected here
# — that network must not get an ephemeral probe attached to it.
net_name() {  # compose-network-shortname
  local want="${PROJECT}_$1" n
  n="$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -Fx "$want" | head -1)"
  [ -n "$n" ] && { echo "$n"; return 0; }
  echo "$want"
}

# Image used by a running service container (for ephemeral probes on its image).
svc_image() { inspect "$1" '{{.Image}}'; }

# Image id produced by `docker compose build` for a service, WITHOUT requiring a
# created container. compose tags locally-built images as <project>-<service>;
# `compose images` only lists images for existing containers (empty right after
# a build), so query the image tag directly and fall back to `compose images`.
built_image_id() {  # service
  local svc="$1" id
  id="$(docker images -q "${PROJECT}-${svc}" 2>/dev/null | head -1)"
  [ -n "$id" ] || id="$(dc images -q "$svc" 2>/dev/null | head -1)"
  printf '%s' "$id"
}

# The TBot's WireGuard IP (10.55.0.x), or empty.
tbot_wg_ip() {
  xsh "$TBOT_SVC" "ip -4 -o addr show clawpatrol 2>/dev/null | awk '{print \$4}' | cut -d/ -f1" 2>/dev/null
}

# Poll <cmd> until it succeeds or <timeout> seconds elapse. Returns 0/1.
wait_for() {  # timeout-seconds  cmd...
  local t="$1"; shift
  local i=0
  while [ "$i" -lt "$t" ]; do
    if eval "$*" >/dev/null 2>&1; then return 0; fi
    i=$((i+1)); sleep 1
  done
  return 1
}
