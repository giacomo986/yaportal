-- yaportal_link — cross-world portals over multiple local servers.
--
-- Each participating world runs this mod (trusted). Coordination happens
-- through a shared directory of small JSON files (one record per file, no
-- locking needed: every file has a single writer):
--   $DIR/worlds/<world>.json                 server presence + port (heartbeat)
--   $DIR/endpoints/<world>__<ep>.json        the doors of a world (kept while
--                                            it is off, so they stay pickable)
--   $DIR/pairs/<aW>__<aEp>__<bW>__<bEp>.json two doors connected to each other
--   $DIR/handoff/<player>.json               arrival state during a hop
-- Crossing a paired portal writes the handoff and calls core.redirect_player
-- (engine fork, TOCLIENT_REDIRECT): the client reconnects to the other server
-- without passing through the menu.

local ie = minetest.request_insecure_environment()
if not ie then
    -- Don't take the whole world down: disable ourselves and tell the admin.
    minetest.log("error", "[yaportal_link] disabled: not a trusted mod. Add\n" ..
        "    secure.trusted_mods = yaportal_link\nto minetest.conf")
    minetest.register_on_joinplayer(function(player)
        if minetest.check_player_privs(player:get_player_name(), {server = true}) then
            minetest.chat_send_player(player:get_player_name(),
                minetest.colorize("#FF5555", "[yaportal_link] disabilitato: aggiungi " ..
                    "'secure.trusted_mods = yaportal_link' a minetest.conf e riavvia."))
        end
    end)
    return
end

local S_HEARTBEAT   = 3     -- s between registry refreshes
local T_ONLINE      = 10    -- s before an endpoint is considered offline
local T_HANDOFF     = 30    -- s validity of a handoff record
local PORT_BASE     = 30001 -- first port for on-demand worlds
-- Only portals built from this dedicated frame are cross-world endpoints;
-- ordinary yaportal frames stay in-world play portals.
local XFRAME        = "yaportal_link:frame"

local worldpath  = minetest.get_worldpath()
local world_id   = worldpath:match("([^/]+)$")
-- The bound port, not the "port" setting: a singleplayer server takes a free
-- port and --port overrides the setting, so advertising the setting sends
-- cross-world hops to a server that isn't there.
local my_port    = (core.get_bind_port and core.get_bind_port())
                   or tonumber(minetest.settings:get("port")) or 30000
local my_addr    = minetest.settings:get("yaportal_link_addr") or "127.0.0.1"
local HOME       = ie.os.getenv("HOME") or "/tmp"
local DIR        = minetest.settings:get("yaportal_link_dir")
                   or (HOME .. "/.minetest/yaportal_link")
local WORLDS_DIR = minetest.settings:get("yaportal_link_worlds_dir")
                   or (HOME .. "/.minetest/worlds")
local LUANTI_BIN = minetest.settings:get("yaportal_link_bin")
if not LUANTI_BIN or LUANTI_BIN == "" then
    -- Default: the binary running this very server (Linux). Inside popen,
    -- /proc/self is the child shell, so resolve the parent ($PPID = us).
    local p = ie.io.popen("readlink -f /proc/$PPID/exe 2>/dev/null")
    if p then
        LUANTI_BIN = p:read("*l")
        p:close()
    end
    LUANTI_BIN = LUANTI_BIN or "luanti"
end

ie.os.execute(("mkdir -p '%s/worlds' '%s/endpoints' '%s/pairs' '%s/handoff' '%s/logs'")
    :format(DIR, DIR, DIR, DIR, DIR))

-- ── JSON file helpers (single writer per file; write is tmp+rename) ─────────

local function read_json(path)
    local f = ie.io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return minetest.parse_json(data)
end

local function write_json(path, tbl)
    local f = ie.io.open(path .. ".tmp", "w")
    if not f then return false end
    f:write(minetest.write_json(tbl))
    f:close()
    ie.os.rename(path .. ".tmp", path)
    return true
end

local function remove_file(path) ie.os.remove(path) end

local function list_dir(path)
    local out = {}
    local p = ie.io.popen(("ls -1 '%s' 2>/dev/null"):format(path))
    if not p then return out end
    for line in p:lines() do out[#out + 1] = line end
    p:close()
    return out
end

local function now() return ie.os.time() end

-- Hopping out of a local (singleplayer) game the engine renames the player to
-- the configured name: write the handoff under both names so the arrival
-- server finds it whichever one connects.
local function write_handoff(pname, rec)
    write_json(DIR .. "/handoff/" .. pname .. ".json", rec)
    if pname == "singleplayer" then
        -- Same fallback chain as the engine's redirect: configured name,
        -- else "player".
        local n = minetest.settings:get("name")
        if not n or n == "" then n = "player" end
        if n ~= pname then
            rec.player = n
            write_json(DIR .. "/handoff/" .. n .. ".json", rec)
        end
    end
end

-- ── endpoint state (this world's announced portals) ─────────────────────────

-- Every portal built from the cross-world frame is a "door" (porta) in the UI:
-- it is announced automatically and carries a name the player can change, so
-- nobody has to deal with the internal portal ids.
-- ep name → {portal=<yaportal name>, open=bool, label=<display name>}
local my_endpoints = {}
local storage = minetest.get_mod_storage()

do
    local raw = storage:get_string("endpoints")
    if raw and raw ~= "" then
        local saved = minetest.parse_json(raw)
        if type(saved) == "table" then my_endpoints = saved end
    end
end

local function save_endpoints()
    storage:set_string("endpoints", minetest.write_json(my_endpoints))
end

local function ep_file(world, ep) return DIR .. "/endpoints/" .. world .. "__" .. ep .. ".json" end

-- Display name of one of my doors, and a fresh default for a new one.
local function my_label(ep)
    local info = my_endpoints[ep]
    return (info and info.label and info.label ~= "") and info.label or ep
end

local function next_default_label()
    local n = 0
    for _, info in pairs(my_endpoints) do
        local k = tostring(info.label or ""):match("^Porta (%d+)$")
        if k then n = math.max(n, tonumber(k)) end
    end
    return "Porta " .. (n + 1)
end

-- A portal is identified by name, but breaking the frame closes that portal and
-- rebuilding it creates a differently named one. The endpoint would then point
-- at a portal that no longer exists: the pairing goes quiet, no xworld link is
-- attached, and crossing does nothing — while the view can keep working off a
-- stale engine slot, which makes it look like only the teleport broke.
local function rebind_endpoint(ep, info)
    if yaportal.xworld.get_portal(info.portal) then return end
    local at = info.at
    if not at then return end
    for _, p in ipairs(yaportal.xworld.list_portals()) do
        if p.node_name == XFRAME and p.axis == at.axis then
            local c = yaportal.xworld.inner_center(p)
            if math.abs(c.x - at.x) <= 2 and math.abs(c.y - at.y) <= 2
               and math.abs(c.z - at.z) <= 2 then
                minetest.log("action", ("[yaportal_link] endpoint '%s': '%s' was rebuilt as '%s'")
                    :format(ep, info.portal, p.name))
                info.portal = p.name
                save_endpoints()
                return
            end
        end
    end
end

-- ── remote exchange (cross-machine registries) ──────────────────────────────
--
-- Worlds on the same machine meet through DIR; a server on ANOTHER machine is
-- reached over TCP through the engine's PortalExchange service, which every
-- yaportal_link world serves on game_port + XPORT_OFF. GET /registry returns
-- what that world announces; POST /post drops a record (endpoint, pair,
-- unpair, handoff) that the mod ingests into DIR as if a local world had
-- written the file — everything downstream (scans, links, panel) is unchanged.

local XPORT_OFF = 5000
local XKEY = minetest.settings:get("yaportal_link_key") or ""
local http = minetest.request_http_api and minetest.request_http_api()
if not http then
    minetest.log("warning", "[yaportal_link] no HTTP API: remote server search disabled")
end

local rs_raw = storage:get_string("remote_servers")
local remote_servers = (rs_raw ~= "" and minetest.parse_json(rs_raw)) or {}

local function save_remote_servers()
    storage:set_string("remote_servers", minetest.write_json(remote_servers) or "{}")
end

local function remember_server(addr, gport)
    gport = tonumber(gport)
    if not addr or not gport then return end
    if (addr == "127.0.0.1" or addr == my_addr) and gport == my_port then return end
    local k = addr .. ":" .. gport
    if not remote_servers[k] then
        remote_servers[k] = {addr = addr, port = gport}
        save_remote_servers()
    end
end

local function xurl(addr, gport, path)
    return ("http://%s:%d%s"):format(addr, gport + XPORT_OFF, path)
end

-- Fire-and-forget write to a remote world's exchange.
local function xpost(addr, gport, payload)
    if not http then return end
    payload.key = XKEY
    http.fetch({
        url = xurl(addr, gport, "/post"),
        method = "POST",
        data = minetest.write_json(payload),
        extra_headers = {"Content-Type: application/json"},
        timeout = 5,
    }, function(res)
        if not res.succeeded then
            minetest.log("warning", ("[yaportal_link] POST to %s:%d failed")
                :format(addr, gport))
        end
    end)
end

local function announce_endpoints()
    write_json(DIR .. "/worlds/" .. world_id .. ".json",
        {world = world_id, addr = my_addr, port = my_port, ts = now()})
    local pub_eps = {}
    for ep, info in pairs(my_endpoints) do
        rebind_endpoint(ep, info)
        local pp = yaportal.xworld.get_portal(info.portal)
        if pp then
            local c = yaportal.xworld.inner_center(pp)
            -- Remembered so a frame rebuilt in the same place can be matched
            -- back to this endpoint (see rebind_endpoint).
            info.at = {x = c.x, y = c.y, z = c.z, axis = pp.axis}
            local n = yaportal.xworld.basis(pp)
            local rec = {
                world = world_id, ep = ep, addr = my_addr, port = my_port,
                portal = info.portal, open = info.open and true or false,
                label = my_label(ep),
                pos = {x = c.x, y = c.y, z = c.z},
                normal = {x = n.x, y = n.y, z = n.z},
                -- raw portal geometry, needed to rebuild the mirror portal
                def = {cx = pp.cx, cy = pp.cy, cz = pp.cz, axis = pp.axis,
                       ns = pp.ns, w = pp.w, h = pp.h, rot = pp.rot,
                       ou = pp.ou, ov = pp.ov, node_name = pp.node_name},
                ts = now(),
            }
            write_json(ep_file(world_id, ep), rec)
            pub_eps[#pub_eps + 1] = rec
        else
            -- Portal gone (closed/broken): stop announcing so nobody pairs
            -- with a dead endpoint. Keep the my_endpoints entry: it revives
            -- if a portal with the same name comes back.
            remove_file(ep_file(world_id, ep))
        end
    end
    if core.xworld_exchange then
        core.xworld_exchange(my_port + XPORT_OFF, minetest.write_json({
            v = 1, world = {world = world_id, port = my_port},
            endpoints = pub_eps,
        }) or "{}")
    end
end

-- ── registry scans ───────────────────────────────────────────────────────────

local function scan_endpoints()
    local out = {}
    for _, fn in ipairs(list_dir(DIR .. "/endpoints")) do
        local rec = read_json(DIR .. "/endpoints/" .. fn)
        if rec and rec.world and rec.ep then
            rec.online = (now() - (rec.ts or 0)) < T_ONLINE
            out[rec.world .. "/" .. rec.ep] = rec
        end
    end
    return out
end

local function pair_file(aw, ae, bw, be)
    return DIR .. "/pairs/" .. aw .. "__" .. ae .. "__" .. bw .. "__" .. be .. ".json"
end

local function scan_pairs()
    local out = {}
    for _, fn in ipairs(list_dir(DIR .. "/pairs")) do
        local rec = read_json(DIR .. "/pairs/" .. fn)
        if rec and rec.a and rec.b then
            -- Connecting two doors is one click now: a pair file on disk means
            -- "connected", full stop. Records left half-done by the old
            -- request/accept handshake count as connected too.
            rec.status = "confirmed"
            out[fn] = rec
        end
    end
    return out
end

-- Pair involving one of my endpoints → the other side, or nil
local function pair_other_side(rec)
    if rec.a.world == world_id and my_endpoints[rec.a.ep] then return rec.b, rec.a end
    if rec.b.world == world_id and my_endpoints[rec.b.ep] then return rec.a, rec.b end
    return nil
end

-- ── portal link sync: confirmed pair + remote online → pp.xworld ────────────

local function sync_links()
    local eps = scan_endpoints()
    local linked = {}  -- endpoints that a confirmed pair keeps live
    for _, rec in pairs(scan_pairs()) do
        local other, mine = pair_other_side(rec)
        if other and rec.status == "confirmed" then
            local my_info  = my_endpoints[mine.ep]
            local other_ep = eps[other.world .. "/" .. other.ep]
            -- Only a dedicated cross-world frame portal may carry an xworld link.
            local lp = my_info and yaportal.xworld.get_portal(my_info.portal)
            if my_info and lp and lp.node_name == XFRAME then
                linked[mine.ep] = true
                if other_ep and other_ep.online then
                    yaportal.xworld.set_link(my_info.portal, {
                        world = other.world, ep = other.ep,
                        addr = other_ep.addr, port = other_ep.port,
                        pos = other_ep.pos, normal = other_ep.normal,
                    })
                else
                    yaportal.xworld.set_link(my_info.portal, nil)
                end
            end
        end
    end
    -- Any endpoint not backed by a confirmed pair must not keep a stale xworld.
    for ep, info in pairs(my_endpoints) do
        if not linked[ep] then
            yaportal.xworld.set_link(info.portal, nil)
        end
    end
end

-- ── connect / disconnect ────────────────────────────────────────────────────
--
-- A door is connected to exactly one other door, so connecting always means
-- "drop whatever either side was connected to, then join these two". Both
-- sides are described by the same file, which is why one click is enough: the
-- other world picks the change up from the registry on its next heartbeat.

local function drop_pairs_of(world, ep)
    for fn, rec in pairs(scan_pairs()) do
        if (rec.a.world == world and rec.a.ep == ep)
           or (rec.b.world == world and rec.b.ep == ep) then
            remove_file(DIR .. "/pairs/" .. fn)
        end
    end
end

-- The door my door is connected to: {world=, ep=} or nil.
local function connected_to(ep)
    for _, rec in pairs(scan_pairs()) do
        if rec.a.world == world_id and rec.a.ep == ep then return rec.b end
        if rec.b.world == world_id and rec.b.ep == ep then return rec.a end
    end
    return nil
end

local function connect_doors(mine, other_world, other_ep)
    drop_pairs_of(world_id, mine)
    drop_pairs_of(other_world, other_ep)
    write_json(pair_file(world_id, mine, other_world, other_ep), {
        a = {world = world_id, ep = mine},
        b = {world = other_world, ep = other_ep},
        status = "confirmed", requester = world_id .. "/" .. mine, ts = now(),
    })
    sync_links()
end

local function disconnect_door(mine)
    -- A cross-machine counterpart cannot see our pair files go away: tell it.
    local other = connected_to(mine)
    if other then
        local rec = scan_endpoints()[other.world .. "/" .. other.ep]
        if rec and rec.remote then
            xpost(rec.addr, rec.port, {kind = "unpair", data = {
                a = {world = world_id, ep = mine},
                b = {world = other.world, ep = other.ep},
            }})
        end
    end
    drop_pairs_of(world_id, mine)
    local info = my_endpoints[mine]
    if info then yaportal.xworld.set_link(info.portal, nil) end
    sync_links()
end

-- Every portal built from the dedicated cross-world frame is auto-registered
-- as an endpoint (open); ordinary yaportal portals are never touched. Drops
-- endpoints whose portal no longer exists or is no longer an xworld frame.
local function sync_xframe_endpoints()
    -- A rebuilt frame is a NEW portal with a new name. Give it back to the
    -- endpoint that used to stand there before anything else looks at it,
    -- otherwise the endpoint is dropped, a differently named one takes its
    -- place, and every pairing made with the old name is orphaned.
    local claimed = {}
    for ep, info in pairs(my_endpoints) do
        rebind_endpoint(ep, info)
        claimed[info.portal] = true
    end

    for _, p in ipairs(yaportal.xworld.list_portals()) do
        if p.node_name == XFRAME then
            if not claimed[p.name] and not my_endpoints[p.name] then
                local label = next_default_label()
                my_endpoints[p.name] = {portal = p.name, open = true,
                    label = label}
                claimed[p.name] = true
                minetest.chat_send_all(minetest.colorize("#88CCFF",
                    ("[porta] '%s' creata. Click destro sulla cornice per " ..
                     "scegliere in che mondo porta."):format(label)))
            end
        elseif p.xworld then
            -- An ORDINARY play portal must never carry a cross-world link.
            -- Strip any stray xworld (e.g. left by an old pair that targeted a
            -- non-frame portal) so crossing it teleports locally, not hops.
            yaportal.xworld.set_link(p.name, nil)
            -- Drop any registry pair that points at this portal, so it doesn't
            -- get re-applied on the next sync.
            for fn, rec in pairs(scan_pairs()) do
                local isa = rec.a.world == world_id and rec.a.ep == p.name
                local isb = rec.b.world == world_id and rec.b.ep == p.name
                if isa or isb then remove_file(DIR .. "/pairs/" .. fn) end
            end
        end
    end
    for ep, info in pairs(my_endpoints) do
        local pp = yaportal.xworld.get_portal(info.portal)
        if not pp or pp.node_name ~= XFRAME then
            my_endpoints[ep] = nil
            remove_file(ep_file(world_id, ep))
            if pp then yaportal.xworld.set_link(info.portal, nil) end
        end
    end
    save_endpoints()
end

-- Repair for worlds broken before the rebind above existed: a confirmed pair
-- names an endpoint of mine that is gone, and an endpoint nobody paired is
-- standing where it used to be. Only acted on when both are unambiguous —
-- with several candidates the right answer is a guess, so leave it alone.
local function adopt_orphan_pairs()
    -- Both sides of a pairing are on disk as their own file, so the same
    -- endpoint name shows up more than once: count names, not records.
    local wanted_set, referenced = {}, {}
    for _, rec in pairs(scan_pairs()) do
        if rec.status == "confirmed" then
            for _, side in ipairs({rec.a, rec.b}) do
                if side.world == world_id then
                    referenced[side.ep] = true
                    if not my_endpoints[side.ep] then wanted_set[side.ep] = true end
                end
            end
        end
    end
    local wanted = {}
    for ep in pairs(wanted_set) do wanted[#wanted + 1] = ep end
    if #wanted ~= 1 then return end

    local free = {}
    for ep in pairs(my_endpoints) do
        if not referenced[ep] then free[#free + 1] = ep end
    end
    if #free ~= 1 then return end

    local from, to = free[1], wanted[1]
    minetest.log("action", ("[yaportal_link] endpoint '%s' adopts the orphaned pairing of '%s'")
        :format(from, to))
    my_endpoints[to] = my_endpoints[from]
    my_endpoints[from] = nil
    remove_file(ep_file(world_id, from))
    save_endpoints()
end

-- ── remote exchange: ingest & refresh ───────────────────────────────────────

-- Network-supplied names end up in file names: keep them boring.
local function safe_id(s)
    return type(s) == "string" and s ~= "" and s:len() <= 64
        and not s:find("[/%z]") and not s:find("%.%.") and s or nil
end

-- A remote /registry answer: its world and door records enter our registry
-- with the address WE reached it at (what it announces is its own loopback).
local function ingest_registry(srv, resp)
    if type(resp) ~= "table" or type(resp.world) ~= "table" then return 0 end
    local rw = safe_id(resp.world.world)
    if not rw or rw == world_id then return 0 end
    write_json(DIR .. "/worlds/" .. rw .. ".json", {
        world = rw, addr = srv.addr,
        port = tonumber(resp.world.port) or srv.port,
        ts = now(), remote = true,
    })
    local n = 0
    for _, rec in ipairs(resp.endpoints or {}) do
        local w, e = safe_id(rec.world), safe_id(rec.ep)
        if w == rw and e then
            rec.addr   = srv.addr
            rec.port   = tonumber(rec.port) or srv.port
            rec.remote = true
            rec.ts     = now()
            write_json(ep_file(w, e), rec)
            n = n + 1
        end
    end
    return n
end

local xrefresh_inflight = {}
local function remote_refresh()
    if not http then return end
    for k, srv in pairs(remote_servers) do
        if not xrefresh_inflight[k] then
            xrefresh_inflight[k] = true
            http.fetch({url = xurl(srv.addr, srv.port, "/registry"), timeout = 5},
                function(res)
                    xrefresh_inflight[k] = nil
                    if res.succeeded then
                        ingest_registry(srv, minetest.parse_json(res.data or ""))
                    end
                end)
        end
    end
end

-- Records POSTed by remote servers: validate, then drop them into DIR as if a
-- local world had written the file.
local function ingest_post(peer, body)
    local msg = minetest.parse_json(body or "")
    if type(msg) ~= "table" or type(msg.data) ~= "table" then return end
    if XKEY ~= "" and msg.key ~= XKEY then
        minetest.log("warning",
            "[yaportal_link] post from " .. peer .. " rejected (wrong key)")
        return
    end
    local d = msg.data
    if msg.kind == "endpoint" then
        local w, e = safe_id(d.world), safe_id(d.ep)
        if not (w and e) or w == world_id then return end
        -- "auto": the sender does not know its own address as seen from
        -- here; the TCP source does. NAT-proof and needs no configuration.
        if d.addr == "auto" or not d.addr then d.addr = peer end
        d.port = tonumber(d.port)
        if not d.port then return end
        d.remote, d.ts = true, now()
        write_json(ep_file(w, e), d)
        remember_server(d.addr, d.port)
    elseif msg.kind == "pair" or msg.kind == "unpair" then
        local ok = type(d.a) == "table" and type(d.b) == "table"
            and safe_id(d.a.world) and safe_id(d.a.ep)
            and safe_id(d.b.world) and safe_id(d.b.ep)
        if not ok then return end
        drop_pairs_of(d.a.world, d.a.ep)
        drop_pairs_of(d.b.world, d.b.ep)
        if msg.kind == "pair" then
            write_json(pair_file(d.a.world, d.a.ep, d.b.world, d.b.ep), {
                a = {world = d.a.world, ep = d.a.ep},
                b = {world = d.b.world, ep = d.b.ep},
                status = "confirmed", requester = d.requester, ts = now(),
            })
        end
    elseif msg.kind == "handoff" then
        local p = safe_id(d.player)
        if not p then return end
        d.ts = now()
        write_handoff(p, d)
    end
end

-- ── heartbeat ────────────────────────────────────────────────────────────────

local hb_timer = 0
minetest.register_globalstep(function(dtime)
    hb_timer = hb_timer + dtime
    if hb_timer < S_HEARTBEAT then return end
    hb_timer = 0
    sync_xframe_endpoints()
    adopt_orphan_pairs()
    announce_endpoints()
    remote_refresh()
    sync_links()
end)

-- Posts are drained every step, not every heartbeat: a handoff must be on
-- disk before the player it precedes connects.
if core.xworld_exchange_posts then
    minetest.register_globalstep(function()
        for _, post in ipairs(core.xworld_exchange_posts()) do
            ingest_post(post.peer, post.body)
        end
    end)
end

-- Defined further down (arrival section); the park/unpark commands need it.
local apply_handoff

-- ── parking: a player who is here but not playing here ──────────────────────
--
-- With the dual-client portal view the same player is connected to both worlds
-- at once: interactive in one, passive in the other. The passive side must not
-- be visible, solid, damageable or moving — it exists only so this server
-- streams the portal's destination region. Same story after a session swap for
-- the player left behind in the world they walked out of.

local parked = {}          -- pname -> saved state

local function park(player)
    local pname = player:get_player_name()
    if parked[pname] then return end
    parked[pname] = {
        armor = player:get_armor_groups(),
        physics = player:get_physics_override(),
        visible = player:get_properties().is_visible,
        pointable = player:get_properties().pointable,
        collide = player:get_properties().collide_with_objects,
        nametag = player:get_nametag_attributes(),
    }
    player:set_properties({is_visible = false, pointable = false,
        collide_with_objects = false})
    player:set_armor_groups({immortal = 1})
    player:set_physics_override({speed = 0, jump = 0, gravity = 0})
    player:set_nametag_attributes({color = {a = 0, r = 255, g = 255, b = 255}})
    -- Mod load order decides whether a game's own join callback (e.g. yafps
    -- arcade physics) runs before or AFTER this one. When it runs after, it
    -- both thaws the freeze and makes our snapshot stale — unparking would
    -- then restore the wrong physics (the "still walking like the old world"
    -- bug). One step later every join callback has run: re-take whatever a
    -- later callback overwrote and re-apply the freeze. Per attribute, not
    -- whole-table: VoxeLibre's playerphysics overrides one attribute at a
    -- time, so a still-frozen 0 next to a thawed value is OUR freeze, not the
    -- game's — copying it into the snapshot would unpark with gravity 0 (the
    -- "can't fall, jump ascends forever" bug).
    minetest.after(0, function()
        local st = parked[pname]
        local pl = minetest.get_player_by_name(pname)
        if not (st and pl) then return end
        local ph = pl:get_physics_override()
        local thawed = false
        if ph.speed ~= 0 then st.physics.speed = ph.speed; thawed = true end
        if ph.jump ~= 0 then st.physics.jump = ph.jump; thawed = true end
        if ph.gravity ~= 0 then st.physics.gravity = ph.gravity; thawed = true end
        if thawed then
            pl:set_physics_override({speed = 0, jump = 0, gravity = 0})
        end
        local props = pl:get_properties()
        local shown = false
        if props.is_visible then st.visible = true; shown = true end
        if props.pointable then st.pointable = true; shown = true end
        if props.collide_with_objects then st.collide = true; shown = true end
        if shown then
            pl:set_properties({is_visible = false, pointable = false,
                collide_with_objects = false})
        end
    end)
end

local function unpark(pname)
    local st = parked[pname]
    if not st then return end
    parked[pname] = nil
    local player = minetest.get_player_by_name(pname)
    if not player then return end
    player:set_properties({is_visible = st.visible ~= false,
        pointable = st.pointable ~= false,
        collide_with_objects = st.collide ~= false})
    player:set_armor_groups(st.armor or {})
    player:set_physics_override(st.physics or {speed = 1, jump = 1, gravity = 1})
    if st.nametag then player:set_nametag_attributes(st.nametag) end
end

-- Park the ghost beside my endpoint portal of a confirmed pair, so the region
-- the other world looks at through the portal is loaded and meshed.
local function park_at_endpoint(pname)
    local player = minetest.get_player_by_name(pname)
    if not player then return end
    for _, rec in pairs(scan_pairs()) do
        local other, mine = pair_other_side(rec)
        if other and rec.status == "confirmed" and my_endpoints[mine.ep] then
            local pp = yaportal.xworld.get_portal(my_endpoints[mine.ep].portal)
            if pp then
                local g = yaportal.xworld.portal_geom(pp)
                -- Beside, not in front: in front would sit in the middle of
                -- the view the other world renders.
                local r = vector.cross(g.up, g.normal)
                player:set_pos({x = g.pos.x + g.normal.x * 2 + r.x * 4,
                    y = g.pos.y - 1,
                    z = g.pos.z + g.normal.z * 2 + r.z * 4})
                minetest.log("action", "[yaportal_link] ghost " .. pname ..
                    " parked at endpoint '" .. my_endpoints[mine.ep].portal .. "'")
                return
            end
        end
    end
end

-- Sent by a passive session once it is ready: this connection is a ghost and
-- must stay parked until its client promotes it.
minetest.register_chatcommand("xworld_park", {
    description = "Mark this connection as a passive cross-world ghost",
    privs = {},
    func = function(pname)
        local player = minetest.get_player_by_name(pname)
        if not player then return false end
        park(player)
        if parked[pname] then parked[pname].ghost = true end
        park_at_endpoint(pname)
        return true
    end,
})

-- Sent by a client that just promoted this connection to its interactive one.
minetest.register_chatcommand("xworld_unpark", {
    description = "Take over a parked cross-world ghost connection",
    privs = {},
    func = function(pname)
        unpark(pname)
        apply_handoff(pname)
        minetest.log("action", "[yaportal_link] " .. pname ..
            " took over their ghost connection on " .. world_id)
        return true
    end,
})

-- ── crossing: swap in place, or redirect ────────────────────────────────────

yaportal.xworld.handler = function(pname, portal_name, pp)
    local other = pp.xworld
    if not other then return end
    local player = minetest.get_player_by_name(pname)
    if not player then return end

    -- Endpoint address from the live registry, not from the pairing snapshot:
    -- the other world may have restarted on a different port since.
    local eps = scan_endpoints()
    local live = eps[other.world .. "/" .. other.ep]
    if not (live and live.online) then
        -- Used to be caught by the portal being linked to a stale mirror copy
        -- of the other world; without that copy there is simply nothing there.
        minetest.chat_send_player(pname, minetest.colorize("#FFAA55",
            "[portale] destinazione intermondo non disponibile (mondo remoto offline)."))
        return
    end
    local addr = live.addr or other.addr
    local port = live.port or other.port

    local vel = player:get_velocity() or {x = 0, y = 0, z = 0}
    local speed = math.sqrt(vel.x^2 + vel.y^2 + vel.z^2)
    -- Where the player was and where they were looking, expressed in this
    -- portal's own frame: the exit server maps that onto its portal, so you
    -- come out of it the way you went in instead of facing straight ahead.
    local rec = {
        player = pname, to_world = other.world, to_ep = other.ep,
        speed = speed, ts = now(),
    }
    if yaportal.xworld.decompose then
        local c = yaportal.xworld.inner_center(pp)
        local pos = player:get_pos()
        rec.rel = yaportal.xworld.decompose(pp,
            {x = pos.x - c.x, y = pos.y - c.y, z = pos.z - c.z})
        rec.vel = yaportal.xworld.decompose(pp, vel)
        rec.look = yaportal.xworld.decompose(pp, player:get_look_dir())
    end
    write_handoff(pname, rec)
    -- On another machine the shared DIR does not exist: hand the record to
    -- the destination server itself, ahead of the redirect below.
    if live.remote then
        xpost(live.addr, live.port, {kind = "handoff", data = rec})
    end

    local slot = yaportal.xworld.engine_slot(portal_name)
    local swapped = false
    if slot and core.xworld_swap_player then
        swapped = core.xworld_swap_player(pname, addr, port, slot,
            other.world, other.ep)
    end

    -- Why a crossing fell back to a redirect: either this portal has no engine
    -- slot, or the server does not hold the client's passive session as ready
    -- for this exact address:port. Print both sides so the mismatch is visible.
    if not swapped then
        local sr, sa, sp, sw = nil, nil, nil, nil
        if core.player_dual_ready then sr, sa, sp, sw = core.player_dual_ready(pname) end
        minetest.log("action", ("[yaportal_link] swap-miss %s: slot=%s pass=%s:%s || " ..
            "server-sees ready=%s %s:%s world=%s")
            :format(pname, tostring(slot), tostring(addr), tostring(port),
                tostring(sr), tostring(sa), tostring(sp), tostring(sw)))
    end

    minetest.log("action", ("[yaportal_link] %s crosses '%s' -> %s/%s (%s:%d)%s")
        :format(pname, portal_name, other.world, other.ep, addr, port,
            swapped and " [swap]" or " [redirect]"))

    if swapped then
        -- The player stays connected here as a ghost so this world remains
        -- visible through the portal from the other side. Freeze them where
        -- they are: they are standing at the portal, which is exactly the
        -- region the other world needs streamed, and moving them now would
        -- show up on their screen — the client is still rendering this world
        -- until the swap packet lands a frame later.
        park(player)
    else
        core.redirect_player(pname, addr, port)
    end
end

-- ── arrival: apply handoff on join ──────────────────────────────────────────

-- A player is "singleplayer" in a local game and their configured name
-- everywhere else, so a handoff written by the world they left may be filed
-- under either. write_handoff writes both for the same reason.
local function handoff_names(pname)
    local names = {pname}
    if pname == "singleplayer" then
        local n = minetest.settings:get("name")
        if n and n ~= "" and n ~= pname then names[#names + 1] = n end
    end
    return names
end

local function read_handoff(pname)
    for _, n in ipairs(handoff_names(pname)) do
        local path = DIR .. "/handoff/" .. n .. ".json"
        local rec = read_json(path)
        if rec and rec.to_world == world_id then return rec, path end
    end
    return nil
end

apply_handoff = function(pname)
    local rec, path = read_handoff(pname)
    if not rec then return end
    remove_file(path)
    if (now() - (rec.ts or 0)) > T_HANDOFF then return end

    if not rec.to_ep then
        -- Plain world jump (panel "Vai"): default spawn is fine.
        minetest.log("action", ("[yaportal_link] %s arrives at %s (spawn)")
            :format(pname, world_id))
        return
    end
    local info = my_endpoints[rec.to_ep]
    local pp = info and yaportal.xworld.get_portal(info.portal)
    if not pp then
        minetest.log("warning", "[yaportal_link] handoff for " .. pname ..
            " but endpoint '" .. tostring(rec.to_ep) .. "' has no portal")
        return
    end
    local player = minetest.get_player_by_name(pname)
    if not player then return end

    local c = yaportal.xworld.inner_center(pp)
    local n = yaportal.xworld.basis(pp)
    local pos, look
    if rec.rel and yaportal.xworld.compose then
        local off = yaportal.xworld.compose(pp, rec.rel)
        -- Keep the entry offset, but never leave the player inside the frame:
        -- push out to at least 0.9 along the exit normal.
        local depth = off.x * n.x + off.y * n.y + off.z * n.z
        if depth < 0.9 then
            local adj = 0.9 - depth
            off.x, off.y, off.z = off.x + adj * n.x, off.y + adj * n.y, off.z + adj * n.z
        end
        pos = {x = c.x + off.x, y = c.y + off.y, z = c.z + off.z}
        look = rec.look and yaportal.xworld.compose(pp, rec.look)
    else
        -- No transform in the record (older handoff): feet just in front of the
        -- exit portal, looking away from it.
        pos = {x = c.x + n.x * 0.9, y = c.y - 0.9 + n.y * 0.9, z = c.z + n.z * 0.9}
    end
    player:set_pos(pos)

    if look and (math.abs(look.x) > 0.001 or math.abs(look.z) > 0.001) then
        player:set_look_horizontal(math.atan2(-look.x, look.z))
        player:set_look_vertical(-math.asin(math.max(-1, math.min(1, look.y))))
    elseif not look and (n.x ~= 0 or n.z ~= 0) then
        player:set_look_horizontal(math.atan2(-n.x, n.z))
        player:set_look_vertical(0)
    end

    if rec.vel and yaportal.xworld.compose then
        player:add_velocity(yaportal.xworld.compose(pp, rec.vel))
    elseif rec.speed and rec.speed > 0.5 then
        player:add_velocity({x = n.x * rec.speed, y = n.y * rec.speed, z = n.z * rec.speed})
    end
    -- Arriving right in front of the exit portal must not re-trigger it.
    if yaportal.xworld.reset_trigger_state then
        yaportal.xworld.reset_trigger_state(pname, pos)
    end
    minetest.log("action", ("[yaportal_link] %s arrives at %s/%s")
        :format(pname, world_id, rec.to_ep))
end

-- A joining connection is one of three things, told apart at join time: a
-- passive ghost declares itself in the CLIENT_READY handshake
-- (get_player_information().xworld_passive), a player arriving through a
-- portal left a handoff on disk, anything else is a normal join and must not
-- be touched. The /xworld_park chat announce stays as a fallback and to
-- re-place the ghost once a pair confirms after the join.
minetest.register_on_joinplayer(function(player)
    local pname = player:get_player_name()

    local info = minetest.get_player_information(pname)
    if info and info.xworld_passive then
        -- Ghost: park it before anyone ever sees it, until its client
        -- promotes the connection.
        park(player)
        parked[pname].ghost = true
        park_at_endpoint(pname)
        minetest.log("action", "[yaportal_link] ghost " .. pname ..
            " joined passive, parked")
        return
    end

    local rec = read_handoff(pname)
    if rec and (now() - (rec.ts or 0)) <= T_HANDOFF then
        -- Redirect hop: this connection is the player. Place and release.
        park(player)
        minetest.after(0.2, function()
            unpark(pname)
            apply_handoff(pname)
        end)
    end
end)

minetest.register_on_leaveplayer(function(player)
    parked[player:get_player_name()] = nil
end)

-- ── on-demand world startup ──────────────────────────────────────────────────

local function running_worlds()
    local out = {}
    for _, fn in ipairs(list_dir(DIR .. "/worlds")) do
        local rec = read_json(DIR .. "/worlds/" .. fn)
        if rec and rec.world and (now() - (rec.ts or 0)) < T_ONLINE then
            out[rec.world] = rec
        end
    end
    return out
end

local function local_worlds()
    return list_dir(WORLDS_DIR)
end

-- ── installed games (for creating a destination world with another game) ─────

-- Same normalization as the engine (subgames.cpp): "minetest_game" and
-- "minetest" are the same id, and the first directory found wins, share
-- before user, so the dropdown matches what the engine would launch.
local function norm_gameid(id)
    return (id:gsub("_game$", ""))
end

local function game_title(conf_path)
    local f = ie.io.open(conf_path, "r")
    if not f then return nil end
    local title
    for line in f:lines() do
        local t = line:match("^%s*title%s*=%s*(.-)%s*$")
        if t and t ~= "" then title = t break end
    end
    f:close()
    return title
end

-- {id, title, path} for every game the engine can see, sorted by title.
local function installed_games()
    local dirs = {}
    -- share dir: <share>/games sits beside <share>/builtin
    local builtin = core.get_builtin_path and core.get_builtin_path() or ""
    local share_games = builtin:gsub("builtin[/\\]?$", "games")
    if share_games ~= "" and share_games ~= builtin then
        dirs[#dirs + 1] = share_games
    end
    dirs[#dirs + 1] = HOME .. "/.minetest/games"
    local env = ie.os.getenv("LUANTI_GAME_PATH")
    if env then
        for p in env:gmatch("[^:]+") do dirs[#dirs + 1] = p end
    end

    local games, seen = {}, {}
    for _, dir in ipairs(dirs) do
        for _, entry in ipairs(list_dir(dir)) do
            local path = dir .. "/" .. entry
            local title = game_title(path .. "/game.conf")
            if title then
                local id = norm_gameid(entry)
                if not seen[id] then
                    seen[id] = true
                    games[#games + 1] = {id = id, title = title, path = path}
                end
            end
        end
    end
    table.sort(games, function(a, b) return a.title < b.title end)
    return games
end

-- Create a world directory with a complete world.mt: the headless server is
-- launched without --gameid, so the gameid must be resolvable from world.mt
-- alone (a partial file would leave it empty). Mirrors the fields written by
-- the engine's loadGameConfAndInitWorld (subgames.cpp).
local function create_world(wname, gameid)
    if not wname:match("^[A-Za-z0-9_%-]+$") then
        return nil, "nome non valido (solo lettere, numeri, _ e -)"
    end
    local wpath = WORLDS_DIR .. "/" .. wname
    if ie.io.open(wpath .. "/world.mt", "r") then
        return nil, ("il mondo '%s' esiste gia'"):format(wname)
    end
    ie.os.execute(("mkdir -p '%s'"):format(wpath))
    -- yafps is a survival arena; for anything else keep this world's flavor.
    local damage, creative
    if gameid == "yafps" then
        damage, creative = "true", "false"
    else
        damage = minetest.settings:get_bool("enable_damage", true)
            and "true" or "false"
        creative = minetest.settings:get_bool("creative_mode", false)
            and "true" or "false"
    end
    local f = ie.io.open(wpath .. "/world.mt", "w")
    if not f then
        return nil, "non riesco a scrivere world.mt"
    end
    f:write(table.concat({
        "world_name = " .. wname,
        "gameid = " .. gameid,
        "enable_damage = " .. damage,
        "creative_mode = " .. creative,
        "backend = sqlite3",
        "player_backend = sqlite3",
        "auth_backend = sqlite3",
        "mod_storage_backend = sqlite3",
        "load_mod_yaportal = true",
        "load_mod_yaportal_link = true",
    }, "\n") .. "\n")
    f:close()
    return wpath
end

local function next_free_port()
    local used = {[my_port] = true}
    for _, rec in pairs(running_worlds()) do used[rec.port or 0] = true end
    local p = PORT_BASE
    while used[p] do p = p + 1 end
    return p
end

-- Make sure world.mt of the target world enables our mods before launch.
local function enable_mods_in_world(wpath)
    local mt = wpath .. "/world.mt"
    local f = ie.io.open(mt, "r")
    local content = f and f:read("*a") or ""
    if f then f:close() end
    local changed = false
    for _, m in ipairs({"yaportal", "yaportal_link"}) do
        local key = "load_mod_" .. m
        if content:find(key .. "%s*=%s*true") then
            -- already enabled
        elseif content:find(key .. "%s*=") then
            content = content:gsub(key .. "%s*=%s*%S+", key .. " = true")
            changed = true
        else
            content = content .. "\n" .. key .. " = true\n"
            changed = true
        end
    end
    if changed then
        local w = ie.io.open(mt, "w")
        if w then w:write(content) w:close() end
    end
end

local function luanti_bin_ok()
    local p = ie.io.popen(("command -v '%s' 2>/dev/null"):format(LUANTI_BIN))
    if not p then return false end
    local found = p:read("*l")
    p:close()
    return found ~= nil or ie.io.open(LUANTI_BIN, "r") ~= nil
end

local function start_world(wname)
    local wpath = WORLDS_DIR .. "/" .. wname
    if not luanti_bin_ok() then
        minetest.log("error", "[yaportal_link] luanti binary not found: '" ..
            LUANTI_BIN .. "' — set yaportal_link_bin in minetest.conf")
        return nil
    end
    enable_mods_in_world(wpath)
    local port = next_free_port()
    local conf = DIR .. "/launch_" .. wname .. ".conf"
    local cf = ie.io.open(conf, "w")
    if cf then
        cf:write("secure.trusted_mods = yaportal_link\n")
        cf:write("default_privs = interact, shout\n")
        cf:write("disallow_empty_password = false\n")
        -- --port alone doesn't show up in minetest.settings: the launched
        -- world reads its own port (for the registry) from here.
        cf:write("port = " .. port .. "\n")
        cf:write("yaportal_link_bin = " .. LUANTI_BIN .. "\n")
        cf:close()
    end
    local cmd = ("nohup '%s' --server --world '%s' --port %d --config '%s' " ..
        "--logfile '%s/logs/%s.log' >/dev/null 2>&1 &")
        :format(LUANTI_BIN, wpath, port, conf, DIR, wname)
    minetest.log("action", "[yaportal_link] starting world: " .. cmd)
    ie.os.execute(cmd)
    return port
end

-- ── the panel: one door, one destination ────────────────────────────────────
--
-- The whole feature is two ideas: a door (a portal built from the cross-world
-- frame) and the door it leads to. So the panel shows exactly that — the door
-- you clicked, and one list with every door of every other world to pick its
-- destination from. Worlds that are not running are listed too and started on
-- demand: nothing has to be prepared in advance, and there is no endpoint to
-- announce, no request to accept, no portal name to type.

-- pname → {mine=<my ep>, doors={...}, rows={...}, sel=<row index>}
local panel_ctx = {}

local function esc(s) return minetest.formspec_escape(tostring(s)) end

-- Panel is admin-only on real servers; in singleplayer everyone is the admin.
local function panel_allowed(pname)
    return minetest.is_singleplayer()
        or minetest.check_player_privs(pname, {server = true})
end

local function my_doors()
    local out = {}
    for ep in pairs(my_endpoints) do out[#out + 1] = ep end
    table.sort(out, function(a, b) return my_label(a) < my_label(b) end)
    return out
end

local function door_display(eps, world, ep)
    if world == world_id then return world .. " / " .. my_label(ep) end
    local rec = eps[world .. "/" .. ep]
    return world .. " / " .. ((rec and rec.label) or ep)
end

local function is_local_world(wname)
    for _, w in ipairs(local_worlds()) do
        if w == wname then return true end
    end
    return false
end

-- Rows of the destination list: every door of every other world, plus the
-- worlds that have no door yet (they can still be started and visited).
local function destination_rows()
    local rows, eps, run, seen = {}, scan_endpoints(), running_worlds(), {}

    -- who is connected to whom, so a door that is taken says so
    local taken = {}
    for _, rec in pairs(scan_pairs()) do
        taken[rec.a.world .. "/" .. rec.a.ep] = rec.b
        taken[rec.b.world .. "/" .. rec.b.ep] = rec.a
    end

    for key, rec in pairs(eps) do
        if rec.world ~= world_id then
            seen[rec.world] = true
            rows[#rows + 1] = {kind = "door", world = rec.world, ep = rec.ep,
                label = rec.label or rec.ep,
                online = rec.online and true or false,
                remote = rec.remote and rec.addr or nil,
                rport = rec.remote and rec.port or nil,
                taken = taken[key],
                taken_txt = taken[key]
                    and door_display(eps, taken[key].world, taken[key].ep)}
        end
    end
    for w in pairs(run) do
        if w ~= world_id and not seen[w] then
            seen[w] = true
            rows[#rows + 1] = {kind = "world", world = w, online = true}
        end
    end
    for _, w in ipairs(local_worlds()) do
        if w ~= world_id and not seen[w] then
            rows[#rows + 1] = {kind = "world", world = w, online = false}
        end
    end

    -- Worlds that are up first, then alphabetical: what is usable right now
    -- sits at the top of the list.
    table.sort(rows, function(a, b)
        if a.online ~= b.online then return a.online end
        if a.world ~= b.world then return a.world < b.world end
        return (a.label or "") < (b.label or "")
    end)
    return rows
end

local function row_text(row, mine)
    if row.kind == "world" then
        return row.online
            and ("%s  --  acceso, nessuna porta li'"):format(row.world)
            or  ("%s  --  spento, nessuna porta li'"):format(row.world)
    end
    local where = ("%s / %s"):format(row.world, row.label)
    if row.remote then where = ("%s  [%s]"):format(where, row.remote) end
    local t = row.taken
    if t and t.world == world_id and t.ep == mine then
        return ("%s  --  COLLEGATA a questa porta"):format(where)
    elseif t then
        return ("%s  --  occupata: va a %s"):format(where, row.taken_txt)
    end
    if row.online then return where .. "  --  libera" end
    return row.remote and (where .. "  --  server remoto irraggiungibile")
        or (where .. "  --  mondo spento (lo avvio io)")
end

local function build_panel_form(pname)
    local ctx = panel_ctx[pname] or {}
    panel_ctx[pname] = ctx

    local doors = my_doors()
    ctx.doors = doors
    if not ctx.mine or not my_endpoints[ctx.mine] then ctx.mine = doors[1] end

    -- Nothing to configure yet: say how to make a door instead of showing
    -- empty lists.
    if #doors == 0 then
        return table.concat({
            "formspec_version[4]",
            "size[11,5.4]",
            "label[0.4,0.6;Porte fra i mondi  --  sei nel mondo: " .. esc(world_id) .. "]",
            "label[0.4,1.6;In questo mondo non c'e' ancora nessuna porta.]",
            "label[0.4,2.2;Costruisci un rettangolo di 'Cornice Portale Intermondo' attorno]",
            "label[0.4,2.7;a un'apertura d'aria, come una normale cornice yaportal.]",
            "label[0.4,3.4;La porta nasce da sola e compare qui: poi le scegli la destinazione.]",
            "button[0.4,4.3;2.2,0.8;refresh;Aggiorna]",
            "button[2.7,4.3;2.6,0.8;newworld;Nuovo mondo...]",
            "button_exit[8.4,4.3;2.2,0.8;close;Chiudi]",
        })
    end

    local eps  = scan_endpoints()
    local rows = destination_rows()
    ctx.rows = rows

    -- Where this door leads right now.
    local dest = connected_to(ctx.mine)
    local status
    if dest then
        local drec = eps[dest.world .. "/" .. dest.ep]
        status = "Adesso porta a:  " .. door_display(eps, dest.world, dest.ep)
        if not (drec and drec.online) then
            status = status .. "   (mondo spento: la porta si riaccende da sola)"
        end
    else
        status = "Questa porta non e' collegata: scegli qui sotto dove deve portare."
    end

    -- Door names in the dropdown; the field beside it renames the selected one.
    local names, cur = {}, 1
    for i, ep in ipairs(doors) do
        names[i] = esc(my_label(ep))
        if ep == ctx.mine then cur = i end
    end

    local list = {}
    for i, row in ipairs(rows) do
        list[i] = esc(row_text(row, ctx.mine))
    end
    if #list == 0 then
        list[1] = esc("(nessun altro mondo trovato in " .. WORLDS_DIR .. ")")
    end

    local fs = {
        "formspec_version[4]",
        "size[12,10.2]",
        "label[0.4,0.6;Porte fra i mondi  --  sei nel mondo: " .. esc(world_id) .. "]",

        "label[0.4,1.5;Porta:]",
        "dropdown[1.4,1.2;4.0,0.7;mine;" .. table.concat(names, ",") ..
            ";" .. cur .. ";true]",
        "field[5.7,1.2;3.6,0.7;newname;;" .. esc(my_label(ctx.mine)) .. "]",
        "field_close_on_enter[newname;false]",
        "button[9.5,1.2;2.1,0.7;rename;Rinomina]",

        "box[0.4,2.2;11.2,0.8;#3a3a3aff]",
        "label[0.6,2.6;" .. esc(status) .. "]",

        "label[0.4,3.5;Scegli dove deve portare:]",
        "button[8.6,3.15;3.0,0.6;newworld;Nuovo mondo...]",
        "textlist[0.4,3.8;11.2,4.2;dests;" .. table.concat(list, ",") ..
            ";" .. (ctx.sel or 0) .. ";false]",

        "button[0.4,8.2;2.6,0.8;connect;Collega qui]",
        "button[3.1,8.2;2.4,0.8;disconnect;Scollega]",
        "button[5.6,8.2;3.0,0.8;goto_world;Vai li' (senza portale)]",
        "button[8.7,8.2;1.4,0.8;refresh;Aggiorna]",
        "button_exit[10.2,8.2;1.4,0.8;close;Chiudi]",

        "label[0.4,9.35;'Collega qui' apre le due porte una sull'altra, nei due sensi. " ..
            "Un mondo spento parte da solo.]",
        "field[0.4,9.6;5.4,0.55;xaddr;;" .. esc(ctx.xaddr or "") .. "]",
        "field_close_on_enter[xaddr;false]",
        "button[5.9,9.6;5.7,0.55;xsearch;Cerca su un altro computer (IP)]",
    }
    return table.concat(fs)
end

local function show_panel(pname, ep)
    local ctx = panel_ctx[pname] or {}
    panel_ctx[pname] = ctx
    if ep and my_endpoints[ep] then
        if ctx.mine ~= ep then ctx.sel = nil end
        ctx.mine = ep
    end
    minetest.show_formspec(pname, "yaportal_link:panel", build_panel_form(pname))
end

-- The door a portal belongs to, by portal name.
local function ep_of_portal(portal_name)
    for ep, info in pairs(my_endpoints) do
        if info.portal == portal_name then return ep end
    end
    return nil
end

minetest.register_chatcommand("porte", {
    description = "Pannello delle porte fra i mondi",
    privs = {server = true},
    func = function(pname)
        show_panel(pname)
        return true
    end,
})

-- Old name, kept so existing habits and docs keep working.
minetest.register_chatcommand("worldportals", {
    description = "Pannello delle porte fra i mondi (alias di /porte)",
    privs = {server = true},
    func = function(pname)
        show_panel(pname)
        return true
    end,
})

minetest.register_chatcommand("portalhome", {
    description = "Torna a una porta intermondo di questo mondo (o allo spawn)",
    func = function(pname)
        local player = minetest.get_player_by_name(pname)
        if not player then return false end
        for _, p in ipairs(yaportal.xworld.list_portals()) do
            if my_endpoints[p.name] and p.pos then
                player:set_pos({x = p.pos.x, y = p.pos.y - 0.5, z = p.pos.z})
                return true, "Riportato alla porta '" .. my_label(p.name) .. "'."
            end
        end
        local sp = minetest.setting_get_pos and minetest.setting_get_pos("static_spawnpoint")
        player:set_pos(sp or {x = 0, y = 20, z = 0})
        return true, "Riportato allo spawn."
    end,
})

minetest.register_node("yaportal_link:panel", {
    description = "Pannello delle porte fra i mondi",
    tiles = {"yaportal_link_panel.png"},
    groups = {cracky = 3, oddly_breakable_by_hand = 2},
    on_rightclick = function(pos, node, clicker)
        local pname = clicker:get_player_name()
        if not panel_allowed(pname) then
            minetest.chat_send_player(pname, "Serve il privilegio 'server'.")
            return
        end
        show_panel(pname)
    end,
})

-- Dedicated cross-world portal frame. Built like a normal yaportal frame
-- (rectangle of these nodes around an air opening), but the resulting portal
-- is a door to another world, not an in-world play portal.
yaportal.xworld.register_frame_material(XFRAME)
minetest.register_node(XFRAME, {
    description = "Cornice Portale Intermondo\n" ..
        "1. costruisci un rettangolo attorno a un'apertura d'aria\n" ..
        "2. click destro sulla cornice\n" ..
        "3. scegli in che mondo deve portare",
    tiles = {"yaportal_link_frame.png"},
    groups = {cracky = 2, oddly_breakable_by_hand = 2},
    after_place_node = function(pos, placer)
        yaportal.xworld.activate_frame(pos, XFRAME, placer)
    end,
    after_dig_node = function(pos)
        yaportal.xworld.deactivate_frame(pos)
    end,
    on_rightclick = function(pos, node, clicker)
        -- Right-clicking a frame configures *that* door: no picking it out of a
        -- list, no typing its name.
        local pname = clicker:get_player_name()
        if not panel_allowed(pname) then
            minetest.chat_send_player(pname, "Serve il privilegio 'server'.")
            return
        end
        local portal = yaportal.xworld.portal_at and yaportal.xworld.portal_at(pos)
        show_panel(pname, portal and ep_of_portal(portal))
    end,
})

-- Walking into a door that leads nowhere: without this it looks broken.
yaportal.xworld.unlinked_handler = function(pname, portal_name)
    minetest.chat_send_player(pname, minetest.colorize("#FFAA55",
        "[porta] Questa porta non porta ancora da nessuna parte. Click destro " ..
        "sulla cornice per scegliere il mondo di destinazione."))
end

-- Per-game recipes: obsidian-ish walls around a light source. Registered only
-- when the ingredients exist, so no "unknown item" spam on games that lack them.
local function have(item) return minetest.registered_items[item] ~= nil end

local function add_frame_recipe(edge, center)
    if have(edge) and have(center) then
        minetest.register_craft({
            output = XFRAME .. " 4",
            recipe = {
                {"",   edge,   ""},
                {edge, center, edge},
                {"",   edge,   ""},
            },
        })
    end
end

-- Registered after all mods load: yaportal_link doesn't depend on the games,
-- so their nodes don't exist yet at this file's main chunk.
minetest.register_on_mods_loaded(function()
    -- Minetest Game
    add_frame_recipe("default:obsidian", "default:mese_crystal")
    -- VoxeLibre / MineClone
    add_frame_recipe("mcl_core:obsidian", "mesecons_torch:redstoneblock")
    -- Backrooms (backroomtest): yellow wallpaper walls around a ceiling light.
    add_frame_recipe("br_core:wallpaper_0", "br_core:ceiling_light_0")
    -- YaFPS: arena wall panels around an arena light.
    add_frame_recipe("yafps_core:wall", "yafps_core:light")
end)

-- Config-gated selftest for headless runs: logs the games the "new world"
-- dropdown would show and creates a throwaway yafps world, so the whole flow
-- is greppable without a GUI (set yaportal_link_worlds_dir to keep it out of
-- the real worlds directory).
if minetest.settings:get_bool("yaportal_link_selftest", false) then
    minetest.after(3, function()
        local ids = {}
        for _, g in ipairs(installed_games()) do ids[#ids + 1] = g.id end
        minetest.log("action", "[yaportal_link] selftest games: "
            .. table.concat(ids, ", "))
        local wpath, err = create_world("selftest_fps", "yafps")
        if wpath then
            minetest.log("action",
                "[yaportal_link] selftest PASS create_world " .. wpath)
        else
            minetest.log("error",
                "[yaportal_link] selftest FAIL create_world: " .. tostring(err))
        end
    end)
end

-- ── panel actions ───────────────────────────────────────────────────────────

local function say(pname, msg, color)
    minetest.chat_send_player(pname, color and minetest.colorize(color, msg) or msg)
end

-- Travel to a world without going through a portal. If it is not running,
-- start it and hop as soon as it answers.
local function travel_to(pname, wname)
    local rec = running_worlds()[wname]
    local function hop(r)
        if not minetest.get_player_by_name(pname) then return end
        local hrec = {player = pname, to_world = wname, ts = now()}
        write_handoff(pname, hrec)
        if r.remote then
            xpost(r.addr, r.port, {kind = "handoff", data = hrec})
        end
        minetest.close_formspec(pname, "yaportal_link:panel")
        core.redirect_player(pname, r.addr, r.port)
    end
    if rec then hop(rec) return end
    if not is_local_world(wname) then
        say(pname, ("Il mondo '%s' non e' su questo computer."):format(wname), "#FFAA55")
        return
    end
    if not start_world(wname) then
        say(pname, ("Non riesco ad avviare '%s': binario luanti non trovato " ..
            "(imposta yaportal_link_bin)."):format(wname), "#FF5555")
        return
    end
    say(pname, ("Avvio '%s'... ti porto li' appena e' pronto."):format(wname))
    local tries = 0
    local function poll()
        tries = tries + 1
        local r = running_worlds()[wname]
        if r then
            hop(r)
        elseif tries < 25 then
            minetest.after(1, poll)
        else
            say(pname, ("'%s' non si e' avviato: guarda %s/logs/%s.log.")
                :format(wname, DIR, wname), "#FF5555")
        end
    end
    minetest.after(2, poll)
end

-- Query a remote machine's exchange and pull its doors into the local
-- registry; from then on the heartbeat keeps them fresh like any other row.
local function search_remote(pname, input)
    if not http then
        say(pname, "Ricerca remota non disponibile: HTTP API spenta per questo mod.",
            "#FF5555")
        return
    end
    local addr, port = (input or ""):match("^%s*([%w%.%-]+):?(%d*)%s*$")
    port = tonumber(port) or 30000
    if not addr or addr == "" then
        say(pname, "Scrivi l'indirizzo del server, es. 192.168.1.20 oppure " ..
            "192.168.1.20:30000.", "#FFAA55")
        return
    end
    local srv = {addr = addr, port = port}
    say(pname, ("Cerco porte su %s:%d..."):format(addr, port))
    http.fetch({url = xurl(addr, port, "/registry"), timeout = 5}, function(res)
        if not minetest.get_player_by_name(pname) then return end
        if not res.succeeded then
            say(pname, ("Nessuna risposta da %s:%d (server spento, IP sbagliato " ..
                "o firewall sulla porta %d)."):format(addr, port, port + XPORT_OFF),
                "#FF5555")
            return
        end
        local resp = minetest.parse_json(res.data or "")
        if type(resp) ~= "table" or type(resp.world) ~= "table" then
            say(pname, "Risposta non valida: non sembra un server con yaportal_link.",
                "#FF5555")
            return
        end
        if resp.world.world == world_id then
            say(pname, "Quel server sei tu: serve l'IP di un'altra macchina.", "#FFAA55")
            return
        end
        local n = ingest_registry(srv, resp)
        remember_server(addr, port)
        say(pname, ("Trovato il mondo '%s': %d porte, ora in lista. " ..
            "D'ora in poi lo tengo d'occhio da solo.")
            :format(tostring(resp.world.world), n), "#55FF55")
        show_panel(pname)
    end)
end

local function do_connect(pname, ctx)
    local row = ctx.sel and ctx.rows and ctx.rows[ctx.sel]
    if not row then
        say(pname, "Scegli prima una destinazione nella lista.", "#FFAA55")
        return
    end
    if row.kind == "world" then
        -- A world with no door of its own: get it running, the door has to be
        -- built there.
        if not row.online then
            if start_world(row.world) then
                say(pname, ("Avvio '%s'. Quando e' acceso, vai li', costruisci una " ..
                    "cornice viola e torna qui: la sua porta comparira' nella lista.")
                    :format(row.world))
            else
                say(pname, ("Non riesco ad avviare '%s': binario luanti non trovato " ..
                    "(imposta yaportal_link_bin)."):format(row.world), "#FF5555")
            end
        else
            say(pname, ("'%s' non ha ancora una porta: usa 'Vai li'', costruisci una " ..
                "cornice viola e torna qui."):format(row.world), "#FFAA55")
        end
        return
    end

    -- A door on the other side: connect, and wake its world up if it is down so
    -- the link goes live by itself.
    connect_doors(ctx.mine, row.world, row.ep)
    -- Cross-machine pair: the other server cannot see our DIR, so send it our
    -- door and the pair record; its next heartbeat links its side.
    if row.remote then
        local myrec = read_json(ep_file(world_id, ctx.mine))
        if myrec then
            myrec.addr, myrec.remote = "auto", nil
            xpost(row.remote, row.rport, {kind = "endpoint", data = myrec})
        end
        xpost(row.remote, row.rport, {kind = "pair", data = {
            a = {world = world_id, ep = ctx.mine},
            b = {world = row.world, ep = row.ep},
            requester = world_id .. "/" .. ctx.mine,
        }})
    end
    local started = false
    if not row.online and is_local_world(row.world)
       and not running_worlds()[row.world] then
        started = start_world(row.world) ~= nil
    end
    say(pname, ("Fatto: '%s' adesso porta a %s / %s.%s"):format(
        my_label(ctx.mine), row.world, row.label,
        (row.online or started) and "" or " (accendi quel mondo per attraversarla)"),
        "#55FF55")
end

-- Sub-form: create a destination world, picking its game. The dropdown shows
-- every game the engine can see, defaulting to the one this world runs.
local function show_newworld_form(pname)
    local ctx = panel_ctx[pname] or {}
    panel_ctx[pname] = ctx
    local games = installed_games()
    ctx.games = games
    local cur_id = core.get_game_info
        and norm_gameid(core.get_game_info().id or "") or ""
    local titles, sel = {}, 1
    for i, g in ipairs(games) do
        titles[i] = esc(("%s (%s)"):format(g.title, g.id))
        if g.id == cur_id then sel = i end
    end
    minetest.show_formspec(pname, "yaportal_link:newworld", table.concat({
        "formspec_version[4]",
        "size[8.2,5.2]",
        "label[0.4,0.6;Nuovo mondo di destinazione]",
        "field[0.4,1.5;7.4,0.7;wname;Nome del mondo;]",
        "field_close_on_enter[wname;false]",
        "label[0.4,2.7;Gioco:]",
        "dropdown[1.6,2.4;6.2,0.7;wgame;" .. table.concat(titles, ",") ..
            ";" .. sel .. ";true]",
        "button[0.4,4.0;2.6,0.8;wcreate;Crea e avvia]",
        "button[5.8,4.0;2.0,0.8;wcancel;Annulla]",
    }))
end

minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= "yaportal_link:newworld" then return end
    local pname = player:get_player_name()
    if not panel_allowed(pname) then return true end
    if fields.wcancel then
        show_panel(pname)
        return true
    end
    if not (fields.wcreate or fields.key_enter_field == "wname") then
        return true
    end
    local ctx = panel_ctx[pname] or {}
    local games = ctx.games or installed_games()
    local g = games[tonumber(fields.wgame) or 0]
    local wname = (fields.wname or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if not g then
        say(pname, "Scegli un gioco nella lista.", "#FFAA55")
        return true
    end
    local wpath, err = create_world(wname, g.id)
    if not wpath then
        say(pname, "Mondo non creato: " .. err, "#FF5555")
        show_newworld_form(pname)
        return true
    end
    if start_world(wname) then
        say(pname, ("Creato '%s' (gioco %s): lo sto avviando. Usa 'Vai li'' " ..
            "oppure collegaci una porta."):format(wname, g.id), "#55FF55")
    else
        say(pname, ("Creato '%s' (gioco %s), ma non riesco ad avviarlo: " ..
            "binario luanti non trovato (imposta yaportal_link_bin).")
            :format(wname, g.id), "#FFAA55")
    end
    show_panel(pname)
    return true
end)

minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= "yaportal_link:panel" then return end
    local pname = player:get_player_name()
    if not panel_allowed(pname) then return true end
    local ctx = panel_ctx[pname]
    if not ctx then show_panel(pname) return true end

    -- Every element submits its value on any event, so the door dropdown is
    -- read first and only the button actually pressed decides what happens.
    local was = ctx.mine
    local di = tonumber(fields.mine)
    if di and ctx.doors and ctx.doors[di] then ctx.mine = ctx.doors[di] end

    if fields.dests then
        local ev = minetest.explode_textlist_event(fields.dests)
        if ev.type == "CHG" or ev.type == "DCL" then ctx.sel = ev.index end
        if ev.type == "DCL" then
            do_connect(pname, ctx)
            show_panel(pname)
            return true
        end
        -- A plain selection must not rebuild the form: that would drop it.
        if ev.type == "CHG" then return true end
    end

    if fields.rename then
        local nm = (fields.newname or ""):gsub("^%s+", ""):gsub("%s+$", "")
        local info = ctx.mine and my_endpoints[ctx.mine]
        if info and nm ~= "" then
            info.label = nm:sub(1, 24)
            save_endpoints()
            announce_endpoints()
            say(pname, "Porta rinominata: " .. info.label)
        end
    elseif fields.connect then
        do_connect(pname, ctx)
    elseif fields.disconnect then
        if ctx.mine then
            disconnect_door(ctx.mine)
            say(pname, ("'%s' non porta piu' da nessuna parte."):format(my_label(ctx.mine)))
        end
    elseif fields.goto_world then
        local row = ctx.sel and ctx.rows and ctx.rows[ctx.sel]
        if row then
            travel_to(pname, row.world)
            return true
        end
        say(pname, "Scegli prima un mondo nella lista.", "#FFAA55")
    elseif fields.newworld then
        show_newworld_form(pname)
        return true
    elseif fields.xsearch or fields.key_enter_field == "xaddr" then
        ctx.xaddr = fields.xaddr
        search_remote(pname, fields.xaddr)
        return true
    elseif not fields.refresh and ctx.mine == was then
        -- Nothing to do (quit/esc, or an event we don't act on).
        return true
    end

    show_panel(pname)
    return true
end)

minetest.register_on_leaveplayer(function(player)
    panel_ctx[player:get_player_name()] = nil
end)

-- ── retired: mirror region ──────────────────────────────────────────────────
--
-- Each side used to serialize the node zone around its portal into
-- $DIR/spool/, and the paired side copied that snapshot into a reserved
-- high-altitude band of its own map, with a mirror portal the local
-- cross-world portal linked to, so the RTT showed *something* of the other
-- world. The dual-client session renders the real world B now, so the copy is
-- dead weight: a second, always-stale version of another world's rooms sitting
-- in every paired world's map. What is left here only clears it away.

local S_SYNC = 2

local function cleanup_mirror_band()
    -- Mirror portals first: they link the local portal to the copied zone.
    for _, p in ipairs(yaportal.xworld.list_portals()) do
        if p.name:match("^gun9_xmir_") then
            yaportal.xworld.close_portal(p.name)
            minetest.log("action", "[yaportal_link] removed mirror portal " .. p.name)
        end
    end

    -- Then the copied nodes. The band is a reserved scratch area (y = 24000,
    -- x/z around -29000), never part of the playable world, so clearing it to
    -- air cannot destroy anything built.
    local raw = storage:get_string("mirror_slots")
    local slots = raw ~= "" and minetest.parse_json(raw) or nil
    if type(slots) == "table" then
        local air = minetest.get_content_id("air")
        local r = 12
        for _, slot in pairs(slots) do
            local sx, sz = slot % 20, math.floor(slot / 20)
            local base = {x = -29000 + sx * 100, y = 24000, z = -29000 + sz * 100}
            local minp = {x = base.x - r, y = base.y - r, z = base.z - r}
            local maxp = {x = base.x + r, y = base.y + r, z = base.z + r}
            local vm = minetest.get_voxel_manip(minp, maxp)
            local emin, emax = vm:get_emerged_area()
            local va = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
            local data = vm:get_data()
            for vi in va:iterp(minp, maxp) do data[vi] = air end
            vm:set_data(data)
            vm:write_to_map(true)
        end
        storage:set_string("mirror_slots", "")
        minetest.log("action", "[yaportal_link] cleared mirror band")
    end

    -- And the snapshot directory: nothing reads it any more.
    for _, fn in ipairs(list_dir(DIR .. "/spool")) do
        remove_file(DIR .. "/spool/" .. fn)
    end
    ie.os.execute(("rmdir '%s/spool' 2>/dev/null"):format(DIR))
end

minetest.after(2, cleanup_mirror_band)

local sync_timer = 0
minetest.register_globalstep(function(dtime)
    sync_timer = sync_timer + dtime
    if sync_timer < S_SYNC then return end
    sync_timer = 0
    local eps = scan_endpoints()
    -- Server the client's passive second session should connect to. Only the
    -- registry knows which port the paired world currently listens on.
    local xtarget = nil
    local live_slots = {}
    for _, rec in pairs(scan_pairs()) do
        local other, mine = pair_other_side(rec)
        if other and rec.status == "confirmed" and my_endpoints[mine.ep] then
            local other_ep = eps[other.world .. "/" .. other.ep]
            local slot = yaportal.xworld.engine_slot(my_endpoints[mine.ep].portal)
            if other_ep and other_ep.online then
                -- The portal's RTT renders the real world B, live, from the
                -- paired destination portal's frame.
                if slot and other_ep.def and core.set_portal_xworld_dest then
                    local g = yaportal.xworld.portal_geom(other_ep.def)
                    core.set_portal_xworld_dest(slot, g.pos, g.normal, g.up)
                    live_slots[slot] = true
                end
                if not xtarget and other_ep.addr and other_ep.port then
                    xtarget = {addr = other_ep.addr, port = other_ep.port,
                        world = other.world}
                end
            elseif slot and core.clear_portal_xworld_dest then
                -- Other side offline: the portal has nothing to show.
                core.clear_portal_xworld_dest(slot)
            end
        end
    end
    -- Slots are assigned by portal order, so a portal that goes away hands its
    -- slot to another one — which would then inherit a destination that has
    -- nothing to do with it, and show another world through the wrong portal.
    if core.clear_portal_xworld_dest then
        for slot = 0, 15 do
            if not live_slots[slot] then core.clear_portal_xworld_dest(slot) end
        end
    end

    if core.set_xworld_target then
        if xtarget then
            core.set_xworld_target(xtarget.addr, xtarget.port, xtarget.world)
        else
            core.clear_xworld_target()
        end
    end
end)

-- Double-open guard: opening a world that already runs as a server (e.g. from
-- the menu after starting it from the panel) locks mod storage in other mods
-- and crashes on shutdown. Refuse to load — before anything touches the DB.
do
    local rec = read_json(DIR .. "/worlds/" .. world_id .. ".json")
    if rec and (now() - (rec.ts or 0)) < T_ONLINE then
        error("\n\nIl mondo '" .. world_id .. "' e' GIA' AVVIATO come server " ..
            "(porta " .. tostring(rec.port) .. ").\nNon aprirlo una seconda " ..
            "volta: entra in un altro mondo e raggiungilo con \"Vai li'\" dal " ..
            "pannello /porte.\n")
    end
end

-- Clean shutdown: retire the presence record so the world can be reopened
-- immediately (the double-open guard only trips on a *live* heartbeat). The
-- endpoint files stay: a door of a world that is currently off is still a
-- destination you can pick — the panel starts the world when you do.
minetest.register_on_shutdown(function()
    remove_file(DIR .. "/worlds/" .. world_id .. ".json")
end)

-- First announce shortly after startup (portals from mod storage may need a tick)
minetest.after(1, function()
    -- Provisioning: auto-announce portals listed in the config, e.g.
    --   yaportal_link_auto_endpoints = testport_a, hub_portal
    local auto = minetest.settings:get("yaportal_link_auto_endpoints") or ""
    for name in auto:gmatch("[^,%s]+") do
        if yaportal.xworld.get_portal(name) then
            if not my_endpoints[name] then
                my_endpoints[name] = {portal = name, open = true}
            end
        else
            minetest.log("warning",
                "[yaportal_link] auto endpoint '" .. name .. "': no such portal")
        end
    end
    save_endpoints()
    announce_endpoints()
    sync_links()
end)

minetest.log("action", ("[yaportal_link] world '%s' on %s:%d, registry at %s, bin %s")
    :format(world_id, my_addr, my_port, DIR, LUANTI_BIN))
