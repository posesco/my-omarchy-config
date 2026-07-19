# My Omarchy Config

Personal Omarchy configuration, optional packages, and secure secret management via AWS SSM Parameter Store.

## Project Structure

```
├── dotfiles/          # Config files linked to ~/.config/ and ~/.local/bin/
├── lib/               # Runtime, config, model, and module installer logic
├── tests/             # Isolated, non-network installer regression tests
├── terraform/         # Terraform code to provision secrets in AWS SSM Parameter Store
├── install.sh         # Thin CLI entry point and module loader
├── models.conf        # Local model metadata registry
├── .gitignore
└── README.md
```

## Secret Management (AWS SSM)

To avoid committing plaintext secrets to Git, we use AWS SSM Parameter Store.

1.  Copy the example variables file:
    ```bash
    cp terraform/terraform.tfvars.example terraform/terraform.tfvars
    ```
2.  Edit `terraform/terraform.tfvars` with your real secret values (this file is git-ignored).
3.  Initialize and apply the Terraform configuration:
    ```bash
    cd terraform
    terraform init
    terraform apply
    ```
4.  Create a `.template` file in `dotfiles/` (e.g. `dotfiles/gentle-ai/config.json.template`).
5.  Use the `{{SSM:path/to/secret}}` marker to reference keys defined in Terraform. The `install.sh` script resolves secrets at runtime and generates the final file locally without compromising the repository.

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

The installer prints the exact backup path when it creates one. Existing `.bashrc` content is also backed up before the aliases source line is added.

Executable import, install, and model workflows also write a color-free diagnostic log to a unique file under `$XDG_STATE_HOME/my-omarchy-config/logs/`, or under `$HOME/.local/state/my-omarchy-config/logs/` when `XDG_STATE_HOME` is empty or relative. Log directories use mode `0700` and log files use mode `0600`; sourcing the installer and displaying help do not create logs.

The installer is split by responsibility: `lib/runtime.sh` owns state, logging, and final status; `lib/config.sh` owns backups, templates, links, and imports; `lib/models.sh` owns model downloads; and `lib/modules.sh` owns the package/config wizard.

Safe, noninteractive verification:

```bash
bash -n install.sh lib/*.sh models.conf tests/*.sh
./tests/run.sh
```
