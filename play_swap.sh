#!/bin/bash
# Session swap — manual test harness.
#
# Starts the paired world as a dedicated server, then launches the client on
# the other world. Walking through a linked cross-world portal should NOT
# disconnect and reload: the passive session the client already holds on the
# other server is promoted in place, and the world you came from becomes the
# passive one (look back through the portal and you still see it, live).
#
#   ./play_swap.sh [world_B] [port_B]
#
# What to watch in the log ($HOME/.minetest/debug.txt):
#   [dualtest] secondary afterContentReceived() -> Ready   passive session up
#   [yaportal_link] ... [swap]                             server chose to swap
#   [swap] promoted <world> ... in N ms                    client did the swap
# A "[redirect]" instead means no promotable session was ready and the old
# disconnect/reconnect hop was used.
set -e
PROJ="$(cd "$(dirname "$0")" && pwd)"
BIN="$PROJ/luanti_src/bin/luanti"
WORLD_B="${1:-backportal}"
PORT_B="${2:-30022}"
DIR="$HOME/.minetest/yaportal_link"
CONF="$HOME/.minetest/minetest.conf"
mkdir -p "$DIR/logs"

[ -d "$HOME/.minetest/worlds/$WORLD_B" ] || { echo "mondo B non trovato: $WORLD_B"; exit 1; }

# The ghost session now logs in under the real player name, so world B must
# accept that account (empty password by default here).
SRVCONF="$DIR/dualtest_srv.conf"
cat > "$SRVCONF" <<EOF
secure.trusted_mods = yaportal_link
default_privs = interact, shout
disallow_empty_password = false
name = $(grep -oP '^name\s*=\s*\K.*' "$CONF" 2>/dev/null || echo singleplayer)
EOF

"$BIN" --server --world "$HOME/.minetest/worlds/$WORLD_B" --port "$PORT_B" \
    --config "$SRVCONF" --logfile "$DIR/logs/swap_$WORLD_B.log" &
SRV=$!

cleanup() {
    kill "$SRV" 2>/dev/null || true
    wait 2>/dev/null || true
    echo "server B fermato."
}
trap cleanup EXIT

# Wait for server B to listen. It announces its real bound port in the
# registry, which is what the client's passive session connects to.
for i in $(seq 1 40); do
    grep -q "listening on" "$DIR/logs/swap_$WORLD_B.log" 2>/dev/null && break
    sleep 0.5
done
echo "server B '$WORLD_B' su :$PORT_B"
echo "apri il mondo accoppiato dal menu e attraversa il portale cross-world."
echo "log: tail -f $HOME/.minetest/debug.txt | grep -E 'dualtest|swap'"

"$BIN"
