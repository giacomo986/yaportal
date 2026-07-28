-- yafps_core — foundations of the YaFPS arena game: nodes, hand, mapgen
-- biome, player setup. Every media file is prefixed "yafps_": the dual-client
-- portal shares the texture cache between the two games by name, so a unique
-- prefix is what keeps VoxeLibre's textures intact (see AGENTS.MD).

rawset(_G, "yafps", rawget(_G, "yafps") or {})

-- ── nodes ────────────────────────────────────────────────────────────────────

minetest.register_node("yafps_core:floor", {
    description = "Arena floor",
    tiles = {"yafps_floor.png"},
    groups = {cracky = 3, oddly_breakable_by_hand = 3},
})

minetest.register_node("yafps_core:base", {
    description = "Arena base rock",
    tiles = {"yafps_base.png"},
    groups = {cracky = 3, oddly_breakable_by_hand = 3},
})

minetest.register_node("yafps_core:wall", {
    description = "Arena wall panel",
    tiles = {"yafps_wall.png"},
    groups = {cracky = 3, oddly_breakable_by_hand = 3},
})

minetest.register_node("yafps_core:light", {
    description = "Arena light",
    tiles = {"yafps_light.png"},
    light_source = 14,
    groups = {cracky = 3, oddly_breakable_by_hand = 3},
})

-- ── mapgen: flat world made of our own nodes ─────────────────────────────────

minetest.register_alias("mapgen_stone", "yafps_core:base")
minetest.register_alias("mapgen_water_source", "air")
minetest.register_alias("mapgen_river_water_source", "air")

minetest.register_biome({
    name = "yafps_core:plain",
    node_top = "yafps_core:floor",
    depth_top = 1,
    node_filler = "yafps_core:base",
    depth_filler = 3,
    node_stone = "yafps_core:base",
    heat_point = 50,
    humidity_point = 50,
    y_min = -31000,
    y_max = 31000,
})

-- ── hand ─────────────────────────────────────────────────────────────────────
-- Covers every dig group used by yafps and by the yaportal/yaportal_link
-- nodes (cracky, oddly_breakable_by_hand, dig_immediate), so frames stay
-- diggable without any game-specific tool.

minetest.override_item("", {
    tool_capabilities = {
        full_punch_interval = 0.5,
        max_drop_level = 0,
        groupcaps = {
            cracky = {times = {[1] = 2.0, [2] = 1.0, [3] = 0.5}, uses = 0},
            crumbly = {times = {[1] = 1.0, [2] = 0.5, [3] = 0.25}, uses = 0},
            snappy = {times = {[1] = 1.0, [2] = 0.5, [3] = 0.25}, uses = 0},
            choppy = {times = {[1] = 2.0, [2] = 1.0, [3] = 0.5}, uses = 0},
            oddly_breakable_by_hand =
                {times = {[1] = 1.0, [2] = 0.5, [3] = 0.25}, uses = 0},
            dig_immediate = {times = {[2] = 0.5, [3] = 0}, uses = 0},
        },
        damage_groups = {fleshy = 2},
    },
})

-- ── player setup ─────────────────────────────────────────────────────────────
-- Everything here must run synchronously inside the join callback: game mods
-- load before world mods, so this runs before yaportal_link's park() snapshots
-- physics for ghost players. Deferring it (minetest.after) would make park()
-- snapshot the wrong values and un-park ghosts with default physics.

local SKY = {
    type = "regular",
    clouds = false,
    sky_color = {
        day_sky = "#20242e", day_horizon = "#3a4150",
        dawn_sky = "#20242e", dawn_horizon = "#3a4150",
        night_sky = "#151920", night_horizon = "#252b36",
        indoors = "#20242e",
        fog_sun_tint = "#000000", fog_moon_tint = "#000000",
        fog_tint_type = "custom",
    },
}

minetest.register_on_joinplayer(function(player)
    player:set_physics_override({speed = 2.2, jump = 1.6, gravity = 1.0})
    player:set_sky(SKY)
    player:set_sun({visible = false, sunrise_visible = false})
    player:set_moon({visible = false})
    player:set_stars({visible = true, count = 700, star_color = "#5f6d80"})
    player:hud_set_hotbar_itemcount(4)
end)

minetest.register_on_respawnplayer(function(player)
    player:set_pos(minetest.setting_get_pos("static_spawnpoint")
        or {x = 0, y = 10, z = 0})
    return true
end)

minetest.register_on_mods_loaded(function()
    -- set_timeofday is rejected during script init, mods_loaded included
    minetest.after(0, function() minetest.set_timeofday(0.5) end)
    minetest.log("action", "[yafps_core] ready")
end)
