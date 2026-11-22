#!/bin/bash
#
# Certify the rebuild: run the README's "Rebuild from nothing" in a fresh
# Ubuntu container that has never seen this repo, then check the outcome.
#
# Runs on the host, which needs docker and git. Nothing here touches the
# machine it runs on apart from pulling an image and writing a log.
#
# Usage:
#   ./certification/certify.sh                  # certify main
#   ./certification/certify.sh --branch <name>  # certify a pushed branch, before it merges
#   ./certification/certify.sh --keep           # leave the container for inspection
#
# The container clones the repo from GitHub, so a branch has to be pushed. The
# transcript goes to certification/logs/, and ends with the commit the
# container built. Put that commit and the verdict in the pull request.
#
# THE DEVIATIONS
#
# The point is to run what the README says, not a convenient variant, so every
# deviation is named. All are forced by the container except the last:
#
#   1. A user is made first.  The image has only root, and no sudo. A fresh
#                      Ubuntu install has a user who can sudo, which is who
#                      the README is written for. The user gets passwordless
#                      sudo because nobody is there to type a password.
#   2. --promptString  Nobody is there to answer chezmoi's one question, so
#                      the host name is given up front.
#   3. --branch <name> Only in a run started with --branch. The README's
#                      command clones main; this makes chezmoi clone the named
#                      branch, so a change can be certified before it merges.
#
# WHAT A PASS DOES NOT COVER
#
#   - No systemd. The host name, snap, sshd reload and firewall steps skip
#     themselves.
#   - No desktop session. The terminal font, dock and mouse scripts cannot do
#     their work.
#   - One architecture. The container has the host's: arm64 on an Apple
#     silicon Mac, where the amd64-only packages (1Password, Chrome, Slack) are
#     not installed, and amd64 on rama. The log names it.
#
# THE VERDICT
#
# CERTIFIED needs all of: `chezmoi init --apply` exited 0, `chezmoi status`
# afterwards ran and printed nothing, and the commit the container built is the
# one GitHub named before the container started. It does not check outcomes
# beyond that, such as whether a runtime resolves.

set -euo pipefail

REPO="${CERT_REPO:-jcouball/rama-config}"
IMAGE="${CERT_IMAGE:-ubuntu:26.04}"
CERT_USER="${CERT_USER:-certuser}"
HOST_NAME="${CERT_HOST_NAME:-rama}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"

KEEP=0
BRANCH=""
BRANCH_GIVEN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1 ;;
    --branch)
      [ $# -ge 2 ] || { echo "--branch needs a branch name" >&2; exit 64; }
      BRANCH="$2"
      BRANCH_GIVEN=1
      shift
      ;;
    --help|-h)
      # The header comment: every line from the second up to the first that is
      # not a comment.
      awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

log()  { printf '\n\033[1m>> %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m❌ %s\033[0m\n' "$*" >&2; exit 1; }

# The branch name is pasted into a command that runs in the container, so only
# the characters a branch name can have are let in. The class is written out
# and the locale pinned so the test means the same under any bash and any
# locale. Checked whenever --branch was given: an empty name, as from an unset
# variable, must not be read as "no option" and certify main.
valid_branch_name() {
  local LC_ALL=C
  local pattern='^[A-Za-z0-9_][A-Za-z0-9_./-]*$'
  [[ "$1" =~ $pattern ]]
}

if [ "$BRANCH_GIVEN" -eq 1 ] && ! valid_branch_name "$BRANCH"; then
  echo "Not a branch name: '$BRANCH'" >&2
  exit 64
fi

# --branch main is a run of main: same clone command, same log file name.
[ "$BRANCH" = "main" ] && BRANCH=""
TARGET_BRANCH="${BRANCH:-main}"
# A slash is the only character the pattern allows that a file name cannot hold.
LOG_SUFFIX="${BRANCH:+-${BRANCH//\//-}}"

# --- Preflight -------------------------------------------------------------

command -v git >/dev/null 2>&1 || die "git not found."
command -v docker >/dev/null 2>&1 || die "docker not found."
docker info >/dev/null 2>&1 \
  || die "docker is installed but its daemon does not answer. Start it and run this again."

# What the container is about to build, asked of GitHub before anything
# starts.
#
# The ref is spelled out in full, because a bare name given to ls-remote also
# matches refs/heads/x/<name>. That is still not exact: ls-remote matches the
# end of a ref, so refs/heads/<name> also returns a branch that is itself named
# x/refs/heads/<name>, and lists it first. So the answer is filtered for the
# one line whose ref is exactly the one asked for.
REPO_URL="https://github.com/$REPO.git"
log "Asking GitHub what $TARGET_BRANCH is in $REPO..."
REMOTE_REFS="$(git ls-remote "$REPO_URL" "refs/heads/$TARGET_BRANCH")" \
  || die "Could not read the branches of $REPO_URL."
# shellcheck disable=SC2016  # awk's $1 and $2 are awk's, not the shell's.
EXPECTED_COMMIT="$(printf '%s\n' "$REMOTE_REFS" \
  | awk -v ref="refs/heads/$TARGET_BRANCH" '$2 == ref { print $1 }')"
[ -n "$EXPECTED_COMMIT" ] \
  || die "Branch '$TARGET_BRANCH' is not on GitHub in $REPO. Push it first: the container clones from GitHub."
echo "   $TARGET_BRANCH is at $EXPECTED_COMMIT" >&2

mkdir -p "$LOG_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOG_DIR/certify-$STAMP$LOG_SUFFIX.log"
CONTAINER="rama-cert-$STAMP"

# A line for the terminal and for the log.
note() { printf '%s\n' "$*" | tee -a "$LOG" >&2; }

# --- The container ---------------------------------------------------------

CREATED=0
# shellcheck disable=SC2329  # Called by the EXIT trap below.
cleanup() {
  if [ "$CREATED" -eq 1 ] && [ "$KEEP" -eq 0 ]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

log "Pulling $IMAGE..."
docker pull -q "$IMAGE" >/dev/null || die "Could not pull $IMAGE."

log "Starting a fresh container, $CONTAINER..."
docker run -d --name "$CONTAINER" "$IMAGE" sleep infinity >/dev/null \
  || die "Could not start a container from $IMAGE."
CREATED=1

# Run a command in the container as the certification user, through a login
# shell. `su -` gives it what a terminal session has and `docker exec -u` does
# not: HOME, USER, LOGNAME and the login PATH.
in_guest() { docker exec "$CONTAINER" su - "$CERT_USER" -c "$1"; }

log "Transcript: $LOG"
note "== Certifying $REPO, branch $TARGET_BRANCH =="
note "Expected commit: $EXPECTED_COMMIT"
note "Image:           $IMAGE ($(docker image inspect --format '{{.Id}}' "$IMAGE"))"
note "Architecture:    $(docker exec "$CONTAINER" uname -m)"
note "Host:            $(uname -s) $(uname -m)"
note ""

# Deviation 1: the user a fresh install would already have.
log "Making the user $CERT_USER..."
docker exec "$CONTAINER" bash -c "
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q sudo
  useradd --create-home --shell /bin/bash '$CERT_USER'
  echo '$CERT_USER ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/'$CERT_USER'
  chmod 440 /etc/sudoers.d/'$CERT_USER'
" >>"$LOG" 2>&1 || die "Could not make the user $CERT_USER in the container. See $LOG"

# --- Run the bootstrap -----------------------------------------------------

BRANCH_OPTION="${BRANCH:+--branch $BRANCH }"

# The two steps of "Rebuild from nothing", verbatim, plus deviations 2 and 3.
# Do not "improve" them here -- the point is to test what the README says.
#
# Written to a file and run as a file. Piped to a shell, the first command
# that read stdin would eat the rest of the script.
BOOTSTRAP_FILE="$(mktemp)"
# shellcheck disable=SC2016  # $(...) must stay unexpanded: it runs in the container.
printf '%s\n' 'set -e
# 1. What the next command needs.
sudo apt-get update && sudo apt-get install -y curl git

# 2. Everything else.
sudo -v && sh -c "$(curl -fsLS get.chezmoi.io)" -- -b /tmp/chezmoi-bootstrap \
  init --apply --promptString "Host name='"$HOST_NAME"'" '"$BRANCH_OPTION$REPO" >"$BOOTSTRAP_FILE"
docker cp -q "$BOOTSTRAP_FILE" "$CONTAINER:/tmp/bootstrap.sh" \
  || die "Could not copy the bootstrap commands into the container."
rm -f "$BOOTSTRAP_FILE"
docker exec "$CONTAINER" chmod 644 /tmp/bootstrap.sh

log "Running the bootstrap..."
note "== The commands =="
note "$(docker exec "$CONTAINER" cat /tmp/bootstrap.sh)"
note ""
note "== The bootstrap =="

# set +e: the pipeline is expected to fail when the bootstrap fails, and with
# set -e plus pipefail that would end the script here, before any verdict.
set +e
in_guest 'bash /tmp/bootstrap.sh' 2>&1 | tee -a "$LOG"
INIT_STATUS=${PIPESTATUS[0]}
set -e

# --- The verdict -----------------------------------------------------------

PROBLEMS=""
problem() { PROBLEMS="$PROBLEMS   - $*"$'\n'; }

[ "$INIT_STATUS" -eq 0 ] || problem "chezmoi init --apply exited $INIT_STATUS."

# Name what was built. The commit GitHub gave before the start is only what
# the container was expected to clone: a push during the run changes what it
# gets, and without this comparison that would show nowhere.
BUILT="$(in_guest 'git -C ~/.local/share/chezmoi rev-parse HEAD "HEAD^{tree}"' 2>/dev/null || true)"
BUILT_COMMIT="$(printf '%s\n' "$BUILT" | sed -n '1p')"
BUILT_TREE="$(printf '%s\n' "$BUILT" | sed -n '2p')"
SHA_PATTERN='^[0-9a-f]{40}$'

note ""
note "== What this run built =="
note "Repo:         $REPO"
note "Branch:       $TARGET_BRANCH"
if [[ "$BUILT_COMMIT" =~ $SHA_PATTERN ]] && [[ "$BUILT_TREE" =~ $SHA_PATTERN ]]; then
  note "Commit:       $BUILT_COMMIT"
  note "Tree:         $BUILT_TREE"
  [ "$BUILT_COMMIT" = "$EXPECTED_COMMIT" ] \
    || problem "The container built $BUILT_COMMIT, but $TARGET_BRANCH was at $EXPECTED_COMMIT on GitHub when the run started. The branch moved during the run."
else
  problem "The commit the container built could not be read. The bootstrap may have failed before the clone."
fi
note "Architecture: $(docker exec "$CONTAINER" uname -m)"

# An exit status alone proves little, so ask chezmoi whether anything is left
# to do. A script that failed, or a file that differs, shows here. The status
# is taken straight from the command, not through a pipe, so a chezmoi that is
# missing or fails cannot pass as "nothing to report".
note ""
note "== chezmoi status =="
set +e
STATUS_OUTPUT="$(in_guest '/tmp/chezmoi-bootstrap/chezmoi status' 2>&1)"
STATUS_EXIT=$?
set -e
[ -z "$STATUS_OUTPUT" ] || note "$STATUS_OUTPUT"
if [ "$STATUS_EXIT" -ne 0 ]; then
  problem "chezmoi status could not be run (exit $STATUS_EXIT)."
elif [ -n "$STATUS_OUTPUT" ]; then
  problem "chezmoi status is not empty: something is still to be applied."
else
  note "(empty)"
fi

note ""
if [ -z "$PROBLEMS" ]; then
  VERDICT=0
  note "CERTIFIED -- $REPO at ${BUILT_COMMIT} rebuilt from nothing in a container."
  printf '\033[32m✅ CERTIFIED\033[0m\n' >&2
else
  VERDICT=1
  note "NOT CERTIFIED"
  note "$PROBLEMS"
  printf '\033[31m❌ NOT CERTIFIED\033[0m -- see %s\n' "$LOG" >&2
fi

if [ "$KEEP" -eq 1 ]; then
  cat >&2 <<KEPT

The container is left running so you can inspect it:

  docker exec -it $CONTAINER su - $CERT_USER
  docker rm -f $CONTAINER      # when you are done
KEPT
fi

exit "$VERDICT"
