-- yaportal/init.lua v2
-- Named portals: auto-detected frame sizes (1-8 nodes),
-- 8 frame materials, right-click GUI for name and link.

minetest.log("action", "[yaportal] Loading mod v2...")

-- Intercept register_abm for all mods that load AFTER this one.
-- Block ABMs whose node is inside a pocket dimension — no natural spawns.
-- Mobs spawned manually by players (eggs, commands) bypass the ABM hook.
local _pocket_spawn_blocker = nil  -- fn(pos)→bool, set after mod load
do
    local _orig_abm = minetest.register_abm
    minetest.register_abm = function(def)
        local orig_action = def.action
        def.action = function(pos, node, aoc, aocw)
            if _pocket_spawn_blocker and _pocket_spawn_blocker(pos) then return end
            return orig_action(pos, node, aoc, aocw)
        end
        return _orig_abm(def)
    end
end

local storage = minetest.get_mod_storage()

-- ── constants ────────────────────────────────────────────────────────────────

local MIN_W, MAX_W = 1, 8   -- portal inner width (nodes)
local MIN_H, MAX_H = 2, 8   -- portal inner height (nodes)
local UP = {x=0, y=1, z=0}
local TRIGGER_DEPTH = 0.05

-- ── global state ────────────────────────────────────────────────────────────

-- portals[name] = {cx,cy,cz,axis,ns,w,h,link,node_name}
local portals = {}
local _pocket_areas = {}  -- pname → {bx,by,bz}, pocket area cache for ABM blocker

-- 0-based C++ index for each portal (rebuilt by sync_portals, stable
-- across consecutive calls as long as names don't change, due to alphabetical sort)
local portal_index = {}  -- name → 0-based int

local anchors = {}              -- name → entity object
local player_states = {}        -- pname → {[portal_name] → {in_bounds,entered_from_front,triggered}}
local roll_targets      = {}    -- pname → target roll (radians), nil = no animation
-- Floor portal passthrough: tracks whether physics_override.floor_portal_cb_shift is active.
-- Set when player is in a floor-portal's bounds from above and not yet triggered;
-- cleared on trigger or exit.  Avoids redundant set_physics_override calls.
local floor_portal_shift_active = {}  -- pname → bool
-- Floor-portal fall-damage grace: get_us_time() stamp set while a player is
-- dropping through a floor portal (shift active) or just teleported out of one.
-- Any "fall" hpchange within the grace window is negated, so a single contact
-- tick that slips past the collision shift never deals damage.
local floor_portal_grace = {}  -- pname → us timestamp
local player_form_context = {}  -- pname → portal_name currently being configured
local player_mat_preview  = {}  -- pname → node_name selected in textlist (not yet applied)
local player_mat_filter   = {}  -- pname → filter string for material textlist
local open_portal_config  -- forward declared; assigned below

-- ── frame node ──────────────────────────────────────────────────────────────

local ALL_FRAME_NODES = {
    ["yaportal:frame"]         = true,
    ["yaportal:frame_blue"]    = true,
    ["yaportal:frame_orange"]  = true,
    ["yaportal:frame_green"]   = true,
    ["yaportal:portal_shell"]  = true,
}

-- ── anchor entity ───────────────────────────────────────────────────────────

minetest.register_entity("yaportal:anchor", {
    initial_properties = {
        -- is_visible MUST be true: the engine returns no selection box for
        -- invisible entities (getSelectionBox/addToScene bail on !is_visible),
        -- so an invisible anchor can never be right-clicked. We keep it
        -- unseen via zero size + a fully transparent texture instead.
        visual = "cube", visual_size = {x=0, y=0, z=0},
        textures = {
            "[fill:1x1:#00000000", "[fill:1x1:#00000000",
            "[fill:1x1:#00000000", "[fill:1x1:#00000000",
            "[fill:1x1:#00000000", "[fill:1x1:#00000000",
        },
        collisionbox = {0,0,0,0,0,0},
        selectionbox = {-0.5,-0.5,-0.5, 0.5,0.5,0.5},
        collide_with_objects = false, physical = false,
        is_visible = true, static_save = false,
        pointable = true,
    },
    on_activate = function(self) self.object:set_armor_groups({immortal=1}) end,
    on_rightclick = function(self, clicker)
        if self._portal_name and clicker and clicker:is_player()
           and not self._portal_name:match("^gun")
           and not self._portal_name:match("^pocket_")
           and not self._portal_name:match("^clock_") then
            open_portal_config(clicker, self._portal_name)
        end
    end,
})

local function update_anchor(name, pp)
    if anchors[name] then
        anchors[name]:remove()
        anchors[name] = nil
    end
    if pp then
        local w = pp.w or 2
        local h = pp.h or 3
        local pos
        if pp.axis == 0 then
            pos = {x=pp.cx+(w-1)/2, y=pp.cy+(h-1)/2, z=pp.cz}
        elseif pp.axis == 1 then
            pos = {x=pp.cx, y=pp.cy+(h-1)/2, z=pp.cz+(w-1)/2}
        else -- axis == 2
            pos = {x=pp.cx+(w-1)/2, y=pp.cy, z=pp.cz+(h-1)/2}
        end
        anchors[name] = minetest.add_entity(pos, "yaportal:anchor")
        if anchors[name] then
            local ent = anchors[name]:get_luaentity()
            if ent then ent._portal_name = name end
            -- Selectionbox covers interior + 1-node frame border (+0.1 margin so
            -- edge/angled clicks on border blocks still land) and protrudes ±0.65
            -- past frame block faces (±0.5) so the entity wins the raycast over
            -- the node behind it — needed once the frame is a foreign material
            -- whose node has no on_rightclick to open the config.
            local hw = w / 2 + 1.1
            local hh = h / 2 + 1.1
            local d  = 0.65
            local sb
            if pp.axis == 0 then
                sb = {-hw, -hh, -d, hw, hh, d}
            elseif pp.axis == 1 then
                sb = {-d, -hh, -hw, d, hh, hw}
            else -- axis == 2: flat in XZ
                local hz = h / 2 + 1.1
                sb = {-hw, -d, -hz, hw, d, hz}
            end
            -- Only configurable portals open a menu; gun/pocket anchors would
            -- otherwise be invisible inert click-blockers, so make them un-pointable.
            local pointable = not (name:match("^gun") or name:match("^pocket_")
                                   or name:match("^clock_"))
            anchors[name]:set_properties({selectionbox = sb, pointable = pointable})
        end
    end
end

-- ── geometry utils ─────────────────────────────────────────────────────────

local function node_at(x,y,z) return minetest.get_node({x=x,y=y,z=z}).name end

-- A node blocks the player's collision box when it is walkable.  Unknown nodes
-- (not yet loaded / unregistered) are treated as solid so we never embed the
-- player inside one.
local function node_is_walkable(name)
    if name == "ignore" then return true end
    local def = minetest.registered_nodes[name]
    return (def == nil) or def.walkable
end

-- Raise a feet position out of any solid block it sits inside, so the player
-- ends up standing on top instead of embedded.  Only the single node directly
-- under the feet centre is tested — sampling the box corners would push the
-- player up whenever a corner grazes adjacent geometry (e.g. the portal's own
-- frame), launching them too high.  Up-only; returns the new feet Y.  A node
-- whose top exactly meets the feet is support, not embedding, so a resting
-- position is left untouched.  Climbs through a solid fill via the iteration cap.
local function lift_feet_out_of_blocks(x, z, feet)
    for _ = 1, 16 do                      -- cap iterations (solid fill)
        local y_n = math.floor(feet + 0.5) -- node whose span contains the feet
        local nm = node_at(x, y_n, z)
        -- Thin glass is a 1/32 pane, not a block to embed in: exiting beside/into
        -- glass must not force a step-up. Treat it as non-embedding here.
        if not node_is_walkable(nm) or nm:match("^yaportal:thin_glass") then break end
        feet = y_n + 0.5                   -- rest on this node's top, recheck above
    end
    return feet
end

local function check_frame(cx, cy, cz, axis, frame_node, w, h)
    if axis == 0 then
        for dx = 0, w-1 do
            for dy = 0, h-1 do
                if node_at(cx+dx, cy+dy, cz) ~= "air" then return false end
            end
        end
        for dx = -1, w do
            if node_at(cx+dx, cy-1, cz) ~= frame_node then return false end
            if node_at(cx+dx, cy+h, cz) ~= frame_node then return false end
        end
        for dy = 0, h-1 do
            if node_at(cx-1, cy+dy, cz) ~= frame_node then return false end
            if node_at(cx+w, cy+dy, cz) ~= frame_node then return false end
        end
    elseif axis == 1 then
        for dz = 0, w-1 do
            for dy = 0, h-1 do
                if node_at(cx, cy+dy, cz+dz) ~= "air" then return false end
            end
        end
        for dz = -1, w do
            if node_at(cx, cy-1, cz+dz) ~= frame_node then return false end
            if node_at(cx, cy+h, cz+dz) ~= frame_node then return false end
        end
        for dy = 0, h-1 do
            if node_at(cx, cy+dy, cz-1) ~= frame_node then return false end
            if node_at(cx, cy+dy, cz+w) ~= frame_node then return false end
        end
    else -- axis == 2: horizontal ring in XZ at y=cy
        for dx = 0, w-1 do
            for dz = 0, h-1 do
                if node_at(cx+dx, cy, cz+dz) ~= "air" then return false end
            end
        end
        for dx = -1, w do
            if node_at(cx+dx, cy, cz-1) ~= frame_node then return false end
            if node_at(cx+dx, cy, cz+h) ~= frame_node then return false end
        end
        for dz = 0, h-1 do
            if node_at(cx-1, cy, cz+dz) ~= frame_node then return false end
            if node_at(cx+w, cy, cz+dz) ~= frame_node then return false end
        end
    end
    return true
end

-- pp.ou / pp.ov (wall portals only): half-node in-plane offsets of the opening
-- relative to the node grid (0 or 0.5) — horizontal (in-plane) and vertical.
-- The opening size stays w×h; the footprint gains one extra half-carved cell
-- row/column on the offset axis. Every consumer of the portal centre
-- (engine sync, bounds, teleport transforms) goes through inner_center, so
-- the offset is applied exactly here.
local function inner_center(pp)
    local w = pp.w or 2
    local h = pp.h or 3
    if pp.axis == 0 then
        return {x=pp.cx+(w-1)/2+(pp.ou or 0), y=pp.cy+(h-1)/2+(pp.ov or 0), z=pp.cz}
    elseif pp.axis == 1 then
        return {x=pp.cx, y=pp.cy+(h-1)/2+(pp.ov or 0), z=pp.cz+(w-1)/2+(pp.ou or 0)}
    else -- axis == 2: horizontal, opening in XZ plane
        return {x=pp.cx+(w-1)/2, y=pp.cy, z=pp.cz+(h-1)/2}
    end
end

-- Anchor entities are static_save=false and vanish when their mapblock unloads.
-- Recreate any that went missing so the config menu stays reachable (esp. after
-- the frame is converted to a foreign material with no node on_rightclick).
-- Skip gun/pocket portals: they don't open a menu and churn every shot.
local _anchor_reensure_t = 0
minetest.register_globalstep(function(dtime)
    _anchor_reensure_t = _anchor_reensure_t + dtime
    if _anchor_reensure_t < 2 then return end
    _anchor_reensure_t = 0
    for name, pp in pairs(portals) do
        if not name:match("^gun") and not name:match("^pocket_")
           and not name:match("^clock_") then
            local ent = anchors[name] and anchors[name]:get_luaentity()
            if not ent and minetest.get_node(inner_center(pp)).name ~= "ignore" then
                update_anchor(name, pp)
            end
        end
    end
end)

local function portal_normal(axis, ns)
    ns = ns or 1
    if axis == 0 then return {x=0,y=0,z=ns}
    elseif axis == 1 then return {x=ns,y=0,z=0}
    else return {x=0,y=ns,z=0} end
end

local function normal_sign(axis, player_pos, cx, cy, cz)
    if axis == 0 then
        return (player_pos.z >= cz) and 1 or -1
    elseif axis == 1 then
        return (player_pos.x >= cx) and 1 or -1
    else -- axis == 2
        return (player_pos.y >= cy) and 1 or -1
    end
end

local function in_portal_bounds(ppos, pp)
    local py = ppos.y + 0.5
    -- Type-2 block portals are free-standing (no surrounding frame to block a
    -- sideways approach), so the loose type-1 bounds below would let the player
    -- trigger the portal while merely standing beside it. Use tight bounds
    -- centred on the opening: laterally within the opening (+ small tol) and
    -- within depth tolerance on the normal axis. Alignment is what gates the
    -- trigger, so a side-walker stays out of bounds.
    if pp.kind == "block" then
        local c  = inner_center(pp)
        local w  = pp.w or 1
        local h  = pp.h or 1
        local hw = w / 2 + 0.1   -- in-plane horizontal half-extent
        local hv = h / 2 + 0.6   -- vertical half-extent (+ body tolerance)
        if pp.axis == 0 then       -- normal Z; in-plane X (w), Y (h)
            return math.abs(ppos.x - c.x) <= hw
               and math.abs(py - c.y)     <= hv
               and math.abs(ppos.z - c.z) <= 1.0
        elseif pp.axis == 1 then   -- normal X; in-plane Z (w), Y (h)
            return math.abs(ppos.z - c.z) <= hw
               and math.abs(py - c.y)     <= hv
               and math.abs(ppos.x - c.x) <= 1.0
        else                       -- normal Y; in-plane X (w), Z (h)
            return math.abs(ppos.x - c.x) <= hw
               and math.abs(ppos.z - c.z) <= (h / 2 + 0.1)
               and math.abs(py - c.y)     <= 2.0
        end
    end
    local M = 0.3
    local w = pp.w or 2
    local h = pp.h or 3
    if pp.axis == 0 then
        return py   >= pp.cy and py   < pp.cy + h
           and ppos.x >= pp.cx - M and ppos.x < pp.cx + w + M
           and math.abs(ppos.z - pp.cz) <= 1.0
    elseif pp.axis == 1 then
        return py   >= pp.cy and py   < pp.cy + h
           and ppos.z >= pp.cz - M and ppos.z < pp.cz + w + M
           and math.abs(ppos.x - pp.cx) <= 1.0
    else -- axis == 2: depth is Y, lateral extents in XZ
        -- Y tolerance 2.0 (was 1.0): camera is eye_h (~1.625) above feet, so at
        -- 50% frame penetration ppos is already 1.125 nodes from pp.cy → old check
        -- exited bounds too early, clearing the cam_hint and making the portal vanish.
        return ppos.x >= pp.cx - M and ppos.x < pp.cx + w + M
           and ppos.z >= pp.cz - M and ppos.z < pp.cz + h + M
           and math.abs(py - pp.cy) <= 2.0
    end
end

local function on_ns_side(ppos, pp)
    local ns = pp.ns or 1
    if pp.axis == 0 then
        return (ppos.z - pp.cz) * ns >= -TRIGGER_DEPTH
    elseif pp.axis == 1 then
        return (ppos.x - pp.cx) * ns >= -TRIGGER_DEPTH
    else -- axis == 2
        -- Floor portals (ns=1): player may walk in from a connected floor whose top face
        -- is 0.5 nodes below the portal plane → needs tolerance of at least 0.5.
        -- Ceiling portals (ns=-1) already trigger fine via cpos; keep tight tolerance.
        local tol = (ns == 1) and -1.0 or -TRIGGER_DEPTH
        return (ppos.y - pp.cy) * ns >= tol
    end
end

local function portal_depth(ppos, pp)
    local ns = pp.ns or 1
    if pp.axis == 0 then
        return (ppos.z - pp.cz) * ns
    elseif pp.axis == 1 then
        return (ppos.x - pp.cx) * ns
    else -- axis == 2
        return (ppos.y - pp.cy) * ns
    end
end

local function past_trigger(ppos, pp)
    return portal_depth(ppos, pp) < (0.5 - TRIGGER_DEPTH)
end

-- Lateral (XZ) test for a floor portal (axis==2, ns==1): is the player
-- horizontally over the opening hole?  Shrunk by 0.15 so standing on the
-- surrounding frame (or, for type-2 block portals, the block's solid rim) does
-- not count.  Since the opening is a hole, being laterally over it means the
-- player is dropping through — there is no solid ground to merely stand on.
local function over_floor_opening_xz(ppos, pp)
    if pp.axis ~= 2 or (pp.ns or 1) ~= 1 then return false end
    local c = inner_center(pp)
    local w = pp.w or 1
    local h = pp.h or 1
    return math.abs(ppos.x - c.x) <= (w / 2 - 0.15)
       and math.abs(ppos.z - c.z) <= (h / 2 - 0.15)
end

-- Rotate right/up vectors by rot×90° around the portal normal axis.
-- Each step: r' = u, u' = -r  (CW when viewed from outside normal).
local function apply_rot(r, u, rot)
    for _ = 1, (rot or 0) % 4 do
        r, u = u, {x=-r.x, y=-r.y, z=-r.z}
    end
    return r, u
end

local function portal_basis(pp)
    local ns  = pp.ns  or 1
    local rot = pp.rot or 0
    local n, r, u
    if pp.axis == 0 then
        n = {x=0,y=0,z=ns}
        r, u = apply_rot({x=-ns,y=0,z=0}, {x=0,y=1,z=0}, rot)
    elseif pp.axis == 1 then
        n = {x=ns,y=0,z=0}
        r, u = apply_rot({x=0,y=0,z=ns}, {x=0,y=1,z=0}, rot)
    else -- axis == 2: horizontal (floor/ceiling), normal = ±Y
        n = {x=0,y=ns,z=0}
        r, u = apply_rot({x=1,y=0,z=0}, {x=0,y=0,z=1}, rot)
    end
    return n, r, u
end

local function dot(a, b) return a.x*b.x + a.y*b.y + a.z*b.z end

local function portal_transform_pos(v, src_n, src_r, src_u, dst_n, dst_r, dst_u)
    local lr = dot(v, src_r)
    local lu = dot(v, src_u)
    local ln = dot(v, src_n)
    local dst_ln = -ln
    if dst_ln >= 0 then
        dst_ln = math.max(dst_ln, 0.02)
    else
        dst_ln = math.min(dst_ln, -0.02)
    end
    return {
        x = (-lr)*dst_r.x + lu*dst_u.x + dst_ln*dst_n.x,
        y = (-lr)*dst_r.y + lu*dst_u.y + dst_ln*dst_n.y,
        z = (-lr)*dst_r.z + lu*dst_u.z + dst_ln*dst_n.z,
    }
end

local function portal_transform_dir(v, src_n, src_r, src_u, dst_n, dst_r, dst_u)
    local lr = dot(v, src_r)
    local lu = dot(v, src_u)
    local ln = dot(v, src_n)
    return {
        x = (-lr)*dst_r.x + lu*dst_u.x + (-ln)*dst_n.x,
        y = (-lr)*dst_r.y + lu*dst_u.y + (-ln)*dst_n.y,
        z = (-lr)*dst_r.z + lu*dst_u.z + (-ln)*dst_n.z,
    }
end

local function block_in_frame(pos, pp)
    local w = pp.w or 2
    local h = pp.h or 3
    if pp.axis == 0 then
        return pos.z == pp.cz
           and pos.x >= pp.cx-1 and pos.x <= pp.cx+w
           and pos.y >= pp.cy-1 and pos.y <= pp.cy+h
    elseif pp.axis == 1 then
        return pos.x == pp.cx
           and pos.z >= pp.cz-1 and pos.z <= pp.cz+w
           and pos.y >= pp.cy-1 and pos.y <= pp.cy+h
    else -- axis == 2
        return pos.y == pp.cy
           and pos.x >= pp.cx-1 and pos.x <= pp.cx+w
           and pos.z >= pp.cz-1 and pos.z <= pp.cz+h
    end
end

local function get_frame_positions(pp)
    local pos_list = {}
    local w = pp.w or 2
    local h = pp.h or 3
    local cx, cy, cz = pp.cx, pp.cy, pp.cz
    if pp.axis == 0 then
        for dx = -1, w do
            pos_list[#pos_list+1] = {x=cx+dx, y=cy-1, z=cz}
            pos_list[#pos_list+1] = {x=cx+dx, y=cy+h, z=cz}
        end
        for dy = 0, h-1 do
            pos_list[#pos_list+1] = {x=cx-1, y=cy+dy, z=cz}
            pos_list[#pos_list+1] = {x=cx+w, y=cy+dy, z=cz}
        end
    elseif pp.axis == 1 then
        for dz = -1, w do
            pos_list[#pos_list+1] = {x=cx, y=cy-1, z=cz+dz}
            pos_list[#pos_list+1] = {x=cx, y=cy+h, z=cz+dz}
        end
        for dy = 0, h-1 do
            pos_list[#pos_list+1] = {x=cx, y=cy+dy, z=cz-1}
            pos_list[#pos_list+1] = {x=cx, y=cy+dy, z=cz+w}
        end
    else -- axis == 2: horizontal ring in XZ at y=cy
        for dx = -1, w do
            pos_list[#pos_list+1] = {x=cx+dx, y=cy, z=cz-1}
            pos_list[#pos_list+1] = {x=cx+dx, y=cy, z=cz+h}
        end
        for dz = 0, h-1 do
            pos_list[#pos_list+1] = {x=cx-1, y=cy, z=cz+dz}
            pos_list[#pos_list+1] = {x=cx+w, y=cy, z=cz+dz}
        end
    end
    return pos_list
end

local function find_portal_for_block(pos)
    for name, pp in pairs(portals) do
        if block_in_frame(pos, pp) then return name end
    end
    return nil
end

-- ── sync / persist ───────────────────────────────────────────────────────────

local function sorted_portal_names()
    local names = {}
    for name in pairs(portals) do names[#names+1] = name end
    table.sort(names)
    return names
end

-- Sky type indices registered once at startup. Indices are stable (deduped by name).
-- Original void look: VoxeLibre's End "noise" skybox (pockets sit in the End
-- Y-range, so that's the sky VoxeLibre itself applies inside them). Plain dark
-- fallback for games without the texture.
local SKY_VOID
if minetest.get_modpath("mcl_playerplus") then
    local t = "mcl_playerplus_end_sky.png"
    SKY_VOID = minetest.register_portal_sky_type("void", {
        type       = "skybox",
        base_color = "#000000",
        textures   = {t, t, t, t, t, t},
        clouds     = false,
        sunlit     = false,
        brightness = 0.0,
    })
else
    SKY_VOID = minetest.register_portal_sky_type("void", {
        type       = "plain",
        base_color = "#000A14",
        clouds     = false,
        sunlit     = false,
        brightness = 0.0,
    })
end
local SKY_OVERWORLD = minetest.register_portal_sky_type("overworld", {
    type       = "regular",
    clouds     = true,
    sunlit     = true,
    brightness = 1.0,
})

local function sync_portals()
    portal_index = {}
    local portal_list = {}
    local sorted = sorted_portal_names()
    for i, name in ipairs(sorted) do
        portal_index[name] = i - 1  -- 0-based C++ index
    end
    for i, name in ipairs(sorted) do
        local pp = portals[name]
        local link_idx = (pp.link and portal_index[pp.link]) or -1
        local _, _, portal_up = portal_basis(pp)
        local pw, ph = (pp.w or 2), (pp.h or 3)
        local rot = pp.rot or 0
        local hw = ((rot % 2) == 1) and ph / 2 or pw / 2
        local hh = ((rot % 2) == 1) and pw / 2 or ph / 2
        portal_list[i] = {
            pos    = inner_center(pp),
            normal = portal_normal(pp.axis, pp.ns),
            up     = portal_up,
            half_w = hw,
            half_h = hh,
            link   = link_idx,
        }
        -- Per-portal RTT sky: void for overworld→pocket, overworld for pocket→overworld.
        local slot = i - 1
        if pp.link and pp.link:match("^pocket_in_") then
            minetest.set_portal_sky(slot, SKY_VOID)
        elseif pp.link and pp.link:match("^pocket_out_") then
            minetest.set_portal_sky(slot, SKY_OVERWORLD)
        else
            minetest.clear_portal_sky(slot)
        end
    end
    minetest.set_portals(portal_list)
end

local function save_portals()
    storage:set_string("portals_v2", minetest.serialize(portals))
end


minetest.register_on_mods_loaded(function()
    local s = storage:get_string("portals_v2")
    if s and s ~= "" then
        portals = minetest.deserialize(s) or {}
    end
    -- Drop deprecated portal_gun2 (Surface) portals; their shells are cleaned by
    -- the LBM in the deprecated-gun2 section.
    local dropped = false
    for name in pairs(portals) do
        if name:match("^gun2_") then portals[name] = nil; dropped = true end
    end
    if dropped then save_portals() end
    sync_portals()
    -- Converted (foreign-material) frames persist: the swapped blocks are already
    -- saved in the map, register_on_dignode handles their deactivation, and the
    -- anchor entity opens the config for any material. No revert to yaportal:frame.
    minetest.after(0, function()
        for name, pp in pairs(portals) do
            update_anchor(name, pp)
        end
    end)
    -- Rebuild pocket area cache from storage
    local names_s = storage:get_string("pocket_players")
    if names_s ~= "" then
        local names = minetest.deserialize(names_s) or {}
        for _, pname in ipairs(names) do
            local s = storage:get_string("pocket_pos_" .. pname)
            if s ~= "" then
                local t = minetest.deserialize(s)
                if t then _pocket_areas[pname] = t end
            end
        end
    end
end)

-- ── portal name generator ───────────────────────────────────────────────────

local function new_portal_name()
    local n = (tonumber(storage:get_string("portal_counter")) or 0) + 1
    storage:set_string("portal_counter", tostring(n))
    return "portal_" .. n
end

-- ── frame detection ─────────────────────────────────────────────────────────

local function try_activate_near(pos, frame_node, placer)
    local px, py, pz = pos.x, pos.y, pos.z
    local ppos = placer and placer:get_pos() or pos

    for _, axis in ipairs({0, 1}) do
        -- Try largest frames first to avoid matching a sub-frame.
        for w = MAX_W, MIN_W, -1 do
            for h = MAX_H, MIN_H, -1 do
                local h_lo = (axis==0) and (px-w) or (pz-w)
                local h_hi = (axis==0) and (px+1) or (pz+1)
                for ch = h_lo, h_hi do
                    for cy = py-h, py+1 do
                        local cx = (axis==0) and ch or px
                        local cz = (axis==0) and pz or ch
                        if check_frame(cx, cy, cz, axis, frame_node, w, h) then
                            local ns = normal_sign(axis, ppos, cx, cy, cz)
                            -- Skip if already active
                            for _, ep in pairs(portals) do
                                if ep.cx==cx and ep.cy==cy and ep.cz==cz
                                   and ep.axis==axis and ep.ns==ns then
                                    return
                                end
                            end
                            local name = new_portal_name()
                            portals[name] = {
                                cx=cx, cy=cy, cz=cz,
                                axis=axis, ns=ns,
                                w=w, h=h,
                                node_name=frame_node,
                            }
                            save_portals()
                            sync_portals()
                            update_anchor(name, portals[name])
                            minetest.chat_send_all(
                                "[portal] '" .. name .. "' activated (" ..
                                w .. "x" .. h .. " nodes). Right-click to configure.")
                            return
                        end
                    end
                end
            end
        end
    end

    -- axis == 2: horizontal portals (floor/ceiling ring in XZ at y=py)
    for w = MAX_W, MIN_W, -1 do
        for h = MAX_H, MIN_H, -1 do
            for cx = px-w, px+1 do
                for cz = pz-h, pz+1 do
                    if check_frame(cx, py, cz, 2, frame_node, w, h) then
                        local ns = (ppos.y >= py) and 1 or -1
                        for _, ep in pairs(portals) do
                            if ep.cx==cx and ep.cy==py and ep.cz==cz
                               and ep.axis==2 and ep.ns==ns then
                                return
                            end
                        end
                        local name = new_portal_name()
                        portals[name] = {
                            cx=cx, cy=py, cz=cz,
                            axis=2, ns=ns,
                            w=w, h=h,
                            node_name=frame_node,
                        }
                        save_portals()
                        sync_portals()
                        update_anchor(name, portals[name])
                        minetest.chat_send_all(
                            "[portal] '" .. name .. "' activated (" ..
                            w .. "x" .. h .. " nodes, horizontal). Right-click to configure.")
                        return
                    end
                end
            end
        end
    end
end

-- Tear a portal down: drop the reverse link, forget it, persist, resync the
-- render list and remove its config anchor. Central path for every close
-- reason (dig, delete button, frame-integrity check).
local function close_portal(name, msg)
    local pp = portals[name]
    if not pp then return end
    if pp.link and portals[pp.link] then
        portals[pp.link].link = nil
    end
    portals[name] = nil
    save_portals()
    sync_portals()
    update_anchor(name, nil)
    if msg then minetest.chat_send_all(msg) end
end

local function deactivate_if_frame(pos)
    for name, pp in pairs(portals) do
        if block_in_frame(pos, pp) then
            close_portal(name, "[portal] '" .. name .. "' deactivated.")
            return
        end
    end
end

-- Frame-integrity check: every frame node of a config-built portal ("portal_N")
-- must still be its chosen material. Catches destruction the dig callbacks miss
-- (explosions, pistons, set_node by other mods). Unloaded nodes (get_node_or_nil
-- == nil) are treated as intact so portals in unloaded chunks aren't culled.
local function frame_intact(pp)
    local node_name = pp.node_name or "yaportal:frame"
    for _, fpos in ipairs(get_frame_positions(pp)) do
        local n = minetest.get_node_or_nil(fpos)
        if n and n.name ~= node_name then return false end
    end
    return true
end

-- Gun- and pocket-spawned portals manage their own block structures and use a
-- different geometry, so the frame check must skip them. Everything else is a
-- player-built frame portal (default "portal_N", or any name the user renamed it
-- to in the config menu).
local function is_user_frame_portal(name)
    return not (name:match("^gun_") or name:match("^gun%d_")
             or name:match("^pocket_") or name:match("^clock_"))
end

local frame_check_accum = 0
minetest.register_globalstep(function(dtime)
    frame_check_accum = frame_check_accum + dtime
    if frame_check_accum < 1.0 then return end
    frame_check_accum = 0
    for name, pp in pairs(portals) do
        if is_user_frame_portal(name) and not frame_intact(pp) then
            close_portal(name, "[portal] '" .. name .. "' closed (frame broken).")
        end
    end
end)

-- ── config GUI ──────────────────────────────────────────────────────────────

local function get_all_nodes()
    local result = {}
    for name, def in pairs(minetest.registered_nodes) do
        if name ~= "air" and name ~= "ignore"
           and def.description and def.description ~= ""
           and def.drawtype ~= "airlike"
           and def.drawtype ~= "liquid"
           and def.drawtype ~= "flowingliquid" then
            result[#result+1] = name
        end
    end
    table.sort(result)
    return result
end

open_portal_config = function(player, portal_name)
    local pp = portals[portal_name]
    if not pp then return end

    local pname = player:get_player_name()
    player_form_context[pname] = portal_name

    -- Build link dropdown: "(none)" + all other portal names
    local link_items = {"(none)"}
    local link_keys  = {}
    for _, name in ipairs(sorted_portal_names()) do
        if name ~= portal_name then
            link_items[#link_items+1] = minetest.formspec_escape(name)
            link_keys[#link_keys+1]   = name
        end
    end

    local selected = 1
    if pp.link then
        for i, k in ipairs(link_keys) do
            if k == pp.link then selected = i + 1; break end
        end
    end

    local axis_str = (pp.axis==0 and "Z") or (pp.axis==1 and "X") or "Y"
    local ns_dir   = (pp.ns or 1) > 0 and ("+" .. axis_str) or ("-" .. axis_str)
    local rot_deg  = ((pp.rot or 0) % 4) * 90
    local info = string.format("Size: %dx%d nodes | Axis: %s | Normal: %s | Rot: %d°",
        pp.w or "?", pp.h or "?", axis_str, ns_dir, rot_deg)

    -- Build filtered material textlist
    local filter      = (player_mat_filter[pname] or ""):lower()
    local all_nodes   = get_all_nodes()
    local nodes       = {}
    for _, name in ipairs(all_nodes) do
        if filter == "" then
            nodes[#nodes+1] = name
        else
            local def  = minetest.registered_nodes[name]
            local desc = (def and def.description and
                def.description:match("^([^\n]+)")) or name
            if name:lower():find(filter, 1, true)
               or desc:lower():find(filter, 1, true) then
                nodes[#nodes+1] = name
            end
        end
    end

    local mat_items    = {}
    local mat_selected = 1
    local current_node = pp.node_name or "yaportal:frame"
    local preview_node = player_mat_preview[pname] or current_node
    for i, name in ipairs(nodes) do
        local def        = minetest.registered_nodes[name]
        local short_desc = (def and def.description and
            def.description:match("^([^\n]+)")) or name
        mat_items[#mat_items+1] = minetest.formspec_escape(short_desc .. " (" .. name .. ")")
        if name == preview_node then mat_selected = i end
    end

    local preview_label = preview_node == current_node
        and "Preview:"
        or  "Preview (not applied):"

    local ns_label  = (pp.ns or 1) > 0 and ("Normal: +" .. axis_str) or ("Normal: -" .. axis_str)
    local rot_label = rot_deg .. "°"

    minetest.show_formspec(pname, "yaportal:config",
        "formspec_version[4]" ..
        "size[9,13.2]" ..
        "label[0.5,0.5;Configure Portal]" ..
        "label[0.5,1.1;" .. minetest.formspec_escape(info) .. "]" ..
        "field[0.5,2;8.5,0.8;portal_name;Portal name;" ..
            minetest.formspec_escape(portal_name) .. "]" ..
        "label[0.5,3.1;Link to:]" ..
        "dropdown[0.5,3.6;8.5,0.8;portal_link;" ..
            table.concat(link_items, ",") .. ";" .. selected .. "]" ..
        -- Orientation row
        "label[0.5,4.85;Orientation:]" ..
        "button[0.5,5.1;3,0.7;flip_ns;" .. minetest.formspec_escape(ns_label) .. " ↔]" ..
        "label[3.8,4.85;Rotation:]" ..
        "button[3.8,5.1;0.75,0.7;rot_ccw;◄]" ..
        "label[4.7,5.35;" .. minetest.formspec_escape(rot_label) .. "]" ..
        "button[5.5,5.1;0.75,0.7;rot_cw;►]" ..
        -- Material section shifted down by 1.5
        "label[0.5,6.3;Frame material:]" ..
        "label[4.5,6.3;" .. minetest.formspec_escape(preview_label) .. "]" ..
        "item_image[7.5,5.9;1.2,1.2;" .. preview_node .. "]" ..
        "field[0.5,6.8;5.5,0.7;mat_filter;Filter:;" ..
            minetest.formspec_escape(player_mat_filter[pname] or "") .. "]" ..
        "button[6.1,6.8;1.3,0.7;cerca_material;Search]" ..
        "textlist[0.5,7.6;8.5,3.5;material_list;" ..
            table.concat(mat_items, ",") .. ";" .. mat_selected .. "]" ..
        "button[0.5,11.6;4,0.8;apply_material;Apply Material]" ..
        "button[5,11.6;3.5,0.8;save;Save]" ..
        "button[0.5,12.2;8,0.8;delete_portal;Delete Portal]"
    )
end

minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= "yaportal:config" then return end

    local pname = player:get_player_name()
    local portal_name = player_form_context[pname]
    if not portal_name or not portals[portal_name] then return end

    -- Form closed
    if fields.quit then
        player_mat_preview[pname] = nil
        player_mat_filter[pname]  = nil
        return
    end

    -- "Delete Portal" button → tear the portal down and close the menu.
    -- Handled early so a stale textlist event can't shadow the press.
    if fields.delete_portal then
        close_portal(portal_name, "[portal] '" .. portal_name .. "' deleted.")
        player_form_context[pname] = nil
        player_mat_preview[pname]  = nil
        player_mat_filter[pname]   = nil
        minetest.close_formspec(pname, "yaportal:config")
        return
    end

    -- Always sync filter from current form state
    if fields.mat_filter ~= nil then
        player_mat_filter[pname] = fields.mat_filter
    end

    -- Orientation: flip normal direction
    if fields.flip_ns then
        local pp = portals[portal_name]
        if pp then
            pp.ns = -((pp.ns or 1))
            save_portals()
            sync_portals()
            open_portal_config(player, portal_name)
        end
        return
    end

    -- Orientation: rotate CW / CCW
    if fields.rot_cw or fields.rot_ccw then
        local pp = portals[portal_name]
        if pp then
            local delta = fields.rot_cw and 1 or -1
            pp.rot = ((pp.rot or 0) + delta) % 4
            save_portals()
            sync_portals()
            open_portal_config(player, portal_name)
        end
        return
    end

    -- Filter applied via button or Enter key
    if fields.cerca_material or fields.key_enter_field == "mat_filter" then
        open_portal_config(player, portal_name)
        return
    end

    -- Textlist selection changed → update preview and reopen (live preview)
    if fields.material_list and not fields.save and not fields.apply_material then
        local evt, idx_str = fields.material_list:match("^([A-Z]+):(%d+)$")
        if evt and evt ~= "INV" then
            local idx    = tonumber(idx_str)
            local filter = (player_mat_filter[pname] or ""):lower()
            local all    = get_all_nodes()
            local nodes  = {}
            for _, name in ipairs(all) do
                if filter == "" then
                    nodes[#nodes+1] = name
                else
                    local def  = minetest.registered_nodes[name]
                    local desc = (def and def.description and
                        def.description:match("^([^\n]+)")) or name
                    if name:lower():find(filter, 1, true)
                       or desc:lower():find(filter, 1, true) then
                        nodes[#nodes+1] = name
                    end
                end
            end
            local node = idx and nodes[idx]
            if node then
                player_mat_preview[pname] = node
                open_portal_config(player, portal_name)
            end
        end
        return
    end

    -- "Apply Material" button → swap frame blocks to selected node
    if fields.apply_material then
        local pp = portals[portal_name]
        if pp then
            local new_node = player_mat_preview[pname]
            if new_node and new_node ~= pp.node_name then
                local old_node = pp.node_name
                for _, fpos in ipairs(get_frame_positions(pp)) do
                    if minetest.get_node(fpos).name == old_node then
                        minetest.swap_node(fpos, {name = new_node})
                    end
                end
                pp.node_name = new_node
                save_portals()
                minetest.chat_send_player(pname,
                    "[portal] Material applied: " .. new_node)
            end
            open_portal_config(player, portal_name)
        end
        return
    end

    if not fields.save then return end

    -- "Save" button → rename + link

    -- Parse and sanitize new name
    local new_name = ((fields.portal_name or portal_name):match("^%s*(.-)%s*$"))
    new_name = new_name:gsub("[^%w%-_]", "_")
    if new_name == "" then new_name = portal_name end

    -- Parse link selection (dropdown returns the item string)
    local selected_str = fields.portal_link or "(none)"
    local link_name = nil
    if selected_str ~= "(none)" then
        if portals[selected_str] and selected_str ~= portal_name then
            link_name = selected_str
        end
    end

    -- Rename portal if needed (and name not already taken)
    if new_name ~= portal_name and portals[new_name] == nil then
        portals[new_name] = portals[portal_name]
        portals[portal_name] = nil
        for _, pp in pairs(portals) do
            if pp.link == portal_name then pp.link = new_name end
        end
        anchors[new_name] = anchors[portal_name]
        anchors[portal_name] = nil
        if anchors[new_name] then
            local ent = anchors[new_name]:get_luaentity()
            if ent then ent._portal_name = new_name end
        end
        player_mat_preview[new_name] = player_mat_preview[pname]
        player_form_context[pname] = new_name
        portal_name = new_name
    end

    local pp = portals[portal_name]
    if not pp then return end

    -- Remove old bidirectional back-link
    if pp.link and pp.link ~= link_name and portals[pp.link] then
        if portals[pp.link].link == portal_name then
            portals[pp.link].link = nil
        end
    end

    -- Set new link (bidirectional)
    pp.link = link_name
    if link_name and portals[link_name] then
        local lt = portals[link_name]
        if lt.link and lt.link ~= portal_name and portals[lt.link] then
            if portals[lt.link].link == link_name then
                portals[lt.link].link = nil
            end
        end
        lt.link = portal_name
    end

    save_portals()
    sync_portals()

    local msg = "[portal] '" .. portal_name .. "' "
    if link_name then
        msg = msg .. "linked to '" .. link_name .. "'"
    else
        msg = msg .. "unlinked"
    end
    minetest.chat_send_player(pname, msg)
end)

-- ── frame node registration ─────────────────────────────────────────────────

minetest.register_node("yaportal:frame", {
    description = "Portal Frame" ..
        "\n(rectangular frame, inner " .. MIN_W .. "x" .. MIN_H ..
        " to " .. MAX_W .. "x" .. MAX_H .. " nodes of air)",
    tiles = {"yaportal_blue.png"},
    groups = {cracky=3, oddly_breakable_by_hand=3},
    after_place_node = function(pos, placer)
        try_activate_near(pos, "yaportal:frame", placer)
    end,
    after_dig_node = function(pos)
        deactivate_if_frame(pos)
    end,
    on_rightclick = function(pos, node, player, itemstack, pointed_thing)
        local found = find_portal_for_block(pos)
        if found then
            open_portal_config(player, found)
        end
        return itemstack
    end,
})

-- Global callbacks so frames built from any game node activate/deactivate portals.
-- yaportal:frame already has after_place/after_dig; skip double-call.
local function is_known_frame_material(node_name)
    for _, pp in pairs(portals) do
        if pp.node_name == node_name then return true end
    end
    return false
end

minetest.register_on_dignode(function(pos, oldnode)
    if ALL_FRAME_NODES[oldnode.name] then return end
    if not is_known_frame_material(oldnode.name) then return end
    deactivate_if_frame(pos)
end)

-- ── teleportation ───────────────────────────────────────────────────────────

minetest.register_on_leaveplayer(function(player)
    local name = player:get_player_name()
    player_states[name] = nil
    floor_portal_shift_active[name] = nil
    floor_portal_grace[name] = nil
    player_form_context[name] = nil
    player_mat_preview[name] = nil
    player_mat_filter[name]  = nil
    -- gun portal cleanup is done by a second register_on_leaveplayer in the portal gun section
end)

-- Cross-world portals (yaportal_link): a portal with pp.xworld set and no
-- local link fires yaportal.xworld.handler on crossing instead of teleporting.
do
    local ns = rawget(_G, "yaportal") or {}
    ns.xworld = {
        handler = nil,  -- set by yaportal_link: function(pname, portal_name, pp)
        -- Attach/detach the cross-world destination of a named portal.
        set_link = function(portal_name, info)
            local pp = portals[portal_name]
            if not pp then return false end
            pp.xworld = info  -- {world=, ep=, addr=, port=, pos=, facing=} or nil
            return true
        end,
        get_portal = function(portal_name)
            return portals[portal_name]
        end,
        list_portals = function()
            local out = {}
            for name, pp in pairs(portals) do
                out[#out + 1] = {name = name, pos = inner_center(pp),
                    axis = pp.axis, linked = pp.link ~= nil,
                    xworld = pp.xworld, node_name = pp.node_name}
            end
            table.sort(out, function(a, b) return a.name < b.name end)
            return out
        end,
        -- Let other mods register a frame material and drive activation, so a
        -- dedicated cross-world frame builds a real portal through the normal
        -- yaportal path.
        register_frame_material = function(node_name)
            ALL_FRAME_NODES[node_name] = true
        end,
        activate_frame = function(pos, frame_node, placer)
            try_activate_near(pos, frame_node, placer)
        end,
        deactivate_frame = function(pos)
            deactivate_if_frame(pos)
        end,
        basis = function(pp) return portal_basis(pp) end,
        inner_center = function(pp) return inner_center(pp) end,
        -- Programmatic portal creation (mirror portals, tests).
        -- def = {cx,cy,cz,axis,ns,w,h,node_name[,link]}
        add_portal = function(name, def)
            if portals[name] then return false end
            portals[name] = def
            save_portals()
            sync_portals()
            update_anchor(name, def)
            return true
        end,
        close_portal = function(name)
            close_portal(name)
        end,
        -- Re-seed a player's trigger state at a position: any portal they are
        -- inside is marked pre-consumed, so being placed on/near an exit portal
        -- (arrival after a hop) doesn't immediately re-fire it.
        reset_trigger_state = function(pname, pos)
            local st = {}
            for portal_name, pp in pairs(portals) do
                if in_portal_bounds(pos, pp) then
                    st[portal_name] = {in_bounds = true,
                        entered_from_front = false, triggered = true}
                end
            end
            player_states[pname] = st
        end,
        -- One-way local link (RTT view of a cross-world portal into its
        -- mirror region). Does not touch the destination portal's link.
        set_link_local = function(name, dst_name)
            local pp = portals[name]
            if not pp then return false end
            pp.link = dst_name
            save_portals()
            sync_portals()
            return true
        end,
    }
    rawset(_G, "yaportal", ns)
end

-- A player who spawns already inside a portal (e.g. arriving right on the exit
-- portal, or logging back in on top of one) must NOT be teleported until they
-- step out and back in. Otherwise a cross-world exit portal re-fires on every
-- join, looping the player between servers. Mark such portals pre-consumed.
minetest.register_on_joinplayer(function(player)
    local pname = player:get_player_name()
    local ppos  = player:get_pos()
    local st = {}
    for portal_name, pp in pairs(portals) do
        if in_portal_bounds(ppos, pp) then
            st[portal_name] = {in_bounds = true, entered_from_front = false,
                triggered = true}
        end
    end
    player_states[pname] = st
end)

minetest.register_globalstep(function(dtime)
    for _, player in ipairs(minetest.get_connected_players()) do
        local pname = player:get_player_name()
        local ppos  = player:get_pos()
        -- Use camera (eye) position for depth-based checks so that the teleport
        -- triggers and exit position are referenced to what the player actually sees,
        -- not to their feet.  Bounds checks still use ppos to avoid rejecting
        -- the camera on tall-but-narrow vertical portals.
        local props = player:get_properties()
        local eye_h = (props and props.eye_height) or 1.625
        local cpos  = {x=ppos.x, y=ppos.y + eye_h, z=ppos.z}
        local vel   = player:get_velocity() or {x=0, y=0, z=0}

        if not player_states[pname] then player_states[pname] = {} end
        local state = player_states[pname]

        -- Remove stale state entries for portals that no longer exist
        for sname in pairs(state) do
            if not portals[sname] then state[sname] = nil end
        end

        local teleport_src, teleport_dst = nil, nil

        for portal_name, pp in pairs(portals) do
            if not state[portal_name] then state[portal_name] = {} end
            local s        = state[portal_name]
            local dst_name = pp.link
            local dst      = dst_name and portals[dst_name]
            -- Mirror portals (gun9_xmir_*) exist only to feed the RTT view of a
            -- cross-world portal; they must NEVER be a local teleport target,
            -- or an offline cross-world portal would drop the player into the
            -- hidden mirror region.
            local dst_is_mirror = dst_name and dst_name:match("^gun9_xmir_") ~= nil

            if in_portal_bounds(ppos, pp) then
                local just_entered = not s.in_bounds
                if just_entered then
                    s.in_bounds          = true
                    -- A fast faller's first in-bounds sample can already be below the
                    -- on_ns_side floor tolerance (-1.0) even though they dropped in
                    -- from the top.  Treat "descending and laterally over the hole" as
                    -- front entry too, so the teleport/shift path isn't gated off.
                    s.entered_from_front = on_ns_side(ppos, pp)
                        or (pp.axis == 2 and (pp.ns or 1) == 1
                            and vel.y < -0.1 and over_floor_opening_xz(ppos, pp))
                    s.triggered          = false
                end

                local border_entry = just_entered and portal_depth(cpos, pp) < (0.5 - TRIGGER_DEPTH)
                if s.entered_from_front and not s.triggered
                   and pp.xworld and not teleport_src
                   and (past_trigger(cpos, pp) or border_entry)
                then
                    -- Cross-world portal: any local link is only the mirror
                    -- region shown by the RTT view; the actual crossing is a
                    -- server hop handled by yaportal_link (handoff + redirect).
                    s.triggered = true
                    local ns = rawget(_G, "yaportal")
                    local h = ns and ns.xworld and ns.xworld.handler
                    if h then h(pname, portal_name, pp) end
                elseif s.entered_from_front and not s.triggered and dst
                   and not dst_is_mirror
                   and not teleport_src
                   and (past_trigger(cpos, pp) or border_entry)
                then
                    s.triggered  = true
                    teleport_src = portal_name
                    teleport_dst = dst_name
                elseif s.entered_from_front and not s.triggered
                   and dst_is_mirror and not pp.xworld
                   and (past_trigger(cpos, pp) or border_entry)
                then
                    -- Cross-world portal whose remote side is offline: don't
                    -- teleport anywhere, just tell the player.
                    s.triggered = true
                    minetest.chat_send_player(pname, minetest.colorize("#FFAA55",
                        "[portale] destinazione intermondo non disponibile (mondo remoto offline)."))
                end
            else
                if s.in_bounds then
                    s.in_bounds  = false
                    s.triggered  = false
                end
            end
        end

        -- Floor portal passthrough: while over a floor portal's hole and not yet
        -- triggered, raise the collision-box bottom so the player sinks past the
        -- blocking node below (type-1: the block under the frame; type-2: the portal
        -- block's own solid bottom panel), letting cpos reach past_trigger naturally.
        --
        -- Gate on a one-tick-ahead predicted feet Y (ppos.y + vy·dtime), NOT on raw
        -- velocity: a fast faller whose box-shift is overrun and arrested on the block
        -- has vy≈0, so a velocity gate would clear the shift and leave them stuck on
        -- the block forever (never descending to trigger depth).  The predicted-Y gate
        -- both engages early for fast falls and keeps re-engaging to un-stick an
        -- arrested player.  Since the opening is a hole, being laterally over it always
        -- means dropping through, so no extra "is falling" guard is needed.
        local look_y = ppos.y + math.min(0, vel.y) * dtime  -- predicted next-tick feet Y
        local need_shift = false
        local shift_cy = nil
        for portal_name, pp in pairs(portals) do
            local s = state[portal_name]
            if pp.axis == 2 and (pp.ns or 1) == 1
               and pp.link and portals[pp.link]   -- only a linked portal lets you drop through
               and s and s.entered_from_front and not s.triggered
               and over_floor_opening_xz(ppos, pp)
               and ppos.y >= pp.cy - 1.3
               and look_y <= pp.cy + 0.6 then
                need_shift = true
                shift_cy = pp.cy
                break
            end
        end
        if need_shift then
            -- Recompute every frame: shift must push box bottom above the obstruction
            -- top (pp.cy + 0.5 is the frame/block-bottom plane).  Capped at 1.7 (just
            -- under player height 1.77) to keep the box valid.  Uses the same predicted
            -- look_y so the pin tracks where the feet WILL be next physics step
            -- (set_physics_override only takes effect next step).
            local shift = math.min(1.7, math.max(0, shift_cy + 0.5 - look_y + 0.1))
            local prev  = floor_portal_shift_active[pname]
            if prev ~= shift then
                floor_portal_shift_active[pname] = shift
                player:set_physics_override({floor_portal_cb_shift = shift})
            end
            floor_portal_grace[pname] = minetest.get_us_time()
        elseif floor_portal_shift_active[pname] then
            floor_portal_shift_active[pname] = nil
            player:set_physics_override({floor_portal_cb_shift = 0})
        end

        if teleport_src and teleport_dst then
            local src = portals[teleport_src]
            local dst = portals[teleport_dst]

            -- Extend the fall-damage grace through a floor-portal exit so the
            -- arrival (and any block grazed on the way out) deals no fall damage.
            if src.axis == 2 and (src.ns or 1) == 1 then
                floor_portal_grace[pname] = minetest.get_us_time()
            end

            local src_n, src_r, src_u = portal_basis(src)
            local dst_n, dst_r, dst_u = portal_basis(dst)
            -- Cancel lateral mirror when either portal is horizontal (horizontal portals use
            -- rotation semantics, not mirror semantics). vert→vert keeps the mirror; all
            -- cases involving a horizontal portal (horiz→vert, vert→horiz, horiz→horiz) don't.
            local eff_src_r = (src.axis == 2 or dst.axis == 2)
                and {x=-src_r.x, y=-src_r.y, z=-src_r.z} or src_r
            local src_c = inner_center(src)
            local dst_c = inner_center(dst)

            -- Clear floor-portal shift before teleport so exit position uses real eye_h.
            if floor_portal_shift_active[pname] then
                floor_portal_shift_active[pname] = nil
                player:set_physics_override({floor_portal_cb_shift = 0})
            end

            -- Transform camera position; convert back to feet for portal_teleport.
            local eff_eye_h = eye_h
            local rel     = {x=cpos.x-src_c.x, y=cpos.y-src_c.y, z=cpos.z-src_c.z}
            local new_off = portal_transform_pos(rel, src_n, eff_src_r, src_u, dst_n, dst_r, dst_u)
            -- Exit at same offset past dst outer face as trigger offset past src outer face
            local cur_n = dot(new_off, dst_n)
            local adj   = (0.5 + TRIGGER_DEPTH) - cur_n
            new_off.x   = new_off.x + adj * dst_n.x
            new_off.y   = new_off.y + adj * dst_n.y
            new_off.z   = new_off.z + adj * dst_n.z
            -- new_off is the camera exit position relative to dst_c; feet = camera - eye_h·Y.
            local new_pos = {
                x = dst_c.x + new_off.x,
                y = dst_c.y + new_off.y - eff_eye_h,
                z = dst_c.z + new_off.z,
            }

            -- Step-up on exit: if the destination feet land inside a solid block,
            -- raise the player so they stand on top of it rather than embedded.
            -- Box bottom = feet + collisionbox min-Y (usually 0 for players).
            local warp_off = nil   -- camera warp offset (world nodes), nil = none
            do
                local cb     = props and props.collisionbox
                local boxbot = cb and cb[2] or 0.0
                local bottom = new_pos.y + boxbot
                local lifted = lift_feet_out_of_blocks(new_pos.x, new_pos.z, bottom)
                if lifted > bottom + 1e-3 then
                    local dy  = lifted - bottom
                    new_pos.y = new_pos.y + dy
                    -- Camera starts at the un-lifted (seamless) exit and rises to
                    -- the lifted standing position over the warp; offset points
                    -- from the actual exit back down to the seamless view.
                    warp_off  = {x = 0, y = -dy, z = 0}
                end
            end

            local vel      = player:get_velocity() or {x=0,y=0,z=0}
            local new_vel  = portal_transform_dir(vel,  src_n, eff_src_r, src_u, dst_n, dst_r, dst_u)
            local look     = player:get_look_dir()
            local new_look = portal_transform_dir(look, src_n, eff_src_r, src_u, dst_n, dst_r, dst_u)
            local xz_len   = math.sqrt(new_look.x^2 + new_look.z^2)
            local new_yaw
            if xz_len < 0.01 then
                -- near-vertical new_look: derive right from original look's horizontal projection,
                -- or from get_look_yaw() when pitch is exactly ±90°
                local olen = math.sqrt(look.x*look.x + look.z*look.z)
                local pr
                if olen > 0.001 then
                    pr = {x=look.z/olen, y=0, z=-look.x/olen}
                else
                    local ly = player:get_look_yaw()  -- (m_rotation.Y + 90°)*DEGTORAD
                    pr = {x=math.sin(ly), y=0, z=-math.cos(ly)}
                end
                local rt = portal_transform_dir(pr, src_n, eff_src_r, src_u, dst_n, dst_r, dst_u)
                new_yaw = math.atan2(rt.z, rt.x)
            else
                new_yaw = math.atan2(-new_look.x, new_look.z)
            end
            local new_pitch = -math.asin(math.max(-1, math.min(1, new_look.y)))

            -- Roll: signed angle from world-Y's camera projection to new world-Y's camera
            -- projection.  Non-zero for any traversal where the portal bases differ
            -- (cross-axis vert↔horiz, or same-axis portals with different rot values).
            -- Portal-style animation: teleport sets roll=new_roll, globalstep recovers to 0.
            local new_roll = 0
            do
                local wup = {x=0, y=1, z=0}
                local nwu = portal_transform_dir(wup, src_n, eff_src_r, src_u, dst_n, dst_r, dst_u)
                -- Project both onto the plane perpendicular to new_look
                local function vproj(v, n)
                    local d = v.x*n.x + v.y*n.y + v.z*n.z
                    return {x=v.x-d*n.x, y=v.y-d*n.y, z=v.z-d*n.z}
                end
                local cu0 = vproj(wup, new_look)   -- roll=0 reference "up"
                local sup  = vproj(nwu, new_look)   -- actual "up" from portal transform
                local l0 = cu0.x^2+cu0.y^2+cu0.z^2
                local l1 = sup.x^2+sup.y^2+sup.z^2
                if l0 > 1e-6 and l1 > 1e-6 then
                    local s0 = 1/math.sqrt(l0)
                    local s1 = 1/math.sqrt(l1)
                    cu0 = {x=cu0.x*s0, y=cu0.y*s0, z=cu0.z*s0}
                    sup  = {x=sup.x*s1,  y=sup.y*s1,  z=sup.z*s1}
                    local d = math.max(-1, math.min(1,
                        cu0.x*sup.x + cu0.y*sup.y + cu0.z*sup.z))
                    -- Sign: cross(cu0,sup)·new_look
                    local cx = cu0.y*sup.z - cu0.z*sup.y
                    local cy = cu0.z*sup.x - cu0.x*sup.z
                    local cz = cu0.x*sup.y - cu0.y*sup.x
                    local sgn = cx*new_look.x + cy*new_look.y + cz*new_look.z
                    new_roll = (sgn >= 0 and 1 or -1) * math.acos(d)
                end
            end  -- do

            local dst_idx = portal_index[teleport_dst]
            if dst_idx then
                -- new_pos is feet; add eye_h to get camera position for the hint.
                -- (eye_h already computed above for cpos)
                minetest.set_portal_cam_hint(dst_idx, {
                    x=new_pos.x, y=new_pos.y + eff_eye_h, z=new_pos.z
                })
            end

            -- sky_sunlit hint forces sunlight_seen on the client so the sky snaps
            -- instantly to the destination state instead of lerping over ~300 frames.
            -- void→overworld: true, releases when bg_sunlit=true.
            -- overworld→void: true as well — the void sky is a skybox (End noise)
            -- and Sky::render() draws skyboxes only when sunlight_seen. bg_sunlit
            -- stays false in the void, so the override intentionally never
            -- releases and the skybox stays visible for the whole stay.
            -- Only override sky for cross-dimension teleports (pocket portals).
            -- For same-dimension teleports the sky type doesn't change: sending
            -- sky_slot with sky_sunlit=nil causes sky_sunlit_override_value=false
            -- for 3 frames → dome not rendered → black sky flash.
            local sky_sunlit
            local src_slot
            if teleport_src:match("^pocket_in_") then
                sky_sunlit = true   -- void→overworld
                src_slot = portal_index[teleport_src]
            elseif teleport_src:match("^pocket_out_") then
                -- true: Sky::render() draws the skybox (End noise) only when
                -- sunlight_seen. bg_sunlit stays false in the void so the
                -- override never releases → skybox stays visible while inside.
                sky_sunlit = true   -- overworld→void
                src_slot = portal_index[teleport_src]
            end
            -- warp_off is set only when the exit step-up forced the player up to
            -- avoid clipping into blocks. The client then eases the camera from
            -- the seamless (un-lifted) exit up to the standing position. Rotation
            -- is left to the normal roll-settling animation below.
            player:portal_teleport(new_pos, new_yaw, {
                x=new_vel.x-vel.x,
                y=new_vel.y-vel.y,
                z=new_vel.z-vel.z,
            }, {
                sky_sunlit = sky_sunlit,
                sky_slot   = src_slot,
                pitch      = new_pitch,
                roll       = new_roll,  -- instant disorientation; roll_targets recovers to 0
                warp       = warp_off,
            })
            -- Portal-style smooth recovery: animate new_roll → 0 (upright).
            -- Controls are briefly inverted only while roll is large; recover in ~|new_roll|/π s.
            local pname = player:get_player_name()
            roll_targets[pname] = math.abs(new_roll) > 0.01 and 0 or nil

            -- Reset src; mark dst as entered from back to prevent bounce
            state[teleport_src] = {in_bounds=false}
            state[teleport_dst] = {
                in_bounds          = in_portal_bounds(new_pos, dst),
                entered_from_front = false,
                triggered          = true,
            }
            -- The cam hint for dst was set above for a seamless pre-render frame.
            -- Clear it now so the live camera takes over on the next render frame.
            -- (state[teleport_src] = {in_bounds=false} bypasses the normal leave-bounds
            -- clearing that would have done this via the source portal's leave handler.)
            if dst_idx then
                minetest.clear_portal_cam_hint(dst_idx)
            end
        end
    end
end)

-- ── entity teleportation ────────────────────────────────────────────────────

local entity_states  = {}  -- tostring(obj) → {[portal_name] → {in_bounds,entered_from_front,triggered,cooldown}}
local entity_cleanup_timer = 0

local function should_teleport_entity(obj)
    local ent = obj:get_luaentity()
    if not ent then return false end
    if ent.name == "yaportal:anchor" then return false end
    if ent._carrier then return false end  -- carried cube follows its carrier, never the portal
    local def = minetest.registered_entities[ent.name]
    if not def then return false end
    if def._portal_exempt then return false end
    return true
end

local function transform_entity_rotation(rot, src_n, src_r, src_u, dst_n, dst_r, dst_u)
    local sy, cy_ = math.sin(rot.y), math.cos(rot.y)
    local sp, cp  = math.sin(rot.x), math.cos(rot.x)
    local fwd = {x = -sy*cp, y = sp, z = -cy_*cp}
    local new_fwd = portal_transform_dir(fwd, src_n, src_r, src_u, dst_n, dst_r, dst_u)
    local xz_len = math.sqrt(new_fwd.x^2 + new_fwd.z^2)
    local new_yaw, new_pitch
    if xz_len < 0.01 then
        local er = {x=math.cos(rot.y), y=0, z=-math.sin(rot.y)}
        local rt = portal_transform_dir(er, src_n, src_r, src_u, dst_n, dst_r, dst_u)
        new_yaw = math.atan2(-rt.z, rt.x)
    else
        new_yaw = math.atan2(-new_fwd.x, -new_fwd.z)
    end
    new_pitch = math.asin(math.max(-1, math.min(1, new_fwd.y)))
    return {x = new_pitch, y = new_yaw, z = rot.z}
end

minetest.register_globalstep(function(dtime)
    -- Periodic stale-entry cleanup (~every 5s)
    entity_cleanup_timer = entity_cleanup_timer + dtime
    if entity_cleanup_timer >= 5 then
        entity_cleanup_timer = 0
        for eid, edata in pairs(entity_states) do
            -- entity_states are keyed by tostring(obj); check if obj is still alive
            -- by looking for any still-valid portal state with in_bounds=true.
            -- Simpler: let them accumulate (harmless) — entries reset to in_bounds=false
            -- naturally when an entity leaves bounds or on next portal scan if not nearby.
            -- Only prune completely empty state tables to keep memory use bounded.
            local has_entry = false
            for _ in pairs(edata) do has_entry = true; break end
            if not has_entry then entity_states[eid] = nil end
        end
    end

    for portal_name, pp in pairs(portals) do
        if not pp.link or not portals[pp.link] then
            -- skip unlinked portals
        else
            local center = inner_center(pp)
            local radius = math.max((pp.w or 2), (pp.h or 3)) + 2
            local nearby = minetest.get_objects_inside_radius(center, radius)
            for _, obj in ipairs(nearby) do
                if not obj:is_player() and should_teleport_entity(obj) then
                    local eid = tostring(obj)
                    if not entity_states[eid] then entity_states[eid] = {} end
                    local state = entity_states[eid]
                    for sname in pairs(state) do
                        if not portals[sname] then state[sname] = nil end
                    end

                    if not state[portal_name] then state[portal_name] = {} end
                    local s = state[portal_name]

                    if s.cooldown and s.cooldown > 0 then
                        s.cooldown = s.cooldown - dtime
                    else
                        local epos = obj:get_pos()
                        if epos then
                            local dst_name = pp.link
                            local dst = portals[dst_name]

                            if in_portal_bounds(epos, pp) then
                                local just_entered = not s.in_bounds
                                if just_entered then
                                    s.in_bounds          = true
                                    s.entered_from_front = on_ns_side(epos, pp)
                                    s.triggered          = false
                                end
                                local border_entry = just_entered and portal_depth(epos, pp) < (0.5 - TRIGGER_DEPTH)
                                if s.entered_from_front and not s.triggered
                                   and (past_trigger(epos, pp) or border_entry)
                                then
                                    s.triggered = true
                                    local src_n, src_r, src_u = portal_basis(pp)
                                    local dst_n, dst_r, dst_u = portal_basis(dst)
                                    local eff_src_r = (pp.axis == 2 or dst.axis == 2)
                                        and {x=-src_r.x, y=-src_r.y, z=-src_r.z} or src_r
                                    local src_c = inner_center(pp)
                                    local dst_c = inner_center(dst)

                                    local rel     = {x=epos.x-src_c.x, y=epos.y-src_c.y, z=epos.z-src_c.z}
                                    local new_off = portal_transform_pos(rel, src_n, eff_src_r, src_u, dst_n, dst_r, dst_u)
                                    local cur_n = dot(new_off, dst_n)
                                    local adj   = (0.5 + TRIGGER_DEPTH) - cur_n
                                    new_off.x = new_off.x + adj * dst_n.x
                                    new_off.y = new_off.y + adj * dst_n.y
                                    new_off.z = new_off.z + adj * dst_n.z
                                    local new_pos = {
                                        x = dst_c.x + new_off.x,
                                        y = dst_c.y + new_off.y,
                                        z = dst_c.z + new_off.z,
                                    }

                                    local vel = obj:get_velocity() or {x=0,y=0,z=0}
                                    local new_vel = portal_transform_dir(vel, src_n, eff_src_r, src_u, dst_n, dst_r, dst_u)

                                    local rot = obj:get_rotation() or {x=0,y=0,z=0}
                                    local new_rot = transform_entity_rotation(rot, src_n, eff_src_r, src_u, dst_n, dst_r, dst_u)

                                    obj:set_pos(new_pos)
                                    obj:set_velocity(new_vel)
                                    obj:set_rotation(new_rot)

                                    entity_states[eid][portal_name] = {in_bounds=false}
                                    entity_states[eid][dst_name] = {
                                        in_bounds          = in_portal_bounds(new_pos, dst),
                                        entered_from_front = false,
                                        triggered          = true,
                                        cooldown           = 1.0,
                                    }
                                end
                            else
                                if s.in_bounds then
                                    s.in_bounds  = false
                                    s.triggered  = false
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end)

-- ── portal gun ────────────────────────────────────────────────────────────────

local GUN_W, GUN_H = 2, 3  -- interior 2×3 → outer frame 4×5

local function portal_gun_can_place(cx, cy, cz, axis, w, h)
    if axis == 0 then
        for dx = 0, w-1 do
            for dy = 0, h-1 do
                if node_at(cx+dx, cy+dy, cz) ~= "air" then return false end
            end
        end
        for dx = -1, w do
            if node_at(cx+dx, cy-1, cz) ~= "air" then return false end
            if node_at(cx+dx, cy+h,  cz) ~= "air" then return false end
        end
        for dy = 0, h-1 do
            if node_at(cx-1, cy+dy, cz) ~= "air" then return false end
            if node_at(cx+w, cy+dy, cz) ~= "air" then return false end
        end
    else
        for dz = 0, w-1 do
            for dy = 0, h-1 do
                if node_at(cx, cy+dy, cz+dz) ~= "air" then return false end
            end
        end
        for dz = -1, w do
            if node_at(cx, cy-1, cz+dz) ~= "air" then return false end
            if node_at(cx, cy+h,  cz+dz) ~= "air" then return false end
        end
        for dy = 0, h-1 do
            if node_at(cx, cy+dy, cz-1) ~= "air" then return false end
            if node_at(cx, cy+dy, cz+w) ~= "air" then return false end
        end
    end
    return true
end

-- Tries horizontal positions near ideal_h, constrained so the frame covers ref_h.
-- Valid range: [ref_h-2, ref_h+1] (frame width 4: border at h-1 through h+w).
-- Returns the first valid value ordered by distance from ideal_h, or nil.
local function portal_gun_find_h(ideal_h, ref_h, test_fn)
    local candidates = {}
    for v = ref_h - 2, ref_h + 1 do
        candidates[#candidates+1] = {val=v, dist=math.abs(v - ideal_h)}
    end
    table.sort(candidates, function(a, b) return a.dist < b.dist end)
    for _, c in ipairs(candidates) do
        if test_fn(c.val) then return c.val end
    end
    return nil
end

local function portal_gun_place_frame(cx, cy, cz, axis, w, h, node_name)
    if axis == 0 then
        for dx = -1, w do
            minetest.set_node({x=cx+dx, y=cy-1, z=cz}, {name=node_name})
            minetest.set_node({x=cx+dx, y=cy+h,  z=cz}, {name=node_name})
        end
        for dy = 0, h-1 do
            minetest.set_node({x=cx-1, y=cy+dy, z=cz}, {name=node_name})
            minetest.set_node({x=cx+w, y=cy+dy, z=cz}, {name=node_name})
        end
    else
        for dz = -1, w do
            minetest.set_node({x=cx, y=cy-1, z=cz+dz}, {name=node_name})
            minetest.set_node({x=cx, y=cy+h,  z=cz+dz}, {name=node_name})
        end
        for dy = 0, h-1 do
            minetest.set_node({x=cx, y=cy+dy, z=cz-1}, {name=node_name})
            minetest.set_node({x=cx, y=cy+dy, z=cz+w}, {name=node_name})
        end
    end
end

-- Removes a player's gun portal of one color. Does NOT call save/sync — caller must.
local function portal_gun_remove(pname, color)
    local portal_name = "gun_" .. color .. "_" .. pname
    local pp = portals[portal_name]
    if not pp then return end
    for _, fpos in ipairs(get_frame_positions(pp)) do
        if minetest.get_node(fpos).name == pp.node_name then
            minetest.remove_node(fpos)
        end
    end
    if pp.link and portals[pp.link] then
        portals[pp.link].link = nil
    end
    portals[portal_name] = nil
    update_anchor(portal_name, nil)
end

local function portal_gun_shoot(player, pointed_thing, color)
    if pointed_thing.type ~= "node" then return end
    local pname = player:get_player_name()
    local under = pointed_thing.under
    local above = pointed_thing.above
    local dz    = above.z - under.z
    local dx    = above.x - under.x
    local dy    = above.y - under.y
    local ip    = pointed_thing.intersection_point
        or {x=above.x, y=above.y, z=above.z}

    local axis, ns, cx, cy, cz

    if dy ~= 0 then
        -- Horizontal surface hit.
        if dy < 0 then
            minetest.chat_send_player(pname,
                "[portal] Cannot place portals on ceilings.")
            return
        end
        -- Floor: create a vertical portal standing on the floor.
        -- Orientation comes from the player's horizontal look direction.
        -- cy = above.y + 1 so the bottom frame row is at above.y (air), not the floor block.
        local look = player:get_look_dir()
        cy = above.y + 1
        if math.abs(look.z) >= math.abs(look.x) then
            axis = 0
            ns   = (look.z < 0) and 1 or -1
            cz   = above.z
            cx   = portal_gun_find_h(math.floor(ip.x), above.x, function(try_cx)
                return portal_gun_can_place(try_cx, cy, cz, axis, GUN_W, GUN_H)
            end)
        else
            axis = 1
            ns   = (look.x < 0) and 1 or -1
            cx   = above.x
            cz   = portal_gun_find_h(math.floor(ip.z), above.z, function(try_cz)
                return portal_gun_can_place(cx, cy, try_cz, axis, GUN_W, GUN_H)
            end)
        end
    elseif dz ~= 0 then
        -- Z-facing wall.
        axis = 0; ns = dz
        cz   = above.z
        cy   = math.floor(ip.y - 0.5)
        cx   = portal_gun_find_h(math.floor(ip.x), above.x, function(try_cx)
            return portal_gun_can_place(try_cx, cy, cz, axis, GUN_W, GUN_H)
        end)
    else
        -- X-facing wall.
        axis = 1; ns = dx
        cx   = above.x
        cy   = math.floor(ip.y - 0.5)
        cz   = portal_gun_find_h(math.floor(ip.z), above.z, function(try_cz)
            return portal_gun_can_place(cx, cy, try_cz, axis, GUN_W, GUN_H)
        end)
    end

    if not cx or not cz then
        minetest.chat_send_player(pname,
            "[portal] Not enough space for the portal.")
        return
    end

    local frame_node  = "yaportal:frame_" .. color
    local portal_name = "gun_" .. color .. "_" .. pname
    portal_gun_remove(pname, color)
    portal_gun_place_frame(cx, cy, cz, axis, GUN_W, GUN_H, frame_node)
    portals[portal_name] = {
        cx=cx, cy=cy, cz=cz,
        axis=axis, ns=ns,
        w=GUN_W, h=GUN_H,
        node_name=frame_node,
    }
    local other_color = color == "blue" and "orange" or "blue"
    local other_name  = "gun_" .. other_color .. "_" .. pname
    if portals[other_name] then
        portals[portal_name].link = other_name
        portals[other_name].link  = portal_name
    end
    save_portals()
    sync_portals()
    update_anchor(portal_name, portals[portal_name])
end

minetest.register_node("yaportal:frame_blue", {
    description = "Blue Portal Frame (portal gun, unbreakable)",
    tiles = {"yaportal_blue.png"},
    groups = {not_in_creative_inventory=1},
    diggable = false,
})

minetest.register_node("yaportal:frame_orange", {
    description = "Orange Portal Frame (portal gun, unbreakable)",
    tiles = {"yaportal_orange.png"},
    groups = {not_in_creative_inventory=1},
    diggable = false,
})

-- Gun tools override on_place, so the engine's default dispatch to the
-- pointed node's on_rightclick never runs for them: right-clicking a
-- pedestal would fire the orange portal instead of storing the gun.
-- Forward pedestal clicks explicitly (yaportal:pedestal is registered
-- later; the lookup happens at click time).
local function gun_place_on_pedestal(itemstack, placer, pointed)
    if not (pointed and pointed.type == "node") then return nil end
    local n = minetest.get_node(pointed.under)
    if n.name ~= "yaportal:pedestal" then return nil end
    local ndef = minetest.registered_nodes[n.name]
    if not (ndef and ndef.on_rightclick) then return nil end
    return ndef.on_rightclick(pointed.under, n, placer, itemstack, pointed)
        or itemstack
end

minetest.register_tool("yaportal:portal_gun", {
    description = "Portal Gun\nLeft click: blue portal\nRight click: orange portal",
    inventory_image = "yaportal_gun.png",
    on_use = function(itemstack, user, pointed_thing)
        portal_gun_shoot(user, pointed_thing, "blue")
        return itemstack
    end,
    on_place = function(itemstack, placer, pointed_thing)
        local st = gun_place_on_pedestal(itemstack, placer, pointed_thing)
        if st then return st end
        portal_gun_shoot(placer, pointed_thing, "orange")
        return itemstack
    end,
})

minetest.register_on_leaveplayer(function(player)
    local name = player:get_player_name()
    local had_gun = portals["gun_blue_"..name] or portals["gun_orange_"..name]
    portal_gun_remove(name, "blue")
    portal_gun_remove(name, "orange")
    if had_gun then
        save_portals()
        sync_portals()
    end
end)

-- ---- deprecated: portal_gun2 (Surface) removed ----------------------------
-- The old "Portal Gun (Surface)" placed a white shell border around a carved
-- opening; it has been removed in favour of the type-2 hollow block portal
-- (portal_gun3, below). portal_shell stays registered only so existing worlds
-- can self-clean: the LBM turns leftover shells into air on mapblock load, and
-- saved gun2_* portals are dropped on load.

minetest.register_node("yaportal:portal_shell", {
    description = "Portal Shell (deprecated)",
    tiles = {"yaportal_shell.png"},
    groups = {not_in_creative_inventory = 1},
    diggable = false,
})

minetest.register_lbm({
    label = "Remove deprecated portal_gun2 shells",
    name = "yaportal:cleanup_portal_shell",
    nodenames = {"yaportal:portal_shell"},
    run_at_every_load = true,
    action = function(pos)
        minetest.remove_node(pos)
    end,
})

minetest.register_alias("yaportal:portal_gun2", "air")

-- ── embedded portal gun 3 (type-2 hollow block portal) ───────────────────────
-- Shoots a surface; spawns a W×H arrangement of solid "portal_block" nodes whose
-- front (open) face points at the player. The blocks are a new engine node type
-- (group portal_block): solid on the outward faces, open on the front (the portal
-- surface) and on faces shared with an adjacent same-orientation portal_block, so
-- a 2×1 portal has 4 solid faces per block (the cavity is continuous). Auto-paired
-- blue/orange per player, like the other guns.

local PGUN3_W, PGUN3_H = 1, 2   -- portal opening: W in-plane horizontal, H vertical

-- wallmounted param2 whose getWallMountedDir() equals the portal normal (axis,ns).
local function pgun3_param2(axis, ns)
    if axis == 0 then return ns > 0 and 4 or 5      -- +Z / -Z
    elseif axis == 1 then return ns > 0 and 2 or 3  -- +X / -X
    else return ns > 0 and 0 or 1 end               -- +Y / -Y
end

local function pgun3_register_block(color, tex)
    minetest.register_node("yaportal:portal_block_" .. color, {
        description = color:gsub("^%l", string.upper) ..
            " Portal Block (type 2, unbreakable)",
        drawtype = "nodebox",
        paramtype = "light",
        paramtype2 = "wallmounted",
        sunlight_propagates = false,
        tiles = {tex},
        node_box = {type = "fixed", fixed = {-0.5,-0.5,-0.5, 0.5,0.5,0.5}},
        -- portal_block VALUE identifies the portal family/colour: the engine
        -- merges adjacent cells into one cavity only when the value matches
        -- (cells of one portal may be different node ids).
        groups = {portal_block = (color == "blue") and 1 or 2,
                  not_in_creative_inventory = 1},
        diggable = false,
    })
end
pgun3_register_block("blue",   "yaportal_blue.png")
pgun3_register_block("orange", "yaportal_orange.png")

-- Reconstruct the integer block positions from a stored block portal. cx/cy/cz
-- hold the block-center plane on the normal axis and the min block coord on the
-- other two axes (all integers).
local function pgun3_block_positions(pp)
    local list = {}
    local w, h = pp.w or 1, pp.h or 1
    if pp.axis == 0 then
        for dx = 0, w-1 do for dy = 0, h-1 do
            list[#list+1] = {x = pp.cx + dx, y = pp.cy + dy, z = pp.cz}
        end end
    elseif pp.axis == 1 then
        for dz = 0, w-1 do for dy = 0, h-1 do
            list[#list+1] = {x = pp.cx, y = pp.cy + dy, z = pp.cz + dz}
        end end
    else -- axis 2
        for dx = 0, w-1 do for dz = 0, h-1 do
            list[#list+1] = {x = pp.cx + dx, y = pp.cy, z = pp.cz + dz}
        end end
    end
    return list
end

local function portal_gun3_remove(pname, color)
    local portal_name = "gun3_" .. color .. "_" .. pname
    local pp = portals[portal_name]
    if not pp then return end
    local bnode = "yaportal:portal_block_" .. color
    for _, bpos in ipairs(pgun3_block_positions(pp)) do
        if minetest.get_node(bpos).name == bnode then
            minetest.remove_node(bpos)
        end
    end
    if pp.link and portals[pp.link] then
        portals[pp.link].link = nil
    end
    portals[portal_name] = nil
    update_anchor(portal_name, nil)
end

local function portal_gun3_shoot(player, pointed_thing, color)
    if pointed_thing.type ~= "node" then return end
    local pname = player:get_player_name()
    local under = pointed_thing.under
    local above = pointed_thing.above
    local dx = above.x - under.x
    local dy = above.y - under.y
    local dz = above.z - under.z

    -- Portal normal = hit-face direction (from the surface toward the player side).
    local axis, ns
    if dz ~= 0 then axis, ns = 0, dz
    elseif dx ~= 0 then axis, ns = 1, dx
    else axis, ns = 2, dy end

    local portal_name = "gun3_" .. color .. "_" .. pname
    portal_gun3_remove(pname, color)

    local param2 = pgun3_param2(axis, ns)
    local bnode  = "yaportal:portal_block_" .. color
    local bx0, by0, bz0 = above.x, above.y, above.z  -- air cell next to the surface

    -- Opening dimensions and rotation. pw = in-plane width, ph = the other in-plane
    -- dimension. Walls keep the fixed 1×2 (width × height) with no rotation. Floor
    -- and ceiling portals instead orient the 1×2 opening along the shooter's facing
    -- (long axis aligned with the look direction) and set rot so the portal "up"
    -- points the same way — otherwise every floor portal would face a fixed way.
    local pw, ph, rot = PGUN3_W, PGUN3_H, 0
    if axis == 2 then
        local look = player:get_look_dir()
        if math.abs(look.z) >= math.abs(look.x) then
            pw, ph = 1, 2                    -- long axis (2) along Z
            rot = (look.z >= 0) and 0 or 2   -- portal up = +Z / -Z
        else
            pw, ph = 2, 1                    -- long axis (2) along X
            rot = (look.x >= 0) and 3 or 1   -- portal up = +X / -X
        end
    end

    -- Place pw×ph blocks in the portal plane. For walls ph runs along Y (height);
    -- for floor/ceiling portals pw runs along X and ph along Z.
    if axis == 0 then
        for ddx = 0, pw-1 do for ddy = 0, ph-1 do
            minetest.set_node({x=bx0+ddx, y=by0+ddy, z=bz0}, {name=bnode, param2=param2})
        end end
    elseif axis == 1 then
        for ddz = 0, pw-1 do for ddy = 0, ph-1 do
            minetest.set_node({x=bx0, y=by0+ddy, z=bz0+ddz}, {name=bnode, param2=param2})
        end end
    else -- axis 2
        for ddx = 0, pw-1 do for ddz = 0, ph-1 do
            minetest.set_node({x=bx0+ddx, y=by0, z=bz0+ddz}, {name=bnode, param2=param2})
        end end
    end

    -- Store with the portal plane at the block CENTER (like type-1 portals at the
    -- air-node center): the render draws the tunnel mouth at pos + 0.5·normal, so a
    -- centered plane puts the mouth flush with the block's front face.
    local cx, cy, cz = bx0, by0, bz0

    portals[portal_name] = {
        cx=cx, cy=cy, cz=cz,
        axis=axis, ns=ns,
        w=pw, h=ph, rot=rot,
        kind="block",
        node_name=bnode,
    }

    local other_color = color == "blue" and "orange" or "blue"
    local other_name  = "gun3_" .. other_color .. "_" .. pname
    if portals[other_name] then
        portals[portal_name].link = other_name
        portals[other_name].link  = portal_name
    end

    save_portals()
    sync_portals()
    update_anchor(portal_name, portals[portal_name])
end

minetest.register_tool("yaportal:portal_gun3", {
    description = "Portal Gun (Block, type 2)" ..
        "\nLeft click: blue portal\nRight click: orange portal" ..
        "\n" .. PGUN3_W .. "×" .. PGUN3_H .. " hollow block portal",
    inventory_image = "yaportal_gun.png^[colorize:#33bbff:100",
    on_use = function(itemstack, user, pointed_thing)
        portal_gun3_shoot(user, pointed_thing, "blue")
        return itemstack
    end,
    on_place = function(itemstack, placer, pointed_thing)
        local st = gun_place_on_pedestal(itemstack, placer, pointed_thing)
        if st then return st end
        portal_gun3_shoot(placer, pointed_thing, "orange")
        return itemstack
    end,
})

minetest.register_on_leaveplayer(function(player)
    local name = player:get_player_name()
    local had = portals["gun3_blue_"..name] or portals["gun3_orange_"..name]
    portal_gun3_remove(name, "blue")
    portal_gun3_remove(name, "orange")
    if had then
        save_portals()
        sync_portals()
    end
end)

-- ── portal gun 4 (in-wall portal on a craftable white block) ─────────────────
-- A craftable white wall block (yaportal:portal_wall). Firing portal_gun4 at a
-- portal_wall node carves a 1×2 hollow block portal *inside the wall*: the white
-- blocks at the portal footprint are replaced by type-2 portal_block nodes (open
-- face toward the shooter, reusing the gun3 blocks). When the portal is removed
-- (re-fire of the same colour, or the player leaving) the white blocks are
-- restored, so the wall returns to its previous state.

local PGUN4_W, PGUN4_H = 1, 2
local PGUN4_WALL = "yaportal:portal_wall"

minetest.register_node(PGUN4_WALL, {
    description = "Portal Wall Block",
    tiles = {"[fill:16x16:#ffffff"},
    paramtype = "light",
    sunlight_propagates = false,
    is_ground_content = false,
    groups = {portal_wall = 1, cracky = 2, pickaxey = 1},
    _mcl_hardness = 1.5,
    _mcl_blast_resistance = 6,
})

-- X of diamonds with iron ingots in the empty holes. Item names differ between
-- VoxeLibre (mcl_core) and Minetest Game (default); pick whichever is present.
do
    local diamond = (minetest.get_modpath("mcl_core") and "mcl_core:diamond")
                 or (minetest.get_modpath("default")  and "default:diamond")
    local iron    = (minetest.get_modpath("mcl_core") and "mcl_core:iron_ingot")
                 or (minetest.get_modpath("default")  and "default:steel_ingot")
    if diamond and iron then
        minetest.register_craft({
            output = PGUN4_WALL .. " 4",
            recipe = {
                {diamond, iron,    diamond},
                {iron,    diamond, iron   },
                {diamond, iron,    diamond},
            },
        })
    end
end

-- Dedicated type-2 portal blocks for the wall gun: white outer shell (so the
-- carved cells blend with the surrounding Portal Wall Block) plus a thin 1/32
-- frame around the opening (engine group portal_frame, drawn with special_tiles
-- [1] = the portal colour). Separate node ids keep gun3's blocks untouched.
-- Shell-texture variants: the carved blocks take the look of the wall
-- material they replaced (portal_wall = white, wall_upper/lower = Aperture
-- panels, floor = Aperture floor tile), so a portal shot into a panel wall
-- or tiled floor doesn't turn its cells white.
-- Name scheme: yaportal:portal_wallblock_<color><mat>[_off].
local PGUN4_MAT_TILES = {
    [""]    = "[fill:16x16:#ffffff",
    ["_up"] = "yaportal_wall_upper.png",
    ["_lo"] = "yaportal_wall_lower.png",
    ["_fl"] = "yaportal_floor.png",
    ["_fc"] = "yaportal_floor_checker.png",
}
local PGUN4_MAT_OF = {
    ["yaportal:portal_wall"] = "",
    ["yaportal:wall_upper"]  = "_up",
    ["yaportal:wall_lower"]  = "_lo",
    ["yaportal:floor"]       = "_fl",
    ["yaportal:floor_checker"] = "_fc",
}
-- Panel slabs the wall gun can also carve: node name → shell material suffix
-- + the half of the cell the slab occupies ("ym".."zp"). Slabs are fixed-box
-- variant nodes (no facedir), one per half; the base item name is the bottom
-- ("ym") node. Orientation rules in pgun4_cell_carveable below.
local PGUN4_SLAB_INFO = {}
for _, m in ipairs({{"upper", "_up"}, {"lower", "_lo"}}) do
    local basename = "yaportal:wall_" .. m[1] .. "_slab"
    PGUN4_SLAB_INFO[basename] = {mat = m[2], half = "ym"}
    for _, h in ipairs({"yp", "xm", "xp", "zm", "zp"}) do
        PGUN4_SLAB_INFO[basename .. "_" .. h] = {mat = m[2], half = h}
    end
end

-- Engine face order (+Y -Y +X -X +Z -Z) index+1 of the slab's outer face:
-- value of the portal_slab group on wallblock slab variants (mapnode.cpp
-- confines the shell geometry to that half of the cell).
local PGUN4_SLAB_GROUP = {yp = 1, ym = 2, xp = 3, xm = 4, zp = 5, zm = 6}

-- Wallblock name suffix for the shell of a carved cell: the wall material
-- variant, plus "_s<half>" when the original node was a panel slab.
local function pgun4_shell_mat(name)
    if PGUN4_MAT_OF[name] then return PGUN4_MAT_OF[name] end
    local info = PGUN4_SLAB_INFO[name]
    if info then return info.mat .. "_s" .. info.half end
    return ""
end

local function pgun4_register_block(color, frametex, pbval)
    local Color = color:gsub("^%l", string.upper)
    for mat, tex in pairs(PGUN4_MAT_TILES) do
        local base = {
            drawtype = "nodebox",
            paramtype = "light",
            paramtype2 = "wallmounted",
            sunlight_propagates = false,
            tiles = {tex},                     -- shell = original wall material
            special_tiles = {frametex},        -- 1/32 frame around the opening
            node_box = {type = "fixed", fixed = {-0.5,-0.5,-0.5, 0.5,0.5,0.5}},
            diggable = false,
        }
        -- portal_block VALUE (pbval) = portal family/colour: engine merge key
        -- (cells of one portal are different node ids across shell materials).
        -- Open variant: linked portal. Front face is carved away.
        local open = table.copy(base)
        open.description = Color .. " Wall Portal Block (type 2, unbreakable)"
        open.groups = {portal_block = pbval, portal_frame = 1,
            not_in_creative_inventory = 1}
        minetest.register_node(
            "yaportal:portal_wallblock_" .. color .. mat, open)
        -- Closed variant: unlinked portal. Solid block + colored frame, no
        -- hole (group portal_closed keeps the front face solid).
        local closed = table.copy(base)
        closed.description = Color .. " Wall Portal Block (closed)"
        closed.groups = {portal_block = pbval, portal_frame = 1,
            portal_closed = 1, not_in_creative_inventory = 1}
        minetest.register_node(
            "yaportal:portal_wallblock_" .. color .. mat .. "_off", closed)
        -- Slab-shell variants (panel slab materials only): group portal_slab
        -- tells the engine the solid material fills just half of the cell,
        -- so the shell keeps the slab silhouette instead of a full cube.
        if mat == "_up" or mat == "_lo" then
            for half, gv in pairs(PGUN4_SLAB_GROUP) do
                local sopen = table.copy(open)
                sopen.groups.portal_slab = gv
                minetest.register_node("yaportal:portal_wallblock_"
                    .. color .. mat .. "_s" .. half, sopen)
                local sclosed = table.copy(closed)
                sclosed.groups.portal_slab = gv
                minetest.register_node("yaportal:portal_wallblock_"
                    .. color .. mat .. "_s" .. half .. "_off", sclosed)
            end
        end
    end
end
pgun4_register_block("blue",   "yaportal_blue.png",   3)
pgun4_register_block("orange", "yaportal_orange.png", 4)
-- Clock-fired portal pair: same machinery, distinct frame colours so they
-- can't be mistaken for the player's gun4 portals (same alpha as the pngs).
pgun4_register_block("purple", "[fill:16x16:#aa00ff96", 5)
pgun4_register_block("yellow", "[fill:16x16:#ffdc0096", 6)

-- Swap a gun4 portal's blocks between the open (linked, see-through) and closed
-- (unlinked, solid + frame) variants to match its current link state.
-- Cells + per-cell param2 for a gun4 portal footprint, including the extra
-- edge cells of a half-offset portal. param2 = wallmounted dir | carve<<3,
-- where carve (engine encoding, see mapnode.cpp) marks half-carved cells:
-- axis_sel 0 = first in-plane world axis ascending (axis 0 → X = horizontal,
-- axis 1 → Y = vertical), value 1+sel*2 = open on the - half, +1 = open on +.
-- Cell order is deterministic: pp.saved is indexed by it.
local function pgun4_cells(pp)
    local dirp2 = pgun3_param2(pp.axis, pp.ns)
    local ou, ov = pp.ou or 0, pp.ov or 0
    local out = {}
    if pp.axis == 2 or (ou == 0 and ov == 0) then
        for _, c in ipairs(pgun3_block_positions(pp)) do
            out[#out + 1] = {pos = c, param2 = dirp2, carve = 0}
        end
        return out
    end
    local nu = (pp.w or 1) + (ou > 0 and 1 or 0)   -- in-plane horizontal cells
    local nv = (pp.h or 1) + (ov > 0 and 1 or 0)   -- vertical cells
    -- Which half of the cell's front face is open on one offset axis:
    -- +1 = the + half, -1 = the - half, 0 = fully open on that axis.
    local function side_state(i, n, off)
        if off == 0 then return 0 end
        if i == 0 then return 1 end
        if i == n - 1 then return -1 end
        return 0
    end
    for du = 0, nu - 1 do
        for dv = 0, nv - 1 do
            local hs = side_state(du, nu, ou)
            local vs = side_state(dv, nv, ov)
            -- engine first/second in-plane axis (ascending X<Y<Z):
            -- axis 0 → X (horizontal), Y (vertical); axis 1 → Y, Z.
            local s0, s1
            if pp.axis == 0 then s0, s1 = hs, vs else s0, s1 = vs, hs end
            local carve = 0
            if s0 ~= 0 and s1 ~= 0 then
                carve = 5 + (s0 > 0 and 1 or 0) + (s1 > 0 and 2 or 0)
            elseif s0 ~= 0 then
                carve = (s0 > 0) and 2 or 1
            elseif s1 ~= 0 then
                carve = (s1 > 0) and 4 or 3
            end
            local pos
            if pp.axis == 0 then
                pos = {x = pp.cx + du, y = pp.cy + dv, z = pp.cz}
            else
                pos = {x = pp.cx, y = pp.cy + dv, z = pp.cz + du}
            end
            out[#out + 1] = {pos = pos, param2 = dirp2 + carve * 8, carve = carve}
        end
    end
    return out
end

local function pgun4_apply_state(portal_name)
    local pp = portals[portal_name]
    if not pp then return end
    local color = pp.color or portal_name:match("^gun4_(%w+)_")
    if not color then return end
    local base   = "yaportal:portal_wallblock_" .. color
    local linked = pp.link ~= nil and portals[pp.link] ~= nil
    for i, c in ipairs(pgun4_cells(pp)) do
        local nn = minetest.get_node(c.pos).name
        if nn:sub(1, #base) == base then
            local mat = pp.saved and pgun4_shell_mat(pp.saved[i]) or ""
            local target = base .. mat .. (linked and "" or "_off")
            minetest.set_node(c.pos, {name = target, param2 = c.param2})
        end
    end
    pp.node_name = base .. (linked and "" or "_off")
end

-- Wall materials the wall gun can carve a portal into. The original node of
-- every carved cell is remembered in pp.saved (name) + pp.saved_p2 (param2)
-- and restored on close.
local PGUN4_CARVEABLE = {
    [PGUN4_WALL] = true,
    ["yaportal:wall_upper"] = true,
    ["yaportal:wall_lower"] = true,
    ["yaportal:floor"] = true,
    ["yaportal:floor_checker"] = true,
}

-- Panel slabs are carveable in two ways:
--  * Fronting slab: occupies the half of the cell pointing along the portal
--    normal — its outer face IS the wall surface, so it hosts any opening
--    (the mid-block face never can: the opening plane sits on the node grid).
--  * In-plane slab (edge cells of a half-offset portal only): the opening in
--    that cell covers just one in-plane half, and the slab occupies exactly
--    that half, so the material behind the whole opening exists.
-- While the portal is open the carved cell becomes a full-depth wallblock
-- (bulges into the empty half); the slab comes back on close.
local PGUN4_AXIS_DIR = {[0] = "z", [1] = "x", [2] = "y"}
-- Engine first/second in-plane axes per portal axis (ascending order).
local PGUN4_INPLANE = {[0] = {"x", "y"}, [1] = {"y", "z"}}
-- carve value → open-half state per in-plane axis: 0 = opening spans the
-- whole axis, ±1 = opening confined to the +/− half (see pgun4_cells).
local PGUN4_CARVE_S = {
    [0] = {0, 0},
    {-1, 0}, {1, 0}, {0, -1}, {0, 1},           -- 1..4: half-open
    {-1, -1}, {1, -1}, {-1, 1}, {1, 1},         -- 5..8: quarter-open
}

local function pgun4_cell_carveable(node, axis, ns, carve)
    if PGUN4_CARVEABLE[node.name] then return true end
    local info = PGUN4_SLAB_INFO[node.name]
    if not info then return false end
    local ha = info.half:sub(1, 1)
    local hs = (info.half:sub(2, 2) == "p") and 1 or -1
    if ha == PGUN4_AXIS_DIR[axis] then
        return hs == ((ns > 0) and 1 or -1)     -- fronting slab
    end
    local inpl = PGUN4_INPLANE[axis]
    if not inpl then return false end           -- axis 2 has no offsets
    local s = PGUN4_CARVE_S[carve or 0]
    local sa = (ha == inpl[1]) and s[1] or (ha == inpl[2]) and s[2]
    return sa == hs
end

-- Aim gate: like pgun4_cell_carveable, but an in-plane slab always passes —
-- whether the opening fits its half depends on the offset candidate, which
-- the probe loop checks per cell later.
local function pgun4_aim_ok(node, axis, ns)
    if PGUN4_CARVEABLE[node.name] then return true end
    local info = PGUN4_SLAB_INFO[node.name]
    if not info then return false end
    local ha = info.half:sub(1, 1)
    if ha ~= PGUN4_AXIS_DIR[axis] then return PGUN4_INPLANE[axis] ~= nil end
    return (info.half:sub(2, 2) == "p") == (ns > 0)
end

-- Thin glass may share the exit cell of a portal as long as it sits BESIDE or
-- OPPOSITE the opening — never on the face toward the portal (which would block
-- the walk-through). These reproduce the thin_glass conventions without the
-- glass helpers (glass_dir_to_bit etc.), which are defined later in the file.
-- Full-face bit per outward direction (GLASS_FACES): -X=1 +X=2 -Y=4 +Y=8 -Z=16 +Z=32.
local FRONT_GLASS_BIT = {
    ["-1,0,0"] = 1, ["1,0,0"] = 2, ["0,-1,0"] = 4,
    ["0,1,0"]  = 8, ["0,0,-1"] = 16, ["0,0,1"] = 32,
}
local function front_glass_face_key(dx, dy, dz)
    if dx ~= 0 then return "x" .. (dx > 0 and "p" or "m") end
    if dy ~= 0 then return "y" .. (dy > 0 and "p" or "m") end
    return "z" .. (dz > 0 and "p" or "m")
end
-- True when a thin_glass node in the exit cell blocks the portal OPENING of
-- footprint cell `c` (carve = c.carve, axis = pp.axis). (ndx,ndy,ndz) points
-- from the exit cell back toward the portal (-n) — the face a blocking pane
-- would sit on. A full-face pane on that face always blocks. A half-pane blocks
-- only when the half it covers overlaps the opening's half: a half-pane sitting
-- beside the opening (e.g. glass on the +X half while the opening is on -X) is
-- fine, so half-slab + half-glass walls stay portable.
local function front_glass_blocks(name, ndx, ndy, ndz, carve, axis)
    local mask = tonumber(name:match("^yaportal:thin_glass_(%d+)$"))
    if mask then
        local b = FRONT_GLASS_BIT[ndx .. "," .. ndy .. "," .. ndz]
        return b ~= nil and (mask % (b * 2)) >= b
    end
    local fkey, hkey = name:match("^yaportal:thin_glass_half_(%a%a)_(%a%a)$")
    if not fkey or fkey ~= front_glass_face_key(ndx, ndy, ndz) then
        return false                       -- not glass, or pane on a side face
    end
    -- Half-pane flush on the opening face. A full-width opening (carve 0, or an
    -- axis with no in-plane offsets) is covered by any pane; otherwise the pane
    -- blocks only if its half meets the opening's half on the same in-plane axis.
    local s = PGUN4_CARVE_S[carve or 0]
    local inpl = PGUN4_INPLANE[axis]
    if (carve or 0) == 0 or not (s and inpl) then return true end
    local ha = hkey:sub(1, 1)
    local hs = (hkey:sub(2, 2) == "p") and 1 or -1
    local os = (ha == inpl[1]) and s[1] or (ha == inpl[2]) and s[2] or 0
    return os == 0 or os == hs             -- opening spans ha, or its half == pane half
end

-- Every footprint cell one step out along the normal must be passable,
-- otherwise part of the opening would be buried in a floor/ceiling/wall.
-- Thin glass in the exit cell is allowed (side/opposite panes, or a front pane
-- on the half beside the opening); only a pane covering the opening itself
-- blocks and refuses placement.
local function pgun4_front_clear(pp)
    local n = portal_normal(pp.axis, pp.ns)
    for _, c in ipairs(pgun4_cells(pp)) do
        local f = {x = c.pos.x + n.x, y = c.pos.y + n.y, z = c.pos.z + n.z}
        local nn = minetest.get_node(f).name
        local def = minetest.registered_nodes[nn]
        if not def then return false end
        if nn:match("^yaportal:thin_glass") then
            if front_glass_blocks(nn, -n.x, -n.y, -n.z, c.carve, pp.axis) then
                return false
            end
        elseif def.walkable then
            return false
        end
    end
    return true
end

-- A candidate placement is valid when the whole footprint is carveable wall
-- material AND the space in front of the opening is clear.
local function pgun4_probe_ok(pp)
    for _, c in ipairs(pgun4_cells(pp)) do
        if not pgun4_cell_carveable(minetest.get_node(c.pos),
                                    pp.axis, pp.ns, c.carve) then
            return false
        end
    end
    return pgun4_front_clear(pp)
end

local function portal_gun4_remove(pname, color)
    local portal_name = "gun4_" .. color .. "_" .. pname
    local pp = portals[portal_name]
    if not pp then return end
    local bnode = "yaportal:portal_wallblock_" .. color
    for i, c in ipairs(pgun4_cells(pp)) do
        local nn = minetest.get_node(c.pos).name
        if nn:sub(1, #bnode) == bnode then
            local orig = pp.saved and pp.saved[i] or PGUN4_WALL
            minetest.set_node(c.pos,
                {name = orig, param2 = pp.saved_p2 and pp.saved_p2[i] or 0})
        end
    end
    local partner = pp.link
    if partner and portals[partner] then
        portals[partner].link = nil
    end
    portals[portal_name] = nil
    update_anchor(portal_name, nil)
    -- Partner is now unlinked → reclose its blocks (solid + frame, no hole).
    if partner and portals[partner] then
        pgun4_apply_state(partner)
    end
end

-- Precise ray hit point on the pointed node: on_use pointed_things carry no
-- intersection_point, so re-raycast along the player's look. nil on mismatch
-- (callers fall back to grid-aligned placement).
local function pgun4_hit_point(player, under)
    local eye = player:get_pos()
    local props = player:get_properties()
    eye.y = eye.y + ((props and props.eye_height) or 1.5)
    local dir = player:get_look_dir()
    local ray = minetest.raycast(eye,
        {x = eye.x + dir.x * 20, y = eye.y + dir.y * 20, z = eye.z + dir.z * 20},
        false, false)
    for pt in ray do
        if pt.type == "node" and pt.under
           and pt.under.x == under.x and pt.under.y == under.y
           and pt.under.z == under.z then
            return pt.intersection_point
        end
    end
    return nil
end

local function portal_gun4_shoot(player, pointed_thing, color)
    if pointed_thing.type ~= "node" then return end
    local pname = player:get_player_name()
    local under = pointed_thing.under
    local above = pointed_thing.above

    local dx = above.x - under.x
    local dy = above.y - under.y
    local dz = above.z - under.z

    -- Portal normal = hit-face direction (from the wall toward the player side).
    local axis, ns
    if dz ~= 0 then axis, ns = 0, dz
    elseif dx ~= 0 then axis, ns = 1, dx
    else axis, ns = 2, dy end

    -- Only fires when aimed at a carveable wall material (a panel slab counts
    -- through its full cell-boundary face or as a half-offset edge cell,
    -- never through the mid-block face).
    if not pgun4_aim_ok(minetest.get_node(under), axis, ns) then return end

    portal_gun4_remove(pname, color)

    local bnode  = "yaportal:portal_wallblock_" .. color
    -- Plane lives IN the wall: carve into the hit block itself (not the air cell
    -- in front, unlike gun3). cx/cy/cz hold the min footprint coords.
    local bx0, by0, bz0 = under.x, under.y, under.z

    -- Wall portals: snap the opening centre to the nearest HALF node of the
    -- precise ray hit, in-plane. A centre landing on a seam/mid-block gives a
    -- half-offset portal (ou/ov = 0.5, both axes allowed → diagonal offsets
    -- use quarter-carved corner cells). No hit point → grid-aligned fallback.
    -- Vertical fit: candidates step half a node up/down from the aim until
    -- the footprint is carveable AND the space in front of the opening is
    -- clear (no floor/ceiling burying part of the portal); if the offset
    -- column can't fit either, retry grid-aligned horizontally.
    local ou, ov = 0, 0
    if axis ~= 2 then
        local hit = pgun4_hit_point(player, under)
        local ha = (axis == 0) and "x" or "z"   -- in-plane horizontal axis
        local col = under[ha]
        local cv2 = under.y * 2 + 1             -- aligned default, half-units
        if hit then
            local cu2 = math.floor(hit[ha] * 2 + 0.5)
            cv2 = math.floor(hit.y * 2 + 0.5)
            if (cu2 % 2) ~= 0 then ou = 0.5; col = (cu2 - 1) / 2
            else col = cu2 / 2 end
        end

        local ucands = {{ou, col}}
        if ou > 0 then
            ucands[#ucands + 1] =
                {0, hit and math.floor(hit[ha] + 0.5) or under[ha]}
        end
        local chosen
        for _, uc in ipairs(ucands) do
            for _, dd in ipairs({0, 1, -1, 2, -2, 3, -3}) do
                local c2 = cv2 + dd
                local vo = ((c2 % 2) == 0) and 0.5 or 0
                local b0 = (vo > 0) and (c2 / 2 - 1) or ((c2 - 1) / 2)
                local probe = {
                    cx = (axis == 0) and uc[2] or under.x,
                    cy = b0,
                    cz = (axis == 0) and under.z or uc[2],
                    axis = axis, ns = ns, w = PGUN4_W, h = PGUN4_H,
                    ou = uc[1], ov = vo,
                }
                if pgun4_probe_ok(probe) then
                    chosen = probe
                    break
                end
            end
            if chosen then break end
        end
        if not chosen then
            minetest.chat_send_player(pname,
                "[yaportal] No room for a portal here (opening blocked or wall too small).")
            return
        end
        bx0, by0, bz0 = chosen.cx, chosen.cy, chosen.cz
        ou, ov = chosen.ou, chosen.ov
    end

    -- Opening dimensions / rotation, same scheme as gun3: walls keep a fixed 1×2
    -- opening. Floor/ceiling portals orient the 1×2 opening along the shooter's
    -- facing (always grid-aligned).
    local pw, ph, rot = PGUN4_W, PGUN4_H, 0
    if axis == 2 then
        local look = player:get_look_dir()
        local along, step   -- long (2-block) axis and +1/-1 step to the far cell
        if math.abs(look.z) >= math.abs(look.x) then
            pw, ph = 1, 2                       -- 1 wide (X) × 2 long (Z)
            rot  = (look.z >= 0) and 0 or 2
            along, step = "z", (look.z >= 0) and 1 or -1
        else
            pw, ph = 2, 1                       -- 2 long (X) × 1 wide (Z)
            rot  = (look.x >= 0) and 3 or 1
            along, step = "x", (look.x >= 0) and 1 or -1
        end
        -- Pointed block is the near end; portal extends one block toward the
        -- view. If that placement can't form a portal (far block not
        -- carveable, or a wall in front would bury part of the opening),
        -- fall back to the opposite side; if neither fits, refuse.
        local chosen
        for _, st in ipairs({step, -step}) do
            local bx, bz = under.x, under.z
            -- cx/cz must hold the min footprint coord.
            if st < 0 then
                if along == "z" then bz = under.z - 1 else bx = under.x - 1 end
            end
            local probe = {cx = bx, cy = by0, cz = bz,
                           axis = 2, ns = ns, w = pw, h = ph}
            if pgun4_probe_ok(probe) then
                chosen = probe
                break
            end
        end
        if not chosen then
            minetest.chat_send_player(pname,
                "[yaportal] No room for a portal here (opening blocked or floor too small).")
            return
        end
        bx0, bz0 = chosen.cx, chosen.cz
    end

    -- The whole footprint (including the extra half-carved cells of an offset
    -- portal) must be carveable wall material: we only carve into the wall,
    -- and restore exactly what we carved via pp.saved.
    local probe = {cx = bx0, cy = by0, cz = bz0, axis = axis, ns = ns,
                   w = pw, h = ph, ou = ou, ov = ov}
    local cells = pgun4_cells(probe)
    local saved, saved_p2 = {}, {}
    for i, c in ipairs(cells) do
        local node = minetest.get_node(c.pos)
        if not pgun4_cell_carveable(node, axis, ns, c.carve) then
            minetest.chat_send_player(pname,
                "[yaportal] Need a " .. pw .. "×" .. ph ..
                " portal-wall surface here.")
            return
        end
        saved[i] = node.name
        saved_p2[i] = node.param2
    end
    -- Place the closed (solid) variant in the shell material of the original
    -- node; pgun4_apply_state below opens it (and the partner) only if a
    -- paired portal already exists.
    for i, c in ipairs(cells) do
        minetest.set_node(c.pos,
            {name = bnode .. pgun4_shell_mat(saved[i]) .. "_off",
             param2 = c.param2})
    end

    local portal_name = "gun4_" .. color .. "_" .. pname
    portals[portal_name] = {
        cx = bx0, cy = by0, cz = bz0,
        axis = axis, ns = ns,
        w = pw, h = ph, rot = rot,
        ou = ou, ov = ov,
        kind = "block",
        node_name = bnode .. "_off",
        saved = saved,
        saved_p2 = saved_p2,
    }

    local other_color = color == "blue" and "orange" or "blue"
    local other_name  = "gun4_" .. other_color .. "_" .. pname
    if portals[other_name] then
        portals[portal_name].link = other_name
        portals[other_name].link  = portal_name
    end

    -- Open both ends when linked, otherwise leave this one closed (solid + frame).
    pgun4_apply_state(portal_name)
    if portals[portal_name].link then
        pgun4_apply_state(portals[portal_name].link)
    end

    save_portals()
    sync_portals()
    update_anchor(portal_name, portals[portal_name])
end

minetest.register_tool("yaportal:portal_gun4", {
    description = "Portal Gun (Wall)" ..
        "\nLeft click: blue portal\nRight click: orange portal" ..
        "\nCarves a " .. PGUN4_W .. "×" .. PGUN4_H ..
        " portal into a Portal Wall Block",
    inventory_image = "yaportal_gun.png^[colorize:#ffffff:80",
    on_use = function(itemstack, user, pointed_thing)
        portal_gun4_shoot(user, pointed_thing, "blue")
        return itemstack
    end,
    on_place = function(itemstack, placer, pointed_thing)
        local st = gun_place_on_pedestal(itemstack, placer, pointed_thing)
        if st then return st end
        portal_gun4_shoot(placer, pointed_thing, "orange")
        return itemstack
    end,
})

minetest.register_on_leaveplayer(function(player)
    local name = player:get_player_name()
    local had = portals["gun4_blue_"..name] or portals["gun4_orange_"..name]
    portal_gun4_remove(name, "blue")
    portal_gun4_remove(name, "orange")
    if had then
        save_portals()
        sync_portals()
    end
end)

-- ── pocket dimension gun ───────────────────────────────────────────────────────

local POCKET_SIZE = 32  -- 32×32 platform

minetest.register_node("yaportal:bedrock", {
    description = "Bedrock (unbreakable)",
    tiles = {"yaportal_bedrock.png"},
    groups = {not_in_creative_inventory=1},
    diggable = false,
})

minetest.register_node("yaportal:frame_green", {
    description = "Green Portal Frame (pocket dimension, unbreakable)",
    tiles = {"yaportal_green.png"},
    groups = {not_in_creative_inventory=1},
    diggable = false,
})

-- ── Portal 1 / Aperture Science decorative blocks ────────────────────────────

minetest.register_node("yaportal:wall_white", {
    description = "Aperture Science White Wall Panel\nClean white ceramic wall tile from Portal test chambers",
    tiles = {"yaportal_wall_white.png"},
    groups = {cracky = 1},
    sounds = minetest.get_modpath("default") and default and default.node_sound_stone_defaults() or nil,
})

-- Two-block wall panel: stack upper on top of lower to form one tall
-- Aperture panel (16x32) with a recessed seam around each panel.
minetest.register_node("yaportal:wall_upper", {
    description = "Aperture Science Wall Panel (upper)\nTop half of a tall white test-chamber panel; place above a lower panel",
    tiles = {"yaportal_wall_upper.png"},
    groups = {cracky = 1},
    sounds = minetest.get_modpath("default") and default and default.node_sound_stone_defaults() or nil,
})

minetest.register_node("yaportal:wall_lower", {
    description = "Aperture Science Wall Panel (lower)\nBottom half of a tall white test-chamber panel; place below an upper panel",
    tiles = {"yaportal_wall_lower.png"},
    groups = {cracky = 1},
    sounds = minetest.get_modpath("default") and default and default.node_sound_stone_defaults() or nil,
})

-- 45° diagonal wall pieces: the upper/lower panels cut in half vertically
-- from edge to edge (triangular prism mesh, models/yaportal_diag.obj).  The
-- diagonal face is sqrt(2) wide and maps the full panel texture stretched
-- across it, so the pattern lines up with the flat panels at both edges.
-- facedir picks which corner stays solid; placement takes it from the
-- placer's look direction.
do
    -- Staircase boxes for the solid half (x >= z at facedir 0, right angle
    -- at the +X/-Z corner); facedir rotates them with the mesh.  8 steps
    -- centered on the diagonal plane: each step straddles it by 1/16 on
    -- either side, so the wireframe/collision hugs the oblique face instead
    -- of jutting a quarter node past it.
    local steps = {}
    for k = 0, 7 do
        local z0 = -0.5 + k * 0.125
        steps[#steps + 1] = {z0 + 0.0625, -0.5, z0, 0.5, 0.5, z0 + 0.125}
    end
    for _, part in ipairs({"upper", "lower"}) do
        minetest.register_node("yaportal:wall_" .. part .. "_diag", {
            description = "Aperture Science Wall Panel (" .. part .. ", 45°)\n" ..
                "Panel cut diagonally edge to edge for 45° walls; " ..
                "places with the diagonal face toward you",
            drawtype = "mesh",
            mesh = "yaportal_diag.obj",
            tiles = {"yaportal_wall_" .. part .. ".png"},
            paramtype = "light",
            paramtype2 = "facedir",
            sunlight_propagates = true,
            collision_box = {type = "fixed", fixed = steps},
            selection_box = {type = "fixed", fixed = steps},
            groups = {cracky = 1},
            sounds = minetest.get_modpath("default") and default and default.node_sound_stone_defaults() or nil,
            on_place = function(itemstack, placer, pointed)
                -- Diagonal-face normals per facedir (from the verified
                -- facedir rotation (x,z)→(z,-x)): 0:(-X,+Z) 1:(+X,+Z)
                -- 2:(+X,-Z) 3:(-X,-Z).  Pick the facedir whose normal points
                -- back at the placer, so the oblique face looks toward them.
                local p2 = 0
                if placer then
                    local ld = placer:get_look_dir()
                    if ld.x >= 0 then
                        p2 = (ld.z >= 0) and 3 or 0
                    else
                        p2 = (ld.z >= 0) and 2 or 1
                    end
                end
                return minetest.item_place(itemstack, placer, pointed, p2)
            end,
        })
    end
end

-- In-plane click coordinates on the pointed face: returns the normal axis
-- ("x"/"y"/"z"), its sign, and {axis = offset} for the two in-plane axes,
-- offsets in [-0.5, 0.5] relative to the face centre (0 when the precise ray
-- hit is unavailable, e.g. non-player placers).
local function face_click_info(placer, under, above)
    local n = {x = above.x - under.x, y = above.y - under.y, z = above.z - under.z}
    local na = (n.x ~= 0 and "x") or (n.y ~= 0 and "y") or (n.z ~= 0 and "z")
    if not na or math.abs(n.x) + math.abs(n.y) + math.abs(n.z) ~= 1 then
        return nil
    end
    local hit = placer and placer:is_player() and pgun4_hit_point(placer, under) or nil
    local inpl = {}
    for _, a in ipairs({"x", "y", "z"}) do
        if a ~= na then
            inpl[a] = hit and math.max(-0.5, math.min(0.5, hit[a] - above[a])) or 0
        end
    end
    return na, n[na], inpl
end

-- Half-thick slab version of the two panels, placeable in all six
-- orientations. One fixed-box node per occupied half (suffix ym/yp/xm/xp/
-- zm/zp; the base item name is the bottom "ym" node): unlike a facedir node,
-- fixed boxes keep the tile projection world-aligned, so the panel pattern
-- lines up with neighbouring full wall blocks on every face.
local SLAB_HALF_BOX = {
    ym = {-0.5, -0.5, -0.5, 0.5, 0,   0.5},
    yp = {-0.5,  0,   -0.5, 0.5, 0.5, 0.5},
    xm = {-0.5, -0.5, -0.5, 0,   0.5, 0.5},
    xp = { 0,   -0.5, -0.5, 0.5, 0.5, 0.5},
    zm = {-0.5, -0.5, -0.5, 0.5, 0.5, 0  },
    zp = {-0.5, -0.5,  0,   0.5, 0.5, 0.5},
}

-- Click a face near its centre to lay the slab flush against it (a wall face
-- gives a standing, vertical slab); click in the outer quarter of the face to
-- push the slab into the half of the cell toward that edge (e.g. a floor
-- clicked near a wall starts a half-thick wall on that side).
local function slab_on_place(basename)
    return function(itemstack, placer, pointed)
        if pointed.type ~= "node" then return itemstack end
        -- Standard courtesy: let the pointed node handle a rightclick
        -- (chests, etc.) unless sneaking.
        if placer and placer:is_player()
           and not placer:get_player_control().sneak then
            local un = minetest.get_node(pointed.under)
            local ndef = minetest.registered_nodes[un.name]
            if ndef and ndef.on_rightclick then
                return ndef.on_rightclick(pointed.under, un, placer,
                    itemstack, pointed) or itemstack
            end
        end
        local na, nsg, inpl = face_click_info(placer, pointed.under, pointed.above)
        if not na then return itemstack end
        local half = na .. (nsg > 0 and "m" or "p")
        local ea, ev = nil, 0.25
        for _, a in ipairs({"x", "y", "z"}) do
            if inpl[a] and math.abs(inpl[a]) > ev then
                ea, ev = a, math.abs(inpl[a])
            end
        end
        if ea then half = ea .. (inpl[ea] >= 0 and "p" or "m") end
        local target = (half == "ym") and basename or (basename .. "_" .. half)
        -- Place a temp stack of the right variant so the standard placement
        -- path (buildable_to, protection, callbacks) still applies.
        local temp = ItemStack(target)
        local _, ppos = minetest.item_place_node(temp, placer, pointed)
        if ppos and placer and placer:is_player()
           and not minetest.is_creative_enabled(placer:get_player_name()) then
            itemstack:take_item()
        end
        return itemstack
    end
end

for _, part in ipairs({"upper", "lower"}) do
    local basename = "yaportal:wall_" .. part .. "_slab"
    local on_place = slab_on_place(basename)
    for half, box in pairs(SLAB_HALF_BOX) do
        local def = {
            description = "Aperture Science Wall Panel Slab (" .. part .. ")\n" ..
                "Half-thick panel: click a face centre to lay it flush " ..
                "against it (walls give a vertical slab), near an edge to " ..
                "stand it toward that edge",
            drawtype = "nodebox",
            paramtype = "light",
            sunlight_propagates = true,
            node_box = {type = "fixed", fixed = box},
            tiles = {"yaportal_wall_" .. part .. ".png"},
            groups = {cracky = 1},
            drop = basename,
            sounds = minetest.get_modpath("default") and default and default.node_sound_stone_defaults() or nil,
            on_place = on_place,
        }
        if half == "ym" then
            minetest.register_node(basename, def)
        else
            def.groups.not_in_creative_inventory = 1
            minetest.register_node(basename .. "_" .. half, def)
        end
    end
end

-- Migration: the first build used one facedir node per slab material; split
-- those into the fixed-box variants (facedir axis group → occupied half).
minetest.register_lbm({
    label = "yaportal: split facedir panel slabs into fixed-box variants",
    name = "yaportal:slab_facedir_split",
    nodenames = {"yaportal:wall_upper_slab", "yaportal:wall_lower_slab"},
    action = function(pos, node)
        local g = math.floor((node.param2 or 0) / 4) % 6
        local sfx = ({"zm", "zp", "xm", "xp", "yp"})[g]   -- g=0 → ym (base)
        if sfx then
            minetest.set_node(pos, {name = node.name .. "_" .. sfx})
        elseif node.param2 ~= 0 then
            minetest.set_node(pos, {name = node.name})
        end
    end,
})

minetest.register_node("yaportal:floor", {
    description = "Aperture Science Floor Tile\nLight grey tiled floor from Portal test chambers",
    tiles = {"yaportal_floor.png"},
    groups = {cracky = 1},
    sounds = minetest.get_modpath("default") and default and default.node_sound_stone_defaults() or nil,
})

minetest.register_node("yaportal:floor_checker", {
    description = "Aperture Science Checker Floor Tile\nCheckerboard grey tiled floor from Portal test chambers",
    tiles = {"yaportal_floor_checker.png"},
    groups = {cracky = 1},
    sounds = minetest.get_modpath("default") and default and default.node_sound_stone_defaults() or nil,
})

-- Thin (1/32) glass panel that can occupy one OR MORE faces of the same node
-- cell. Each of the 6 faces is a bit in a mask (1..63); every non-empty mask is
-- a registered variant node "yaportal:thin_glass_<mask>" whose fixed node_box is
-- the union of the slabs for its set bits. A custom on_place OR-s the pointed
-- face into the target cell, so pointing at the six solids around one air cell
-- builds a hollow glass cube in that single cell.
local THIN = 1/32
local GLASS_FACES = {
    {bit = 1,  dir = {x=-1, y= 0, z= 0}, box = {-0.5,      -0.5,      -0.5,      -0.5+THIN, 0.5,       0.5     }},
    {bit = 2,  dir = {x= 1, y= 0, z= 0}, box = { 0.5-THIN, -0.5,      -0.5,       0.5,      0.5,       0.5     }},
    {bit = 4,  dir = {x= 0, y=-1, z= 0}, box = {-0.5,      -0.5,      -0.5,       0.5,     -0.5+THIN,  0.5     }},
    {bit = 8,  dir = {x= 0, y= 1, z= 0}, box = {-0.5,       0.5-THIN, -0.5,       0.5,      0.5,       0.5     }},
    {bit = 16, dir = {x= 0, y= 0, z=-1}, box = {-0.5,      -0.5,      -0.5,       0.5,      0.5,      -0.5+THIN}},
    {bit = 32, dir = {x= 0, y= 0, z= 1}, box = {-0.5,      -0.5,       0.5-THIN,  0.5,      0.5,       0.5     }},
}
local function glass_dir_to_bit(d)
    for _, f in ipairs(GLASS_FACES) do
        if f.dir.x == d.x and f.dir.y == d.y and f.dir.z == d.z then return f.bit end
    end
end
local function glass_mask_boxes(mask)
    local t = {}
    for _, f in ipairs(GLASS_FACES) do
        if mask % (f.bit*2) >= f.bit then t[#t+1] = f.box end
    end
    return t
end
local function glass_has_bit(mask, bit) return mask % (bit*2) >= bit end
local function glass_popcount(m)
    local c = 0
    while m > 0 do c = c + (m % 2); m = math.floor(m/2) end
    return c
end
local function glass_mask_of(name)
    if name == "yaportal:thin_glass" then return 0 end
    local m = name:match("^yaportal:thin_glass_(%d+)$")
    return m and tonumber(m) or nil
end

-- on_place shared by the base item and every variant: add the targeted face to
-- an existing glass cell, or drop a fresh single-face panel on the side opposite
-- the placer (flush against the surface pointed at).
local function glass_place(itemstack, placer, pointed)
    if pointed.type ~= "node" then return itemstack end
    local pname = placer and placer:is_player() and placer:get_player_name() or ""
    local under, above = pointed.under, pointed.above
    local un = minetest.get_node(under)

    -- Standard courtesy: let the pointed node handle a rightclick (chests, etc.)
    -- unless sneaking.
    if placer and not placer:get_player_control().sneak then
        local ndef = minetest.registered_nodes[un.name]
        if ndef and ndef.on_rightclick then
            return ndef.on_rightclick(under, un, placer, itemstack, pointed) or itemstack
        end
    end

    local function put(pos, base_mask, bit)
        if not bit or glass_has_bit(base_mask, bit) then return false end
        if minetest.is_protected(pos, pname) then
            minetest.record_protection_violation(pos, pname)
            return false
        end
        minetest.set_node(pos, {name = "yaportal:thin_glass_" .. (base_mask + bit)})
        if placer and not minetest.is_creative_enabled(pname) then
            itemstack:take_item()
        end
        return true
    end

    -- Case A: pointing at an existing glass cell with the clicked face still
    -- empty → fill that face of the SAME cell.
    local unmask = glass_mask_of(un.name)
    if unmask and unmask > 0 then
        local bit = glass_dir_to_bit({x=above.x-under.x, y=above.y-under.y, z=above.z-under.z})
        if put(under, unmask, bit) then return itemstack end
    end

    -- Case B: place into the neighbour cell, on the face touching the pointed
    -- surface (opposite side from the player). Merge into glass already there.
    local tn = minetest.get_node(above)
    local tmask = glass_mask_of(tn.name)
    if not tmask then
        local tdef = minetest.registered_nodes[tn.name]
        if not (tdef and tdef.buildable_to) then return itemstack end
        tmask = 0
    end
    local bit = glass_dir_to_bit({x=under.x-above.x, y=under.y-above.y, z=under.z-above.z})
    put(above, tmask, bit)
    return itemstack
end

for mask = 1, 63 do
    local boxes = glass_mask_boxes(mask)
    minetest.register_node("yaportal:thin_glass_" .. mask, {
        description = "Thin Glass Panel",
        drawtype = "nodebox",
        paramtype = "light",
        sunlight_propagates = true,
        use_texture_alpha = "blend",
        tiles = {"yaportal_thin_glass.png"},
        node_box = {type = "fixed", fixed = boxes},
        selection_box = {type = "fixed", fixed = boxes},
        groups = {cracky = 3, oddly_breakable_by_hand = 1, not_in_creative_inventory = 1},
        drop = "yaportal:thin_glass " .. glass_popcount(mask),
        sounds = minetest.get_modpath("default") and default and default.node_sound_glass_defaults() or nil,
        on_place = glass_place,
    })
end

-- Creative / inventory item. When placed it delegates to glass_place, which
-- converts it into the right thin_glass_<mask> variant.
minetest.register_node("yaportal:thin_glass", {
    description = "Thin Glass Panel\n1/32-thick glass — occupies one or more faces of a cell (aim at each face)",
    drawtype = "nodebox",
    paramtype = "light",
    sunlight_propagates = true,
    use_texture_alpha = "blend",
    inventory_image = "yaportal_thin_glass.png",
    wield_image = "yaportal_thin_glass.png",
    tiles = {"yaportal_thin_glass.png"},
    node_box = {type = "fixed", fixed = GLASS_FACES[5].box},  -- single -Z slab preview
    selection_box = {type = "fixed", fixed = GLASS_FACES[5].box},
    groups = {cracky = 3, oddly_breakable_by_hand = 1},
    drop = "yaportal:thin_glass",
    sounds = minetest.get_modpath("default") and default and default.node_sound_glass_defaults() or nil,
    on_place = glass_place,
})

-- Half-face thin glass: the same 1/32 pane covering only HALF of one face,
-- for glass walls that start or stop on a half-node line. One pane per cell
-- (it does not combine with the full-face mask panels); each (face, half)
-- pair is its own variant node. Placing the complementary half onto the same
-- face fuses the two into the corresponding full thin_glass_<bit> panel.
local GLASS_AXIS_IDX = {x = 1, y = 2, z = 3}   -- box min index; max = idx + 3
local GLASS_HALF_BIT = {}                       -- face key → full-panel mask bit
local GLASS_HALF_BOX = {}                       -- "<face>_<half>" suffix → box

for _, f in ipairs(GLASS_FACES) do
    local fa = (f.dir.x ~= 0 and "x") or (f.dir.y ~= 0 and "y") or "z"
    local fkey = fa .. (f.dir[fa] > 0 and "p" or "m")
    GLASS_HALF_BIT[fkey] = f.bit
    for _, ha in ipairs({"x", "y", "z"}) do
        if ha ~= fa then
            for _, hs in ipairs({-1, 1}) do
                local box = {f.box[1], f.box[2], f.box[3], f.box[4], f.box[5], f.box[6]}
                if hs > 0 then box[GLASS_AXIS_IDX[ha]] = 0
                else box[GLASS_AXIS_IDX[ha] + 3] = 0 end
                GLASS_HALF_BOX[fkey .. "_" .. ha .. (hs > 0 and "p" or "m")] = box
            end
        end
    end
end

-- The pane goes on the face of the neighbour cell flush with the clicked
-- surface (same convention as the full thin glass); the half is the in-plane
-- side the click leans toward. Dead-centre clicks on a wall face default to
-- the bottom half.
local function glass_half_place(itemstack, placer, pointed)
    if pointed.type ~= "node" then return itemstack end
    local pname = placer and placer:is_player() and placer:get_player_name() or ""
    local under, above = pointed.under, pointed.above
    local un = minetest.get_node(under)

    -- Standard courtesy: let the pointed node handle a rightclick (chests,
    -- etc.) unless sneaking.
    if placer and not placer:get_player_control().sneak then
        local ndef = minetest.registered_nodes[un.name]
        if ndef and ndef.on_rightclick then
            return ndef.on_rightclick(under, un, placer, itemstack, pointed) or itemstack
        end
    end

    local na, ns, inpl = face_click_info(placer, under, above)
    if not na then return itemstack end
    local fkey = na .. (ns > 0 and "m" or "p")
    local ha, hv = nil, -1
    for _, a in ipairs({"y", "x", "z"}) do
        if inpl[a] and math.abs(inpl[a]) > hv then ha, hv = a, math.abs(inpl[a]) end
    end
    local hkey = ha .. (inpl[ha] > 0 and "p" or "m")
    local target = "yaportal:thin_glass_half_" .. fkey .. "_" .. hkey
    local comp   = "yaportal:thin_glass_half_" .. fkey .. "_" ..
                   ha .. (inpl[ha] > 0 and "m" or "p")

    if minetest.is_protected(above, pname) then
        minetest.record_protection_violation(above, pname)
        return itemstack
    end
    local tn = minetest.get_node(above)
    if tn.name == target then
        return itemstack                    -- that half is already there
    elseif tn.name == comp then
        -- Complementary half present → fuse into the full-face panel.
        minetest.set_node(above, {name = "yaportal:thin_glass_" .. GLASS_HALF_BIT[fkey]})
    else
        local tdef = minetest.registered_nodes[tn.name]
        if not (tdef and tdef.buildable_to) then return itemstack end
        minetest.set_node(above, {name = target})
    end
    if placer and not minetest.is_creative_enabled(pname) then
        itemstack:take_item()
    end
    return itemstack
end

for suffix, box in pairs(GLASS_HALF_BOX) do
    minetest.register_node("yaportal:thin_glass_half_" .. suffix, {
        description = "Thin Glass Half Panel",
        drawtype = "nodebox",
        paramtype = "light",
        sunlight_propagates = true,
        use_texture_alpha = "blend",
        tiles = {"yaportal_thin_glass.png"},
        node_box = {type = "fixed", fixed = box},
        selection_box = {type = "fixed", fixed = box},
        groups = {cracky = 3, oddly_breakable_by_hand = 1, not_in_creative_inventory = 1},
        drop = "yaportal:thin_glass_half",
        sounds = minetest.get_modpath("default") and default and default.node_sound_glass_defaults() or nil,
        on_place = glass_half_place,
    })
end

-- Creative / inventory item; placement resolves it into the right variant.
minetest.register_node("yaportal:thin_glass_half", {
    description = "Thin Glass Half Panel\n1/32-thick glass covering half of a face — aim toward an edge to pick " ..
        "the half; add the missing half to fuse into a full pane",
    drawtype = "nodebox",
    paramtype = "light",
    sunlight_propagates = true,
    use_texture_alpha = "blend",
    tiles = {"yaportal_thin_glass.png"},
    node_box = {type = "fixed", fixed = GLASS_HALF_BOX["zm_ym"]},
    selection_box = {type = "fixed", fixed = GLASS_HALF_BOX["zm_ym"]},
    groups = {cracky = 3, oddly_breakable_by_hand = 1},
    drop = "yaportal:thin_glass_half",
    sounds = minetest.get_modpath("default") and default and default.node_sound_glass_defaults() or nil,
    on_place = glass_half_place,
})

local function _in_any_pocket(pos)
    for _, t in pairs(_pocket_areas) do
        if pos.x >= t.bx - 1 and pos.x <= t.bx + POCKET_SIZE
           and pos.y >= t.by - 1 and pos.y <= t.by + 40
           and pos.z >= t.bz - 1 and pos.z <= t.bz + POCKET_SIZE then
            return true
        end
    end
    return false
end
_pocket_spawn_blocker = _in_any_pocket

-- ── overworld sky sync ─────────────────────────────────────────────────────────
-- SKY_OVERWORLD is registered with engine-default colors, but games like
-- VoxeLibre drive the real sky per-player via set_sky (custom sunset tint,
-- black night sky, weather changes). Mirror the current sky of an overworld
-- player into the sky type so pocket→overworld portals show the actual sky.
local sky_sync_timer = 0
local sky_sync_last = nil
minetest.register_globalstep(function(dtime)
    sky_sync_timer = sky_sync_timer + dtime
    if sky_sync_timer < 2 then return end
    sky_sync_timer = 0
    for _, player in ipairs(minetest.get_connected_players()) do
        if not _in_any_pocket(player:get_pos()) then
            local s = player:get_sky(true)
            -- Only mirror "regular" skies: skybox/plain types (e.g. VoxeLibre
            -- End) don't represent the overworld view through the portal.
            if s and s.type == "regular" then
                local def = {
                    type       = "regular",
                    sky_color  = s.sky_color,
                    clouds     = s.clouds,
                    sunlit     = true,
                    brightness = 1.0,
                }
                local key = minetest.serialize(def)
                if key ~= sky_sync_last then
                    sky_sync_last = key
                    minetest.update_portal_sky_type(SKY_OVERWORLD, def)
                end
            end
            break
        end
    end
end)

-- Returns {bx,by,bz} bottom-left corner of the player's platform.
-- Allocates a new slot on first access.
local function pocket_get_or_alloc(pname)
    local key = "pocket_pos_" .. pname
    local s = storage:get_string(key)
    if s and s ~= "" then
        local t = minetest.deserialize(s)
        if t then
            _pocket_areas[pname] = t
            return t
        end
    end
    local slot = storage:get_int("pocket_slot_count")
    storage:set_int("pocket_slot_count", slot + 1)
    local t = {bx = slot * 300, by = -20001, bz = 0}
    storage:set_string(key, minetest.serialize(t))
    -- keep list of players with pockets to rebuild cache on restart
    local names_s = storage:get_string("pocket_players")
    local names = (names_s ~= "" and minetest.deserialize(names_s)) or {}
    names[#names+1] = pname
    storage:set_string("pocket_players", minetest.serialize(names))
    _pocket_areas[pname] = t
    return t
end

-- Generates the platform and fixed portal in the dimension (async callback).
-- If the portal already exists, calls callback immediately.
local function pocket_ensure(pname, callback)
    local t = pocket_get_or_alloc(pname)
    if portals["pocket_in_" .. pname] then
        callback(t); return
    end
    local bx, by, bz = t.bx, t.by, t.bz
    local pos1 = {x=bx-1,   y=by-1, z=bz-1}
    local pos2 = {x=bx+POCKET_SIZE, y=by+GUN_H+3, z=bz+POCKET_SIZE}
    minetest.emerge_area(pos1, pos2, function(_, _, remaining)
        if remaining > 0 then return end
        -- bedrock platform
        for dx = 0, POCKET_SIZE-1 do
            for dz = 0, POCKET_SIZE-1 do
                minetest.set_node({x=bx+dx, y=by, z=bz+dz},
                    {name="yaportal:bedrock"})
            end
        end
        -- fixed portal centered on platform, Z axis, inner face toward +z
        local cx = bx + 15
        local cy = by + 1  -- bottom frame at by (bedrock), interior starts at by+1
        local cz = bz  -- portal at -z edge, platform extends forward (+z, ns=1)
        portal_gun_place_frame(cx, cy, cz, 0, GUN_W, GUN_H, "yaportal:frame_green")
        local in_name = "pocket_in_" .. pname
        portals[in_name] = {
            cx=cx, cy=cy, cz=cz,
            axis=0, ns=1,
            w=GUN_W, h=GUN_H,
            node_name="yaportal:frame_green",
        }
        update_anchor(in_name, portals[in_name])
        callback(t)
    end)
end

local function pocket_remove_world(pname)
    local out_name = "pocket_out_" .. pname
    local pp = portals[out_name]
    if not pp then return end
    for _, fpos in ipairs(get_frame_positions(pp)) do
        if minetest.get_node(fpos).name == pp.node_name then
            minetest.remove_node(fpos)
        end
    end
    local in_name = "pocket_in_" .. pname
    if portals[in_name] then portals[in_name].link = nil end
    portals[out_name] = nil
    update_anchor(out_name, nil)
end

local function pocket_gun_shoot(player, pointed_thing)
    if pointed_thing.type ~= "node" then return end
    local pname = player:get_player_name()
    local under = pointed_thing.under
    local above = pointed_thing.above
    local dz    = above.z - under.z
    local dx    = above.x - under.x
    local dy    = above.y - under.y
    local ip    = pointed_thing.intersection_point
        or {x=above.x, y=above.y, z=above.z}

    local axis, ns, cx, cy, cz

    if dy ~= 0 then
        if dy < 0 then
            minetest.chat_send_player(pname,
                "[pocket] Cannot place portals on ceilings.")
            return
        end
        local look = player:get_look_dir()
        cy = above.y + 1
        if math.abs(look.z) >= math.abs(look.x) then
            axis = 0; ns = (look.z < 0) and 1 or -1; cz = above.z
            cx = portal_gun_find_h(math.floor(ip.x), above.x, function(try_cx)
                return portal_gun_can_place(try_cx, cy, cz, axis, GUN_W, GUN_H)
            end)
        else
            axis = 1; ns = (look.x < 0) and 1 or -1; cx = above.x
            cz = portal_gun_find_h(math.floor(ip.z), above.z, function(try_cz)
                return portal_gun_can_place(cx, cy, try_cz, axis, GUN_W, GUN_H)
            end)
        end
    elseif dz ~= 0 then
        axis = 0; ns = dz; cz = above.z
        cy = math.floor(ip.y - 0.5)
        cx = portal_gun_find_h(math.floor(ip.x), above.x, function(try_cx)
            return portal_gun_can_place(try_cx, cy, cz, axis, GUN_W, GUN_H)
        end)
    else
        axis = 1; ns = dx; cx = above.x
        cy = math.floor(ip.y - 0.5)
        cz = portal_gun_find_h(math.floor(ip.z), above.z, function(try_cz)
            return portal_gun_can_place(cx, cy, try_cz, axis, GUN_W, GUN_H)
        end)
    end

    if not cx or not cz then
        minetest.chat_send_player(pname,
            "[pocket] Not enough space for the portal.")
        return
    end

    pocket_ensure(pname, function()
        pocket_remove_world(pname)
        portal_gun_place_frame(cx, cy, cz, axis, GUN_W, GUN_H, "yaportal:frame_green")
        local out_name = "pocket_out_" .. pname
        local in_name  = "pocket_in_" .. pname
        portals[out_name] = {
            cx=cx, cy=cy, cz=cz,
            axis=axis, ns=ns,
            w=GUN_W, h=GUN_H,
            node_name="yaportal:frame_green",
            link=in_name,
        }
        if portals[in_name] then portals[in_name].link = out_name end
        save_portals()
        sync_portals()
        update_anchor(out_name, portals[out_name])
    end)
end

minetest.register_tool("yaportal:pocket_gun", {
    description = "Pocket Dimension Gun\nLeft click: open portal | Right click: close portal",
    inventory_image = "yaportal_gun.png^[colorize:#00cc00:120",
    on_use = function(itemstack, user, pointed_thing)
        pocket_gun_shoot(user, pointed_thing)
        return itemstack
    end,
    on_place = function(itemstack, placer, pointed_thing)
        local st = gun_place_on_pedestal(itemstack, placer, pointed_thing)
        if st then return st end
        local pname = placer:get_player_name()
        pocket_remove_world(pname)
        if portals["pocket_in_" .. pname] then
            portals["pocket_in_" .. pname].link = nil
        end
        save_portals()
        sync_portals()
        return itemstack
    end,
})

-- Aliases for worlds created with the old mod name (mio_portale).
for _, name in ipairs({"frame", "frame_blue", "frame_orange", "frame_green", "bedrock"}) do
    minetest.register_alias("mio_portale:" .. name, "yaportal:" .. name)
end
minetest.register_alias("mio_portale:portal_gun",  "yaportal:portal_gun")
minetest.register_alias("mio_portale:pocket_gun",  "yaportal:pocket_gun")

-- ── camera roll animation ─────────────────────────────────────────────────────
-- roll_targets[pname] = target roll (rad), nil = no animation.
-- Sources: portal traversal (vert↔horiz) and /upright command.

local ROLL_SPEED = math.pi  -- rad/s (~180°/s)

minetest.register_chatcommand("roll", {
    params = "<gradi>",
    description = "Imposta camera roll in gradi (debug portali)",
    privs = {interact = true},
    func = function(name, param)
        local deg = tonumber(param)
        if not deg then return false, "Uso: /roll <gradi>" end
        local p = minetest.get_player_by_name(name)
        if not p then return false, "Player non trovato" end
        roll_targets[name] = nil   -- cancel any running animation
        p:set_look_roll(deg * math.pi / 180)
        return true, ("Roll: %g°"):format(deg)
    end,
})

minetest.register_chatcommand("upright", {
    description = "Animazione raddrizzamento camera (roll → 0)",
    privs = {interact = true},
    func = function(name, _)
        local p = minetest.get_player_by_name(name)
        if not p then return false, "Player non trovato" end
        roll_targets[name] = 0
        return true, "Raddrizzamento in corso..."
    end,
})

minetest.register_globalstep(function(dtime)
    for name, target in pairs(roll_targets) do
        local p = minetest.get_player_by_name(name)
        if not p then
            roll_targets[name] = nil
        else
            local r = p:get_look_roll()
            local diff = target - r
            -- Shortest path (normalize to [-π, π])
            if diff > math.pi  then diff = diff - 2*math.pi end
            if diff < -math.pi then diff = diff + 2*math.pi end
            if math.abs(diff) < 0.002 then
                p:set_look_roll(target)
                roll_targets[name] = nil
            else
                local step = math.min(ROLL_SPEED * dtime, math.abs(diff))
                p:set_look_roll(r + (diff > 0 and 1 or -1) * step)
            end
        end
    end
end)

-- Anti-fall boots: negate all fall damage while worn. Crafted from iron and
-- diamonds. Integrates with VoxeLibre's mcl_armor (equippable in the feet slot)
-- when present; falls back to a plain inventory-carried item otherwise.
local ANTIFALL_BOOTS = "yaportal:antifall_boots"
local HAVE_MCL_ARMOR = minetest.get_modpath("mcl_armor") ~= nil

if HAVE_MCL_ARMOR then
    minetest.register_tool(ANTIFALL_BOOTS, {
        description = "Anti-Fall Boots\nNegate fall damage while worn",
        inventory_image = "yaportal_boots_inv.png",
        -- feet armor piece; no mcl_armor_uses group => never wears out
        groups = {armor = 1, armor_feet = 1,
                  non_combat_armor = 1, non_combat_feet = 1},
        on_place = mcl_armor.equip_on_use,
        on_secondary_use = mcl_armor.equip_on_use,
        _mcl_armor_element = "feet",
        _mcl_armor_texture = "yaportal_boots.png",
        sounds = {
            _mcl_armor_equip   = "mcl_armor_equip_diamond",
            _mcl_armor_unequip = "mcl_armor_unequip_diamond",
        },
    })
else
    minetest.register_craftitem(ANTIFALL_BOOTS, {
        description = "Anti-Fall Boots\nNegate fall damage while carried",
        inventory_image = "yaportal_boots_inv.png",
        stack_max = 1,
        groups = {armor_feet = 1},
    })
end

do
    local diamond = (minetest.get_modpath("mcl_core") and "mcl_core:diamond")
                 or (minetest.get_modpath("default")  and "default:diamond")
    local iron    = (minetest.get_modpath("mcl_core") and "mcl_core:iron_ingot")
                 or (minetest.get_modpath("default")  and "default:steel_ingot")
    if diamond and iron then
        minetest.register_craft({
            output = ANTIFALL_BOOTS,
            recipe = {
                {diamond, "", diamond},
                {iron,    "", iron   },
            },
        })
    end
end

-- True when the player has the boots equipped in the feet armor slot (mcl_armor
-- list "armor" index 5), or — without mcl_armor — simply carried in "main".
local function wearing_antifall_boots(player)
    local inv = player:get_inventory()
    if not inv then return false end
    if HAVE_MCL_ARMOR then
        local st = inv:get_stack("armor", 5)
        return st and st:get_name() == ANTIFALL_BOOTS
    end
    return inv:contains_item("main", ANTIFALL_BOOTS)
end

minetest.register_on_player_hpchange(function(player, hp_change, reason)
    if hp_change < 0 and reason and reason.type == "fall" then
        if wearing_antifall_boots(player) then return 0 end
        -- Negate fall damage during/just after a floor-portal drop: a fast faller
        -- may graze the under-block for a single tick before the collision shift
        -- engages.  The grace stamp is refreshed every shift tick and on exit.
        local grace = floor_portal_grace[player:get_player_name()]
        if grace and (minetest.get_us_time() - grace) < 500000 then
            return 0
        end
    end
    return hp_change
end, true)  -- modifier = true so the returned value replaces the damage

-- ── Portal 1 interactive blocks (cube, super button, dispenser, door) ────────
-- Weighted Storage Cube (carried Portal-style in front of the camera), a 2x2
-- Heavy Duty Super-Colliding Super Button pressed by players and loose cubes,
-- a Vital Apparatus Vent that dispenses cubes (and replaces its lost one), and
-- a 2x2 automatic door.  The door auto-detects its mode: with a super button
-- within 8 nodes it opens only while that button is pressed (the classic
-- Portal puzzle loop, no redstone needed); otherwise it opens on approach.
-- When a mesecons implementation is present (VoxeLibre's fork or the mesecons
-- mod) the button is additionally a receptor and the door an effector.

local hashpos = minetest.hash_node_position
local HAVE_MESECON = rawget(_G, "mesecon") ~= nil

local carried_cubes = {}  -- pname → ObjectRef of the cube that player carries
local superbuttons  = {}  -- hash(anchor) → {pos = anchor (min X/Z corner), pressed}
local dispensers    = {}  -- hash(pos) → {pos, empty_ticks}
local doors         = {}  -- hash(bl) → {pos = bottom-left quarter, p2, open, powered}

local CARRY_DIST  = 1.75
local CUBE_ENTITY = "yaportal:cube"

-- Classic mesecon API (Minetest Game mesecons and VoxeLibre's bundled fork
-- both provide it).  Newer VoxeLibre replaces it with mcl_redstone whose API
-- is not verified against any installed game here — if needed, extend these
-- three helpers with an `elseif rawget(_G, "mcl_redstone")` branch.
local function signal_rules()
    return mesecon.rules.pplate or mesecon.rules.default
end

local function signal_receptor(state)
    if not HAVE_MESECON then return nil end
    return {receptor = {
        state = (state == "on") and mesecon.state.on or mesecon.state.off,
        rules = signal_rules(),
    }}
end

local function signal_set(quarter_positions, on)
    if not HAVE_MESECON then return end
    for _, p in ipairs(quarter_positions) do
        if on then mesecon.receptor_on(p, signal_rules())
        else mesecon.receptor_off(p, signal_rules()) end
    end
end

local function button_sound(center, pressed)
    local spec = {pos = center, gain = 0.5, max_hear_distance = 16,
                  pitch = pressed and 1.0 or 0.9}
    if minetest.get_modpath("mesecons_button") then
        minetest.sound_play("mesecons_button_push", spec, true)
    elseif minetest.get_modpath("default") then
        minetest.sound_play("default_metal_footstep", spec, true)
    end
end

local function door_sound(center, open)
    local name
    if minetest.get_modpath("doors") then
        name = open and "doors_steel_door_open" or "doors_steel_door_close"
    elseif minetest.get_modpath("mcl_doors") then
        name = open and "doors_door_open" or "doors_door_close"
    end
    if name then
        minetest.sound_play(name, {pos = center, gain = 0.5,
                                   max_hear_distance = 16}, true)
    end
end

local block_sounds = minetest.get_modpath("default") and default
    and default.node_sound_stone_defaults() or nil

-- ── weighted storage cube ─────────────

-- Drop a carried cube back into the world (restores physics).  If the cube
-- currently overlaps a solid node, pull it back to the carrier's eye position
-- first so it cannot be released inside a wall.
local function drop_cube(pname)
    local obj = carried_cubes[pname]
    carried_cubes[pname] = nil
    if not obj then return end
    local ent = obj:get_luaentity()
    if not ent then return end
    ent._carrier = nil
    local pos = obj:get_pos()
    if pos then
        local def = minetest.registered_nodes[minetest.get_node(pos).name]
        if def and def.walkable then
            local player = minetest.get_player_by_name(pname)
            if player then
                local eye = player:get_pos()
                local props = player:get_properties()
                eye.y = eye.y + ((props and props.eye_height) or 1.5)
                obj:move_to(eye, false)
            end
        end
    end
    obj:set_properties({physical = true, collide_with_objects = true})
    obj:set_velocity({x = 0, y = 0, z = 0})
    obj:set_acceleration({x = 0, y = -9.81, z = 0})
end

minetest.register_entity(CUBE_ENTITY, {
    initial_properties = {
        visual = "cube",
        visual_size = {x = 0.9, y = 0.9, z = 0.9},
        textures = {
            "yaportal_cube.png", "yaportal_cube.png", "yaportal_cube.png",
            "yaportal_cube.png", "yaportal_cube.png", "yaportal_cube.png",
        },
        collisionbox = {-0.45, -0.45, -0.45, 0.45, 0.45, 0.45},
        selectionbox = {-0.45, -0.45, -0.45, 0.45, 0.45, 0.45},
        physical = true, collide_with_objects = true,
        pointable = true, is_visible = true,
        hp_max = 5, static_save = true,
        damage_texture_modifier = "^[brighten",
    },
    -- _home: hash of the dispenser that spawned this cube (persisted).
    -- _carrier: name of the carrying player (runtime only — after a server
    -- restart a carried cube reloads as a loose cube at its last position).
    on_activate = function(self, staticdata)
        self.object:set_armor_groups({fleshy = 100})
        self.object:set_acceleration({x = 0, y = -9.81, z = 0})
        if staticdata and staticdata ~= "" then
            local data = minetest.parse_json(staticdata)
            if type(data) == "table" then
                self._home = data.home
                if type(data.hp) == "number" and data.hp > 0 then
                    self.object:set_hp(data.hp)
                end
            end
        end
    end,
    get_staticdata = function(self)
        return minetest.write_json({home = self._home,
                                    hp = self.object:get_hp()})
    end,
    on_rightclick = function(self, clicker)
        if not (clicker and clicker:is_player()) then return end
        local pname = clicker:get_player_name()
        if self._carrier then
            if self._carrier == pname then drop_cube(pname) end
            return
        end
        if carried_cubes[pname] then
            minetest.chat_send_player(pname, "You are already carrying a cube.")
            return
        end
        self._carrier = pname
        carried_cubes[pname] = self.object
        self.object:set_properties({physical = false, collide_with_objects = false})
        self.object:set_velocity({x = 0, y = 0, z = 0})
        self.object:set_acceleration({x = 0, y = 0, z = 0})
    end,
    on_death = function(self)
        if self._carrier then
            carried_cubes[self._carrier] = nil
        end
    end,
})

minetest.register_on_leaveplayer(function(player)
    drop_cube(player:get_player_name())
end)
minetest.register_on_dieplayer(function(player)
    drop_cube(player:get_player_name())
end)

-- ── heavy duty super-colliding super button (2x2) ─────────────

-- The quarter node is registered with its cap flush toward +X/+Z; facedir
-- param2 rotates the cap toward the 2x2 center.  param2 doubles as the corner
-- id, so the anchor (min X/Z quarter) is recovered arithmetically — no meta.
-- Engine yaw convention verified in-game: if the caps point outward instead
-- of meeting at the center, swap 1↔3 in BOTH tables below.
local BTN_P2 = {[0] = {[0] = 0, [1] = 1}, [1] = {[0] = 3, [1] = 2}}  -- [dx][dz]
local BTN_ANCHOR_OFF = {
    [0] = {x = 0, z = 0}, [1] = {x = 0, z = -1},
    [2] = {x = -1, z = -1}, [3] = {x = -1, z = 0},
}

local function button_anchor(pos, param2)
    local off = BTN_ANCHOR_OFF[param2 % 4]
    return {x = pos.x + off.x, y = pos.y, z = pos.z + off.z}
end

local function button_quarters(anchor)
    local out = {}
    for dx = 0, 1 do
        for dz = 0, 1 do
            out[#out + 1] = {
                pos = {x = anchor.x + dx, y = anchor.y, z = anchor.z + dz},
                param2 = BTN_P2[dx][dz],
            }
        end
    end
    return out
end

local function button_swap(anchor, pressed)
    local target = pressed and "yaportal:superbutton_pressed"
                            or "yaportal:superbutton"
    for _, q in ipairs(button_quarters(anchor)) do
        local nn = minetest.get_node(q.pos).name
        if nn:find("^yaportal:superbutton") and nn ~= target then
            minetest.set_node(q.pos, {name = target, param2 = q.param2})
        end
    end
end

local function button_positions(anchor)
    local out = {}
    for _, q in ipairs(button_quarters(anchor)) do out[#out + 1] = q.pos end
    return out
end

local function superbutton_place(itemstack, placer, pointed)
    if pointed.type ~= "node" then return itemstack end
    local pname = placer and placer:is_player() and placer:get_player_name() or ""
    local un = minetest.get_node(pointed.under)

    -- Standard courtesy: let the pointed node handle a rightclick (chests,
    -- etc.) unless sneaking.
    if placer and not placer:get_player_control().sneak then
        local ndef = minetest.registered_nodes[un.name]
        if ndef and ndef.on_rightclick then
            return ndef.on_rightclick(pointed.under, un, placer, itemstack, pointed) or itemstack
        end
    end

    local anchor = pointed.above
    for dx = 0, 1 do
        for dz = 0, 1 do
            local cell = {x = anchor.x + dx, y = anchor.y, z = anchor.z + dz}
            local cdef = minetest.registered_nodes[minetest.get_node(cell).name]
            local below = {x = cell.x, y = cell.y - 1, z = cell.z}
            local bdef = minetest.registered_nodes[minetest.get_node(below).name]
            if not (cdef and cdef.buildable_to) or not (bdef and bdef.walkable) then
                minetest.chat_send_player(pname,
                    "The super button needs a free 2x2 area on solid ground " ..
                    "(expands +X/+Z from the clicked cell).")
                return itemstack
            end
            if minetest.is_protected(cell, pname) then
                minetest.record_protection_violation(cell, pname)
                return itemstack
            end
        end
    end

    for _, q in ipairs(button_quarters(anchor)) do
        minetest.set_node(q.pos, {name = "yaportal:superbutton", param2 = q.param2})
    end
    superbuttons[hashpos(anchor)] = {
        pos = {x = anchor.x, y = anchor.y, z = anchor.z}, pressed = false,
    }
    if placer and not minetest.is_creative_enabled(pname) then
        itemstack:take_item()
    end
    return itemstack
end

local function superbutton_after_dig(pos, oldnode)
    local anchor = button_anchor(pos, oldnode.param2)
    local h = hashpos(anchor)
    local entry = superbuttons[h]
    superbuttons[h] = nil
    for _, q in ipairs(button_quarters(anchor)) do
        if not (q.pos.x == pos.x and q.pos.y == pos.y and q.pos.z == pos.z) then
            if minetest.get_node(q.pos).name:find("^yaportal:superbutton") then
                minetest.remove_node(q.pos)
            end
        end
    end
    if entry and entry.pressed then
        signal_set(button_positions(anchor), false)
    end
end

do
    -- Cap: staircase of three boxes approximating a quarter disc rounded away
    -- from the 2x2 center; assembled, the four caps form an octagonal button.
    local cap_up = {
        {-4/16, -6/16,  0,     8/16, -2/16, 8/16},
        { 0,    -6/16, -4/16,  8/16, -2/16, 8/16},
        {-2/16, -6/16, -2/16,  8/16, -2/16, 8/16},
    }
    local cap_dn = {}
    for i, b in ipairs(cap_up) do
        cap_dn[i] = {b[1], b[2], b[3], b[4], -4/16, b[6]}
    end
    local function boxes(cap)
        local out = {{-0.5, -0.5, -0.5, 0.5, -6/16, 0.5}}  -- base slab
        for _, b in ipairs(cap) do out[#out + 1] = b end
        return out
    end

    local base = {
        description = "Heavy Duty Super-Colliding Super Button\n" ..
            "2x2 floor button (expands +X/+Z from the clicked cell); " ..
            "pressed by players and storage cubes",
        drawtype = "nodebox",
        paramtype = "light",
        paramtype2 = "facedir",
        sunlight_propagates = true,
        is_ground_content = false,
        inventory_image = "yaportal_superbutton_inv.png",
        wield_image = "yaportal_superbutton_inv.png",
        selection_box = {type = "fixed",
            fixed = {-0.5, -0.5, -0.5, 0.5, -2/16, 0.5}},
        sounds = block_sounds,
        on_place = superbutton_place,
        after_dig_node = superbutton_after_dig,
    }

    local up = table.copy(base)
    up.tiles = {"yaportal_button_top.png", "[fill:16x16:#3a3a3c",
                "yaportal_button_side.png"}
    up.node_box = {type = "fixed", fixed = boxes(cap_up)}
    up.groups = {cracky = 3, oddly_breakable_by_hand = 1}
    up.mesecons = signal_receptor("off")
    minetest.register_node("yaportal:superbutton", up)

    local dn = table.copy(base)
    dn.tiles = {"yaportal_button_top_pressed.png", "[fill:16x16:#3a3a3c",
                "yaportal_button_side_pressed.png"}
    dn.node_box = {type = "fixed", fixed = boxes(cap_dn)}
    dn.groups = {cracky = 3, oddly_breakable_by_hand = 1,
                 not_in_creative_inventory = 1}
    dn.drop = "yaportal:superbutton"
    dn.mesecons = signal_receptor("on")
    minetest.register_node("yaportal:superbutton_pressed", dn)
end

minetest.register_lbm({
    label = "Re-register super buttons",
    name = "yaportal:register_superbutton",
    nodenames = {"yaportal:superbutton", "yaportal:superbutton_pressed"},
    run_at_every_load = true,
    action = function(pos, node)
        local anchor = button_anchor(pos, node.param2)
        local h = hashpos(anchor)
        if not superbuttons[h] then
            -- A reloaded pressed button with nothing on it self-corrects on
            -- the first poll.
            superbuttons[h] = {pos = anchor,
                pressed = node.name == "yaportal:superbutton_pressed"}
        end
    end,
})

-- ── push button (momentary trigger) ─────────────
-- A small wall/floor/ceiling button: punching or right-clicking it pulses
-- its trigger active for ~1s.  Bindable from the vent/door/clock config
-- forms (binding kind "push"), e.g. vent start / stop / dispense.

local pushbuttons = {}  -- hash → {pos, until_t (us; pulse active while now < until_t)}

do
    local function push_entry(pos)
        local h = hashpos(pos)
        local e = pushbuttons[h]
        if not e then
            e = {pos = {x = pos.x, y = pos.y, z = pos.z}}
            pushbuttons[h] = e
        end
        return e
    end

    local function push_press(pos, node)
        push_entry(pos).until_t = minetest.get_us_time() + 1e6
        if node.name == "yaportal:pushbutton" then
            minetest.swap_node(pos,
                {name = "yaportal:pushbutton_pressed", param2 = node.param2})
        end
        minetest.after(1.0, function()
            local n = minetest.get_node(pos)
            if n.name == "yaportal:pushbutton_pressed" then
                minetest.swap_node(pos,
                    {name = "yaportal:pushbutton", param2 = n.param2})
            end
        end)
    end

    local base = {
        drawtype = "nodebox",
        paramtype = "light",
        paramtype2 = "wallmounted",
        sunlight_propagates = true,
        is_ground_content = false,
        walkable = false,
        selection_box = {type = "wallmounted",
            wall_side   = {-0.5, -0.1875, -0.1875, -0.3125, 0.1875, 0.1875},
            wall_bottom = {-0.1875, -0.5, -0.1875, 0.1875, -0.3125, 0.1875},
            wall_top    = {-0.1875, 0.3125, -0.1875, 0.1875, 0.5, 0.1875}},
        groups = {cracky = 3, oddly_breakable_by_hand = 1},
        sounds = block_sounds,
        drop = "yaportal:pushbutton",
        on_punch = function(pos, node) push_press(pos, node) end,
        on_rightclick = function(pos, node) push_press(pos, node) end,
        on_construct = function(pos) push_entry(pos) end,
        after_dig_node = function(pos) pushbuttons[hashpos(pos)] = nil end,
    }

    local up = table.copy(base)
    up.description = "Push Button\n" ..
        "Momentary trigger (~1s pulse on punch/right-click); link it in a " ..
        "vent, door or clock config, e.g. as start / stop / dispense"
    up.tiles = {"[fill:16x16:#c8c8cc^[fill:8x8:4,4:#c03434"}
    up.node_box = {type = "wallmounted",
        wall_side   = {-0.5, -0.1875, -0.1875, -0.375, 0.1875, 0.1875},
        wall_bottom = {-0.1875, -0.5, -0.1875, 0.1875, -0.375, 0.1875},
        wall_top    = {-0.1875, 0.375, -0.1875, 0.1875, 0.5, 0.1875}}
    minetest.register_node("yaportal:pushbutton", up)

    local dn = table.copy(base)
    dn.description = "Push Button (pressed)"
    dn.tiles = {"[fill:16x16:#a8a8ac^[fill:8x8:4,4:#701c1c"}
    dn.node_box = {type = "wallmounted",
        wall_side   = {-0.5, -0.1875, -0.1875, -0.4375, 0.1875, 0.1875},
        wall_bottom = {-0.1875, -0.5, -0.1875, 0.1875, -0.4375, 0.1875},
        wall_top    = {-0.1875, 0.4375, -0.1875, 0.1875, 0.5, 0.1875}}
    dn.groups = {cracky = 3, oddly_breakable_by_hand = 1,
                 not_in_creative_inventory = 1}
    minetest.register_node("yaportal:pushbutton_pressed", dn)
end

minetest.register_lbm({
    label = "Re-register push buttons",
    name = "yaportal:register_pushbutton",
    nodenames = {"yaportal:pushbutton", "yaportal:pushbutton_pressed"},
    run_at_every_load = true,
    action = function(pos, node)
        local h = hashpos(pos)
        if not pushbuttons[h] then
            pushbuttons[h] = {pos = {x = pos.x, y = pos.y, z = pos.z}}
        end
        -- A pressed button reloaded mid-pulse resets to idle.
        if node.name == "yaportal:pushbutton_pressed" then
            minetest.swap_node(pos,
                {name = "yaportal:pushbutton", param2 = node.param2})
        end
    end,
})

-- ── vital apparatus vent (2x2x2 dispenser) ─────────────

-- Same corner scheme as the super button: each quarter is registered with its
-- two outer walls toward -X/-Z and facedir param2 = BTN_P2 corner id; the
-- node name carries the layer (bottom = "yaportal:dispenser", top =
-- "yaportal:dispenser_top"), so the anchor (bottom min-X/Z quarter) is
-- arithmetic — no meta.  The 2x2 bottom is open: the cube spawns inside the
-- cavity and falls out of the opening.
local function vent_anchor(pos, name, param2)
    local off = BTN_ANCHOR_OFF[param2 % 4]
    return {x = pos.x + off.x,
            y = pos.y - (name:find("_top", 1, true) and 1 or 0),
            z = pos.z + off.z}
end

local function vent_cells(anchor)
    local out = {}
    for dy = 0, 1 do
        for dx = 0, 1 do
            for dz = 0, 1 do
                out[#out + 1] = {
                    pos = {x = anchor.x + dx, y = anchor.y + dy, z = anchor.z + dz},
                    name = dy == 0 and "yaportal:dispenser" or "yaportal:dispenser_top",
                    param2 = BTN_P2[dx][dz],
                }
            end
        end
    end
    return out
end

-- Destroy a cube with a Portal-style fizzle: a burst of cube-texture crumbs
-- plus a brief glowing flash at its position.
local function cube_fizzle(obj)
    local p = obj:get_pos()
    if p then
        minetest.add_particlespawner({
            amount = 36,
            time = 0.05,
            minpos = {x = p.x - 0.35, y = p.y - 0.35, z = p.z - 0.35},
            maxpos = {x = p.x + 0.35, y = p.y + 0.35, z = p.z + 0.35},
            minvel = {x = -1.5, y = 0.5, z = -1.5},
            maxvel = {x = 1.5, y = 2.5, z = 1.5},
            minacc = {x = 0, y = -6, z = 0},
            maxacc = {x = 0, y = -6, z = 0},
            minexptime = 0.35,
            maxexptime = 0.9,
            minsize = 1.2,
            maxsize = 2.6,
            texture = "yaportal_cube.png",
        })
        minetest.add_particle({
            pos = p,
            expirationtime = 0.25,
            size = 9,
            texture = "yaportal_cube.png^[colorize:#aef1ff:200",
            glow = 14,
        })
    end
    obj:remove()
end

local function dispense(anchor, h)
    -- The cube drops out of the open 2x2 bottom: all 4 cells below must be
    -- clear of walkable nodes.
    for dx = 0, 1 do
        for dz = 0, 1 do
            local below = {x = anchor.x + dx, y = anchor.y - 1, z = anchor.z + dz}
            local bdef = minetest.registered_nodes[minetest.get_node(below).name]
            if not bdef or bdef.walkable then return false end
        end
    end
    local center = {x = anchor.x + 0.5, y = anchor.y + 0.6, z = anchor.z + 0.5}
    -- The vent tracks its own cube: dispensing destroys the previous one so
    -- only the newest exists — no orphans, no runaway auto-respawn loops.
    -- (A previous cube beyond the scan radius or in an unloaded mapblock
    -- survives; same accepted edge case as the lost-cube detection.)
    local d = dispensers[h]
    if d and d.cube and d.cube:get_pos() then cube_fizzle(d.cube) end
    local scan = ((d and d.max_dist) or 16) + 16
    for _, obj in ipairs(minetest.get_objects_inside_radius(center, scan)) do
        local ent = obj:get_luaentity()
        if ent and ent.name == CUBE_ENTITY and ent._home == h then
            cube_fizzle(obj)
        end
    end
    local obj = minetest.add_entity(center, CUBE_ENTITY)
    if obj then
        local ent = obj:get_luaentity()
        if ent then ent._home = h end
        if d then d.cube = obj end
        return true
    end
    return false
end

local vent_open_config  -- forward decl (assigned in the vent-config closure)

local function vent_rightclick(pos, node, clicker)
    if not (clicker and clicker:is_player()) then return end
    local anchor = vent_anchor(pos, node.name, node.param2)
    if vent_open_config then vent_open_config(clicker, anchor) end
end

local function vent_after_dig(pos, oldnode)
    local anchor = vent_anchor(pos, oldnode.name, oldnode.param2)
    dispensers[hashpos(anchor)] = nil
    for _, c in ipairs(vent_cells(anchor)) do
        if not (c.pos.x == pos.x and c.pos.y == pos.y and c.pos.z == pos.z) then
            if minetest.get_node(c.pos).name:find("^yaportal:dispenser") then
                minetest.remove_node(c.pos)
            end
        end
    end
end

local function vent_place(itemstack, placer, pointed)
    if pointed.type ~= "node" then return itemstack end
    local pname = placer and placer:is_player() and placer:get_player_name() or ""
    local un = minetest.get_node(pointed.under)
    if placer and not placer:get_player_control().sneak then
        local ndef = minetest.registered_nodes[un.name]
        if ndef and ndef.on_rightclick then
            return ndef.on_rightclick(pointed.under, un, placer, itemstack, pointed) or itemstack
        end
    end
    -- Clicking a ceiling underside hangs the vent below it (the clicked free
    -- cell becomes the top layer); anything else builds upward.
    local anchor = {x = pointed.above.x, y = pointed.above.y, z = pointed.above.z}
    if pointed.under.y > pointed.above.y then anchor.y = anchor.y - 1 end
    local cells = vent_cells(anchor)
    for _, c in ipairs(cells) do
        local cdef = minetest.registered_nodes[minetest.get_node(c.pos).name]
        if not (cdef and cdef.buildable_to) then
            minetest.chat_send_player(pname,
                "The vent needs a free 2x2x2 volume " ..
                "(expands +X/+Z from the clicked cell).")
            return itemstack
        end
        if minetest.is_protected(c.pos, pname) then
            minetest.record_protection_violation(c.pos, pname)
            return itemstack
        end
    end
    for _, c in ipairs(cells) do
        minetest.set_node(c.pos, {name = c.name, param2 = c.param2})
    end
    dispensers[hashpos(anchor)] =
        {pos = anchor, empty_ticks = 0, enabled = true, bindings = {},
         max_dist = 16}
    if placer and not minetest.is_creative_enabled(pname) then
        itemstack:take_item()
    end
    return itemstack
end

do
    -- Quarter walls toward -X/-Z (the outer faces of the anchor corner);
    -- facedir rotates them outward on the other three corners.
    local vent_walls = {
        {-0.5, -0.5, -0.5, -0.375, 0.5,  0.5},
        {-0.5, -0.5, -0.5,  0.5,   0.5, -0.375},
    }

    local base = {
        drawtype = "nodebox",
        paramtype = "light",
        paramtype2 = "facedir",
        sunlight_propagates = true,
        is_ground_content = false,
        tiles = {"yaportal_vent_top.png", "[fill:16x16:#2a2a2c",
                 "yaportal_tube_side.png"},
        selection_box = {type = "fixed",
            fixed = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}},
        groups = {cracky = 3, oddly_breakable_by_hand = 1},
        sounds = block_sounds,
        drop = "yaportal:dispenser",
        on_rightclick = vent_rightclick,
        after_dig_node = vent_after_dig,
    }

    local bottom = table.copy(base)
    bottom.description = "Vital Apparatus Vent\n" ..
        "2x2x2 cube dispenser, open at the bottom (expands +X/+Z and " ..
        "upward from the clicked cell; hangs downward from a ceiling).\n" ..
        "While enabled it automatically replaces its cube when lost; " ..
        "dispensing destroys the previous cube.\n" ..
        "Right-click: settings (start/stop/dispense triggers, manual dispense)"
    bottom.inventory_image = "yaportal_tube_open.png"
    bottom.wield_image = "yaportal_tube_open.png"
    bottom.node_box = {type = "fixed", fixed = vent_walls}
    bottom.on_place = vent_place
    minetest.register_node("yaportal:dispenser", bottom)

    local top = table.copy(base)
    top.description = "Vital Apparatus Vent (top segment)"
    local top_boxes = table.copy(vent_walls)
    top_boxes[#top_boxes + 1] = {-0.5, 0.375, -0.5, 0.5, 0.5, 0.5}  -- cap
    top.node_box = {type = "fixed", fixed = top_boxes}
    top.groups = {cracky = 3, oddly_breakable_by_hand = 1,
                  not_in_creative_inventory = 1}
    minetest.register_node("yaportal:dispenser_top", top)
end

-- ── vent config (triggers + enable/disable) ──
-- Right-clicking any vent cell opens a settings form: an Enabled switch
-- (gates the lost-cube auto-respawn), a manual dispense button, and trigger
-- bindings à la door — "start"/"stop" flip the Enabled switch on the
-- trigger's rising edge, "dispense" drops a fresh cube (destroying the
-- previous one).  Config persists in the anchor node's meta ("disabled" int
-- + "triggers" JSON, so legacy vents without meta default to enabled).
-- Wrapped in a closure: the main chunk is near Lua's 200-local limit.
;(function()

local VENT_TRIG_MODES  = {"start", "stop", "dispense"}
local VENT_TRIG_LABELS = {"Start — enable the vent",
                          "Stop — disable the vent",
                          "Dispense — new cube on activation"}

local function vent_read_cfg(anchor)
    local meta = minetest.get_meta(anchor)
    local bindings = {}
    local raw  = meta:get_string("triggers")
    local list = raw ~= "" and minetest.parse_json(raw)
    if type(list) == "table" then
        for _, b in ipairs(list) do
            local m = (b.m == "stop" or b.m == "dispense") and b.m or "start"
            if (b.k == "button" or b.k == "push") and b.pos then
                bindings[#bindings + 1] = {k = b.k, m = m,
                    pos = {x = b.pos.x, y = b.pos.y, z = b.pos.z}}
            elseif b.k == "space" and b.id then
                bindings[#bindings + 1] = {k = "space", m = m, id = b.id}
            end
        end
    end
    local maxd = meta:get_int("max_dist")
    if maxd <= 0 then maxd = 16 end
    return meta:get_int("disabled") ~= 1, bindings, maxd
end

local function vent_write_cfg(anchor, enabled, bindings, maxd)
    local meta = minetest.get_meta(anchor)
    meta:set_int("disabled", enabled and 0 or 1)
    meta:set_int("max_dist", maxd or 16)
    local list = {}
    for _, b in ipairs(bindings or {}) do
        list[#list + 1] = {k = b.k, m = b.m, pos = b.pos, id = b.id}
    end
    meta:set_string("triggers", #list > 0 and minetest.write_json(list) or "")
    meta:set_string("infotext",
        "Vital Apparatus Vent" .. (enabled and "" or " (disabled)"))
end

local vent_form_ctx = {}  -- pname → {anchor, enabled, bindings, choices, sel}

local function vent_form_show(pname)
    local ctx = vent_form_ctx[pname]
    if not ctx then return end
    local T = rawget(_G, "yaportal") and yaportal.triggers

    local rows = {}
    for _, b in ipairs(ctx.bindings) do
        rows[#rows + 1] = minetest.formspec_escape(
            ((T and T.label(b)) or "?") .. " — " .. b.m)
    end
    local add_items = {"— add trigger —"}
    for _, c in ipairs(ctx.choices) do
        add_items[#add_items + 1] = minetest.formspec_escape(c.label)
    end

    minetest.show_formspec(pname, "yaportal:vent_config",
        "formspec_version[4]" ..
        "size[10,9.4]" ..
        "label[0.5,0.6;Configure Vital Apparatus Vent]" ..
        "label[0.5,1.25;Status: " ..
            (ctx.enabled and "ENABLED — auto-replaces its cube when lost"
                          or "DISABLED") .. "]" ..
        "button[0.5,1.6;2.5,0.8;enable_now;Enable]" ..
        "button[3.2,1.6;2.5,0.8;disable_now;Disable]" ..
        "button[5.9,1.6;3.6,0.8;dispense_now;Dispense cube now]" ..
        "label[0.5,2.9;Triggers (start / stop flip the status, dispense drops a cube):]" ..
        "textlist[0.5,3.2;9,2.2;trig_list;" ..
            table.concat(rows, ",") .. ";" .. (ctx.sel or 1) .. ";false]" ..
        "button[0.5,5.55;3,0.7;remove_trig;Remove selected]" ..
        "dropdown[0.5,6.55;5.1,0.8;trig_new;" ..
            table.concat(add_items, ",") .. ";1;true]" ..
        "dropdown[5.8,6.55;2.6,0.8;trig_mode;" ..
            table.concat(VENT_TRIG_LABELS, ",") .. ";1;true]" ..
        "button[8.6,6.55;0.9,0.8;add_trig;+]" ..
        "field[0.5,8.15;3,0.8;max_dist;Max cube distance (nodes);" ..
            tostring(ctx.max_dist or 16) .. "]" ..
        "field_close_on_enter[max_dist;false]" ..
        "button_exit[6,8.15;3.5,0.8;save_vent;Save]"
    )
end

vent_open_config = function(player, anchor)
    local pname = player:get_player_name()
    local d = dispensers[hashpos(anchor)]
    local enabled, bindings, maxd
    if d and d.bindings then
        enabled, bindings, maxd = d.enabled ~= false, d.bindings,
            d.max_dist or 16
    else
        enabled, bindings, maxd = vent_read_cfg(anchor)
    end
    -- Working copies: Add/Remove round-trips don't touch the vent until Save.
    local tb = {}
    for _, b in ipairs(bindings) do
        tb[#tb + 1] = {k = b.k, m = b.m, pos = b.pos, id = b.id}
    end
    local T = rawget(_G, "yaportal") and yaportal.triggers
    local center = {x = anchor.x + 0.5, y = anchor.y + 1, z = anchor.z + 0.5}
    vent_form_ctx[pname] = {anchor = anchor, enabled = enabled,
        bindings = tb, sel = 1, max_dist = maxd,
        choices = (T and T.list_near(center, 48)) or {}}
    vent_form_show(pname)
end

minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= "yaportal:vent_config" then return end
    local pname = player:get_player_name()
    local ctx = vent_form_ctx[pname]
    if not ctx then return end
    local anchor = ctx.anchor

    if minetest.is_protected(anchor, pname) then
        vent_form_ctx[pname] = nil
        return
    end

    -- Button re-renders resubmit the distance field: keep the latest valid
    -- value in the ctx.
    if fields.max_dist ~= nil then
        local n = tonumber(fields.max_dist)
        if n then ctx.max_dist = math.max(4, math.min(64, math.floor(n))) end
    end

    -- Enable/Disable apply immediately (runtime + meta), no Save needed.
    if fields.enable_now or fields.disable_now then
        local en = fields.enable_now ~= nil
        ctx.enabled = en
        local d = dispensers[hashpos(anchor)]
        local bnd = d and d.bindings
        local maxd = d and d.max_dist
        if not bnd then
            local _
            _, bnd, maxd = vent_read_cfg(anchor)
        end
        if d then d.enabled = en end
        vent_write_cfg(anchor, en, bnd, maxd or 16)
        vent_form_show(pname)
        return
    end

    if fields.trig_list then
        local ev = minetest.explode_textlist_event(fields.trig_list)
        if ev.type == "CHG" or ev.type == "DCL" then ctx.sel = ev.index end
    end

    if fields.add_trig then
        local idx  = tonumber(fields.trig_new or "1") or 1
        local midx = tonumber(fields.trig_mode or "1") or 1
        local c = (idx >= 2) and ctx.choices[idx - 1]
        if c then
            ctx.bindings[#ctx.bindings + 1] =
                {k = c.k, m = VENT_TRIG_MODES[midx] or "start",
                 pos = c.pos, id = c.id}
            ctx.sel = #ctx.bindings
        end
        vent_form_show(pname)
        return
    end

    if fields.remove_trig then
        if ctx.bindings[ctx.sel or 0] then
            table.remove(ctx.bindings, ctx.sel)
            if ctx.sel > #ctx.bindings then ctx.sel = math.max(#ctx.bindings, 1) end
        end
        vent_form_show(pname)
        return
    end

    if fields.dispense_now then
        if minetest.get_node(anchor).name == "yaportal:dispenser" then
            local h = hashpos(anchor)
            if dispense(anchor, h) then
                local d = dispensers[h]
                if d then d.empty_ticks = 0 end
            end
        end
        vent_form_show(pname)
        return
    end

    if fields.save_vent then
        vent_write_cfg(anchor, ctx.enabled == true, ctx.bindings,
            ctx.max_dist or 16)
        local d = dispensers[hashpos(anchor)]
        if d then
            d.enabled  = ctx.enabled == true
            d.max_dist = ctx.max_dist or 16
            -- Fresh copies: drop per-binding edge state.
            local tb = {}
            for _, b in ipairs(ctx.bindings) do
                tb[#tb + 1] = {k = b.k, m = b.m, pos = b.pos, id = b.id}
            end
            d.bindings = tb
        end
        vent_form_ctx[pname] = nil
        return
    end

    if fields.quit then vent_form_ctx[pname] = nil end
end)

minetest.register_lbm({
    label = "Re-register vital apparatus vents",
    name = "yaportal:register_dispenser",
    nodenames = {"yaportal:dispenser", "yaportal:dispenser_top"},
    run_at_every_load = true,
    action = function(pos, node)
        local anchor = vent_anchor(pos, node.name, node.param2)
        local h = hashpos(anchor)
        if not dispensers[h] then
            local enabled, bindings, maxd = vent_read_cfg(anchor)
            dispensers[h] = {pos = anchor, empty_ticks = 0,
                             enabled = enabled, bindings = bindings,
                             max_dist = maxd}
        end
    end,
})

-- Trigger polling (0.2s, matching the door cadence so space/button edges
-- aren't missed by the slow 2s dispenser tick).
local vent_trig_accum = 0
minetest.register_globalstep(function(dtime)
    vent_trig_accum = vent_trig_accum + dtime
    if vent_trig_accum < 0.2 then return end
    vent_trig_accum = 0
    local T = rawget(_G, "yaportal") and yaportal.triggers
    if not T then return end
    for h, d in pairs(dispensers) do
        if d.bindings and #d.bindings > 0 then
            for _, b in ipairs(d.bindings) do
                local act = T.active(b)
                if act and not b.prev then
                    if b.m == "dispense" then
                        if minetest.get_node(d.pos).name == "yaportal:dispenser"
                           and dispense(d.pos, h) then
                            d.empty_ticks = 0
                        end
                    else
                        local en = (b.m == "start")
                        if d.enabled ~= en then
                            d.enabled = en
                            vent_write_cfg(d.pos, en, d.bindings,
                                d.max_dist or 16)
                        end
                    end
                end
                b.prev = act
            end
        end
    end
end)

end)()  -- end vent-config closure

-- ── automatic door (2x2, Aperture style) ─────────────

-- Quarters live in the wall plane: bl/br bottom row, tl/tr top row, with the
-- big circular seam meeting at the door center.  facedir param2 is the plane
-- orientation only (0 = width along X, 1 = width along Z); the quarter id is
-- in the node name, so the bottom-left anchor is arithmetic — no meta.
-- DOOR_WDIR[p2] = world direction from the left to the right column (the
-- rotated +X axis; same engine yaw convention as BTN_P2 — verify in-game).
local DOOR_WDIR = {
    [0] = {x = 1, y = 0, z = 0}, [1] = {x = 0, y = 0, z = -1},
    [2] = {x = -1, y = 0, z = 0}, [3] = {x = 0, y = 0, z = 1},
}
local DOOR_Q = {
    bl = {right = false, top = false}, br = {right = true, top = false},
    tl = {right = false, top = true},  tr = {right = true, top = true},
}

-- Per-door config lives in the bottom-left cell's node metadata: a display
-- name, a "normally open" flag (the door's resting state is inverted), and the
-- hash of an explicitly linked super button (empty = the auto rule).  door_set
-- preserves this meta across the open/close name swap.
local open_door_config  -- forward decl (defined after the craftitem)

-- Door activation is a LIST of trigger bindings, meta "triggers" (JSON):
-- each {k = "button"|"space", m = "hold"|"open"|"close", pos = {x,y,z} (button)
-- | id = n (space)}.  hold = door activated while the trigger is active;
-- open/close = latch set/cleared on the trigger's rising edge (so a door can
-- open on space entry and close only from a button, ignoring the exit).
-- Empty list = auto rule.  Legacy single-trigger meta "button" (numeric hash
-- or "space:<id>") is migrated to one hold binding on read.
local function door_read_cfg(pos)
    local meta = minetest.get_meta(pos)
    local bindings = {}
    local raw  = meta:get_string("triggers")
    local list = raw ~= "" and minetest.parse_json(raw)
    if type(list) == "table" then
        for _, b in ipairs(list) do
            local m = (b.m == "open" or b.m == "close") and b.m or "hold"
            if (b.k == "button" or b.k == "push") and b.pos then
                bindings[#bindings + 1] = {k = b.k, m = m,
                    pos = {x = b.pos.x, y = b.pos.y, z = b.pos.z}}
            elseif b.k == "space" and b.id then
                bindings[#bindings + 1] = {k = "space", m = m, id = b.id}
            end
        end
    else
        local trig = meta:get_string("button")
        local sid  = trig:match("^space:(%d+)")
        if sid then
            bindings[1] = {k = "space", m = "hold", id = tonumber(sid)}
        elseif trig ~= "" and tonumber(trig) then
            bindings[1] = {k = "button", m = "hold",
                pos = minetest.get_position_from_hash(tonumber(trig))}
        end
    end
    return meta:get_string("name"),
           meta:get_int("normally_open") == 1,
           bindings
end

local function door_write_cfg(pos, name, normally_open, bindings)
    local meta = minetest.get_meta(pos)
    name = name or ""
    meta:set_string("name", name)
    meta:set_int("normally_open", normally_open and 1 or 0)
    local list = {}
    for _, b in ipairs(bindings or {}) do
        list[#list + 1] = {k = b.k, m = b.m, pos = b.pos, id = b.id}
    end
    meta:set_string("triggers", #list > 0 and minetest.write_json(list) or "")
    meta:set_string("button", "")  -- clear the legacy single-trigger slot
    meta:set_string("infotext",
        (name ~= "" and ("Door: " .. name .. "\n") or "") ..
        (normally_open and "Normally open" or "Normally closed"))
end

local function door_cells(bl, p2)
    local wd = DOOR_WDIR[p2 % 4]
    return {
        {q = "bl", pos = {x = bl.x, y = bl.y, z = bl.z}},
        {q = "br", pos = {x = bl.x + wd.x, y = bl.y, z = bl.z + wd.z}},
        {q = "tl", pos = {x = bl.x, y = bl.y + 1, z = bl.z}},
        {q = "tr", pos = {x = bl.x + wd.x, y = bl.y + 1, z = bl.z + wd.z}},
    }
end

local function door_bl_from(pos, name, param2)
    local q = name:match("^yaportal:door_(%a%a)")
    local info = q and DOOR_Q[q]
    if not info then return nil end
    local wd = DOOR_WDIR[param2 % 4]
    return {
        x = pos.x - (info.right and wd.x or 0),
        y = pos.y - (info.top and 1 or 0),
        z = pos.z - (info.right and wd.z or 0),
    }
end

local function door_set(entry, open)
    local suffix = open and "_open" or ""
    -- set_node wipes metadata; snapshot the bl cell's config and restore it.
    local blmeta = minetest.get_meta(entry.pos):to_table().fields
    for _, c in ipairs(door_cells(entry.pos, entry.p2)) do
        local want = "yaportal:door_" .. c.q .. suffix
        local n = minetest.get_node(c.pos)
        if n.name:find("^yaportal:door_") and n.name ~= want then
            minetest.set_node(c.pos, {name = want, param2 = entry.p2})
        end
    end
    minetest.get_meta(entry.pos):from_table({fields = blmeta})
    entry.open = open
end

local function door_power(pos, node, on)
    local bl = door_bl_from(pos, node.name, node.param2)
    if not bl then return end
    local h = hashpos(bl)
    local entry = doors[h]
    if not entry then
        local nm, no, tb = door_read_cfg(bl)
        entry = {pos = bl, p2 = node.param2 % 4,
                 open = node.name:find("_open") ~= nil, powered = false,
                 name = nm, normally_open = no, bindings = tb, latch = false}
        doors[h] = entry
    end
    entry.powered = on
end

local function door_effector()
    if not HAVE_MESECON then return nil end
    return {effector = {
        action_on = function(pos, node) door_power(pos, node, true) end,
        action_off = function(pos, node) door_power(pos, node, false) end,
        rules = mesecon.rules.default,
    }}
end

local function door_after_dig(pos, oldnode)
    local bl = door_bl_from(pos, oldnode.name, oldnode.param2)
    if not bl then return end
    doors[hashpos(bl)] = nil
    for _, c in ipairs(door_cells(bl, oldnode.param2 % 4)) do
        if not (c.pos.x == pos.x and c.pos.y == pos.y and c.pos.z == pos.z) then
            if minetest.get_node(c.pos).name:find("^yaportal:door_") then
                minetest.remove_node(c.pos)
            end
        end
    end
end

do
    local DOOR_EDGE = "[fill:16x16:#9a9a9e"
    for q, info in pairs(DOOR_Q) do
        local face = info.top and "yaportal_door_upper.png"
                              or "yaportal_door_lower.png"
        local facem = face .. "^[transformFX"
        -- Engine UV (generateCuboidTextureCoords): the -Z face maps u+ to +X,
        -- the +Z face maps u+ to -X, so front and back need mutually mirrored
        -- tiles: plain art (circle center at pixel x=15 = node +X) goes on -Z
        -- for the left column, and the right column uses the mirrored pair.
        local front, back  -- +Z tile, -Z tile
        if info.right then front, back = face, facem
        else front, back = facem, face end

        local base = {
            drawtype = "nodebox",
            paramtype = "light",
            paramtype2 = "facedir",
            sunlight_propagates = true,
            is_ground_content = false,
            tiles = {DOOR_EDGE, DOOR_EDGE, DOOR_EDGE, DOOR_EDGE, front, back},
            sounds = block_sounds,
            drop = "yaportal:door",
            after_dig_node = door_after_dig,
            mesecons = door_effector(),
            on_rightclick = function(pos, node, clicker)
                if not (clicker and clicker:is_player()) then return end
                local bl = door_bl_from(pos, node.name, node.param2)
                if not bl then return end
                local pname = clicker:get_player_name()
                if minetest.is_protected(bl, pname) then
                    minetest.record_protection_violation(bl, pname)
                    return
                end
                if open_door_config then
                    open_door_config(clicker, bl, node.param2 % 4)
                end
            end,
        }

        local closed = table.copy(base)
        closed.description = "Aperture Automatic Door (segment)"
        closed.node_box = {type = "fixed",
            fixed = {-0.5, -0.5, -1/16, 0.5, 0.5, 1/16}}
        closed.selection_box = closed.node_box
        closed.groups = {cracky = 3, oddly_breakable_by_hand = 1,
                         not_in_creative_inventory = 1}
        minetest.register_node("yaportal:door_" .. q, closed)

        -- Open: only a sliver toward the column's outer edge remains (the
        -- retracted leaf); the passage is clear.
        local sliver
        if info.right then sliver = {0.5 - 2/16, -0.5, -1/16, 0.5, 0.5, 1/16}
        else sliver = {-0.5, -0.5, -1/16, -0.5 + 2/16, 0.5, 1/16} end
        local open = table.copy(base)
        open.description = "Aperture Automatic Door (open segment)"
        open.node_box = {type = "fixed", fixed = sliver}
        open.selection_box = open.node_box
        open.groups = {cracky = 3, oddly_breakable_by_hand = 1,
                       not_in_creative_inventory = 1}
        minetest.register_node("yaportal:door_" .. q .. "_open", open)
    end
end

minetest.register_craftitem("yaportal:door", {
    description = "Aperture Automatic Door\n" ..
        "2 wide x 2 tall; opens on approach — or, with a super button within " ..
        "8 nodes, only while that button is pressed.\n" ..
        "Right-click a placed door to name it, set normally open/closed, or " ..
        "link activation triggers (buttons / trigger spaces, hold or " ..
        "open/close on edge).",
    inventory_image = "yaportal_door_inv.png",
    wield_image = "yaportal_door_inv.png",
    on_place = function(itemstack, placer, pointed)
        if pointed.type ~= "node" then return itemstack end
        local pname = placer and placer:is_player() and placer:get_player_name() or ""
        local un = minetest.get_node(pointed.under)
        if placer and not placer:get_player_control().sneak then
            local ndef = minetest.registered_nodes[un.name]
            if ndef and ndef.on_rightclick then
                return ndef.on_rightclick(pointed.under, un, placer, itemstack, pointed) or itemstack
            end
        end
        -- Plane orientation from the placer's view: looking mostly along X
        -- puts the passage along X, i.e. the width along Z.
        local p2 = 0
        if placer then
            local ld = placer:get_look_dir()
            if math.abs(ld.x) > math.abs(ld.z) then p2 = 1 end
        end
        local bl = pointed.above
        local cells = door_cells(bl, p2)
        for _, c in ipairs(cells) do
            local cdef = minetest.registered_nodes[minetest.get_node(c.pos).name]
            if not (cdef and cdef.buildable_to) then
                minetest.chat_send_player(pname,
                    "The door needs a free 2x2 area (upward from the clicked cell).")
                return itemstack
            end
            if minetest.is_protected(c.pos, pname) then
                minetest.record_protection_violation(c.pos, pname)
                return itemstack
            end
        end
        for _, c in ipairs(cells) do
            minetest.set_node(c.pos, {name = "yaportal:door_" .. c.q, param2 = p2})
        end
        door_write_cfg(bl, "", false, nil)  -- defaults: unnamed, normally closed, auto
        doors[hashpos(bl)] = {pos = {x = bl.x, y = bl.y, z = bl.z},
                              p2 = p2, open = false, powered = false,
                              name = "", normally_open = false,
                              bindings = {}, latch = false}
        if placer and not minetest.is_creative_enabled(pname) then
            itemstack:take_item()
        end
        return itemstack
    end,
})

minetest.register_lbm({
    label = "Re-register automatic doors",
    name = "yaportal:register_door",
    nodenames = {"yaportal:door_bl", "yaportal:door_bl_open"},
    run_at_every_load = true,
    action = function(pos, node)
        local h = hashpos(pos)
        if not doors[h] then
            local nm, no, tb = door_read_cfg(pos)
            local fm = minetest.get_meta(pos):get_int("forced")
            local forced
            if fm == 1 then forced = true elseif fm == 2 then forced = false end
            doors[h] = {pos = {x = pos.x, y = pos.y, z = pos.z},
                        p2 = node.param2 % 4,
                        open = node.name:find("_open") ~= nil, powered = false,
                        name = nm, normally_open = no,
                        bindings = tb, latch = false, forced = forced}
        end
    end,
})

-- ── door config menu ─────────────
-- Right-clicking any door quarter opens this form: set a name, choose the
-- resting state (normally open/closed), and link an activation super button
-- (or leave it on Auto).  The dropdown lists nearby buttons; the session ctx
-- maps the selected index back to the button's position hash.

local door_form_ctx = {}  -- pname → {bl, p2, name, normally_open, bindings, choices, sel}

local DOOR_TRIG_MODES  = {"hold", "open", "close"}
local DOOR_TRIG_LABELS = {"Hold — open while active",
                          "Open — on activation",
                          "Close — on activation"}

-- Render the form from the session ctx (working copy of the bindings, so
-- Add/Remove round-trips don't touch the door until Save).
local function door_form_show(pname)
    local ctx = door_form_ctx[pname]
    if not ctx then return end
    local T = rawget(_G, "yaportal") and yaportal.triggers

    local rows = {}
    for _, b in ipairs(ctx.bindings) do
        local lbl = (T and T.label(b)) or "?"
        rows[#rows + 1] = minetest.formspec_escape(lbl .. " — " .. b.m)
    end
    local add_items = {"— add trigger —"}
    for _, c in ipairs(ctx.choices) do
        add_items[#add_items + 1] = minetest.formspec_escape(c.label)
    end

    local fstate = "Auto (triggers / approach)"
    if ctx.forced == true then fstate = "FORCED OPEN"
    elseif ctx.forced == false then fstate = "FORCED CLOSED" end

    minetest.show_formspec(pname, "yaportal:door_config",
        "formspec_version[4]" ..
        "size[10,10.9]" ..
        "label[0.5,0.6;Configure Automatic Door]" ..
        "field[0.5,1.2;9,0.8;door_name;Name;" ..
            minetest.formspec_escape(ctx.name or "") .. "]" ..
        "checkbox[0.5,2.5;normally_open;Normally open (open at rest, activation closes);" ..
            (ctx.normally_open and "true" or "false") .. "]" ..
        "label[0.5,3.15;State: " .. fstate .. "]" ..
        "button[0.5,3.5;2.5,0.7;force_open;Open]" ..
        "button[3.2,3.5;2.5,0.7;force_close;Close]" ..
        "button[5.9,3.5;2.5,0.7;force_auto;Auto]" ..
        "label[0.5,4.55;Triggers (empty = auto: nearby button / approach):]" ..
        "textlist[0.5,4.85;9,2.2;trig_list;" ..
            table.concat(rows, ",") .. ";" .. (ctx.sel or 1) .. ";false]" ..
        "button[0.5,7.2;3,0.7;remove_trig;Remove selected]" ..
        "dropdown[0.5,8.2;5.1,0.8;trig_new;" ..
            table.concat(add_items, ",") .. ";1;true]" ..
        "dropdown[5.8,8.2;2.6,0.8;trig_mode;" ..
            table.concat(DOOR_TRIG_LABELS, ",") .. ";1;true]" ..
        "button[8.6,8.2;0.9,0.8;add_trig;+]" ..
        "button_exit[0.5,9.7;3.5,0.8;save_door;Save]" ..
        "button[4.5,9.7;4,0.8;delete_door;Remove door]"
    )
end

open_door_config = function(player, bl, p2)
    local pname = player:get_player_name()
    local name, normally_open, bindings = door_read_cfg(bl)

    local wd     = DOOR_WDIR[p2] or DOOR_WDIR[0]
    local center = {x = bl.x + wd.x * 0.5, y = bl.y + 0.5, z = bl.z + wd.z * 0.5}
    local T = rawget(_G, "yaportal") and yaportal.triggers

    local e = doors[hashpos(bl)]
    local forced
    if e then
        forced = e.forced
    else
        local fm = minetest.get_meta(bl):get_int("forced")
        if fm == 1 then forced = true elseif fm == 2 then forced = false end
    end
    door_form_ctx[pname] = {
        bl = bl, p2 = p2, name = name, normally_open = normally_open,
        bindings = bindings, sel = 1, forced = forced,
        choices = (T and T.list_near(center, 48)) or {},
    }
    door_form_show(pname)
end

minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= "yaportal:door_config" then return end
    local pname = player:get_player_name()
    local ctx   = door_form_ctx[pname]
    if not ctx then return end
    local bl = ctx.bl

    if minetest.is_protected(bl, pname) then
        door_form_ctx[pname] = nil
        return
    end

    -- Track the checkbox from its own toggle events: the Save submit does not
    -- reliably re-include an unchanged checkbox, so remember the last state.
    if fields.normally_open ~= nil then
        ctx.normally_open = (fields.normally_open == "true")
    end
    -- Same for the name field: Add/Remove re-render the form, so keep the
    -- latest typed value in the ctx.
    if fields.door_name ~= nil then ctx.name = fields.door_name end

    if fields.trig_list then
        local ev = minetest.explode_textlist_event(fields.trig_list)
        if ev.type == "CHG" or ev.type == "DCL" then ctx.sel = ev.index end
    end

    -- Open/Close/Auto apply immediately (runtime + meta), no Save needed;
    -- the 0.2s poll performs the actual node swap.
    if fields.force_open or fields.force_close or fields.force_auto then
        local forced
        if fields.force_open then forced = true
        elseif fields.force_close then forced = false end
        ctx.forced = forced
        local e = doors[hashpos(bl)]
        if e then e.forced = forced end
        minetest.get_meta(bl):set_int("forced",
            forced == true and 1 or forced == false and 2 or 0)
        door_form_show(pname)
        return
    end

    if fields.add_trig then
        local idx  = tonumber(fields.trig_new or "1") or 1
        local midx = tonumber(fields.trig_mode or "1") or 1
        local c = (idx >= 2) and ctx.choices[idx - 1]
        if c then
            ctx.bindings[#ctx.bindings + 1] =
                {k = c.k, m = DOOR_TRIG_MODES[midx] or "hold",
                 pos = c.pos, id = c.id}
            ctx.sel = #ctx.bindings
        end
        door_form_show(pname)
        return
    end

    if fields.remove_trig then
        if ctx.bindings[ctx.sel or 0] then
            table.remove(ctx.bindings, ctx.sel)
            if ctx.sel > #ctx.bindings then ctx.sel = math.max(#ctx.bindings, 1) end
        end
        door_form_show(pname)
        return
    end

    if fields.delete_door then
        local p2 = minetest.get_node(bl).param2 % 4
        doors[hashpos(bl)] = nil
        for _, c in ipairs(door_cells(bl, p2)) do
            if minetest.get_node(c.pos).name:find("^yaportal:door_") then
                minetest.remove_node(c.pos)
            end
        end
        minetest.add_item(bl, "yaportal:door")
        door_form_ctx[pname] = nil
        return
    end

    if fields.save_door then
        local nm = fields.door_name or ctx.name or ""
        local no = ctx.normally_open == true
        door_write_cfg(bl, nm, no, ctx.bindings)
        local e = doors[hashpos(bl)]
        if e then
            e.name, e.normally_open = nm, no
            -- Fresh copies: drop per-binding edge state and reset the latch.
            local tb = {}
            for _, b in ipairs(ctx.bindings) do
                tb[#tb + 1] = {k = b.k, m = b.m, pos = b.pos, id = b.id}
            end
            e.bindings, e.latch = tb, false
        end
        door_form_ctx[pname] = nil
        return
    end

    if fields.quit then door_form_ctx[pname] = nil end
end)

-- ── countdown clock ──────────────
-- A Portal-1 style timer block: half a cube tall, spanning 2 cells (its solid
-- body is inset, so it reads narrower than the full 2-wide footprint).  A
-- billboard display in front shows HH:MM:SS.CC on a 7-segment LCD.  Right-click
-- opens a menu to set the countdown and two portal effects (blue + orange,
-- each an absolute cell + face).  A mesecons signal starts the countdown; when
-- it reaches zero the linked gun4 portal pair is carved into the target walls,
-- exactly as if fired by the Portal Gun (Wall).

-- Wrapped in an immediately-invoked function so its many locals belong to this
-- closure, not the main chunk (which is near Lua's 200-local limit).
;(function()

local clocks_disp = {}   -- node hash → display objref (rebuilt on load, dig)
local clock_trig_open    -- forward decl (assigned in the trigger-space section)

-- Portal-name pair for a clock. The hash must be formatted as an integer:
-- plain concat prints it as a 14-digit float ("1.40743…e+14"), which both
-- truncates (nearby clocks could collide) and is unreadable in logs.
local function clock_portal_names(pos)
    local h = string.format("%.0f", hashpos(pos))
    return "clock_blue_" .. h, "clock_orange_" .. h
end

-- Face dropdown value → (axis, ns), matching portal_gun4_shoot's normal scheme
-- (axis 0 = ±Z faces, axis 1 = ±X faces, axis 2 = ±Y floor/ceiling).
local CLOCK_FACES = {"+Z", "-Z", "+X", "-X", "+Y", "-Y"}
local CLOCK_FACE  = {
    ["+Z"] = {axis = 0, ns =  1}, ["-Z"] = {axis = 0, ns = -1},
    ["+X"] = {axis = 1, ns =  1}, ["-X"] = {axis = 1, ns = -1},
    ["+Y"] = {axis = 2, ns =  1}, ["-Y"] = {axis = 2, ns = -1},
}

-- Front (display) direction per facedir, and the 2nd-cell (width) offset which
-- reuses DOOR_WDIR: p2 0 → +X width / +Z front, etc.
local CLOCK_FRONT = {
    [0] = {x = 0, y = 0, z = 1}, [1] = {x = 1, y = 0, z = 0},
    [2] = {x = 0, y = 0, z = -1}, [3] = {x = -1, y = 0, z = 0},
}

-- ── 7-segment display texture ──
-- Each glyph is drawn as filled rects composited with [combine.  Segment rects
-- (a,b,c,d,e,f,g) live in a 12×25 cell; colon/dot glyphs are 6 wide.
local CLOCK_SEG = {
    a = {3, 1, 6, 2}, b = {9, 2, 2, 9}, c = {9, 13, 2, 9}, d = {3, 22, 6, 2},
    e = {1, 13, 2, 9}, f = {1, 2, 2, 9}, g = {3, 11, 6, 2},
}
local CLOCK_DIG = {
    [0] = "abcdef", [1] = "bc", [2] = "abged", [3] = "abgcd", [4] = "fgbc",
    [5] = "afgcd", [6] = "afgecd", [7] = "abc", [8] = "abcdefg", [9] = "abcdfg",
}
local CLOCK_W, CLOCK_H = 114, 25
local CLOCK_LIT, CLOCK_OFF, CLOCK_BG = "#63d6e6", "#0d2a30", "#08171b"

local function clock_fill(L, x, y, w, h, color)
    L[#L + 1] = string.format("%d,%d=[fill\\:%dx%d\\:%s", x, y, w, h, color)
end

local function clock_glyph_digit(L, ox, dg)
    local on = CLOCK_DIG[dg] or ""
    for name, r in pairs(CLOCK_SEG) do
        local lit = on:find(name) ~= nil
        clock_fill(L, ox + r[1], r[2], r[3], r[4], lit and CLOCK_LIT or CLOCK_OFF)
    end
end

local function clock_glyph_colon(L, ox)
    clock_fill(L, ox + 2, 8, 3, 3, CLOCK_LIT)
    clock_fill(L, ox + 2, 16, 3, 3, CLOCK_LIT)
end

local function clock_glyph_dot(L, ox)
    clock_fill(L, ox + 2, 20, 3, 3, CLOCK_LIT)
end

-- total centiseconds → h,m,s,cs (hours capped at 99 for the 2-digit field)
local function clock_split(totalcs)
    totalcs = math.max(0, math.floor(totalcs))
    local cs = totalcs % 100; local t = math.floor(totalcs / 100)
    local s = t % 60; t = math.floor(t / 60)
    local m = t % 60; local h = math.floor(t / 60)
    if h > 99 then h = 99 end
    return h, m, s, cs
end

local function clock_texture(totalcs)
    local h, m, s, cs = clock_split(totalcs)
    local L = {}
    clock_fill(L, 0, 0, CLOCK_W, CLOCK_H, CLOCK_BG)
    local x = 0
    clock_glyph_digit(L, x, math.floor(h / 10)); x = x + 12
    clock_glyph_digit(L, x, h % 10);             x = x + 12
    clock_glyph_colon(L, x);                     x = x + 6
    clock_glyph_digit(L, x, math.floor(m / 10)); x = x + 12
    clock_glyph_digit(L, x, m % 10);             x = x + 12
    clock_glyph_colon(L, x);                     x = x + 6
    clock_glyph_digit(L, x, math.floor(s / 10)); x = x + 12
    clock_glyph_digit(L, x, s % 10);             x = x + 12
    clock_glyph_dot(L, x);                       x = x + 6
    clock_glyph_digit(L, x, math.floor(cs / 10)); x = x + 12
    clock_glyph_digit(L, x, cs % 10)
    return "[combine:" .. CLOCK_W .. "x" .. CLOCK_H .. ":" .. table.concat(L, ":")
end

-- ── portal effect (reuses the gun4 carve machinery) ──
-- Spec from a target cell + face: walls carve a 1×2 opening, floor/ceiling a
-- 2×1 opening along X.  A grid-aligned wall opening is tried first; when the
-- target wall is made of panel slabs the aligned footprint isn't carveable, so
-- the gun's half-offset variants (ou/ov = 0.5, opening shifted half a cell)
-- are probed as fallbacks — same pgun4_probe_ok gate as the gun (footprint
-- carveable + space in front of the opening clear).
-- Coordinates may carry a .5 fraction (half-block portal positions, wall
-- portals only): the fraction becomes the spec's ou/ov offset directly.
local function clock_portal_probe(x, y, z, face)
    local f = CLOCK_FACE[face]
    if not f then return nil end
    local function split_half(v)
        local b = math.floor(v)
        return b, (v - b >= 0.25) and 0.5 or 0
    end
    if f.axis == 2 then
        -- Floor/ceiling portals have no in-plane offsets: whole cells only.
        local spec = {cx = math.floor(x + 0.5), cy = math.floor(y + 0.5),
                      cz = math.floor(z + 0.5), axis = 2, ns = f.ns,
                      w = 2, h = 1, ou = 0, ov = 0, rot = 3}
        return pgun4_probe_ok(spec) and spec or nil
    end
    -- Wall: in-plane horizontal coord is X for axis 0, Z for axis 1; the
    -- perpendicular coord has no half-cell meaning and is rounded.
    local u0, uf = split_half((f.axis == 0) and x or z)
    local y0, vf = split_half(y)
    local wc = math.floor(((f.axis == 0) and z or x) + 0.5)
    local function mk(uc, ou, vc, ov)
        local spec = {cy = vc, axis = f.axis, ns = f.ns,
                      w = PGUN4_W, h = PGUN4_H, ou = ou, ov = ov, rot = 0}
        if f.axis == 0 then spec.cx, spec.cz = uc, wc
        else spec.cx, spec.cz = wc, uc end
        return spec
    end
    local cands
    if uf ~= 0 or vf ~= 0 then
        -- Explicit half-block position: carve exactly there, no fallbacks.
        cands = {mk(u0, uf, y0, vf)}
    else
        -- Preference order: aligned, vertical half-offset (opening starting at
        -- the target cell's mid, then half a cell below it), horizontal
        -- half-offset, then both offsets (quarter-carved corner cells).
        cands = {
            mk(u0, 0, y0, 0),
            mk(u0, 0, y0, 0.5),       mk(u0, 0, y0 - 1, 0.5),
            mk(u0, 0.5, y0, 0),       mk(u0 - 1, 0.5, y0, 0),
            mk(u0, 0.5, y0, 0.5),     mk(u0 - 1, 0.5, y0, 0.5),
            mk(u0, 0.5, y0 - 1, 0.5), mk(u0 - 1, 0.5, y0 - 1, 0.5),
        }
    end
    for _, spec in ipairs(cands) do
        if pgun4_probe_ok(spec) then return spec end
    end
    return nil
end

local function clock_portal_remove(portal_name)
    local pp = portals[portal_name]
    if not pp then return end
    local color = pp.color or "blue"
    local bnode = "yaportal:portal_wallblock_" .. color
    for i, c in ipairs(pgun4_cells(pp)) do
        local nn = minetest.get_node(c.pos).name
        if nn:sub(1, #bnode) == bnode then
            minetest.set_node(c.pos,
                {name = pp.saved and pp.saved[i] or PGUN4_WALL,
                 param2 = pp.saved_p2 and pp.saved_p2[i] or 0})
        end
    end
    local partner = pp.link
    portals[portal_name] = nil
    update_anchor(portal_name, nil)
    if partner and portals[partner] then
        portals[partner].link = nil
        pgun4_apply_state(partner)
    end
end

local function clock_portal_build(portal_name, color, spec)
    local bnode = "yaportal:portal_wallblock_" .. color
    local cells = pgun4_cells(spec)
    local saved, saved_p2 = {}, {}
    for i, c in ipairs(cells) do
        local node = minetest.get_node(c.pos)
        if not pgun4_cell_carveable(node, spec.axis, spec.ns, c.carve) then
            return false
        end
        saved[i] = node.name
        saved_p2[i] = node.param2
    end
    for i, c in ipairs(cells) do
        minetest.set_node(c.pos,
            {name = bnode .. pgun4_shell_mat(saved[i]) .. "_off", param2 = c.param2})
    end
    portals[portal_name] = {
        cx = spec.cx, cy = spec.cy, cz = spec.cz,
        axis = spec.axis, ns = spec.ns,
        w = spec.w, h = spec.h, rot = spec.rot or 0,
        ou = spec.ou or 0, ov = spec.ov or 0,
        kind = "block", color = color,
        node_name = bnode .. "_off", saved = saved, saved_p2 = saved_p2,
    }
    return true
end

-- Close (un-carve) this clock's portal pair, restoring the saved wall nodes.
local function clock_portals_close(pos)
    local bn, on = clock_portal_names(pos)
    clock_portal_remove(bn)
    clock_portal_remove(on)
    save_portals()
    sync_portals()
end

-- Fire the configured effect: carve the purple+yellow pair and link them.  Any
-- previously spawned pair for this clock is removed first.  (Clock portals use
-- their own frame colours so they read apart from the gun4 blue/orange pair.)
local function clock_fire(pos, pname)
    local meta = minetest.get_meta(pos)
    local bn, on = clock_portal_names(pos)
    clock_portal_remove(bn)
    clock_portal_remove(on)

    local bx, by, bz = meta:get_float("bx"), meta:get_float("by"), meta:get_float("bz")
    local ox, oy, oz = meta:get_float("ox"), meta:get_float("oy"), meta:get_float("oz")
    local bface = meta:get_string("bface")
    local oface = meta:get_string("oface")
    local bspec = bface ~= "" and clock_portal_probe(bx, by, bz, bface)
    local ospec = oface ~= "" and clock_portal_probe(ox, oy, oz, oface)

    local okb = bspec and clock_portal_build(bn, "purple", bspec)
    local oko = ospec and clock_portal_build(on, "yellow", ospec)
    if okb and oko then
        portals[bn].link = on
        portals[on].link = bn
    end
    if okb then pgun4_apply_state(bn); update_anchor(bn, portals[bn]) end
    if oko then pgun4_apply_state(on); update_anchor(on, portals[on]) end
    save_portals()
    sync_portals()

    -- Feedback: the "not carveable" cause is otherwise silent (mesecons trigger
    -- has no player), so report to the caller when we have one (Fire-now button).
    local function report(color, ok, x, y, z, face)
        if face == "" then return end
        if ok then
            if pname then minetest.chat_send_player(pname, string.format(
                "[clock] %s portal created at (%g,%g,%g) face %s", color, x, y, z, face)) end
        else
            local msg = string.format("[yaportal] clock %s portal: no room at " ..
                "(%g,%g,%g) face %s — needs carveable wall (a wall opening is " ..
                "1x2: that cell AND the one above it) with clear space in front",
                color, x, y, z, face)
            minetest.log("warning", msg)
            if pname then minetest.chat_send_player(pname, msg) end
        end
    end
    report("purple", okb, bx, by, bz, bface)
    report("yellow", oko, ox, oy, oz, oface)
    if okb and oko and pname then
        minetest.chat_send_player(pname, "[clock] purple+yellow linked.")
    end
end

-- ── display entity ──
-- A thin cube sprite fixed to the clock face (yaw set from the block's facedir,
-- NOT a billboard) so the digits stay parallel to the panel.  Owns the
-- countdown runtime (self._remcs / self._running).  static_save=false:
-- respawned + re-oriented by the LBM.
local CLOCK_TRANSP = "[fill:1x1:#00000000"
local function clock_faces(tex)
    -- node/entity face order {+Y,-Y,+X,-X,+Z,-Z}: put the display on the +Z
    -- (front) and -Z faces; the back copy is mirrored so it reads correctly.
    return {CLOCK_TRANSP, CLOCK_TRANSP, CLOCK_TRANSP, CLOCK_TRANSP,
            tex, tex .. "^[transformFX"}
end
minetest.register_entity("yaportal:clock_display", {
    initial_properties = {
        visual = "cube",
        visual_size = {x = 2.0, y = 2.0 * CLOCK_H / CLOCK_W, z = 0.05},
        textures = clock_faces(clock_texture(0)),
        physical = false, collide_with_objects = false,
        pointable = false, is_visible = true, static_save = false,
        glow = 14,
    },
    on_activate = function(self)
        self.object:set_armor_groups({immortal = 1})
        self._acc, self._chk = 0, 0
    end,
    _refresh = function(self, totalcs)
        local tex = clock_texture(totalcs)
        if tex ~= self._lasttex then
            self._lasttex = tex
            self.object:set_properties({textures = clock_faces(tex)})
        end
    end,
    on_step = function(self, dtime)
        -- die if the owning node is gone
        self._chk = self._chk + dtime
        if self._chk >= 1.0 then
            self._chk = 0
            if self._pos and minetest.get_node(self._pos).name ~= "yaportal:clock" then
                if self._chash then clocks_disp[self._chash] = nil end
                self.object:remove()
                return
            end
        end
        if self._running then
            self._remcs = (self._remcs or 0) - dtime * 100
            if self._remcs <= 0 then
                self._remcs = 0
                self._running = false
                self:_refresh(0)
                if self._pos then clock_fire(self._pos) end
                return
            end
            self._acc = self._acc + dtime
            if self._acc >= 0.03 then
                self._acc = 0
                self:_refresh(self._remcs)
            end
            return
        end
        -- idle: show the configured countdown, refreshed lazily
        self._acc = self._acc + dtime
        if self._acc >= 0.25 and self._pos then
            self._acc = 0
            self:_refresh(minetest.get_meta(self._pos):get_int("cd_cs"))
        end
    end,
})

-- Display world position: centred across the 2 cells, just in front of the
-- panel face (local z = -0.3), on the room side.
local function clock_disp_pos(pos, p2)
    local wd = DOOR_WDIR[p2] or DOOR_WDIR[0]
    local fr = CLOCK_FRONT[p2] or CLOCK_FRONT[0]
    return {x = pos.x + wd.x * 0.5 + fr.x * -0.27,
            y = pos.y,
            z = pos.z + wd.z * 0.5 + fr.z * -0.27}
end

local function clock_spawn_disp(pos)
    local h = hashpos(pos)
    local cur = clocks_disp[h]
    if cur and cur:get_luaentity() then return cur end
    local node = minetest.get_node(pos)
    local p2   = node.param2 % 4
    local obj  = minetest.add_entity(clock_disp_pos(pos, p2), "yaportal:clock_display")
    if obj then
        -- Fix yaw so the sprite's +Z face points along the block's front (N),
        -- keeping the digits parallel to the panel instead of billboarding.
        -- yaw_to_dir(θ) = (-sinθ, cosθ): +X front needs -π/2, -X front +π/2.
        local yaw = ({[0] = 0, [1] = -math.pi / 2,
                      [2] = math.pi, [3] = math.pi / 2})[p2] or 0
        obj:set_rotation({x = 0, y = yaw, z = 0})
        local ent = obj:get_luaentity()
        if ent then
            ent._pos = {x = pos.x, y = pos.y, z = pos.z}
            ent._chash = h
            ent:_refresh(minetest.get_meta(pos):get_int("cd_cs"))
        end
        clocks_disp[h] = obj
    end
    return obj
end

local function clock_start(pos)
    local obj = clock_spawn_disp(pos)
    local ent = obj and obj:get_luaentity()
    if not ent then return end
    ent._remcs = minetest.get_meta(pos):get_int("cd_cs")
    ent._running = ent._remcs > 0
    ent:_refresh(ent._remcs)
end

local function clock_stop(pos)
    local obj = clocks_disp[hashpos(pos)]
    local ent = obj and obj:get_luaentity()
    if not ent then return end
    ent._running = false
    ent:_refresh(minetest.get_meta(pos):get_int("cd_cs"))
end

-- ── node geometry / registration ──
local function clock_cells(pos, p2)
    local wd = DOOR_WDIR[p2] or DOOR_WDIR[0]
    return {{x = pos.x, y = pos.y, z = pos.z},
            {x = pos.x + wd.x, y = pos.y, z = pos.z + wd.z}}
end

local clock_open_config  -- forward decl

-- Left/body node box: extends toward the shared edge; right node mirrors it, so
-- the pair reads as one ~1.7-wide, half-tall inset panel.
-- Thin panel hugging the wall: back at local -Z (=-0.5, flush on the wall the
-- clock is mounted on), front face at -0.3 (protrudes 0.2 into the room).
local CLOCK_BOX_L = {-0.35, -0.25, -0.5, 0.5, 0.25, -0.3}
local CLOCK_BOX_R = {-0.5, -0.25, -0.5, 0.35, 0.25, -0.3}
local CLOCK_BODY  = "[fill:16x16:#20292c"
local CLOCK_BEZEL = "[fill:16x16:#0a1519"

local function clock_after_dig(pos, oldnode)
    local p2 = oldnode.param2 % 4
    local h  = hashpos(pos)
    if clocks_disp[h] then
        if clocks_disp[h]:get_luaentity() then clocks_disp[h]:remove() end
        clocks_disp[h] = nil
    end
    local bn, on = clock_portal_names(pos)
    clock_portal_remove(bn)
    clock_portal_remove(on)
    for _, c in ipairs(clock_cells(pos, p2)) do
        if not (c.x == pos.x and c.z == pos.z)
           and minetest.get_node(c).name == "yaportal:clock_r" then
            minetest.remove_node(c)
        end
    end
end

local clock_base = {
    drawtype = "nodebox",
    paramtype = "light",
    paramtype2 = "facedir",
    sunlight_propagates = true,
    is_ground_content = false,
    light_source = 6,
    tiles = {CLOCK_BODY, CLOCK_BODY, CLOCK_BODY, CLOCK_BODY, CLOCK_BEZEL, CLOCK_BEZEL},
    sounds = block_sounds,
    groups = {cracky = 2, oddly_breakable_by_hand = 1},
}

do
    local left = table.copy(clock_base)
    left.description = "Countdown Clock\n" ..
        "2 wide x 1/2 tall.  Right-click to set the countdown and portal " ..
        "effects; a mesecons signal or a linked trigger space starts the timer."
    left.node_box = {type = "fixed", fixed = CLOCK_BOX_L}
    left.selection_box = {type = "fixed", fixed = CLOCK_BOX_L}
    left.drop = "yaportal:clock_item"
    left.after_dig_node = clock_after_dig
    left.on_rightclick = function(pos, node, clicker)
        if not (clicker and clicker:is_player()) then return end
        local pname = clicker:get_player_name()
        if minetest.is_protected(pos, pname) then
            minetest.record_protection_violation(pos, pname)
            return
        end
        if clock_open_config then clock_open_config(clicker, pos) end
    end
    if HAVE_MESECON then
        left.mesecons = {effector = {
            action_on  = function(pos) clock_start(pos) end,
            action_off = function(pos) clock_stop(pos) end,
            rules = mesecon.rules.default,
        }}
    end
    minetest.register_node("yaportal:clock", left)

    local right = table.copy(clock_base)
    right.description = "Countdown Clock (segment)"
    right.node_box = {type = "fixed", fixed = CLOCK_BOX_R}
    right.selection_box = {type = "fixed", fixed = CLOCK_BOX_R}
    right.drop = ""   -- the item is dropped by after_dig below
    right.groups = {cracky = 2, oddly_breakable_by_hand = 1,
                    not_in_creative_inventory = 1}
    right.after_dig_node = function(pos, oldnode)
        -- digging the right half: remove the left half and drop one item
        local wd = DOOR_WDIR[oldnode.param2 % 4]
        local bl = {x = pos.x - wd.x, y = pos.y, z = pos.z - wd.z}
        if minetest.get_node(bl).name == "yaportal:clock" then
            minetest.remove_node(bl)
            clock_after_dig(bl, {name = "yaportal:clock", param2 = oldnode.param2})
        end
        minetest.add_item(pos, "yaportal:clock_item")
    end
    minetest.register_node("yaportal:clock_r", right)
end

minetest.register_node("yaportal:clock_item", {
    -- inventory item; on_place lays down the clock + clock_r pair
    description = "Countdown Clock",
    drawtype = "nodebox",
    paramtype = "light",
    paramtype2 = "facedir",
    tiles = {CLOCK_BODY, CLOCK_BODY, CLOCK_BODY, CLOCK_BODY, CLOCK_BEZEL, CLOCK_BEZEL},
    node_box = {type = "fixed", fixed = {-0.5, -0.25, -0.12, 0.5, 0.25, 0.12}},
    groups = {not_in_creative_inventory = 0},
    on_place = function(itemstack, placer, pointed)
        if pointed.type ~= "node" then return itemstack end
        local pname = placer and placer:is_player() and placer:get_player_name() or ""
        if placer and not placer:get_player_control().sneak then
            local un = minetest.get_node(pointed.under)
            local ndef = minetest.registered_nodes[un.name]
            if ndef and ndef.on_rightclick then
                return ndef.on_rightclick(pointed.under, un, placer, itemstack, pointed)
                    or itemstack
            end
        end
        -- Wall-mount: the front (display) faces out of the clicked wall into
        -- the room, so the panel sits flush against that wall; its width runs
        -- horizontally along the wall.  A floor/ceiling click falls back to
        -- facing the placer.
        local nx = pointed.above.x - pointed.under.x
        local nz = pointed.above.z - pointed.under.z
        local p2
        if nx ~= 0 or nz ~= 0 then
            if nz > 0 then p2 = 0            -- front +Z
            elseif nz < 0 then p2 = 2        -- front -Z
            elseif nx > 0 then p2 = 1        -- front +X
            else p2 = 3 end                  -- front -X
        else
            p2 = 0
            if placer then
                local ld = placer:get_look_dir()
                if math.abs(ld.x) > math.abs(ld.z) then
                    p2 = (ld.x > 0) and 3 or 1
                else
                    p2 = (ld.z > 0) and 2 or 0
                end
            end
        end
        local bl = pointed.above
        local cells = clock_cells(bl, p2)
        for _, c in ipairs(cells) do
            local cdef = minetest.registered_nodes[minetest.get_node(c).name]
            if not (cdef and cdef.buildable_to) then
                minetest.chat_send_player(pname,
                    "The clock needs a free 2-wide space.")
                return itemstack
            end
            if minetest.is_protected(c, pname) then
                minetest.record_protection_violation(c, pname)
                return itemstack
            end
        end
        minetest.set_node(cells[1], {name = "yaportal:clock", param2 = p2})
        minetest.set_node(cells[2], {name = "yaportal:clock_r", param2 = p2})
        clock_spawn_disp(cells[1])
        if placer and not minetest.is_creative_enabled(pname) then
            itemstack:take_item()
        end
        return itemstack
    end,
})

minetest.register_lbm({
    label = "Respawn countdown clock displays",
    name = "yaportal:clock_disp",
    nodenames = {"yaportal:clock"},
    run_at_every_load = true,
    action = function(pos) clock_spawn_disp(pos) end,
})

-- ── config menu ──
local clock_ctx = {}  -- pname → {pos, [trigger sub-form: bindings, choices, sel]}

clock_open_config = function(player, pos)
    local pname = player:get_player_name()
    local meta = minetest.get_meta(pos)
    local h, m, s, cs = clock_split(meta:get_int("cd_cs"))
    clock_ctx[pname] = {pos = {x = pos.x, y = pos.y, z = pos.z}}

    local function fsel(cur)
        for i, f in ipairs(CLOCK_FACES) do
            if f == cur then return i end
        end
        return 1
    end
    local faces = table.concat(CLOCK_FACES, ",")
    local bx, by, bz = meta:get_float("bx"), meta:get_float("by"), meta:get_float("bz")
    local ox, oy, oz = meta:get_float("ox"), meta:get_float("oy"), meta:get_float("oz")
    local bface = meta:get_string("bface"); if bface == "" then bface = "+Z" end
    local oface = meta:get_string("oface"); if oface == "" then oface = "+Z" end

    minetest.show_formspec(pname, "yaportal:clock_config",
        "formspec_version[4]" ..
        "size[11,9.2]" ..
        "label[0.5,0.6;Countdown Clock]" ..
        "label[0.5,1.2;Countdown  (H : M : S . CC)]" ..
        "field[0.5,1.5;1.6,0.8;cd_h;;" .. h .. "]" ..
        "field[2.3,1.5;1.6,0.8;cd_m;;" .. m .. "]" ..
        "field[4.1,1.5;1.6,0.8;cd_s;;" .. s .. "]" ..
        "field[5.9,1.5;1.6,0.8;cd_cs;;" .. cs .. "]" ..
        "button[7.7,1.5;2.8,0.8;trig;Triggers...]" ..
        "box[0.5,3.0;10,0.05;#4488aa]" ..
        "label[0.5,3.4;Purple portal  (bottom cell X / Y / Z + face\\; .5 = half-block offset\\; target must be Portal Wall Block)]" ..
        "field[0.5,3.7;2,0.8;bx;;" .. bx .. "]" ..
        "field[2.7,3.7;2,0.8;by;;" .. by .. "]" ..
        "field[4.9,3.7;2,0.8;bz;;" .. bz .. "]" ..
        "dropdown[7.1,3.7;2,0.8;bface;" .. faces .. ";" .. fsel(bface) .. "]" ..
        "label[0.5,5.0;Yellow portal  (bottom cell X / Y / Z + face\\; .5 = half-block offset\\; target must be Portal Wall Block)]" ..
        "field[0.5,5.3;2,0.8;ox;;" .. ox .. "]" ..
        "field[2.7,5.3;2,0.8;oy;;" .. oy .. "]" ..
        "field[4.9,5.3;2,0.8;oz;;" .. oz .. "]" ..
        "dropdown[7.1,5.3;2,0.8;oface;" .. faces .. ";" .. fsel(oface) .. "]" ..
        "box[0.5,6.6;10,0.05;#4488aa]" ..
        "button_exit[0.5,7.0;2.4,0.8;save;Save]" ..
        "button[3.1,7.0;2.4,0.8;start;Start]" ..
        "button[5.7,7.0;2.4,0.8;stop;Stop / Reset]" ..
        "button[8.3,7.0;2.2,0.8;fire;Fire now]" ..
        "button[0.5,8.0;3,0.8;close;Close portals]"
    )
end

local function clock_field_int(fields, key, fallback)
    local v = fields[key]
    return v and math.floor(tonumber(v) or fallback) or fallback
end

-- Portal coordinates accept half-block positions: snap to the nearest 0.5.
local function clock_field_coord(fields, key, fallback)
    local v = tonumber(fields[key] or "")
    if not v then return fallback end
    return math.floor(v * 2 + 0.5) / 2
end

minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= "yaportal:clock_config" then return end
    local pname = player:get_player_name()
    local ctx   = clock_ctx[pname]
    if not ctx then return end
    local pos = ctx.pos
    if minetest.is_protected(pos, pname) then clock_ctx[pname] = nil; return end
    local meta = minetest.get_meta(pos)

    -- Persist config on any submit that carries the fields (Save/Start/Fire).
    if fields.save or fields.start or fields.fire then
        local h  = math.max(0, clock_field_int(fields, "cd_h", 0))
        local m  = math.max(0, clock_field_int(fields, "cd_m", 0))
        local s  = math.max(0, clock_field_int(fields, "cd_s", 0))
        local cs = math.max(0, clock_field_int(fields, "cd_cs", 0))
        local total = ((h * 60 + m) * 60 + s) * 100 + cs
        meta:set_int("cd_cs", total)

        local function face(key)
            local v = fields[key]
            return (v and CLOCK_FACE[v]) and v or "+Z"
        end
        meta:set_float("bx", clock_field_coord(fields, "bx", 0))
        meta:set_float("by", clock_field_coord(fields, "by", 0))
        meta:set_float("bz", clock_field_coord(fields, "bz", 0))
        meta:set_string("bface", face("bface"))
        meta:set_float("ox", clock_field_coord(fields, "ox", 0))
        meta:set_float("oy", clock_field_coord(fields, "oy", 0))
        meta:set_float("oz", clock_field_coord(fields, "oz", 0))
        meta:set_string("oface", face("oface"))
        meta:set_string("infotext",
            string.format("Countdown %02d:%02d:%02d.%02d", h, m, s, cs))
        clock_stop(pos)  -- refresh idle display to the new value
    end

    if fields.trig then
        if clock_trig_open then clock_trig_open(player, pos) end
        return
    end
    if fields.start then clock_start(pos) end
    if fields.stop then clock_stop(pos) end
    if fields.fire then clock_fire(pos, pname) end
    if fields.close then
        clock_portals_close(pos)
        minetest.chat_send_player(pname, "[clock] portals closed.")
    end
    if fields.quit or fields.save then clock_ctx[pname] = nil end
end)

-- ── trigger spaces ───────────────
-- A wand defines named cuboid volumes ("trigger spaces") from two corner
-- nodes.  A space holds no behaviour of its own: objects use spaces as
-- activation triggers — an automatic door lists nearby spaces in its config
-- next to the super buttons (activated while someone is inside), and a clock
-- can start its countdown on space entry.  Punch a node to pick corners or to
-- edit the space containing it; click into the air for the wand menu
-- (outline visibility, cancel a pending corner, list/edit/delete spaces).
--
-- This section lives inside the clock closure on purpose: it needs
-- clock_start / clocks_disp (closure locals), and the main chunk is at Lua's
-- 200-local limit so nothing new can be exported through it.  Consumers
-- outside the closure (door config + stepper) reach the registry through the
-- yaportal.tspaces global API below.

local spaces = {}          -- id → {id, name, min, max, occupied}
local ts_next_id = 1
local ts_visible = storage:get_int("ts_visible") == 1
local ts_corner = {}       -- pname → first-corner node pos
local ts_form_ctx = {}     -- pname → {id} (space form) | {ids, sel} (wand form)

local function ts_save()
    local list = {}
    for _, sp in pairs(spaces) do
        list[#list + 1] = {id = sp.id, name = sp.name,
                           min = sp.min, max = sp.max}
    end
    storage:set_string("trigger_spaces", minetest.write_json(list))
end

do
    local raw = storage:get_string("trigger_spaces")
    local list = raw ~= "" and minetest.parse_json(raw)
    if type(list) == "table" then
        for _, sp in ipairs(list) do
            if sp.id and sp.min and sp.max then
                spaces[sp.id] = {id = sp.id, name = sp.name,
                                 min = sp.min, max = sp.max}
                if sp.id >= ts_next_id then ts_next_id = sp.id + 1 end
            end
        end
    end
end

local function ts_center(sp)
    return {x = (sp.min.x + sp.max.x) / 2, y = (sp.min.y + sp.max.y) / 2,
            z = (sp.min.z + sp.max.z) / 2}
end

-- Point (e.g. player feet) inside the space's world box: node coords span
-- their full cell, so the box extends 0.5 past the corner node centers.
local function ts_contains(sp, p)
    return p.x >= sp.min.x - 0.5 and p.x <= sp.max.x + 0.5
       and p.y >= sp.min.y - 0.5 and p.y <= sp.max.y + 0.5
       and p.z >= sp.min.z - 0.5 and p.z <= sp.max.z + 0.5
end

-- Public API for trigger consumers outside this closure (door config and
-- stepper).  rawset/rawget bypass the engine's strict-mode global warning.
do
    local api = {
        get = function(id) return spaces[id] end,
        occupied = function(id)
            local sp = spaces[id]
            return sp ~= nil and sp.occupied == true
        end,
        -- Spaces within `r` of `center`, sorted by distance:
        -- {id, name, center, d} each.
        list_near = function(center, r)
            local out = {}
            for _, sp in pairs(spaces) do
                local c = ts_center(sp)
                local d = vector.distance(c, center)
                if d <= r then
                    out[#out + 1] = {id = sp.id, name = sp.name or "?",
                                     center = c, d = d}
                end
            end
            table.sort(out, function(a, b) return a.d < b.d end)
            return out
        end,
    }
    -- Trigger bindings: the shared {k = "button"|"space", pos|id} shape used
    -- by doors and clocks.  active() = current level (pressed / occupied);
    -- consumers derive edges themselves.
    local trig = {
        active = function(b)
            if b.k == "button" and b.pos then
                local sb = superbuttons[hashpos(b.pos)]
                return sb ~= nil and sb.pressed == true
            elseif b.k == "push" and b.pos then
                local pb = pushbuttons[hashpos(b.pos)]
                return pb ~= nil and pb.until_t ~= nil
                   and minetest.get_us_time() < pb.until_t
            elseif b.k == "space" and b.id then
                local sp = spaces[b.id]
                return sp ~= nil and sp.occupied == true
            end
            return false
        end,
        label = function(b)
            if b.k == "button" and b.pos then
                return string.format("Button (%d,%d,%d)",
                    b.pos.x, b.pos.y, b.pos.z)
            elseif b.k == "push" and b.pos then
                return string.format("Push button (%d,%d,%d)",
                    b.pos.x, b.pos.y, b.pos.z)
            elseif b.k == "space" and b.id then
                local sp = spaces[b.id]
                return sp and ("Space '" .. (sp.name or "?") .. "'")
                          or ("Space #" .. b.id .. " (deleted)")
            end
            return "?"
        end,
        -- Buttons and spaces within `r` of `center`, sorted by distance:
        -- {k, pos|id, d, label} each — ready to become bindings.
        list_near = function(center, r)
            local out = {}
            for _, sb in pairs(superbuttons) do
                local c = {x = sb.pos.x + 0.5, y = sb.pos.y, z = sb.pos.z + 0.5}
                local d = vector.distance(c, center)
                if d <= r then
                    out[#out + 1] = {k = "button", d = d,
                        pos = {x = sb.pos.x, y = sb.pos.y, z = sb.pos.z},
                        label = string.format("Button (%d,%d,%d) — %.1fm",
                            sb.pos.x, sb.pos.y, sb.pos.z, d)}
                end
            end
            for _, pb in pairs(pushbuttons) do
                local d = vector.distance(pb.pos, center)
                if d <= r then
                    out[#out + 1] = {k = "push", d = d,
                        pos = {x = pb.pos.x, y = pb.pos.y, z = pb.pos.z},
                        label = string.format("Push button (%d,%d,%d) — %.1fm",
                            pb.pos.x, pb.pos.y, pb.pos.z, d)}
                end
            end
            for _, sp in pairs(spaces) do
                local d = vector.distance(ts_center(sp), center)
                if d <= r then
                    out[#out + 1] = {k = "space", id = sp.id, d = d,
                        label = string.format("Space '%s' — %.1fm",
                            sp.name or "?", d)}
                end
            end
            table.sort(out, function(a, b) return a.d < b.d end)
            return out
        end,
    }
    local ns = rawget(_G, "yaportal") or {}
    ns.tspaces = api
    ns.triggers = trig
    rawset(_G, "yaportal", ns)
end

-- Smallest space whose box contains the node — punching a node inside nested
-- spaces edits the most specific one.
local function ts_find_at(npos)
    local best, bestvol
    for _, sp in pairs(spaces) do
        if npos.x >= sp.min.x and npos.x <= sp.max.x
           and npos.y >= sp.min.y and npos.y <= sp.max.y
           and npos.z >= sp.min.z and npos.z <= sp.max.z then
            local vol = (sp.max.x - sp.min.x + 1) * (sp.max.y - sp.min.y + 1)
                      * (sp.max.z - sp.min.z + 1)
            if not best or vol < bestvol then best, bestvol = sp, vol end
        end
    end
    return best
end

-- ── outline particles ──
local function ts_box_particles(minp, maxp, color, pstep)
    local lo = {x = minp.x - 0.5, y = minp.y - 0.5, z = minp.z - 0.5}
    local hi = {x = maxp.x + 0.5, y = maxp.y + 0.5, z = maxp.z + 0.5}
    local function line(from, axis, len)
        local n = math.max(1, math.ceil(len / pstep))
        for i = 0, n do
            local p = {x = from.x, y = from.y, z = from.z}
            p[axis] = p[axis] + len * i / n
            minetest.add_particle({
                pos = p, expirationtime = 1.2, size = 1.5,
                texture = "[fill:8x8:" .. color, glow = 14,
            })
        end
    end
    for _, y in ipairs({lo.y, hi.y}) do
        for _, z in ipairs({lo.z, hi.z}) do
            line({x = lo.x, y = y, z = z}, "x", hi.x - lo.x)
        end
        for _, x in ipairs({lo.x, hi.x}) do
            line({x = x, y = y, z = lo.z}, "z", hi.z - lo.z)
        end
    end
    for _, x in ipairs({lo.x, hi.x}) do
        for _, z in ipairs({lo.z, hi.z}) do
            line({x = x, y = lo.y, z = z}, "y", hi.y - lo.y)
        end
    end
end

local function ts_player_near(center, dist)
    for _, pl in ipairs(minetest.get_connected_players()) do
        if vector.distance(pl:get_pos(), center) <= dist then return true end
    end
    return false
end

local function ts_draw_outlines()
    if ts_visible then
        for _, sp in pairs(spaces) do
            local c = ts_center(sp)
            if ts_player_near(c, 96) then
                local maxdim = math.max(sp.max.x - sp.min.x,
                                        sp.max.y - sp.min.y,
                                        sp.max.z - sp.min.z) + 1
                local pstep = math.max(0.75, maxdim / 24)
                ts_box_particles(sp.min, sp.max,
                    sp.occupied and "#ff5533" or "#00ff88", pstep)
            end
        end
    end
    -- Pending first corners always show, so the builder can see the pick.
    for _, c in pairs(ts_corner) do
        ts_box_particles(c, c, "#ffaa00", 0.5)
    end
end

-- ── formspecs ──
local function ts_open_space_form(player, sp)
    local pname = player:get_player_name()
    ts_form_ctx[pname] = {id = sp.id}
    minetest.show_formspec(pname, "yaportal:ts_space",
        "formspec_version[4]" ..
        "size[10,5.4]" ..
        "label[0.5,0.6;Trigger Space]" ..
        "label[0.5,1.15;" .. minetest.formspec_escape(string.format(
            "From (%d,%d,%d) to (%d,%d,%d)",
            sp.min.x, sp.min.y, sp.min.z, sp.max.x, sp.max.y, sp.max.z)) .. "]" ..
        "field[0.5,1.8;9,0.8;sp_name;Name;" ..
            minetest.formspec_escape(sp.name or "") .. "]" ..
        "label[0.5,3.2;Link it from an object's config (door\\, clock): the]" ..
        "label[0.5,3.6;space appears there as a trigger\\, like a button.]" ..
        "button_exit[0.5,4.2;3.5,0.8;save_sp;Save]" ..
        "button_exit[4.5,4.2;4,0.8;delete_sp;Delete space]"
    )
end

local function ts_open_wand_form(player)
    local pname = player:get_player_name()
    local ids, rows = {}, {}
    for id, sp in pairs(spaces) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local sp = spaces[id]
        rows[#rows + 1] = minetest.formspec_escape(string.format(
            "%s  (%d,%d,%d)..(%d,%d,%d)", sp.name or "?",
            sp.min.x, sp.min.y, sp.min.z, sp.max.x, sp.max.y, sp.max.z))
    end
    local ctx = ts_form_ctx[pname]
    local sel = (ctx and ctx.ids and ctx.sel) or 1
    if sel > #ids then sel = #ids end
    ts_form_ctx[pname] = {ids = ids, sel = sel}

    local pending = ts_corner[pname]
    local fs =
        "formspec_version[4]" ..
        "size[11,8.6]" ..
        "label[0.5,0.6;Trigger Spaces]" ..
        "checkbox[0.5,1.3;ts_show;Show space outlines;" ..
            (ts_visible and "true" or "false") .. "]"
    if pending then
        fs = fs ..
            "label[0.5,2.0;" .. minetest.formspec_escape(string.format(
                "Creating: first corner at (%d,%d,%d) — punch the opposite corner",
                pending.x, pending.y, pending.z)) .. "]" ..
            "button[0.5,2.35;4.5,0.7;ts_cancel;Cancel space creation]"
    else
        fs = fs .. "label[0.5,2.2;Punch two corner nodes to create a space.]"
    end
    fs = fs ..
        "label[0.5,3.4;Spaces:]" ..
        "textlist[0.5,3.7;10,3.2;ts_list;" ..
            (#rows > 0 and table.concat(rows, ",") or "") .. ";" ..
            math.max(sel, 1) .. ";false]" ..
        "button[0.5,7.3;3,0.8;ts_edit;Edit selected]" ..
        "button[3.8,7.3;3,0.8;ts_delete;Delete selected]" ..
        "button_exit[7.5,7.3;3,0.8;ts_close;Close]"
    minetest.show_formspec(pname, "yaportal:ts_wand", fs)
end

minetest.register_on_player_receive_fields(function(player, formname, fields)
    local pname = player:get_player_name()

    if formname == "yaportal:ts_space" then
        local ctx = ts_form_ctx[pname]
        if not ctx or not ctx.id then return end
        local sp = spaces[ctx.id]
        if not sp then ts_form_ctx[pname] = nil; return end

        if fields.delete_sp then
            spaces[ctx.id] = nil
            ts_save()
            minetest.chat_send_player(pname,
                "[wand] space '" .. (sp.name or "?") .. "' deleted.")
            ts_form_ctx[pname] = nil
            return
        end
        if fields.save_sp then
            if fields.sp_name and fields.sp_name ~= "" then
                sp.name = fields.sp_name
            end
            ts_save()
            minetest.chat_send_player(pname,
                "[wand] space '" .. sp.name .. "' saved.")
            ts_form_ctx[pname] = nil
            return
        end
        if fields.quit then ts_form_ctx[pname] = nil end
        return
    end

    if formname ~= "yaportal:ts_wand" then return end
    local ctx = ts_form_ctx[pname]

    if fields.ts_show ~= nil then
        ts_visible = (fields.ts_show == "true")
        storage:set_int("ts_visible", ts_visible and 1 or 0)
    end
    if fields.ts_cancel then
        ts_corner[pname] = nil
        ts_open_wand_form(player)
        return
    end
    if fields.ts_list and ctx then
        local ev = minetest.explode_textlist_event(fields.ts_list)
        if ev.type == "CHG" or ev.type == "DCL" then
            ctx.sel = ev.index
            if ev.type == "DCL" then
                local sp = ctx.ids and spaces[ctx.ids[ev.index]]
                if sp then ts_open_space_form(player, sp) end
                return
            end
        end
    end
    if fields.ts_edit and ctx and ctx.ids then
        local sp = spaces[ctx.ids[ctx.sel or 1]]
        if sp then ts_open_space_form(player, sp) end
        return
    end
    if fields.ts_delete and ctx and ctx.ids then
        local id = ctx.ids[ctx.sel or 1]
        if id and spaces[id] then
            minetest.chat_send_player(pname,
                "[wand] space '" .. (spaces[id].name or "?") .. "' deleted.")
            spaces[id] = nil
            ts_save()
        end
        ts_open_wand_form(player)
        return
    end
    if fields.quit or fields.ts_close then
        ts_form_ctx[pname] = nil
    end
end)

-- ── wand tool ──
local function ts_punch_node(player, npos)
    local pname = player:get_player_name()
    local c1 = ts_corner[pname]
    if c1 then
        ts_corner[pname] = nil
        local sp = {
            id = ts_next_id,
            name = "Space " .. ts_next_id,
            min = {x = math.min(c1.x, npos.x), y = math.min(c1.y, npos.y),
                   z = math.min(c1.z, npos.z)},
            max = {x = math.max(c1.x, npos.x), y = math.max(c1.y, npos.y),
                   z = math.max(c1.z, npos.z)},
        }
        ts_next_id = ts_next_id + 1
        spaces[sp.id] = sp
        ts_save()
        ts_open_space_form(player, sp)
        return
    end
    -- No pending corner: a punch inside an existing space edits it; sneak
    -- forces corner picking (to start a space nested in another).
    local sp = not player:get_player_control().sneak and ts_find_at(npos)
    if sp then
        ts_open_space_form(player, sp)
        return
    end
    ts_corner[pname] = {x = npos.x, y = npos.y, z = npos.z}
    ts_box_particles(npos, npos, "#ffaa00", 0.5)
    minetest.chat_send_player(pname, string.format(
        "[wand] first corner (%d,%d,%d) — punch the opposite corner.",
        npos.x, npos.y, npos.z))
end

minetest.register_tool("yaportal:trigger_wand", {
    description = "Trigger Space Wand\n" ..
        "Punch two nodes to define a named cuboid trigger space.  Objects " ..
        "use spaces like buttons: a door or clock config lists nearby " ..
        "spaces as activation triggers.\n" ..
        "Punch a node inside a space to edit it (sneak-punch to start a new " ..
        "corner instead); click into the air for the menu (outlines, cancel, " ..
        "space list).",
    inventory_image = "yaportal_gun.png^[colorize:#ffcc00:140",
    range = 20,
    on_use = function(itemstack, user, pointed)
        if not (user and user:is_player()) then return itemstack end
        if pointed and pointed.type == "node" then
            ts_punch_node(user, pointed.under)
        elseif not pointed or pointed.type == "nothing" then
            ts_open_wand_form(user)
        end
        return itemstack
    end,
    on_secondary_use = function(itemstack, user)
        if user and user:is_player() then ts_open_wand_form(user) end
        return itemstack
    end,
    on_place = function(itemstack, placer, pointed)
        if placer and placer:is_player() then ts_open_wand_form(placer) end
        return itemstack
    end,
})

-- ── clock trigger bindings ──
-- Meta "triggers" (JSON list of {k, pos|id, m = "start"|"stop"|"close"}):
-- each fires on its trigger's rising edge — start begins the countdown (if
-- idle), stop resets it, close removes the clock's carved portal pair.
-- Legacy single-space meta "tspace" is migrated on read.
local function clock_read_trig(pos)
    local meta = minetest.get_meta(pos)
    local out = {}
    local raw  = meta:get_string("triggers")
    local list = raw ~= "" and minetest.parse_json(raw)
    if type(list) == "table" then
        for _, b in ipairs(list) do
            local m = (b.m == "stop" or b.m == "close") and b.m or "start"
            if (b.k == "button" or b.k == "push") and b.pos then
                out[#out + 1] = {k = b.k, m = m,
                    pos = {x = b.pos.x, y = b.pos.y, z = b.pos.z}}
            elseif b.k == "space" and b.id then
                out[#out + 1] = {k = "space", m = m, id = b.id}
            end
        end
    elseif meta:get_int("tspace") > 0 then
        out[1] = {k = "space", m = "start", id = meta:get_int("tspace")}
    end
    return out
end

local function clock_write_trig(pos, bindings)
    local meta = minetest.get_meta(pos)
    local list = {}
    for _, b in ipairs(bindings or {}) do
        list[#list + 1] = {k = b.k, m = b.m, pos = b.pos, id = b.id}
    end
    meta:set_string("triggers", #list > 0 and minetest.write_json(list) or "")
    meta:set_int("tspace", 0)  -- clear the legacy slot
end

-- Trigger sub-form for the clock config ("Triggers..." button): same list UI
-- as the door's, with start/stop modes.
local CLOCK_TRIG_MODES  = {"start", "stop", "close"}
local CLOCK_TRIG_LABELS = {"Start countdown", "Stop countdown", "Close portals"}

local function clock_trig_show(pname)
    local ctx = clock_ctx[pname]
    if not (ctx and ctx.bindings) then return end
    local T = yaportal.triggers
    local rows = {}
    for _, b in ipairs(ctx.bindings) do
        rows[#rows + 1] = minetest.formspec_escape(T.label(b) .. " — " .. b.m)
    end
    local add_items = {"— add trigger —"}
    for _, c in ipairs(ctx.choices) do
        add_items[#add_items + 1] = minetest.formspec_escape(c.label)
    end
    minetest.show_formspec(pname, "yaportal:clock_trig",
        "formspec_version[4]" ..
        "size[10,7.4]" ..
        "label[0.5,0.6;Clock Triggers  (fire on activation edge)]" ..
        "textlist[0.5,1.0;9,2.2;trig_list;" ..
            table.concat(rows, ",") .. ";" .. (ctx.sel or 1) .. ";false]" ..
        "button[0.5,3.35;3,0.7;remove_trig;Remove selected]" ..
        "dropdown[0.5,4.4;5.1,0.8;trig_new;" ..
            table.concat(add_items, ",") .. ";1;true]" ..
        "dropdown[5.8,4.4;2.6,0.8;trig_mode;" ..
            table.concat(CLOCK_TRIG_LABELS, ",") .. ";1;true]" ..
        "button[8.6,4.4;0.9,0.8;add_trig;+]" ..
        "button[0.5,6.1;3.5,0.8;save_trig;Save]" ..
        "button[4.5,6.1;3,0.8;back;Back]"
    )
end

clock_trig_open = function(player, pos)
    local pname = player:get_player_name()
    clock_ctx[pname] = {
        pos = {x = pos.x, y = pos.y, z = pos.z},
        bindings = clock_read_trig(pos), sel = 1,
        choices = yaportal.triggers.list_near(pos, 48),
    }
    clock_trig_show(pname)
end

minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= "yaportal:clock_trig" then return end
    local pname = player:get_player_name()
    local ctx = clock_ctx[pname]
    if not (ctx and ctx.bindings) then return end
    local pos = ctx.pos
    if minetest.is_protected(pos, pname) then clock_ctx[pname] = nil; return end

    if fields.trig_list then
        local ev = minetest.explode_textlist_event(fields.trig_list)
        if ev.type == "CHG" or ev.type == "DCL" then ctx.sel = ev.index end
    end
    if fields.add_trig then
        local idx  = tonumber(fields.trig_new or "1") or 1
        local midx = tonumber(fields.trig_mode or "1") or 1
        local c = (idx >= 2) and ctx.choices[idx - 1]
        if c then
            ctx.bindings[#ctx.bindings + 1] =
                {k = c.k, m = CLOCK_TRIG_MODES[midx] or "start",
                 pos = c.pos, id = c.id}
            ctx.sel = #ctx.bindings
        end
        clock_trig_show(pname)
        return
    end
    if fields.remove_trig then
        if ctx.bindings[ctx.sel or 0] then
            table.remove(ctx.bindings, ctx.sel)
            if ctx.sel > #ctx.bindings then ctx.sel = math.max(#ctx.bindings, 1) end
        end
        clock_trig_show(pname)
        return
    end
    if fields.save_trig or fields.back then
        if fields.save_trig then clock_write_trig(pos, ctx.bindings) end
        -- Return to the main clock config either way.
        clock_open_config(player, pos)
        return
    end
    if fields.quit then clock_ctx[pname] = nil end
end)

-- ── trigger stepper ──
-- 0.2s: occupancy update (doors poll it through yaportal.triggers.active in
-- the combined stepper), then clock bindings: each fires on its rising edge —
-- start begins the countdown if idle, stop resets it.  Parsed bindings are
-- cached on the display entity, invalidated when the meta string changes.
local ts_step_accum, ts_viz_accum = 0, 0

minetest.register_globalstep(function(dtime)
    ts_step_accum = ts_step_accum + dtime
    if ts_step_accum >= 0.2 then
        ts_step_accum = 0
        local players = minetest.get_connected_players()
        for _, sp in pairs(spaces) do
            sp.occupied = false
            for _, pl in ipairs(players) do
                if ts_contains(sp, pl:get_pos()) then
                    sp.occupied = true
                    break
                end
            end
        end
        local T = yaportal.triggers
        for _, obj in pairs(clocks_disp) do
            local ent = obj:get_luaentity()
            if ent and ent._pos then
                local meta = minetest.get_meta(ent._pos)
                local key = meta:get_string("triggers")
                    .. "|" .. meta:get_int("tspace")
                if key ~= ent._trig_key then
                    ent._trig_key = key
                    ent._trig = clock_read_trig(ent._pos)
                end
                for _, b in ipairs(ent._trig or {}) do
                    local act = T.active(b)
                    if act and not b.prev then
                        if b.m == "start" then
                            if not ent._running then clock_start(ent._pos) end
                        elseif b.m == "close" then
                            clock_portals_close(ent._pos)
                        else
                            clock_stop(ent._pos)
                        end
                    end
                    b.prev = act
                end
            end
        end
    end

    ts_viz_accum = ts_viz_accum + dtime
    if ts_viz_accum >= 1.0 then
        ts_viz_accum = 0
        if ts_visible or next(ts_corner) then ts_draw_outlines() end
    end
end)

minetest.register_on_leaveplayer(function(player)
    local pname = player:get_player_name()
    ts_corner[pname] = nil
    ts_form_ctx[pname] = nil
end)

end)()  -- end clock closure

-- ── combined stepper ─────────────
-- tier 0 (every step): carried-cube positioning; tier 1 (0.2s): button and
-- door polling; tier 2 (2s): dispenser auto-respawn.

local ib_button_accum, ib_vent_accum = 0, 0

minetest.register_globalstep(function(dtime)
    -- carried cubes float in front of the carrier's camera
    for pname, obj in pairs(carried_cubes) do
        local player = minetest.get_player_by_name(pname)
        if not obj:get_pos() then
            carried_cubes[pname] = nil        -- cube object died/unloaded
        elseif not player then
            drop_cube(pname)                  -- carrier gone (leave handler missed)
        else
            local eye = player:get_pos()
            local props = player:get_properties()
            eye.y = eye.y + ((props and props.eye_height) or 1.5)
            local ld = player:get_look_dir()
            obj:move_to({x = eye.x + ld.x * CARRY_DIST,
                         y = eye.y + ld.y * CARRY_DIST,
                         z = eye.z + ld.z * CARRY_DIST}, true)
            obj:set_rotation({x = 0, y = player:get_look_horizontal(), z = 0})
        end
    end

    ib_button_accum = ib_button_accum + dtime
    if ib_button_accum >= 0.2 then
        ib_button_accum = 0

        for h, b in pairs(superbuttons) do
            if not minetest.get_node(b.pos).name:find("^yaportal:superbutton") then
                superbuttons[h] = nil
            else
                local center = {x = b.pos.x + 0.5, y = b.pos.y, z = b.pos.z + 0.5}
                local pressed = false
                for _, obj in ipairs(minetest.get_objects_inside_radius(center, 1.8)) do
                    local opos = obj:get_pos()
                    if opos
                       and math.abs(opos.x - center.x) <= 1.35
                       and math.abs(opos.z - center.z) <= 1.35
                       and opos.y >= b.pos.y - 0.45 and opos.y <= b.pos.y + 0.7 then
                        if obj:is_player() then
                            pressed = true
                            break
                        end
                        local ent = obj:get_luaentity()
                        if ent and ent.name == CUBE_ENTITY and not ent._carrier then
                            pressed = true
                            break
                        end
                    end
                end
                if pressed ~= b.pressed then
                    b.pressed = pressed
                    button_swap(b.pos, pressed)
                    button_sound(center, pressed)
                    signal_set(button_positions(b.pos), pressed)
                end
            end
        end

        for h, e in pairs(doors) do
            local n = minetest.get_node(e.pos)
            if not n.name:find("^yaportal:door_bl") then
                doors[h] = nil
            else
                e.p2 = n.param2 % 4
                local wd = DOOR_WDIR[e.p2]
                local center = {x = e.pos.x + wd.x * 0.5, y = e.pos.y + 0.5,
                                z = e.pos.z + wd.z * 0.5}
                -- Resolve activation from the trigger bindings: "hold" ones
                -- activate while their trigger is active; "open"/"close" ones
                -- set/clear a latch on the trigger's rising edge (a door can
                -- open on space entry yet close only from a button).  With no
                -- bindings the auto rule applies (a super button within 8
                -- while pressed, otherwise proximity).  Mesecons always
                -- counts as activation.
                local activated = e.powered
                if e.bindings and #e.bindings > 0 then
                    local T = rawget(_G, "yaportal") and yaportal.triggers
                    if T then
                        for _, b in ipairs(e.bindings) do
                            local act = T.active(b)
                            if b.m == "hold" then
                                if act then activated = true end
                            elseif act and not b.prev then
                                e.latch = (b.m == "open")
                            end
                            b.prev = act
                        end
                    end
                    if e.latch then activated = true end
                else
                    local controlled = false
                    for _, b in pairs(superbuttons) do
                        local bc = {x = b.pos.x + 0.5, y = b.pos.y, z = b.pos.z + 0.5}
                        if vector.distance(bc, center) <= 8 then
                            controlled = true
                            if b.pressed then activated = true end
                        end
                    end
                    if not controlled and not activated then
                        for _, pl in ipairs(minetest.get_connected_players()) do
                            if vector.distance(pl:get_pos(), center) <= 2.5 then
                                activated = true
                                break
                            end
                        end
                    end
                end
                -- Manual override from the config form wins; otherwise
                -- normally-open doors invert: activation closes them.
                local want
                if e.forced ~= nil then
                    want = e.forced
                else
                    want = (activated ~= (e.normally_open == true))
                end
                if want ~= e.open then
                    door_set(e, want)
                    door_sound(center, want)
                end
            end
        end
    end

    ib_vent_accum = ib_vent_accum + dtime
    if ib_vent_accum >= 2.0 then
        ib_vent_accum = 0
        for h, d in pairs(dispensers) do
            if minetest.get_node(d.pos).name ~= "yaportal:dispenser" then
                dispensers[h] = nil
            elseif d.enabled == false then
                d.empty_ticks = 0  -- consistent delay on re-enable
            else
                local maxd = d.max_dist or 16
                -- A home cube within max_dist counts as alive (and refreshes
                -- the tracked ref); one that strayed past the limit is
                -- destroyed and respawns via the lost-cube path below.
                local found = false
                for _, obj in ipairs(minetest.get_objects_inside_radius(
                        d.pos, maxd + 16)) do
                    local ent = obj:get_luaentity()
                    if ent and ent.name == CUBE_ENTITY and ent._home == h then
                        if vector.distance(obj:get_pos(), d.pos) <= maxd then
                            found = true
                            d.cube = obj
                        else
                            cube_fizzle(obj)
                        end
                    end
                end
                -- Tracked ref may reach a loaded cube beyond the scan radius
                -- (active near another player): apply the limit there too.
                if not found and d.cube then
                    local cp = d.cube:get_pos()
                    if cp and vector.distance(cp, d.pos) > maxd then
                        cube_fizzle(d.cube)
                    end
                end
                if found then
                    d.empty_ticks = 0
                else
                    -- Accepted edge case: a home cube in an unloaded mapblock
                    -- counts as lost and gets replaced — a duplicate may
                    -- appear (the scan destroys it once it reloads nearby).
                    d.empty_ticks = d.empty_ticks + 1
                    if d.empty_ticks >= 2 then  -- ~4s, Portal-like delay
                        if dispense(d.pos, h) then d.empty_ticks = 0 end
                    end
                end
            end
        end
    end
end)

-- ── portal gun pedestal ─────────────
-- 2x2 stand holding a portal gun on display (Portal-1 style).  Right-click
-- with a gun to put it on the pedestal; a player walking up to it receives
-- the gun.  Pickup is edge-triggered on entering the radius, so whoever just
-- stored a gun does not instantly grab it back.  Same corner scheme as the
-- super button (facedir param2 = corner id, anchor = min X/Z quarter); the
-- "gun" meta lives on the anchor node.

local pedestals = {}  -- hash(anchor) → {pos = anchor, inside = {pname = true}}

local PEDESTAL_GUNS = {
    ["yaportal:portal_gun"]  = true,
    ["yaportal:portal_gun3"] = true,
    ["yaportal:portal_gun4"] = true,
    ["yaportal:pocket_gun"]  = true,
}
local PEDESTAL_RADIUS = 1.9  -- from the 2x2 center, per horizontal axis

local function pedestal_display_pos(anchor)
    return {x = anchor.x + 0.5, y = anchor.y + 0.75, z = anchor.z + 0.5}
end

minetest.register_entity("yaportal:pedestal_gun", {
    initial_properties = {
        visual = "wielditem",
        wield_item = "yaportal:portal_gun4",
        visual_size = {x = 0.30, y = 0.30},
        physical = false,
        pointable = false,
        static_save = false,      -- LBM respawns it on mapblock load
        automatic_rotate = 1.2,
        glow = 4,
    },
    on_activate = function(self)
        self.object:set_armor_groups({immortal = 1})
    end,
})

local function pedestal_find_display(anchor)
    local dp = pedestal_display_pos(anchor)
    for _, obj in ipairs(minetest.get_objects_inside_radius(dp, 0.5)) do
        local ent = obj:get_luaentity()
        if ent and ent.name == "yaportal:pedestal_gun" then return obj end
    end
end

local function pedestal_update_display(anchor)
    local gun = minetest.get_meta(anchor):get_string("gun")
    local obj = pedestal_find_display(anchor)
    if gun == "" then
        if obj then obj:remove() end
        return
    end
    if not obj then
        obj = minetest.add_entity(pedestal_display_pos(anchor),
            "yaportal:pedestal_gun")
    end
    if obj then
        obj:set_properties({wield_item = ItemStack(gun):get_name()})
    end
end

local function pedestal_rightclick(pos, node, clicker, itemstack)
    if not (clicker and clicker:is_player()) then return itemstack end
    local anchor = button_anchor(pos, node.param2)
    local meta = minetest.get_meta(anchor)
    if meta:get_string("gun") ~= "" then return itemstack end
    if not PEDESTAL_GUNS[itemstack:get_name()] then return itemstack end
    local one = itemstack:take_item(1)
    meta:set_string("gun", one:to_string())
    local entry = pedestals[hashpos(anchor)]
    if entry then entry.inside[clicker:get_player_name()] = true end
    pedestal_update_display(anchor)
    return itemstack
end

local function pedestal_place(itemstack, placer, pointed)
    if pointed.type ~= "node" then return itemstack end
    local pname = placer and placer:is_player() and placer:get_player_name() or ""
    local un = minetest.get_node(pointed.under)
    if placer and not placer:get_player_control().sneak then
        local ndef = minetest.registered_nodes[un.name]
        if ndef and ndef.on_rightclick then
            return ndef.on_rightclick(pointed.under, un, placer, itemstack,
                pointed) or itemstack
        end
    end
    local anchor = pointed.above
    for dx = 0, 1 do
        for dz = 0, 1 do
            local cell = {x = anchor.x + dx, y = anchor.y, z = anchor.z + dz}
            local cdef = minetest.registered_nodes[minetest.get_node(cell).name]
            local below = {x = cell.x, y = cell.y - 1, z = cell.z}
            local bdef = minetest.registered_nodes[minetest.get_node(below).name]
            if not (cdef and cdef.buildable_to) or not (bdef and bdef.walkable) then
                minetest.chat_send_player(pname,
                    "The pedestal needs a free 2x2 area on solid ground " ..
                    "(expands +X/+Z from the clicked cell).")
                return itemstack
            end
            if minetest.is_protected(cell, pname) then
                minetest.record_protection_violation(cell, pname)
                return itemstack
            end
        end
    end
    for _, q in ipairs(button_quarters(anchor)) do
        minetest.set_node(q.pos, {name = "yaportal:pedestal", param2 = q.param2})
    end
    pedestals[hashpos(anchor)] =
        {pos = {x = anchor.x, y = anchor.y, z = anchor.z}, inside = {}}
    if placer and not minetest.is_creative_enabled(pname) then
        itemstack:take_item()
    end
    return itemstack
end

local function pedestal_after_dig(pos, oldnode, oldmetadata)
    local anchor = button_anchor(pos, oldnode.param2)
    pedestals[hashpos(anchor)] = nil
    local obj = pedestal_find_display(anchor)
    if obj then obj:remove() end
    -- Read the stored gun before removing the other quarters (removing the
    -- anchor wipes its meta); the dug node's own meta arrives in oldmetadata.
    local gun
    if pos.x == anchor.x and pos.z == anchor.z then
        gun = oldmetadata and oldmetadata.fields and oldmetadata.fields.gun
    else
        gun = minetest.get_meta(anchor):get_string("gun")
    end
    for _, q in ipairs(button_quarters(anchor)) do
        if not (q.pos.x == pos.x and q.pos.y == pos.y and q.pos.z == pos.z) then
            if minetest.get_node(q.pos).name == "yaportal:pedestal" then
                minetest.remove_node(q.pos)
            end
        end
    end
    if gun and gun ~= "" then
        minetest.add_item(pedestal_display_pos(anchor), gun)
    end
end

do
    -- Quarter boxes for corner param2 = 0 (anchor, min X/Z): geometry leans
    -- toward the 2x2 center at the node's +X/+Z corner; facedir rotates the
    -- other three corners (same convention as the super button caps).
    local quarter = {
        {-0.5,   -0.5,    -0.5,   0.5, -0.3125, 0.5},  -- base slab (full 2x2)
        { 0.25,  -0.3125,  0.25,  0.5,  0.125,  0.5},  -- column
        {-0.125,  0.125,  -0.125, 0.5,  0.3125, 0.5},  -- head
    }
    minetest.register_node("yaportal:pedestal", {
        description = "Portal Gun Pedestal\n" ..
            "2x2 stand (expands +X/+Z from the clicked cell). Right-click " ..
            "with a portal gun to put it on display; walking up to the " ..
            "pedestal hands the gun to the player",
        drawtype = "nodebox",
        paramtype = "light",
        paramtype2 = "facedir",
        sunlight_propagates = true,
        is_ground_content = false,
        tiles = {"[fill:16x16:#d6d6da", "[fill:16x16:#87878d",
                 "[fill:16x16:#b4b4ba^[fill:16x3:0,13:#87878d"},
        node_box = {type = "fixed", fixed = quarter},
        selection_box = {type = "fixed",
            fixed = {-0.5, -0.5, -0.5, 0.5, 0.3125, 0.5}},
        groups = {cracky = 3, oddly_breakable_by_hand = 1},
        sounds = block_sounds,
        on_place = pedestal_place,
        on_rightclick = pedestal_rightclick,
        after_dig_node = pedestal_after_dig,
    })
end

minetest.register_lbm({
    label = "Re-register portal gun pedestals",
    name = "yaportal:register_pedestal",
    nodenames = {"yaportal:pedestal"},
    run_at_every_load = true,
    action = function(pos, node)
        local anchor = button_anchor(pos, node.param2)
        local h = hashpos(anchor)
        if not pedestals[h] then
            pedestals[h] = {pos = anchor, inside = {}}
        end
        pedestal_update_display(anchor)
    end,
})

local pedestal_accum = 0
minetest.register_globalstep(function(dtime)
    pedestal_accum = pedestal_accum + dtime
    if pedestal_accum < 0.3 then return end
    pedestal_accum = 0
    if not next(pedestals) then return end
    local players = minetest.get_connected_players()
    for h, e in pairs(pedestals) do
        if minetest.get_node(e.pos).name ~= "yaportal:pedestal" then
            pedestals[h] = nil
        else
            local cx, cz = e.pos.x + 0.5, e.pos.z + 0.5
            for _, pl in ipairs(players) do
                local pname = pl:get_player_name()
                local ppos = pl:get_pos()
                local near = math.abs(ppos.x - cx) <= PEDESTAL_RADIUS
                    and math.abs(ppos.z - cz) <= PEDESTAL_RADIUS
                    and ppos.y >= e.pos.y - 1.2 and ppos.y <= e.pos.y + 1.5
                if near and not e.inside[pname] then
                    local meta = minetest.get_meta(e.pos)
                    local gun = meta:get_string("gun")
                    if gun ~= "" then
                        local left = pl:get_inventory()
                            :add_item("main", ItemStack(gun))
                        if left:is_empty() then
                            meta:set_string("gun", "")
                            pedestal_update_display(e.pos)
                        end
                    end
                end
                e.inside[pname] = near or nil
            end
        end
    end
end)

-- ── crafts ─────────────

do
    local iron  = (minetest.get_modpath("mcl_core") and "mcl_core:iron_ingot")
               or (minetest.get_modpath("default")  and "default:steel_ingot")
    local stone = (minetest.get_modpath("mcl_core") and "mcl_core:stone")
               or (minetest.get_modpath("default")  and "default:stone")
    local glass = (minetest.get_modpath("mcl_core") and "mcl_core:glass")
               or (minetest.get_modpath("default")  and "default:glass")
    if iron and stone then
        minetest.register_craft({
            output = "yaportal:superbutton",
            recipe = {
                {iron,  iron,  iron },
                {stone, stone, stone},
            },
        })
    end
    if iron and glass then
        minetest.register_craft({
            output = "yaportal:dispenser",
            recipe = {
                {iron, iron,  iron},
                {iron, glass, iron},
                {iron, iron,  iron},
            },
        })
    end
    if iron then
        minetest.register_craft({
            output = "yaportal:door",
            recipe = {
                {iron, iron},
                {iron, iron},
                {iron, iron},
            },
        })
    end
    if iron and glass then
        minetest.register_craft({
            output = "yaportal:clock_item",
            recipe = {
                {iron,  glass, iron},
                {iron,  iron,  iron},
            },
        })
    end
    if iron and stone then
        minetest.register_craft({
            output = "yaportal:pushbutton 4",
            recipe = {
                {iron},
                {stone},
            },
        })
    end
    if iron and stone then
        minetest.register_craft({
            output = "yaportal:pedestal",
            recipe = {
                {"",    iron,  ""   },
                {"",    stone, ""   },
                {stone, stone, stone},
            },
        })
    end
    local stick = (minetest.get_modpath("mcl_core") and "mcl_core:stick")
               or (minetest.get_modpath("default")  and "default:stick")
    if iron and stick then
        minetest.register_craft({
            output = "yaportal:trigger_wand",
            recipe = {
                {"",    "",    iron},
                {"",    stick, ""},
                {stick, "",    ""},
            },
        })
    end
end

-- Halves ↔ full conversions (mod-internal, no external items needed).
for _, part in ipairs({"upper", "lower"}) do
    minetest.register_craft({
        output = "yaportal:wall_" .. part .. "_slab 2",
        recipe = {{"yaportal:wall_" .. part}},
    })
    minetest.register_craft({
        output = "yaportal:wall_" .. part,
        recipe = {
            {"yaportal:wall_" .. part .. "_slab"},
            {"yaportal:wall_" .. part .. "_slab"},
        },
    })
end
minetest.register_craft({
    output = "yaportal:thin_glass_half 2",
    recipe = {{"yaportal:thin_glass"}},
})
minetest.register_craft({
    output = "yaportal:thin_glass",
    recipe = {
        {"yaportal:thin_glass_half"},
        {"yaportal:thin_glass_half"},
    },
})
