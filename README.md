# rama-config

The configuration of `rama`, an x86_64 machine running Ubuntu 26.04 LTS
Desktop. It is managed by [chezmoi](https://www.chezmoi.io/).

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

## Rebuild from nothing

On a fresh Ubuntu 26.04 install:

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
the mise runtimes and tools, installs the VS Code extensions, and installs any
snaps listed.

The temporary chezmoi in `/tmp` is only for this first run. mise installs the
permanent one.

Run `sudo -v` first and never `sudo chezmoi apply`: chezmoi would write
root-owned files into the home directory. The scripts call `sudo` themselves
where they need it.

Afterwards, by hand:

1. Add the public keys of the machines that will drive rama to
   `~/.ssh/authorized_keys`.
2. Log out and back in so the login shell change and the `docker` group
   membership take effect.
3. Run `claude` and `gh auth login` to sign in to each.

## What installs what

| What | Source | Declared in |
| --- | --- | --- |
| Compilers, libraries, services, zsh, sshd, and every tool Ubuntu carries | apt, Ubuntu archive | [apt-packages.txt](apt-packages.txt) |
| VS Code, `gh`, the 1Password app and CLI, Claude Code, mise, Chrome, Slack, Warp, Typora, Docker Engine | apt, vendor repositories | script `before_03_vendor_apt_repositories` |
| Ruby, Node, Python, Go, Rust | mise | [dot_config/mise/config.toml](dot_config/mise/config.toml) |
| Command-line tools with no apt package, including chezmoi and topgrade | mise | the same file |
| VS Code extensions | `code --install-extension` | [vscode-extensions.txt](vscode-extensions.txt) |
| GUI applications with no apt source | snap | [snap-packages.txt](snap-packages.txt), empty so far |
| The powerlevel10k zsh theme, and the `jcouball/scripts` utilities | git checkouts kept by chezmoi | [.chezmoiexternal.toml](.chezmoiexternal.toml) |
| The MesloLGS NF font the prompt needs | files downloaded once by chezmoi | [.chezmoiexternal.toml](.chezmoiexternal.toml) |
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

`before_` scripts run before chezmoi writes any file; `after_` scripts run
after, because script 04 reads `~/.config/mise/config.toml`.

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

**Nothing here moves rama to the next Ubuntu release.** Going from 26.04 to
28.04 is `sudo do-release-upgrade`, run by hand.

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

Different versions: apt provides PostgreSQL 18 and Redis 8.0, where the Mac has
`postgresql@17`.

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
- **A snap install.** `snap-packages.txt` is empty and the container has no
  snapd, so script 06 has only run with a stand-in `snap` command.
- **More GUI applications.** VS Code, 1Password, Chrome, Slack, Warp, and
  Typora are installed. Zoom, Discord, Synology Drive, and GitButler publish a
  deb with no apt repository; each needs a source chosen (snap, or a pinned
  download) and recorded here.
