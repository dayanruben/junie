# Junie installer templates

This directory is the single source of truth for the `install.sh` / `install.ps1`
scripts that live in the repository root. The root scripts are **generated** —
do not edit them directly.

## Workflow

1. Edit a template or a shim:
   - `install.sh.template` — Bash installer
   - `install.ps1.template` — PowerShell installer
   - `junie.shim.sh` — Bash shim inlined into every `install*.sh`
   - `junie.shim.bat` — Windows `.bat` shim inlined into every `install*.ps1`
2. Edit `channels.tsv` if you need to add/remove a channel.
3. Regenerate the root scripts:
   ```sh
   ./templates/generate.sh
   ```
4. Verify the result is clean and idempotent:
   ```sh
   ./templates/generate.sh --check
   ```
5. Commit the templates and the regenerated root scripts together.

## Files

| File                    | Purpose                                                    |
|-------------------------|------------------------------------------------------------|
| `channels.tsv`          | `name<TAB>update_info_url` rows (one per channel)          |
| `install.sh.template`   | Bash installer template with `{{CHANNEL}}`, `{{UPDATE_INFO_URL}}`, `{{SHIM}}` placeholders |
| `install.ps1.template`  | PowerShell installer template with the same placeholders   |
| `junie.shim.sh`         | Bash shim body (verbatim, no escaping)                     |
| `junie.shim.bat`        | Windows `.bat` shim body (verbatim, no escaping)           |
| `generate.sh`           | Regenerates `install*.sh` and `install*.ps1` in the repo root |

## Output layout

For each row in `channels.tsv`:

- `release`      → `install.sh`, `install.ps1`
- `<name>` else → `install-<name>.sh`, `install-<name>.ps1`
