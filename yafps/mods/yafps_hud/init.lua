-- yafps_hud — crosshair image plus an ammo counter that follows the wielded
-- rifle's meta. Display-only: it polls, so it needs no hooks in yafps_weapons.

yafps.hud = {}

local huds = {}     -- player name -> {cross = id, ammo = id, last = text}

minetest.register_on_joinplayer(function(player)
    player:hud_set_flags({crosshair = false})
    huds[player:get_player_name()] = {
        cross = player:hud_add({
            type = "image",
            position = {x = 0.5, y = 0.5},
            text = "yafps_crosshair.png",
            scale = {x = 2, y = 2},
            alignment = {x = 0, y = 0},
            z_index = 100,
        }),
        ammo = player:hud_add({
            type = "text",
            position = {x = 0.5, y = 1},
            text = "",
            number = 0xDFF4FF,
            size = {x = 2, y = 2},
            alignment = {x = 0, y = -1},
            offset = {x = 0, y = -40},
            z_index = 100,
        }),
    }
end)

minetest.register_on_leaveplayer(function(player)
    huds[player:get_player_name()] = nil
end)

local acc = 0
minetest.register_globalstep(function(dtime)
    acc = acc + dtime
    if acc < 0.2 then
        return
    end
    acc = 0
    for _, player in ipairs(minetest.get_connected_players()) do
        local name = player:get_player_name()
        local h = huds[name]
        if h then
            local w = player:get_wielded_item()
            local txt = ""
            if w:get_name() == "yafps_weapons:rifle" then
                if yafps.weapons.is_reloading(name) then
                    txt = "RELOADING"
                else
                    txt = yafps.weapons.get_ammo(w)
                        .. " / " .. yafps.weapons.mag_size()
                end
            end
            if txt ~= h.last then
                h.last = txt
                player:hud_change(h.ammo, "text", txt)
            end
        end
    end
end)
