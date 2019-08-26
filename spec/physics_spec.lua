-- FIXME ideally, don't do this
_G.love = {
}
-- FIXME this either
_G.game = {
    -- FIXME deep in components
    time_push = function() end,
    time_pop = function() end,
}

local Vector = require 'klinklang.vendor.hump.vector'

local actors_base = require 'klinklang.actors.base'
local actors_map = require 'klinklang.actors.map'
local components_cargo = require 'klinklang.components.cargo'
local specutil = require 'klinklang.spec.util'
local whammo_shapes = require 'klinklang.whammo.shapes'
local world_mod = require 'klinklang.world'


local DT = 1/4

describe("Sentient actors", function()
    it("should stay still on a slope", function()
        -- FIXME might be nice to get data from a test map, or otherwise
        -- describe maps in a more readable way
        local player = actors_base.SentientActor(Vector(100 - 10, 100))
        player:set_shape(whammo_shapes.Box(-10, -20, 20, 20))

        local world = world_mod.World(player)
        local map = world_mod.Map(world, 200, 200)
        -- FIXME i realize i am not actually sure how the player ends up in the map normally??
        map:add_actor(player)

        map:add_actor(actors_map.MapCollider(whammo_shapes.Polygon(0, 200, 200, 0, 200, 200)))

        -- FIXME need to do one update because the player won't realize it's on the ground to start with
        -- FIXME fix that, seriously, christ
        map:update(DT)

        specutil.dump_svg_on_error(map, function()
            local original_pos = player.pos
            for _ = 1, 4 do
                map:update(DT)
                assert.are.equal(player.pos, original_pos)
            end
        end)
    end)
end)

describe("Tote actors", function()
    it("should notice they have cargo", function()
        -- FIXME might be nice to get data from a test map, or otherwise
        -- describe maps in a more readable way
        local player = actors_base.SentientActor(Vector(100, 100))
        player:set_shape(whammo_shapes.Box(-10, -20, 20, 20))
        player.is_portable = true

        local platform = actors_base.MobileActor(Vector(100, 100))
        platform:set_shape(whammo_shapes.Box(-50, 0, 100, 100))
        local tote = components_cargo.Tote(platform)
        platform.can_carry = true
        platform.components['tote'] = tote

        local world = world_mod.World(player)
        local map = world_mod.Map(world, 200, 200)
        -- FIXME i realize i am not actually sure how the player ends up in the map normally??
        map:add_actor(player)
        map:add_actor(platform)

        -- Do one sync update so the player knows it's on the platform
        -- FIXME fix that too?
        map:update(DT)

        specutil.dump_svg_on_error(map, function()
            -- Check that the player gets, basically, carried around
            local player_pos = player.pos
            local delta = Vector(50, 0)
            platform:get('move'):nudge(delta)
            assert.are.equal(player.pos, player_pos + delta)

            player_pos = player_pos + delta
            delta = Vector(0, -50)
            platform:get('move'):nudge(delta)
            assert.are.equal(player.pos, player_pos + delta)
        end)
    end)
end)
