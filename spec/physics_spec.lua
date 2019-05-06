-- FIXME ideally, don't do this
_G.love = {
    filesystem = {
        -- FIXME used in util's file reading stuff, which is called directly by TiledMap:parse_json_file
        read = function(path)
            local f, err = io.open(path, 'rb')
            if not f then
                error(err)
            end
            local data = f:read('*all')
            f:close()
            return data
        end,
    },
}

local Vector = require 'klinklang.vendor.hump.vector'

local actors_base = require 'klinklang.actors.base'
local ResourceManager = require 'klinklang.resources'
local tiledmap = require 'klinklang.tiledmap'
local whammo_shapes = require 'klinklang.whammo.shapes'
local world_mod = require 'klinklang.world'


local DT = 1/4

describe("Sentient actors", function()
    it("should stay still on a slope", function()
        local resource_manager = ResourceManager()
        -- FIXME? this is relative to the klinklang root, not relative to this file
        local tiled_map = tiledmap.TiledMap:parse_json_file('spec/data/physicsmap.tmx.json', resource_manager)

        -- FIXME would be nice to get the data from the test map since this is kind of unreadable
        -- FIXME wow gosh, creating (spriteless) actors manually is a pain.
        -- this doesn't work because Actor and everything below it //expects//
        -- to have a sprite name
        local player = actors_base.SentientActor(Vector(256 - 16, 256))
        player:set_shape(whammo_shapes.Box(-16, -32, 32, 32))

        local world = world_mod.World(player)
        local map = world_mod.Map(world, tiled_map, nil)

        -- FIXME i realize i am not actually sure how the player ends up in the map normally??
        map:add_actor(player)

        map.collider:add(whammo_shapes.Polygon(0, 512, 512, 0, 512, 512))

        -- FIXME need to do one update because the player won't realize it's on the ground to start with
        -- FIXME fix that, seriously, christ
        map:update(DT)

        local original_pos = player.pos
        for _ = 1, 4 do
            map:update(DT)
            assert.are.equal(player.pos, original_pos)
        end
        -- FIXME i'd love if, on failure, i got an svg or something of all the
        -- actors and their physics state
    end)
end)
