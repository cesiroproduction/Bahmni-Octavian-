# manage_patches.sh

This script syncs patch files between Bahmni Docker containers and your local patches directory. It helps copy, update, and clean config/frontend files for Bahmni modules.

## Usage

```
./manage_patches.sh <step> <module_name|all> [options]
```

- `<step>`: What to do (see below)
- `<module_name>`: One of the supported modules or `all`
- `[options]`: See below

## Steps

- `copy_all`    — Copy all files from container to local patches
- `copy_json`   — Copy only *.json files from container to local patches
- `replace`     — Copy files from local patches to container (skips ignored and *.incoming files)
- `clean`       — Remove *.incoming files from local patch folder

## Supported Modules

- bahmni-config
- bahmni-web
- bahmni-apps-frontend
- appointments
- microfrontend-ipd
- all

## Options

- `-d`, `--dry-run`       — Show what would change, make no changes
- `--show-ignored`        — Print ignored files while scanning
- `-h`, `--help`          — Show help

## Ignore Patterns

Patterns in `.bahmniignore` control which files are skipped during sync.

## Example

```
./manage_patches.sh copy_json bahmni-web --dry-run
```

Shows which JSON files would be copied from the container to local patches for the `bahmni-web` module, without making changes.

## Requirements

- Docker
- find
- mktemp
- cmp
