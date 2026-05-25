#!/bin/bash
# Build a portable AppImage of Luanti with the yaportal mod bundled.
#
# System dependencies: patchelf, wget, fuse (or --appimage-extract-and-run)
#   sudo apt install patchelf wget libfuse2
#
# Optional environment variables:
#   CMAKE=/path/to/cmake    (default: cmake from PATH)
#   NINJA=/path/to/ninja    (default: ninja from PATH)
set -e

PROJ="$(cd "$(dirname "$0")" && pwd)"
SRC="$PROJ/luanti_src"
BUILD="$SRC/build"
TOOLS="$PROJ/tmp/appimage-tools"
APPDIR="$PROJ/tmp/AppDir"
CMAKE="${CMAKE:-cmake}"
NINJA="${NINJA:-ninja}"
OUT="$PROJ/Luanti-portal-x86_64.AppImage"

# ── check prerequisites ──────────────────────────────────────────────────────
for cmd in patchelf wget; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found. Install with: sudo apt install $cmd"; exit 1; }
done

if [ ! -f "$SRC/bin/luanti" ]; then
    echo "ERROR: binary not found. Run build.sh first."
    exit 1
fi

# ── download appimagetool ───────────────────────────────────────────────────────
mkdir -p "$TOOLS"
APPIMAGETOOL="$TOOLS/appimagetool-x86_64.AppImage"
if [ ! -f "$APPIMAGETOOL" ]; then
    echo ">>> Downloading appimagetool..."
    wget -q --show-progress -O "$APPIMAGETOOL" \
        "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
    chmod +x "$APPIMAGETOOL"
fi

# ── recreate /tmp symlinks (cleared on reboot) ───────────────────────────
ln -sfn "$PROJ/tmp/deps"            /tmp/deps
ln -sfn "$PROJ/tmp/leveldb-extract" /tmp/leveldb-extract
ln -sfn "$PROJ/tmp/luajit-extract"  /tmp/luajit-extract

# SDL2/_real_SDL_config.h lives in an arch-specific path; symlink to the generic path
# so #include <SDL2/_real_SDL_config.h> works without the arch-specific -I flag
SDLINC="$PROJ/tmp/deps/usr/include"
ln -sf "$SDLINC/x86_64-linux-gnu/SDL2/_real_SDL_config.h" \
       "$SDLINC/SDL2/_real_SDL_config.h" 2>/dev/null || true

# ── recompile with RUN_IN_PLACE=FALSE ───────────────────────────────────────────
# RUN_IN_PLACE=FALSE: setSystemPaths() reads LUANTI_USER_PATH (writable) and
# finds path_share from bindir/../builtin = AppDir/builtin. With RUN_IN_PLACE=TRUE
# path_user is hardcoded to the read-only AppImage → crash on debug.txt.
echo ">>> Reconfiguring cmake with RUN_IN_PLACE=FALSE..."
"$CMAKE" -S "$SRC" -B "$BUILD" -DRUN_IN_PLACE=FALSE > /dev/null
echo ">>> Build..."
"$CMAKE" --build "$BUILD" -j"$(nproc)"

# ── build AppDir ────────────────────────────────────────────────────────────────
# Layout: AppDir/bin/luanti  →  path_share = AppDir/
#         AppDir/lib/*.so    →  RPATH $ORIGIN/../lib
echo ">>> Building AppDir..."
rm -rf "$APPDIR"
mkdir -p "$APPDIR/bin" "$APPDIR/lib"

# Binary
cp "$SRC/bin/luanti" "$APPDIR/bin/luanti"

# Game data (devtest + builtin + resources)
for dir in games builtin fonts textures locale clientmods; do
    [ -d "$SRC/$dir" ] && cp -r "$SRC/$dir" "$APPDIR/$dir"
done
# Shaders: Luanti looks for path_share/client/shaders/
mkdir -p "$APPDIR/client"
[ -d "$SRC/client/shaders" ] && cp -r "$SRC/client/shaders" "$APPDIR/client/shaders"

# yaportal mod
mkdir -p "$APPDIR/bundled_mods/yaportal"
cp "$PROJ/yaportal/init.lua" "$PROJ/yaportal/mod.conf" "$APPDIR/bundled_mods/yaportal/"
cp -r "$PROJ/yaportal/textures" "$APPDIR/bundled_mods/yaportal/"

# ── collect .so dependencies ───────────────────────────────────────────────────
echo ">>> Collecting libraries..."
# Exclude: GL/GLX/EGL (driver-specific, each machine has its own), libc/libm/libgcc
EXCLUDE="libGL|libGLX|libGLdispatch|libEGL|libOpenGL|libvulkan|libc\.so|libm\.so|libgcc|libstdc|ld-linux"

ldd "$APPDIR/bin/luanti" \
    | awk '/=> \// {print $3}' \
    | grep -Ev "$EXCLUDE" \
    | while read -r lib; do
        [ -f "$lib" ] && cp -n "$lib" "$APPDIR/lib/"
    done

# Also copy transitive dependencies of the .so files just collected
for lib in "$APPDIR/lib/"*.so*; do
    [ -f "$lib" ] || continue
    ldd "$lib" 2>/dev/null \
        | awk '/=> \// {print $3}' \
        | grep -Ev "$EXCLUDE" \
        | while read -r dep; do
            [ -f "$dep" ] && cp -n "$dep" "$APPDIR/lib/" 2>/dev/null || true
        done
done

# ── patch RPATH ───────────────────────────────────────────────────────────────
echo ">>> Patching RPATH..."
patchelf --set-rpath '$ORIGIN/../lib' "$APPDIR/bin/luanti"

# ── AppRun ────────────────────────────────────────────────────────────────────
cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/bash
APPDIR="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$APPDIR/lib:${LD_LIBRARY_PATH}"

# Detect user data dir (priority: ~/.minetest > XDG ~/.local/share/luanti > ~/.luanti)
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

# Sync mod to detected user mods path
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

# ── .desktop and icon ──────────────────────────────────────────────────────────
cat > "$APPDIR/luanti.desktop" <<'EOF'
[Desktop Entry]
Name=Luanti (portal)
Exec=luanti
Icon=luanti
Type=Application
Categories=Game;
EOF

cp "$SRC/misc/luanti-xorg-icon-128.png" "$APPDIR/luanti.png"

# ── create AppImage ──────────────────────────────────────────────────────────────
echo ">>> Creating AppImage..."
ARCH=x86_64 "$APPIMAGETOOL" "$APPDIR" "$OUT"

# ── restore dev configuration (Debug) ────────────────────────────────────
echo ">>> Restoring Debug build for dev..."
"$CMAKE" -S "$SRC" -B "$BUILD" -DCMAKE_BUILD_TYPE=Debug > /dev/null
"$CMAKE" --build "$BUILD" -j"$(nproc)"

echo ""
echo "✓ AppImage created: $OUT"
echo "  Run with: ./$OUT"
