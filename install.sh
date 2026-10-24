#!/usr/bin/env bash
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
qs_dir="${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/roseclip"
cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/roseclip"

# qml files -> quickshell
mkdir -p "$qs_dir"
for f in shell.qml config.js search.js; do
  install -Dm644 "$src/$f" "$qs_dir/$f"
done

# seed config only if absent
mkdir -p "$cfg_dir"
if [ ! -f "$cfg_dir/config.toml" ]; then
  install -Dm644 "$src/config.toml" "$cfg_dir/config.toml"
  echo "seeded $cfg_dir/config.toml"
else
  echo "kept existing $cfg_dir/config.toml"
fi

echo "installed to $qs_dir"
echo "run: qs -c roseclip"