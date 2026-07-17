#!/bin/bash
# Dual-client live portal view — manual test harness.
# Starts world B (backportal) as a dedicated server, enables the passive
# secondary connection in the client (yaportal_dualtest), then launches the
# normal client. Pick the "portal start" world (singleplayer) from the menu:
# world B's live view is drawn in the TOP-LEFT screen corner.
#
#   ./play_dualtest.sh [world_B] [port_B]
set -e
PROJ="$(cd "$(dirname "$0")" && pwd)"
BIN="$PROJ/luanti_src/bin/luanti"
WORLD_B="${1:-backportal}"
PORT_B="${2:-30022}"
DIR="$HOME/.minetest/yaportal_link"
CONF="$HOME/.minetest/minetest.conf"
mkdir -p "$DIR/logs"

[ -d "$HOME/.minetest/worlds/$WORLD_B" ] || { echo "mondo B non trovato: $WORLD_B"; exit 1; }

# Dedicated server config for world B (trusts yaportal_link).
SRVCONF="$DIR/dualtest_srv.conf"
cat > "$SRVCONF" <<EOF
secure.trusted_mods = yaportal_link
default_privs = interact, shout
disallow_empty_password = false
name = $(grep -oP '^name\s*=\s*\K.*' "$CONF" 2>/dev/null || echo singleplayer)
EOF

# Start server B.
"$BIN" --server --world "$HOME/.minetest/worlds/$WORLD_B" --port "$PORT_B" \
    --config "$SRVCONF" --logfile "$DIR/logs/dualtest_$WORLD_B.log" &
SRV=$!

# Enable dualtest in the client config, remembering the original.
BACKUP="$(mktemp)"
cp "$CONF" "$BACKUP"
cleanup() {
    cp "$BACKUP" "$CONF"; rm -f "$BACKUP"
    kill "$SRV" 2>/dev/null || true
    wait 2>/dev/null || true
    echo "ripristinata config, server B fermato."
}
trap cleanup EXIT

# Strip any prior dualtest lines, then append fresh ones.
sed -i '/^yaportal_dualtest/d' "$CONF"
cat >> "$CONF" <<EOF
yaportal_dualtest = true
yaportal_dualtest_addr = 127.0.0.1
yaportal_dualtest_port = $PORT_B
EOF
# Optional test-hook override: DUALTEST_PORTAL=<engine slot> shows world B in
# that portal slot even without a confirmed yaportal_link pair.
[ -n "$DUALTEST_PORTAL" ] && echo "yaportal_dualtest_portal = $DUALTEST_PORTAL" >> "$CONF"

# Wait for server B to listen.
for i in $(seq 1 40); do
    grep -q "listening on" "$DIR/logs/dualtest_$WORLD_B.log" 2>/dev/null && break
    sleep 0.5
done
echo "server B '$WORLD_B' su :$PORT_B — apri il mondo 'portal start' dal menu."
echo "la vista di B compare nell'angolo IN ALTO A SINISTRA."

# Launch the normal client (menu). dualtest settings are now in minetest.conf.
"$BIN"
