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
local whammo_shapes = require 'klinklang.whammo.shapes'
local world_mod = require 'klinklang.world'


local DT = 1/4

describe("Sentient actors", function()
    it("should stay still on a slope", function()
        -- FIXME would be nice to get the data from the test map since this is kind of unreadable
        -- FIXME wow gosh, creating (spriteless) actors manually is a pain.
        -- this doesn't work because Actor and everything below it //expects//
        -- to have a sprite name
        local player = actors_base.SentientActor(Vector(256 - 16, 256))
        player:set_shape(whammo_shapes.Box(-16, -32, 32, 32))

        local world = world_mod.World(player)
        local map = world_mod.Map(world, 512, 512)

        -- FIXME i realize i am not actually sure how the player ends up in the map normally??
        map:add_actor(player)

        local slope = actors_map.MapCollider(whammo_shapes.Polygon(0, 512, 512, 0, 512, 512))
        map:add_actor(slope)

        -- FIXME need to do one update because the player won't realize it's on the ground to start with
        -- FIXME fix that, seriously, christ
        map:update(DT)

        local status, err = xpcall(function()
            local original_pos = player.pos
            for _ = 1, 4 do
                collectgarbage()
                map:update(DT)
                assert.are.equal(player.pos, original_pos)
            end
        end, debug.traceback)
        if not status then
            local function tag(name, attrs)
                local parts = {name}
                for key, value in pairs(attrs) do
                    table.insert(parts, key .. '="' .. tostring(value) .. '"')
                end
                return '<' .. table.concat(parts, ' ') .. ' />'

            end

            local parts = {}
            table.insert(parts, '<?xml version="1.0" encoding="UTF-8"?>')
            table.insert(parts, '<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">')
--<svg xmlns:xlink="http://www.w3.org/1999/xlink" version="1.1" viewBox="-800 -400 1600 800" width="100%" height="100%">
            table.insert(parts, ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="%d %d %d %d">'):format(-64, -64, map.width + 128, map.height + 128))
            table.insert(parts, '<style>path, rect { fill: #f444; }</style>')
            for shape in pairs(map.collider.shapes) do
                if shape:isa(whammo_shapes.Box) then
                    table.insert(parts, tag('rect', {x = shape.x0, y = shape.y0, width = shape.width, height = shape.height}))
                elseif shape:isa(whammo_shapes.Polygon) then
                    local d = {}
                    for i, point in ipairs(shape.points) do
                        if i == 1 then
                            table.insert(d, 'M')
                        else
                            table.insert(d, 'L')
                        end
                        table.insert(d, tostring(point.x))
                        table.insert(d, tostring(point.y))
                    end
                    table.insert(d, 'z')
                    table.insert(parts, tag('path', {d = table.concat(d, ' ')}))
                end
            end
            table.insert(parts, tag('rect', {x1 = 0, y1 = 0, width = map.width, height = map.height, fill = 'none', stroke = '#999'}))
            table.insert(parts, '</svg>')
            local f = io.open('klinklang-test-failure.svg', 'w')
            f:write(table.concat(parts, '\n'))
            f:close()

            error(err)
        end
        -- FIXME i'd love if, on failure, i got an svg or something of all the
        -- actors and their physics state
    end)
end)
