#!/bin/zsh
set -euo pipefail
setopt NULL_GLOB

if (( $# != 3 )); then
  print -u2 "Usage: steam-play-launch.sh APP_ID GAME_DIRECTORY EXECUTABLE"
  exit 2
fi

app_id="$1"
game_name="$2"
game_exe="$3"
[[ "$app_id" == <-> ]] || exit 2
[[ "$game_name" != *'/'* && "$game_name" != *'\\'* && "$game_name" != '.' && "$game_name" != '..' ]] || exit 2
[[ "$game_exe" =~ '^[A-Za-z0-9 ._()-]+\.exe$' ]] || exit 2

steam_common="${0:A:h:h}"
game_dir="$steam_common/$game_name"
[[ -f "$game_dir/$game_exe" ]] || { print -u2 "Game executable is missing: $game_dir/$game_exe"; exit 3; }

support="$HOME/Library/Application Support/WinLauncher"
prefix="$support/Environments/default/prefix"
engine_candidates=("$support"/Engines/*/WineForgeCore/bin/wine(N))
(( ${#engine_candidates} > 0 )) || { print -u2 "WineForge is not installed"; exit 4; }
wine="${engine_candidates[-1]}"
engine_root="${wine:h:h}"

steam_games="$prefix/drive_c/users/Public/WinLauncher/SteamGames"
mkdir -p "$steam_games"
game_link="$steam_games/$app_id"
if [[ -L "$game_link" ]]; then
  [[ "$(readlink "$game_link")" == "$game_dir" ]] || unlink "$game_link"
elif [[ -e "$game_link" ]]; then
  print -u2 "Steam game mapping is occupied: $game_link"
  exit 5
fi
[[ -L "$game_link" ]] || ln -s "$game_dir" "$game_link"

export WINEPREFIX="$prefix"
export WINEDEBUG="err+all"
export WINEDLLOVERRIDES="dxgi,d3d10,d3d10core,d3d11,winemetal=b"
export WINEESYNC=1
export WINEMSYNC=1
export LC_ALL=C
export SteamAppId="$app_id"
export SteamGameId="$app_id"
export PATH="${wine:h}:/usr/bin:/bin:/usr/sbin:/sbin"
export DYLD_FALLBACK_LIBRARY_PATH="$engine_root/lib"
if [[ -d "$engine_root/lib/dxmt" ]]; then
  export GRAPHICS_BACKEND=dxmt
  export DXMT_RUNTIME_DIR="$engine_root/lib/dxmt"
  export DXMT_CEF_RUNTIME_DIR="$engine_root/lib/dxmt"
fi
if [[ -d "$engine_root/lib/gstreamer-1.0" ]]; then
  export GST_PLUGIN_PATH="$engine_root/lib/gstreamer-1.0"
  export GST_PLUGIN_SYSTEM_PATH="$engine_root/lib/gstreamer-1.0"
fi

cd "$game_dir"
exec "$wine" cmd /c "cd /d C:\\users\\Public\\WinLauncher\\SteamGames\\$app_id & $game_exe"
