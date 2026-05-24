#!/bin/bash
# Crea un AppImage portabile di Luanti con la mod mio_portale inclusa.
#
# Dipendenze sistema: patchelf, wget, fuse (o --appimage-extract-and-run)
#   sudo apt install patchelf wget libfuse2
#
# Variabili d'ambiente opzionali:
#   CMAKE=/percorso/cmake    (default: cmake dal PATH)
#   NINJA=/percorso/ninja    (default: ninja dal PATH)
set -e

PROJ="$(cd "$(dirname "$0")" && pwd)"
SRC="$PROJ/luanti_src"
BUILD="$SRC/build"
TOOLS="$PROJ/tmp/appimage-tools"
APPDIR="$PROJ/tmp/AppDir"
CMAKE="${CMAKE:-cmake}"
NINJA="${NINJA:-ninja}"
OUT="$PROJ/Luanti-portal-x86_64.AppImage"

# ── verifica prerequisiti ──────────────────────────────────────────────────────
for cmd in patchelf wget; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERRORE: '$cmd' non trovato. Installare con: sudo apt install $cmd"; exit 1; }
done

if [ ! -f "$SRC/bin/luanti" ]; then
    echo "ERRORE: binario non trovato. Eseguire prima build.sh."
    exit 1
fi

# ── scarica appimagetool ───────────────────────────────────────────────────────
mkdir -p "$TOOLS"
APPIMAGETOOL="$TOOLS/appimagetool-x86_64.AppImage"
if [ ! -f "$APPIMAGETOOL" ]; then
    echo ">>> Download appimagetool..."
    wget -q --show-progress -O "$APPIMAGETOOL" \
        "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
    chmod +x "$APPIMAGETOOL"
fi

# ── ricrea symlink /tmp (cancellati a ogni riavvio) ───────────────────────────
ln -sfn "$PROJ/tmp/deps"            /tmp/deps
ln -sfn "$PROJ/tmp/leveldb-extract" /tmp/leveldb-extract
ln -sfn "$PROJ/tmp/luajit-extract"  /tmp/luajit-extract

# SDL2/_real_SDL_config.h è in un path arch-specifico; crea symlink nel path generico
# così #include <SDL2/_real_SDL_config.h> lo trova anche senza -I arch-specifico
SDLINC="$PROJ/tmp/deps/usr/include"
ln -sf "$SDLINC/x86_64-linux-gnu/SDL2/_real_SDL_config.h" \
       "$SDLINC/SDL2/_real_SDL_config.h" 2>/dev/null || true

# ── ricompila con RUN_IN_PLACE=TRUE ───────────────────────────────────────────
# Necessario perché senza RUN_IN_PLACE il binario cerca dati in percorso assoluto
# compilato (STATIC_SHAREDIR). Con RUN_IN_PLACE cerca in ../  rispetto al binario.
echo ">>> Riconfigura cmake con RUN_IN_PLACE=TRUE..."
"$CMAKE" -S "$SRC" -B "$BUILD" -DRUN_IN_PLACE=TRUE > /dev/null
echo ">>> Build..."
"$CMAKE" --build "$BUILD" -j"$(nproc)"

# ── crea AppDir ────────────────────────────────────────────────────────────────
# Layout: AppDir/bin/luanti  →  path_share = AppDir/
#         AppDir/lib/*.so    →  RPATH $ORIGIN/../lib
echo ">>> Costruisce AppDir..."
rm -rf "$APPDIR"
mkdir -p "$APPDIR/bin" "$APPDIR/lib"

# Binario
cp "$SRC/bin/luanti" "$APPDIR/bin/luanti"

# Dati di gioco (devtest + builtin + risorse)
for dir in games builtin fonts textures locale clientmods; do
    [ -d "$SRC/$dir" ] && cp -r "$SRC/$dir" "$APPDIR/$dir"
done
# Shaders: Luanti cerca path_share/client/shaders/
mkdir -p "$APPDIR/client"
[ -d "$SRC/client/shaders" ] && cp -r "$SRC/client/shaders" "$APPDIR/client/shaders"

# Mod mio_portale
mkdir -p "$APPDIR/mods/mio_portale"
cp "$PROJ/init.lua" "$PROJ/mod.conf" "$APPDIR/mods/mio_portale/"
cp -r "$PROJ/textures" "$APPDIR/mods/mio_portale/"

# ── raccoglie .so dipendenti ───────────────────────────────────────────────────
echo ">>> Raccoglie librerie..."
# Esclude: GL/GLX/EGL (driver-specifiche, ogni macchina ha le sue), libc/libm/libgcc
EXCLUDE="libGL|libGLX|libGLdispatch|libEGL|libOpenGL|libvulkan|libc\.so|libm\.so|libgcc|libstdc|ld-linux"

ldd "$APPDIR/bin/luanti" \
    | awk '/=> \// {print $3}' \
    | grep -Ev "$EXCLUDE" \
    | while read -r lib; do
        [ -f "$lib" ] && cp -n "$lib" "$APPDIR/lib/"
    done

# Copia anche le dipendenze transitive delle .so appena copiate
for lib in "$APPDIR/lib/"*.so*; do
    [ -f "$lib" ] || continue
    ldd "$lib" 2>/dev/null \
        | awk '/=> \// {print $3}' \
        | grep -Ev "$EXCLUDE" \
        | while read -r dep; do
            [ -f "$dep" ] && cp -n "$dep" "$APPDIR/lib/" 2>/dev/null || true
        done
done

# ── patcha RPATH ───────────────────────────────────────────────────────────────
echo ">>> Patcha RPATH..."
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
export MINETEST_USER_PATH="$LUANTI_USER"

# Sync mod to detected user mods path
USERMOD="$LUANTI_USER/mods/mio_portale"
if [ ! -d "$USERMOD" ] || [ "$APPDIR/mods/mio_portale/init.lua" -nt "$USERMOD/init.lua" ]; then
    mkdir -p "$LUANTI_USER/mods"
    rm -rf "$USERMOD"
    cp -r "$APPDIR/mods/mio_portale" "$USERMOD"
fi

# Fix world.mt entries that stored an absolute/wrong mod path (e.g. share/mio_portale)
find "$LUANTI_USER/worlds" -name "world.mt" 2>/dev/null | while read -r wmt; do
    grep -q "^load_mod_mio_portale = " "$wmt" && \
        sed -i 's|^load_mod_mio_portale = .*|load_mod_mio_portale = true|' "$wmt"
done

exec "$APPDIR/bin/luanti" "$@"
EOF
chmod +x "$APPDIR/AppRun"

# ── .desktop e icona ──────────────────────────────────────────────────────────
cat > "$APPDIR/luanti.desktop" <<'EOF'
[Desktop Entry]
Name=Luanti (portal)
Exec=luanti
Icon=luanti
Type=Application
Categories=Game;
EOF

cp "$SRC/misc/luanti-xorg-icon-128.png" "$APPDIR/luanti.png"

# ── crea AppImage ──────────────────────────────────────────────────────────────
echo ">>> Crea AppImage..."
ARCH=x86_64 "$APPIMAGETOOL" "$APPDIR" "$OUT"

# ── ripristina configurazione dev (RUN_IN_PLACE=FALSE) ────────────────────────
echo ">>> Ripristina RUN_IN_PLACE=FALSE per build dev..."
"$CMAKE" -S "$SRC" -B "$BUILD" -DRUN_IN_PLACE=FALSE > /dev/null
"$CMAKE" --build "$BUILD" -j"$(nproc)"

echo ""
echo "✓ AppImage creata: $OUT"
echo "  Avvia con: ./$OUT"
