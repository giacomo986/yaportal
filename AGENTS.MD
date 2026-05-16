Questo progetto è una mod per Luanti. Usa l'API Lua di Luanti. I file principali sono init.lua. Per testare, l'agente deve verificare la sintassi con luacheck

---

## Build del motore (C++)

Il sorgente del motore è in `luanti_src/`. La build usa CMake + Ninja.

### Comandi build

Le dipendenze sono in `PROJECT/tmp/` (persistente). `/tmp/deps`, `/tmp/luajit-extract`, `/tmp/leveldb-extract` sono symlink → `PROJECT/tmp/`. Dopo ogni riavvio ricreare i symlink (un comando), poi build normale.

**Dopo riavvio — ricreare symlink:**
```sh
PROJ=~/luanti/mods/yaportal
ln -sfn $PROJ/tmp/deps            /tmp/deps
ln -sfn $PROJ/tmp/luajit-extract  /tmp/luajit-extract
ln -sfn $PROJ/tmp/leveldb-extract /tmp/leveldb-extract
```

**Build normale (dopo symlink):**
```sh
NINJA=/usr/bin/ninja
BUILD_DIR=~/luanti/mods/yaportal/luanti_src/build

touch $BUILD_DIR/build.ninja   # evita loop cmake↔ninja
cd $BUILD_DIR && $NINJA -j$(nproc)
```

**Solo se build.ninja deve essere rigenerato** (dopo cmake cache delete):
```sh
CMAKE=/usr/bin/cmake
NINJA=/usr/bin/ninja
SRC=~/luanti/mods/yaportal/luanti_src
BUILD_DIR=$SRC/build

rm -f $BUILD_DIR/CMakeCache.txt
cd $BUILD_DIR && $CMAKE \
  -DCMAKE_BUILD_TYPE=Debug \
  -DBUILD_UNITTESTS=TRUE \
  -DENABLE_POSTGRESQL=OFF \
  -DENABLE_REDIS=OFF \
  -DENABLE_SYSTEM_GMP=ON \
  -DGMP_LIBRARY=/usr/lib/libgmp.so \
  -DGMP_INCLUDE_DIR=/usr/include \
  -DCMAKE_PREFIX_PATH=/tmp/deps/usr \
  -DCMAKE_INCLUDE_PATH="/tmp/deps/usr/include;/tmp/deps/usr/include/x86_64-linux-gnu;/tmp/luajit-extract/usr/include" \
  -DCMAKE_LIBRARY_PATH="/tmp/deps/usr/lib/x86_64-linux-gnu;/tmp/luajit-extract/usr/lib/x86_64-linux-gnu" \
  -DLUA_INCLUDE_DIR=/tmp/deps/usr/include/luajit-2.1 \
  -DLUA_LIBRARY=/tmp/luajit-extract/usr/lib/x86_64-linux-gnu/libluajit-5.1.so \
  -DLEVELDB_INCLUDE_DIR=/tmp/leveldb-extract/usr/include \
  -DLEVELDB_LIBRARY=/tmp/deps/usr/lib/x86_64-linux-gnu/libleveldb.a \
  $SRC
touch $BUILD_DIR/build.ninja
cd $BUILD_DIR && $NINJA -j$(nproc)
```

`ninja` e `cmake` non sono nel PATH di sistema — usare i percorsi assoluti sopra.

Il binario prodotto è `luanti_src/bin/luanti`. Per avviarlo:

```sh
~/luanti/mods/yaportal/luanti_src/bin/luanti
```

### Dipendenze

Le dipendenze vivono in `PROJECT/tmp/` (persistente tra riavvii). `/tmp/deps` ecc. sono symlink → `PROJECT/tmp/` (da ricreare dopo ogni riavvio con il comando sopra).

**Setup da zero** (solo se `PROJECT/tmp/deps` non esiste):

```sh
PROJ=~/luanti/mods/yaportal
mkdir -p $PROJ/tmp/deps $PROJ/tmp/luajit-extract $PROJ/tmp/leveldb-extract
ln -sfn $PROJ/tmp/deps            /tmp/deps
ln -sfn $PROJ/tmp/luajit-extract  /tmp/luajit-extract
ln -sfn $PROJ/tmp/leveldb-extract /tmp/leveldb-extract
cd $PROJ/tmp

apt-get download libsdl2-dev libsdl2-2.0-0 zlib1g-dev libjpeg-turbo8-dev libjpeg8-dev \
  libpng-dev libgl-dev libopenal-dev libcurl4-openssl-dev libbrotli-dev libbz2-dev \
  libzstd-dev liblua5.4-dev libsqlite3-dev libleveldb-dev libvorbis-dev libogg-dev \
  libgmp-dev libfreetype-dev libharfbuzz-dev libglu1-mesa-dev \
  libsnappy-dev libsnappy1v5

for deb in $PROJ/tmp/*.deb; do dpkg-deb -x "$deb" /tmp/deps; done

LIBDIR=/tmp/deps/usr/lib/x86_64-linux-gnu
SYSLIB=/usr/lib/x86_64-linux-gnu

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

find $LIBDIR -maxdepth 1 -type l | while read lnk; do
  target=$(readlink "$lnk")
  if [[ "$target" != /* ]] && [ ! -e "$(dirname $lnk)/$target" ]; then
    name=$(basename "$lnk" .so)
    sys=$(ls $SYSLIB/${name}.so.* 2>/dev/null | head -1)
    [ -n "$sys" ] && ln -sf "$sys" "$lnk"
  fi
done

ln -sf /tmp/deps/usr/include/x86_64-linux-gnu/curl /tmp/deps/usr/include/curl

# jconfig.h estratto dal deb finisce come symlink rotto: fixare manualmente
ln -sf /tmp/deps/usr/include/x86_64-linux-gnu/jconfig.h /tmp/deps/usr/include/jconfig.h

# libSDL2.a nel deb causa link statico (richiede -lasound ecc.) → nasconderla
mv $LIBDIR/libSDL2.a     $LIBDIR/libSDL2.a.bak     2>/dev/null || true
mv $LIBDIR/libSDL2main.a $LIBDIR/libSDL2main.a.bak 2>/dev/null || true
mv $LIBDIR/libSDL2_test.a $LIBDIR/libSDL2_test.a.bak 2>/dev/null || true
```

**LuaJIT** (libluajit-5.1.so.2):

```sh
cd $PROJ/tmp
apt-get download libluajit-5.1-dev libluajit-5.1-2 2>/dev/null || true
for deb in $PROJ/tmp/libluajit*.deb; do dpkg-deb -x "$deb" /tmp/luajit-extract 2>/dev/null; done
# copia headers in deps
mkdir -p /tmp/deps/usr/include/luajit-2.1
cp -r /tmp/luajit-extract/usr/include/luajit-2.1/. /tmp/deps/usr/include/luajit-2.1/
```

**LevelDB headers**:
```sh
cd $PROJ/tmp
apt-get download libleveldb-dev
for deb in $PROJ/tmp/libleveldb*.deb; do dpkg-deb -x "$deb" /tmp/leveldb-extract; done
```

Il `build.ninja` usa LuaJIT come `.so` condivisa (non `.a` statica) per evitare conflitti IFUNC con glibc.
Il RUNPATH del binario include `/tmp/luajit-extract/usr/lib/x86_64-linux-gnu`.

**IMPORTANTE**: dopo aver estratto i deb e creato i symlink, rieseguire CMake (vedi comando build nella sezione Comandi build) prima di ninja. CMake deve trovare `libSDL2.so` (non `.a`) per generare il link dinamico corretto.

### Problemi noti

- **IFUNC conflict**: NON usare `libluajit-5.1.a` statica — conflitto `memcpy`/`strcasecmp` con glibc IFUNC. Usare sempre `.so` condivisa.
- **libSDL2.a nel deb causa link statico**: il deb include `libSDL2.a` che cmake preferisce alla `.so`. Fix: rinominare in `.a.bak` (già nel blocco sh sopra) poi rieseguire cmake. Sintomo: link fallisce con `-lasound not found`.
- **curl header in path arch-specifico**: dopo estrazione serve il symlink sopra.
- **leveldb richiede snappy**: già fixato in `src/CMakeLists.txt`.
- **libluajit RUNPATH**: se il binario dice "libluajit-5.1.so.2 not found", serve riscrivere il RUNPATH in build.ninja aggiungendo `/tmp/luajit-extract/usr/lib/x86_64-linux-gnu` alla voce `-Wl,-rpath,...` nella riga `LINK_LIBRARIES` e ricompilare.

---

## File portale (C++)

File aggiunti/modificati nel motore:

- `luanti_src/src/client/render/portal.h/.cpp` — rendering RTT + quad portale
- `luanti_src/src/portal_manager.h/.cpp` — singleton `PortalManager` con 2 `PortalInfo` + cam hint
- `luanti_src/src/client/clientmap.h/.cpp` — `updatePortalDrawList`, `clearPortalDrawList`, loop in `renderMap`
- `luanti_src/src/script/lua_api/l_env.cpp/.h` — `l_set_portals`, `l_set_portal_cam_hint`
- `luanti_src/src/script/lua_api/l_object.cpp/.h` — `l_portal_teleport`
- `luanti_src/src/network/clientpackethandler.cpp` — `handleCommand_PortalTeleport`
- `luanti_src/src/server/player_sao.cpp/.h` — `setPlayerYaw`, `getLookPitch`
- `luanti_src/irr/src/CCameraSceneNode.h/.cpp` — `setRenderProjectionMatrix`, `clearRenderProjectionMatrix`

### API Lua

```lua
-- Imposta/aggiorna posizione portali (chiamato da sync_portals in init.lua)
minetest.set_portals(p0, p1)
-- p0, p1 = {pos={x,y,z}, normal={x,y,z}, up={x,y,z}} oppure nil
-- pos in coordinate nodo (moltiplicato per BS in C++)
-- normal e up vettori unitari; right = normal × up (calcolato in C++)

-- Pre-renderizza RTT portale destinazione dalla posizione di uscita
minetest.set_portal_cam_hint(portal_idx, pos_world)
minetest.clear_portal_cam_hint(portal_idx)

-- Teletrasporto atomico: pos + yaw + vel_delta in un pacchetto
player:portal_teleport(pos, yaw_radians, vel_delta)
-- yaw_radians → converito in gradi → setPlayerYaw(degrees)
-- vel_delta aggiunto alla velocità corrente (delta, non assoluto)
```

### Tecnica di rendering

**PortalPrepareStep** (prima di Draw3D):
1. Per ogni portale i: posiziona `vcam[i]` tramite `setVirtualCamera`, aggiorna posizione assoluta
2. Chiama `cmap.updatePortalDrawList(vcam_world_positions)` — aggiunge blocchi vicini a ogni vcam alla `m_portal_drawlist` (bypassa frustum della camera principale)
3. Per ogni portale i: renderizza scena su `rtex[i]` con `setBypassFrustumCulling(true)`
4. Chiama `cmap.clearPortalDrawList()` — libera i blocchi extra

**PortalQuadStep** (dopo Draw3D, prima del post-processing):
- Ordina portali back-to-front
- Per ognuno: `drawPortalFaces(src, rtex[i], mainCam)`
- Se camera si è spostata ≥ 4 nodi dall'RTT precedente (intra-frame teleport): ri-renderizza RTT

Per pipeline senza post-processing: `PortalRenderStep` esegue entrambi i passi.

### Geometria portale 3D (tunnel a 5 facce)

```
camera →  |front|   center   |RTT face|back|
           z>0       z=0    -TUNNEL_DEPTH  -0.5BS
```

Costanti:
```cpp
PORTAL_HALF_W      = 1.0f * BS    // metà apertura (2 nodi)
PORTAL_HALF_H      = 1.5f * BS    // metà altezza (3 nodi)
PORTAL_TUNNEL_DEPTH = 0.45f * BS  // profondità tunnel
```

**`drawPortalFaces`**: 4 pareti laterali + 1 faccia RTT posteriore. Tutte e 5 usano lo stesso GLSL shader screen-space (vedi sotto). `side_sign = sign((camPos - src.pos)·src.normal)`.

**Visibilità quad**: `d = (camPos - src.pos)·src.normal`. Portale visibile finché `d >= -0.45*BS` (player è al 95% attraverso il frame).

### Screen-space UV shader (CRITICO)

Tutte e 5 le facce del tunnel usano un custom GLSL shader:

```glsl
// VS: attribute inVertexPosition, uniform uMVP
gl_Position = uMVP * vec4(inVertexPosition, 1.0);

// FS: gl_FragCoord normalizzato per UV
vec2 uv = vec2(gl_FragCoord.x / W, gl_FragCoord.y / H);
gl_FragColor = texture2D(baseTexture, uv);
```

- NON usare `gl_Vertex` o `gl_ModelViewProjectionMatrix` — Irrlicht OpenGL3 non aggiorna il fixed-function stack
- `inVertexPosition` è il nome Irrlicht per `EVA_POSITION=0`
- MVP = `getTransform(ETS_PROJECTION) * getTransform(ETS_VIEW) * getTransform(ETS_WORLD)`
- Y NON invertita: RTT OpenGL ha y=0 in basso, `gl_FragCoord` idem → corrispondenza diretta

### Camera offset (CRITICO)

Luanti sposta la camera Irrlicht vicino all'origine sottraendo un offset da tutte le posizioni di rendering.

```cpp
v3f offset = intToFloat(game_cam->getOffset(), BS);
data.cam_offset_world = offset;
src.pos -= offset;  // in setVirtualCamera e drawPortalFaces
dst.pos -= offset;
```

Senza fix: quad portale appare offset di decine/centinaia di nodi.

### Camera virtuale — `setVirtualCamera`

Trasformazione: decomposizione in base (right, up, normal) del portale sorgente, rimappata sul portale destinazione con **negazione di right e normal**:

```cpp
v3f ar = right_of(src), au = src.up, an = src.normal;  // right = normal × up
v3f br = right_of(dst), bu = dst.up, bn = dst.normal;

// Posizione
float lx = rel.dotProduct(ar), ly = rel.dotProduct(au), lz = rel.dotProduct(an);
v3f vpos = dst_surface + br*(-lx) + bu*ly + bn*(-lz);

// Direzione
float dx = dir.dotProduct(ar), dy = dir.dotProduct(au), dz = dir.dotProduct(an);
v3f vdir = br*(-dx) + bu*dy + bn*(-dz);
```

**Questa è la trasformazione canonica per portali.** Lua usa la stessa formula per velocità e sguardo.

### Oblique near-plane clipping (Lengyel)

Scopo: GPU clipa geometria davanti al portale, senza area nera nell'RTT.

**Patch critica**: usare `setRenderProjectionMatrix` (NON `setProjectionMatrix`) su `CCameraSceneNode`. `setProjectionMatrix` aggiorna anche il frustum CPU → SceneManager culla entità → aree nere. `setRenderProjectionMatrix` invia solo al driver/shader.

**Formula per Irrlicht LH OpenGL [-1,+1]** (row3=(0,0,1,0), w_clip=z_eye):

```cpp
float c_e_x = -clip_n.dotProduct(vright_axis);
float c_e_y =  clip_n.dotProduct(vup);
float c_e_z =  clip_n.dotProduct(vdir);
float c_e_w =  clip_n.dotProduct(vpos - dst_surface);

// P^{-T}: (1/M[0], 1/M[5], 0/1/M[14], 1/-M[10]/M[14])
float cc_x = c_e_x / m[0];
float cc_y = c_e_y / m[5];
float cc_z = c_e_w / m[14];
float cc_w = c_e_z - (m[10] / m[14]) * c_e_w;

float lam = 2.0f / (abs(cc_x) + abs(cc_y) + cc_z + cc_w);
m[2] = lam*c_e_x; m[6] = lam*c_e_y; m[10] = lam*c_e_z - 1.0f; m[14] = lam*c_e_w;
vcam->setRenderProjectionMatrix(proj);
```

### updatePortalDrawList / clearPortalDrawList

Aggiunto in `clientmap.h/.cpp` per risolvere il problema di chunk non caricati quando il portale destinazione è fuori dal frustum principale.

```cpp
// Popola m_portal_drawlist con blocchi vicini a ogni vcam world position
void ClientMap::updatePortalDrawList(const std::vector<v3f> &portal_cam_positions);

// Libera refcount e svuota m_portal_drawlist + m_portal_keeplist
void ClientMap::clearPortalDrawList();
```

In `renderMap()`, dopo il loop su `m_drawlist`, loop aggiuntivo su `m_portal_drawlist` senza frustum culling.

---

## Logica Lua (init.lua)

### Struttura cornice

- Cornice 4×5 nodi (apertura interna 2×3 nodi di aria)
- Due colori: `mio_portale:portal_blue`, `mio_portale:portal_orange`
- `axis=0`: normale ±Z, `axis=1`: normale ±X

### Attivazione

Quando un blocco cornice viene piazzato, `try_activate_near` scansiona angoli possibili e chiama `check_frame`. Se completa: salva `{cx,cy,cz,axis,ns}`, chiama `sync_portals` → `minetest.set_portals`.

`ns` = segno normale: +1 se player è sul lato +Z/+X al momento del piazzamento, -1 altrimenti.

### Base locale portale

```lua
local function portal_basis(pp)
    local ns = pp.ns or 1
    if pp.axis == 0 then
        return {x=0,y=0,z=ns}, {x=-ns,y=0,z=0}  -- (normal, right)
    else
        return {x=ns,y=0,z=0}, {x=0,y=0,z=ns}
    end
end
-- right = normal × up (identico a C++ right_of)
```

### Trasformazione portale — posizione

```lua
local function portal_transform_pos(v, src_n, src_r, dst_n, dst_r)
    local lr = dot(v, src_r)
    local lu = v.y
    local ln = dot(v, src_n)
    local dst_ln = -ln  -- clampato a ±0.02 min
    return {
        x = (-lr)*dst_r.x + dst_ln*dst_n.x,
        y = lu,
        z = (-lr)*dst_r.z + dst_ln*dst_n.z,
    }
end
```

### Trasformazione portale — direzione (velocità / sguardo)

**Formula identica a `setVirtualCamera` C++**: negate both right and normal components.

```lua
local function portal_transform_dir(v, src_n, src_r, dst_n, dst_r)
    local lr = dot(v, src_r)
    local lu = v.y
    local ln = dot(v, src_n)
    return {
        x = (-lr)*dst_r.x + (-ln)*dst_n.x,
        y = lu,
        z = (-lr)*dst_r.z + (-ln)*dst_n.z,
    }
end
-- Derivazione: r_src → -r_dst (player_right when entering = r_src;
-- player_right when exiting = -r_dst due to right_of = n×u convention).
-- Verifica: facing portals = direction preserved; same-dir portals = 180° flip; 90° = 90° rotation.
```

### Convenzione yaw — CRITICO

```lua
-- get_look_dir() usa getRadYawDep() = (m_rotation.Y + 90°) × DEGTORAD
-- look.x = cos(rot.Y + 90°) = -sin(rot.Y_rad)
-- look.z = sin(rot.Y + 90°) =  cos(rot.Y_rad)
-- get_look_horizontal() restituisce rot.Y_rad = m_rotation.Y × DEGTORAD

-- Per estrarre rot.Y_rad da look direction:
local new_yaw = math.atan2(-new_look.x, new_look.z)  -- NON atan2(x,z)!
-- atan2(x,z) è sbagliato: porta a errore di 90° per portali con uscita lungo X (axis=1)
```

### Trigger teletrasporto

```lua
local TRIGGER_DEPTH = 0.05  -- 5% del nodo = 55% depth da centro

local function portal_depth(ppos, pp)
    local ns = pp.ns or 1
    return pp.axis==0 and (ppos.z - pp.cz)*ns or (ppos.x - pp.cx)*ns
end

-- Trigger normale: player entra dal fronte (ns side) e supera 55% di profondità
local function past_trigger(ppos, pp)
    return portal_depth(ppos, pp) < -TRIGGER_DEPTH
end

-- Trigger laterale: player entra dai bordi già al centro/oltre il piano
-- border_entry = just_entered AND portal_depth <= 0
```

`entered_from_front`: true se al primo frame nei bounds il player era sul lato ns (`on_ns_side`).
`on_ns_side` usa leniency `>= -TRIGGER_DEPTH` per gestire entrate laterali leggermente oltre il piano.

### Blocco teletrasporto

```lua
local src_n, src_r = portal_basis(src)
local dst_n, dst_r = portal_basis(dst)

local rel     = ppos - inner_center(src)
local new_off = portal_transform_pos(rel, src_n, src_r, dst_n, dst_r)
local new_pos = inner_center(dst) + new_off

local vel      = player:get_velocity()
local new_vel  = portal_transform_dir(vel,  src_n, src_r, dst_n, dst_r)
local look     = player:get_look_dir()
local new_look = portal_transform_dir(look, src_n, src_r, dst_n, dst_r)
local new_yaw  = math.atan2(-new_look.x, new_look.z)  -- vedi convenzione sopra

minetest.set_portal_cam_hint(dst_idx, new_pos)  -- pre-render RTT
player:portal_teleport(new_pos, new_yaw, {
    x = new_vel.x - vel.x,
    y = new_vel.y - vel.y,
    z = new_vel.z - vel.z,
})
```

Cooldown: 0.5s dopo ogni teletrasporto.
`state[dst_color].entered_from_front = false` blocca re-trigger immediato all'uscita.

### Posizione portale

```lua
local function inner_center(pp)
    if pp.axis == 0 then
        return {x=pp.cx+(W-1)/2, y=pp.cy+(H-1)/2, z=pp.cz}
    else
        return {x=pp.cx,         y=pp.cy+(H-1)/2, z=pp.cz+(W-1)/2}
    end
end
-- Centro geometrico esatto — nessun offset ±ns
```
