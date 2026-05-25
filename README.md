# yaportal

Mod per [Luanti](https://www.luanti.org/) che aggiunge portali 3D in stile Portal: rendering in tempo reale di ciò che c'è dall'altro lato, teletrasporto con correzione di orientamento, e dimensioni tascabili (pocket dimensions).

Richiede un build personalizzato di Luanti 5.16.1 con le patch C++ incluse in questo repo (`src_patches/`). Il modo più semplice per usarla è l'AppImage precompilata.

---

## Installazione rapida (AppImage)

1. Scarica `Luanti-portal-x86_64.AppImage` dalla pagina [Releases](https://gitea.com/giacomo986/yaportal/releases).
2. Rendila eseguibile e avviala:
   ```sh
   chmod +x Luanti-portal-x86_64.AppImage
   ./Luanti-portal-x86_64.AppImage
   ```
3. Al primo avvio, l'AppImage installa automaticamente la mod `yaportal` nella cartella utente di Luanti (`~/.luanti/mods/` o `~/.minetest/mods/`).
4. Crea o apri un mondo, vai in **Impostazioni → Mod** e abilita `yaportal`.

---

## Oggetti della mod

### Cornice portale (`yaportal:frame`)

Blocco base per costruire portali manuali. Disponibile anche nelle varianti colorata blu (`frame_blue`) e arancione (`frame_orange`).

**Costruire un portale manuale:**
1. Costruisci una cornice rettangolare con i blocchi `frame` (larghezza interna 1–8, altezza interna 2–8 nodi).
2. Il portale si attiva automaticamente quando la cornice è completa.
3. **Clic destro** su qualsiasi blocco della cornice (o sull'entità ancora al centro) apre la GUI di configurazione:
   - **Nome** — assegna un nome univoco al portale.
   - **Collegamento** — scegli a quale portale deve condurre.
   - **Materiale** — cambia la texture della cornice.

### Portal Gun (`yaportal:portal_gun`)

Crea portali al volo senza costruire cornici.

| Azione | Effetto |
|--------|---------|
| Clic sinistro | Piazza portale blu sulla superficie puntata |
| Clic destro | Piazza portale arancione sulla superficie puntata |

I due portali sono automaticamente collegati tra loro. Passarci attraverso teletrasporta il giocatore con orientamento corretto.

### Pocket Dimension Gun (`yaportal:pocket_gun`)

Crea una dimensione tascabili privata per il giocatore.

| Azione | Effetto |
|--------|---------|
| Clic sinistro | Apre un portale verso la pocket dimension del giocatore |
| Clic destro | Chiude e distrugge la pocket dimension |

La pocket dimension è una piattaforma 32×32 in uno spazio isolato. Ogni giocatore ha la propria.

---

## Compilazione da sorgente

### Prerequisiti

- Ubuntu 24.04 x86\_64 (altre distro non testate)
- `build-essential`, `cmake`, `ninja-build`, `patchelf`, `wget`
  ```sh
  sudo apt install build-essential cmake ninja-build patchelf wget
  ```

### Setup iniziale (solo la prima volta)

```sh
PROJ=/path/to/yaportal   # directory di questo repo

# 1. Clona Luanti al commit base corretto
git clone https://github.com/luanti-org/luanti.git $PROJ/luanti_src
git -C $PROJ/luanti_src checkout e35647861   # tag 5.16.1

# 2. Applica le patch C++ del progetto
cp -r $PROJ/src_patches/. $PROJ/luanti_src/

# 3. Scarica le dipendenze binarie
mkdir -p $PROJ/tmp
cd $PROJ/tmp
apt-get download \
  libsdl2-dev libsdl2-2.0-0 zlib1g-dev libjpeg-turbo8-dev libjpeg8-dev \
  libpng-dev libgl-dev libopenal-dev libcurl4-openssl-dev libbrotli-dev libbz2-dev \
  libzstd-dev libsqlite3-dev libleveldb-dev libvorbis-dev libogg-dev

# Estrai i deb
for deb in $PROJ/tmp/*.deb; do
    case "$deb" in
        *luajit*)   dpkg-deb -x "$deb" $PROJ/tmp/luajit-extract ;;
        *leveldb*)  dpkg-deb -x "$deb" $PROJ/tmp/leveldb-extract ;;
        *)          dpkg-deb -x "$deb" $PROJ/tmp/deps ;;
    esac
done

# Symlink librerie di sistema
LIBDIR=$PROJ/tmp/deps/usr/lib/x86_64-linux-gnu
SYSLIB=/usr/lib/x86_64-linux-gnu
ln -sf $SYSLIB/libSDL2-2.0.so.0     $LIBDIR/libSDL2.so
ln -sf $SYSLIB/libcurl.so.4         $LIBDIR/libcurl.so
ln -sf $SYSLIB/libjpeg.so.8         $LIBDIR/libjpeg.so
ln -sf $SYSLIB/libopenal.so.1       $LIBDIR/libopenal.so
ln -sf $SYSLIB/libGL.so.1           $LIBDIR/libGL.so
ln -sf $SYSLIB/libzstd.so.1         $LIBDIR/libzstd.so
# Nascondi .a SDL2 per evitare link statico
mv $LIBDIR/libSDL2.a     $LIBDIR/libSDL2.a.bak     2>/dev/null || true
mv $LIBDIR/libSDL2main.a $LIBDIR/libSDL2main.a.bak 2>/dev/null || true

# Symlink header
ln -sf $PROJ/tmp/deps/usr/include/x86_64-linux-gnu/curl $PROJ/tmp/deps/usr/include/curl
mkdir -p $PROJ/tmp/deps/usr/include/luajit-2.1
cp -r $PROJ/tmp/luajit-extract/usr/include/luajit-2.1/. $PROJ/tmp/deps/usr/include/luajit-2.1/

# 4. Configura CMake (solo prima volta)
SRC=$PROJ/luanti_src
BUILD=$SRC/build
mkdir -p $BUILD
cmake -S $SRC -B $BUILD \
  -DCMAKE_BUILD_TYPE=Debug \
  -DBUILD_UNITTESTS=TRUE \
  -DENABLE_POSTGRESQL=OFF \
  -DENABLE_REDIS=OFF \
  -DENABLE_SYSTEM_GMP=ON \
  -DCMAKE_PREFIX_PATH=/tmp/deps/usr \
  -DCMAKE_INCLUDE_PATH="/tmp/deps/usr/include;/tmp/deps/usr/include/x86_64-linux-gnu;/tmp/luajit-extract/usr/include" \
  -DCMAKE_LIBRARY_PATH="/tmp/deps/usr/lib/x86_64-linux-gnu;/tmp/luajit-extract/usr/lib/x86_64-linux-gnu" \
  -DLUA_INCLUDE_DIR=/tmp/deps/usr/include/luajit-2.1 \
  -DLUA_LIBRARY=/tmp/luajit-extract/usr/lib/x86_64-linux-gnu/libluajit-5.1.so \
  -DLEVELDB_INCLUDE_DIR=/tmp/leveldb-extract/usr/include \
  -DLEVELDB_LIBRARY=/tmp/deps/usr/lib/x86_64-linux-gnu/libleveldb.a \
  -GNinja
```

### Build normale

Dopo il setup iniziale, per ricompilare basta:

```sh
./build.sh
```

Lo script ricrea i symlink `/tmp/` (cancellati a ogni riavvio) e lancia `ninja`.

### Avvio per sviluppo

```sh
./luanti_src/bin/luanti
```

La mod `yaportal/` va abilitata manualmente nel mondo come qualsiasi altra mod globale.

### Build AppImage per distribuzione

```sh
./release.sh
```

Produce `Luanti-portal-x86_64.AppImage` nella directory del progetto. Richiede `patchelf` e `wget`.

---

## Aggiornare src_patches/ dopo modifiche C++

Dopo aver modificato file C++ in `luanti_src/`, sincronizza `src_patches/` prima di committare:

```sh
PROJ=$(pwd)
SRC=$PROJ/luanti_src
for f in $(git -C $SRC diff --name-only HEAD); do
    mkdir -p "$PROJ/src_patches/$(dirname $f)"
    cp "$SRC/$f" "$PROJ/src_patches/$f"
done
git add src_patches/ && git commit -m "chore: sync src_patches"
```
