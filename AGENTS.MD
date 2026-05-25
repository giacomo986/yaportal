This project is a Luanti mod with a custom C++ engine that adds 3D portal rendering. The patched engine source lives in `luanti_src/` (git-ignored); only the engine modifications are tracked in `src_patches/`. The mod's Lua logic is in `yaportal/`.

---

## First-time setup

Follow the steps in order. Requires Ubuntu 24.04 x86_64 with access to `apt-get download`.

### 1. Clone the Luanti engine

```sh
PROJ=/path/to/yaportal   # this repo's directory
git clone https://github.com/luanti-org/luanti.git $PROJ/luanti_src
# Base commit used for the patches:
git -C $PROJ/luanti_src checkout e35647861  # 5.16.1
```

### 2. Apply the source patches

```sh
PROJ=/path/to/yaportal
cp -r $PROJ/src_patches/. $PROJ/luanti_src/
```

Files added/modified by this project (all in `src_patches/`):

| File | Type |
|------|------|
| `src/portal_manager.h/.cpp` | **new** — `PortalManager` singleton, N portals, cam hint |
| `src/client/render/portal.h/.cpp` | **new** — `PortalRTTData`, `PortalPrepareStep`, `PortalQuadStep`, `PortalRenderStep` |
| `src/client/render/plain.h/.cpp` | modified — inserts portal render steps into the pipeline |
| `src/client/clientmap.h/.cpp` | modified — `updatePortalDrawList`, `clearPortalDrawList` |
| `src/client/client.h` | modified — exposes ClientMap access for rendering |
| `src/client/game.cpp` | modified — starts portal steps |
| `src/client/localplayer.h` | modified — teleportation support |
| `src/client/renderingengine.cpp` | modified — pipeline integration |
| `src/script/lua_api/l_env.h/.cpp` | modified — `set_portals`, `set_portal_cam_hint`, `clear_portal_cam_hint` |
| `src/script/lua_api/l_object.h/.cpp` | modified — `portal_teleport` |
| `src/network/networkprotocol.h` | modified — opcode `TOCLIENT_PORTAL_TELEPORT` |
| `src/network/clientopcodes.cpp` | modified |
| `src/network/serveropcodes.cpp` | modified |
| `src/network/clientpackethandler.cpp` | modified — `handleCommand_PortalTeleport` handler |
| `src/server.h/.cpp` | modified — teleport packet sending |
| `src/server/player_sao.h/.cpp` | modified — `setPlayerYaw`, `getLookPitch` |
| `src/server/clientiface.cpp` | modified |
| `irr/include/ICameraSceneNode.h` | modified — `setRenderProjectionMatrix` |
| `irr/src/CCameraSceneNode.h/.cpp` | modified — `setRenderProjectionMatrix` (no frustum update) |
| `irr/src/CMakeLists.txt` | modified |
| `src/CMakeLists.txt` | modified — adds `portal_manager`, `portal` to build targets |
| `src/client/CMakeLists.txt` | modified |
| `cmake/Modules/FindZstd.cmake` | modified — fix find for static zstd |

### 3. Prepare dependencies

Binary dependencies live in `$PROJ/tmp/` (persistent across reboots). If missing, download them (see [Download .deb packages from scratch](#download-deb-packages-from-scratch)).

```sh
PROJ=/path/to/yaportal

mkdir -p $PROJ/tmp/deps $PROJ/tmp/luajit-extract $PROJ/tmp/leveldb-extract

# Extract all .deb files into deps/
for deb in $PROJ/tmp/*.deb; do
    case "$deb" in
        *luajit*) dpkg-deb -x "$deb" $PROJ/tmp/luajit-extract ;;
        *leveldb*) dpkg-deb -x "$deb" $PROJ/tmp/leveldb-extract ;;
        *) dpkg-deb -x "$deb" $PROJ/tmp/deps ;;
    esac
done

LIBDIR=$PROJ/tmp/deps/usr/lib/x86_64-linux-gnu
SYSLIB=/usr/lib/x86_64-linux-gnu

# Symlink shared system libraries (don't use the static ones from the .deb)
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

# Put curl and jpeg headers in the non-arch path
ln -sf $PROJ/tmp/deps/usr/include/x86_64-linux-gnu/curl    $PROJ/tmp/deps/usr/include/curl
ln -sf $PROJ/tmp/deps/usr/include/x86_64-linux-gnu/jconfig.h $PROJ/tmp/deps/usr/include/jconfig.h

# Copy LuaJIT headers into deps
mkdir -p $PROJ/tmp/deps/usr/include/luajit-2.1
cp -r $PROJ/tmp/luajit-extract/usr/include/luajit-2.1/. $PROJ/tmp/deps/usr/include/luajit-2.1/

# Hide libSDL2.a — cmake prefers it over the .so, causing a static link failure (-lasound etc.)
mv $LIBDIR/libSDL2.a      $LIBDIR/libSDL2.a.bak      2>/dev/null || true
mv $LIBDIR/libSDL2main.a  $LIBDIR/libSDL2main.a.bak  2>/dev/null || true
mv $LIBDIR/libSDL2_test.a $LIBDIR/libSDL2_test.a.bak 2>/dev/null || true
```

### 4. Create /tmp symlinks (after every reboot)

`build.ninja` uses `/tmp/` paths. Recreate after every reboot:

```sh
PROJ=/path/to/yaportal
ln -sfn $PROJ/tmp/deps            /tmp/deps
ln -sfn $PROJ/tmp/luajit-extract  /tmp/luajit-extract
ln -sfn $PROJ/tmp/leveldb-extract /tmp/leveldb-extract
```

Or just use `build.sh` (it does this automatically):

```sh
./build.sh
```

### 5. Configure with CMake (first time or after cache reset)

```sh
PROJ=/path/to/yaportal
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

> If cmake or ninja are not in PATH, set the `CMAKE` and `NINJA` environment variables to their absolute paths before running.

### 6. Regular build (after /tmp symlinks are set)

```sh
./build.sh
# or:
cd /path/to/yaportal/luanti_src/build && ninja -j$(nproc)
```

### 7. Launch the game

```sh
/path/to/yaportal/luanti_src/bin/luanti
```

---

## Updating src_patches/ after C++ changes

After modifying any C++ files in `luanti_src/`, update `src_patches/` and commit:

```sh
PROJ=/path/to/yaportal
SRC=$PROJ/luanti_src
DEST=$PROJ/src_patches

for f in $(git -C $SRC diff --name-only HEAD); do
    mkdir -p "$DEST/$(dirname $f)"
    cp "$SRC/$f" "$DEST/$f"
done
# New files not tracked by luanti_src:
for f in src/portal_manager.cpp src/portal_manager.h \
          src/client/render/portal.cpp src/client/render/portal.h; do
    cp "$SRC/$f" "$DEST/$f"
done

git add src_patches/ && git commit -m "chore: sync src_patches with luanti_src changes"
```

---

## Download .deb packages from scratch

Only if `$PROJ/tmp/*.deb` don't exist:

```sh
PROJ=/path/to/yaportal
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

## Building a portable AppImage

Produces `Luanti-portal-x86_64.AppImage` (~70 MB) runnable on any x86_64 Linux.

### Prerequisites

```sh
sudo apt install patchelf wget libfuse2t64
```

### Run

```sh
PROJ=/path/to/yaportal
CMAKE=/path/to/cmake $PROJ/release.sh
```

`CMAKE` can be omitted if cmake is in PATH. The script:
1. Recreates `/tmp/deps`, `/tmp/leveldb-extract`, `/tmp/luajit-extract` symlinks
2. Creates the `SDL2/_real_SDL_config.h` symlink (arch-specific header required by the build)
3. Recompiles with `RUN_IN_PLACE=FALSE` (binary finds game data at `../` relative to itself)
4. Patches RPATH to `$ORIGIN/../lib` using patchelf
5. Collects all `.so` dependencies (excludes GL/EGL, driver-specific)
6. Downloads `appimagetool` into `tmp/appimage-tools/` (first run only)
7. Produces the AppImage in the repo root

### Notes

- `release.sh` is idempotent: re-running only recompiles changed files.
- GL/EGL/Vulkan are **not** bundled — each machine uses its own drivers.
- AppDir layout:
  ```
  AppDir/
    bin/luanti          ← binary (RPATH: $ORIGIN/../lib)
    lib/*.so            ← bundled dependencies
    client/shaders/     ← GLSL shaders (Luanti looks for path_share/client/shaders/)
    games/ builtin/ fonts/ textures/ locale/ clientmods/
    bundled_mods/yaportal/   ← mod bundled in the AppImage
  ```

---

## Known issues

- **IFUNC conflict**: do NOT use the static `libluajit-5.1.a` — conflicts with glibc IFUNC `memcpy`/`strcasecmp`. Always use the shared `.so`.
- **libSDL2.a in the .deb**: cmake prefers it over the `.so` → static link fails with `-lasound not found`. Fix: rename to `.a.bak` (already in the setup block above).
- **curl/jpeg headers in arch-specific path**: require the symlinks created in the setup step.
- **leveldb requires snappy**: already fixed in `src/CMakeLists.txt`.
- **libluajit RUNPATH**: if the binary says `libluajit-5.1.so.2 not found`, verify that `build.ninja`'s RUNPATH includes `/tmp/luajit-extract/usr/lib/x86_64-linux-gnu`. If not, regenerate with cmake (step 5).
- **ninja/cmake not in PATH**: set `NINJA=/path/to/ninja` or add the directory to PATH.

---

## Portal C++ internals

### Lua API exposed by the engine

```lua
-- Set the active portal list (called by sync_portals in yaportal/init.lua)
-- portal_list: 1-based array, max MAX_PORTALS (8) elements
-- Each element: {pos, normal, up, half_w, half_h, link}
-- link: 0-based index of the destination portal (-1 = none)
minetest.set_portals(portal_list)

-- Override the virtual camera position for portal RTT at index idx (0-based).
-- Used before teleport to pre-render the arrival point.
minetest.set_portal_cam_hint(idx, {x, y, z})   -- world position in node coordinates
minetest.clear_portal_cam_hint(idx)

-- Atomic teleport: pos + yaw + velocity delta in one packet.
-- vel_delta: delta added to the current velocity (not absolute).
player:portal_teleport(pos, yaw_radians, vel_delta)
```

### Rendering technique

**PortalPrepareStep** (before Draw3D):
1. `ensureCameras` — creates vcam[i] once, never destroys them
2. For each active portal with a link: `setVirtualCamera(vcam[i], src, dst, cam_pos)`
3. `updatePortalDrawList` — adds nearby blocks for each vcam to `m_portal_drawlist`
4. Renders each RTT with frustum culling bypassed
5. `clearPortalDrawList`

**PortalQuadStep** (after Draw3D, before post-processing):
- Sorts portals back-to-front
- `drawPortalFaces(src, rtex[i], mainCam)` — 5-face tunnel + screen-space UV shader
- If camera moved ≥ 4 nodes from the previous RTT: re-renders the RTT (intra-frame teleport)

For pipelines without post-processing: `PortalRenderStep` runs both passes.

### Screen-space UV shader (CRITICAL)

```glsl
// VS
gl_Position = uMVP * vec4(inVertexPosition, 1.0);
// FS
vec2 uv = vec2(gl_FragCoord.x / W, gl_FragCoord.y / H);
gl_FragColor = texture2D(baseTexture, uv);
```

- Do NOT use `gl_Vertex` / `gl_ModelViewProjectionMatrix` — Irrlicht OpenGL3 does not update the fixed-function stack
- `inVertexPosition` = Irrlicht name for `EVA_POSITION=0`
- Y not inverted: OpenGL RTT has y=0 at bottom, `gl_FragCoord` same

### Camera offset (CRITICAL)

```cpp
v3f offset = intToFloat(game_cam->getOffset(), BS);
src.pos -= offset;
dst.pos -= offset;
```

Without this fix the portal quad appears offset by tens/hundreds of nodes.

### Virtual camera — setVirtualCamera

```cpp
// right = normal × up (identical in C++ and Lua)
float lx = rel.dotProduct(ar), ly = rel.dotProduct(au), lz = rel.dotProduct(an);
v3f vpos = dst_surface + br*(-lx) + bu*ly + bn*(-lz);
// Direction: negate right and normal
float dx = dir.dotProduct(ar), dy = dir.dotProduct(au), dz = dir.dotProduct(an);
v3f vdir = br*(-dx) + bu*dy + bn*(-dz);
```

### Oblique near-plane clipping (Lengyel)

`setRenderProjectionMatrix` on `CCameraSceneNode` — NOT `setProjectionMatrix` (that updates the CPU frustum → SceneManager culls entities → black patches).

Active **only when `side < 0`** (vcam on the destination side). When `side > 0` (player inside the portal, vcam on the source side): `clearRenderProjectionMatrix()` and skip. Reason: with `side > 0`, `c_e_w = -side + 0.49*BS` goes negative for `side > 0.49*BS` → oblique near plane ends up behind the camera → everything clipped.

### Lateral clip planes (gl_ClipDistance)

Four frustum planes computed for each RTT pass, passed as the `portalClipPlanes[4]` uniform to all vertex shaders (`nodes_shader`, `object_shader`). Prevent the destination portal frame from leaking into the RTT at oblique angles where the Lengyel plane is insufficient.

**Calculation** (in `renderPortalRTTs`, Phase 2):
- `vpos` = virtual camera position (render space)
- If `apex_side > 0` (camera on destination side = player inside the portal): lateral check `|lx| < hw && |ly| < hh`; if both true → **clip planes disabled** (player fully inside the opening)
- If `apex_side <= 0`: minimum standoff `-0.05*BS` along the normal, then 4 frustum planes from `vpos` through the destination portal edges

**Each plane**: `dot(worldPosition, n) + d >= 0` → inside (visible in RTT).

**`nbn < 0` clamping** (backward tilt): the plane is projected onto the portal plane (the `bn` component is removed) and anchored to `edge_center` → a corridor plane perpendicular to the face. Prevents destination geometry from being clipped when the apex is displaced laterally past an edge.

**GPU activation**: `GL.Enable(GL_CLIP_DISTANCE0..3)` before `drawAll()`, `GL.Disable` right after. Active only when `use_clip_planes = true`.

**Shaders**: uniform `portalClipPlanes[4]` declared in both vertex shaders; four lines `gl_ClipDistance[k] = dot(worldPosition, portalClipPlanes[k].xyz) + portalClipPlanes[k].w` after `worldPosition` is computed.

**`PortalManager`**: `setClipPlanes` / `getClipPlanes` — `GameGlobalShaderUniformSetter::onSetUniforms` reads `getClipPlanes().data` and passes it to the uniform on every material/program change.

---

## Lua logic (yaportal/init.lua)

### Portal data structure

```lua
-- portals[name] = {cx, cy, cz, axis, ns, w, h, link, node_name}
-- portal_index[name] = 0-based C++ index (stable by alphabetical sort)
-- anchors[name] = entity object (invisible, pointable, on_rightclick → config GUI)
```

### Public API (init.lua)

- `try_activate_near(pos, frame_node, placer)` — scans nearby frames, activates portal
- `deactivate_if_frame(pos)` — deactivates portal if pos is in the frame
- `open_portal_config(player, portal_name)` — opens the config GUI
- `ensure_portal_rightclick(node_name)` — patches `on_rightclick` on external nodes used as frames

### Portal geometry

```
axis=0: XY plane, normal ±Z
axis=1: YZ plane, normal ±X
ns: normal sign (+1/-1, chosen from player side at activation time)
inner_center: {cx+(w-1)/2, cy+(h-1)/2, cz} (axis=0) or {cx, cy+(h-1)/2, cz+(w-1)/2} (axis=1)
```

### Yaw convention (CRITICAL)

```lua
-- get_look_dir() uses getRadYawDep() = (m_rotation.Y + 90°) × DEGTORAD
-- To extract yaw from look direction:
local new_yaw = math.atan2(-new_look.x, new_look.z)  -- NOT atan2(x,z)!
```

### Teleport trigger

```lua
TRIGGER_DEPTH = 0.05  -- nodes

-- Normal trigger: player enters from front and crosses the trigger depth
past_trigger(ppos, pp)  →  portal_depth < -TRIGGER_DEPTH

-- Border entry: player enters already at center or past the plane
border_entry = just_entered AND portal_depth <= 0
```

`entered_from_front = true` if on the first frame inside bounds the player was on the ns side.
`on_ns_side` uses leniency `>= -TRIGGER_DEPTH` for lateral entries.

### Cam hint lifecycle

```lua
-- Inside bounds, entered_from_front=true:
minetest.set_portal_cam_hint(dst_idx, transformed_pos)   -- every globalstep frame

-- Leave bounds (normal):
minetest.clear_portal_cam_hint(dst_idx)

-- After teleport (direct state reset, bypasses normal leave handler):
minetest.set_portal_cam_hint(dst_idx, new_pos)   -- pre-render the arrival frame
player:portal_teleport(...)
minetest.clear_portal_cam_hint(dst_idx)           -- hand off to the live camera
```
