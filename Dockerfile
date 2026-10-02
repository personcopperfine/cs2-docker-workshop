### SteamCMD Install ###
FROM registry.gitlab.steamos.cloud/steamrt/steamrt4/sdk as steamcmd
# stage https://github.com/steamcmd/docker under MIT
#
# MIT License
#
# Copyright (c) 2020 Jona Koudijs
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

ENV USER root
ENV HOME /root

WORKDIR $HOME

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN echo steam steam/question select "I AGREE" | debconf-set-selections \
    && echo steam steam/license note '' | debconf-set-selections

RUN \
    DEBIAN_FRONTEND=noninteractive apt-get update \
    && apt-get install --yes --no-install-recommends --no-install-suggests steamcmd \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN ln -s /usr/games/steamcmd /usr/bin/steamcmd

RUN steamcmd +quit \
    && rm -rf $HOME/Steam/package $HOME/package

RUN mkdir -p $HOME/.steam \
    && ln -s $HOME/.local/share/Steam/steamcmd/linux32 $HOME/.steam/sdk32 \
    && ln -s $HOME/.local/share/Steam/steamcmd/linux64 $HOME/.steam/sdk64 \
    && ln -s $HOME/.steam/sdk32/steamclient.so $HOME/.steam/sdk32/steamservice.so \
    && ln -s $HOME/.steam/sdk64/steamclient.so $HOME/.steam/sdk64/steamservice.so

ENTRYPOINT ["steamcmd"]
CMD ["+help", "+quit"]

### CS2ResourceCompiler (windows build) ###
# https://github.com/dirtkiller23/CS2ResourceCompiler — .NET 4.8 WinForms,
# classic (non-SDK) csproj. Built on Linux with the dotnet SDK's MSBuild:
#   - net48 reference assemblies come from the Microsoft.NETFramework.ReferenceAssemblies
#     nuget package via FrameworkPathOverride (no Windows Developer Pack on Linux);
#   - GenerateResourceMSBuildRuntime/Architecture=Current* keeps resgen in-process
#     (the default x86 task host does not exist on a linux dotnet install).
FROM ubuntu:24.04 AS rescompilerbuilder

ARG RESCOMPILER_SHA=3adf6b99791da525dd9cbd47549801b56e408e31
ARG DOTNET_SDK_VERSION=8.0.416
ARG NETFRAMEWORK_REFASMS_VERSION=1.0.3

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
        wget ca-certificates git libicu74 unzip \
    && rm -rf /var/lib/apt/lists/*

# dotnet SDK (MSBuild) + net48 reference assemblies
RUN wget -qO /tmp/dotnet.tgz \
        "https://builds.dotnet.microsoft.com/dotnet/Sdk/${DOTNET_SDK_VERSION}/dotnet-sdk-${DOTNET_SDK_VERSION}-linux-x64.tar.gz" \
    && mkdir -p /usr/share/dotnet \
    && tar -xzf /tmp/dotnet.tgz -C /usr/share/dotnet \
    && ln -s /usr/share/dotnet/dotnet /usr/local/bin/dotnet \
    && rm -f /tmp/dotnet.tgz

RUN wget -qO /tmp/refasms.zip \
        "https://www.nuget.org/api/v2/package/Microsoft.NETFramework.ReferenceAssemblies.net48/${NETFRAMEWORK_REFASMS_VERSION}" \
    && mkdir -p /refasms \
    && unzip -q /tmp/refasms.zip -d /refasms \
    && rm -f /tmp/refasms.zip

WORKDIR /src
RUN git clone https://github.com/dirtkiller23/CS2ResourceCompiler . \
    && git checkout "${RESCOMPILER_SHA}" \
    && dotnet msbuild CS2MapCompiler.sln \
        -p:Configuration=Release \
        -p:FrameworkPathOverride=/refasms/build/.NETFramework/v4.8/ \
        -p:GenerateResourceMSBuildRuntime=CurrentRuntime \
        -p:GenerateResourceMSBuildArchitecture=CurrentArchitecture

# artifacts: /src/CS2MapCompiler/bin/Release/CS2MapCompiler{.exe,.exe.config} (WinForms net48, Windows PE)

FROM steamcmd AS gameinstall

# Steam credentials come from build secrets (never ARGs, which persist in image
# metadata): --secret id=steam_username,env=STEAM_USERNAME --secret id=steam_password,env=STEAM_PASSWORD
ARG PROTON="4628710"

# single root for all game + proton files; the final stage copies this tree
# into a scratch image, so nothing below hardcodes an absolute path.
ARG GAME_DIR=/app
ENV GAME_DIR="${GAME_DIR}"
ENV HOME "/home/steam"
ENV STEAM_APP_ID "730"

RUN mkdir -p /home/steam/.steam
WORKDIR /home/steam

RUN --mount=type=cache,target=/license \
    --mount=type=secret,id=steam_username,required=true \
    --mount=type=secret,id=steam_password,required=true \
    if [ ! -f /license/.done ]; then \
        steamcmd \
            +@sSteamCmdForcePlatformType linux \
            +login "$(cat /run/secrets/steam_username)" "$(cat /run/secrets/steam_password)" \
            +app_license_request "${PROTON}" \
            +quit \
        && touch /license/.done; \
    fi

# empty = latest public manifest; CI pins the gids it checked
ARG MANIFEST_2347779=""
ARG MANIFEST_2347771=""

RUN --mount=type=secret,id=steam_username,required=true \
    --mount=type=secret,id=steam_password,required=true \
    mkdir -p "${GAME_DIR}" \
    && steamcmd \
    +@sSteamCmdForcePlatformType windows \
    +force_install_dir "${GAME_DIR}/" \
    +login "$(cat /run/secrets/steam_username)" "$(cat /run/secrets/steam_password)" \
    # https://steamdb.info/depot/2347779/
    +download_depot "${STEAM_APP_ID}" 2347779 ${MANIFEST_2347779} \
    # https://steamdb.info/depot/2347771/
    +download_depot "${STEAM_APP_ID}" 2347771 ${MANIFEST_2347771} \
    +quit \
    && for dir in $(find "${HOME}" -type d -name "depot_[0-9]*"); do \
        echo "depot: ${dir}"; \
        rsync -a "${dir}/" "${GAME_DIR}" \
            --exclude='csgo_community_addons/' \
            --remove-source-files; \
      done

RUN --mount=type=secret,id=steam_username,required=true \
    --mount=type=secret,id=steam_password,required=true \
    steamcmd \
    +@sSteamCmdForcePlatformType linux \
    +force_install_dir "${GAME_DIR}/" \
    +login "$(cat /run/secrets/steam_username)" "$(cat /run/secrets/steam_password)" \
    # https://steamdb.info/app/4628710/
    +app_update "${PROTON}" \
    +quit

# CS2ResourceCompiler GUI; launch it as CS2MapCompiler.exe. It must sit next to
# Valve's own resourcecompiler.exe (which it runs), so never install it under that name.
COPY --from=rescompilerbuilder /src/CS2MapCompiler/bin/Release/CS2MapCompiler.exe \
    ${GAME_DIR}/game/bin/win64/CS2MapCompiler.exe
COPY --from=rescompilerbuilder /src/CS2MapCompiler/bin/Release/CS2MapCompiler.exe.config \
    ${GAME_DIR}/game/bin/win64/CS2MapCompiler.exe.config

### Proton environment emulation ###
# Emulates /usr/local/proton's setup (workshop/.extracted/proton) so CS2 runs without the Steam client.
FROM registry.gitlab.steamos.cloud/steamrt/steamrt4/sdk AS protonsetup

ARG GAME_DIR=/app
ENV STEAM_APP_ID "730"
ENV GAME_DIR="${GAME_DIR}"
ENV COMPATDATA="${GAME_DIR}/compatdata/${STEAM_APP_ID}"
ENV WINEPREFIX="${COMPATDATA}/pfx"

COPY --from=gameinstall ${GAME_DIR}/ ${GAME_DIR}/

# No wine ENVs here: entrypoint.sh derives the full runtime env
# (LD_LIBRARY_PATH, WINEDLLPATH, GST/espeak paths, PATH, ...) from $GAME_DIR.

# --- setup_prefix(): copy default prefix -> game prefix ---
# wine-builtin symlinks are recreated as relative links so the whole
# $GAME_DIR tree (prefix included) can be relocated into a scratch image
RUN set -e; \
    PFX="$WINEPREFIX"; \
    DDEF="${GAME_DIR}/files/share/default_pfx"; \
    mkdir -p "$PFX"; \
    ( cd "$DDEF" && find . -mindepth 1 | while IFS= read -r f; do \
        f="${f#./}"; \
        mkdir -p "$PFX/$(dirname "$f")"; \
        if [ -L "$DDEF/$f" ]; then \
            tgt=$(readlink "$DDEF/$f"); \
            abs=$(cd "$DDEF/$(dirname "$f")" && realpath -m -- "$tgt"); \
            case "$(dirname "$tgt")" in \
                */lib/wine/*-unix|*/lib/wine/*-windows) \
                    ln -sr "$DDEF/$f" "$PFX/$f" ;; \
                *) case "$abs" in \
                       "$DDEF"/*) ln -s "$tgt" "$PFX/$f" ;; \
                       "$GAME_DIR"/*) ln -sr "$abs" "$PFX/$f" ;; \
                       *) ln -s "$tgt" "$PFX/$f" ;; \
                   esac ;; \
            esac; \
        elif [ -d "$DDEF/$f" ]; then \
            mkdir -p "$PFX/$f"; \
        else \
            cp -a "$DDEF/$f" "$PFX/$f"; \
        fi; \
    done ); \
    # tracked_files bookkeeping
    ( cd "$DDEF" && find . -mindepth 1 | sed 's|^\./||' > "${COMPATDATA}/tracked_files" ); \
    stat -c %Y "${GAME_DIR}/files/share/wine/wine.inf" > "$PFX/.update-timestamp"; \
    # fixed all-zero MachineGuid
    GUID="00000000-0000-0000-0000-000000000000"; \
    sed -i "0,/^\"MachineGuid\"=/s|^\"MachineGuid\"=.*|\"MachineGuid\"=\"${GUID}\"|" "$PFX/system.reg"; \
    [ -e "$PFX/dosdevices/c:" ] || ln -s ../drive_c "$PFX/dosdevices/c:"; \
    [ -e "$PFX/dosdevices/z:" ] || ln -s / "$PFX/dosdevices/z:"; \
    # s: gamedrive (relative so the prefix is relocatable)
    ln -srfn "$GAME_DIR/game" "$PFX/dosdevices/s:"; \
    # version + creation sync guard
    echo "11.0-100" > "${COMPATDATA}/version"; \
    touch "$PFX/creation_sync_guard"

# --- setup_prefix(): D3D backend DLL placement (DXVK + vkd3d-proton, no wined3d) ---
RUN set -e; \
    PFX="$WINEPREFIX"; \
    W="${GAME_DIR}/files/lib/wine"; \
    # dxvk: d3d11, d3d10core, d3d9 (+dxgi)
    for f in d3d11 d3d10core d3d9 dxgi; do \
        cp -f "$W/dxvk/x86_64-windows/$f.dll" "$PFX/drive_c/windows/system32/"; \
        cp -f "$W/dxvk/i386-windows/$f.dll"   "$PFX/drive_c/windows/syswow64/"; \
    done; \
    # openvr_api_dxvk
    cp -f "$W/dxvk/x86_64-windows/openvr_api_dxvk.dll" "$PFX/drive_c/windows/system32/"; \
    cp -f "$W/dxvk/i386-windows/openvr_api_dxvk.dll"   "$PFX/drive_c/windows/syswow64/"; \
    # vkd3d-proton
    for f in d3d12 d3d12core; do \
        [ -f "$W/vkd3d-proton/x86_64-windows/$f.dll" ] && cp -f "$W/vkd3d-proton/x86_64-windows/$f.dll" "$PFX/drive_c/windows/system32/"; \
        [ -f "$W/vkd3d-proton/i386-windows/$f.dll" ]   && cp -f "$W/vkd3d-proton/i386-windows/$f.dll"   "$PFX/drive_c/windows/syswow64/"; \
    done; \
    # icu68
    for f in icuin68 icuuc68 icudt68; do \
        [ -e "$PFX/drive_c/windows/system32/$f.dll" ] || ln -sf "$W/icu/x86_64-windows/$f.dll" "$PFX/drive_c/windows/system32/$f.dll"; \
        [ -e "$PFX/drive_c/windows/syswow64/$f.dll" ] || ln -sf "$W/icu/i386-windows/$f.dll"   "$PFX/drive_c/windows/syswow64/$f.dll"; \
    done; \
    # nvapi
    [ -f "$W/nvapi/x86_64-windows/nvapi64.dll" ] && cp -f "$W/nvapi/x86_64-windows/nvapi64.dll" "$PFX/drive_c/windows/system32/"; \
    [ -f "$W/nvapi/x86_64-windows/nvofapi64.dll" ] && cp -f "$W/nvapi/x86_64-windows/nvofapi64.dll" "$PFX/drive_c/windows/system32/"; \
    [ -f "$W/nvapi/i386-windows/nvapi.dll" ] && cp -f "$W/nvapi/i386-windows/nvapi.dll" "$PFX/drive_c/windows/syswow64/"; \
    true

# fonts
RUN set -e; \
    FONTS="$WINEPREFIX/drive_c/windows/Fonts"; \
    mkdir -p "$FONTS"; \
    for d in "${GAME_DIR}/files/share/fonts" "${GAME_DIR}/files/share/wine/fonts"; do \
        for f in "$d"/*.ttf "$d"/*.ttc; do \
            # relative links so the prefix stays relocatable (scratch stage)
            [ -e "$f" ] && ln -srfn "$f" "$FONTS/$(basename "$f")"; \
        done; \
    done; \
    true

# Session env (DXVK/VKD3D logging, WINEFSYNC, XALIA, WINELOADERNOEXEC,
# WINEDLLOVERRIDES, ...) likewise lives in entrypoint.sh, not as image ENVs.

# Entrypoint resolves shorthand exe names (e.g. cs2.exe) against $GAME_DIR/game;
# only CS2 game .exe files can be launched, paths go through winepath.
# It self-locates to find GAME_DIR and derives wine's runtime env from it, so
# the final scratch stage only needs WORKDIR + a relative ENTRYPOINT.
COPY entrypoint.sh ${GAME_DIR}/entrypoint.sh
RUN chmod +x ${GAME_DIR}/entrypoint.sh

WORKDIR ${GAME_DIR}
ENTRYPOINT ["./entrypoint.sh"]

### Final: scratch image of just the files ###
# File source, not a runtime: this stage exists so other images can pull the
# licensed content (game tree + Proton/wine prefix) out of it, e.g.
#     COPY --from=cs2-workshop /app/ /app/
# The target image provides the userland (wine's host-lib deps, glibc, X11,
# GL/Vulkan). entrypoint.sh ships in the tree and derives wine's env from
# GAME_DIR if a consuming image wants to run it.
FROM scratch
ARG GAME_DIR=/app

COPY --from=protonsetup ${GAME_DIR}/ ${GAME_DIR}/

# No ENTRYPOINT: this image is a file source, not something to run.
# Consuming images COPY the tree out and use their own entrypoint.
WORKDIR ${GAME_DIR}
