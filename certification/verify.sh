#!/bin/bash
#
# Verify a provisioned machine by its outcomes, not by exit codes.
#
# A provisioning script that returns zero has proved nothing: one that finds
# nothing to do says "all installed" and exits 0 on a machine with nothing on
# it. Every check here looks at the machine.
#
# certify.sh copies this into the certification machine and runs it as a file
# (never piped to `bash -s`: the first check that reads stdin would swallow the
# rest of the script). It is also standalone. Run it on rama any time, to know
# whether the machine still matches the repo:
#
#   sudo -v && ./certification/verify.sh
#
# `sudo -v` first, because sshd's effective settings and the firewall's rules
# can only be read as root. Without it those two checks warn and the rest run.
#
# WHAT IS EXPECTED comes from the chezmoi source directory on the machine being
# checked: the package lists, the firewall rules, the dock, the sshd settings.
# So the machine is checked against the commit it was built from, and nothing
# here has to be kept in step with those files by hand.
#
# The output is the interface, and is the same as mac-dev-config's
# verify.sh: sections, one PASS / FAIL / WARN / SKIP line per check, a summary,
# and a last line of
#
#   VERIFY-COMPLETE <n> passed <n> failed <n> warnings <n> excluded
#
# which certify.sh requires. Exit 1 if any check failed.

# The tildes below are display text in human-readable messages, not paths.
# shellcheck disable=SC2088

set -uo pipefail   # deliberately no -e: every check must run, then report

PASS=0
FAIL=0
WARNED=0
EXCLUDED=0

green() { printf '\033[32m%s\033[0m' "$*"; }
red()   { printf '\033[31m%s\033[0m' "$*"; }
amber() { printf '\033[33m%s\033[0m' "$*"; }
dim()   { printf '\033[2m%s\033[0m' "$*"; }

ok()      { PASS=$((PASS + 1));   printf '  %s  %s\n' "$(green PASS)" "$1"; }
bad()     { FAIL=$((FAIL + 1));   printf '  %s  %s\n' "$(red FAIL)" "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; return 0; }
caution() { WARNED=$((WARNED + 1)); printf '  %s  %s\n' "$(amber WARN)" "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; return 0; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# SKIP is not WARN, and the difference is the whole point.
#
# WARN means something unexpected: look at it. SKIP means the machine being
# checked cannot have the thing at all: a container has no systemd, no udevd
# and no desktop. It is reported on every run there, and there is nothing to be
# done about it here.
#
# Reporting those as warnings teaches you to skim past warnings. A warning you
# are expected to ignore devalues every warning beside it.
#
# A skip is decided by what the machine has, the same way the provisioning
# script it mirrors decides whether to run. Anything else that fails is a FAIL.
# On rama itself nothing is skipped: a run there ends with 0 excluded.
excluded() { EXCLUDED=$((EXCLUDED + 1)); printf '  %s  %s\n' "$(dim SKIP)" "$1"; [ $# -gt 1 ] && printf '        %s\n' "$(dim "$2")"; return 0; }

# What a terminal has, from .zshenv: this script may be started from a shell
# that has not read it.
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"

# Where the repo is on this machine. Asked of chezmoi, not assumed, so that the
# lists read below are the ones `chezmoi status` is comparing the machine with.
# If chezmoi cannot say, the default is used so the remaining checks can still
# run, and the chezmoi section reports it.
SRC="$(chezmoi source-path 2>/dev/null || true)"
SRC_RESOLVED=1
if [ -z "$SRC" ]; then
  SRC="$HOME/.local/share/chezmoi"
  SRC_RESOLVED=0
fi
HAS_SYSTEMD=0; [ -d /run/systemd/system ] && HAS_SYSTEMD=1
HAS_SUDO=0; sudo -n true 2>/dev/null && HAS_SUDO=1

# The entries of a list file: every line that is not blank and not a comment,
# as the provisioning scripts read them.
list_entries() { grep -v -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$1" 2>/dev/null; }

# Whether a text has this exact line. The text is given whole, as a here-string,
# and never piped in: under pipefail, `producer | grep -q` fails when grep finds
# its match and exits while the producer is still writing, and a check then
# reports missing something that is there.
has_line() { grep -qxF -- "$2" <<<"$1"; }

# A field of /etc/os-release.
os_field() { sed -n "s/^$1=//p" /etc/os-release 2>/dev/null | tr -d '"' | head -1; }

# Whether a list file is there to be read. A list that is missing must never
# pass as a list with nothing in it: "all 0 rules are set" is true and
# worthless.
have_list() { [ -f "$1" ] && [ -r "$1" ]; }

# A WORD ON COMMANDS THAT FAIL. A check must not read a command that failed as
# good news. Where no output means a pass -- no drift, nothing missing, nothing
# unlisted -- the command's exit status is checked first, and a failure is a
# FAIL of its own. Where no output already means a FAIL, nothing more is needed.

apt_installed() { [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" = "installed" ]; }

printf '\033[1mVerifying %s (%s)\033[0m\n' "$(hostname)" "$(os_field PRETTY_NAME)"

# --- Foundations -----------------------------------------------------------

section "Foundations"

if [ "$(os_field ID)" = "ubuntu" ]; then
  ok "Ubuntu ($(os_field VERSION_ID))"
else
  bad "Not Ubuntu" "/etc/os-release ID = $(os_field ID)"
fi

arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
if [ "$arch" = "amd64" ]; then
  ok "amd64"
else
  bad "Not amd64" "architecture = $arch; this repo targets amd64"
fi

for tool in curl git; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool installed"
  else
    bad "$tool missing"
  fi
done

# --- chezmoi ---------------------------------------------------------------

section "chezmoi"

if command -v chezmoi >/dev/null 2>&1; then
  ok "chezmoi installed ($(chezmoi --version | awk '{print $3}' | tr -d ,))"

  # A file that differs shows here, and so does a run_onchange_ script that has
  # not succeeded: chezmoi lists it as still to run.
  status_out="$(chezmoi status 2>&1)"
  status_exit=$?
  if [ "$status_exit" -ne 0 ]; then
    bad "chezmoi status failed (exit $status_exit)" "$(printf '%s' "$status_out" | head -3 | tr '\n' ' ')"
  elif [ -z "$status_out" ]; then
    ok "chezmoi status is empty (no drift)"
  else
    bad "chezmoi reports drift" "$(printf '%s' "$status_out" | head -5 | tr '\n' ' ')"
  fi
else
  bad "chezmoi not installed" "mise installs it; script 04"
fi

if [ "$SRC_RESOLVED" -eq 0 ]; then
  bad "chezmoi could not say where its source directory is" "'chezmoi source-path' failed; assuming $SRC for the checks below"
elif [ -d "$SRC/.git" ]; then
  ok "chezmoi source directory is a git checkout"
else
  bad "chezmoi source directory missing or not a git checkout" "$SRC"
fi

# --- Managed files landed --------------------------------------------------

section "Managed files"

for f in .zshrc .zprofile .zshenv .zlogin .bashrc .bash_profile .profile \
         .gitconfig .gitignore_global .p10k.zsh .irbrc \
         .config/mise/config.toml .config/topgrade.toml \
         .ssh/config .ssh/authorized_keys .claude/CLAUDE.md; do
  if [ -f "$HOME/$f" ]; then
    ok "~/$f"
  else
    bad "~/$f missing"
  fi
done

if [ -x "$HOME/.local/bin/dock-capture" ]; then
  ok "~/.local/bin/dock-capture is executable"
else
  bad "~/.local/bin/dock-capture missing or not executable"
fi

# Anything in the source root without a leading dot and without one of
# chezmoi's attribute prefixes becomes a target of the same name, unless
# .chezmoiignore lists it. certification/ was deployed that way once, and a
# passing apply said nothing, because a file chezmoi wrote is not drift. So
# every such entry is checked from the other side: it must not be at home.
stray=""; source_entries=0
for entry in "$SRC"/*; do
  [ -e "$entry" ] || continue
  source_entries=$((source_entries + 1))
  name="$(basename "$entry")"
  case "$name" in
    dot_*|private_*|empty_*|executable_*|exact_*|readonly_*|encrypted_*|symlink_*|create_*|modify_*|remove_*|run_*|literal_*|external_*) continue ;;
  esac
  [ -e "$HOME/$name" ] && stray="$stray $name"
done
if [ "$source_entries" -eq 0 ]; then
  bad "the chezmoi source directory has nothing in it to compare the home directory with" "$SRC"
elif [ -z "$stray" ]; then
  ok "nothing from the source root is deployed that should not be (README.md, the lists, certification)"
else
  bad "deployed to the home directory but should not be:$stray" "check .chezmoiignore"
fi

# --- apt packages ----------------------------------------------------------

section "apt packages"

if [ -f "$SRC/apt-packages.txt" ]; then
  missing=""; n=0
  while IFS= read -r pkg; do
    n=$((n + 1))
    apt_installed "$pkg" || missing="$missing $pkg"
  done < <(list_entries "$SRC/apt-packages.txt")
  if [ "$n" -eq 0 ]; then
    bad "apt-packages.txt lists no packages" "$SRC/apt-packages.txt"
  elif [ -z "$missing" ]; then
    ok "all $n packages in apt-packages.txt installed"
  else
    bad "packages in apt-packages.txt not installed:$missing"
  fi
else
  bad "apt-packages.txt not found" "$SRC/apt-packages.txt"
fi

# The vendor repositories and their packages are named only in script 03, so
# they are read out of it. If the script's shape changes and nothing can be
# read, that is a FAIL here, not a quiet pass over an empty list.
script03="$SRC/.chezmoiscripts/run_onchange_before_03_vendor_apt_repositories.sh.tmpl"
if [ -f "$script03" ]; then
  repos="$(awk '$1 == "add_repository" && $2 != "" { print $2 }' "$script03")"
  vendor_pkgs="$(awk '
    /^[[:space:]]*packages=\(/    { inlist = 1; next }
    inlist && /^[[:space:]]*\)/   { inlist = 0; next }
    inlist                        { print $1; next }
    /^[[:space:]]*packages\+=\(/  { line = $0; sub(/.*\(/, "", line); sub(/\).*/, "", line); n = split(line, a, " "); for (i = 1; i <= n; i++) print a[i] }
  ' "$script03")"
  repo_n="$(printf '%s\n' "$repos" | grep -c . || true)"
  pkg_n="$(printf '%s\n' "$vendor_pkgs" | grep -c . || true)"

  if [ "$repo_n" -lt 5 ] || [ "$pkg_n" -lt 5 ]; then
    bad "could not read the vendor repositories and packages out of script 03" \
        "found $repo_n repositories and $pkg_n packages; verify.sh needs updating to the script's new shape"
  else
    missing=""
    for repo in $repos; do
      [ -f "/etc/apt/sources.list.d/$repo.sources" ] || missing="$missing $repo"
    done
    if [ -z "$missing" ]; then
      ok "all $repo_n vendor apt repositories registered"
    else
      bad "vendor apt repositories not registered:$missing"
    fi

    missing=""
    for pkg in $vendor_pkgs; do
      apt_installed "$pkg" || missing="$missing $pkg"
    done
    if [ -z "$missing" ]; then
      ok "all $pkg_n vendor packages installed"
    else
      bad "vendor packages not installed:$missing"
    fi

    # A .sources file that is there can still be empty or disabled -- a release
    # upgrade disables third-party repositories by adding "Enabled: no" -- and
    # the packages stay installed while their updates quietly stop. So each
    # file has to name a repository and must not be switched off.
    #
    # The file is read, not apt's view of it. Asking apt which repository
    # offers a package depends on when `apt-get update` last ran: Chrome's
    # package rewrites its own .sources file as it installs, with a different
    # address, and until the next update apt has no index for it. On a machine
    # that has just been built that is every time, and nothing is wrong.
    unusable=""
    for repo in $repos; do
      sources_file="/etc/apt/sources.list.d/$repo.sources"
      [ -f "$sources_file" ] || continue   # reported above as not registered
      if ! grep -q '^URIs:[[:space:]]*[^[:space:]]' "$sources_file" \
          || grep -qi '^Enabled:[[:space:]]*no[[:space:]]*$' "$sources_file"; then
        unusable="$unusable $repo"
      fi
    done
    if [ -z "$unusable" ]; then
      ok "every vendor apt repository names a source and is enabled"
    else
      bad "vendor apt repositories empty or disabled:$unusable" "see /etc/apt/sources.list.d/<name>.sources"
    fi
  fi
else
  bad "script 03 not found in the chezmoi source" "$script03"
fi

# Script 03 adds the user to the docker group. `id -nG <name>` reads the group
# database, so this is true before the next login makes it take effect.
user_name="$(id -un)"
if has_line "$(id -nG "$user_name" | tr ' ' '\n')" docker; then
  ok "$user_name is in the docker group"
else
  bad "$user_name is not in the docker group"
fi

# --- Runtimes --------------------------------------------------------------

section "Runtimes (mise)"

mise_config="$HOME/.config/mise/config.toml"
if command -v mise >/dev/null 2>&1; then
  ok "mise installed ($(mise --version 2>/dev/null | awk '{print $1}'))"

  if [ -f "$mise_config" ]; then
    mise_list="$(cd "$HOME" && mise ls --global --missing --no-header 2>/dev/null)"
    mise_exit=$?
    mise_missing="$(awk '{print $1}' <<<"$mise_list" | tr '\n' ' ')"
    declared_n="$(awk '/^\[tools\]/ { t = 1; next } /^\[/ { t = 0 } t && /^[^#[:space:]].*=/ { n++ } END { print n + 0 }' "$mise_config")"
    if [ "$mise_exit" -ne 0 ]; then
      bad "mise could not list its tools (exit $mise_exit)" "see: mise ls --global --missing"
    elif [ "$declared_n" -eq 0 ]; then
      bad "no tools declared in ~/.config/mise/config.toml"
    elif [ -z "$(printf '%s' "$mise_missing" | tr -d ' ')" ]; then
      ok "all $declared_n tools declared in config.toml installed"
    else
      bad "declared in config.toml but not installed: $mise_missing"
    fi

    # The runtimes are pinned to exact versions, so the version is checked too.
    for tool in go node python ruby rust; do
      want="$(sed -n "s/^${tool}[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$mise_config" | head -1)"
      have="$(cd "$HOME" && mise current "$tool" 2>/dev/null | awk '{print $1}')"
      if [ -z "$want" ]; then
        bad "$tool is not pinned in config.toml"
      elif [ "$have" = "$want" ]; then
        ok "$tool $have"
      else
        bad "$tool is ${have:-not installed}" "config.toml pins $want"
      fi
    done
  else
    bad "~/.config/mise/config.toml missing"
  fi

  for cmd in ruby node python go; do
    resolved="$(command -v "$cmd" 2>/dev/null || true)"
    case "$resolved" in
      "$HOME/.local/share/mise/shims/"*) ok "$cmd resolves through mise shims" ;;
      "") bad "$cmd not on PATH" ;;
      *)  bad "$cmd resolves to $resolved" "expected a mise shim" ;;
    esac
  done
else
  bad "mise not installed" "script 03 installs it from its apt repository"
fi

# --- VS Code ---------------------------------------------------------------

section "VS Code"

if command -v code >/dev/null 2>&1 && [ -f "$SRC/vscode-extensions.txt" ]; then
  # Names, not counts: extensions pulled in as dependencies inflate a total.
  # Both lists are built once, before either comparison.
  installed_list="$(code --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]' | sort)"
  declared_list="$(list_entries "$SRC/vscode-extensions.txt" | tr '[:upper:]' '[:lower:]' | sort)"
  declared_n="$(printf '%s\n' "$declared_list" | grep -c . || true)"
  installed_n="$(printf '%s\n' "$installed_list" | grep -c . || true)"

  missing_ext="$(comm -23 <(printf '%s\n' "$declared_list") <(printf '%s\n' "$installed_list") | tr '\n' ' ')"
  if [ "$declared_n" -eq 0 ]; then
    bad "vscode-extensions.txt lists no extensions"
  elif [ -z "$(printf '%s' "$missing_ext" | tr -d ' ')" ]; then
    ok "all $declared_n declared extensions installed ($installed_n present in total)"
  else
    bad "declared extensions missing: $missing_ext"
  fi

  # A warning, not a failure: an extension pack can gain a member upstream, and
  # Settings Sync can add one. It says the list has fallen behind the machine.
  extra_ext="$(comm -13 <(printf '%s\n' "$declared_list") <(printf '%s\n' "$installed_list") | tr '\n' ' ')"
  if [ -z "$(printf '%s' "$extra_ext" | tr -d ' ')" ]; then
    ok "no undeclared extensions (vscode-extensions.txt fully determines the set)"
  else
    caution "installed but not declared: $extra_ext" \
            "add them to vscode-extensions.txt, or uninstall"
  fi
elif ! command -v code >/dev/null 2>&1; then
  bad "code CLI not on PATH" "script 03 installs VS Code from Microsoft's apt repository"
else
  bad "vscode-extensions.txt not found" "$SRC/vscode-extensions.txt"
fi

# --- Shell environment -----------------------------------------------------

section "Shell environment"

# From the account database, not $SHELL: script 02 changes the database, and
# $SHELL only follows at the next login.
login_shell="$(getent passwd "$user_name" | cut -d: -f7)"
if [ "$(basename "${login_shell:-}")" = "zsh" ]; then
  ok "login shell is zsh"
else
  bad "login shell is ${login_shell:-unset}" "expected zsh; script 02 sets it"
fi

if command -v zsh >/dev/null 2>&1; then
  # A fresh login shell, not this one: it reads .zshenv, where PATH is set.
  login_path="$(zsh -lc 'printf "%s" "$PATH"' 2>/dev/null)"
  case "$login_path" in
    *"$HOME/.local/share/mise/shims"*) ok "mise shims on PATH in a login shell" ;;
    *) bad "mise shims not on PATH in a login shell" ;;
  esac

  # An interactive login shell, because that is what a terminal opens. There
  # .zshrc runs `mise activate`, which takes the shims off PATH and puts each
  # tool's own directory on it, so the answer is under mise's data directory
  # but not under shims. Run through `script` for a pty: without one zsh cannot
  # enable job control and powerlevel10k's gitstatus fails to start, which says
  # nothing about the machine.
  # shellcheck disable=SC2016  # Expanded by the zsh this starts, not here.
  interactive_ruby="$(script -qec 'zsh -lic "printf \"ruby=%s\n\" \"\$(command -v ruby)\""' /dev/null </dev/null 2>&1 \
    | tr -d '\r' \
    | sed -n 's/.*ruby=//p' \
    | tail -1)"
  case "$interactive_ruby" in
    "$HOME/.local/share/mise/"*) ok "ruby resolves through mise in an interactive login shell" ;;
    "") bad "ruby not on PATH in an interactive login shell" ;;
    *)  bad "ruby resolves to $interactive_ruby in an interactive login shell" "expected a path under ~/.local/share/mise" ;;
  esac

  # An interactive login shell must start cleanly: no output at all, and a zero
  # exit. A login shell, so that .zprofile and .zlogin are read as well as
  # .zshrc: it is what a terminal opens. One line is not allowed through. A single "command not found" from .zshrc
  # is exactly one line, and is exactly what this check is for. `script -e`
  # hands back the shell's own exit status.
  if command -v script >/dev/null 2>&1; then
    interactive_raw="$(script -qec 'zsh -lic exit' /dev/null </dev/null 2>&1)"
    interactive_exit=$?
    interactive_text="$(printf '%s\n' "$interactive_raw" | sed $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' | tr -d '\r' | grep -v '^\^D' | grep .)"
    if [ "$interactive_exit" -ne 0 ]; then
      bad "interactive login shell exits $interactive_exit" "$(head -3 <<<"$interactive_text" | tr '\n' ' ')"
    elif [ -n "$interactive_text" ]; then
      bad "interactive login shell prints $(grep -c . <<<"$interactive_text") line(s) at startup" \
          "$(head -3 <<<"$interactive_text" | tr '\n' ' ')"
    else
      ok "interactive login shell starts without errors"
    fi
  else
    bad "cannot start an interactive shell to test: 'script' is not installed"
  fi
else
  bad "zsh not installed"
fi

# --- Snaps -----------------------------------------------------------------

section "Snaps"

snap_n="$(list_entries "$SRC/snap-packages.txt" | grep -c . || true)"
if ! have_list "$SRC/snap-packages.txt"; then
  bad "snap-packages.txt not found" "$SRC/snap-packages.txt"
elif [ "$snap_n" -eq 0 ]; then
  ok "no snaps listed"
elif ! command -v snap >/dev/null 2>&1 || [ "$HAS_SYSTEMD" -eq 0 ]; then
  excluded "$snap_n snaps not verified" "snapd is not running here"
else
  missing=""
  while IFS= read -r entry; do
    name="${entry%% *}"
    snap list "$name" >/dev/null 2>&1 || missing="$missing $name"
  done < <(list_entries "$SRC/snap-packages.txt")
  if [ -z "$missing" ]; then
    ok "all $snap_n snaps in snap-packages.txt installed"
  else
    bad "snaps in snap-packages.txt not installed:$missing"
  fi
fi

# --- sshd ------------------------------------------------------------------

section "sshd"

sshd_dropin=/etc/ssh/sshd_config.d/00-rama.conf
if [ -x /usr/sbin/sshd ]; then
  if [ -f "$sshd_dropin" ] && cmp -s "$sshd_dropin" "$SRC/sshd-rama.conf"; then
    ok "$sshd_dropin matches sshd-rama.conf"
  else
    bad "$sshd_dropin is missing or differs from sshd-rama.conf" "script 09 installs it"
  fi

  # What sshd will do, not what the file says: another drop-in could override
  # it. sshd -T reads the host keys, so it needs root.
  if [ "$HAS_SUDO" -eq 1 ]; then
    sudo mkdir -p /run/sshd
    # Lowercased before comparing. Which case sshd prints its keywords in
    # depends on its version: lowercase on Ubuntu 26.04, and as written in the
    # manual (PasswordAuthentication) on 26.10. Script 09 ignores case for the
    # same reason.
    effective="$(sudo /usr/sbin/sshd -T -C "user=$user_name,host=client,addr=192.168.0.2" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    wrong=""
    for want in \
      'authenticationmethods publickey' \
      'pubkeyauthentication yes' \
      'passwordauthentication no' \
      'kbdinteractiveauthentication no' \
      'permitrootlogin no' \
      'disableforwarding yes' \
      'authorizedkeysfile .ssh/authorized_keys'; do
      has_line "$effective" "$want" || wrong="$wrong [$want]"
    done
    if [ -z "$effective" ]; then
      bad "sshd -T printed nothing" "the configuration may not parse: sudo sshd -t"
    elif [ -z "$wrong" ]; then
      ok "sshd accepts public keys only, with root login and forwarding off"
    else
      bad "sshd's effective settings are missing:$wrong"
    fi
  else
    caution "sshd's effective settings not read" "they need root: run 'sudo -v' and then this script again"
  fi

  if [ "$HAS_SYSTEMD" -eq 1 ]; then
    if systemctl is-active --quiet ssh.socket || systemctl is-active --quiet ssh.service; then
      ok "sshd is running"
    else
      bad "sshd is not running" "script 01 enables it"
    fi
  else
    excluded "sshd running not verified" "systemd is not running here"
  fi
else
  bad "sshd not installed" "openssh-server is in apt-packages.txt"
fi

# Every key line must carry `restrict`: script 09 refuses any other.
keys_file="$HOME/.ssh/authorized_keys"
if [ -f "$keys_file" ]; then
  key_n=0; unrestricted=0
  while IFS= read -r line; do
    key_n=$((key_n + 1))
    case "$line" in
      'restrict '*|'restrict,pty '*) ;;
      *) unrestricted=$((unrestricted + 1)) ;;
    esac
  done < <(list_entries "$keys_file")
  if [ "$unrestricted" -eq 0 ]; then
    ok "all $key_n key(s) in authorized_keys are restricted"
  else
    bad "$unrestricted of $key_n key(s) in authorized_keys lack 'restrict'"
  fi
fi

# --- Firewall --------------------------------------------------------------

section "Firewall"

if ! have_list "$SRC/ufw-rules.txt"; then
  bad "ufw-rules.txt not found" "$SRC/ufw-rules.txt"
elif ! command -v ufw >/dev/null 2>&1 || [ "$HAS_SYSTEMD" -eq 0 ]; then
  excluded "firewall not verified" "ufw cannot run here"
elif [ "$HAS_SUDO" -eq 0 ]; then
  caution "firewall not read" "ufw's state needs root: run 'sudo -v' and then this script again"
else
  ufw_status="$(sudo ufw status verbose 2>/dev/null)"
  if has_line "$ufw_status" 'Status: active'; then
    ok "ufw is active"
  else
    bad "ufw is not active" "script 10 enables it"
  fi
  if grep -q '^Default: deny (incoming), allow (outgoing)' <<<"$ufw_status"; then
    ok "inbound blocked and outbound allowed by default"
  else
    bad "ufw's defaults are not deny incoming, allow outgoing" \
        "$(printf '%s\n' "$ufw_status" | grep '^Default:' | head -1)"
  fi

  ufw_added="$(sudo ufw show added 2>/dev/null)"
  missing=0; rule_n=0
  while IFS= read -r rule; do
    rule_n=$((rule_n + 1))
    has_line "$ufw_added" "ufw $rule" || missing=$((missing + 1))
  done < <(list_entries "$SRC/ufw-rules.txt")
  if [ "$missing" -eq 0 ]; then
    ok "all $rule_n rules in ufw-rules.txt are set"
  else
    bad "$missing of $rule_n rules in ufw-rules.txt are not set" "compare with: sudo ufw show added"
  fi
fi

# --- udev ------------------------------------------------------------------

section "udev"

udev_rule_file=/etc/udev/rules.d/99-hide-zfs-member.rules
script08="$SRC/.chezmoiscripts/run_onchange_after_08_hide_zfs_member.sh.tmpl"
udev_rule="$(sed -n "s/^RULE='\\(.*\\)'\$/\\1/p" "$script08" 2>/dev/null | head -1)"
if [ -z "$udev_rule" ]; then
  bad "could not read the udev rule out of script 08" "verify.sh needs updating to the script's new shape"
elif [ -f "$udev_rule_file" ] && [ "$(cat "$udev_rule_file")" = "$udev_rule" ]; then
  ok "$udev_rule_file holds the rule"
else
  bad "$udev_rule_file is missing or differs from the rule in script 08"
fi

# Whether the rule is in force, shown by what it does: udev marks every ZFS
# pool member UDISKS_IGNORE=1. That needs a running udevd and a pool member to
# look at, which rama has and a container or an ext4 VM does not.
block_devices="$(lsblk -rno NAME,FSTYPE 2>/dev/null)"
lsblk_exit=$?
zfs_members="$(awk '$2 == "zfs_member" { print $1 }' <<<"$block_devices")"
if [ ! -S /run/udev/control ]; then
  excluded "udev rule in force not verified" "udevd is not running here"
elif [ "$lsblk_exit" -ne 0 ]; then
  bad "lsblk could not list the block devices (exit $lsblk_exit)" "so whether the udev rule is in force is unknown"
elif [ -z "$zfs_members" ]; then
  excluded "udev rule in force not verified" "this machine has no ZFS pool member for the rule to match"
else
  unmarked=""; member_n=0
  for dev in $zfs_members; do
    member_n=$((member_n + 1))
    properties="$(udevadm info --query=property --name="/dev/$dev" 2>/dev/null)"
    has_line "$properties" 'UDISKS_IGNORE=1' || unmarked="$unmarked $dev"
  done
  if [ -z "$unmarked" ]; then
    ok "udev marks all $member_n ZFS pool member(s) to be ignored by udisks"
  else
    bad "ZFS pool members not marked UDISKS_IGNORE=1:$unmarked" \
        "the rule is not loaded: sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=block"
  fi
fi

# --- Desktop ---------------------------------------------------------------

section "Desktop"

fonts="$(fc-list 2>/dev/null)"
if grep -q 'MesloLGS NF' <<<"$fonts"; then
  ok "MesloLGS NF font installed"
else
  bad "MesloLGS NF font not found by fontconfig" "script 07 rebuilds the font cache"
fi

schemas=""; schemas_exit=0
if command -v gsettings >/dev/null 2>&1; then
  schemas="$(gsettings list-schemas 2>/dev/null)"
  schemas_exit=$?
fi
has_schema() { has_line "$schemas" "$1"; }

if [ "$schemas_exit" -ne 0 ]; then
  bad "gsettings could not list its schemas (exit $schemas_exit)" "so whether GNOME is installed is unknown"
elif ! has_schema org.gnome.shell; then
  excluded "terminal font, dock and mouse not verified" "GNOME is not installed here"
else
  if has_schema org.gnome.Ptyxis; then
    font_want="$(sed -n "s/^font='\\(.*\\)'\$/\\1/p" "$SRC/.chezmoiscripts/run_onchange_after_07_terminal_font.sh.tmpl" 2>/dev/null | head -1)"
    font_have="$(gsettings get org.gnome.Ptyxis font-name 2>/dev/null)"
    system_font="$(gsettings get org.gnome.Ptyxis use-system-font 2>/dev/null)"
    if [ -z "$font_want" ]; then
      bad "could not read the font out of script 07" "verify.sh needs updating to the script's new shape"
    elif [ "$font_have" = "'$font_want'" ] && [ "$system_font" = "false" ]; then
      ok "Ptyxis font is $font_want"
    else
      bad "Ptyxis font is $font_have (use-system-font $system_font)" "expected '$font_want' with use-system-font false; script 07 sets it"
    fi
  else
    bad "Ptyxis is not installed" "it is Ubuntu Desktop's terminal"
  fi

  wanted_favorites='['
  while IFS= read -r favorite; do
    wanted_favorites="$wanted_favorites'$favorite', "
  done < <(list_entries "$SRC/dock-favorites.txt")
  wanted_favorites="${wanted_favorites%, }]"
  have_favorites="$(gsettings get org.gnome.shell favorite-apps 2>/dev/null)"
  if ! have_list "$SRC/dock-favorites.txt"; then
    bad "dock-favorites.txt not found" "$SRC/dock-favorites.txt"
  elif [ "$have_favorites" = "$wanted_favorites" ]; then
    ok "dock launchers match dock-favorites.txt"
  else
    bad "dock launchers differ from dock-favorites.txt" "they are: $have_favorites"
  fi

  dock_path=/org/gnome/shell/extensions/dash-to-dock/
  if has_schema org.gnome.shell.extensions.dash-to-dock && command -v dconf >/dev/null 2>&1; then
    # Script 11 sets each listed key and resets every other one. A listed key
    # is read with gsettings, which gives its value whether or not it was ever
    # written: a key left at a default that matches is not in the dump at all.
    # The dump is what shows a key that is set and not listed.
    dock_schema=org.gnome.shell.extensions.dash-to-dock
    wrong=""; listed=""; setting_n=0
    while IFS= read -r setting; do
      setting_n=$((setting_n + 1))
      key="${setting%%=*}"; want="${setting#*=}"
      listed="$listed$key"$'\n'
      have="$(gsettings get "$dock_schema" "$key" 2>/dev/null)"
      [ "$have" = "$want" ] || wrong="$wrong $key=$have"
    done < <(list_entries "$SRC/dock-settings.txt")
    dump="$(dconf dump "$dock_path" 2>/dev/null)"
    dump_exit=$?
    unlisted=""
    while IFS= read -r line; do
      case "$line" in ''|\[*) continue ;; esac
      key="${line%%=*}"
      has_line "$listed" "$key" || unlisted="$unlisted $key"
    done <<<"$dump"
    if ! have_list "$SRC/dock-settings.txt"; then
      bad "dock-settings.txt not found" "$SRC/dock-settings.txt"
    elif [ "$dump_exit" -ne 0 ]; then
      bad "dconf could not list the dock settings (exit $dump_exit)" "so a setting that is set and not listed would not show"
    elif [ -z "$wrong" ] && [ -z "$unlisted" ]; then
      ok "all $setting_n dock settings match dock-settings.txt, and no other is set"
    else
      bad "dock settings differ from dock-settings.txt" "wrong:${wrong:- none}; set but not listed:${unlisted:- none}"
    fi
  else
    bad "Ubuntu Dock or dconf is not installed" "dconf-cli is in apt-packages.txt"
  fi

  if [ "$(gsettings get org.gnome.desktop.peripherals.mouse natural-scroll 2>/dev/null)" = "true" ]; then
    ok "mouse wheel uses natural scrolling"
  else
    bad "mouse wheel does not use natural scrolling" "script 12 sets it"
  fi
fi

# --- Identity --------------------------------------------------------------

section "Identity"

want_host="$(chezmoi execute-template '{{ if hasKey . "hostName" }}{{ .hostName }}{{ end }}' 2>/dev/null)"
if [ "$HAS_SYSTEMD" -eq 0 ]; then
  excluded "host name not verified" "systemd is not running here; a container gets its name from the runtime"
elif [ -z "$want_host" ]; then
  bad "no host name is configured in chezmoi" "answer the question with: chezmoi init"
elif [ "$(hostname)" = "$want_host" ]; then
  ok "host name = $want_host"
else
  bad "host name is $(hostname)" "expected $want_host; script 00 sets it"
fi

# --- Summary ---------------------------------------------------------------

printf '\n\033[1m%s\033[0m\n' "Summary"
printf '  %s passed, %s failed, %s warnings, %s excluded\n' \
  "$(green "$PASS")" \
  "$([ "$FAIL" -gt 0 ] && red "$FAIL" || echo 0)" \
  "$([ "$WARNED" -gt 0 ] && amber "$WARNED" || echo 0)" \
  "$(dim "$EXCLUDED")"

if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$(red 'Verification failed.')"
else
  printf '%s\n' "$(green 'All checks passed.')"
fi

# The line below is the last thing this script prints, and certify.sh requires
# it to be the last line of the log, with a failed count of 0. A verification
# that dies partway through must never be mistaken for one that passed.
printf 'VERIFY-COMPLETE %s passed %s failed %s warnings %s excluded\n' \
  "$PASS" "$FAIL" "$WARNED" "$EXCLUDED"

[ "$FAIL" -eq 0 ] || exit 1
exit 0
