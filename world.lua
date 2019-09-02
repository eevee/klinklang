local flux = require 'klinklang.vendor.flux'
local tick = require 'klinklang.vendor.tick'
local Vector = require 'klinklang.vendor.hump.vector'

local AABB = require 'klinklang.aabb'
local actors_base = require 'klinklang.actors.base'
local actors_map = require 'klinklang.actors.map'
local Object = require 'klinklang.object'
local tiledmap = require 'klinklang.tiledmap'
local whammo = require 'klinklang.whammo'
local whammo_shapes = require 'klinklang.whammo.shapes'


local Camera = Object:extend{
    minx = -math.huge,
    miny = -math.huge,
    maxx = math.huge,
    maxy = math.huge,
    -- TODO what happens if i just don't provide these?
    width = 0,
    height = 0,
    x = 0,
    y = 0,
    margin = 0.33,
}

function Camera:clone()
    local camera = getmetatable(self)()
    camera:set_size(self.width, self.height)
    camera:set_bounds(self.minx, self.miny, self.maxx, self.maxy)
    camera.margin = self.margin
    camera.x = self.x
    camera.y = self.y
    return camera
end

function Camera:set_size(width, height)
    self.width = width
    self.height = height
end

function Camera:set_bounds(minx, miny, maxx, maxy)
    self.minx = minx
    self.maxx = maxx
    self.miny = miny
    self.maxy = maxy
end

function Camera:clear_bounds()
    self.minx = -math.huge
    self.maxx = math.huge
    self.miny = -math.huge
    self.maxy = math.huge
end

function Camera:aabb()
    return AABB(self.x, self.y, self.width, self.height)
end

function Camera:aim_at(focusx, focusy)
    -- Update camera position
    -- TODO i miss having a box type
    -- FIXME would like some more interesting features here like smoothly
    -- catching up with the player, platform snapping?
    local marginx = self.margin * self.width
    local x0 = marginx
    local x1 = self.width - marginx
    --local minx = self.map.camera_margin_left
    --local maxx = self.map.width - self.map.camera_margin_right - self.width
    local newx = self.x
    if focusx - newx < x0 then
        newx = focusx - x0
    elseif focusx - newx > x1 then
        newx = focusx - x1
    end
    newx = math.max(self.minx, math.min(self.maxx - self.width, newx))
    self.x = math.floor(newx)

    local marginy = self.margin * self.height
    local y0 = marginy
    local y1 = self.height - marginy
    --local miny = self.map.camera_margin_top
    --local maxy = self.map.height - self.map.camera_margin_bottom - self.height
    local newy = self.y
    if focusy - newy < y0 then
        newy = focusy - y0
    elseif focusy - newy > y1 then
        newy = focusy - y1
    end
    newy = math.max(self.miny, math.min(self.maxy - self.height, newy))
    -- FIXME moooove, elsewhere.  only tricky bit is that it still wants to clamp to miny/maxy
    --[[
    if self.player.camera_jitter and self.player.camera_jitter > 0 then
        newy = newy + math.sin(self.player.camera_jitter * math.pi) * 3
        newy = math.max(miny, math.min(maxy, newy))
    end
    ]]
    self.y = math.floor(newy)
end

function Camera:apply()
    love.graphics.translate(-self.x, -self.y)
end

-- Draws the camera parameters, in world coordinates
function Camera:draw()
    love.graphics.rectangle('line',
        self.x + self.width * self.margin,
        self.y + self.height * self.margin,
        self.width * (1 - 2 * self.margin),
        self.height * (1 - 2 * self.margin))
end


-- This is one independent map, though it's often referred to as a "submap"
-- because more than one of them (e.g., overworld and inside buildings) can
-- exist within the same Tiled map.
local Map = Object:extend{}

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

    actor:on_enter(self)

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
    actor:on_leave()

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

-- Test whether a shape is blocked.  You must provide your own predicate, which for example might test actor:blocks(something).
function Map:is_blocked(shape, predicate)
    local blocked = false
    -- FIXME i wish i could cancel the slide partway through?
    self.collider:sweep(shape, Vector.zero, function(collision)
        if collision.contact_type <= 0 then
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
    self.flux:update(dt)
    self.tick:update(dt)

    -- TODO it might be nice for players to always update first, ESPECIALLY if
    -- their controls end up as a component on themselves
    self:_update_actors(dt)

    local seen = {}  -- avoid removing the same one twice!
    for i, actor in ipairs(self.actors_to_remove) do
        if not seen[actor] then
            self:remove_actor(actor)
            seen[actor] = true
        end
        self.actors_to_remove[i] = nil
    end
end

-- FIXME this is only here so anise can override it, which, seems very silly to
-- me?  but also i don't see a great way around it short of some separate
-- mechanism for deciding whether to update each actor.  well.  actually.  hmm
-- FIXME and now it is definitely not appropriate for anise
function Map:_update_actors(dt)
    print()
    local fmt = "%50s %20s %20s %20s %20s"
    print(fmt:format("Actor move summary:", "velocity", "p velocity", "p accel", "friction"))
    for _, actor in ipairs(self.actors) do
        local move = actor:get('move')
        if move then
            print(fmt:format(tostring(actor), tostring(move.velocity), tostring(move.pending_velocity), tostring(move.pending_accel), tostring(move.pending_friction)))
        end
    end
    for _, actor in ipairs(self.actors) do
        local move = actor:get('move')
        if move then
            move:update(dt)
        end
    end
    for _, actor in ipairs(self.actors) do
        actor:update(dt)
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
        if not actor.pos or aabb:contains(actor.pos) then
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

    -- TODO this seems /slightly/ invasive but i'm not sure where else it would
    -- go.  i guess if the "map" parts of the world got split off it would be
    -- more appropriate.  i DO like that it starts to move "submap" out of the
    -- map parsing, where it 100% does not belong
    -- TODO imo the collision should be attached to the tile layers too
    local parallax_z = -20000
    for _, layer in ipairs(self.tiled_map.layers) do
        if layer.submap ~= self.submap then
            -- Not relevant to us; skip it
        elseif layer.type == 'tilelayer' then
            local z
            -- FIXME better!  but i still don't like hardcoded layer names
            if layer.name == 'background' then
                z = -10002
            elseif layer.name == 'main terrain' then
                z = -10001
            -- FIXME okay this particular case is terrible
            elseif self.submap ~= '' and layer.name == self.submap then
                z = -10000
            elseif layer.name == 'objects' then
                z = 10000
            elseif layer.name == 'foreground' then
                z = 10001
            elseif layer.name == 'wiring' then
                z = 10002
            end
            if z ~= nil then
                self:add_actor(actors_map.TiledMapLayer(layer, self.tiled_map, z))
            end
        elseif layer.type == 'imagelayer' then
            -- FIXME well this is stupid.  the main problem with automatic
            -- z-numbering of tiled layers is that it's not obvious at a glance
            -- where the object layer is...
            -- FIXME slime effect also needs to know what the "background" is
            -- FIXME maybe i need a more rigorous set of z ranges?
            local z
            if layer.name == 'foreground' then
                z = 10001
            else
                z = parallax_z
                parallax_z = parallax_z + 1
            end
            self:add_actor(actors_map.TiledMapImage(layer, z))
        elseif layer.type == 'objectgroup' then
            for _, obj in ipairs(layer.objects) do
                if obj.type == 'collision' then
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

    for _, template in ipairs(self.tiled_map.actor_templates) do
        if (template.submap or '') == self.submap then
            local class = actors_base.Actor:get_named_type(template.name)
            local position = template.position:clone()
            -- FIXME i am unsure about template.shape here; atm it's only used for trigger zone, water, and ladder?
            -- FIXME maybe "actor properties" should be a more consistent and well-defined thing in tiled and should include shapes and other special things, whether it comes from a sprite or a tile object or a shape object
            -- FIXME oh hey maybe this should use a different kind of constructor entirely, so the main one doesn't have a goofy-ass signature?
            local actor = class(position, template.properties, template.shapes)
            -- FIXME this feels...  hokey...
            -- FIXME this also ends up requiring that a lot of init stuff has
            -- to go in on_enter because the position is bogus.  but maybe it
            -- should go there anyway?
            if actor.sprite and actor.sprite.anchor then
                actor:move_to(position + actor.sprite.anchor)
            end
            self:add_actor(actor)
        end
    end
end




-- Entire game world.  Knows about maps (or, at least one!)
local World = Object:extend{
    map_class = Map,
}

function World:init(player)
    self.player = player

    -- All maps whose state is preserved: both current ones and stashed ones.
    -- Nested table of TiledMap => submap_name => Map
    self.live_maps = {}
    -- Currently-active maps, mostly useful if you have one submap that draws
    -- on top of another.  In the common case, this will only contain one map
    self.map_stack = {}
    -- Always equivalent to self.map_stack[#self.map_stack]
    self.active_map = nil

    self.camera = Camera()
end

-- Loads a new map, or returns an existing map if it's been seen before.  Does
-- NOT add the map to the stack.
function World:load_map(tiled_map, submap)
    local revisiting = true
    if not self.live_maps[tiled_map] then
        self.live_maps[tiled_map] = {}
    end
    if not self.live_maps[tiled_map][submap] then
        self.live_maps[tiled_map][submap] = self.map_class(self, tiled_map, submap)
        revisiting = false
    end
    return self.live_maps[tiled_map][submap], revisiting
end

function World:push(map)
    self.map_stack[#self.map_stack + 1] = map
    self:_set_active(map)
end

-- TODO maybe an arg to say whether to preserve it?  or is that determined when
-- it's first pushed?  or by the map itself somehow??
function World:pop()
    local popped_map = self.active_map
    self.map_stack[#self.map_stack] = nil
    self:_set_active(self.map_stack[#self.map_stack])
    return popped_map
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

    -- XXX this looks copy/pasted from update at the moment, but there's a
    -- crucial difference: update may someday change to limit the rate of
    -- camera movement or whatever, but this MUST be instant since we're
    -- switching maps and there is no sensible "previous" camera position!
    -- FIXME i don't think i need to set the camera size every frame though
    local w, h = game:getDimensions()
    self.camera:set_size(w, h)
    self.camera:aim_at(self.player.pos.x, self.player.pos.y)
end

function World:update(dt)
    if self.active_map then
        self.active_map:update(dt)
    end

    local w, h = game:getDimensions()
    self.camera:set_size(w, h)
    self.camera:aim_at(self.player.pos.x, self.player.pos.y)
end

function World:draw()
    local w, h = game:getDimensions()

    local camera_box = self.camera:aabb()
    for i, map in ipairs(self.map_stack) do
        if i > 1 then
            love.graphics.setColor(0, 0, 0, 0.75)
            love.graphics.rectangle('fill', self.camera.x, self.camera.y, w, h)
            love.graphics.setColor(1, 1, 1)
        end
        map:draw(camera_box)
    end
end


return {
    Map = Map,
    World = World,
}
