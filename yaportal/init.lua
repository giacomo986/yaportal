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
local player_form_context = {}  -- pname → portal_name currently being configured
local player_mat_preview  = {}  -- pname → node_name selected in textlist (not yet applied)
local player_mat_filter   = {}  -- pname → filter string for material textlist
local open_portal_config  -- forward declared; assigned below

-- ── frame node ──────────────────────────────────────────────────────────────

local ALL_FRAME_NODES = {
    ["yaportal:frame"]        = true,
    ["yaportal:frame_blue"]   = true,
    ["yaportal:frame_orange"] = true,
    ["yaportal:frame_green"]  = true,
}

-- ── anchor entity ───────────────────────────────────────────────────────────

minetest.register_entity("yaportal:anchor", {
    initial_properties = {
        visual = "cube", visual_size = {x=0, y=0},
        collisionbox = {0,0,0,0,0,0},
        selectionbox = {-0.5,-0.5,-0.5, 0.5,0.5,0.5},
        collide_with_objects = false, physical = false,
        is_visible = false, static_save = false,
        pointable = true,
    },
    on_activate = function(self) self.object:set_armor_groups({immortal=1}) end,
    on_rightclick = function(self, clicker)
        if self._portal_name and clicker and clicker:is_player()
           and not self._portal_name:match("^gun_")
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
        else
            pos = {x=pp.cx, y=pp.cy+(h-1)/2, z=pp.cz+(w-1)/2}
        end
        anchors[name] = minetest.add_entity(pos, "yaportal:anchor")
        if anchors[name] then
            local ent = anchors[name]:get_luaentity()
            if ent then ent._portal_name = name end
            -- Selectionbox covers the entire portal opening so right-clicking
            -- Selectionbox covers interior + 1-node frame border on all sides.
            -- Depth ±0.6 protrudes slightly past frame block faces (±0.5) so
            -- the entity intercepts clicks before the underlying node.
            local hw = w / 2 + 1
            local hh = h / 2 + 1
            local sb
            if pp.axis == 0 then
                sb = {-hw, -hh, -0.6, hw, hh, 0.6}
            else
                sb = {-0.6, -hh, -hw, 0.6, hh, hw}
            end
            anchors[name]:set_properties({selectionbox = sb})
        end
    end
end

-- ── geometry utils ─────────────────────────────────────────────────────────

local function node_at(x,y,z) return minetest.get_node({x=x,y=y,z=z}).name end

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
    else
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
    end
    return true
end

local function inner_center(pp)
    local w = pp.w or 2
    local h = pp.h or 3
    if pp.axis == 0 then
        return {x=pp.cx+(w-1)/2, y=pp.cy+(h-1)/2, z=pp.cz}
    else
        return {x=pp.cx, y=pp.cy+(h-1)/2, z=pp.cz+(w-1)/2}
    end
end

local function portal_normal(axis, ns)
    ns = ns or 1
    return axis==0 and {x=0,y=0,z=ns} or {x=ns,y=0,z=0}
end

local function normal_sign(axis, player_pos, cx, cz)
    if axis == 0 then
        return (player_pos.z >= cz) and 1 or -1
    else
        return (player_pos.x >= cx) and 1 or -1
    end
end

local function in_portal_bounds(ppos, pp)
    local py = ppos.y + 0.5
    local M = 0.3
    local w = pp.w or 2
    local h = pp.h or 3
    if pp.axis == 0 then
        return py   >= pp.cy and py   < pp.cy + h
           and ppos.x >= pp.cx - M and ppos.x < pp.cx + w + M
           and math.abs(ppos.z - pp.cz) <= 1.0
    else
        return py   >= pp.cy and py   < pp.cy + h
           and ppos.z >= pp.cz - M and ppos.z < pp.cz + w + M
           and math.abs(ppos.x - pp.cx) <= 1.0
    end
end

local function on_ns_side(ppos, pp)
    local ns = pp.ns or 1
    if pp.axis == 0 then
        return (ppos.z - pp.cz) * ns >= -TRIGGER_DEPTH
    else
        return (ppos.x - pp.cx) * ns >= -TRIGGER_DEPTH
    end
end

local function portal_depth(ppos, pp)
    local ns = pp.ns or 1
    if pp.axis == 0 then
        return (ppos.z - pp.cz) * ns
    else
        return (ppos.x - pp.cx) * ns
    end
end

local function past_trigger(ppos, pp)
    return portal_depth(ppos, pp) < (0.5 - TRIGGER_DEPTH)
end

local function portal_basis(pp)
    local ns = pp.ns or 1
    if pp.axis == 0 then
        return {x=0,y=0,z=ns}, {x=-ns,y=0,z=0}
    else
        return {x=ns,y=0,z=0}, {x=0,y=0,z=ns}
    end
end

local function dot(a, b) return a.x*b.x + a.y*b.y + a.z*b.z end

local function portal_transform_pos(v, src_n, src_r, dst_n, dst_r)
    local lr = dot(v, src_r)
    local lu = v.y
    local ln = dot(v, src_n)
    local dst_ln = -ln
    if dst_ln >= 0 then
        dst_ln = math.max(dst_ln, 0.02)
    else
        dst_ln = math.min(dst_ln, -0.02)
    end
    return {
        x = (-lr)*dst_r.x + dst_ln*dst_n.x,
        y = lu,
        z = (-lr)*dst_r.z + dst_ln*dst_n.z,
    }
end

local function portal_transform_dir(v, src_n, src_r, dst_n, dst_r)
    local lr = dot(v, src_r)
    local lu = v.y
    local ln = dot(v, src_n)
    return {
        x = (-lr)*dst_r.x + (-ln)*dst_n.x,
        y = lu,
        z = (-lr)*dst_r.z + (-ln)*dst_n.z,
    }
end

local function block_in_frame(pos, pp)
    local w = pp.w or 2
    local h = pp.h or 3
    if pp.axis == 0 then
        return pos.z == pp.cz
           and pos.x >= pp.cx-1 and pos.x <= pp.cx+w
           and pos.y >= pp.cy-1 and pos.y <= pp.cy+h
    else
        return pos.x == pp.cx
           and pos.z >= pp.cz-1 and pos.z <= pp.cz+w
           and pos.y >= pp.cy-1 and pos.y <= pp.cy+h
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
    else
        for dz = -1, w do
            pos_list[#pos_list+1] = {x=cx, y=cy-1, z=cz+dz}
            pos_list[#pos_list+1] = {x=cx, y=cy+h, z=cz+dz}
        end
        for dy = 0, h-1 do
            pos_list[#pos_list+1] = {x=cx, y=cy+dy, z=cz-1}
            pos_list[#pos_list+1] = {x=cx, y=cy+dy, z=cz+w}
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
local SKY_VOID = minetest.register_portal_sky_type("void", {
    type       = "plain",
    bgcolor    = "#000000",
    clouds     = false,
    sunlit     = false,
    brightness = 0.0,
})
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
        portal_list[i] = {
            pos    = inner_center(pp),
            normal = portal_normal(pp.axis, pp.ns),
            up     = UP,
            half_w = (pp.w or 2) / 2,
            half_h = (pp.h or 3) / 2,
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
    sync_portals()
    -- Migrate portals with external frame materials to yaportal:frame.
    -- Avoids injecting on_rightclick globally into common node types.
    local migrated = false
    for name, pp in pairs(portals) do
        if pp.node_name and not ALL_FRAME_NODES[pp.node_name] then
            local ok, err = pcall(function()
                for _, fpos in ipairs(get_frame_positions(pp)) do
                    if minetest.get_node(fpos).name == pp.node_name then
                        minetest.swap_node(fpos, {name = "yaportal:frame"})
                    end
                end
            end)
            if ok then
                pp.node_name = "yaportal:frame"
                migrated = true
            else
                minetest.log("warning", "[yaportal] skip migration for '" ..
                    name .. "': " .. tostring(err))
            end
        end
    end
    if migrated then save_portals() end
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
                            local ns = normal_sign(axis, ppos, cx, cz)
                            -- Skip if already active
                            for _, pp in pairs(portals) do
                                if pp.cx==cx and pp.cy==cy and pp.cz==cz
                                   and pp.axis==axis and pp.ns==ns then
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
end

local function deactivate_if_frame(pos)
    for name, pp in pairs(portals) do
        if block_in_frame(pos, pp) then
            -- Clean up bidirectional link
            if pp.link and portals[pp.link] then
                portals[pp.link].link = nil
            end
            portals[name] = nil
            save_portals()
            sync_portals()
            update_anchor(name, nil)
            minetest.chat_send_all("[portal] '" .. name .. "' deactivated.")
            return
        end
    end
end

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

    local info = "Size: " .. (pp.w or "?") .. "x" .. (pp.h or "?") ..
                 " nodes  |  Axis: " .. (pp.axis==0 and "Z" or "X")

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

    minetest.show_formspec(pname, "yaportal:config",
        "formspec_version[4]" ..
        "size[9,11.5]" ..
        "label[0.5,0.5;Configure Portal]" ..
        "label[0.5,1.1;" .. minetest.formspec_escape(info) .. "]" ..
        "field[0.5,2;8.5,0.8;portal_name;Portal name;" ..
            minetest.formspec_escape(portal_name) .. "]" ..
        "label[0.5,3.1;Link to:]" ..
        "dropdown[0.5,3.6;8.5,0.8;portal_link;" ..
            table.concat(link_items, ",") .. ";" .. selected .. "]" ..
        "label[0.5,4.8;Frame material:]" ..
        "label[4.5,4.8;" .. minetest.formspec_escape(preview_label) .. "]" ..
        "item_image[7.5,4.4;1.2,1.2;" .. preview_node .. "]" ..
        "field[0.5,5.3;5.5,0.7;mat_filter;Filter:;" ..
            minetest.formspec_escape(player_mat_filter[pname] or "") .. "]" ..
        "button[6.1,5.3;1.3,0.7;cerca_material;Search]" ..
        "textlist[0.5,6.1;8.5,3.5;material_list;" ..
            table.concat(mat_items, ",") .. ";" .. mat_selected .. "]" ..
        "button[0.5,10.1;4,0.8;apply_material;Apply Material]" ..
        "button[5,10.1;3.5,0.8;save;Save]"
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

    -- Always sync filter from current form state
    if fields.mat_filter ~= nil then
        player_mat_filter[pname] = fields.mat_filter
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
    player_form_context[name] = nil
    player_mat_preview[name] = nil
    player_mat_filter[name]  = nil
    -- gun portal cleanup is done by a second register_on_leaveplayer in the portal gun section
end)

minetest.register_globalstep(function(dtime)
    for _, player in ipairs(minetest.get_connected_players()) do
        local pname = player:get_player_name()
        local ppos  = player:get_pos()

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
                    s.entered_from_front = on_ns_side(ppos, pp)
                    s.triggered          = false
                end

                local border_entry = just_entered and portal_depth(ppos, pp) < (0.5 - TRIGGER_DEPTH)
                if s.entered_from_front and not s.triggered and dst
                   and not teleport_src
                   and (past_trigger(ppos, pp) or border_entry)
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

        if teleport_src and teleport_dst then
            local src = portals[teleport_src]
            local dst = portals[teleport_dst]

            local src_n, src_r = portal_basis(src)
            local dst_n, dst_r = portal_basis(dst)
            local src_c = inner_center(src)
            local dst_c = inner_center(dst)

            local rel     = {x=ppos.x-src_c.x, y=ppos.y-src_c.y, z=ppos.z-src_c.z}
            local new_off = portal_transform_pos(rel, src_n, src_r, dst_n, dst_r)
            -- Exit at same offset past dst outer face as trigger offset past src outer face
            local cur_n = new_off.x * dst_n.x + new_off.z * dst_n.z
            local adj   = (0.5 + TRIGGER_DEPTH) - cur_n
            new_off.x   = new_off.x + adj * dst_n.x
            new_off.z   = new_off.z + adj * dst_n.z
            local new_pos = {
                x=dst_c.x+new_off.x,
                y=dst_c.y+new_off.y,
                z=dst_c.z+new_off.z,
            }

            local vel      = player:get_velocity() or {x=0,y=0,z=0}
            local new_vel  = portal_transform_dir(vel,  src_n, src_r, dst_n, dst_r)
            local look     = player:get_look_dir()
            local new_look = portal_transform_dir(look, src_n, src_r, dst_n, dst_r)
            local new_yaw  = math.atan2(-new_look.x, new_look.z)

            local dst_idx = portal_index[teleport_dst]
            if dst_idx then
                -- Hint is in destination render space; add eye height so the
                -- virtual camera matches the actual eye position, not the feet.
                local props = player:get_properties()
                local eye_h = (props and props.eye_height) or 1.625
                minetest.set_portal_cam_hint(dst_idx, {
                    x=new_pos.x, y=new_pos.y + eye_h, z=new_pos.z
                })
            end

            -- sky_sunlit hint forces sunlight_seen on the client so the sky snaps
            -- instantly to the destination state instead of lerping over ~300 frames.
            -- void→overworld needs true: snap to sunlit sky, releases when bg_sunlit=true.
            -- overworld→void needs false: snap to dark sky; bg_sunlit in void is always
            -- false so the override releases immediately once block data arrives.
            -- Sending true for void would cause the override to never release
            -- (bg_sunlit=false ≠ override=true) → sunlight_seen stuck true → daylight in void.
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
                sky_sunlit = false  -- overworld→void
                src_slot = portal_index[teleport_src]
            end
            player:portal_teleport(new_pos, new_yaw, {
                x=new_vel.x-vel.x,
                y=new_vel.y-vel.y,
                z=new_vel.z-vel.z,
            }, {
                sky_sunlit = sky_sunlit,
                sky_slot   = src_slot,
            })

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
