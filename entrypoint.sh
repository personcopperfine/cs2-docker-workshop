#!/bin/bash
# =============================================================================
# CS2 workshop image entrypoint (wine, no Steam client)
#
# Usage:  entrypoint.sh <program> [args...]
#
#   <program> is a shorthand name of an .exe that lives under $GAME_DIR/game
#     (e.g. cs2.exe), or a path to one (unix or windows style). Only .exe
#     files found in $GAME_DIR/game can be launched; everything else exits 1.
#
#   All arguments after <program> are passed through to the exe:
#     - a path argument (leading / or containing \) is converted to a unix
#       path, checked against $GAME_DIR/game if it is an .exe, and
#       re-converted to a windows path with winepath;
#     - anything else is passed through unchanged.
# =============================================================================
set -euo pipefail

# Self-locate: the script lives at the root of the game tree, so that root
# is GAME_DIR unless overridden (keeps everything relative for scratch images).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export GAME_DIR="${GAME_DIR:-$SCRIPT_DIR}"
# Only CS2 game files are available to launch (wine's own exes in
# $GAME_DIR/files are excluded on purpose).
STEAM_APP_ID="${STEAM_APP_ID:-730}"
GAME_GAME_DIR="$GAME_DIR/game"
WINE_BIN="$GAME_DIR/files/lib/wine/x86_64-unix"
WINE_PRELOADER="$WINE_BIN/wine-preloader"
WINE="$WINE_BIN/wine"

log() { echo "[cs2-workshop] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[ -x "$WINE_PRELOADER" ] || die "wine-preloader not found at $WINE_PRELOADER"
[ -d "$GAME_GAME_DIR/bin/win64" ] || die "game dir not found at $GAME_GAME_DIR"

export WINEPREFIX="${WINEPREFIX:-$GAME_DIR/compatdata/$STEAM_APP_ID/pfx}"
# Wine's runtime env lives here (no wine ENVs are baked into the image):
# derive everything from $GAME_DIR, each overridable.
export PATH="${GAME_DIR}/files/bin:${PATH}"
export WINEDLLPATH="${WINEDLLPATH:-${GAME_DIR}/files/lib/vkd3d:${GAME_DIR}/files/lib/wine}"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+${LD_LIBRARY_PATH}:}${GAME_DIR}/files/lib/x86_64-linux-gnu:${GAME_DIR}/files/lib/aarch64-linux-gnu:${GAME_DIR}/files/lib/i386-linux-gnu"
export GST_PLUGIN_SYSTEM_PATH_1_0="${GST_PLUGIN_SYSTEM_PATH_1_0:-${GAME_DIR}/files/lib/x86_64-linux-gnu/gstreamer-1.0:${GAME_DIR}/files/lib/i386-linux-gnu/gstreamer-1.0}"
export WINE_GST_REGISTRY_DIR="${WINE_GST_REGISTRY_DIR:-$GAME_DIR/compatdata/$STEAM_APP_ID/gstreamer-1.0}"
export ESPEAK_DATA_PATH="${ESPEAK_DATA_PATH:-${GAME_DIR}/files/share}"
# launch via wine-preloader directly (no start.exe restart)
export WINELOADERNOEXEC="${WINELOADERNOEXEC:-1}"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-steam.exe=b;dotnetfx35.exe=b;dotnetfx35setup.exe=b;beclient.dll=b,n;beclient_x64.dll=b,n;winebth.sys=d;opencl=n,d;d3d11=n;d3d10core=n;d3d9=n;dxgi=n;d3d12=n;d3d12core=n;nvapi64=n;nvofapi64=n;nvapi=n;nvcuda=b}"
export DXVK_LOG_LEVEL="${DXVK_LOG_LEVEL:-none}"
export VKD3D_DEBUG="${VKD3D_DEBUG:-none}"
export VKD3D_SHADER_DEBUG="${VKD3D_SHADER_DEBUG:-none}"
export WINEFSYNC="${WINEFSYNC:-1}"
export WINE_LARGE_ADDRESS_AWARE="${WINE_LARGE_ADDRESS_AWARE:-1}"
export __GLVND_DISALLOW_PATCHING="${__GLVND_DISALLOW_PATCHING:-1}"
export PROTON_USE_XALIA="${PROTON_USE_XALIA:-1}"
export XALIA_SUPPORTED_ONLY="${XALIA_SUPPORTED_ONLY:-1}"
export DXVK_ENABLE_NVAPI="${DXVK_ENABLE_NVAPI:-0}"

# --- fake Steam library layout (for CS2ResourceCompiler's GetCS2Dir()) ----
# The GUI reads HKCU\Software\Valve\Steam "SteamPath" (HKCU = user.reg), then
# requires <SteamPath>\steamapps\common\Counter-Strike Global Offensive\game\bin\win64.
# steamapps/common/<game> links back to $GAME_DIR so the app's path math lands
# on the real layout. Idempotent.
game_win="Z:$GAME_DIR"; game_win=${game_win//\//\\}
mkdir -p "$GAME_DIR/steamapps/common"
ln -sfn ../.. "$GAME_DIR/steamapps/common/Counter-Strike Global Offensive"
# The default prefix's user.reg already ships a [Software\Valve\Steam] key with
# SteamPath="C:\Program Files (x86)\Steam"; overwrite every SteamPath value.
# .reg files escape backslashes, so the file needs doubled ones; sed's
# replacement consumes one more level -> quadruple each backslash below.
touch "$WINEPREFIX/user.reg"
game_win_esc=${game_win//\\/\\\\\\\\}
sed -i "s|\"SteamPath\"[[:space:]]*=.*|\"SteamPath\"=\"$game_win_esc\"|g" "$WINEPREFIX/user.reg"

# --- parse arguments ---------------------------------------------------------
if [ $# -lt 1 ]; then
    log "usage: entrypoint.sh <program.exe> [args...]"
    log "available programs in ${GAME_GAME_DIR}:"
    find "$GAME_GAME_DIR" -type f -name '*.exe' | sort | sed 's/^/  /' >&2
    exit 1
fi

prog="$1"; shift
args=()
for a in "$@"; do
    case "$a" in
        /*|*\\*)
            # path-shaped argument: resolve to unix form, then back to a
            # canonical windows form for wine.
            u=$("$WINE_PRELOADER" "$WINE" winepath -u -- "$a") \
                || die "winepath: cannot resolve argument path '$a'"
            case "$u" in
                *.exe)
                    # only game .exe files inside $GAME_GAME_DIR may be used
                    real=$(realpath -m -- "$u")
                    case "$real" in
                        "$GAME_GAME_DIR"/*/*.exe) ;;
                        *) die "program '$a' resolves to '$u', outside ${GAME_GAME_DIR} (only .exe files found in ${GAME_GAME_DIR} can be used)" ;;
                    esac
                    ;;
            esac
            args+=("$("$WINE_PRELOADER" "$WINE" winepath -w -- "$u")")
            ;;
        *)
            args+=("$a")
            ;;
    esac
done

# --- resolve the program -----------------------------------------------------
case "$prog" in
    /*|*\\*)
        # given as a path: convert to unix form and verify it's an exe inside $GAME_DIR.
        u=$("$WINE_PRELOADER" "$WINE" winepath -u -- "$prog") \
            || die "winepath: cannot resolve program path '$prog'"
        real=$(realpath -m -- "$u")
        case "$real" in
            "$GAME_GAME_DIR"/*/*.exe) ;;
            *) die "program '$prog' resolves to '$u', outside ${GAME_GAME_DIR} (only .exe files found in ${GAME_GAME_DIR} can be used)" ;;
        esac
        exe="$u"
        ;;
    *[\*\?\[]*)
        die "program name '${prog}' must not contain glob characters"
        ;;
    *.exe)
        # shorthand: search $GAME_GAME_DIR for an exact basename match.
        matches=$(find "$GAME_GAME_DIR" -type f -name "${prog}" | sort) || true
        [ -n "$matches" ] || die "no .exe named '${prog}' found in ${GAME_GAME_DIR}"
        count=$(printf '%s\n' "$matches" | wc -l)
        [ "$count" -eq 1 ] || { log "ambiguous name '${prog}':"; printf '%s\n' "$matches" >&2; exit 1; }
        exe="$matches"
        ;;
    *)
        die "program '${prog}' is not an .exe (only .exe files found in ${GAME_GAME_DIR} can be used)"
        ;;
esac

log "launching $exe with wine ($((${#args[@]})) args)"
exec "$WINE_PRELOADER" "$WINE" "$("$WINE_PRELOADER" "$WINE" winepath -w -- "$exe")" "${args[@]}"
