local flux = require 'vendor.flux'
local tick = require 'vendor.tick'
local Vector = require 'vendor.hump.vector'

local actors_base = require 'klinklang.actors.base'
local actors_map = require 'klinklang.actors.map'
local Object = require 'klinklang.object'
local whammo = require 'klinklang.whammo'


local CAMERA_MARGIN = 0.33

local Camera = Object:extend{
    minx = -math.huge,
    miny = -math.huge,
    maxx = math.huge,
    maxy = math.huge,
    x = 0,
    y = 0,
}

function Camera:set_bounds(minx, miny, maxx, maxy)
    self.minx = minx
    self.maxx = maxx
    self.miny = miny
    self.maxy = maxy
end

function Camera:aim_at(focusx, focusy, w, h)
    -- Update camera position
    -- TODO i miss having a box type
    -- FIXME would like some more interesting features here like smoothly
    -- catching up with the player, platform snapping?
    local marginx = CAMERA_MARGIN * w
    local x0 = marginx
    local x1 = w - marginx
    --local minx = self.map.camera_margin_left
    --local maxx = self.map.width - self.map.camera_margin_right - w
    local newx = self.x
    if focusx - newx < x0 then
        newx = focusx - x0
    elseif focusx - newx > x1 then
        newx = focusx - x1
    end
    newx = math.max(self.minx, math.min(self.maxx - w, newx))
    self.x = math.floor(newx)

    local marginy = CAMERA_MARGIN * h
    local y0 = marginy
    local y1 = h - marginy
    --local miny = self.map.camera_margin_top
    --local maxy = self.map.height - self.map.camera_margin_bottom - h
    local newy = self.y
    if focusy - newy < y0 then
        newy = focusy - y0
    elseif focusy - newy > y1 then
        newy = focusy - y1
    end
    newy = math.max(self.miny, math.min(self.maxy - h, newy))
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


-- This is one independent map, though it's often referred to as a "submap"
-- because more than one of them (e.g., overworld and inside buildings) can
-- exist within the same Tiled map.
local Map = Object:extend{}

function Map:init(world, tiled_map, submap)
    self.world = world
    -- TODO i would prefer if, somehow, this class were blissfully unaware of
    -- the entire 'submap' concept, but we need it to get stuff out of tiled
    self.submap = submap

    -- TODO would be nice to not be so reliant on particular details of
    -- TiledMap, i guess, abstractly, but also who cares that much
    self.tiled_map = tiled_map

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
    self.collider = whammo.Collider(4 * tiled_map.tilewidth)

    tiled_map:add_to_collider(self.collider, submap)

    -- TODO this seems more a candidate for an 'enter' or map-switch event?
    -- maybe?  maybe not?
    self:_create_actors()
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
    -- XXX temporary
    if not actor.map then
        print("ACTOR WITH A BROKEN ON_ENTER PROBABLY:", actor)
    end
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
function Map:_update_actors(dt)
    for _, actor in ipairs(self.actors) do
        actor:update(dt)
    end
end

function Map:draw()
    -- TODO could reduce allocation and probably speed up the sort below if we
    -- kept this list around.  or hell is there any downside to just keeping
    -- the actors list in draw order?  would mean everyone updates in a fairly
    -- consistent order, back to front.  the current order is completely
    -- arbitrary and can change at a moment's notice anyway
    -- OH WAIT, this specifically takes a list of actors to draw, uh oh!  i'm
    -- pretty sure anise is using that to exclude some actors from drawing, for
    -- example.  but, fuck, we should probably just not bother drawing actors
    -- outside the camera anyway.  (tricky bit is figuring out /when/ they're
    -- outside the camera i suppose; merely inspecting actor.pos will cause no
    -- end of edge cases, but not everyone has a shape either...  should it be
    -- up to the actor??)
    -- ALSO, it might be nice for the player to always update first, ESPECIALLY
    -- if their controls end up as a component on themselves
    local sorted_actors = {}
    for k, v in ipairs(self.actors) do
        sorted_actors[k] = v
    end

    -- TODO this has actually /increased/ z-fighting, good job.  
    table.sort(sorted_actors, function(actor1, actor2)
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

    for _, actor in ipairs(sorted_actors) do
        actor:draw()
    end
end

function Map:_create_actors()
    -- TODO this seems /slightly/ invasive but i'm not sure where else it would
    -- go.  i guess if the "map" parts of the world got split off it would be
    -- more appropriate.  i DO like that it starts to move "submap" out of the
    -- map parsing, where it 100% does not belong
    -- TODO imo the collision should be attached to the tile layers too
    for _, layer in ipairs(self.tiled_map.layers) do
        if layer.type == 'tilelayer' and layer.submap == self.submap then
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
        end
    end

    for _, template in ipairs(self.tiled_map.actor_templates) do
        if (template.submap or '') == self.submap then
            local class = actors_base.Actor:get_named_type(template.name)
            local position = template.position:clone()
            -- FIXME i am unsure about template.shape here; atm it's only used for trigger zone
            -- FIXME oh hey maybe this should use a different kind of constructor entirely, so the main one doesn't have a goofy-ass signature?
            local actor = class(position, template.properties, template.shape)
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
        self.camera:set_bounds(
            map.tiled_map.camera_margin_left,
            map.tiled_map.camera_margin_top,
            map.tiled_map.width - map.tiled_map.camera_margin_right,
            map.tiled_map.height - map.tiled_map.camera_margin_bottom)
    end
end

function World:update(dt)
    if self.active_map then
        self.active_map:update(dt)
    end

    local w, h = game:getDimensions()
    self.camera:aim_at(self.player.pos.x, self.player.pos.y, w, h)
end

function World:draw()
    local w, h = game:getDimensions()

    -- FIXME the parallax background should just be an actor so it's not
    -- goofily special-cased here...  but it would need to know the camera
    -- position...
    if #self.map_stack > 0 then
        self.map_stack[1].tiled_map:draw_parallax_background(self.camera, w, h)
    end

    for i, map in ipairs(self.map_stack) do
        if i > 1 then
            love.graphics.setColor(0, 0, 0, 192)
            -- TODO could draw a rectangle the full size of the map instead?
            -- would avoid knowing the camera or viewport here...  though i
            -- guess i own the camera already eh
            love.graphics.rectangle('fill', self.camera.x, self.camera.y, w, h)
            love.graphics.setColor(255, 255, 255)
        end
        map:draw()
    end
end


return {
    Map = Map,
    World = World,
}
