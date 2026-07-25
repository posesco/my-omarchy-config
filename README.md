# My Omarchy Config

Personal Omarchy configuration, binaries, and optional workstation setup.

## Project Structure

```
├── dotfiles/          # Config files linked to ~/.config/ and ~/.local/bin/
├── lib/               # Runtime, config, Samba, and module installer logic
├── system/            # Files for explicit privileged system modules
├── tests/             # Isolated, non-network installer regression tests
├── install.sh         # Thin CLI entry point and module loader
├── .gitignore
└── README.md
```

## Usage

### Import existing local configs into the repository (initial setup)
```bash
./install.sh --import
```

Existing repository destinations are backed up before import. If a local config is already a symlink to the same repository destination, it is skipped to avoid replacing its own source.

### Run the interactive installation and configuration wizard
```bash
./install.sh --install
```

Configuration targets are linked from this repository using paths derived from `$HOME`. Before an existing file, directory, or symlink is replaced, the previous target is copied to a unique timestamped directory under `$XDG_STATE_HOME/my-omarchy-config/backups/` when `XDG_STATE_HOME` is absolute, or otherwise under:

```text
$HOME/.local/state/my-omarchy-config/backups/
```

The installer prints the exact backup path when it creates one.

Executable import and install workflows also write a color-free diagnostic log to a unique file under `$XDG_STATE_HOME/my-omarchy-config/logs/`, or under `$HOME/.local/state/my-omarchy-config/logs/` when `XDG_STATE_HOME` is empty or relative. Log directories use mode `0700` and log files use mode `0600`; sourcing the installer and displaying help do not create logs.

The installer is split by responsibility: `lib/runtime.sh` owns state, logging, and final status; `lib/config.sh` owns backups, links, and imports; `lib/samba.sh` owns privileged Samba setup; and `lib/modules.sh` owns the package/config wizard.

## Personal Artifacts

Select **Personal Binaries and Llama Server Config** to link these repository-owned files:

| Repository path | Local target |
|---|---|
| `dotfiles/bin/llm` | `~/.local/bin/llm` |
| `dotfiles/bin/openweb` | `~/.local/bin/openweb` |
| `dotfiles/bin/screen-posesco` | `~/.local/bin/screen-posesco` |
| `dotfiles/llama-server.conf` | `~/.config/llama-server.conf` |

The installer does not install Llama.cpp or manage local model files. The `llm` launcher expects the configured model file to be managed manually and exits with an error when that file is absent.

## Samba Module

Select **Samba (LAN-only pandastic share)** in the install wizard to configure the authenticated `pandastic` share at `/srv/pandastic` for the dedicated non-login user `mordecai`. The module installs Samba and UFW when missing, keeps `smb` and `nmb` discovery, and retains Apple `fruit` interoperability for iPhone alongside modern Windows SMB support.

The security boundary is enforced twice: `smb.conf` denies hosts outside `192.168.1.0/24`, and UFW receives only subnet-scoped rules for UDP 137-138 and TCP 139/445. Exact broad `Anywhere` rules from the old setup are reported and removed. UFW is not enabled automatically; when it is inactive, the installer warns after preparing the rules.

The module validates a temporary candidate with `testparm` before replacing `/etc/samba/smb.conf`. Existing configuration is backed up beside the live file, deployment uses an atomic rename with owner `root:root` and mode `0644`, and validation or service failures restore the previous file when practical. The share root receives owner `mordecai` and mode `0770` without recursively changing existing content; new files use `0660` and directories use `0770`.

On the first run only, `smbpasswd` prompts interactively when `mordecai` is absent from Samba passdb. The password is never stored, printed, logged, or passed as a command argument. Reruns skip completed state. Rollback restores Samba configuration and prior service state, but intentionally leaves the restricted share root, account, packages, passdb enrollment, and safer firewall rules in place. An existing interactive `mordecai` account, unavailable firewall state, or missing required tools stops the module safely.

Safe, noninteractive verification:

```bash
bash -n install.sh lib/*.sh tests/*.sh
./tests/run.sh
```
