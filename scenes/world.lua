local flux = require 'vendor.flux'
local tick = require 'vendor.tick'
local Vector = require 'vendor.hump.vector'

local actors_base = require 'klinklang.actors.base'
local Player = require 'klinklang.actors.player'
local actors_generic = require 'klinklang.actors.generic'
local actors_map = require 'klinklang.actors.map'
local Object = require 'klinklang.object'
local BaseScene = require 'klinklang.scenes.base'
local SceneFader = require 'klinklang.scenes.fader'
local whammo = require 'klinklang.whammo'

local CAMERA_MARGIN = 0.33
-- Sets the maximum length of an actor update.
-- 50~60 fps should only do one update, of course; 30fps should do two.
local MIN_FRAMERATE = 45
-- Don't do more than this many updates at once
local MAX_UPDATES = 10

-- XXX stuff to fix in other games now that i've broken everything here:
-- - WorldScene:_create_actors has gone away
-- - WorldScene:update_camera has gone away
-- TODO obvious post cleanup
-- - remove actors, collider, fluct, tick, submap, camera
-- - give actors a reference to the map they're on?  maybe pass it to on_enter?
-- - remove _draw_use_key_hint (fox flux specific?  or maybe neon phase?)
-- - remove the inventory switch Q binding (oh my GOD)
-- - move drawing of the blockmap to DebugLayer
-- - give everything a self.game property maybe??
-- - do something with camera jitter?

--------------------------------------------------------------------------------
-- Layers


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

function Map:init(name, tiled_map, submap)
    -- TODO actually i don't really know what "name" means here
    self.name = name
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

    for i, actor in ipairs(self.actors_to_remove) do
        self:remove_actor(actor)
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
    for _, actor in ipairs(self.actors) do
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

function World:init()
    -- All maps whose state is preserved: both current ones and stashed ones
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
    local key = tiled_map.path .. '\0' .. submap
    local revisiting = true
    if not self.live_maps[key] then
        self.live_maps[key] = self.map_class(key, tiled_map, submap)
        revisiting = false
    end
    return self.live_maps[key], revisiting
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
    self.active_map = map

    self.camera:set_bounds(
        map.tiled_map.camera_margin_left,
        map.tiled_map.camera_margin_top,
        map.tiled_map.width - map.tiled_map.camera_margin_right,
        map.tiled_map.height - map.tiled_map.camera_margin_bottom)
end

function World:update(dt)
    if self.active_map then
        self.active_map:update(dt)
    end

    local w, h = game:getDimensions()
    -- FIXME i should own the player, probably!
    self.camera:aim_at(worldscene.player.pos.x, worldscene.player.pos.y, w, h)
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



local DebugLayer = Object:extend{}

function DebugLayer:init(world)
    -- FIXME i dream of a day when the world is different from the scene it's in?
    self.world = world
end

function DebugLayer:draw()
    if not game.debug then
        return
    end

    if game.debug_twiddles.show_shapes then
        for _, actor in ipairs(self.world.actors) do
            if actor.shape then
                love.graphics.setColor(255, 255, 0, 128)
                actor.shape:draw('fill')
            end
            if actor.pos then
                love.graphics.setColor(255, 0, 0)
                love.graphics.circle('fill', actor.pos.x, actor.pos.y, 2)
                love.graphics.setColor(255, 255, 255)
                love.graphics.circle('line', actor.pos.x, actor.pos.y, 2)
            end
        end
    end

    if game.debug_twiddles.show_collision then
        for hit, collision in pairs(game.debug_hits) do
            if collision.touchtype > 0 then
                -- Collision: red
                love.graphics.setColor(255, 0, 0, 128)
            elseif collision.touchtype < 0 then
                -- Overlap: blue
                love.graphics.setColor(0, 64, 255, 128)
            else
                -- Touch: green
                love.graphics.setColor(0, 192, 0, 128)
            end
            hit:draw('fill')
            --love.graphics.setColor(255, 255, 0)
            --local x, y = hit:bbox()
            --love.graphics.print(("%0.2f"):format(d), x, y)

            love.graphics.setColor(255, 0, 255)
            local x0, y0, x1, y1 = collision.shape:bbox()
            local x, y = math.floor((x0 + x1) / 2), math.floor((y0 + y1) / 2)
            for normal, normal1 in pairs(collision.normals) do
                local startpt = Vector(x, y)
                local endpt = startpt + normal1 * 8
                local perp = normal1:perpendicular()
                local arrowpt1 = endpt + perp * 3
                local arrowpt2 = endpt - perp * 3
                local arrowpt3 = endpt + normal1 * 3
                love.graphics.line(x, y, endpt.x, endpt.y)
                love.graphics.polygon('fill', arrowpt1.x, arrowpt1.y, arrowpt2.x, arrowpt2.y, arrowpt3.x, arrowpt3.y)
            end
        end
        for _, ray in ipairs(game.debug_rays) do
            local start, direction, hit = unpack(ray)
            love.graphics.setColor(255, 0, 0, 128)
            love.graphics.line(start.x, start.y, start.x + direction.x * 500, start.y + direction.y * 500)
            if hit then
                love.graphics.circle('fill', hit.x, hit.y, 4)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- World scene, which draws the game world (as stored in a World)

local WorldScene = BaseScene:extend{
    __tostring = function(self) return "worldscene" end,

    -- Configurables
    -- TODO probably just pass these in rather than letting the scene create
    -- them?  the world at the very least; player i could see wanting to be
    -- configurable maybe
    player_class = Player,
    world_class = World,

    -- State
    music = nil,
    fluct = nil,
    tick = nil,

    -- TODO these should really be in a separate player controls gizmo.
    -- components.....
    using_gamepad = false,
    was_left_down = false,
    was_right_down = false,
    was_up_down = false,
    was_down_down = false,
}

--------------------------------------------------------------------------------
-- hump.gamestate hooks

function WorldScene:init(...)
    BaseScene.init(self, ...)

    -- FIXME? i'd rather rely on enter() for this, but the world is drawn via
    -- SceneFader /before/ enter() is called for the first time
    self:_refresh_canvas()

    self.layers = {}
    if game.debug then
        table.insert(self.layers, DebugLayer(self))
    end

    -- TODO lol why am i even doing this, just pass a world in
    self.world = self.world_class()
    self.camera = self.world.camera

    -- FIXME well, i guess, don't actually fix me, but, this is used to stash
    -- entire maps atm too
    self.stashed_submaps = {}

    -- TODO probably need a more robust way of specifying music
    --self.music = love.audio.newSource('assets/music/square-one.ogg', 'stream')
    --self.music:setLooping(true)
end

function WorldScene:enter()
    --self.music:play()
    self:_refresh_canvas()
end

function WorldScene:resume()
    -- Just in case, whenever we become the current scene, double-check the
    -- canvas size
    self:_refresh_canvas()
end

function WorldScene:_refresh_canvas()
    local w, h = game:getDimensions()

    if self.canvas then
        local cw, ch = self.canvas:getDimensions()
        if w == cw and h == ch then
            return
        end
    end

    self.canvas = love.graphics.newCanvas(w, h)
end

function WorldScene:update(dt)
    -- FIXME could get rid of this entirely if actors had to go through me to
    -- collide
    game.debug_hits = {}
    game.debug_rays = {}

    -- Handle movement input.
    -- Input comes in two flavors: "instant" actions that happen once when a
    -- button is pressed, and "continuous" actions that happen as long as a
    -- button is held down.
    -- "Instant" actions need to be handled in keypressed, but "continuous"
    -- actions need to be handled with an explicit per-frame check.  The
    -- difference is that a press might happen in another scene (e.g. when the
    -- game is paused), which for instant actions should be ignored, but for
    -- continuous actions should start happening as soon as we regain control —
    -- even though we never know a physical press happened.
    -- Walking has the additional wrinkle that there are two distinct inputs.
    -- If both are held down, then we want to obey whichever was held more
    -- recently, which means we also need to track whether they were held down
    -- last frame.
    local is_left_down = game.input:down('left')
    local is_right_down = game.input:down('right')
    local is_up_down = game.input:down('up')
    local is_down_down = game.input:down('down')
    if is_left_down and is_right_down then
        if self.was_left_down and self.was_right_down then
            -- Continuing to hold both keys; do nothing
        elseif self.was_left_down then
            -- Was holding left, also pressed right, so move right
            self.player:decide_walk(1)
        elseif self.was_right_down then
            -- Was holding right, also pressed left, so move left
            self.player:decide_walk(-1)
        else
            -- Miraculously went from holding neither to holding both, so let's
            -- not move at all
            self.player:decide_walk(0)
        end
    elseif is_left_down then
        self.player:decide_walk(-1)
    elseif is_right_down then
        self.player:decide_walk(1)
    else
        self.player:decide_walk(0)
    end
    self.was_left_down = is_left_down
    self.was_right_down = is_right_down
    -- FIXME this is such a fucking mess lmao
    if is_up_down and is_down_down then
        if self.was_up_down and self.was_down_down then
        elseif self.was_up_down then
            self.player:decide_climb(1)
        elseif self.was_down_down then
            self.player:decide_climb(-1)
        else
            self.player:decide_pause_climbing()
        end
    elseif is_up_down then
        -- TODO up+jump doesn't work correctly, but it's a little fiddly, since
        -- you should only resume climbing once you reach the peak of the jump?
        self.player:decide_climb(1)
    elseif is_down_down then
        -- Only start climbing down if this is a NEW press, so that down+jump
        -- doesn't immediately regrab on the next frame
        if not self.was_down_down then
            self.player:decide_climb(-1)
        end
    else
        self.player:decide_pause_climbing()
    end
    self.was_up_down = is_up_down
    self.was_down_down = is_down_down
    -- Jumping is slightly more subtle.  The initial jump is an instant action,
    -- but /continuing/ to jump is a continuous action.  So we handle the
    -- initial jump in keypressed, but abandon a jump here as soon as the key
    -- is no longer held.
    -- FIXME no longer true, but input is handled globally so catching a
    -- spacebar from dialogue is okay
    if game.input:pressed('jump') then
        -- Down + jump also means let go
        if is_down_down then
            self.player:decide_climb(nil)
        end
        self.player:decide_jump()
    end
    if not game.input:down('jump') then
        self.player:decide_abandon_jump()
    end

    -- FIXME this stupid dt thing is so we don't try to do a second "use" after
    -- switching maps (which does a zero update), ugghhh.  i don't know where
    -- else this belongs though?
    if dt > 0 and game.input:pressed('use') then
        if self.player.is_locked then
            -- Do nothing
        elseif self.player.form == 'stone' then
            -- Do nothing
        else
            -- Use inventory item, or nearby thing
            -- FIXME this should be separate keys maybe?
            if self.player.touching_mechanism then
                self.player.touching_mechanism:on_use(self.player)
            elseif self.player.inventory_cursor > 0 then
                self.player.inventory[self.player.inventory_cursor]:on_inventory_use(self.player)
            end
        end
    end

    -- Update the music to match the player's current position
    -- FIXME shouldn't this happen /after/ the actor updates...??  but also
    -- this probably doesn't belong here as usual
    local x, y = self.player.pos:unpack()
    local new_music = false
    if self.map_music then
        new_music = self.map_music
    end
    for shape, music in pairs(self.map.music_zones) do
        -- FIXME don't have a real api for this yet oops
        local x0, y0, x1, y1 = shape:bbox()
        if x0 <= x and x <= x1 and y0 <= y and y <= y1 then
            new_music = music
            break
        end
    end
    if self.music == new_music then
        -- Do nothing
    elseif new_music == false then
        -- Didn't find a zone at all; keep current music
    elseif self.music == nil then
        new_music:setLooping(true)
        new_music:play()
        self.music = new_music
    elseif new_music == nil then
        self.music:stop()
        self.music = nil
    else
        -- FIXME crossfade?
        new_music:setLooping(true)
        new_music:play()
        new_music:seek(self.music:tell())
        self.music:stop()
        self.music = new_music
    end

    -- If the framerate drops significantly below 60fps, do multiple updates.
    -- This avoids objects completely missing each other, as well as subtler
    -- problems like the player's jump height being massively different due to
    -- large acceleration steps.
    -- TODO if the slowdown is due to the updates, not the draw, then this is
    -- not going to help!  might be worth timing this and giving up if it takes
    -- more time than it's trying to simulate
    local updatect = math.max(1, math.min(MAX_UPDATES,
        math.ceil(dt * MIN_FRAMERATE)))
    local subdt = dt / updatect
    for i = 1, updatect do
        self.world:update(subdt)
    end

    love.audio.setPosition(self.player.pos.x, self.player.pos.y, 0)
    local fx = 1
    if self.player.facing_left then
        fx = -1
    end
    love.audio.setOrientation(fx, 0, 0, -1, 0, 0)

    for _, layer in ipairs(self.layers) do
        if layer.update then
            layer:update(dt)
        end
    end
end


function WorldScene:draw()
    local w, h = game:getDimensions()
    love.graphics.push('all')
    love.graphics.setCanvas(self.canvas)
    love.graphics.clear()

    -- FIXME where does this belong...?  the camera is in the world, but we
    -- have some layers that may care about world coordinates.  maybe they
    -- should just deal with that themselves?
    self.camera:apply()

    self.world:draw()

    -- Draw a keycap when the player is next to something touchable
    -- FIXME i seem to put this separately in every game?  standardize somehow?
    if self.player.touching_mechanism then
        if self.player.form ~= 'stone' then
            self:_draw_use_key_hint(self.player.pos + Vector(0, -80))
        end
    end

    -- FIXME i have overlooked something significant: some layers are in world
    -- coordinates, some are not
    for _, layer in ipairs(self.layers) do
        layer:draw()
    end

    love.graphics.pop()

    self:_draw_final_canvas()

    if game.debug and game.debug_twiddles.show_blockmap then
        self:_draw_blockmap()
    end
end

-- Draws a set of actors in _world_ coordinates
function WorldScene:_draw_actors(actors)
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
    for k, v in ipairs(actors) do
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

-- Note: pos is the center of the hint; sprites should have their anchors at
-- their centers too
function WorldScene:_draw_use_key_hint(anchor)
    local letter, sprite
    -- TODO just get the actual key/button from game.input
    if game.input:getActiveDevice() == 'joystick' then
        letter = 'X'
        sprite = game.sprites['keycap button']:instantiate()
    else
        letter = love.keyboard.getKeyFromScancode('e'):upper()
        sprite = game.sprites['keycap key']:instantiate()
    end
    sprite:draw_at(anchor)
    love.graphics.push('all')
    love.graphics.setColor(0, 0, 0)
    love.graphics.setFont(m5x7small)
    local tw = m5x7small:getWidth(letter)
    local th = m5x7small:getHeight() * m5x7small:getLineHeight()
    love.graphics.print(letter, math.floor(anchor.x - tw / 2 + 0.5), math.floor(anchor.y - 8))
    love.graphics.pop()
end

function WorldScene:_draw_blockmap()
    love.graphics.push('all')
    love.graphics.setColor(255, 255, 255, 64)
    love.graphics.scale(game.scale, game.scale)

    local blockmap = self.collider.blockmap
    local blocksize = blockmap.blocksize
    local x0 = -self.camera.x % blocksize
    local y0 = -self.camera.y % blocksize
    local w, h = game:getDimensions()
    for x = x0, w, blocksize do
        love.graphics.line(x, 0, x, h)
    end
    for y = y0, h, blocksize do
        love.graphics.line(0, y, w, y)
    end

    for x = x0, w, blocksize do
        for y = y0, h, blocksize do
            local a, b = blockmap:to_block_units(self.camera.x + x, self.camera.y + y)
            love.graphics.print((" %d, %d"):format(a, b), x, y)
        end
    end

    love.graphics.pop()
end

function WorldScene:_draw_final_canvas()
    love.graphics.setCanvas()
    love.graphics.draw(self.canvas, 0, 0, 0, game.scale, game.scale)
end

function WorldScene:resize(w, h)
    self:_refresh_canvas()
end

-- FIXME this is really /all/ game-specific
function WorldScene:keypressed(key, scancode, isrepeat)
    if isrepeat then
        return
    end

    if scancode == 'q' then
        do return end
        -- Switch inventory items
        if not self.inventory_switch or self.inventory_switch.progress == 1 then
            local old_item = self.player.inventory[self.player.inventory_cursor]
            self.player.inventory_cursor = self.player.inventory_cursor + 1
            if self.player.inventory_cursor > #self.player.inventory then
                self.player.inventory_cursor = 1
            end
            if self.inventory_switch then
                self.inventory_switch.event:stop()
            end
            self.inventory_switch = {
                old_item = old_item,
                new_name = love.graphics.newText(m5x7, self.player.inventory[self.player.inventory_cursor].display_name),
                progress = 0,
                name_opacity = 1,
            }
            local event = self.fluct:to(self.inventory_switch, 0.33, { progress = 1 })
                :ease('linear')
                :after(0.33, { name_opacity = 0 })
                :delay(1)
                :oncomplete(function() self.inventory_switch = nil end)
            self.inventory_switch.event = event
        end
    end
end

function WorldScene:mousepressed(x, y, button, istouch)
    if game.debug and button == 2 then
        self.player:move_to(Vector(
            x / game.scale + self.camera.x,
            y / game.scale + self.camera.y))
        self.player.velocity = Vector()
    end
end

--------------------------------------------------------------------------------
-- API

-- TODO it annoys me that this is somehow distinct from entering a submap
-- TODO i guess actually the scene could be responsible for the transition,
-- right?  if everything else is, you know, elsewhere
function WorldScene:load_map(tiled_map, spot_name)
    if self.current_map then
        -- TODO hmmm
        while self.world.active_map do
            self.world:pop()
        end
        -- FIXME maybe this doesn't go here
        self.current_map:unload()
    end
    -- TODO as usual, need a more rigorous idea of music management
    if self.music then
        self.music:stop()
    end

    if spot_name then
        -- FIXME this is very much a hack that happens to work with the design
        -- of fox flux; there should be a more explicit way of setting save
        -- points
        game:set_save_spot(tiled_map.path, spot_name)
    else
        -- If this map declares its attachment to an overworld, use that point
        -- as a save point
        local overworld_map = tiled_map:prop('overworld map')
        local overworld_spot = tiled_map:prop('overworld spot')
        if overworld_map and overworld_spot then
            game:set_save_spot(overworld_map, overworld_spot)
        end
    end

    self.map = tiled_map
    --self.music = nil  -- FIXME not sure when this should happen; isaac vs neon are very different

    -- XXX revisiting is currently really half-assed; it relies on the caller
    -- to add the player back to the map too!  it was basically hacked in for
    -- neon phase's angel zone (contrast with isaac or fox flux, which
    -- explicitly want to discard every map as we leave), but it's also useful
    -- for anise.  find a way to reconcile these behaviors?
    local map, revisiting = self.world:load_map(tiled_map, '')
    self.world:push(map)
    self.current_map = map
    self.fluct = self.current_map.flux
    self.tick = self.current_map.tick
    self.actors = self.current_map.actors
    self.collider = self.current_map.collider

    if not revisiting then
        local player_start
        if spot_name then
            player_start = tiled_map.named_spots[spot_name]
            if not player_start then
                error(("No spot named %s on map %s"):format(spot_name, tiled_map))
            end
        else
            player_start = tiled_map.player_start
            if not player_start then
                error(("No player start found on map %s"):format(map))
            end
        end
        if self.player then
            self.player:move_to(player_start:clone())
        else
            self.player = self.player_class(player_start:clone())
        end
        self:add_actor(self.player)

        local map_music_path = tiled_map:prop('music')
        if map_music_path then
            self.map_music = love.audio.newSource(map_music_path, 'stream')
        else
            self.map_music = nil
        end
    end

    self.map_region = self.map:prop('region', '')

    -- Rez the player if necessary.  This MUST happen after moving the player
    -- (and SHOULD happen after populating the world, anyway) because it does a
    -- zero-duration update, and if the player is still touching whatever
    -- killed them, they'll instantly die again.
    -- FIXME maybe make it not do a zero-duration update
    -- FIXME in general this seems like it does not remotely belong here, but
    -- also that seems like the same general question as stashing maps vs not
    if self.player.is_dead then
        -- TODO should this be a more general 'reset'?
        self.player:resurrect()
    end

    -- FIXME i don't know what i was doing here.  especially subtracting the
    -- map height, What??  clearly i want a separate api for "ignore any state
    -- and jump to here" though
    self.camera.x = self.player.pos.x
    self.camera.y = self.player.pos.y - self.map.height

    -- Advance the world by zero time to put it in a consistent state (e.g.
    -- figure out what's on the ground, update the camera)
    -- FIXME i would love to not do this because it keeps causing minor but
    -- irritating surprises.  we can update the camera, sure, but i think a
    -- newly-spawned actor should be able to deal with inconsistent state on
    -- its own
    self:update(0)
end

function WorldScene:reload_map()
    self:load_map(self.map)
end

-- TODO how does this work if you enter submap A, then B, then A again?  poorly thought through
function WorldScene:enter_submap(name)
    self.submap = name
    self:remove_actor(self.player)

    local map = self.world:load_map(self.current_map.tiled_map, name or '')
    self.world:push(map)
    self.current_map = self.world.active_map

    self:add_actor(self.player)

    self.fluct = self.current_map.flux
    self.tick = self.current_map.tick
    self.actors = self.current_map.actors
    self.collider = self.current_map.collider
end

function WorldScene:leave_submap()
    self:remove_actor(self.player)

    self.world:pop()
    self.current_map = self.world.active_map
    self.submap = nil

    self:add_actor(self.player)

    self.fluct = self.current_map.flux
    self.tick = self.current_map.tick
    self.actors = self.current_map.actors
    self.collider = self.current_map.collider
end

function WorldScene:add_actor(actor)
    self.current_map:add_actor(actor)
end

function WorldScene:remove_actor(actor)
    self.current_map:remove_actor(actor)
end


return WorldScene
-- TODO do i want to do this, or move the other stuff into other files?
--[[
return {
    WorldScene = WorldScene,
    World = World,
    Map = Map,
}
]]
