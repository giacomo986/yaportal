This project is a Luanti mod with a custom C++ engine that adds 3D portal rendering. The engine is a **git submodule** at `luanti_src/`, tracking the fork `github.com/giacomo986/luanti` on branch `portal-fork` (the fork holds the full set of engine changes as real commits; `master` there tracks upstream for rebases). The mod's Lua logic is in `yaportal/` (single-world play portals) and `yaportal_link/` (cross-world doors — see the dual-client section below).

> **Layout note:** there is no `src_patches/` any more. Engine changes are committed directly in the `luanti_src` submodule and the outer repo records the submodule pointer. If a doc or script still mentions copying `src_patches/`, it is stale — ignore it.

---

## First-time setup

Follow the steps in order. Requires Ubuntu 24.04 x86_64 with access to `apt-get download`.

### 1. Get the engine submodule

```sh
PROJ=/path/to/yaportal   # this repo's directory
# Fresh clone: pull the submodule in one go
git clone --recursive <this-repo-url> $PROJ
# Already cloned without --recursive:
git -C $PROJ submodule update --init luanti_src
```

The submodule is pinned to a commit on the fork's `portal-fork` branch; that
commit already contains every engine change (portal rendering, cross-world
dual-client, etc.). There is nothing to copy or patch on top.

To work on the engine: edit inside `luanti_src/`, commit there (on
`portal-fork`), then `git add luanti_src` in the outer repo to record the new
pointer. See "Committing engine changes" below.

### 2. (nothing to apply)

Skip — kept only so the step numbers match older notes. Engine source is the
submodule checkout itself; no patch step.

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

## Committing engine changes

The engine is a submodule, so a C++ change is two commits — the inner one on
the fork, then the outer pointer bump. Order matters: commit the submodule
first, or the outer records a pointer that does not exist on the remote.

```sh
PROJ=/path/to/yaportal

# 1. Inner: the engine change itself, on the fork's branch.
cd $PROJ/luanti_src
git branch --show-current            # expect: portal-fork
git add -A && git commit -m "feat: ..."

# 2. Outer: record the new submodule commit alongside the mod changes.
cd $PROJ
git add luanti_src <changed mod files>
git commit -m "..."
```

`git status` in the outer repo shows a modified submodule as `m luanti_src`
(lowercase m = the submodule's checkout moved). Pushing is two `git push`es:
the fork (`luanti_src`, GitHub only) and the outer repo (GitHub + Gitea).

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
-- portal_list: 1-based array, max MAX_PORTALS (16) elements
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

---

## Cross-world portals & dual-client (yaportal_link)

A cross-world "door" shows another world live through the portal and walks you
into it. The client holds **two** connections at once: the interactive
*primary* session and a passive *secondary* `WorldSession` (world B), rendered
into the portal's RTT. Crossing swaps the two in place (no reconnect) via
`core.xworld_swap_player`; if there is no ready passive session it falls back to
`core.redirect_player` (a loading screen). Registry is a shared directory of
JSON files under `~/.minetest/yaportal_link/` (see the header of
`yaportal_link/init.lua`).

Manual test: `./play_dualtest.sh` (world B = backportal :30022, open "portal
start"). A crossing that fell back to a redirect logs a `[yaportal_link]
swap-miss` line with the address the mod passed vs what the server holds — read
that first when a hop is not seamless.

### Invariants — break one and a past bug comes back

- **`Sky::applySkyParams` must store the WHOLE `SkyboxParams`** (not just the
  fields its setters touch). `getSkyParams()` is copied into the demoted
  session's sky at swap; if `type`/`bgcolor`/`clouds` fall back to constructor
  defaults, a plain black sky comes back as a white "regular" one after a round
  trip. `handleClientEvent_SetSky` must go through the same `applySkyParams`
  path so the primary sky holds the full set too.

- **At a swap, take the promoted world's sky/clouds/view-range from the passive
  session's live `Sky`/`Clouds`, NOT from the replayed client events.** The
  replay (`deferred.takeAll()`) is empty on every visit after the first — a
  server sends `set_sky` only once — so relying on it paints world B's fog with
  world A's sky on the second round trip. The passive session's own Sky has been
  driven live the whole time; snapshot it (see `performSessionSwap`).

- **`initSecondaryClient()` must no-op if `m_secondary` already exists.** Both
  `startup()` and the step-loop backoff call it, and the backoff can fire during
  world load. A second connect under the same name is refused by the server
  ("already connected"), which drops the working passive session and turns every
  crossing into a redirect. The backoff `teardown()`s (clearing `m_secondary`)
  before it retries, so a session still present is one to keep.

- **`TOSERVER_XWORLD_STATUS` must be re-sent on a timer while the passive
  session is Ready — never fire-and-forget.** The primary server drops in-game
  packets until the client is `CS_Active` there, and world A can keep loading
  for tens of seconds after the passive is already Ready, so a one-shot status
  can vanish ("Got packet command 84 ... Dropping packet."). The server then
  holds `ready=false` forever and EVERY crossing of the session falls back to
  a redirect (`swap-miss ... server-sees ready=false :0 world=`). Same
  deafness window the `/xworld_park` announcement already works around; the
  status heartbeat in `stepSecondaryClient` (2s) is the cure — keep it.

- **Passive-target precedence and re-pairing.** The pair registry
  (`core.set_xworld_target`) WINS over the `yaportal_dualtest_*` settings
  whenever the mods have published a target; the dualtest override is only the
  no-pairing smoke fallback (`Game::secondaryTarget`). Letting the override
  win kept the passive glued to the test port after pairing a door inside a
  `play_dualtest.sh` session: black portal, crossing degraded to redirect —
  and a redirect out of a singleplayer-hosted world KILLS that world's server,
  so the return door goes offline too (a swap keeps it hosted). Retargeting
  (`stepSecondaryClient`): a target naming a DIFFERENT world (≠ the session's
  `target_world` AND ≠ `m_current_world`) is a deliberate re-pair and is
  followed even by a Ready or pinned (just-swapped) session — without the
  pinned bypass, re-pairing after ANY crossing left the passive stuck on the
  old world. The `m_current_world` exclusion keeps the M8 protection: right
  after a swap the registry still names the world just entered, and treating
  that as a re-pair would drop the freshly demoted session. Same-world
  addr:port changes (registry flap / stale endpoint port) still only retarget
  an unpinned, not-yet-Ready session.

- **Cross-game doors are supported, but only under the unique-media-name
  convention.** `TextureSource`, `ISoundManager` and `ItemVisualsManager` are
  shared between the two sessions and keyed by plain file/item name: two games
  serving the same filename with different content silently corrupt each other
  (the passive session skips `rebuildImagesAndTextures()`, and a swap rebuilds
  nothing). `Client::loadMedia` logs `[xworld] media collision: image "..."`
  when the passive session overwrites an image with different bytes — grep for
  it FIRST when a cross-game portal looks visually wrong; sounds and item
  visuals collide silently (no diagnostic). The bundled `yafps` game prefixes
  every file `yafps_` precisely to keep this set empty (verified 0 collisions
  against the full VoxeLibre media set).

### Registry hazards

- Rebuilding a door's frame makes a NEW portal with a new name; `rebind_endpoint`
  re-attaches the old endpoint by position. A stale endpoint file can still name
  an old portal (`ep=portal_6` but `portal=portal_7`) or an old ephemeral port —
  a singleplayer server takes a fresh port each launch, so an endpoint from a
  dead session lists a port nothing listens on. Endpoints are kept while a world
  is offline (so its doors stay pickable) and refreshed on next announce; if a
  hop misbehaves after lots of rebuilds, inspect `~/.minetest/yaportal_link/`.

- `core.get_bind_port()` (not the `port` setting) is the address a hop must
  target: singleplayer picks a free port and `--port` overrides the setting.

- **Background world servers keep the OLD mod code (and binary) until
  restarted.** `start_world` launches them with nohup and they survive the
  client for hours; Lua loads once at launch. After editing yaportal_link /
  yaportal / a game, a fix "verified in smoke but not in game" is usually a
  stale server: `ps -ef | grep bin/luanti`, SIGTERM it (clean shutdown
  retires the heartbeat), the panel restarts it on demand. This masked the
  park physics fix for a whole evening.

### YaFPS — the cross-game destination game (`yafps/`)

`yafps/` (repo root, symlinked as `~/.minetest/games/yafps` for dev, bundled by
`release.sh` and the flatpak manifest) is a minimal FPS arena game meant as a
"different game" portal destination: hitscan rifle (`yafps_weapons.fire_ray`,
server-side raycast — worlds are local, no lag compensation needed), targets
and drones with respawn, crosshair+ammo HUD, arcade movement. The `/porte`
panel's "Nuovo mondo…" button creates a destination world with any installed
game: `create_world()` in `yaportal_link/init.lua` writes a **complete**
`world.mt` (a partial one leaves the gameid unresolvable, the headless server
is launched without `--gameid`), and `installed_games()` replicates the
engine's discovery/de-dup (`subgames.cpp`: strip `_game`, share wins).

Rules that keep it working:

- **Every media file must keep the `yafps_` prefix** — see the media-collision
  invariant above.
- **`yafps_core` must set physics/sky synchronously inside
  `register_on_joinplayer`, never via `minetest.after`.** Load order between
  game mods and global mods is NOT guaranteed (observed: yaportal loads
  before yafps_core), so yaportal_link's `park()` may snapshot ghost physics
  BEFORE the game's join callback sets the arcade values — that produced
  "still walking like the old world" after a swap. `park()` therefore
  re-snapshots and re-freezes in `minetest.after(0)`, which runs after every
  join callback; a game that set physics via its own `after()` would fire
  later still and thaw the parked ghost with an unrecoverable snapshot.
- The game keeps sky `type="regular"` (custom colors): the yaportal overworld
  sky-sync mirrors only regular skies into the portal view.
- A world created from the panel gets its cross-world door pre-built:
  `yafps_arena` carves a frame into the north arena wall and calls
  `yaportal.xworld.activate_frame` with a stand-in placer position inside the
  arena (only `get_pos()` is read; it decides the door's facing).
