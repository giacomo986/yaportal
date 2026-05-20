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

# ── ricompila con RUN_IN_PLACE=TRUE ───────────────────────────────────────────
# Necessario perché senza RUN_IN_PLACE il binario cerca dati in percorso assoluto
# compilato (STATIC_SHAREDIR). Con RUN_IN_PLACE cerca in ../  rispetto al binario.
echo ">>> Riconfigura cmake con RUN_IN_PLACE=TRUE..."
"$CMAKE" -S "$SRC" -B "$BUILD" -DRUN_IN_PLACE=TRUE -GNinja > /dev/null
echo ">>> Build..."
"$NINJA" -C "$BUILD" -j"$(nproc)"

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
exec "$APPDIR/bin/luanti" \
    --gamepath "$APPDIR/games" \
    --worldpath "${XDG_DATA_HOME:-$HOME/.local/share}/luanti/worlds" \
    "$@"
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
ARCH=x86_64 "$APPIMAGETOOL" --comp gzip "$APPDIR" "$OUT"

echo ""
echo "✓ AppImage creata: $OUT"
echo "  Avvia con: ./$OUT"
