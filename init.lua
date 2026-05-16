-- mio_portale/init.lua v2
-- Portali variabili: N portali nominati, dimensioni auto-rilevate (1-8 nodi),
-- 8 materiali cornice, GUI destra-click per nome e collegamento.

minetest.log("action", "[mio_portale] Caricamento mod v2...")

local storage = minetest.get_mod_storage()

-- ── costanti ──────────────────────────────────────────────────────────────────

local MIN_W, MAX_W = 1, 8   -- larghezza interna portale (nodi)
local MIN_H, MAX_H = 2, 8   -- altezza interna portale (nodi)
local UP = {x=0, y=1, z=0}
local TRIGGER_DEPTH = 0.05

-- ── stato globale ─────────────────────────────────────────────────────────────

-- portals[name] = {cx,cy,cz,axis,ns,w,h,link,node_name}
local portals = {}

-- C++ indice 0-based per ogni portale (ricostruito da sync_portals, stabile
-- tra chiamate consecutive se i nomi non cambiano grazie all'ordine alfabetico)
local portal_index = {}  -- name → 0-based int

local anchors = {}              -- name → entity object
local player_states = {}        -- pname → {[portal_name] → {in_bounds,entered_from_front,triggered}}
local player_form_context = {}  -- pname → portal_name currently being configured
local player_mat_preview  = {}  -- pname → node_name selected in textlist (not yet applied)
local open_portal_config  -- forward declared; assigned below
local hooked_nodes        = {}  -- node names that received the portal right-click hook

-- ── nodo cornice ─────────────────────────────────────────────────────────────

local ALL_FRAME_NODES = {["mio_portale:frame"] = true}

-- ── entity ancora ─────────────────────────────────────────────────────────────

minetest.register_entity("mio_portale:anchor", {
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
        if self._portal_name and clicker and clicker:is_player() then
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
        anchors[name] = minetest.add_entity(pos, "mio_portale:anchor")
        if anchors[name] then
            local ent = anchors[name]:get_luaentity()
            if ent then ent._portal_name = name end
            -- Selectionbox covers the entire portal opening so right-clicking
            -- the air inside the portal (from either side) hits the anchor.
            local hw = w / 2
            local hh = h / 2
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

-- ── utilità geometria ────────────────────────────────────────────────────────

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
    return portal_depth(ppos, pp) < -TRIGGER_DEPTH
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
    end
    minetest.set_portals(portal_list)
end

local function save_portals()
    storage:set_string("portals_v2", minetest.serialize(portals))
end

-- Injects a portal right-click handler into any external node type used as a
-- frame material, falling back to the node's original on_rightclick if the
-- clicked position isn't part of a portal.
local function ensure_portal_rightclick(node_name)
    if hooked_nodes[node_name] then return end
    if ALL_FRAME_NODES[node_name] then return end  -- already handled via node def
    local def = minetest.registered_nodes[node_name]
    if not def then return end
    hooked_nodes[node_name] = true
    local original_rc = def.on_rightclick
    minetest.override_item(node_name, {
        on_rightclick = function(pos, node, player, itemstack, pointed_thing)
            local found = find_portal_for_block(pos)
            if found then
                open_portal_config(player, found)
                return itemstack
            end
            if original_rc then
                return original_rc(pos, node, player, itemstack, pointed_thing)
            end
        end,
    })
end

minetest.register_on_mods_loaded(function()
    local s = storage:get_string("portals_v2")
    if s and s ~= "" then
        portals = minetest.deserialize(s) or {}
    end
    sync_portals()
    for name, pp in pairs(portals) do
        update_anchor(name, pp)
        if pp.node_name then
            ensure_portal_rightclick(pp.node_name)
        end
    end
end)

-- ── generatore nomi portale ───────────────────────────────────────────────────

local function new_portal_name()
    local n = (tonumber(storage:get_string("portal_counter")) or 0) + 1
    storage:set_string("portal_counter", tostring(n))
    return "portale_" .. n
end

-- ── rilevamento cornice ───────────────────────────────────────────────────────

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
                                "[portale] '" .. name .. "' attivato (" ..
                                w .. "x" .. h .. " nodi). Clic destro per configurare.")
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
            minetest.chat_send_all("[portale] '" .. name .. "' disattivato.")
            return
        end
    end
end

-- ── GUI configurazione ────────────────────────────────────────────────────────

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

    -- Build link dropdown: "(nessuno)" + all other portal names
    local link_items = {"(nessuno)"}
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

    local info = "Dimensioni: " .. (pp.w or "?") .. "x" .. (pp.h or "?") ..
                 " nodi  |  Asse: " .. (pp.axis==0 and "Z" or "X")

    -- Build material textlist from all registered nodes
    local all_nodes = get_all_nodes()
    local mat_items = {}
    local mat_selected = 1
    local current_node = pp.node_name or "mio_portale:frame"
    local preview_node = player_mat_preview[pname] or current_node
    for i, name in ipairs(all_nodes) do
        local def = minetest.registered_nodes[name]
        local short_desc = (def and def.description and
            def.description:match("^([^\n]+)")) or name
        mat_items[#mat_items+1] = minetest.formspec_escape(short_desc .. " (" .. name .. ")")
        if name == preview_node then mat_selected = i end
    end

    local preview_label = preview_node == current_node
        and "Anteprima:"
        or  "Anteprima (non applicato):"

    minetest.show_formspec(pname, "mio_portale:config",
        "formspec_version[4]" ..
        "size[9,11.5]" ..
        "label[0.5,0.5;Configura Portale]" ..
        "label[0.5,1.1;" .. minetest.formspec_escape(info) .. "]" ..
        "field[0.5,2;8.5,0.8;portal_name;Nome portale;" ..
            minetest.formspec_escape(portal_name) .. "]" ..
        "label[0.5,3.1;Collega a:]" ..
        "dropdown[0.5,3.6;8.5,0.8;portal_link;" ..
            table.concat(link_items, ",") .. ";" .. selected .. "]" ..
        "label[0.5,4.8;Materiale cornice:]" ..
        "label[4.5,4.8;" .. minetest.formspec_escape(preview_label) .. "]" ..
        "item_image[7.5,4.4;1.2,1.2;" .. preview_node .. "]" ..
        "textlist[0.5,5.6;8.5,4.0;material_list;" ..
            table.concat(mat_items, ",") .. ";" .. mat_selected .. "]" ..
        "button[0.5,10.1;4,0.8;apply_material;Applica Materiale]" ..
        "button[5,10.1;3.5,0.8;save;Salva]"
    )
end

minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= "mio_portale:config" then return end

    local pname = player:get_player_name()
    local portal_name = player_form_context[pname]
    if not portal_name or not portals[portal_name] then return end

    -- Form closed
    if fields.quit then
        player_mat_preview[pname] = nil
        return
    end

    -- Textlist selection changed → update preview and reopen (live preview)
    if fields.material_list and not fields.save and not fields.apply_material then
        local evt, idx_str = fields.material_list:match("^([A-Z]+):(%d+)$")
        if evt and evt ~= "INV" then
            local idx = tonumber(idx_str)
            local node = idx and get_all_nodes()[idx]
            if node then
                player_mat_preview[pname] = node
                open_portal_config(player, portal_name)
            end
        end
        return
    end

    -- "Applica Materiale" button → swap frame blocks to selected node
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
                ensure_portal_rightclick(new_node)
                save_portals()
                minetest.chat_send_player(pname,
                    "[portale] Materiale applicato: " .. new_node)
            end
            open_portal_config(player, portal_name)
        end
        return
    end

    if not fields.save then return end

    -- "Salva" button → rename + link

    -- Parse and sanitize new name
    local new_name = ((fields.portal_name or portal_name):match("^%s*(.-)%s*$"))
    new_name = new_name:gsub("[^%w%-_]", "_")
    if new_name == "" then new_name = portal_name end

    -- Parse link selection (dropdown returns the item string)
    local selected_str = fields.portal_link or "(nessuno)"
    local link_name = nil
    if selected_str ~= "(nessuno)" then
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

    local msg = "[portale] '" .. portal_name .. "' "
    if link_name then
        msg = msg .. "collegato a '" .. link_name .. "'"
    else
        msg = msg .. "scollegato"
    end
    minetest.chat_send_player(pname, msg)
end)

-- ── registrazione nodo cornice ────────────────────────────────────────────────

minetest.register_node("mio_portale:frame", {
    description = "Cornice Portale" ..
        "\n(cornice rettangolare, interno " .. MIN_W .. "x" .. MIN_H ..
        " a " .. MAX_W .. "x" .. MAX_H .. " nodi di aria)",
    tiles = {"mio_portale_blue.png"},
    groups = {cracky=3, oddly_breakable_by_hand=3},
    after_place_node = function(pos, placer)
        try_activate_near(pos, "mio_portale:frame", placer)
    end,
    after_dig_node = function(pos)
        deactivate_if_frame(pos)
    end,
    on_rightclick = function(pos, node, player, itemstack, pointed_thing)
        local found = find_portal_for_block(pos)
        if found then
            open_portal_config(player, found)
        else
            minetest.chat_send_player(player:get_player_name(),
                "[portale] Questo blocco non fa parte di un portale attivo.")
        end
    end,
})

-- Global callbacks so frames built from any game node activate/deactivate portals.
-- mio_portale:frame already has after_place/after_dig; skip double-call.
minetest.register_on_placenode(function(pos, newnode, placer)
    if ALL_FRAME_NODES[newnode.name] then return end
    try_activate_near(pos, newnode.name, placer)
end)

minetest.register_on_dignode(function(pos, oldnode)
    if ALL_FRAME_NODES[oldnode.name] then return end
    deactivate_if_frame(pos)
end)

-- ── teletrasporto ────────────────────────────────────────────────────────────

minetest.register_on_leaveplayer(function(player)
    local name = player:get_player_name()
    player_states[name] = nil
    player_form_context[name] = nil
    player_mat_preview[name] = nil
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

                -- Update RTT camera hint for destination portal
                if s.entered_from_front and dst then
                    local src_n, src_r = portal_basis(pp)
                    local dst_n, dst_r = portal_basis(dst)
                    local src_c = inner_center(pp)
                    local dst_c = inner_center(dst)
                    local rel = {x=ppos.x-src_c.x, y=ppos.y-src_c.y, z=ppos.z-src_c.z}
                    local off = portal_transform_pos(rel, src_n, src_r, dst_n, dst_r)
                    local dst_idx = portal_index[dst_name]
                    if dst_idx then
                        minetest.set_portal_cam_hint(dst_idx, {
                            x=dst_c.x+off.x, y=dst_c.y+off.y, z=dst_c.z+off.z
                        })
                    end
                end

                local border_entry = just_entered and portal_depth(ppos, pp) <= 0
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
                    -- Clear cam hint for destination
                    if dst_name then
                        local dst_idx = portal_index[dst_name]
                        if dst_idx then
                            minetest.clear_portal_cam_hint(dst_idx)
                        end
                    end
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
                minetest.set_portal_cam_hint(dst_idx, new_pos)
            end

            player:portal_teleport(new_pos, new_yaw, {
                x=new_vel.x-vel.x,
                y=new_vel.y-vel.y,
                z=new_vel.z-vel.z,
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
