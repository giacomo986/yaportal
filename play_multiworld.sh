#!/bin/bash
# Avvia un mondo come server dedicato (porta fissa, hop in/out funzionanti)
# e ci attacca il client. Gli altri mondi si avviano dal pannello in gioco.
#
#   ./play_multiworld.sh [nome-mondo] [porta]
#
set -e
PROJ="$(cd "$(dirname "$0")" && pwd)"
BIN="$PROJ/luanti_src/bin/luanti"
WORLD="${1:-portal start}"
PORT="${2:-30000}"
WPATH="$HOME/.minetest/worlds/$WORLD"
DIR="$HOME/.minetest/yaportal_link"
mkdir -p "$DIR/logs"

[ -d "$WPATH" ] || { echo "mondo non trovato: $WPATH"; exit 1; }

CONF="$DIR/launch_$WORLD.conf"
cat > "$CONF" <<EOF
secure.trusted_mods = yaportal_link
default_privs = interact, shout
disallow_empty_password = false
port = $PORT
name = ${USER_NAME:-$(grep -oP '^name\s*=\s*\K.*' "$HOME/.minetest/minetest.conf" 2>/dev/null || echo singleplayer)}
EOF

"$BIN" --server --world "$WPATH" --port "$PORT" --config "$CONF" \
    --logfile "$DIR/logs/$WORLD.log" &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT

# attendi che il server ascolti
for i in $(seq 1 30); do
    grep -q "listening" "$DIR/logs/$WORLD.log" 2>/dev/null && break
    sleep 0.5
done

"$BIN" --go --address 127.0.0.1 --port "$PORT" \
    --name "$(grep -oP '^name\s*=\s*\K.*' "$HOME/.minetest/minetest.conf" 2>/dev/null || echo singleplayer)"

# il client è uscito: spegni il server principale
kill $SRV 2>/dev/null || true
wait 2>/dev/null || true
