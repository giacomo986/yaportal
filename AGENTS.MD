Questo progetto è una mod per Luanti con un motore C++ personalizzato che aggiunge rendering di portali 3D. Il sorgente del motore modificato è in `luanti_src/` (ignorato da git); le sole modifiche al motore sono tracciate in `src_patches/`. La logica Lua della mod è in `init.lua`.

---

## Setup da zero

Seguire i passi in ordine. Richiede Ubuntu 24.04 x86_64 con accesso a `apt-get download`.

### 1. Clona il motore Luanti

```sh
PROJ=/path/to/mio_portale   # directory di questo repo
git clone https://github.com/luanti-org/luanti.git $PROJ/luanti_src
# Il commit base usato per le patch:
git -C $PROJ/luanti_src checkout a6c948946
```

### 2. Applica le patch al sorgente

```sh
PROJ=/path/to/mio_portale
cp -r $PROJ/src_patches/. $PROJ/luanti_src/
```

File aggiunti/modificati dal progetto (tutti in `src_patches/`):

| File | Tipo |
|------|------|
| `src/portal_manager.h/.cpp` | **nuovo** — singleton `PortalManager`, N portali, cam hint |
| `src/client/render/portal.h/.cpp` | **nuovo** — `PortalRTTData`, `PortalPrepareStep`, `PortalQuadStep`, `PortalRenderStep` |
| `src/client/render/plain.h/.cpp` | modificato — inserisce i portal render step nella pipeline |
| `src/client/clientmap.h/.cpp` | modificato — `updatePortalDrawList`, `clearPortalDrawList` |
| `src/client/client.h` | modificato — espone accesso a ClientMap per il rendering |
| `src/client/game.cpp` | modificato — avvia portal step |
| `src/client/localplayer.h` | modificato — supporto teletrasporto |
| `src/client/renderingengine.cpp` | modificato — integrazione pipeline |
| `src/script/lua_api/l_env.h/.cpp` | modificato — `set_portals`, `set_portal_cam_hint`, `clear_portal_cam_hint` |
| `src/script/lua_api/l_object.h/.cpp` | modificato — `portal_teleport` |
| `src/network/networkprotocol.h` | modificato — opcode `TOCLIENT_PORTAL_TELEPORT` |
| `src/network/clientopcodes.cpp` | modificato |
| `src/network/serveropcodes.cpp` | modificato |
| `src/network/clientpackethandler.cpp` | modificato — handler `handleCommand_PortalTeleport` |
| `src/server.h/.cpp` | modificato — invio pacchetto teletrasporto |
| `src/server/player_sao.h/.cpp` | modificato — `setPlayerYaw`, `getLookPitch` |
| `src/server/clientiface.cpp` | modificato |
| `irr/include/ICameraSceneNode.h` | modificato — `setRenderProjectionMatrix` |
| `irr/src/CCameraSceneNode.h/.cpp` | modificato — `setRenderProjectionMatrix` (no frustum update) |
| `irr/src/CMakeLists.txt` | modificato |
| `src/CMakeLists.txt` | modificato — aggiunge `portal_manager`, `portal` ai target |
| `src/client/CMakeLists.txt` | modificato |
| `cmake/Modules/FindZstd.cmake` | modificato — fix find per zstd statica |

### 3. Prepara le dipendenze

Le dipendenze binarie vivono in `$PROJ/tmp/` (persistente tra riavvii). Se mancano, eseguire il download (vedi sezione [Download deb da zero](#download-deb-da-zero)).

```sh
PROJ=/path/to/mio_portale

mkdir -p $PROJ/tmp/deps $PROJ/tmp/luajit-extract $PROJ/tmp/leveldb-extract

# Estrai tutti i deb in deps/
for deb in $PROJ/tmp/*.deb; do
    case "$deb" in
        *luajit*) dpkg-deb -x "$deb" $PROJ/tmp/luajit-extract ;;
        *leveldb*) dpkg-deb -x "$deb" $PROJ/tmp/leveldb-extract ;;
        *) dpkg-deb -x "$deb" $PROJ/tmp/deps ;;
    esac
done

LIBDIR=$PROJ/tmp/deps/usr/lib/x86_64-linux-gnu
SYSLIB=/usr/lib/x86_64-linux-gnu

# Symlink .so condivise dalle librerie di sistema (non usare quelle statiche del deb)
ln -sf $SYSLIB/libSDL2-2.0.so.0     $LIBDIR/libSDL2.so
ln -sf $SYSLIB/libcurl.so.4         $LIBDIR/libcurl.so
ln -sf $SYSLIB/libjpeg.so.8         $LIBDIR/libjpeg.so
ln -sf $SYSLIB/libopenal.so.1       $LIBDIR/libopenal.so
ln -sf $SYSLIB/libGL.so.1           $LIBDIR/libGL.so
ln -sf $SYSLIB/libGLX.so.0          $LIBDIR/libGLX.so
ln -sf $SYSLIB/libOpenGL.so.0       $LIBDIR/libOpenGL.so
ln -sf $SYSLIB/libzstd.so.1         $LIBDIR/libzstd.so
ln -sf $SYSLIB/libbrotlidec.so.1    $LIBDIR/libbrotlidec.so
ln -sf $SYSLIB/libbrotlicommon.so.1 $LIBDIR/libbrotlicommon.so
ln -sf $SYSLIB/libbz2.so.1          $LIBDIR/libbz2.so
ln -sf $SYSLIB/libGLU.so.1          $LIBDIR/libGLU.so
ln -sf $SYSLIB/libsnappy.so.1       $LIBDIR/libsnappy.so

# Header curl e jpeg in path non-arch
ln -sf $PROJ/tmp/deps/usr/include/x86_64-linux-gnu/curl    $PROJ/tmp/deps/usr/include/curl
ln -sf $PROJ/tmp/deps/usr/include/x86_64-linux-gnu/jconfig.h $PROJ/tmp/deps/usr/include/jconfig.h

# Copia header LuaJIT in deps
mkdir -p $PROJ/tmp/deps/usr/include/luajit-2.1
cp -r $PROJ/tmp/luajit-extract/usr/include/luajit-2.1/. $PROJ/tmp/deps/usr/include/luajit-2.1/

# Nascondi libSDL2.a — cmake la preferisce alla .so causando link statico (-lasound ecc.)
mv $LIBDIR/libSDL2.a      $LIBDIR/libSDL2.a.bak      2>/dev/null || true
mv $LIBDIR/libSDL2main.a  $LIBDIR/libSDL2main.a.bak  2>/dev/null || true
mv $LIBDIR/libSDL2_test.a $LIBDIR/libSDL2_test.a.bak 2>/dev/null || true
```

### 4. Crea symlink /tmp (dopo ogni riavvio)

`build.ninja` usa percorsi `/tmp/`. Dopo ogni riavvio ricreare i symlink:

```sh
PROJ=/path/to/mio_portale
ln -sfn $PROJ/tmp/deps            /tmp/deps
ln -sfn $PROJ/tmp/luajit-extract  /tmp/luajit-extract
ln -sfn $PROJ/tmp/leveldb-extract /tmp/leveldb-extract
```

In alternativa, usare `build.sh` (lo fa automaticamente):

```sh
./build.sh
```

### 5. Configura con CMake (solo prima volta o dopo reset cache)

```sh
PROJ=/path/to/mio_portale
SRC=$PROJ/luanti_src
BUILD=$SRC/build

mkdir -p $BUILD
cd $BUILD && cmake \
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
  -GNinja \
  $SRC
touch $BUILD/build.ninja
cd $BUILD && ninja -j$(nproc)
```

> Se cmake o ninja non sono nel PATH, impostare le variabili d'ambiente `CMAKE` e `NINJA` con il percorso assoluto prima di eseguire.

### 6. Build normale (dopo symlink /tmp)

```sh
./build.sh
# oppure:
cd /path/to/mio_portale/luanti_src/build && ninja -j$(nproc)
```

### 7. Avvia il gioco

```sh
/path/to/mio_portale/luanti_src/bin/luanti
```

---

## Aggiornare src_patches/ dopo modifiche C++

Dopo ogni modifica ai file C++ in `luanti_src/`, aggiornare `src_patches/` e committare:

```sh
PROJ=/path/to/mio_portale
SRC=$PROJ/luanti_src
DEST=$PROJ/src_patches

for f in $(git -C $SRC diff --name-only HEAD); do
    mkdir -p "$DEST/$(dirname $f)"
    cp "$SRC/$f" "$DEST/$f"
done
# Nuovi file non tracciati da luanti_src:
for f in src/portal_manager.cpp src/portal_manager.h \
          src/client/render/portal.cpp src/client/render/portal.h; do
    cp "$SRC/$f" "$DEST/$f"
done

git add src_patches/ && git commit -m "chore: sync src_patches with luanti_src changes"
```

---

## Download deb da zero

Solo se `$PROJ/tmp/*.deb` non esistono:

```sh
PROJ=/path/to/mio_portale
mkdir -p $PROJ/tmp
cd $PROJ/tmp
apt-get download \
  libsdl2-dev libsdl2-2.0-0 zlib1g-dev libjpeg-turbo8-dev libjpeg8-dev \
  libpng-dev libgl-dev libopenal-dev libcurl4-openssl-dev libbrotli-dev libbz2-dev \
  libzstd-dev libsqlite3-dev libleveldb-dev libvorbis-dev libogg-dev \
  libgmp-dev libfreetype-dev libharfbuzz-dev libglu1-mesa-dev \
  libsnappy-dev libsnappy1v5 \
  libluajit-5.1-dev libluajit-5.1-2
```

---

## Creare un AppImage portabile

Produce `Luanti-portal-x86_64.AppImage` (~70 MB) eseguibile su qualsiasi Linux x86_64.

### Prerequisiti

```sh
sudo apt install patchelf wget libfuse2t64
```

### Esecuzione

```sh
PROJ=/path/to/mio_portale
CMAKE=/percorso/cmake $PROJ/make_appimage.sh
```

Se `cmake` è nel PATH si può omettere la variabile. Lo script:
1. Ricrea i symlink `/tmp/deps`, `/tmp/leveldb-extract`, `/tmp/luajit-extract`
2. Crea il symlink `SDL2/_real_SDL_config.h` (header arch-specifico richiesto dalla build)
3. Ricompila con `RUN_IN_PLACE=TRUE` (il binario cerca dati in `../` rispetto a sé)
4. Patcha RPATH a `$ORIGIN/../lib` con patchelf
5. Raccoglie tutte le `.so` dipendenti (esclude GL/EGL, driver-specifiche)
6. Scarica `appimagetool` in `tmp/appimage-tools/` (solo la prima volta)
7. Produce l'AppImage nella root del repo

### Note

- `make_appimage.sh` è idempotente: rieseguirlo ricompila solo i file modificati.
- GL/EGL/Vulkan **non** sono incluse — ogni macchina usa i propri driver.
- Struttura AppDir:
  ```
  AppDir/
    bin/luanti          ← binario (RPATH: $ORIGIN/../lib)
    lib/*.so            ← dipendenze bundled
    client/shaders/     ← shader GLSL (Luanti cerca path_share/client/shaders/)
    games/ builtin/ fonts/ textures/ locale/ clientmods/
    mods/mio_portale/   ← mod inclusa nell'AppImage
  ```

---

## Problemi noti

- **IFUNC conflict**: NON usare `libluajit-5.1.a` statica — conflitto `memcpy`/`strcasecmp` con glibc IFUNC. Usare sempre la `.so` condivisa.
- **libSDL2.a nel deb**: cmake la preferisce alla `.so` → link statico fallisce con `-lasound not found`. Fix: rinominare in `.a.bak` (già nel blocco setup sopra).
- **curl/jpeg header in path arch-specifico**: richiedono i symlink creati nel setup.
- **leveldb richiede snappy**: già fixato in `src/CMakeLists.txt`.
- **libluajit RUNPATH**: se il binario dice `libluajit-5.1.so.2 not found`, verificare che il RUNPATH in `build.ninja` includa `/tmp/luajit-extract/usr/lib/x86_64-linux-gnu`. In caso, rigenerare con cmake (passo 5).
- **ninja/cmake non nel PATH**: impostare `NINJA=/percorso/ninja ninja -j$(nproc)` o aggiungere la directory al PATH.

---

## File portale (C++)

### API Lua esposta dal motore

```lua
-- Imposta lista portali attivi (chiamato da sync_portals in init.lua)
-- portal_list: array 1-based, max MAX_PORTALS (8) elementi
-- Ogni elemento: {pos, normal, up, half_w, half_h, link}
-- link: indice 0-based del portale destinazione (-1 = nessuno)
minetest.set_portals(portal_list)

-- Override posizione camera virtuale per RTT del portale idx (0-based)
-- Usato pre-teletrasporto per pre-renderizzare il punto di arrivo
minetest.set_portal_cam_hint(idx, {x, y, z})   -- posizione world in coordinate nodo
minetest.clear_portal_cam_hint(idx)

-- Teletrasporto atomico: pos + yaw + delta velocità in un pacchetto
-- vel_delta: delta da aggiungere alla velocità corrente (non assoluto)
player:portal_teleport(pos, yaw_radians, vel_delta)
```

### Tecnica di rendering

**PortalPrepareStep** (prima di Draw3D):
1. `ensureCameras` — crea vcam[i] una sola volta, mai distrugge
2. Per ogni portale attivo con link: `setVirtualCamera(vcam[i], src, dst, cam_pos)`
3. `updatePortalDrawList` — aggiunge blocchi vicini a ogni vcam alla `m_portal_drawlist`
4. Renderizza ogni RTT con bypass frustum culling
5. `clearPortalDrawList`

**PortalQuadStep** (dopo Draw3D, prima del post-processing):
- Ordina portali back-to-front
- `drawPortalFaces(src, rtex[i], mainCam)` — tunnel a 5 facce + screen-space UV shader
- Se camera spostata ≥ 4 nodi dall'RTT precedente: ri-renderizza RTT (intra-frame teleport)

Per pipeline senza post-processing: `PortalRenderStep` esegue entrambi i passi.

### Screen-space UV shader (CRITICO)

```glsl
// VS
gl_Position = uMVP * vec4(inVertexPosition, 1.0);
// FS
vec2 uv = vec2(gl_FragCoord.x / W, gl_FragCoord.y / H);
gl_FragColor = texture2D(baseTexture, uv);
```

- NON usare `gl_Vertex` / `gl_ModelViewProjectionMatrix` — Irrlicht OpenGL3 non aggiorna il fixed-function stack
- `inVertexPosition` = nome Irrlicht per `EVA_POSITION=0`
- Y non invertita: RTT OpenGL ha y=0 in basso, `gl_FragCoord` idem

### Camera offset (CRITICO)

```cpp
v3f offset = intToFloat(game_cam->getOffset(), BS);
src.pos -= offset;
dst.pos -= offset;
```

Senza fix: quad portale appare offset di decine/centinaia di nodi.

### Camera virtuale — setVirtualCamera

```cpp
// right = normal × up (identico in C++ e Lua)
float lx = rel.dotProduct(ar), ly = rel.dotProduct(au), lz = rel.dotProduct(an);
v3f vpos = dst_surface + br*(-lx) + bu*ly + bn*(-lz);
// Direzione: negate right e normal
float dx = dir.dotProduct(ar), dy = dir.dotProduct(au), dz = dir.dotProduct(an);
v3f vdir = br*(-dx) + bu*dy + bn*(-dz);
```

### Oblique near-plane clipping (Lengyel)

`setRenderProjectionMatrix` su `CCameraSceneNode` — NON `setProjectionMatrix` (quella aggiorna il frustum CPU → SceneManager culla entità → aree nere).

Attivo **solo quando `side < 0`** (vcam sul lato destinazione). Quando `side > 0` (player dentro il portale, vcam sul lato sorgente): `clearRenderProjectionMatrix()` e skip. Motivo: con `side > 0`, `c_e_w = -side + 0.49*BS` diventa negativo per `side > 0.49*BS` → il near plane obliquo finisce dietro la camera → tutto clippato.

### Piani di clipping laterali (gl_ClipDistance)

Quattro piani frustum calcolati per ogni RTT pass, trasmessi come uniform `portalClipPlanes[4]` a tutti gli shader vertex (`nodes_shader`, `object_shader`). Impediscono al frame del portale destinazione di leakare nell'RTT ad angoli obliqui dove il piano di Lengyel è insufficiente.

**Calcolo** (in `renderPortalRTTs`, Phase 2):
- `vpos` = posizione camera virtuale (render space)
- Se `apex_side > 0` (camera sul lato destinazione = player dentro il portale): check laterale `|lx| < hw && |ly| < hh`; se entrambe vere → **clip planes disabilitate** (player completamente dentro l'apertura)
- Se `apex_side <= 0`: standoff minimo `-0.05*BS` lungo la normale, poi 4 piani frustum da `vpos` attraverso i bordi del portale destinazione

**Ogni piano**: `dot(worldPosition, n) + d >= 0` → dentro (visibile nell'RTT).

**Clamping `nbn < 0`** (inclinazione all'indietro): il piano viene proiettato sul piano del portale (componente `bn` rimossa) e ancorato a `edge_center` → piano corridoio perpendicolare alla faccia. Evita che geometria destinazione venga clippata quando l'apice è spostato lateralmente oltre il bordo.

**Abilitazione GPU**: `GL.Enable(GL_CLIP_DISTANCE0..3)` prima di `drawAll()`, `GL.Disable` subito dopo. Attivi solo se `use_clip_planes = true`.

**Shader**: uniform `portalClipPlanes[4]` dichiarata in entrambi i vertex shader; quattro righe `gl_ClipDistance[k] = dot(worldPosition, portalClipPlanes[k].xyz) + portalClipPlanes[k].w` dopo il calcolo di `worldPosition`.

**`PortalManager`**: `setClipPlanes` / `getClipPlanes` — `GameGlobalShaderUniformSetter::onSetUniforms` legge `getClipPlanes().data` e lo passa all'uniform a ogni cambio materiale/programma.

---

## Logica Lua (init.lua)

### Struttura dati portali

```lua
-- portals[name] = {cx, cy, cz, axis, ns, w, h, link, node_name}
-- portal_index[name] = 0-based C++ index (stabile per ordine alfabetico)
-- anchors[name] = entity object (invisible, pointable, on_rightclick → config GUI)
```

### API pubblica (init.lua)

- `try_activate_near(pos, frame_node, placer)` — scansiona frame vicini, attiva portale
- `deactivate_if_frame(pos)` — disattiva portale se pos è nel frame
- `open_portal_config(player, portal_name)` — apre GUI configurazione
- `ensure_portal_rightclick(node_name)` — patcha `on_rightclick` su nodi esterni usati come cornice

### Geometria portale

```
axis=0: piano XY, normale ±Z
axis=1: piano YZ, normale ±X
ns: segno normale (+1/-1, scelto dal lato del player al momento dell'attivazione)
inner_center: {cx+(w-1)/2, cy+(h-1)/2, cz} (axis=0) oppure {cx, cy+(h-1)/2, cz+(w-1)/2} (axis=1)
```

### Convenzione yaw (CRITICO)

```lua
-- get_look_dir() usa getRadYawDep() = (m_rotation.Y + 90°) × DEGTORAD
-- Per estrarre yaw da look direction:
local new_yaw = math.atan2(-new_look.x, new_look.z)  -- NON atan2(x,z)!
```

### Trigger teletrasporto

```lua
TRIGGER_DEPTH = 0.05  -- nodi

-- Trigger normale: player entra dal fronte e supera profondità
past_trigger(ppos, pp)  →  portal_depth < -TRIGGER_DEPTH

-- Trigger laterale: player entra già al centro/oltre il piano
border_entry = just_entered AND portal_depth <= 0
```

`entered_from_front = true` se al primo frame nei bounds il player era sul lato ns.
`on_ns_side` usa leniency `>= -TRIGGER_DEPTH` per entrate laterali.

### Cam hint lifecycle

```lua
-- Dentro i bounds, entered_from_front=true:
minetest.set_portal_cam_hint(dst_idx, pos_trasformata)   -- ogni frame globalstep

-- Leave bounds (normale):
minetest.clear_portal_cam_hint(dst_idx)

-- Dopo teletrasporto (reset diretto state senza leave handler):
minetest.set_portal_cam_hint(dst_idx, new_pos)   -- pre-render frame di arrivo
player:portal_teleport(...)
minetest.clear_portal_cam_hint(dst_idx)           -- lascia prendere la live camera
```
