# rama-config

The configuration of `rama`, an x86_64 machine running Ubuntu 26.10 Desktop. It is managed by [chezmoi](https://www.chezmoi.io/).

rama has two jobs:

- A backup development machine that can do most of what the Mac
  (`neuromancer`) does.
- A Linux test machine that other machines drive over ssh, the way `sophon` is
  used for Windows.

This repo is a sibling of
[neuromancer-config](https://github.com/jcouball/neuromancer-config) (macOS)
and [sophon-config](https://github.com/jcouball/sophon-config) (Windows). Each
repo configures one machine. Shared dotfiles are copied between them, not
templated, so a change to one machine never needs testing on another.

**Status: tested in a container, not yet on the machine.** The rebuild
procedure below ran to completion in an `ubuntu:26.04` container. See
[Not done yet](#not-done-yet) for what that leaves untested.

## Principle: conventional Ubuntu

rama is set up the way an Ubuntu administrator would expect. Software comes
from the first of these sources that has it:

1. **The Ubuntu archive, with `apt`.** This is the default for everything.
2. **The vendor's own apt repository**, when the archive lacks the software or
   carries a version too old to use.
3. **mise**, only for what neither of the first two provides: language
   runtimes at pinned versions, and command-line tools with no apt package.
4. **snap**, only for GUI applications that none of the first three provides.

Being conventional takes priority over matching the Mac. Where the two
conflict, rama follows Ubuntu practice and accepts that the commands differ
from `neuromancer`. The Mac uses Homebrew and asdf; rama uses neither.

Two consequences of the principle:

- **No Homebrew.** It works on Linux, but it is not how Ubuntu machines are
  managed, and it installs its own copies of libraries that builds can pick up
  by accident.
- **No snap for command-line tools.** Snap puts commands in `/snap/bin`, which
  only login shells have on `PATH`, so `ssh rama 'some-tool'` would not find
  them. Snaps also update on their own schedule. Snap is acceptable for GUI
  applications.

## Install Ubuntu

rama is a Dell Inspiron 3880 desktop with one 238 GB NVMe disk. Install from
the Ubuntu 26.10 Desktop ISO, with the network cable plugged in. The installer
shows these screens in this order; its wording changes between releases, so
match each by what it asks.

| Screen | Choice |
| --- | --- |
| Language | English |
| Accessibility | Nothing |
| Keyboard | English (US) |
| Network | The wired connection. Wi-Fi is not used |
| Try or install | Install Ubuntu |
| Interactive or automated | Interactive installation |
| Which apps to install | Default selection, the minimal desktop. Not the extended selection |
| Extra software | Leave both boxes unticked: third-party drivers, and support for more media formats |
| Disk setup | Erase the disk and install Ubuntu. Under the advanced features, ZFS, without encryption |
| Account | Name `James Couball`, computer name `rama`, username `james`, and a password required to log in |
| Time zone | `America/Los_Angeles` |

Why these:

- **26.10, not 26.04 LTS.** 26.10 is what the scripts have run on. It is an
  interim release: see [Updates](#updates) for when it has to be upgraded.
- **The minimal desktop and no extras.** The lists in this repo are the whole
  inventory of what is installed on top of Ubuntu. The Inspiron's Intel
  graphics needs no proprietary driver.
- **ZFS.** The installer labels it experimental. It puts the root pool,
  `rpool`, on the fourth partition, after the EFI, `/boot`, and swap
  partitions it creates. Script 08 exists because of this choice.
- **No encryption.** rama stays at home and has to come back from a reboot
  with nobody at the keyboard, so that other machines can drive it over ssh.
  Anyone who takes the disk can read it, including the `gh` and Claude Code
  sign-ins. The installer is the only place to change this.
- **The username `james`.** The ssh client entry under
  [Set up a client](#set-up-a-client) logs in as `james`.
- **The computer name `rama`.** chezmoi asks for the host name and offers the
  current one as the default, so naming the machine here makes that answer
  Enter.

## Rebuild from nothing

On the fresh install, in a terminal on the desktop, not over ssh: the scripts
that set the terminal font, the dock, and the mouse need the desktop session.

```bash
# 1. What the next command needs.
sudo apt-get update && sudo apt-get install -y curl git

# 2. Everything else.
sudo -v && sh -c "$(curl -fsLS get.chezmoi.io)" -- -b /tmp/chezmoi-bootstrap \
  init --apply jcouball/rama-config
```

Step 2 downloads a temporary copy of chezmoi and runs it. It asks what the
machine is called, then installs the apt packages, changes the login shell to
zsh, registers the vendor apt repositories, writes the config files, installs
the mise runtimes and tools, installs the VS Code extensions, installs any
snaps listed, restricts sshd to key logins, turns on the firewall, and sets up
the dock.

The temporary chezmoi in `/tmp` is only for this first run. mise installs the
permanent one.

Run `sudo -v` first and never `sudo chezmoi apply`: chezmoi would write
root-owned files into the home directory. The scripts call `sudo` themselves
where they need it.

Afterwards, by hand:

1. Give the machines that will drive rama the key: see
   [Set up a client](#set-up-a-client).
2. Log out and back in so the login shell change and the `docker` group
   membership take effect.
3. Log into 1Password.
4. Sign in to mail in Thunderbird, and set View > Layout to Classic View.
5. Run `claude` and `gh auth login` to sign in to each.
6. Sign in to VS Code with GitHub and turn on Settings Sync.
7. Sign in to Telegram: scan its QR code from the phone app.

## What installs what

| What | Source | Declared in |
| --- | --- | --- |
| Compilers, libraries, services, zsh, sshd, and every tool Ubuntu carries | apt, Ubuntu archive | [apt-packages.txt](apt-packages.txt) |
| VS Code, `gh`, the 1Password app and CLI, Claude Code, mise, Chrome, Slack, Warp, Typora, Docker Engine | apt, vendor repositories | script `before_03_vendor_apt_repositories` |
| Ruby, Node, Python, Go, Rust | mise | [dot_config/mise/config.toml](dot_config/mise/config.toml) |
| Command-line tools with no apt package, including chezmoi and topgrade | mise | the same file |
| VS Code extensions | `code --install-extension` | [vscode-extensions.txt](vscode-extensions.txt) |
| GUI applications with no apt source | snap | [snap-packages.txt](snap-packages.txt) |
| The powerlevel10k zsh theme, and the `jcouball/scripts` utilities | git checkouts kept by chezmoi | [.chezmoiexternal.toml](.chezmoiexternal.toml) |
| The MesloLGS NF font the prompt needs | files downloaded once by chezmoi | [.chezmoiexternal.toml](.chezmoiexternal.toml) |
| Dock launchers for web pages, and their icons | chezmoi | [dot_local/share/private_applications](dot_local/share/private_applications), [dot_local/share/icons](dot_local/share/icons) |
| The dock's pinned launchers and settings | gsettings | [dock-favorites.txt](dock-favorites.txt), [dock-settings.txt](dock-settings.txt) |
| Config files | chezmoi | the `dot_*` files |

### Why each vendor repository is there

| Package | Why not the Ubuntu archive |
| --- | --- |
| `code` | Not in the archive |
| `gh` | The archive has 2.46.0, more than two years old |
| `1password` | Not in the archive |
| `1password-cli` | Not in the archive |
| `claude-code` | Not in the archive |
| `mise` | Not in the archive |
| `warp-terminal` | Not in the archive |
| `typora` | Not in the archive |
| `docker-ce` and its plugins | The archive has `docker.io`, Ubuntu's own build; Docker's repository has Docker's releases and the Compose and Buildx plugins |
| `google-chrome-stable` | Not in the archive |
| `slack-desktop` | Not in the archive |

Claude Code follows the repository's `latest` channel, the same channel Claude
Code checks for updates, so its "Update available" notice means `topgrade` has
an upgrade to install. The `stable` channel runs about a week behind and skips
releases with major regressions. To switch, change the URI and suite in script
03 from `latest` to `stable`.

The script checks the Claude Code and Docker signing keys against the
fingerprints Anthropic and Docker document. The other eight keys are fetched
over HTTPS from the vendor, as each vendor's own instructions do.

The 1Password app, Chrome, and Slack are published for amd64 only. The script
installs them when the machine is amd64 and skips them otherwise.

**Docker is Docker Engine, not Docker Desktop.** Desktop runs the engine inside
a virtual machine, which Linux does not need. The script adds the user to the
`docker` group, so `docker` runs without `sudo`, including in a command started
over ssh. Membership of that group is equivalent to root access.

**Four packages register their vendor's repository themselves.** apt refuses to
update when two files define one repository with different keys, and warns on
every update when they differ in any other way. The script avoids a second
definition in each case:

| Package | What it does | What the script does |
| --- | --- | --- |
| `1password` | Rewrites `1password.sources` on every install and upgrade | Uses the same file name |
| `google-chrome-stable` | Rewrites `google-chrome.sources` on every install and upgrade | Uses the same file name |
| `warp-terminal` | Writes `warpdotdev.sources` only when it is missing | Uses the same file name, so the package leaves it alone |
| `slack-desktop` | A daily cron job writes `slack.list` | Turns the cron job's switch off in `/etc/default/slack` |

For 1Password and Chrome, the file on disk is the package's version after an
install or upgrade and the script's version after the script runs. Both work.

### What mise installs, and how

mise's own registry covers most tools and downloads them from the project's
GitHub releases. Four entries in the config use a different route:

- `npm:@github/copilot` and `npm:markdownlint-cli` are npm packages, installed
  with the Node that mise provides.
- `pipx:checkov` is a Python package. The registry's `checkov` entry downloads
  a release binary that is not published for every architecture.
- `github:` entries (`dblab`, `git-trim`, `mq`) are not in the registry and are
  installed straight from the project's GitHub releases.

Runtimes are pinned to exact versions. Tools are set to `latest`.

**Ruby and Python are precompiled.** mise downloads a prebuilt Ruby and Python
where one exists, which takes seconds. Ruby still loads the system's OpenSSL,
and gems with native extensions compile against apt's headers. To build Ruby
from source against apt's libraries, run `mise settings set ruby.compile true`
before installing it.

### PATH is set in .zshenv

`ssh rama 'ruby -v'` starts a zsh that is neither a login shell nor
interactive. That shell reads `.zshenv` and nothing else, so `.zshenv` is the
only file that can put mise's Ruby on `PATH` for a command run over ssh. It
does so with mise's shims directory.

Interactive shells also run `mise activate` from `.zshrc`, which manages `PATH`
directly and applies a project's own `mise.toml` or `.tool-versions` on `cd`.

## Remote access over SSH

Other machines on the LAN run commands and tests on rama over ssh. A session
logs in as `james`, who has sudo and is in the `docker` group, so a login is
close to root access. Three things limit who gets one, the same three
[sophon-config](https://github.com/jcouball/sophon-config) uses:

- **Keys only.** [sshd-rama.conf](sshd-rama.conf) is installed as
  `/etc/ssh/sshd_config.d/00-rama.conf`. It allows public keys alone, so the
  account password does not open a session, and it refuses root.
- **Keys from this repo.** chezmoi writes `~/.ssh/authorized_keys` from
  [private_dot_ssh/private_authorized_keys](private_dot_ssh/private_authorized_keys).
  Each line must start with `restrict` or `restrict,pty`; script 09 fails the
  apply on any other.
- **LAN only.** ufw blocks every inbound connection except the rules in
  [ufw-rules.txt](ufw-rules.txt), which allow port 22 from `192.168.0.0/16`
  and from IPv6 link-local addresses.

Forwarding is off: `DisableForwarding yes` covers ports, the agent, X11, and
tunnels, and no key option can turn it back on. Use `scp` or `sftp` to move
files; both still work.

There is one key for rama, `id_ed25519_rama`, used for rama alone. Its private
half is kept in 1Password as an SSH Key item of the same name, and every
client holds a copy. Each copy should have a passphrase, so a copy of the key
file is useless on its own. Nothing here can enforce that.

**The firewall does not cover Docker.** Docker publishes ports with its own
packet-filter rules, which run ahead of ufw's, so `docker run -p 8080:80` is
reachable from the network whatever `ufw-rules.txt` says. To keep a container
private, publish it on the loopback address: `-p 127.0.0.1:8080:80`.

**The firewall blocks everything else inbound.** A dev server or Redis on
rama is unreachable from another machine until it has a rule: see
[Open a port](#open-a-port). Connections from rama to itself, outbound
connections, ping, and `rama.local` name lookups need no rule.

### Set up a client

The key is already listed in `private_dot_ssh/private_authorized_keys`, so a
new client needs only its own copy of the private half. Nothing changes on
rama.

On the client, save the private key from the `id_ed25519_rama` item in
1Password to `~/.ssh/id_ed25519_rama`. 1Password hands the key over without a
passphrase, so give the copy one:

```bash
chmod 600 ~/.ssh/id_ed25519_rama
ssh-keygen -p -f ~/.ssh/id_ed25519_rama
```

Add an entry to the client's `~/.ssh/config`. `UseKeychain` is for a Mac, and
stores the passphrase in the Keychain so commands run without a prompt; leave
it out elsewhere.

```
Host rama
  HostName rama.local
  User james
  IdentityFile ~/.ssh/id_ed25519_rama
  IdentitiesOnly yes
  ForwardAgent no
  AddKeysToAgent yes
  UseKeychain yes
```

Check from the client: `ssh rama 'ruby -v'` prints mise's Ruby.

### Replace the key

Every client shares the one key, so replacing it locks all of them out until
each has the new private half.

Make the new key on any machine. `ssh-keygen` asks for a passphrase; give it
one.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_rama -C id_ed25519_rama
```

Replace the private key in the `id_ed25519_rama` item in 1Password. In a
checkout of this repo, delete the old key line from
`private_dot_ssh/private_authorized_keys`, then add the new one and push:

```bash
printf 'restrict,pty %s\n' "$(cat ~/.ssh/id_ed25519_rama.pub)" \
  >> private_dot_ssh/private_authorized_keys
git commit private_dot_ssh/private_authorized_keys -m "Replace rama's SSH key"
git push
```

On rama, run `chezmoi update`, at the machine or over a session that is
already open, because the old key stops working once its line is gone. Then
repeat [Set up a client](#set-up-a-client) on each client.

### Revoke the key

Delete its line from `private_dot_ssh/private_authorized_keys` and run
`chezmoi apply`. sshd reads the file on every login, so the key stops working
at once, on every client. A session the key already opened stays open:
`loginctl list-sessions` lists them and `sudo loginctl terminate-session ID`
ends one.

### Open a port

Add a line to `ufw-rules.txt`, then `chezmoi apply`. A line is the arguments to
`ufw`:

```
allow from 192.168.0.0/16 to any port 3000 proto tcp
```

`sudo ufw status` shows the rules in force. For a port needed once, run `sudo
ufw allow ...` by hand and delete the rule afterwards.

### Close a port

Delete the line from `ufw-rules.txt`, then remove the rule by hand: `sudo ufw
status numbered` lists the rules, and `sudo ufw delete N` removes one. Script
10 adds rules and never removes them.

### Change sshd's settings

Edit `sshd-rama.conf`, then `chezmoi apply`. Script 09 installs the file,
checks it with `sshd -t`, and checks with `sshd -T` that passwords are still
off. If either check fails it puts the previous file back and fails the apply.
An edit made directly in `/etc/ssh/sshd_config.d/00-rama.conf` lasts until the
next apply that runs the script.

## Scripts

chezmoi runs these in order during `chezmoi apply`. Each is `run_onchange_`: it
runs again only when its rendered content changes.

| Script | What it does | Re-runs when |
| --- | --- | --- |
| `before_00_set_host_name` | `hostnamectl set-hostname`, and fixes `/etc/hosts` | the host name answer changes |
| `before_01_apt_install` | Installs the missing packages from `apt-packages.txt`, upgrading none; checks sshd is running | `apt-packages.txt` changes |
| `before_02_set_login_shell` | Makes zsh the login shell | the script changes |
| `before_03_vendor_apt_repositories` | Registers ten vendor apt repositories and installs their packages; adds the user to the `docker` group | the script changes |
| `after_04_mise_install` | `mise install`, then verifies nothing declared is missing | the mise config changes |
| `after_05_vscode_extensions` | Installs the missing extensions from `vscode-extensions.txt` | `vscode-extensions.txt` changes |
| `after_06_snap_install` | Installs the missing snaps from `snap-packages.txt`; skips itself where snapd is not running | `snap-packages.txt` changes |
| `after_07_terminal_font` | Rebuilds the font cache and sets the Ptyxis font to MesloLGS NF; fails outside a desktop session, so a later apply retries | the script changes |
| `after_08_hide_zfs_member` | Installs a udev rule that makes udisks ignore ZFS pool members, so the dock and Files stop listing the root pool as an unmountable `rpool` volume | the script changes |
| `after_09_sshd_lockdown` | Installs `sshd-rama.conf` as an sshd drop-in, checks it with `sshd -t` and `sshd -T`, rolls it back if either fails, and reloads sshd; fails on a key line without `restrict` | `sshd-rama.conf` or the key file changes |
| `after_10_firewall` | Blocks inbound connections with ufw, adds the rules in `ufw-rules.txt`, and enables the firewall; skips itself where ufw cannot run | `ufw-rules.txt` changes |
| `after_11_dock` | Sets the dock's pinned launchers to `dock-favorites.txt` and its settings to `dock-settings.txt`, resetting every other dock setting to its default; fails outside a desktop session, so a later apply retries | either list changes |
| `after_12_mouse_scroll` | Turns on natural scrolling for the mouse wheel; skips itself where GNOME is not installed, and fails outside a desktop session, so a later apply retries | the script changes |

`before_` scripts run before chezmoi writes any file; `after_` scripts run
after, because script 04 reads `~/.config/mise/config.toml` and script 09
needs `~/.ssh/authorized_keys` in place before it turns passwords off.

## Playbooks

Install a package or tool. Check the sources in order:

1. `apt-cache policy name`. If Ubuntu has a usable version, add the name to
   `apt-packages.txt`.
2. If the vendor publishes an apt repository, add an `add_repository` line and
   the package name to script 03.
3. Otherwise add it to `dot_config/mise/config.toml`. `mise registry | grep
   name` shows whether mise knows it.
4. For a GUI application that none of those has, add it to
   `snap-packages.txt`. `snap info name` shows who publishes the snap.

Then `chezmoi apply`.

Remove one: delete the line, then uninstall by hand (`sudo apt-get remove
name`, `mise uninstall name`, or `sudo snap remove name`). No script
uninstalls.

Upgrade a language version: edit the version in
`dot_config/mise/config.toml`, then `chezmoi apply`.

Test on a Ruby that is not installed: `mise install ruby@3.3`. It installs
beside the others and changes no default. See the note on `mise prune` under
[Updates](#updates).

Install a VS Code extension: add its id to `vscode-extensions.txt`, then
`chezmoi apply`.

Change the dock: pin, unpin, or reorder in the dock itself, and change its
settings in Settings > Ubuntu Desktop > Dock. Then run `dock-capture`, which
rewrites `dock-favorites.txt` and `dock-settings.txt` from the live dock, and
commit. `chezmoi status` does not report a dock changed by hand, and the next
apply that runs script 11 puts the dock back the way the lists have it.
Editing the lists and running `chezmoi apply` works too.

Add a dock icon for a web page: copy
`dot_local/share/private_applications/glinet.desktop` under a new name and
change `Name`, the URL in `Exec`, `Icon`, and `StartupWMClass`. Put a PNG icon
named after the `Icon` value in `dot_local/share/icons/hicolor/SIZE/apps/`,
where `SIZE` is the image's size, such as `256x256`. Add the launcher's file
name to `dock-favorites.txt`, then `chezmoi apply`.

Update everything: `topgrade`. See [Updates](#updates).

## Updates

Three things change the packages on rama, and each has one job.

| | What it does | When |
| --- | --- | --- |
| `chezmoi apply` | Installs what is in the lists and missing from the machine | When a list changed |
| `topgrade` | Upgrades everything already installed | When you run it |
| Ubuntu's `unattended-upgrades` | Installs security updates | Daily, with no action from you |

**chezmoi installs and never upgrades.** Both apt scripts pass `--no-upgrade`,
and the extension and snap scripts skip what is installed, so adding one item
to a list never upgrades the others as a side effect. If a list has not changed, its
script does not run.

**chezmoi never uninstalls.** Deleting a line from a list leaves the package on
the machine. Remove it by hand.

**topgrade is the upgrade path.** [dot_config/topgrade.toml](dot_config/topgrade.toml)
limits it to these steps:

- `system`: `apt update`, `apt dist-upgrade`, `apt clean`, and `apt
  autoremove`. This covers Ubuntu's archive and every vendor repository, so
  everything script 03 installs, mise itself included, upgrades here. It asks
  for the sudo password. The `autoremove` comes from `cleanup =
  true` and removes packages that were installed only as dependencies and are
  no longer needed.
- `mise`: `mise upgrade` and `mise prune`. The upgrade moves tools set to
  `latest` forward. Runtimes pinned to an exact version do not move.
- `vscode`: updates the extensions.
- `chezmoi`: pulls this repo and applies it.
- `shell` and `github_cli_extensions`.

**`mise prune` deletes versions no config refers to.** A Ruby installed by hand
for one test run, with `mise install ruby@3.3`, is removed the next time
topgrade runs. To keep one, add it to the mise config.

**`unattended-upgrades` covers security fixes between topgrade runs.** Ubuntu
enables it by default. It applies security updates from Ubuntu's own archive
only: not regular updates, and not vendor repositories. Those wait for
topgrade.

**Snaps are not topgrade's job.** snapd refreshes them itself, several times a
day.

**Nothing here moves rama to the next Ubuntu release.** 26.10 is an interim
release, supported for nine months, until about July 2027. Before then, move
to 27.04 with `sudo do-release-upgrade`, run by hand.

## Differences from neuromancer-config

| | neuromancer (macOS) | rama (Ubuntu) |
| --- | --- | --- |
| System packages and most tools | Homebrew | apt |
| Language runtimes | asdf, `.tool-versions` | mise, `config.toml` |
| VS Code extensions | Brewfile `vscode` lines | `vscode-extensions.txt` |
| powerlevel10k | Homebrew formula | git checkout kept by chezmoi |
| Claude Code | Homebrew cask | Anthropic's apt repository |
| 1Password, Chrome, Slack, Warp, Typora | Homebrew casks | each vendor's apt repository |
| Docker | Docker Desktop, a Homebrew cask | Docker Engine, from Docker's apt repository |
| `PATH` setup | `.zprofile` | `.zshenv`, because of ssh |

Not carried over, because they are macOS-only:

- App Store apps, and every cask not named in the table above.
- The OpenJDK link script (Java comes from apt's `default-jdk`), the Amphetamine
  Power Protect script, and the Warp quarantine script.
- `scutil`, `plutil`, `xcrun`, `path_helper`, `java_home`, and the Amazon Q
  blocks in the shell files.
- The `sophon` and Proxmox entries in the ssh config. Their keys live on the
  Mac.

No PostgreSQL server: the Mac has `postgresql@17`, and rama has only `libpq-dev`,
the headers the `pg` gem builds against.

## Not done yet

- **A run on rama.** The container test was arm64, because Docker's x86_64
  emulation on an Apple silicon Mac cannot extract tar files under Ubuntu
  26.04. One arm64-only failure turned up (`checkov`, now fixed); an
  x86_64-only failure is possible and would show on rama. The container has no
  systemd either, so the host name and sshd steps skipped themselves. Both run
  for the first time on rama.
- **A certification script.** The container test was run by hand. To repeat
  it: start an `ubuntu:26.04` container, create a non-root user with
  passwordless sudo, copy this repo to `~/.local/share/chezmoi`, and run step 2
  of [Rebuild from nothing](#rebuild-from-nothing) with
  `init --apply --promptString "Host name=rama"` and no repo name.
- **A real topgrade run.** `topgrade --dry-run` in the container printed the
  commands listed under [Updates](#updates). It has not been run for real.
- **GitHub rate limits.** mise asks the GitHub API for release information.
  The container run did not hit the unauthenticated limit. If a rebuild does,
  set `GITHUB_TOKEN` and run `chezmoi apply` again.
- **An install of the amd64-only packages.** The 1Password app, Chrome, and
  Slack cannot be installed in the arm64 container. Their repositories and
  signing keys were checked there, with the architecture forced to amd64, and
  nothing more. Script 03 as a whole was run with the installs simulated.
- **A snap install.** The container has no snapd, so script 06 has only run
  there with a stand-in `snap` command.
- **More GUI applications.** VS Code, 1Password, Chrome, Slack, Warp, and
  Typora are installed. Zoom, Discord, Synology Drive, and GitButler publish a
  deb with no apt repository; each needs a source chosen (snap, or a pinned
  download) and recorded here.
