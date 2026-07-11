# yaportal

A [Luanti](https://www.luanti.org/) mod that adds Portal-style 3D portals: real-time rendering of what's on the other side, teleportation with orientation correction, and per-player pocket dimensions.

Requires a custom build of Luanti 5.16.1 with the C++ patches included in this repo (`src_patches/`). See [Building from source](#building-from-source) below.

---

## Download

Pre-built packages for Linux x86\_64:

- **[Luanti-portal-x86\_64.AppImage](https://github.com/giacomo986/yaportal/releases/download/v0.4.0-alpha/Luanti-portal-x86_64.AppImage)**
- **[Luanti-portal-x86\_64.flatpak](https://github.com/giacomo986/yaportal/releases/download/v0.4.0-alpha/Luanti-portal-x86_64.flatpak)** — install with `flatpak install --user Luanti-portal-x86_64.flatpak`

(or browse all releases on [GitHub](https://github.com/giacomo986/yaportal/releases))

---

## Quick start (AppImage)

Download the AppImage above, or build it yourself with `release.sh` (see [Build AppImage](#build-appimage)), then:

```sh
chmod +x Luanti-portal-x86_64.AppImage
./Luanti-portal-x86_64.AppImage
```

On first launch, the AppImage automatically installs the `yaportal` mod into your Luanti user directory (`~/.luanti/mods/` or `~/.minetest/mods/`). Create or open a world, go to **Settings → Mods** and enable `yaportal`.

> **Compatibility note.** The AppImage runs on any modern Linux kernel; the kernel version is not the limiting factor. Two host requirements matter:
>
> - **FUSE** — AppImages self-mount through FUSE. Most distributions ship FUSE in the kernel, but the userspace library `libfuse2` is often missing on recent releases (they default to FUSE 3). Install it (`sudo apt install libfuse2`), or run without FUSE entirely:
>   ```sh
>   ./Luanti-portal-x86_64.AppImage --appimage-extract-and-run
>   ```
> - **glibc** — `libc`/`libstdc++` are not bundled, so the AppImage uses the host's C library. It runs on systems whose glibc is **at least as new** as the machine it was built on. An error like `version 'GLIBC_2.x' not found` means the host glibc is too old; use a host with a newer glibc or rebuild on an older one (see [Build AppImage](#build-appimage)).

---

## Mod items

### Portal frame (`yaportal:frame`)

The base block for building manual portals. Also available in blue (`frame_blue`) and orange (`frame_orange`) variants.

**Building a manual portal:**
1. Build a rectangular frame with `frame` blocks (inner width 1–8, inner height 2–8 nodes).
2. The portal activates automatically when the frame is complete.
3. **Right-click** any frame block (or the invisible anchor entity at the center) to open the configuration GUI:
   - **Name** — assign a unique name to the portal.
   - **Link to** — choose which portal this one leads to.
   - **Frame material** — change the frame texture.

### Portal Gun (`yaportal:portal_gun`)

Places portals on surfaces without building a frame.

| Action | Effect |
|--------|--------|
| Left click | Place blue portal on the pointed surface |
| Right click | Place orange portal on the pointed surface |

The two portals are automatically linked. Walking through one teleports the player with correct orientation.

### Wall Portal Gun (`yaportal:portal_gun4`)

Carves a portal *into* a craftable **Portal Wall Block** surface (the portal sits flush in the wall instead of in front of it).

| Action | Effect |
|--------|--------|
| Left click | Carve blue portal into the pointed Portal Wall Block |
| Right click | Carve orange portal into the pointed Portal Wall Block |

On a **floor/ceiling** the portal orients along the nearest cardinal to your view and grows *away* from you: the block you point at is the near edge, with the portal extending one block forward (it falls back to the opposite side if that block can't form the portal).

A portal whose pair doesn't exist yet stays **closed** — a solid block showing only the coloured frame (no see-through hole, no fall-through). It opens once both blue and orange are placed; removing one re-closes the other.

### Pocket Dimension Gun (`yaportal:pocket_gun`)

Creates a private pocket dimension for the player.

| Action | Effect |
|--------|--------|
| Left click | Open a portal to the player's pocket dimension |
| Right click | Close and destroy the pocket dimension |

The pocket dimension is a 32×32 platform in an isolated space. Each player has their own.

### Portal-1 interactive blocks

A set of Aperture-style puzzle blocks, all linkable through a shared trigger
system (super buttons, push buttons, and *trigger spaces* — invisible volumes
drawn with the Trigger Wand):

| Block | Description |
|-------|-------------|
| **Weighted Storage Cube** | Carryable cube entity (right-click to pick up / drop). Presses super buttons. |
| **Super Button** (`yaportal:superbutton`) | 2x2 floor button, pressed by players and cubes. Mesecons receptor. |
| **Push Button** (`yaportal:pushbutton`) | Small wall/floor/ceiling button; punch or right-click for a ~1s trigger pulse. Generic trigger for vents, doors and clocks. |
| **Vital Apparatus Vent** (`yaportal:dispenser`) | 2x2x2 cube dispenser, open at the bottom. Right-click opens its settings: Enable/Disable/Dispense buttons, start/stop/dispense trigger bindings, and a max cube distance. The vent tracks its own cube: dispensing (or straying past the distance limit) destroys the previous cube with a fizzle effect, and a lost cube is automatically replaced while the vent is enabled. |
| **Automatic Door** (`yaportal:door`) | 2x2 door. Config form: name, normally-open, trigger bindings (hold/open/close), and Open/Close/Auto buttons for an immediate manual override that wins over every trigger. With no bindings it works automatically (nearby super button, else proximity). |
| **Countdown Clock** (`yaportal:clock`) | 2-wide 7-segment timer; on zero it fires a linked blue+orange wall-portal pair. Startable from triggers or mesecons. |
| **Portal Gun Pedestal** (`yaportal:pedestal`) | 2x2 stand displaying a portal gun. Right-click with a gun to put it on display; walking up to the pedestal hands the gun to the player. |
| **Trigger Wand** (`yaportal:trigger_wand`) | Draws and manages trigger spaces (pure volumes usable as bindings by doors, vents and clocks). |

---

## Building from source

### Prerequisites

- Ubuntu 24.04 x86\_64 (other distros untested)
- `build-essential`, `cmake`, `ninja-build`, `patchelf`, `wget`
  ```sh
  sudo apt install build-essential cmake ninja-build patchelf wget
  ```

### First-time setup

```sh
PROJ=/path/to/yaportal   # this repo's directory

# 1. Clone Luanti at the correct base commit
git clone https://github.com/luanti-org/luanti.git $PROJ/luanti_src
git -C $PROJ/luanti_src checkout e35647861   # tag 5.16.1

# 2. Apply the C++ patches
cp -r $PROJ/src_patches/. $PROJ/luanti_src/

# 3. Download binary dependencies
mkdir -p $PROJ/tmp
cd $PROJ/tmp
apt-get download \
  libsdl2-dev libsdl2-2.0-0 zlib1g-dev libjpeg-turbo8-dev libjpeg8-dev \
  libpng-dev libgl-dev libopenal-dev libcurl4-openssl-dev libbrotli-dev libbz2-dev \
  libzstd-dev libsqlite3-dev libleveldb-dev libvorbis-dev libogg-dev

# Extract the .deb files
for deb in $PROJ/tmp/*.deb; do
    case "$deb" in
        *luajit*)   dpkg-deb -x "$deb" $PROJ/tmp/luajit-extract ;;
        *leveldb*)  dpkg-deb -x "$deb" $PROJ/tmp/leveldb-extract ;;
        *)          dpkg-deb -x "$deb" $PROJ/tmp/deps ;;
    esac
done

# Symlink shared system libraries
LIBDIR=$PROJ/tmp/deps/usr/lib/x86_64-linux-gnu
SYSLIB=/usr/lib/x86_64-linux-gnu
ln -sf $SYSLIB/libSDL2-2.0.so.0     $LIBDIR/libSDL2.so
ln -sf $SYSLIB/libcurl.so.4         $LIBDIR/libcurl.so
ln -sf $SYSLIB/libjpeg.so.8         $LIBDIR/libjpeg.so
ln -sf $SYSLIB/libopenal.so.1       $LIBDIR/libopenal.so
ln -sf $SYSLIB/libGL.so.1           $LIBDIR/libGL.so
ln -sf $SYSLIB/libzstd.so.1         $LIBDIR/libzstd.so
# Hide SDL2 static libs to prevent cmake from preferring them over the .so
mv $LIBDIR/libSDL2.a     $LIBDIR/libSDL2.a.bak     2>/dev/null || true
mv $LIBDIR/libSDL2main.a $LIBDIR/libSDL2main.a.bak 2>/dev/null || true

# Fix header symlinks
ln -sf $PROJ/tmp/deps/usr/include/x86_64-linux-gnu/curl $PROJ/tmp/deps/usr/include/curl
mkdir -p $PROJ/tmp/deps/usr/include/luajit-2.1
cp -r $PROJ/tmp/luajit-extract/usr/include/luajit-2.1/. $PROJ/tmp/deps/usr/include/luajit-2.1/

# 4. Configure CMake (first time only)
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

### Regular build

After the first-time setup, just run:

```sh
./build.sh
```

The script recreates the `/tmp/` symlinks (deleted on reboot) and runs `ninja`.

### Dev launch

```sh
./luanti_src/bin/luanti
```

Enable the `yaportal/` mod in the world settings as you would any global mod.

### Build AppImage

```sh
./release.sh
```

Produces `Luanti-portal-x86_64.AppImage` in the project root. Requires `patchelf`, `wget`, and `libfuse2`.

**For maximum portability, build on the oldest glibc you want to support.** `libc`/`libstdc++` are not bundled, so the resulting AppImage only runs on systems with a glibc equal to or newer than the build host's. Building inside a container based on an old LTS (e.g. an older Ubuntu/Debian) yields the widest compatibility.

---

## Credits

- **Giacomo Perin** — author
- **Claude** (Anthropic) — co-author

---

## Keeping src_patches/ in sync

After modifying C++ files in `luanti_src/`, sync `src_patches/` before committing:

```sh
PROJ=$(pwd)
SRC=$PROJ/luanti_src
for f in $(git -C $SRC diff --name-only HEAD); do
    mkdir -p "$PROJ/src_patches/$(dirname $f)"
    cp "$SRC/$f" "$PROJ/src_patches/$f"
done
git add src_patches/ && git commit -m "chore: sync src_patches"
```
