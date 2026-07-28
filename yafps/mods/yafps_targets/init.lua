-- yafps_targets — PvE population: static cube targets on the cover pillars
-- and drones orbiting above the arena. Each entity remembers its home spot
-- and respawns there a few seconds after dying.

yafps.targets = {}

local storage = minetest.get_mod_storage()
local RESPAWN = 5

local function die_fx(pos)
    minetest.add_particlespawner({
        amount = 20,
        time = 0.1,
        pos = pos,
        vel = {min = {x = -4, y = -1, z = -4}, max = {x = 4, y = 5, z = 4}},
        acc = {min = {x = 0, y = -8, z = 0}, max = {x = 0, y = -8, z = 0}},
        exptime = {min = 0.3, max = 0.8},
        size = {min = 1, max = 2.5},
        texture = "yafps_spark.png",
        glow = 12,
    })
end

function yafps.targets.spawn(kind, pos)
    return minetest.add_entity(pos, "yafps_targets:" .. kind,
        minetest.write_json(pos))
end

local function make_def(kind, props, extra)
    local def = {
        initial_properties = props,
        on_activate = function(self, staticdata)
            self.object:set_armor_groups({fleshy = 100})
            local home = staticdata ~= "" and minetest.parse_json(staticdata)
            self.home = home or vector.round(self.object:get_pos())
        end,
        get_staticdata = function(self)
            return minetest.write_json(self.home)
        end,
        on_death = function(self, killer)
            local pos = self.object:get_pos()
            die_fx(pos)
            if killer and killer:is_player() then
                minetest.chat_send_player(killer:get_player_name(),
                    "[yafps] " .. kind .. " down")
            end
            local home = self.home
            minetest.after(RESPAWN, function()
                yafps.targets.spawn(kind, home)
            end)
        end,
    }
    for k, v in pairs(extra or {}) do
        def[k] = v
    end
    return def
end

minetest.register_entity("yafps_targets:target", make_def("target", {
    visual = "cube",
    textures = {"yafps_target.png", "yafps_target.png", "yafps_target.png",
                "yafps_target.png", "yafps_target.png", "yafps_target.png"},
    visual_size = {x = 0.7, y = 0.7, z = 0.7},
    physical = false,
    collide_with_objects = false,
    collisionbox = {-0.35, -0.35, -0.35, 0.35, 0.35, 0.35},
    hp_max = 8,
    glow = 6,
}))

minetest.register_entity("yafps_targets:drone", make_def("drone", {
    visual = "cube",
    textures = {"yafps_drone.png", "yafps_drone.png", "yafps_drone.png",
                "yafps_drone.png", "yafps_drone.png", "yafps_drone.png"},
    visual_size = {x = 0.5, y = 0.5, z = 0.5},
    physical = false,
    collide_with_objects = false,
    collisionbox = {-0.25, -0.25, -0.25, 0.25, 0.25, 0.25},
    hp_max = 8,
    glow = 4,
    automatic_rotate = 1.5,
}, {
    -- spring toward a point orbiting home: smooth without physics
    on_step = function(self, dtime)
        self.t = (self.t or math.random() * 6) + dtime
        local a = self.t * 0.8
        local home = self.home or self.object:get_pos()
        local want = {
            x = home.x + math.cos(a) * 4,
            y = home.y + math.sin(self.t * 2) * 0.4,
            z = home.z + math.sin(a) * 4,
        }
        local cur = self.object:get_pos()
        self.object:set_velocity(
            vector.multiply(vector.subtract(want, cur), 3))
    end,
}))

-- first population, once per world (afterwards death->respawn keeps it alive)
minetest.register_on_mods_loaded(function()
    minetest.after(3, function()
        if storage:get_int("populated") == 1 then
            return
        end
        local g = yafps.arena.ground
        for _, p in ipairs({{8, 8}, {-8, -8}, {0, 12}, {-12, 0}}) do
            yafps.targets.spawn("target", {x = p[1], y = g + 3.2, z = p[2]})
        end
        yafps.targets.spawn("drone", {x = 6, y = g + 5, z = -6})
        yafps.targets.spawn("drone", {x = -6, y = g + 5, z = 6})
        storage:set_int("populated", 1)
        minetest.log("action", "[yafps_targets] populated")
    end)
end)
