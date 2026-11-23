#!/bin/bash
#
# Certify the rebuild: run the README's "Rebuild from nothing" in a fresh
# Ubuntu container that has never seen this repo, then verify the outcome with
# verify.sh.
#
# Runs on the host, which needs docker and git. Nothing here touches the
# machine it runs on apart from pulling an image and writing a log.
#
# Usage:
#   ./certification/certify.sh                  # certify main
#   ./certification/certify.sh --branch <name>  # certify a pushed branch, before it merges
#   ./certification/certify.sh --keep           # leave the container for inspection
#   ./certification/certify.sh --verify-only    # re-run the checks in a kept container;
#                                               # reports the checks, never certifies
#
# The container clones the repo from GitHub, so a branch has to be pushed.
# verify.sh comes from this checkout, so for a branch run the checkout has to
# be at the branch's commit. The transcripts go to certification/logs/, and the
# bootstrap log ends with the commit the container built. Put that commit and
# the verdict in the pull request.
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
#   - No udevd. Script 08 writes its udev rule and skips loading it.
#   - No desktop session. The terminal font, dock and mouse scripts skip
#     themselves.
#   - One architecture. The container has the host's: arm64 on an Apple
#     silicon Mac, where the amd64-only packages (1Password, Chrome, Slack) are
#     not installed, and amd64 on rama. The log names it.
#
# THE VERDICT
#
# CERTIFIED needs both of: the last line verify.sh printed is its completion
# record and that record counts no failed check, and the commit the container
# built is the one GitHub named before the container started. The exit status of the bootstrap is reported and decides
# nothing: verify.sh runs whatever it was, because a script that exits 0 has
# proved nothing and a machine is judged by what is on it.

set -euo pipefail

REPO="${CERT_REPO:-jcouball/ubuntu-dev-config}"
IMAGE="${CERT_IMAGE:-ubuntu:26.04}"
CERT_USER="${CERT_USER:-certuser}"
HOST_NAME="${CERT_HOST_NAME:-rama}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"

KEEP=0
VERIFY_ONLY=0
BRANCH=""
BRANCH_GIVEN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1 ;;
    --verify-only) VERIFY_ONLY=1 ;;
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
warn() { printf '\033[33m!! %s\033[0m\n' "$*" >&2; }
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

REPO_URL="https://github.com/$REPO.git"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXPECTED_COMMIT=""

if [ "$VERIFY_ONLY" -eq 0 ]; then
  # What the container is about to build, asked of GitHub before anything
  # starts.
  #
  # The ref is spelled out in full, because a bare name given to ls-remote also
  # matches refs/heads/x/<name>. That is still not exact: ls-remote matches the
  # end of a ref, so refs/heads/<name> also returns a branch that is itself
  # named x/refs/heads/<name>, and lists it first. So the answer is filtered
  # for the one line whose ref is exactly the one asked for.
  log "Asking GitHub what $TARGET_BRANCH is in $REPO..."
  REMOTE_REFS="$(git ls-remote "$REPO_URL" "refs/heads/$TARGET_BRANCH")" \
    || die "Could not read the branches of $REPO_URL."
  # shellcheck disable=SC2016  # awk's $1 and $2 are awk's, not the shell's.
  EXPECTED_COMMIT="$(printf '%s\n' "$REMOTE_REFS" \
    | awk -v ref="refs/heads/$TARGET_BRANCH" '$2 == ref { print $1 }')"
  [ -n "$EXPECTED_COMMIT" ] \
    || die "Branch '$TARGET_BRANCH' is not on GitHub in $REPO. Push it first: the container clones from GitHub."
  echo "   $TARGET_BRANCH is at $EXPECTED_COMMIT" >&2

  # The container clones $REPO from GitHub, and verify.sh is copied in from
  # this checkout. If the two are at different revisions, one revision's files
  # are tested against another revision's checks. A branch run stops on that.
  # A run of main only warns, because the run of main that certifies a change
  # to these scripts is made from that change's branch, before it merges.
  LOCAL_HEAD="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  VERIFY_CHANGES="$(git -C "$REPO_ROOT" status --porcelain -- certification/verify.sh)"
  if [ -n "$BRANCH" ]; then
    [ "$LOCAL_HEAD" = "$EXPECTED_COMMIT" ] \
      || die "This checkout is at $LOCAL_HEAD, but '$BRANCH' on GitHub is at $EXPECTED_COMMIT.
     verify.sh comes from this checkout, so the two have to be the same commit.
     Check out '$BRANCH' and push or pull until they match."
    [ -z "$VERIFY_CHANGES" ] \
      || die "certification/verify.sh has uncommitted changes.
     The container would build '$BRANCH' as pushed and be checked by a verify.sh
     that is in no commit. Commit and push it, or discard the changes."
  else
    [ "$LOCAL_HEAD" = "$EXPECTED_COMMIT" ] \
      || warn "This checkout is at $LOCAL_HEAD, but main on GitHub is at $EXPECTED_COMMIT.
   The container builds main; verify.sh comes from this checkout."
    [ -z "$VERIFY_CHANGES" ] \
      || warn "certification/verify.sh has uncommitted changes. The container is checked by a verify.sh that is in no commit."
  fi
fi

mkdir -p "$LOG_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
BOOTSTRAP_LOG="$LOG_DIR/bootstrap-$STAMP$LOG_SUFFIX.log"
VERIFY_LOG="$LOG_DIR/verify-$STAMP$LOG_SUFFIX.log"

# The verify.sh this run checks the container with, copied now and kept beside
# the logs. The checks above describe the checkout as it is at this moment, and
# the container is not verified until the bootstrap is over, minutes later.
# Copying verify.sh from the checkout then would use whatever is there by then:
# an edit, or another branch checked out in the meantime.
VERIFY_SNAPSHOT="$LOG_DIR/verify-$STAMP$LOG_SUFFIX.sh"
cp "$SCRIPT_DIR/verify.sh" "$VERIFY_SNAPSHOT" \
  || die "Could not copy verify.sh to $VERIFY_SNAPSHOT."

# A line for the terminal and for the bootstrap log.
note() { printf '%s\n' "$*" | tee -a "$BOOTSTRAP_LOG" >&2; }

# --- The container ---------------------------------------------------------

CREATED=0
# shellcheck disable=SC2329  # Called by the EXIT trap below.
cleanup() {
  if [ "$CREATED" -eq 1 ] && [ "$KEEP" -eq 0 ]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [ "$VERIFY_ONLY" -eq 1 ]; then
  # The newest container a run with --keep left. The names end in a time
  # stamp, so the last in sorted order is the newest. The list is read to the
  # end before it is sorted: nothing here is piped into a command that stops
  # early.
  KEPT="$(docker ps --filter 'name=^rama-cert-' --format '{{.Names}}')" \
    || die "Could not list the containers."
  CONTAINER="$(printf '%s\n' "$KEPT" | sort | tail -n 1)"
  [ -n "$CONTAINER" ] \
    || die "No certification container is running. Make one with a full run and --keep."
  log "Verifying the kept container $CONTAINER..."
else
  CONTAINER="rama-cert-$STAMP"

  log "Pulling $IMAGE..."
  docker pull -q "$IMAGE" >/dev/null || die "Could not pull $IMAGE."

  log "Starting a fresh container, $CONTAINER..."
  docker run -d --name "$CONTAINER" "$IMAGE" sleep infinity >/dev/null \
    || die "Could not start a container from $IMAGE."
  CREATED=1
fi

# Run a command in the container as the certification user, through a login
# shell. `su -` gives it what a terminal session has and `docker exec -u` does
# not: HOME, USER, LOGNAME and the login PATH.
in_guest() { docker exec "$CONTAINER" su - "$CERT_USER" -c "$1"; }

# Set when the commit the container built is not known to be the one GitHub
# named.
COMMIT_PROBLEM=""
BUILT_COMMIT=""
BUILT_TREE=""

if [ "$VERIFY_ONLY" -eq 0 ]; then
  log "Bootstrap transcript: $BOOTSTRAP_LOG"
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
  " >>"$BOOTSTRAP_LOG" 2>&1 || die "Could not make the user $CERT_USER in the container. See $BOOTSTRAP_LOG"

  # --- Run the bootstrap ---------------------------------------------------

  BRANCH_OPTION="${BRANCH:+--branch $BRANCH }"

  # The two steps of "Rebuild from nothing", verbatim, plus deviations 2 and
  # 3. Do not "improve" them here -- the point is to test what the README says.
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

  # set +e: the pipeline is expected to fail when the bootstrap fails, and
  # with set -e plus pipefail that would end the script here, before the
  # machine is verified.
  set +e
  in_guest 'bash /tmp/bootstrap.sh' 2>&1 | tee -a "$BOOTSTRAP_LOG"
  INIT_STATUS=${PIPESTATUS[0]}
  set -e
  if [ "$INIT_STATUS" -eq 0 ]; then
    log "Bootstrap exited 0."
  else
    warn "Bootstrap exited $INIT_STATUS. Verifying anyway -- the exit code is not the point."
  fi

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
    if [ "$BUILT_COMMIT" != "$EXPECTED_COMMIT" ]; then
      COMMIT_PROBLEM="The container built $BUILT_COMMIT, but $TARGET_BRANCH was at $EXPECTED_COMMIT on GitHub when the run started. The branch moved during the run."
    fi
  else
    BUILT_COMMIT=""
    BUILT_TREE=""
    COMMIT_PROBLEM="The commit the container built could not be read. The bootstrap may have failed before the clone."
  fi
  note "Architecture: $(docker exec "$CONTAINER" uname -m)"
  note "Bootstrap:    exited $INIT_STATUS"
  [ -z "$COMMIT_PROBLEM" ] || note "$COMMIT_PROBLEM"
fi

# --- Verify ----------------------------------------------------------------

log "Verifying outcomes. Transcript: $VERIFY_LOG"

# The copy taken at the start, run in the container as a file.
docker cp -q "$VERIFY_SNAPSHOT" "$CONTAINER:/tmp/verify.sh" \
  || die "Could not copy verify.sh into the container."
docker exec "$CONTAINER" chmod 644 /tmp/verify.sh

# set +e: the pipeline is expected to fail when verification fails.
set +e
in_guest 'bash /tmp/verify.sh' 2>&1 | tee "$VERIFY_LOG"
VERIFY_STATUS=${PIPESTATUS[0]}
set -e

# Never trust a zero exit on its own. verify.sh prints its completion record as
# the last thing it does, so the last line of the log has to be that record,
# and the record has to say that nothing failed. A run that died partway has
# no record. A run cut off after the record but before its exit status was set
# has a record that says what failed. Neither may pass.
COMPLETE_LINE="$(tail -n 1 "$VERIFY_LOG")"
COMPLETE_ANY='^VERIFY-COMPLETE [0-9]+ passed [0-9]+ failed [0-9]+ warnings [0-9]+ excluded$'
COMPLETE_CLEAN='^VERIFY-COMPLETE [0-9]+ passed 0 failed [0-9]+ warnings [0-9]+ excluded$'
if ! [[ "$COMPLETE_LINE" =~ $COMPLETE_ANY ]]; then
  warn "verify.sh did not run to completion -- its result cannot be trusted."
  VERIFY_STATUS=1
elif ! [[ "$COMPLETE_LINE" =~ $COMPLETE_CLEAN ]]; then
  [ "$VERIFY_STATUS" -ne 0 ] \
    || warn "verify.sh exited 0, but its last line reports failures: $COMPLETE_LINE"
  VERIFY_STATUS=1
fi

# Passing every check certifies nothing if the commit that passed is unknown
# or is not the one this run set out to build.
if [ -n "$COMMIT_PROBLEM" ]; then
  VERIFY_STATUS=1
fi

echo
if [ "$VERIFY_ONLY" -eq 1 ]; then
  # Never a certification. This run did not rebuild the container, did not ask
  # GitHub for a commit and did not read the one the container holds, so it
  # cannot say what passed the checks. A container whose full run failed on its
  # commit must not come back CERTIFIED by being checked again.
  if [ "$VERIFY_STATUS" -eq 0 ]; then
    printf '\033[32m✅ CHECKS PASSED\033[0m -- NOT A CERTIFICATION: %s was not rebuilt in this run.\n' "$CONTAINER"
  else
    printf '\033[31m❌ CHECKS FAILED\033[0m -- see %s\n' "$VERIFY_LOG"
  fi
elif [ "$VERIFY_STATUS" -eq 0 ]; then
  printf '\033[32m✅ CERTIFIED\033[0m -- %s rebuilt from nothing and passed every check.\n' "$CONTAINER"
else
  printf '\033[31m❌ NOT CERTIFIED\033[0m -- see %s\n' "$VERIFY_LOG"
  [ -z "$COMMIT_PROBLEM" ] || printf '   %s\n' "$COMMIT_PROBLEM"
fi
if [ "$VERIFY_ONLY" -eq 0 ] && [ -n "$BUILT_COMMIT" ]; then
  printf '   Branch: %s\n   Commit: %s\n   Tree:   %s\n' "$TARGET_BRANCH" "$BUILT_COMMIT" "$BUILT_TREE"
fi

if [ "$KEEP" -eq 1 ] || [ "$VERIFY_ONLY" -eq 1 ]; then
  cat >&2 <<KEPT

The container is left running so you can inspect it:

  docker exec -it $CONTAINER su - $CERT_USER
  ./certification/certify.sh --verify-only   # re-check without rebuilding
  docker rm -f $CONTAINER      # when you are done
KEPT
fi

exit "$VERIFY_STATUS"
