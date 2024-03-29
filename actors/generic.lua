local Vector = require 'klinklang.vendor.hump.vector'

local Object = require 'klinklang.object'
local actors_base = require 'klinklang.actors.base'
local actors_misc = require 'klinklang.actors.misc'
local whammo_shapes = require 'klinklang.whammo.shapes'


local GenericSlidingDoor = actors_base.Actor:extend{
    is_solid = true,

    -- Configuration
    door_width = 16,

    -- State
    door_height = 0,
    busy = false,
}

function GenericSlidingDoor:init(...)
    GenericSlidingDoor.__super.init(self, ...)

    self.sprite:set_pose('middle')

    -- TODO this would be nice
    --[[
    self.sfx = game.resource_manager:get('assets/sounds/stonegrind.ogg'):clone()
    self.sfx:setVolume(0.75)
    self.sfx:setLooping(true)
    self.sfx:setPosition(self.pos.x, self.pos.y, 0)
    self.sfx:setAttenuationDistances(game.TILE_SIZE * 4, game.TILE_SIZE * 32)
    ]]
end

-- FIXME what happens if you stick a rune in an open doorway?
function GenericSlidingDoor:on_enter(...)
    GenericSlidingDoor.__super.on_enter(self, ...)

    -- Do a shape cast to figure out how tall the door should be
    local test_shape = whammo_shapes.Box(-12, 0, 24, 1)
    test_shape:move(self.pos:unpack())
    local movement = self.map.collider:sweep(test_shape, Vector(0, 256), function(collision)
        return not collision.their_owner:blocks(self, collision)
    end)
    -- Add a pixel to make up for the height of the test shape
    -- TODO technically this isn't right if there's a gap of 1px...
    self.door_height = movement.y + 1
    self:set_shape(whammo_shapes.Box(-12, 0, 24, self.door_height))
end

function GenericSlidingDoor:on_leave()
    --self.sfx:stop()
end

function GenericSlidingDoor:update(dt)
end

-- FIXME this makes some assumptions about anchors that i'm pretty sure could be either less necessary or more meaningful
function GenericSlidingDoor:draw()
    if self.door_height <= 0 then
        return
    end

    local pt = self.pos - self.sprite.anchor
    love.graphics.push('all')
    -- FIXME maybe worldscene needs a helper for this
    -- FIXME lot of hardcoded numbers here
    love.graphics.setScissor(pt.x - self.map.world.camera.x, pt.y - self.map.world.camera.y, 32, self.door_height)
    local height = self.door_height + (-self.door_height) % 32
    local top = pt.y - (-self.door_height) % 32
    local bottom = pt.y + self.door_height, 32
    for y = top, bottom, 32 do
        local sprite = self.sprite.anim
        if y == bottom - 32 then
            -- FIXME invasive...
            sprite = self.sprite.spriteset.poses['end'].right.animation
        end
        sprite:draw(self.sprite.spriteset.image, math.floor(pt.x), math.floor(y))
    end
    love.graphics.pop()
end

function GenericSlidingDoor:open()
    if self.busy then
        return
    end
    self.busy = true
    if self.door_height <= 32 then
        return
    end

    -- FIXME i would like some little dust clouds
    -- FIXME grinding noise
    -- FIXME what happens if the door hits something?
    local height = self.door_height
    local time = height / 30
    self.map.flux:to(self, time, { door_height = 32 })
        :ease('linear')
        -- TODO would be nice to build the shape from individual sprite collisions
        :onupdate(function() self:set_shape(whammo_shapes.Box(-12, 0, 24, self.door_height)) end)
        --:onstart(function() self.sfx:play() end)
        --:oncomplete(function() self.sfx:stop() end)
    -- FIXME closing should be configurable
    --[[
        :after(time, { door_height = height })
        :delay(4)
        :ease('linear')
        :onupdate(function() self:set_shape(whammo_shapes.Box(-12, 0, 24, self.door_height)) end)
        :oncomplete(function() self.busy = false end)
        --:onstart(function() self.sfx:play() end)
        --:oncomplete(function() self.sfx:stop() end)
    ]]
end

function GenericSlidingDoor:open_instant()
    if self.busy then
        -- FIXME this should cancel an ongoing open(), surely
        return
    end
    if self.door_height <= 32 then
        return
    end

    self.door_height = 32
    self:set_shape(whammo_shapes.Box(-12, 0, 24, self.door_height))
end



local GenericSlidingDoorShutter = actors_base.Actor:extend{
    is_solid = true,

    -- Configuration
    door_type = nil,
}

function GenericSlidingDoorShutter:init(...)
    actors_base.Actor.init(self, ...)
end

function GenericSlidingDoorShutter:on_enter(...)
    GenericSlidingDoorShutter.__super.on_enter(self, ...)
    local door = self.door_type(self.pos)
    self.ptrs.door = door
    self.map:add_actor(door)
end

function GenericSlidingDoorShutter:open()
    -- FIXME support this, but also turn it off when the door is off
    --self.sprite:set_pose('active')
    self.ptrs.door:open()
end

function GenericSlidingDoorShutter:open_instant()
    self.ptrs.door:open_instant()
end


local LadderZone = actors_base.BareActor:extend{
    name = 'ladder',

    is_climbable = true,
}

function LadderZone:init(pos, props, shapes)
    -- FIXME?
    self.shape = shapes[1]
    LadderZone.__super.init(self, pos)
end


return {
    GenericSlidingDoor = GenericSlidingDoor,
    GenericSlidingDoorShutter = GenericSlidingDoorShutter,
    GenericLadder = GenericLadder,
    LadderZone = LadderZone,
}
