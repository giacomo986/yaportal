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
           and not self._portal_name:match("^pocket_") then
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
            local pointable = not (name:match("^gun") or name:match("^pocket_"))
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
        if not node_is_walkable(node_at(x, y_n, z)) then break end
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
        if not name:match("^gun") and not name:match("^pocket_") then
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
             or name:match("^pocket_"))
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
                if s.entered_from_front and not s.triggered and dst
                   and not teleport_src
                   and (past_trigger(cpos, pp) or border_entry)
                then
                    s.triggered  = true
                    teleport_src = portal_name
                    teleport_dst = dst_name
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

minetest.register_tool("yaportal:portal_gun", {
    description = "Portal Gun\nLeft click: blue portal\nRight click: orange portal",
    inventory_image = "yaportal_gun.png",
    on_use = function(itemstack, user, pointed_thing)
        portal_gun_shoot(user, pointed_thing, "blue")
        return itemstack
    end,
    on_place = function(itemstack, placer, pointed_thing)
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
-- panels), so a portal shot into a panel wall doesn't turn its cells white.
-- Name scheme: yaportal:portal_wallblock_<color><mat>[_off].
local PGUN4_MAT_TILES = {
    [""]    = "[fill:16x16:#ffffff",
    ["_up"] = "yaportal_wall_upper.png",
    ["_lo"] = "yaportal_wall_lower.png",
}
local PGUN4_MAT_OF = {
    ["yaportal:portal_wall"] = "",
    ["yaportal:wall_upper"]  = "_up",
    ["yaportal:wall_lower"]  = "_lo",
}

local function pgun4_register_block(color, frametex)
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
        -- portal_block VALUE = portal family/colour: engine merge key (cells
        -- of one portal are different node ids across shell materials).
        local pbval = (color == "blue") and 3 or 4
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
    end
end
pgun4_register_block("blue",   "yaportal_blue.png")
pgun4_register_block("orange", "yaportal_orange.png")

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
            out[#out + 1] = {pos = c, param2 = dirp2}
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
            out[#out + 1] = {pos = pos, param2 = dirp2 + carve * 8}
        end
    end
    return out
end

local function pgun4_apply_state(portal_name)
    local pp = portals[portal_name]
    if not pp then return end
    local color = portal_name:match("^gun4_(%w+)_")
    if not color then return end
    local base   = "yaportal:portal_wallblock_" .. color
    local linked = pp.link ~= nil and portals[pp.link] ~= nil
    for i, c in ipairs(pgun4_cells(pp)) do
        local nn = minetest.get_node(c.pos).name
        if nn:sub(1, #base) == base then
            local mat = (pp.saved and PGUN4_MAT_OF[pp.saved[i]]) or ""
            local target = base .. mat .. (linked and "" or "_off")
            minetest.set_node(c.pos, {name = target, param2 = c.param2})
        end
    end
    pp.node_name = base .. (linked and "" or "_off")
end

-- Wall materials the wall gun can carve a portal into. The original node of
-- every carved cell is remembered in pp.saved and restored on close.
local PGUN4_CARVEABLE = {
    [PGUN4_WALL] = true,
    ["yaportal:wall_upper"] = true,
    ["yaportal:wall_lower"] = true,
}

-- Every footprint cell one step out along the normal must be passable,
-- otherwise part of the opening would be buried in a floor/ceiling/wall.
local function pgun4_front_clear(pp)
    local n = portal_normal(pp.axis, pp.ns)
    for _, c in ipairs(pgun4_cells(pp)) do
        local f = {x = c.pos.x + n.x, y = c.pos.y + n.y, z = c.pos.z + n.z}
        local def = minetest.registered_nodes[minetest.get_node(f).name]
        if not def or def.walkable then return false end
    end
    return true
end

-- A candidate placement is valid when the whole footprint is carveable wall
-- material AND the space in front of the opening is clear.
local function pgun4_probe_ok(pp)
    for _, c in ipairs(pgun4_cells(pp)) do
        if not PGUN4_CARVEABLE[minetest.get_node(c.pos).name] then
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
            minetest.set_node(c.pos, {name = orig})
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
    -- Only fires when aimed at a carveable wall material.
    if not PGUN4_CARVEABLE[minetest.get_node(under).name] then return end

    local dx = above.x - under.x
    local dy = above.y - under.y
    local dz = above.z - under.z

    -- Portal normal = hit-face direction (from the wall toward the player side).
    local axis, ns
    if dz ~= 0 then axis, ns = 0, dz
    elseif dx ~= 0 then axis, ns = 1, dx
    else axis, ns = 2, dy end

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
    local saved = {}
    for i, c in ipairs(cells) do
        local nn = minetest.get_node(c.pos).name
        if not PGUN4_CARVEABLE[nn] then
            minetest.chat_send_player(pname,
                "[yaportal] Need a " .. pw .. "×" .. ph ..
                " portal-wall surface here.")
            return
        end
        saved[i] = nn
    end
    -- Place the closed (solid) variant in the shell material of the original
    -- node; pgun4_apply_state below opens it (and the partner) only if a
    -- paired portal already exists.
    for i, c in ipairs(cells) do
        local mat = PGUN4_MAT_OF[saved[i]] or ""
        minetest.set_node(c.pos,
            {name = bnode .. mat .. "_off", param2 = c.param2})
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
    groups = {cracky = 3, oddly_breakable_by_hand = 1},
    sounds = minetest.get_modpath("default") and default and default.node_sound_stone_defaults() or nil,
})

-- Two-block wall panel: stack upper on top of lower to form one tall
-- Aperture panel (16x32) with a recessed seam around each panel.
minetest.register_node("yaportal:wall_upper", {
    description = "Aperture Science Wall Panel (upper)\nTop half of a tall white test-chamber panel; place above a lower panel",
    tiles = {"yaportal_wall_upper.png"},
    groups = {cracky = 3, oddly_breakable_by_hand = 1},
    sounds = minetest.get_modpath("default") and default and default.node_sound_stone_defaults() or nil,
})

minetest.register_node("yaportal:wall_lower", {
    description = "Aperture Science Wall Panel (lower)\nBottom half of a tall white test-chamber panel; place below an upper panel",
    tiles = {"yaportal_wall_lower.png"},
    groups = {cracky = 3, oddly_breakable_by_hand = 1},
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
            groups = {cracky = 3, oddly_breakable_by_hand = 1},
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

minetest.register_node("yaportal:floor", {
    description = "Aperture Science Floor Tile\nDark grey concrete floor tile from Portal test chambers",
    tiles = {"yaportal_floor.png"},
    groups = {cracky = 3, oddly_breakable_by_hand = 1},
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

-- ── vital apparatus vent (2x2x2 dispenser) + decorative tube ─────────────

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
    -- Re-home rule: orphan any previous cube of this vent so only the newest
    -- one counts — right-clicking cannot create runaway auto-respawn loops.
    for _, obj in ipairs(minetest.get_objects_inside_radius(center, 16)) do
        local ent = obj:get_luaentity()
        if ent and ent.name == CUBE_ENTITY and ent._home == h then
            ent._home = nil
        end
    end
    local obj = minetest.add_entity(center, CUBE_ENTITY)
    if obj then
        local ent = obj:get_luaentity()
        if ent then ent._home = h end
        return true
    end
    return false
end

local function vent_rightclick(pos, node)
    local anchor = vent_anchor(pos, node.name, node.param2)
    local h = hashpos(anchor)
    dispense(anchor, h)
    local entry = dispensers[h]
    if entry then entry.empty_ticks = 0 end
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
    dispensers[hashpos(anchor)] = {pos = anchor, empty_ticks = 0}
    if placer and not minetest.is_creative_enabled(pname) then
        itemstack:take_item()
    end
    return itemstack
end

local tube_walls = {
    {-0.5,   -0.5, -0.5,   -0.375, 0.5,  0.5},
    { 0.375, -0.5, -0.5,    0.5,   0.5,  0.5},
    {-0.5,   -0.5, -0.5,    0.5,   0.5, -0.375},
    {-0.5,   -0.5,  0.375,  0.5,   0.5,  0.5},
}

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
        "Right-click: dispense a Weighted Storage Cube; automatically " ..
        "replaces its cube when lost"
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

minetest.register_node("yaportal:tube", {
    description = "Apparatus Tube\nDecorative tube segment, open at both ends",
    drawtype = "nodebox",
    paramtype = "light",
    sunlight_propagates = true,
    is_ground_content = false,
    tiles = {"yaportal_tube_open.png", "yaportal_tube_open.png",
             "yaportal_tube_side.png"},
    node_box = {type = "fixed", fixed = tube_walls},
    selection_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}},
    groups = {cracky = 3, oddly_breakable_by_hand = 1},
    sounds = block_sounds,
})

minetest.register_lbm({
    label = "Re-register vital apparatus vents",
    name = "yaportal:register_dispenser",
    nodenames = {"yaportal:dispenser", "yaportal:dispenser_top"},
    run_at_every_load = true,
    action = function(pos, node)
        local anchor = vent_anchor(pos, node.name, node.param2)
        local h = hashpos(anchor)
        if not dispensers[h] then
            dispensers[h] = {pos = anchor, empty_ticks = 0}
        end
    end,
})

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
    for _, c in ipairs(door_cells(entry.pos, entry.p2)) do
        local want = "yaportal:door_" .. c.q .. suffix
        local n = minetest.get_node(c.pos)
        if n.name:find("^yaportal:door_") and n.name ~= want then
            minetest.set_node(c.pos, {name = want, param2 = entry.p2})
        end
    end
    entry.open = open
end

local function door_power(pos, node, on)
    local bl = door_bl_from(pos, node.name, node.param2)
    if not bl then return end
    local h = hashpos(bl)
    local entry = doors[h]
    if not entry then
        entry = {pos = bl, p2 = node.param2 % 4,
                 open = node.name:find("_open") ~= nil, powered = false}
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
        "8 nodes, only while that button is pressed",
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
        doors[hashpos(bl)] = {pos = {x = bl.x, y = bl.y, z = bl.z},
                              p2 = p2, open = false, powered = false}
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
            doors[h] = {pos = {x = pos.x, y = pos.y, z = pos.z},
                        p2 = node.param2 % 4,
                        open = node.name:find("_open") ~= nil, powered = false}
        end
    end,
})

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
                local controlled = false
                local want = e.powered
                for _, b in pairs(superbuttons) do
                    local bc = {x = b.pos.x + 0.5, y = b.pos.y, z = b.pos.z + 0.5}
                    if vector.distance(bc, center) <= 8 then
                        controlled = true
                        if b.pressed then want = true end
                    end
                end
                if not controlled and not want then
                    for _, pl in ipairs(minetest.get_connected_players()) do
                        if vector.distance(pl:get_pos(), center) <= 2.5 then
                            want = true
                            break
                        end
                    end
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
            else
                local found = false
                for _, obj in ipairs(minetest.get_objects_inside_radius(d.pos, 16)) do
                    local ent = obj:get_luaentity()
                    if ent and ent.name == CUBE_ENTITY and ent._home == h then
                        found = true
                        break
                    end
                end
                if found then
                    d.empty_ticks = 0
                else
                    -- Accepted edge case: a home cube beyond 16 nodes (walked
                    -- off, portal-teleported) or in an unloaded mapblock counts
                    -- as lost and gets replaced — a duplicate may appear.
                    d.empty_ticks = d.empty_ticks + 1
                    if d.empty_ticks >= 2 then  -- ~4s, Portal-like delay
                        if dispense(d.pos, h) then d.empty_ticks = 0 end
                    end
                end
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
            output = "yaportal:tube 8",
            recipe = {
                {iron, iron, iron},
                {iron, "",   iron},
                {iron, iron, iron},
            },
        })
        minetest.register_craft({
            output = "yaportal:door",
            recipe = {
                {iron, iron},
                {iron, iron},
                {iron, iron},
            },
        })
    end
end
