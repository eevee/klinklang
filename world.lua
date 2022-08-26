local flux = require 'klinklang.vendor.flux'
local tick = require 'klinklang.vendor.tick'
local Vector = require 'klinklang.vendor.hump.vector'

local AABB = require 'klinklang.aabb'
local actors_base = require 'klinklang.actors.base'
local actors_map = require 'klinklang.actors.map'
local Object = require 'klinklang.object'
local tiledmap = require 'klinklang.tiledmap'
local util = require 'klinklang.util'
local whammo = require 'klinklang.whammo'
local whammo_shapes = require 'klinklang.whammo.shapes'


-- Camera that smoothly catches up to its target.
-- Attempts to keep the target within a particular part of the screen:
-- | C |  B  |    A    |  B  | C |
-- If the subject is within region A, all is well, and the camera won't move.
-- If the subject is within region B, the camera will attempt to move to put them within region
-- A.  The camera's movement speed is proportional to how deep into region B they are; it will
-- ramp from min_speed to max_speed.  You can set these to the same value to disable the varying
-- movement speed.
-- If the subject is within region C, the camera will immediately snap to put the subject back
-- within region B.
--
-- 
--
-- Has several interesting special cases:
-- 1. If the target is outside 
local Camera = Object:extend{
    xmin = -math.huge,
    ymin = -math.huge,
    xmax = math.huge,
    ymax = math.huge,
    -- TODO what happens if i just don't provide these?
    width = 0,
    height = 0,
    x = 0,
    y = 0,
    rounded_x = 0,
    rounded_y = 0,
    margin_left = 0.33,
    margin_right = 0.33,
    margin_top = 0.33,
    margin_bottom = 0.33,
    panic_margin_left = 0,
    panic_margin_right = 0,
    panic_margin_top = 0,
    panic_margin_bottom = 0,
    x_min_speed = 64,
    x_max_speed = 1024,
    y_min_speed = 64,
    y_max_speed = 1024,

    -- Acceleration and maximum speed when shifting the camera
    max_speed = nil,
    velocity = nil,
}

function Camera:init()
    self.velocity = Vector()
end

function Camera:clone()
    local camera = getmetatable(self)()
    camera:set_size(self.width, self.height)
    camera:set_bounds(self.xmin, self.ymin, self.xmax, self.ymax)
    camera.margin_left = self.margin_left
    camera.margin_right = self.margin_right
    camera.margin_top = self.margin_top
    camera.margin_bottom = self.margin_bottom
    camera.x = self.x
    camera.y = self.y
    return camera
end

function Camera:set_size(width, height)
    self.width = width
    self.height = height
end

function Camera:set_bounds(xmin, ymin, xmax, ymax)
    self.xmin = xmin
    self.xmax = xmax
    self.ymin = ymin
    self.ymax = ymax
end

function Camera:clear_bounds()
    self.xmin = -math.huge
    self.xmax = math.huge
    self.ymin = -math.huge
    self.ymax = math.huge
end

function Camera:set_margins(left, right, top, bottom)
    self.margin_left = left
    self.margin_right = right
    self.margin_top = top
    self.margin_bottom = bottom
end

function Camera:aabb()
    return AABB(self.x, self.y, self.width, self.height)
end

-- This is intended to be used as a quick test against the position of an actor whose size is much
-- smaller than the size of the screen, hence the vague name.  In practice it returns true if the
-- point is less than half a screen size outside of the actual camera view
function Camera:fuzzy_includes_point(x, y)
    return (
        self.x - self.width / 2 < x and x < self.x + self.width * 3 / 2 and
        self.y - self.height / 2 < y and y < self.y + self.height * 3 / 2)
end

function Camera:overlaps_bounds(x0, y0, x1, y1)
    if x1 < self.rounded_x or self.rounded_x + self.width < x0 or
        y1 < self.rounded_y or self.rounded_y + self.height < y0
    then
        return false
    else
        return true
    end
end

-- Fuzzy version of bounds, for things that we want to activate when nearing the camera
function Camera:fuzzy_overlaps_bounds(x0, y0, x1, y1)
    return (
        self.x - self.width / 2 < x1 and x0 < self.x + self.width * 3 / 2 and
        self.y - self.height / 2 < y1 and y0 < self.y + self.height * 3 / 2)
end

function Camera:aim_at(focusx, focusy, dt)
    -- Clamp to the panic margin
    local panic_x0 = focusx - self.width * (1 - self.panic_margin_right)
    local panic_x1 = focusx - self.width * (0 + self.panic_margin_left)
    local prev_x = math.max(panic_x0, math.min(panic_x1, self.x))
    -- Try to move to within the regular margin
    local x0 = focusx - self.width * (1 - self.margin_right)
    local x1 = focusx - self.width * (0 + self.margin_left)
    local x = math.max(x0, math.min(x1, self.x))
    -- Clamp both to extreme bounds
    prev_x = math.max(self.xmin, math.min(self.xmax - self.width, prev_x))
    x = math.max(self.xmin, math.min(self.xmax - self.width, x))
    if dt > 0 then
        local p
        if prev_x < x0 then
            if panic_x0 < x0 then
                p = (prev_x - x0) / (panic_x0 - x0)
            end
        elseif prev_x > x1 then
            if panic_x1 > x1 then
                p = (prev_x - x1) / (panic_x1 - x1)
            end
        end
        if p then
            local speed = util.lerp(p * p, self.x_min_speed, self.x_max_speed)
            local dist = speed * dt
            local shift = x - prev_x
            if math.abs(shift) > dist then
                shift = dist * util.sign(shift)
            end
            x = prev_x + shift
        end
    end
    self.x = x

    -- Clamp to the panic margin
    local panic_y0 = focusy - self.height * (1 - self.panic_margin_bottom)
    local panic_y1 = focusy - self.height * (0 + self.panic_margin_top)
    local prev_y = math.max(panic_y0, math.min(panic_y1, self.y))
    -- Try to move to within the regular margin
    local y0 = focusy - self.height * (1 - self.margin_bottom)
    local y1 = focusy - self.height * (0 + self.margin_top)
    local y = math.max(y0, math.min(y1, prev_y))
    -- Clamp both to extreme bounds
    prev_y = math.max(self.ymin, math.min(self.ymax - self.height, prev_y))
    y = math.max(self.ymin, math.min(self.ymax - self.height, y))
    if dt > 0 then
        local p
        if prev_y < y0 then
            if panic_y0 < y0 then
                p = (prev_y - y0) / (panic_y0 - y0)
            end
        elseif prev_y > y1 then
            if panic_y1 > y1 then
                p = (prev_y - y1) / (panic_y1 - y1)
            end
        end
        if p then
            local speed = util.lerp(p, self.y_min_speed, self.y_max_speed)
            local dist = speed * dt
            local shift = y - prev_y
            if math.abs(shift) > dist then
                shift = dist * util.sign(shift)
            end
            y = prev_y + shift
        end
    end
    self.y = y

    self.rounded_x = math.floor(self.x + 0.5)
    self.rounded_y = math.floor(self.y + 0.5)
end

function Camera:apply()
    love.graphics.translate(-self.rounded_x, -self.rounded_y)
    --love.graphics.translate(-math.floor(self.x), -math.floor(self.y))
end

-- Draws the camera parameters, in world coordinates
function Camera:draw()
    -- top, bottom, left, right
    love.graphics.setColor(0.5, 0, 0)
    love.graphics.line(
        self.x, self.y + self.height * self.panic_margin_top,
        self.x + self.width, self.y + self.height * self.panic_margin_top)
    love.graphics.line(
        self.x, self.y + self.height * (1 - self.panic_margin_bottom),
        self.x + self.width, self.y + self.height * (1 - self.panic_margin_bottom))
    love.graphics.line(
        self.x + self.width * self.panic_margin_left, self.y,
        self.x + self.width * self.panic_margin_left, self.y + self.height)
    love.graphics.line(
        self.x + self.width * (1 - self.panic_margin_right), self.y,
        self.x + self.width * (1 - self.panic_margin_right), self.y + self.height)

    love.graphics.setColor(1, 1, 1)
    love.graphics.line(
        self.x, self.y + self.height * self.margin_top,
        self.x + self.width, self.y + self.height * self.margin_top)
    love.graphics.line(
        self.x, self.y + self.height * (1 - self.margin_bottom),
        self.x + self.width, self.y + self.height * (1 - self.margin_bottom))
    love.graphics.line(
        self.x + self.width * self.margin_left, self.y,
        self.x + self.width * self.margin_left, self.y + self.height)
    love.graphics.line(
        self.x + self.width * (1 - self.margin_right), self.y,
        self.x + self.width * (1 - self.margin_right), self.y + self.height)
end


-- This is one independent map, though it's often referred to as a "submap"
-- because more than one of them (e.g., overworld and inside buildings) can
-- exist within the same Tiled map.
local Map = Object:extend{
    -- If true when this map is removed from the World, this map will be
    -- remembered as-is the next time it's returned from `World:reify_map`,
    -- rather than reloaded from scratch
    stashed = false,
    initial_parallax_z = -20000,

    timer = 0,
}

function Map:init(world, tiled_map, submap)
    -- TODO? this could be added by a method that activates the map...
    self.world = world

    local blockmap_size
    -- FIXME better argspec please
    if type(tiled_map) == 'number' then
        self.width = tiled_map
        self.height = submap
        self.tiled_map = nil
        self.submap = nil

        blockmap_size = 64

        self.camera_bounds = AABB(0, 0, self.width, self.height)
    else
        -- TODO i would prefer if, somehow, this class were blissfully unaware of
        -- the entire 'submap' concept, but we need it to get stuff out of tiled
        self.submap = submap
        -- TODO would be nice to not be so reliant on particular details of
        -- TiledMap, so i could write some freakin' tests
        self.tiled_map = tiled_map

        self.width = tiled_map.width
        self.height = tiled_map.height

        blockmap_size = tiled_map.tilewidth * 4

        self.camera_bounds = AABB:from_bounds(
            0 + tiled_map.camera_margin_left,
            0 + tiled_map.camera_margin_top,
            self.width - tiled_map.camera_margin_right,
            self.height - tiled_map.camera_margin_bottom)
    end

    -- FIXME if i put these here, then anything the PLAYER (or any other moved
    -- object) tries to do when changing maps will be suspended, and will
    -- resume when they return to that map (!).  if i put it at the World
    -- level, a bunch of actors might update themselves when they're no longer
    -- on the map any more!  slightly troubling.  do they have some kinda api
    -- for, i don't know, removing a timer or putting it elsewhere?  should
    -- actors just have their own fluxes?  (eugh)
    self.flux = flux.group()
    self.tick = tick.group()

    self.actors = {}
    self.actors_to_remove = {}
    self.collider = whammo.Collider(blockmap_size)

    -- TODO this seems more a candidate for an 'enter' or map-switch event?
    -- maybe?  maybe not?
    self:_create_initial_actors()
end

function Map:__tostring()
    local submap_bit = ''
    if self.submap ~= '' then
        submap_bit = (" (submap %s)"):format(self.submap)
    end
    return ("<Map from %s%s>"):format(self.tiled_map.path, submap_bit)
end

function Map:add_actor(actor)
    table.insert(self.actors, actor)

    actor:each('on_enter', self)

    return actor  -- for ease of chaining
end

-- Schedules the actor to be removed at the end of the next update; this lets
-- them destroy themselves in the middle of an update /and then complete that
-- update/ without making the world state inconsistent.  Such cases are more
-- obvious now that on_leave sets Actor.map to nil; if the actor continues
-- trying to do anything interesting, it might crash because its map has
-- vanished out from under it!
function Map:delayed_remove_actor(actor)
    table.insert(self.actors_to_remove, actor)
end

function Map:remove_actor(actor)
    -- TODO what if the actor is the player...?  should we unset self.player?
    actor:each('on_leave')

    -- TODO maybe an index would be useful
    for i, an_actor in ipairs(self.actors) do
        if actor == an_actor then
            local last = #self.actors
            self.actors[i] = self.actors[last]
            self.actors[last] = nil
            break
        end
    end
end

-- Broadcast a message to some set of actors on the map.
-- `source` is the actor doing the broadcasting, if any.
-- `filters` is a table of simple filters, as follows:
--     distance: Only broadcast to actors within this distance (measured by
--       pos, not by shape).  Actors without a pos are automatically excluded.
--     pred: Arbitrary predicate, i.e. callable that takes an actor and returns
--       true to broadcast or false to skip.
-- `func` is either a callable or a method name.  If the latter, the method
-- will only be called if it exists (though its type won't be checked).  Any
-- further arguments are passed along in the call.
function Map:broadcast(source, filters, func, ...)
    local distance = filters.distance
    local distance2
    if distance then
        assert(source, "Must provide a source actor when filtering by distance")
        distance2 = distance * distance
    end

    local pred = filters.pred

    local is_method = type(func) == 'string'

    for _, actor in ipairs(self.actors) do
        repeat
            -- Check distance
            if distance2 then
                if not actor.pos then
                    break
                end
                if (actor.pos - source.pos):len2() > distance2 then
                    break
                end
            end

            -- Check predicate
            if pred then
                if not pred(actor) then
                    break
                end
            end

            -- Seems good; do the call
            if is_method then
                local method = actor[func]
                if method then
                    method(actor, ...)
                end
            else
                func(actor, ...)
            end
        until true
    end
end

-- Check whether one actor can pass into another, given an optional collision.
function Map:check_blocking(mover, obstacle, collision)
    -- Moving apart is always fine
    if collision and collision:is_moving_away() then
        return false
    end

    -- This has to return true or false, not just nil
    local is_blocked = mover:collect('is_blocked_by', obstacle, collision)
    if is_blocked ~= nil then
        return is_blocked
    end

    if not obstacle:blocks(mover, collision) then
        return false
    end

    -- One-way platforms only block when the collision hits a surface
    -- facing the specified direction
    -- FIXME what should this return without a collision?  always yes or always no?
    -- FIXME doubtless need to fix overlap collision with a pushable
    if collision and obstacle.one_way_direction then
        if collision.overlapped or not collision:faces(obstacle.one_way_direction) then
            return false
        end
    end

    return true
end


-- Test whether a shape is blocked.  You must provide your own predicate, which for example might test actor:blocks(something).
function Map:is_blocked(shape, predicate)
    local blocked = false
    -- FIXME i wish i could cancel the slide partway through?
    self.collider:sweep(shape, Vector.zero, function(collision)
        if not collision.overlapped then
            -- Anything we're only touching, not overlapping, isn't going to
            -- block us
            return
        end
        if predicate(collision.their_owner, collision) then
            blocked = true
        end
    end)
    return blocked
end


-- TODO this isn't really the right name for this operation, nor for the
-- callback.  it's just being suspended; the actors aren't actually being
-- removed from the map they're on.  and i'm only doing this in the first place
-- for sounds, which, maybe, belong in a sound manager?
function Map:unload()
    -- Unload previous map; this allows actors to clean up global resources,
    -- such as ambient sounds.
    -- TODO i'm not sure this is the right thing to do; it would be wrong for
    -- NEON PHASE, for example, since there we stash a map to go back to it
    -- later!  i'm also not sure it should apply to the player?  but i only
    -- need it in the first place to stop the laser sound.  wow audio is hard
    if self.actors then
        for i = #self.actors, 1, -1 do
            local actor = self.actors[i]
            self.actors[i] = nil
            if actor then
                actor:on_leave()
            end
        end
    end
end

-- Note that this might be called multiple times per frame, if WorldScene is
-- trying to do catch-up updates
function Map:update(dt)
    self.timer = self.timer + dt
    --print('-- begin frame --')
    self.flux:update(dt)
    self.tick:update(dt)

    -- TODO it might be nice for players to always update first, ESPECIALLY if
    -- their controls end up as a component on themselves
    self:_update_actors(dt)

    self:_remove_actors()
end

-- FIXME this is only here so anise can override it, which, seems very silly to
-- me?  but also i don't see a great way around it short of some separate
-- mechanism for deciding whether to update each actor.  well.  actually.  hmm
-- FIXME and now it is definitely not appropriate for anise
function Map:_update_actors(dt)
    --print()
    --[[
    local fmt = "%50s %20s %20s %20s %20s"
    print(fmt:format("Actor move summary:", "velocity", "p velocity", "p accel", "friction"))
    for _, actor in ipairs(self.actors) do
        local move = actor:get('move')
        if move then
            print(fmt:format(tostring(actor), tostring(move.velocity), tostring(move.pending_velocity), tostring(move.pending_accel), tostring(move.pending_friction)))
        end
    end
    ]]
    for _, actor in ipairs(self.actors) do
        actor:update(dt)
    end
end

function Map:_remove_actors()
    for i, actor in ipairs(self.actors_to_remove) do
        if actor.map == self then
            self:remove_actor(actor)
        end
        self.actors_to_remove[i] = nil
    end
end

-- Draw actors in z-order, excluding any that aren't within the given bounds
-- (presumably a camera).  Note that this relies on the pos attribute;
-- extremely large actors or actors that draw very far away from their position
-- might want to inherit from BareActor and forego having a position entirely,
-- in which case they'll draw unconditionally.
function Map:draw(aabb)
    if aabb then
        aabb = aabb:with_margin(-aabb.width / 2, -aabb.height / 2)
    else
        -- In the interest of preserving the argument-less draw(), default to
        -- drawing the entire map, with a wide margin around it.
        aabb = AABB(
            -self.width / 2, -self.height / 2,
            self.width * 2, self.height * 2)
    end

    -- TODO could reduce allocation and probably speed up the sort below if we
    -- kept this list around?  or hell is there any downside to just keeping
    -- the actors list in draw order?  would mean everyone updates in a fairly
    -- consistent order, back to front.  the current order is completely
    -- arbitrary and can change at a moment's notice anyway
    local sorted_actors = {}
    for _, actor in ipairs(self.actors) do
        if actor.always_draw or not actor.pos or aabb:contains(actor.pos) then
            table.insert(sorted_actors, actor)
        end
    end

    -- TODO this has actually /increased/ z-fighting, good job.
    -- FIXME the counter appears /in front/ of npcs while fading in??  what??
    table.sort(sorted_actors, function(actor1, actor2)
        -- FIXME this is only for top-down mode, which is currently per-actor, yikes!!
        -- FIXME i think this makes the sort non-transitive, whhhoooopps
        --[[
        if actor1.pos and actor2.pos and actor1.pos.y ~= actor2.pos.y then
            return actor1.pos.y < actor2.pos.y
        end
        ]]

        local z1 = actor1.z or 0
        local z2 = actor2.z or 0
        if z1 ~= z2 then
            return z1 < z2
        elseif actor1.pos and actor2.pos then
            return actor1.pos.x < actor2.pos.x
        else
            return (actor1.timer or 0) < (actor2.timer or 0)
        end
    end)

    self:draw_actors(sorted_actors)
end

-- Draw a list of actors, in the given order.  Split out for overriding for
-- special effects.
function Map:draw_actors(sorted_actors)
    for _, actor in ipairs(sorted_actors) do
        actor:draw()
    end
end

function Map:_create_initial_actors()
    -- Add borders around the map itself, so nothing can leave it
    local margin = 64
    for _, shape in ipairs{
        -- Top
        whammo_shapes.Box(-margin, -margin, self.width + margin * 2, margin),
        -- Bottom
        whammo_shapes.Box(-margin, self.height, self.width + margin * 2, margin),
        -- Left
        whammo_shapes.Box(-margin, -margin, margin, self.height + margin * 2),
        -- Right
        whammo_shapes.Box(self.width, -margin, margin, self.height + margin * 2),
    } do
        self:add_actor(actors_map.MapEdge(shape))
    end

    -- TODO slightly hokey
    if not self.tiled_map then
        return
    end

    self._actors_by_id = setmetatable({}, { __mode = 'v' })
    self._actor_ids = setmetatable({}, { __mode = 'k' })
    -- TODO this seems /slightly/ invasive but i'm not sure where else it would
    -- go.  i guess if the "map" parts of the world got split off it would be
    -- more appropriate.  i DO like that it starts to move "submap" out of the
    -- map parsing, where it 100% does not belong
    -- TODO imo the collision should be attached to the tile layers too
    self._last_parallax_z = self.initial_parallax_z
    for _, layer in ipairs(self.tiled_map.layers) do
        if layer.submap ~= self.submap then
            -- Not relevant to us; skip it
        elseif layer.type == 'tilelayer' then
            self:_add_tile_layer_actor(layer, self.tiled_map)
        elseif layer.type == 'imagelayer' then
            self:_add_image_layer_actor(layer, self.tiled_map)
        elseif layer.type == 'objectgroup' then
            for _, obj in ipairs(layer.objects) do
                local objtype = obj.class or obj.type
                if objtype == 'collision' then
                    -- TODO i wonder if the map should create these
                    -- automatically on load so i don't need to call this
                    local shapes = tiledmap.tiled_shape_to_whammo_shapes(obj)
                    if shapes then
                        for _, shape in ipairs(shapes) do
                            -- TODO oughta allow the map to specify some properties on
                            -- the shape too
                            self:add_actor(actors_map.MapCollider(shape))
                        end
                    end
                end
            end
        end
    end

    -- Tile actors can hold references to other actors (via Tiled object id), but the other actors
    -- may or may not exist yet, so to avoid dependency resolution hell, create the actors first and
    -- then add them all to the map in a separate pass
    local pending_actors = {}
    for _, template in ipairs(self.tiled_map.actor_templates) do
        if (template.submap or '') == self.submap then
            local class = actors_base.Actor:get_named_type(template.name)
            local position = template.position:clone()
            -- FIXME i am unsure about template.shape here; atm it's only used for trigger zone, water, and ladder?
            -- FIXME maybe "actor properties" should be a more consistent and well-defined thing in tiled and should include shapes and other special things, whether it comes from a sprite or a tile object or a shape object
            -- FIXME oh hey maybe this should use a different kind of constructor entirely, so the main one doesn't have a goofy-ass signature?
            local actor = class(position, template.properties, template.shapes, template.tile, template.object)
            if template.id then
                self._actors_by_id[template.id] = actor
                self._actor_ids[actor] = template.id
            end
            table.insert(pending_actors, actor)
        end
    end
    for _, actor in ipairs(pending_actors) do
        self:add_actor(actor)
    end
end

function Map:_add_tile_layer_actor(layer, tiled_map)
    local z
    -- FIXME better!  but i still don't like hardcoded layer names
    if layer.name == 'background' then
        z = -10002
    elseif layer.name == 'main terrain' then
        z = -10001
    -- FIXME okay this particular case is terrible
    elseif self.submap ~= '' and layer.name == self.submap then
        z = -10000
    elseif layer.name == 'background objects' then
        z = -9999
    elseif layer.name == 'objects' then
        z = 900
    elseif layer.name == 'foreground' then
        z = 10001
    elseif layer.name == 'wiring' then
        z = 10002
    end
    if z ~= nil then
        self:add_actor(actors_map.TiledMapLayer(layer, tiled_map, z))
    end
end

function Map:_add_image_layer_actor(layer, tiled_map)
    -- FIXME well this is stupid.  the main problem with automatic
    -- z-numbering of tiled layers is that it's not obvious at a glance
    -- where the object layer is...
    -- FIXME slime effect also needs to know what the "background" is
    -- FIXME maybe i need a more rigorous set of z ranges?
    local z
    if layer.name == 'foreground' then
        z = 10001
    else
        z = self._last_parallax_z
        self._last_parallax_z = self._last_parallax_z + 1
    end
    self:add_actor(actors_map.TiledMapImage(layer, z))
end


-- Entire game world.  Knows about maps (or, at least one!)
local World = Object:extend{
    map_class = Map,
}

function World:init(player)
    self.player = player

    -- Currently-active maps, mostly useful if you have one submap that draws
    -- on top of another.  In the common case, this will only contain one map
    self.map_stack = {}
    -- Always equivalent to self.map_stack[#self.map_stack]
    self.active_map = nil
    -- Maps (presumably, not currently on the stack) whose state is preserved
    self.stashed_maps = {}

    self.camera = Camera()
    self.camera_offset = Vector()
    self.camera_shake_intensity = 0
end

local function _map_key(tiled_map, submap)
    return tiled_map.path .. '//' .. (submap or '')
end

-- Create a Map object, populated with actors, based on the given tiled map.
-- If the map was stashed last time it was unloaded, returns that existing map
-- instead.  An optional second return value is true if the map was stashed.
-- Note that this does NOT add the map to the stack.
function World:reify_map(tiled_map, submap)
    if type(tiled_map) == 'string' then
        -- XXX is there any reason to use resource_manager here??  it keeps all maps in memory forever...
        tiled_map = game.resource_manager:load(tiled_map)
    end
    submap = submap or ''

    local stashed_map = self.stashed_maps[_map_key(tiled_map, submap)]
    if stashed_map then
        return stashed_map, true
    else
        return self.map_class(self, tiled_map, submap), false
    end
end

function World:push(map)
    self.map_stack[#self.map_stack + 1] = map
    self:_set_active(map)
end

function World:pop()
    local popped_map = self.active_map
    self.map_stack[#self.map_stack] = nil
    self:_set_active(self.map_stack[#self.map_stack])

    if popped_map.stashed then
        if popped_map.tiled_map then
            self.stashed_maps[_map_key(popped_map.tiled_map, popped_map.submap)] = popped_map
        else
            io.stderr:write("Can't stash a map that wasn't loaded from a Tiled map\n")
        end
    end

    return popped_map
end

-- Replace the entire stack with a given map
function World:replace(map)
    while self.active_map do
        self:pop()
    end
    self:push(map)
end

function World:_set_active(map)
    -- TODO figure this out, for NEON PHASE, etc
    if self.active_map then
        --self.active_map:suspend()
    end

    self.active_map = map

    if map then
        self.camera:set_bounds(map.camera_bounds:bounds())
    end

    -- FIXME i don't think i need to set the camera size every frame though
    self:update_camera(0)
end

function World:update_camera(dt)
    self.camera:set_size(game:getDimensions())

    self.camera:aim_at(math.floor(self.player.pos.x + 0.5), math.floor(self.player.pos.y + 0.5), dt)
    --self.camera:aim_at(self.player.pos.x, self.player.pos.y, dt)
end

-- Shakes the camera.
-- Shakes do not stack; a new shake will simply clobber any existing one.
-- FIXME this shouldn't persist through map changes, and it could easily have a smoother ease
function World:shake_camera(amount, duration)
    local freq = 1/30
    self.camera_shake_amount = amount
    self.camera_shake_duration = duration
    self.camera_shake_timer = 0
    self.camera_shake_frequency = freq
end

function World:update(dt)
    if self.active_map then
        self.active_map:update(dt)
    end

    local w, h = game:getDimensions()
    self:update_camera(dt)

    if self.camera_shake_timer then
        self.camera_shake_timer = self.camera_shake_timer + dt
        if self.camera_shake_timer >= self.camera_shake_duration then
            self.camera_shake_amount = nil
            self.camera_shake_duration = nil
            self.camera_shake_timer = nil
            self.camera_shake_frequency = nil
            self.camera_offset = Vector()
        else
            local progress = self.camera_shake_timer / self.camera_shake_duration
            local intensity = math.pow(1 - progress, 2)
            self.camera_offset = self.camera_shake_amount * (intensity * math.cos(self.camera_shake_timer / self.camera_shake_frequency * math.pi))
        end
    end
end

function World:draw()
    local w, h = game:getDimensions()

    love.graphics.push()
    local camera_box = self.camera:aabb()
    if self.camera_shake_timer then
        -- FIXME uggggghhhh the parallax background actually reads from the camera directly; hacked it for now
        love.graphics.translate(self.camera_offset:unpack())
    end
    self.camera:apply()
    for i, map in ipairs(self.map_stack) do
        if i > 1 then
            love.graphics.setColor(0, 0, 0, 0.75)
            love.graphics.rectangle('fill', self.camera.x, self.camera.y, w, h)
            love.graphics.setColor(1, 1, 1)
        end
        map:draw(camera_box)
    end
    --self.camera:draw()
    love.graphics.pop()
end

function World:_client_to_world_coords(x, y)
    local wx = (x - game.screen.x) / game.scale + self.camera.x
    local wy = (y - game.screen.y) / game.scale + self.camera.y
    return wx, wy
end


return {
    Map = Map,
    World = World,
}
