-- yafps_weapons — hitscan rifle. The shot is a server-side raycast: at local
-- latencies (all worlds run on this machine) there is no need for any lag
-- compensation, so the server ray is authoritative.

yafps.weapons = {}

local RANGE = 60
local DAMAGE = 4
local MAG = 12
local RELOAD_TIME = 1.2
local FIRE_US = 180 * 1000      -- min microseconds between shots

local RIFLE = "yafps_weapons:rifle"

local last_fire = {}            -- player name -> us timestamp of last shot
local reloading = {}            -- player name -> true while a reload pends

function yafps.weapons.mag_size()
    return MAG
end

function yafps.weapons.is_reloading(name)
    return reloading[name] == true
end

function yafps.weapons.get_ammo(stack)
    local m = stack:get_meta()
    if m:get_string("ammo") == "" then
        return MAG
    end
    return m:get_int("ammo")
end

local function set_ammo(stack, n)
    stack:get_meta():set_int("ammo", n)
    stack:set_wear(math.min(65534, math.floor(65535 * (1 - n / MAG))))
end

local function tracer(origin, hitpos)
    local dist = vector.distance(origin, hitpos)
    local dir = vector.direction(origin, hitpos)
    for d = 2, dist, 1.5 do
        minetest.add_particle({
            pos = vector.add(origin, vector.multiply(dir, d)),
            expirationtime = 0.08,
            size = 1.2,
            texture = "yafps_tracer.png",
            glow = 14,
        })
    end
end

local function impact(pos)
    minetest.add_particlespawner({
        amount = 8,
        time = 0.05,
        pos = pos,
        vel = {min = {x = -2, y = -2, z = -2}, max = {x = 2, y = 2, z = 2}},
        exptime = {min = 0.1, max = 0.25},
        size = {min = 0.8, max = 1.6},
        texture = "yafps_spark.png",
        glow = 12,
    })
end

-- Testable core: raycast from origin along dir, damage the first object hit
-- (skipping the shooter), sparks on nodes. shooter is optional (nil in the
-- headless selftest). Returns the hit pointed_thing, or nil on a miss.
function yafps.weapons.fire_ray(origin, dir, shooter)
    local ray = minetest.raycast(origin,
        vector.add(origin, vector.multiply(dir, RANGE)), true, false)
    for pt in ray do
        if pt.type == "object" then
            local obj = pt.ref
            if not (shooter and obj == shooter) then
                local hitpos = pt.intersection_point or obj:get_pos()
                if shooter then
                    obj:punch(shooter, 1.0, {
                        full_punch_interval = 0.2,
                        damage_groups = {fleshy = DAMAGE},
                    }, dir)
                else
                    obj:set_hp(obj:get_hp() - DAMAGE, {type = "punch"})
                end
                tracer(origin, hitpos)
                impact(hitpos)
                return pt
            end
        elseif pt.type == "node" then
            tracer(origin, pt.intersection_point)
            impact(pt.intersection_point)
            return pt
        end
    end
    tracer(origin, vector.add(origin, vector.multiply(dir, RANGE)))
    return nil
end

local function start_reload(itemstack, user)
    if not (user and user:is_player()) then
        return itemstack
    end
    local name = user:get_player_name()
    if reloading[name] or yafps.weapons.get_ammo(itemstack) >= MAG then
        return itemstack
    end
    reloading[name] = true
    minetest.sound_play("yafps_reload", {to_player = name}, true)
    minetest.after(RELOAD_TIME, function()
        reloading[name] = nil
        local player = minetest.get_player_by_name(name)
        if not player then
            return
        end
        local w = player:get_wielded_item()
        if w:get_name() == RIFLE then
            set_ammo(w, MAG)
            player:set_wielded_item(w)
        end
    end)
    return itemstack
end

local function do_fire(itemstack, user)
    if not (user and user:is_player()) then
        return itemstack
    end
    local name = user:get_player_name()
    if reloading[name] then
        return itemstack
    end
    local now = minetest.get_us_time()
    if last_fire[name] and now - last_fire[name] < FIRE_US then
        return itemstack
    end
    last_fire[name] = now
    local ammo = yafps.weapons.get_ammo(itemstack)
    if ammo <= 0 then
        minetest.sound_play("yafps_dry", {to_player = name}, true)
        return start_reload(itemstack, user)
    end
    ammo = ammo - 1
    set_ammo(itemstack, ammo)
    local origin = user:get_pos()
    origin.y = origin.y + (user:get_properties().eye_height or 1.625)
    minetest.sound_play("yafps_shot", {pos = origin, max_hear_distance = 48}, true)
    yafps.weapons.fire_ray(origin, user:get_look_dir(), user)
    if ammo == 0 then
        return start_reload(itemstack, user)
    end
    return itemstack
end

minetest.register_tool(RIFLE, {
    description = "Rifle (left: fire, right: reload)",
    inventory_image = "yafps_rifle.png",
    wield_image = "yafps_rifle.png",
    wield_scale = {x = 1.5, y = 1.5, z = 1.5},
    range = 4,
    on_use = do_fire,
    on_secondary_use = start_reload,
    on_place = function(itemstack, placer, pointed_thing)
        return start_reload(itemstack, placer)
    end,
})

minetest.register_on_joinplayer(function(player)
    local inv = player:get_inventory()
    if not inv:contains_item("main", RIFLE) then
        inv:add_item("main", RIFLE)
    end
end)

minetest.register_on_leaveplayer(function(player)
    local name = player:get_player_name()
    last_fire[name] = nil
    reloading[name] = nil
end)
