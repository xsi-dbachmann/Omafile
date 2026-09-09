#!/usr/bin/env bash
# Install omafile for development by symlinking this repo into the Omarchy
# plugins directory.
#
# Symlinking the plugin *directory itself* is the sanctioned development
# workflow: omarchy-plugin-validate refuses symlinks INSIDE a plugin folder,
# but omarchy-plugin-catalog walks the plugins directory with `find -L` and
# omarchy-plugin-remove has an explicit "Unlink" branch. (Ticket 02.)
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plugin_id="io.github.xsi-dbachmann.omafile"
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
plugin_home="$config_home/omarchy/plugins"
install_path="$plugin_home/$plugin_id"
# Backups must live OUTSIDE the plugins directory: Omarchy scans every
# subdirectory of it for a manifest, so a backup left alongside the install is
# a second plugin with the same id.
backup_home="$config_home/omarchy/plugin-backups"
restart_shell=true

usage() { printf 'Usage: %s [--no-restart]\n' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-restart) restart_shell=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

command -v omarchy >/dev/null 2>&1 || {
  printf '%s\n' 'omarchy is required to install this plugin.' >&2
  exit 1
}

printf '%s\n' 'Validating plugin…'
omarchy plugin validate "$project_dir"

mkdir -p "$plugin_home"
if [[ -L "$install_path" && "$(readlink -f "$install_path")" == "$project_dir" ]]; then
  printf '%s\n' 'Already linked.'
elif [[ -e "$install_path" || -L "$install_path" ]]; then
  mkdir -p "$backup_home"
  backup_path="$backup_home/$plugin_id.bak.$(date +%Y%m%d%H%M%S)"
  mv "$install_path" "$backup_path"
  printf 'Backed up the previous install to %s\n' "$backup_path"
  ln -s "$project_dir" "$install_path"
else
  ln -s "$project_dir" "$install_path"
fi

if $restart_shell; then
  printf '%s\n' 'Restarting Omarchy shell…'
  omarchy restart shell
fi

omarchy-shell shell rescanPlugins

printf 'omafile linked at %s\n' "$install_path"
printf '%s\n' 'Open it with:  omarchy-shell shell summon io.github.xsi-dbachmann.omafile "{}"'
printf '%s\n' 'QML edits are read through the symlink; re-summon to pick them up.'
