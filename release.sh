#!/bin/bash
# Compile Luanti-portal in Release mode and produce the AppImage.
# Restores the dev build (Debug + RUN_IN_PLACE=FALSE) when done.
#
# Dipendenze: patchelf wget fuse/libfuse2
#   sudo apt install patchelf wget libfuse2
#
# Optional variables:
#   CMAKE=/path/to/cmake   (default: cmake from PATH)
#   NINJA=/path/to/ninja   (default: ninja from PATH)
set -e

PROJ="$(cd "$(dirname "$0")" && pwd)"
SRC="$PROJ/luanti_src"
BUILD="$SRC/build"
TOOLS="$PROJ/tmp/appimage-tools"
APPDIR="$PROJ/tmp/AppDir"
# Auto-detect cmake from CMakeCache if not set in environment.
if [ -z "$CMAKE" ]; then
    CMAKE="$(grep '^CMAKE_COMMAND:INTERNAL=' "$BUILD/CMakeCache.txt" 2>/dev/null | cut -d= -f2)"
    CMAKE="${CMAKE:-cmake}"
fi
NINJA="${NINJA:-ninja}"
OUT="$PROJ/Luanti-portal-x86_64.AppImage"

# ── prerequisites ──────────────────────────────────────────────────────────────
for cmd in patchelf wget; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: '$cmd' not found. Install with: sudo apt install $cmd"; exit 1
    }
done

# ── /tmp symlinks (cleared on reboot) ──────────────────────────────────
ln -sfn "$PROJ/tmp/deps"            /tmp/deps
ln -sfn "$PROJ/tmp/leveldb-extract" /tmp/leveldb-extract
ln -sfn "$PROJ/tmp/luajit-extract"  /tmp/luajit-extract

SDLINC="$PROJ/tmp/deps/usr/include"
ln -sf "$SDLINC/x86_64-linux-gnu/SDL2/_real_SDL_config.h" \
       "$SDLINC/SDL2/_real_SDL_config.h" 2>/dev/null || true

# Fix broken .so symlinks on non-Debian distros (e.g. Arch).
DEPS_LIB="$PROJ/tmp/deps/usr/lib/x86_64-linux-gnu"
for link in "$DEPS_LIB"/*.so*; do
    [ -L "$link" ] || continue
    target="$(readlink "$link")"
    [[ "$target" == /usr/lib/x86_64-linux-gnu/* ]] || continue
    [ -e "$link" ] && continue
    alt="/usr/lib/$(basename "$target")"
    if [ -e "$alt" ]; then
        ln -sfn "$alt" "$link"
    fi
done

# ── download appimagetool ──────────────────────────────────────────────────────
mkdir -p "$TOOLS"
APPIMAGETOOL="$TOOLS/appimagetool-x86_64.AppImage"
if [ ! -f "$APPIMAGETOOL" ]; then
    echo ">>> Downloading appimagetool..."
    wget -q --show-progress -O "$APPIMAGETOOL" \
        "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
    chmod +x "$APPIMAGETOOL"
fi

# ── configure Release ────────────────────────────────────────────────────────
# RUN_IN_PLACE=FALSE: setSystemPaths() reads LUANTI_USER_PATH and finds
# path_share from bindir/../builtin (= AppDir/builtin). With TRUE path_user
# is hardcoded to the read-only AppImage → crash on debug.txt.
echo ">>> cmake Release..."
"$CMAKE" -S "$SRC" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DRUN_IN_PLACE=FALSE \
    > /dev/null

# ── compile ───────────────────────────────────────────────────────────────────
echo ">>> Build Release..."
"$NINJA" -C "$BUILD" -j"$(nproc)"

# ── build AppDir ───────────────────────────────────────────────────────────────
echo ">>> Building AppDir..."
rm -rf "$APPDIR"
mkdir -p "$APPDIR/bin" "$APPDIR/lib"

cp "$SRC/bin/luanti" "$APPDIR/bin/luanti"

for dir in games builtin fonts textures locale clientmods; do
    [ -d "$SRC/$dir" ] && cp -r "$SRC/$dir" "$APPDIR/$dir"
done
# The FPS arena game lives in the repo root, not in luanti_src/games.
mkdir -p "$APPDIR/games"
cp -r "$PROJ/yafps" "$APPDIR/games/yafps"
mkdir -p "$APPDIR/client"
[ -d "$SRC/client/shaders" ] && cp -r "$SRC/client/shaders" "$APPDIR/client/shaders"

# Mod in bundled_mods/ (not auto-discovered by Luanti as global mods).
# AppRun copies it to $LUANTI_USER/mods/ on first launch.
mkdir -p "$APPDIR/bundled_mods/yaportal"
cp "$PROJ/yaportal/init.lua" "$PROJ/yaportal/mod.conf" "$APPDIR/bundled_mods/yaportal/"
cp -r "$PROJ/yaportal/textures" "$APPDIR/bundled_mods/yaportal/"

# ── collect .so ─────────────────────────────────────────────────────────────
echo ">>> Collecting libraries..."
EXCLUDE="libGL|libGLX|libGLdispatch|libEGL|libOpenGL|libvulkan|libc\.so|libm\.so|libgcc|libstdc|ld-linux"

ldd "$APPDIR/bin/luanti" \
    | awk '/=> \// {print $3}' \
    | grep -Ev "$EXCLUDE" \
    | while read -r lib; do
        [ -f "$lib" ] && cp -n "$lib" "$APPDIR/lib/"
    done

for lib in "$APPDIR/lib/"*.so*; do
    [ -f "$lib" ] || continue
    ldd "$lib" 2>/dev/null \
        | awk '/=> \// {print $3}' \
        | grep -Ev "$EXCLUDE" \
        | while read -r dep; do
            [ -f "$dep" ] && cp -n "$dep" "$APPDIR/lib/" 2>/dev/null || true
        done
done

# ── RPATH ─────────────────────────────────────────────────────────────────────
echo ">>> Patching RPATH..."
patchelf --set-rpath '$ORIGIN/../lib' "$APPDIR/bin/luanti"

# ── AppRun ────────────────────────────────────────────────────────────────────
cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/bash
APPDIR="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$APPDIR/lib:${LD_LIBRARY_PATH}"

if [ -d "$HOME/.minetest" ]; then
    LUANTI_USER="$HOME/.minetest"
elif [ -d "$HOME/.local/share/luanti" ]; then
    LUANTI_USER="$HOME/.local/share/luanti"
else
    LUANTI_USER="$HOME/.luanti"
fi
export LUANTI_USER_PATH="$LUANTI_USER"
mkdir -p "$LUANTI_USER"

# Remove old mod dir left over from rename mio_portale → yaportal
rm -rf "$LUANTI_USER/mods/mio_portale"

USERMOD="$LUANTI_USER/mods/yaportal"
if [ ! -d "$USERMOD" ] || [ "$APPDIR/bundled_mods/yaportal/init.lua" -nt "$USERMOD/init.lua" ]; then
    mkdir -p "$LUANTI_USER/mods"
    rm -rf "$USERMOD"
    cp -r "$APPDIR/bundled_mods/yaportal" "$USERMOD"
fi

# Migrate world.mt: rename old mod key and force-enable yaportal
find "$LUANTI_USER/worlds" -name "world.mt" 2>/dev/null | while read -r wmt; do
    sed -i \
        's|^load_mod_mio_portale = .*|load_mod_yaportal = true|' \
        "$wmt"
    grep -q "^load_mod_yaportal" "$wmt" || true
done

exec "$APPDIR/bin/luanti" "$@"
EOF
chmod +x "$APPDIR/AppRun"

cat > "$APPDIR/luanti.desktop" <<'EOF'
[Desktop Entry]
Name=Luanti (portal)
Exec=luanti
Icon=luanti
Type=Application
Categories=Game;
EOF

cp "$SRC/misc/luanti-xorg-icon-128.png" "$APPDIR/luanti.png"

# ── create AppImage ─────────────────────────────────────────────────────────────
echo ">>> Creating AppImage..."
ARCH=x86_64 "$APPIMAGETOOL" "$APPDIR" "$OUT"

# ── restore dev build ──────────────────────────────────────────────────────
echo ">>> Restoring Debug build for dev..."
"$CMAKE" -S "$SRC" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Debug \
    > /dev/null
"$NINJA" -C "$BUILD" -j"$(nproc)"

echo ""
echo "AppImage: $OUT"
echo "Run with: ./$OUT"
