-- mio_portale/init.lua
-- I blocchi blu/arancioni formano la CORNICE 4×5.
-- Il portale (quad 2×3) appare nell'apertura AIR centrale.
-- Il giocatore viene teletrasportato camminando nell'apertura.

minetest.log("action", "[mio_portale] Caricamento mod...")

local storage = minetest.get_mod_storage()

local W = 2   -- larghezza interna
local H = 3   -- altezza interna

local BLUE   = "mio_portale:portal_blue"
local ORANGE = "mio_portale:portal_orange"

-- Stato portali: {cx,cy,cz,axis} o nil
-- axis 0 = cornice nel piano XY (normale ±Z)
-- axis 1 = cornice nel piano ZY (normale ±X)
local portals = {blue=nil, orange=nil}

-- Entity invisibile che mantiene attiva l'area intorno al portale.
-- Il server di Minetest/Luanti mantiene caricati i chunk entro
-- active_block_range (default 4 mapblock) da ogni entity attiva.
minetest.register_entity("mio_portale:anchor", {
    initial_properties = {
        visual = "cube",
        visual_size = {x=0, y=0},
        collisionbox = {0,0,0,0,0,0},
        collide_with_objects = false,
        physical = false,
        is_visible = false,
        static_save = false,
    },
    on_activate = function(self)
        self.object:set_armor_groups({immortal=1})
    end,
})

local anchors = {blue=nil, orange=nil}

local function update_anchor(color, pp)
    if anchors[color] then
        anchors[color]:remove()
        anchors[color] = nil
    end
    if pp then
        local pos = {x=pp.cx + (W-1)/2, y=pp.cy + (H-1)/2, z=pp.cz}
        anchors[color] = minetest.add_entity(pos, "mio_portale:anchor")
    end
end

-- ── utilità ──────────────────────────────────────────────────────────────────

local function node_at(x,y,z) return minetest.get_node({x=x,y=y,z=z}).name end

-- Verifica cornice completa: 14 blocchi del colore specificato + 2×3 air interni
local function check_frame(cx,cy,cz, axis, frame_node)
    if axis == 0 then
        for dx=0,W-1 do for dy=0,H-1 do
            if node_at(cx+dx,cy+dy,cz) ~= "air" then return false end
        end end
        for dx=-1,W do
            if node_at(cx+dx,cy-1,cz) ~= frame_node then return false end
            if node_at(cx+dx,cy+H,cz) ~= frame_node then return false end
        end
        for dy=0,H-1 do
            if node_at(cx-1,cy+dy,cz) ~= frame_node then return false end
            if node_at(cx+W,cy+dy,cz) ~= frame_node then return false end
        end
    else
        for dz=0,W-1 do for dy=0,H-1 do
            if node_at(cx,cy+dy,cz+dz) ~= "air" then return false end
        end end
        for dz=-1,W do
            if node_at(cx,cy-1,cz+dz) ~= frame_node then return false end
            if node_at(cx,cy+H,cz+dz) ~= frame_node then return false end
        end
        for dy=0,H-1 do
            if node_at(cx,cy+dy,cz-1) ~= frame_node then return false end
            if node_at(cx,cy+dy,cz+W) ~= frame_node then return false end
        end
    end
    return true
end

local function inner_center(cx,cy,cz,axis)
    if axis == 0 then
        return {x=cx+(W-1)/2, y=cy+(H-1)/2, z=cz}
    else
        return {x=cx,         y=cy+(H-1)/2, z=cz+(W-1)/2}
    end
end

local function portal_normal(axis, ns)
    ns = ns or 1
    return axis==0 and {x=0,y=0,z=ns} or {x=ns,y=0,z=0}
end

-- Which side of the portal plane is the player on?
local function normal_sign(axis, player_pos, cx, cz)
    if axis == 0 then
        return (player_pos.z >= cz) and 1 or -1
    else
        return (player_pos.x >= cx) and 1 or -1
    end
end

local UP = {x=0,y=1,z=0}

-- Verifica se il player è nel range del portale (1 nodo su entrambi i lati).
-- La direzionalità è gestita da entered_from_front nel globalstep.
local function in_portal_bounds(ppos, pp)
    local py = ppos.y + 0.5
    local M = 0.3
    if pp.axis == 0 then
        return py  >= pp.cy and py  < pp.cy + H
           and ppos.x >= pp.cx - M and ppos.x < pp.cx + W + M
           and math.abs(ppos.z - pp.cz) <= 1.0
    else
        return py  >= pp.cy and py  < pp.cy + H
           and ppos.z >= pp.cz - M and ppos.z < pp.cz + W + M
           and math.abs(ppos.x - pp.cx) <= 1.0
    end
end

-- ── sync / persist ───────────────────────────────────────────────────────────

local function sync_portals()
    local p0 = portals.blue and {
        pos    = inner_center(portals.blue.cx,   portals.blue.cy,   portals.blue.cz,   portals.blue.axis),
        normal = portal_normal(portals.blue.axis,   portals.blue.ns),
        up     = UP,
    }
    local p1 = portals.orange and {
        pos    = inner_center(portals.orange.cx, portals.orange.cy, portals.orange.cz, portals.orange.axis),
        normal = portal_normal(portals.orange.axis, portals.orange.ns),
        up     = UP,
    }
    minetest.set_portals(p0, p1)
end

local function save_portals()
    for _,color in ipairs({"blue","orange"}) do
        local pp = portals[color]
        storage:set_string(color, pp and minetest.serialize(pp) or "")
    end
end

minetest.register_on_mods_loaded(function()
    for _,color in ipairs({"blue","orange"}) do
        local s = storage:get_string(color)
        if s and s ~= "" then portals[color] = minetest.deserialize(s) end
    end
    sync_portals()
    for _,color in ipairs({"blue","orange"}) do
        update_anchor(color, portals[color])
    end
end)

-- ── rilevamento cornice ───────────────────────────────────────────────────────

local function try_activate_near(pos, frame_node, color, placer)
    local px,py,pz = pos.x,pos.y,pos.z
    local ppos = placer and placer:get_pos() or pos
    for _,axis in ipairs({0,1}) do
        -- Calcola range di corner interni che includono il blocco appena piazzato
        local h_lo = (axis==0) and (px-W)  or (pz-W)
        local h_hi = (axis==0) and (px+1)  or (pz+1)
        for ch=h_lo,h_hi do
            for cy=py-H,py+1 do
                local cx = (axis==0) and ch or px
                local cz = (axis==0) and pz or ch
                if check_frame(cx,cy,cz,axis,frame_node) then
                    local pp = portals[color]
                    local ns = normal_sign(axis, ppos, cx, cz)
                    if pp and pp.cx==cx and pp.cy==cy and pp.cz==cz and pp.axis==axis and pp.ns==ns then
                        return  -- già attivo
                    end
                    portals[color] = {cx=cx,cy=cy,cz=cz,axis=axis,ns=ns}
                    save_portals()
                    sync_portals()
                    update_anchor(color, portals[color])
                    minetest.chat_send_all("Portale "..color.." attivato!")
                    return
                end
            end
        end
    end
end

local function deactivate_if_frame(pos, color)
    local pp = portals[color]
    if not pp then return end
    local hit
    if pp.axis==0 then
        hit = pos.z==pp.cz
           and pos.x>=pp.cx-1 and pos.x<=pp.cx+W
           and pos.y>=pp.cy-1 and pos.y<=pp.cy+H
    else
        hit = pos.x==pp.cx
           and pos.z>=pp.cz-1 and pos.z<=pp.cz+W
           and pos.y>=pp.cy-1 and pos.y<=pp.cy+H
    end
    if hit then
        portals[color] = nil
        save_portals()
        sync_portals()
        update_anchor(color, nil)
        minetest.chat_send_all("Portale "..color.." disattivato.")
    end
end

-- ── registrazione nodi ────────────────────────────────────────────────────────

local function register_portal_block(name, desc, tex, color)
    minetest.register_node(name, {
        description = desc.."\n(cornice 4 larga × 5 alta, interno 2×3 aria)",
        tiles = {tex},
        groups = {cracky=3, oddly_breakable_by_hand=3},
        after_place_node = function(pos,placer) try_activate_near(pos,name,color,placer) end,
        after_dig_node   = function(pos) deactivate_if_frame(pos,color) end,
    })
end

register_portal_block(BLUE,   "Portale Blu",       "mio_portale_blue.png",   "blue")
register_portal_block(ORANGE, "Portale Arancione", "mio_portale_orange.png", "orange")

-- ── teletrasporto ────────────────────────────────────────────────────────────

-- 55% della larghezza di un nodo (0.5) dalla faccia frontale = 0.05 nodi
-- oltre il centro del frame verso il lato opposto.
local TRIGGER_DEPTH = 0.05

local player_states = {}

-- Ritorna true se il player è sul lato di costruzione (ns) del portale.
-- Usa -TRIGGER_DEPTH come soglia: player appena oltre il piano (max 5cm)
-- conta ancora come "lato frontale" (gestisce entrata laterale al bordo).
local function on_ns_side(ppos, pp)
    local ns = pp.ns or 1
    if pp.axis == 0 then
        return (ppos.z - pp.cz) * ns >= -TRIGGER_DEPTH
    else
        return (ppos.x - pp.cx) * ns >= -TRIGGER_DEPTH
    end
end

-- Profondità firmata del player rispetto al piano del portale (positivo = lato frontale).
local function portal_depth(ppos, pp)
    local ns = pp.ns or 1
    if pp.axis == 0 then
        return (ppos.z - pp.cz) * ns
    else
        return (ppos.x - pp.cx) * ns
    end
end

-- Ritorna true se il player ha superato il 55% dal lato da cui è entrato.
-- from_front=true: trigger a 55% dal fronte (lato ns).
-- from_front=false: trigger a 55% dal retro (lato opposto ns). Non usato in pratica.
local function past_trigger(ppos, pp, from_front)
    local d = portal_depth(ppos, pp)
    if from_front then
        return d < -TRIGGER_DEPTH   -- 55% dal fronte: supera il centro verso il retro
    else
        return d > TRIGGER_DEPTH    -- 55% dal retro: supera il centro verso il fronte
    end
end

-- Base locale del portale: restituisce (normal, right) come vettori mondo.
-- Stessa convenzione del C++ (right = normal × up).
local function portal_basis(pp)
    local ns = pp.ns or 1
    if pp.axis == 0 then
        return {x=0,y=0,z=ns}, {x=-ns,y=0,z=0}
    else
        return {x=ns,y=0,z=0}, {x=0,y=0,z=ns}
    end
end

local function dot(a, b) return a.x*b.x + a.y*b.y + a.z*b.z end

-- Posizione relativa: right negata (specchio spaziale).
local function portal_transform_pos(v, src_n, src_r, dst_n, dst_r)
    local lr = dot(v, src_r)
    local lu = v.y
    local ln = dot(v, src_n)
    -- Preserva la profondità esatta; margine minimo solo per evitare z=0 esatto.
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

-- Stessa trasformazione del C++ setVirtualCamera:
-- vdir = -lr*dst_r + lu*dst_u + (-ln)*dst_n
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

minetest.register_on_leaveplayer(function(player)
    local name = player:get_player_name()
    if player_states then
        player_states[name] = nil
    end
end)

minetest.register_globalstep(function(dtime)
    for _,player in ipairs(minetest.get_connected_players()) do
        local name = player:get_player_name()
        local ppos = player:get_pos()

        if not player_states[name] then
            player_states[name] = { blue = {}, orange = {} }
        end
        local state = player_states[name]

        if portals.blue and portals.orange then
            local src_color, dst_color

            for _, color in ipairs({"blue", "orange"}) do
                local pp = portals[color]
                local s = state[color]

                if in_portal_bounds(ppos, pp) then
                    local just_entered = not s.in_bounds
                    if just_entered then
                        -- Blocca il lato di entrata: solo il lato ns (frontale)
                        -- attiva il trigger. Dal lato opposto entered_from_front=false
                        -- e il trigger non scatterà mai.
                        s.in_bounds = true
                        s.entered_from_front = on_ns_side(ppos, pp)
                        s.triggered = false
                    end

                    -- Aggiorna ogni frame la vista del portale di destinazione
                    -- con la posizione di uscita proiettata.
                    if s.entered_from_front then
                        local other_color = (color == "blue") and "orange" or "blue"
                        local other = portals[other_color]
                        local src_n_c, src_r_c = portal_basis(pp)
                        local dst_n_c, dst_r_c = portal_basis(other)
                        local src_c_c = inner_center(pp.cx, pp.cy, pp.cz, pp.axis)
                        local dst_c_c = inner_center(other.cx, other.cy, other.cz, other.axis)
                        local rel_c = {x=ppos.x-src_c_c.x, y=ppos.y-src_c_c.y, z=ppos.z-src_c_c.z}
                        local off_c = portal_transform_pos(rel_c, src_n_c, src_r_c, dst_n_c, dst_r_c)
                        local dst_idx_c = (other_color == "blue") and 0 or 1
                        minetest.set_portal_cam_hint(dst_idx_c, {
                            x = dst_c_c.x + off_c.x,
                            y = dst_c_c.y + off_c.y,
                            z = dst_c_c.z + off_c.z,
                        })
                    end

                    -- Trigger normale: 55% oltre il centro del frame.
                    -- Eccezione bordo: primo ingresso laterale già al piano (d<=0)
                    -- evita che il player resti bloccato premuto contro la cornice.
                    local border_entry = just_entered and portal_depth(ppos, pp) <= 0
                    if s.entered_from_front and not s.triggered
                       and (past_trigger(ppos, pp, true) or border_entry)
                    then
                        s.triggered = true
                        src_color = color
                        dst_color = (color == "blue") and "orange" or "blue"
                    end
                else
                    s.in_bounds = false
                    s.triggered = false
                    -- Hint for the other portal no longer needed.
                    local other_color_c = (color == "blue") and "orange" or "blue"
                    local dst_idx_clear = (other_color_c == "blue") and 0 or 1
                    minetest.clear_portal_cam_hint(dst_idx_clear)
                end
            end

            if src_color and dst_color then
                local src = portals[src_color]
                local dst = portals[dst_color]

                local src_n, src_r = portal_basis(src)
                local dst_n, dst_r = portal_basis(dst)
                local src_c = inner_center(src.cx, src.cy, src.cz, src.axis)
                local dst_c = inner_center(dst.cx, dst.cy, dst.cz, dst.axis)

                local rel = {x=ppos.x-src_c.x, y=ppos.y-src_c.y, z=ppos.z-src_c.z}
                local new_off = portal_transform_pos(rel, src_n, src_r, dst_n, dst_r)
                local new_pos = {
                    x = dst_c.x + new_off.x,
                    y = dst_c.y + new_off.y,
                    z = dst_c.z + new_off.z,
                }

                local vel = player:get_velocity() or {x=0,y=0,z=0}
                local new_vel = portal_transform_dir(vel, src_n, src_r, dst_n, dst_r)

                local look = player:get_look_dir()
                local new_look = portal_transform_dir(look, src_n, src_r, dst_n, dst_r)
                local new_yaw = math.atan2(-new_look.x, new_look.z)
                local cur_yaw = player:get_look_horizontal()

                local dst_idx = (dst_color == "blue") and 0 or 1

                -- Pre-renderizza la RTT del portale di destinazione dalla posizione
                -- di uscita prima che il player si teletrasporti, per evitare il
                -- flash di un frame con l'immagine vecchia.
                minetest.set_portal_cam_hint(dst_idx, new_pos)

                -- portal_teleport invia UN solo pacchetto TOCLIENT_PORTAL_TELEPORT
                -- con pos + yaw + vel_delta; il client snappa la camera senza damping.
                player:portal_teleport(new_pos, new_yaw, {
                    x = new_vel.x - vel.x,
                    y = new_vel.y - vel.y,
                    z = new_vel.z - vel.z,
                })

                -- Sorgente: reset completo.
                state[src_color] = { in_bounds = false }
                -- Destinazione: entered_from_front=false blocca re-trigger anche se
                -- il player finisce nei bounds del dst (arriva dal lato posteriore).
                state[dst_color] = {
                    in_bounds          = in_portal_bounds(new_pos, portals[dst_color]),
                    entered_from_front = false,
                    triggered          = true,
                }
            end
        else
            state.blue   = { in_bounds = false }
            state.orange = { in_bounds = false }
        end
    end
end)
