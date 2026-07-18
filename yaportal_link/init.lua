-- yaportal_link — cross-world portals over multiple local servers.
--
-- Each participating world runs this mod (trusted). Coordination happens
-- through a shared directory of small JSON files (one record per file, no
-- locking needed: every file has a single writer):
--   $DIR/worlds/<world>.json                 server presence + port (heartbeat)
--   $DIR/endpoints/<world>__<ep>.json        announced portal endpoints
--   $DIR/pairs/<aW>__<aEp>__<bW>__<bEp>.json pairing state (pending/confirmed)
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

ie.os.execute(("mkdir -p '%s/worlds' '%s/endpoints' '%s/pairs' '%s/handoff' " ..
    "'%s/logs' '%s/announce_req'")
    :format(DIR, DIR, DIR, DIR, DIR, DIR))

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

-- ep name → {portal=<yaportal name>, open=bool}
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

local function announce_endpoints()
    -- Publish only cross-world endpoints (auto-registered xframe portals),
    -- never ordinary play portals.
    local pnames = {}
    for _, p in ipairs(yaportal.xworld.list_portals()) do
        if #pnames < 20 and p.node_name == XFRAME then
            pnames[#pnames + 1] = p.name
        end
    end
    write_json(DIR .. "/worlds/" .. world_id .. ".json",
        {world = world_id, addr = my_addr, port = my_port, ts = now(),
         portals = pnames})
    -- Remote announce requests (from another world's panel): announce one of
    -- our portals as an endpoint without anyone having to join us first.
    for _, fn in ipairs(list_dir(DIR .. "/announce_req")) do
        local w, portal = fn:match("^(.-)__(.+)%.json$")
        if w == world_id and portal then
            if yaportal.xworld.get_portal(portal) then
                my_endpoints[portal] = my_endpoints[portal]
                    or {portal = portal, open = true}
                save_endpoints()
                minetest.log("action",
                    "[yaportal_link] endpoint '" .. portal .. "' announced remotely")
            else
                minetest.log("warning", "[yaportal_link] remote announce: no portal '"
                    .. portal .. "'")
            end
            remove_file(DIR .. "/announce_req/" .. fn)
        end
    end
    for ep, info in pairs(my_endpoints) do
        local pp = yaportal.xworld.get_portal(info.portal)
        if pp then
            local c = yaportal.xworld.inner_center(pp)
            local n = yaportal.xworld.basis(pp)
            write_json(ep_file(world_id, ep), {
                world = world_id, ep = ep, addr = my_addr, port = my_port,
                portal = info.portal, open = info.open and true or false,
                pos = {x = c.x, y = c.y, z = c.z},
                normal = {x = n.x, y = n.y, z = n.z},
                -- raw portal geometry, needed to rebuild the mirror portal
                def = {cx = pp.cx, cy = pp.cy, cz = pp.cz, axis = pp.axis,
                       ns = pp.ns, w = pp.w, h = pp.h, rot = pp.rot,
                       ou = pp.ou, ov = pp.ov, node_name = pp.node_name},
                ts = now(),
            })
        else
            -- Portal gone (closed/broken): stop announcing so nobody pairs
            -- with a dead endpoint. Keep the my_endpoints entry: it revives
            -- if a portal with the same name comes back.
            remove_file(ep_file(world_id, ep))
        end
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
        if rec and rec.a and rec.b then out[fn] = rec end
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

-- Every portal built from the dedicated cross-world frame is auto-registered
-- as an endpoint (open); ordinary yaportal portals are never touched. Drops
-- endpoints whose portal no longer exists or is no longer an xworld frame.
local function sync_xframe_endpoints()
    for _, p in ipairs(yaportal.xworld.list_portals()) do
        if p.node_name == XFRAME then
            if not my_endpoints[p.name] then
                my_endpoints[p.name] = {portal = p.name, open = true}
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
    for ep in pairs(my_endpoints) do
        local pp = yaportal.xworld.get_portal(ep)
        if not pp or pp.node_name ~= XFRAME then
            my_endpoints[ep] = nil
            remove_file(ep_file(world_id, ep))
            if pp then yaportal.xworld.set_link(ep, nil) end
        end
    end
    save_endpoints()
end

-- ── heartbeat ────────────────────────────────────────────────────────────────

local hb_timer = 0
minetest.register_globalstep(function(dtime)
    hb_timer = hb_timer + dtime
    if hb_timer < S_HEARTBEAT then return end
    hb_timer = 0
    sync_xframe_endpoints()
    announce_endpoints()
    sync_links()
end)

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
-- Long enough to cover the ghost's retries: its first announcements are
-- dropped while the server still considers the connection inactive.
local GHOST_CONFIRM_T = 6  -- s to wait for a ghost to announce itself

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
    local addr = (live and live.addr) or other.addr
    local port = (live and live.port) or other.port

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

    local slot = yaportal.xworld.engine_slot(portal_name)
    local swapped = false
    if slot and core.xworld_swap_player then
        swapped = core.xworld_swap_player(pname, addr, port, slot,
            other.world, other.ep)
    end

    minetest.log("action", ("[yaportal_link] %s crosses '%s' -> %s/%s (%s:%d)%s")
        :format(pname, portal_name, other.world, other.ep, addr, port,
            swapped and " [swap]" or " [redirect]"))

    if swapped then
        -- The player stays connected here as a ghost so this world remains
        -- visible through the portal from the other side.
        park(player)
        park_at_endpoint(pname)
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

-- A joining connection is one of three things and we cannot tell them apart
-- yet: a normal player, a player arriving through a portal (handoff on disk),
-- or a passive ghost whose client is playing in another world. Park everyone
-- first, then release whoever turns out to be playing here — parking a player
-- for a fraction of a second is invisible, letting a ghost walk around is not.
minetest.register_on_joinplayer(function(player)
    local pname = player:get_player_name()
    park(player)

    local rec = read_handoff(pname)
    local arriving = rec and (now() - (rec.ts or 0)) <= T_HANDOFF

    if arriving then
        -- Redirect hop: this connection is the player. Place and release.
        minetest.after(0.2, function()
            unpark(pname)
            apply_handoff(pname)
        end)
        return
    end

    -- Give a ghost time to announce itself with /xworld_park; if nothing
    -- arrives, this is an ordinary join.
    minetest.after(GHOST_CONFIRM_T, function()
        local st = parked[pname]
        if st and not st.ghost then
            unpark(pname)
        end
    end)
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

-- ── pairing panel ────────────────────────────────────────────────────────────

-- pname → {remote_keys={...}, pending_files={...}, offline_worlds={...}}
local panel_ctx = {}

local function esc(s) return minetest.formspec_escape(tostring(s)) end

-- Panel is admin-only on real servers; in singleplayer everyone is the admin.
local function panel_allowed(pname)
    return minetest.is_singleplayer()
        or minetest.check_player_privs(pname, {server = true})
end

local function build_panel_form(pname)
    local ctx = {remote_keys = {}, pending_files = {}, offline_worlds = {},
        online_worlds = {}}
    panel_ctx[pname] = ctx

    local eps = scan_endpoints()
    local prs = scan_pairs()
    local run = running_worlds()

    -- pair status per endpoint key
    local paired, pending_out, pending_in = {}, {}, {}
    for fn, rec in pairs(prs) do
        local ka = rec.a.world .. "/" .. rec.a.ep
        local kb = rec.b.world .. "/" .. rec.b.ep
        if rec.status == "confirmed" then
            paired[ka], paired[kb] = kb, ka
        elseif rec.status == "pending" then
            pending_out[ka] = kb
            pending_in[kb] = {other = ka, file = fn}
        end
    end

    local fs = {
        "formspec_version[4]",
        "size[13,12.8]",
        "label[0.4,0.5;Portali intermondo — mondo: " .. esc(world_id) .. "]",
    }

    -- My cross-world endpoints: portals built from the dedicated frame, auto
    -- registered. Ordinary play portals never appear here.
    local ep_names = {}
    for ep in pairs(my_endpoints) do ep_names[#ep_names + 1] = ep end
    table.sort(ep_names)
    local portals_dd = #ep_names > 0 and table.concat(ep_names, ",")
        or "(nessun portale intermondo qui)"

    -- My endpoints
    fs[#fs + 1] = "label[0.4,1.2;I MIEI portali intermondo (cornice viola):]"
    local my_list = {}
    for _, ep in ipairs(ep_names) do
        local key = world_id .. "/" .. ep
        local st = paired[key] and ("accoppiato con " .. paired[key])
            or pending_out[key] and ("richiesta inviata a " .. pending_out[key])
            or pending_in[key] and ("richiesta DA " .. pending_in[key].other)
            or "libero"
        my_list[#my_list + 1] = esc(ep .. "  [" .. st .. "]")
    end
    fs[#fs + 1] = "textlist[0.4,1.6;5.8,2.2;my_eps;" .. table.concat(my_list, ",") .. "]"
    fs[#fs + 1] = "label[0.4,4.0;Costruisci una cornice viola per creare un portale intermondo.]"

    -- Remote endpoints
    fs[#fs + 1] = "label[6.8,1.2;Endpoint remoti online:]"
    local remote_list = {}
    for key, rec in pairs(eps) do
        if rec.world ~= world_id and rec.online then
            ctx.remote_keys[#ctx.remote_keys + 1] = key
            local st = paired[key] and "accoppiato" or "libero"
            remote_list[#remote_list + 1] = esc(key .. "  [" .. st .. "]")
        end
    end
    fs[#fs + 1] = "textlist[6.8,1.6;5.8,2.2;remotes;" .. table.concat(remote_list, ",") .. "]"
    fs[#fs + 1] = "field[6.8,4.3;3.4,0.7;pair_from;Mio endpoint da collegare;]"
    fs[#fs + 1] = "button[10.4,4.3;2.2,0.7;pair_req;Richiedi collegamento]"

    -- Incoming requests
    fs[#fs + 1] = "label[0.4,5.5;Richieste in arrivo:]"
    local in_list = {}
    for key, p in pairs(pending_in) do
        local w, e = key:match("([^/]+)/(.+)")
        if w == world_id and my_endpoints[e] then
            ctx.pending_files[#ctx.pending_files + 1] = p.file
            in_list[#in_list + 1] = esc(p.other .. "  ->  " .. key)
        end
    end
    fs[#fs + 1] = "textlist[0.4,5.9;5.8,1.8;pending;" .. table.concat(in_list, ",") .. "]"
    fs[#fs + 1] = "button[0.4,7.9;1.6,0.7;accept;Accetta]"
    fs[#fs + 1] = "button[2.2,7.9;1.6,0.7;reject;Rifiuta]"

    -- Offline local worlds (on-demand start)
    fs[#fs + 1] = "label[6.8,5.5;Mondi locali fermi (avvio on-demand):]"
    local off_list = {}
    for _, w in ipairs(local_worlds()) do
        if w ~= world_id and not run[w] then
            ctx.offline_worlds[#ctx.offline_worlds + 1] = w
            off_list[#off_list + 1] = esc(w)
        end
    end
    fs[#fs + 1] = "textlist[6.8,5.9;5.8,1.8;offline;" .. table.concat(off_list, ",") .. "]"
    fs[#fs + 1] = "button[6.8,7.9;2.2,0.7;start_world;Avvia mondo]"

    -- Online worlds (running servers), with or without announced endpoints:
    -- jump straight to their spawn, or announce one of their portals from here.
    fs[#fs + 1] = "label[0.4,8.8;Mondi online:]"
    local on_list = {}
    for w, rec in pairs(run) do
        if w ~= world_id then
            ctx.online_worlds[#ctx.online_worlds + 1] = rec
            local plist = rec.portals and #rec.portals > 0
                and table.concat(rec.portals, ", ") or "nessun portale"
            on_list[#on_list + 1] = esc(("%s (:%d) — %s"):format(w, rec.port or 0, plist))
        end
    end
    fs[#fs + 1] = "textlist[0.4,9.1;7.0,1.6;online;" .. table.concat(on_list, ",") .. "]"
    fs[#fs + 1] = "button[8.0,9.1;2.0,0.7;goto_world;Vai (spawn)]"
    fs[#fs + 1] = "button[10.2,9.1;2.4,0.7;rannounce;Annuncia remoto]"
    -- One-click link: my local portal <-> a portal of the selected online world.
    fs[#fs + 1] = "label[0.4,10.5;Collega un MIO portale a uno del mondo online selezionato:]"
    fs[#fs + 1] = "dropdown[0.4,10.9;3.2,0.7;link_mine;" .. portals_dd .. ";1]"
    fs[#fs + 1] = "field[3.8,10.9;3.2,0.7;link_theirs;SUO portale (vedi riga);]"
    fs[#fs + 1] = "button[7.2,10.9;2.4,0.7;link_direct;Collega i due]"

    fs[#fs + 1] = "button[0.4,11.9;2.0,0.7;refresh;Aggiorna]"
    fs[#fs + 1] = "button_exit[10.6,11.9;2.0,0.7;close;Chiudi]"
    return table.concat(fs)
end

local function show_panel(pname)
    minetest.show_formspec(pname, "yaportal_link:panel", build_panel_form(pname))
end

minetest.register_chatcommand("worldportals", {
    description = "Pannello portali intermondo",
    privs = {server = true},
    func = function(pname)
        show_panel(pname)
        return true
    end,
})

-- Escape hatch: get out of the hidden mirror region (y ~24000) back to a local
-- cross-world portal, or to spawn.
minetest.register_chatcommand("portalhome", {
    description = "Torna a un portale intermondo (o allo spawn) — esci dalla mirror region",
    func = function(pname)
        local player = minetest.get_player_by_name(pname)
        if not player then return false end
        for _, p in ipairs(yaportal.xworld.list_portals()) do
            if my_endpoints[p.name] and p.pos then
                player:set_pos({x = p.pos.x, y = p.pos.y - 0.5, z = p.pos.z})
                return true, "Riportato al portale intermondo '" .. p.name .. "'."
            end
        end
        local sp = minetest.setting_get_pos and minetest.setting_get_pos("static_spawnpoint")
        player:set_pos(sp or {x = 0, y = 20, z = 0})
        return true, "Riportato allo spawn."
    end,
})

minetest.register_node("yaportal_link:panel", {
    description = "Pannello portali intermondo",
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
-- is a cross-world endpoint, not an in-world play portal.
yaportal.xworld.register_frame_material(XFRAME)
minetest.register_node(XFRAME, {
    description = "Cornice Portale Intermondo\n(costruisci un rettangolo attorno " ..
        "a un'apertura d'aria, come una cornice yaportal)",
    tiles = {"yaportal_link_frame.png"},
    groups = {cracky = 2, oddly_breakable_by_hand = 2},
    after_place_node = function(pos, placer)
        yaportal.xworld.activate_frame(pos, XFRAME, placer)
    end,
    after_dig_node = function(pos)
        yaportal.xworld.deactivate_frame(pos)
    end,
    on_rightclick = function(pos, node, clicker)
        -- Configuring a cross-world frame opens the linking panel directly.
        local pname = clicker:get_player_name()
        if panel_allowed(pname) then show_panel(pname) end
    end,
})

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
end)

-- selection state per player (textlist indexes)
local sel = {}

minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= "yaportal_link:panel" then return end
    local pname = player:get_player_name()
    if not panel_allowed(pname) then return true end
    local ctx = panel_ctx[pname] or {remote_keys = {}, pending_files = {}, offline_worlds = {}}
    sel[pname] = sel[pname] or {}

    for _, f in ipairs({"remotes", "pending", "offline", "online"}) do
        if fields[f] then
            local ev = minetest.explode_textlist_event(fields[f])
            if ev.type == "CHG" then sel[pname][f] = ev.index end
        end
    end

    if fields.announce and fields.new_ep and fields.new_ep ~= "" then
        local portal = fields.new_ep
        if yaportal.xworld.get_portal(portal) then
            my_endpoints[portal] = {portal = portal, open = false}
            save_endpoints()
            announce_endpoints()
            minetest.chat_send_player(pname, "Endpoint '" .. portal .. "' annunciato.")
        else
            minetest.chat_send_player(pname, "Portale yaportal '" .. portal .. "' inesistente.")
        end
        show_panel(pname)
    elseif fields.pair_req then
        local idx = sel[pname].remotes
        local key = idx and ctx.remote_keys[idx]
        local mine = fields.pair_from or ""
        if key and my_endpoints[mine] then
            local bw, be = key:match("([^/]+)/(.+)")
            write_json(pair_file(world_id, mine, bw, be), {
                a = {world = world_id, ep = mine}, b = {world = bw, ep = be},
                status = "pending", requester = world_id .. "/" .. mine, ts = now(),
            })
            minetest.chat_send_player(pname, "Richiesta inviata a " .. key .. ".")
        else
            minetest.chat_send_player(pname,
                "Seleziona un endpoint remoto e indica un tuo endpoint valido.")
        end
        show_panel(pname)
    elseif fields.accept or fields.reject then
        local idx = sel[pname].pending
        local fn = idx and ctx.pending_files[idx]
        if fn then
            local path = DIR .. "/pairs/" .. fn
            if fields.accept then
                local rec = read_json(path)
                if rec then
                    rec.status = "confirmed"
                    rec.ts = now()
                    write_json(path, rec)
                    minetest.chat_send_player(pname, "Collegamento confermato.")
                    sync_links()
                end
            else
                remove_file(path)
                minetest.chat_send_player(pname, "Richiesta rifiutata.")
            end
        end
        show_panel(pname)
    elseif fields.goto_world then
        local idx = sel[pname].online
        local rec = idx and ctx.online_worlds[idx]
        if rec then
            write_handoff(pname, {
                player = pname, to_world = rec.world, ts = now(),
            })
            minetest.close_formspec(pname, "yaportal_link:panel")
            core.redirect_player(pname, rec.addr, rec.port)
        else
            minetest.chat_send_player(pname, "Seleziona un mondo online.")
            show_panel(pname)
        end
    elseif fields.rannounce then
        local idx = sel[pname].online
        local rec = idx and ctx.online_worlds[idx]
        local portal = fields.rannounce_portal or ""
        if rec and portal ~= "" then
            write_json(DIR .. "/announce_req/" .. rec.world .. "__" .. portal .. ".json",
                {world = rec.world, portal = portal, ts = now()})
            minetest.chat_send_player(pname,
                ("Richiesta inviata: '%s' su '%s' — comparirà tra gli endpoint " ..
                 "remoti entro qualche secondo."):format(portal, rec.world))
        else
            minetest.chat_send_player(pname,
                "Seleziona un mondo online e scrivi il nome di un suo portale.")
        end
        show_panel(pname)
    elseif fields.link_direct then
        -- One click: announce my local portal, ask the remote world to announce
        -- its portal, and create the confirmed pair. The link activates as soon
        -- as the remote endpoint comes online (sync_links waits for it).
        local idx = sel[pname].online
        local rec = idx and ctx.online_worlds[idx]
        local mine = fields.link_mine or ""
        local theirs = fields.link_theirs or ""
        if not rec then
            minetest.chat_send_player(pname, "Seleziona prima un mondo online.")
        elseif mine == "" or mine:sub(1, 1) == "(" or theirs == "" then
            minetest.chat_send_player(pname,
                "Serve un TUO portale intermondo (cornice viola) e il nome del " ..
                "portale remoto.")
        elseif not my_endpoints[mine] then
            minetest.chat_send_player(pname,
                "'" .. mine .. "' non e' un portale intermondo di questo mondo.")
        else
            -- my local endpoint
            my_endpoints[mine] = my_endpoints[mine] or {portal = mine, open = true}
            save_endpoints()
            announce_endpoints()
            -- remote endpoint request
            write_json(DIR .. "/announce_req/" .. rec.world .. "__" .. theirs .. ".json",
                {world = rec.world, portal = theirs, ts = now()})
            -- confirmed pair (order by world name for a stable filename)
            local pa = {world = world_id, ep = mine}
            local pb = {world = rec.world, ep = theirs}
            write_json(pair_file(pa.world, pa.ep, pb.world, pb.ep), {
                a = pa, b = pb, status = "confirmed",
                requester = world_id .. "/" .. mine, ts = now(),
            })
            sync_links()
            minetest.chat_send_player(pname, minetest.colorize("#55FF55",
                ("Collegato '%s' <-> %s/'%s'. Il portale si attiva appena il " ..
                 "mondo remoto annuncia il suo (pochi secondi)."):format(
                 mine, rec.world, theirs)))
        end
        show_panel(pname)
    elseif fields.start_world then
        local idx = sel[pname].offline
        local w = idx and ctx.offline_worlds[idx]
        if w then
            local port = start_world(w)
            minetest.chat_send_player(pname, port
                and ("Avvio '%s' sulla porta %d — comparirà tra i mondi online."):format(w, port)
                or ("Impossibile avviare '%s': binario luanti non trovato " ..
                    "(imposta yaportal_link_bin)."):format(w))
        end
        show_panel(pname)
    elseif fields.refresh then
        show_panel(pname)
    end
    return true
end)

minetest.register_on_leaveplayer(function(player)
    local pname = player:get_player_name()
    panel_ctx[pname] = nil
    sel[pname] = nil
end)

-- ── mirror region: live view of the other world through the portal ──────────
--
-- Each side periodically serializes the node zone around its announced portal
-- into $DIR/spool/<world>__<ep>.json. The paired side copies that zone into a
-- reserved high-altitude band of its own map (one slot per pair) and creates a
-- mirror portal there; the local cross-world portal gets a one-way local link
-- to the mirror, so the whole existing RTT pipeline renders the other world's
-- exit zone unchanged. Interaction in the band is blocked.

local R        = tonumber(minetest.settings:get("yaportal_link_mirror_radius")) or 8
local MIRROR_Y = 24000
local S_SYNC   = 2

ie.os.execute(("mkdir -p '%s/spool'"):format(DIR))

minetest.register_node("yaportal_link:unknown", {
    description = "Nodo sconosciuto (mirror intermondo)",
    tiles = {"yaportal_link_panel.png^[colorize:#7722AA:180"},
    groups = {not_in_creative_inventory = 1},
    diggable = false,
})

-- Slot allocation (persisted): pairkey → slot index on a 20x20 grid.
local mirror_slots = {}
do
    local raw = storage:get_string("mirror_slots")
    if raw and raw ~= "" then
        local t = minetest.parse_json(raw)
        if type(t) == "table" then mirror_slots = t end
    end
end

local function slot_base(slot)
    local sx, sz = slot % 20, math.floor(slot / 20)
    return {x = -29000 + sx * 100, y = MIRROR_Y, z = -29000 + sz * 100}
end

local function get_slot(pairkey)
    if mirror_slots[pairkey] then return mirror_slots[pairkey] end
    local used = {}
    for _, s in pairs(mirror_slots) do used[s] = true end
    local s = 0
    while used[s] do s = s + 1 end
    mirror_slots[pairkey] = s
    storage:set_string("mirror_slots", minetest.write_json(mirror_slots))
    return s
end

-- Anything in the mirror band is read-only for players.
local old_is_protected = minetest.is_protected
function minetest.is_protected(pos, name)
    if pos.y > MIRROR_Y - 500 and pos.y < MIRROR_Y + 500 then
        return true
    end
    return old_is_protected(pos, name)
end

-- Writer: serialize the zone around one of my endpoints if it changed.
local spool_hash = {}
local forceloaded = {}
local function write_spool(ep, info)
    local pp = yaportal.xworld.get_portal(info.portal)
    if not pp then return end
    local c = {x = pp.cx, y = pp.cy, z = pp.cz}
    -- Keep the whole exit zone loaded so the spool stays live with no players
    -- near (the zone spans up to 8 mapblocks; bump max_forceloaded_blocks if
    -- you announce many endpoints).
    if not forceloaded[ep] then
        for _, dy in ipairs({-R, R}) do
            for _, dz in ipairs({-R, R}) do
                for _, dx in ipairs({-R, R}) do
                    minetest.forceload_block(
                        {x = c.x + dx, y = c.y + dy, z = c.z + dz}, true)
                end
            end
        end
        minetest.forceload_block(c, true)
        forceloaded[ep] = true
    end
    if minetest.get_node(c).name == "ignore" then return end
    local minp = {x = c.x - R, y = c.y - R, z = c.z - R}
    local maxp = {x = c.x + R, y = c.y + R, z = c.z + R}
    local names, name_idx, nodes, p2s = {}, {}, {}, {}
    local i = 0
    for y = minp.y, maxp.y do
        for z = minp.z, maxp.z do
            for x = minp.x, maxp.x do
                i = i + 1
                local n = minetest.get_node({x = x, y = y, z = z})
                local ni = name_idx[n.name]
                if not ni then
                    names[#names + 1] = n.name
                    ni = #names
                    name_idx[n.name] = ni
                end
                nodes[i] = ni
                p2s[i] = n.param2
            end
        end
    end
    local body = minetest.write_json({names = names, nodes = nodes, param2 = p2s})
    local h = minetest.sha1(body)
    if spool_hash[ep] == h then return end
    spool_hash[ep] = h
    write_json(DIR .. "/spool/" .. world_id .. "__" .. ep .. ".json", {
        world = world_id, ep = ep, v = h, ts = now(),
        center = c, r = R,
        zone = {names = names, nodes = nodes, param2 = p2s},
    })
end

-- Reader: copy a remote endpoint's zone into my mirror slot.
local applied_v = {}
local mirror_ready = {}  -- epkey → mirror portal name

local function apply_spool(pairkey, mine, other, other_ep)
    local epkey = other.world .. "/" .. other.ep
    local rec = read_json(DIR .. "/spool/" .. other.world .. "__" .. other.ep .. ".json")
    if not rec or not rec.zone or applied_v[epkey] == rec.v then return end

    local base = slot_base(get_slot(pairkey))
    local c = rec.center
    local T = {x = base.x - c.x, y = base.y - c.y, z = base.z - c.z}
    local r = rec.r or R
    local minp = {x = base.x - r, y = base.y - r, z = base.z - r}
    local maxp = {x = base.x + r, y = base.y + r, z = base.z + r}

    local ids = {}
    for i, nm in ipairs(rec.zone.names) do
        local ok, cid = pcall(minetest.get_content_id, nm)
        ids[i] = ok and cid or minetest.get_content_id("yaportal_link:unknown")
    end

    local vm = minetest.get_voxel_manip(minp, maxp)
    local emin, emax = vm:get_emerged_area()
    local va = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
    local data = vm:get_data()
    local p2data = vm:get_param2_data()
    local i = 0
    for y = minp.y, maxp.y do
        for z = minp.z, maxp.z do
            for x = minp.x, maxp.x do
                i = i + 1
                local vi = va:index(x, y, z)
                data[vi] = ids[rec.zone.nodes[i]] or ids[1]
                p2data[vi] = rec.zone.param2[i] or 0
            end
        end
    end
    vm:set_data(data)
    vm:set_param2_data(p2data)
    vm:write_to_map(true)
    applied_v[epkey] = rec.v

    -- Mirror portal + one-way local link from my cross-world portal, so the
    -- RTT view of my portal shows the mirrored zone.
    local mname = "gun9_xmir_" .. other.world .. "_" .. other.ep
    if not mirror_ready[epkey] and other_ep.def then
        local d = other_ep.def
        if not yaportal.xworld.get_portal(mname) then
            yaportal.xworld.add_portal(mname, {
                cx = d.cx + T.x, cy = d.cy + T.y, cz = d.cz + T.z,
                axis = d.axis, ns = d.ns, w = d.w, h = d.h, rot = d.rot,
                ou = d.ou, ov = d.ov, node_name = d.node_name,
            })
        end
        local my_info = my_endpoints[mine.ep]
        if my_info then
            yaportal.xworld.set_link_local(my_info.portal, mname)
        end
        mirror_ready[epkey] = mname
    end
end

local sync_timer = 0
minetest.register_globalstep(function(dtime)
    sync_timer = sync_timer + dtime
    if sync_timer < S_SYNC then return end
    sync_timer = 0
    local eps = scan_endpoints()
    -- Server the client's passive second session should connect to. Only the
    -- registry knows which port the paired world currently listens on.
    local xtarget = nil
    for fn, rec in pairs(scan_pairs()) do
        local other, mine = pair_other_side(rec)
        if other and rec.status == "confirmed" and my_endpoints[mine.ep] then
            -- writer: my side of the pair
            write_spool(mine.ep, my_endpoints[mine.ep])
            -- reader: the other side, if online
            local other_ep = eps[other.world .. "/" .. other.ep]
            local slot = yaportal.xworld.engine_slot(my_endpoints[mine.ep].portal)
            if other_ep and other_ep.online then
                apply_spool(fn, mine, other, other_ep)
                -- Dual-client live view: my portal's RTT renders the real
                -- world B from the paired destination portal's frame.
                if slot and other_ep.def and core.set_portal_xworld_dest then
                    local g = yaportal.xworld.portal_geom(other_ep.def)
                    core.set_portal_xworld_dest(slot, g.pos, g.normal, g.up)
                end
                if not xtarget and other_ep.addr and other_ep.port then
                    xtarget = {addr = other_ep.addr, port = other_ep.port,
                        world = other.world}
                end
            elseif slot and core.clear_portal_xworld_dest then
                -- Other side offline: fall back to the mirror snapshot view.
                core.clear_portal_xworld_dest(slot)
            end
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
            "volta: entra in un altro mondo e usa 'Vai' dal pannello " ..
            "/worldportals per raggiungerlo.\n")
    end
end

-- Clean shutdown: retire our registry entries so the world can be reopened
-- immediately (the double-open guard only trips on a *live* heartbeat).
minetest.register_on_shutdown(function()
    remove_file(DIR .. "/worlds/" .. world_id .. ".json")
    for ep in pairs(my_endpoints) do
        remove_file(ep_file(world_id, ep))
    end
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
