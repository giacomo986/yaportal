#!/bin/bash
# Compila Luanti-portal in modalità Release e produce l'AppImage.
# Al termine ripristina la build dev (Debug + RUN_IN_PLACE=FALSE).
#
# Dipendenze: patchelf wget fuse/libfuse2
#   sudo apt install patchelf wget libfuse2
#
# Variabili opzionali:
#   CMAKE=/percorso/cmake   (default: cmake dal PATH)
#   NINJA=/percorso/ninja   (default: ninja dal PATH)
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

# ── prerequisiti ──────────────────────────────────────────────────────────────
for cmd in patchelf wget; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERRORE: '$cmd' non trovato. Installare: sudo apt install $cmd"; exit 1
    }
done

# ── symlink /tmp (cancellati a ogni riavvio) ──────────────────────────────────
ln -sfn "$PROJ/tmp/deps"            /tmp/deps
ln -sfn "$PROJ/tmp/leveldb-extract" /tmp/leveldb-extract
ln -sfn "$PROJ/tmp/luajit-extract"  /tmp/luajit-extract

SDLINC="$PROJ/tmp/deps/usr/include"
ln -sf "$SDLINC/x86_64-linux-gnu/SDL2/_real_SDL_config.h" \
       "$SDLINC/SDL2/_real_SDL_config.h" 2>/dev/null || true

# Fissa symlink .so rotti su distro non Debian (es. Arch).
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

# ── scarica appimagetool ──────────────────────────────────────────────────────
mkdir -p "$TOOLS"
APPIMAGETOOL="$TOOLS/appimagetool-x86_64.AppImage"
if [ ! -f "$APPIMAGETOOL" ]; then
    echo ">>> Download appimagetool..."
    wget -q --show-progress -O "$APPIMAGETOOL" \
        "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
    chmod +x "$APPIMAGETOOL"
fi

# ── configura Release ────────────────────────────────────────────────────────
# RUN_IN_PLACE=FALSE: setSystemPaths() legge LUANTI_USER_PATH e scopre
# path_share da bindir/../builtin (= AppDir/builtin). Con TRUE path_user
# è hardcoded all'AppImage read-only → crash su debug.txt.
echo ">>> cmake Release..."
"$CMAKE" -S "$SRC" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DRUN_IN_PLACE=FALSE \
    > /dev/null

# ── compila ───────────────────────────────────────────────────────────────────
echo ">>> Build Release..."
"$NINJA" -C "$BUILD" -j"$(nproc)"

# ── crea AppDir ───────────────────────────────────────────────────────────────
echo ">>> Costruisce AppDir..."
rm -rf "$APPDIR"
mkdir -p "$APPDIR/bin" "$APPDIR/lib"

cp "$SRC/bin/luanti" "$APPDIR/bin/luanti"

for dir in games builtin fonts textures locale clientmods; do
    [ -d "$SRC/$dir" ] && cp -r "$SRC/$dir" "$APPDIR/$dir"
done
mkdir -p "$APPDIR/client"
[ -d "$SRC/client/shaders" ] && cp -r "$SRC/client/shaders" "$APPDIR/client/shaders"

# Mod in bundled_mods/ (non auto-scoperto da Luanti come global mods).
# AppRun la copia in $LUANTI_USER/mods/ al primo avvio.
mkdir -p "$APPDIR/bundled_mods/mio_portale"
cp "$PROJ/init.lua" "$PROJ/mod.conf" "$APPDIR/bundled_mods/mio_portale/"
cp -r "$PROJ/textures" "$APPDIR/bundled_mods/mio_portale/"

# ── raccoglie .so ─────────────────────────────────────────────────────────────
echo ">>> Raccoglie librerie..."
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
echo ">>> Patcha RPATH..."
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

USERMOD="$LUANTI_USER/mods/mio_portale"
if [ ! -d "$USERMOD" ] || [ "$APPDIR/bundled_mods/mio_portale/init.lua" -nt "$USERMOD/init.lua" ]; then
    mkdir -p "$LUANTI_USER/mods"
    rm -rf "$USERMOD"
    cp -r "$APPDIR/bundled_mods/mio_portale" "$USERMOD"
fi

find "$LUANTI_USER/worlds" -name "world.mt" 2>/dev/null | while read -r wmt; do
    grep -q "^load_mod_mio_portale" "$wmt" && \
        sed -i 's|^load_mod_mio_portale = .*|load_mod_mio_portale = true|' "$wmt"
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

# ── crea AppImage ─────────────────────────────────────────────────────────────
echo ">>> Crea AppImage..."
ARCH=x86_64 "$APPIMAGETOOL" "$APPDIR" "$OUT"

# ── ripristina build dev ──────────────────────────────────────────────────────
echo ">>> Ripristina Debug per build dev..."
"$CMAKE" -S "$SRC" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Debug \
    > /dev/null
"$NINJA" -C "$BUILD" -j"$(nproc)"

echo ""
echo "AppImage: $OUT"
echo "Avvia con: ./$OUT"
