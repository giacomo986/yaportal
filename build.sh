#!/bin/bash
set -e

PROJ="~/luanti/mods/yaportal"
NINJA="/usr/bin/ninja"
DEPS_LIB="$PROJ/tmp/deps/usr/lib/x86_64-linux-gnu"

ln -sfn "$PROJ/tmp/deps"            /tmp/deps
ln -sfn "$PROJ/tmp/leveldb-extract" /tmp/leveldb-extract
ln -sfn "$PROJ/tmp/luajit-extract"  /tmp/luajit-extract

# Fix absolute symlinks pointing to /usr/lib/x86_64-linux-gnu/ (Debian/Ubuntu path).
# On Arch and derivatives the same libs live in /usr/lib/ — relink if broken.
for link in "$DEPS_LIB"/*.so*; do
    [ -L "$link" ] || continue
    target="$(readlink "$link")"
    [[ "$target" == /usr/lib/x86_64-linux-gnu/* ]] || continue
    [ -e "$link" ] && continue  # already valid
    libfile="$(basename "$target")"
    alt="/usr/lib/$libfile"
    if [ -e "$alt" ]; then
        ln -sfn "$alt" "$link"
        echo "relinked: $(basename "$link") -> $alt"
    else
        echo "WARNING: cannot fix $(basename "$link") — missing $target and $alt" >&2
    fi
done

cd "$PROJ/luanti_src/build"
"$NINJA" -j$(nproc)
