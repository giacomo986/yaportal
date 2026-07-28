-- yafps_arena — builds the spawn arena once per world: a walled square on the
-- flat ground around the static spawn point, with lights and cover blocks.

local storage = minetest.get_mod_storage()

local GROUND = 8   -- mgflat default ground level: top solid node sits at y=8
local R = 20       -- arena half-size
local H = 5        -- wall height

yafps.arena = {ground = GROUND, radius = R}

local function set(x, y, z, name)
    minetest.set_node({x = x, y = y, z = z}, {name = name})
end

local function build_arena()
    -- perimeter walls with a light strip on top
    for i = -R, R do
        for _, p in ipairs({{i, R}, {i, -R}, {R, i}, {-R, i}}) do
            for dy = 1, H do
                set(p[1], GROUND + dy, p[2], "yafps_core:wall")
            end
            set(p[1], GROUND + H + 1, p[2],
                i % 5 == 0 and "yafps_core:light" or "yafps_core:wall")
        end
    end
    -- cover pillars inside the arena
    for _, p in ipairs({{8, 8}, {8, -8}, {-8, 8}, {-8, -8},
                        {0, 12}, {0, -12}, {12, 0}, {-12, 0}}) do
        for dy = 1, 2 do
            set(p[1], GROUND + dy, p[2], "yafps_core:wall")
        end
    end
    -- lit center marker
    set(0, GROUND, 0, "yafps_core:light")
end

-- Pre-built cross-world door: when the yaportal_link frame exists (a world
-- created from the /porte panel loads those mods), carve a doorway into the
-- north wall and activate it, so a fresh yafps world is born with its own
-- door already listed in the panel.
local function build_door()
    local F = "yaportal_link:frame"
    if not minetest.registered_nodes[F] then
        return
    end
    local xw = rawget(_G, "yaportal") and yaportal.xworld
    if not (xw and xw.activate_frame) then
        return
    end
    local z = -R
    for x = -1, 2 do
        for y = GROUND, GROUND + 4 do
            local border = x == -1 or x == 2 or y == GROUND or y == GROUND + 4
            set(x, y, z, border and F or "air")
        end
    end
    -- activate_frame only reads placer:get_pos(), used for the door's facing:
    -- a stand-in position inside the arena makes it open toward the player.
    xw.activate_frame({x = 0, y = GROUND + 1, z = z}, F, {
        get_pos = function()
            return {x = 0, y = GROUND + 2, z = z + 4}
        end,
    })
    minetest.log("action", "[yafps_arena] cross-world door ready")
end

minetest.register_on_mods_loaded(function()
    minetest.after(1, function()
        if storage:get_int("arena_built") == 1 then return end
        local r = R + 2
        minetest.emerge_area(
            {x = -r, y = GROUND - 2, z = -r},
            {x = r, y = GROUND + H + 2, z = r},
            function(blockpos, action, remaining)
                if remaining > 0 then return end
                build_arena()
                build_door()
                storage:set_int("arena_built", 1)
                minetest.log("action", "[yafps_arena] arena built")
            end)
    end)
end)
