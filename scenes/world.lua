local Vector = require 'klinklang.vendor.hump.vector'

local Object = require 'klinklang.object'
local BaseScene = require 'klinklang.scenes.base'

-- Sets the maximum length of an actor update.
-- 50~60 fps should only do one update, of course; 30fps should do two.
local MIN_FRAMERATE = 45
-- Don't do more than this many updates at once
local MAX_UPDATES = 10

-- XXX stuff to fix in other games now that i've broken everything here:
-- - WorldScene:_create_actors has gone away
-- - WorldScene:update_camera has gone away
-- TODO obvious post cleanup
-- - remove submap, camera, add_actor, remove_actor

--------------------------------------------------------------------------------
-- Layers

local DebugLayer = Object:extend{}

function DebugLayer:init(world)
    self.world = world
end

function DebugLayer:draw()
    if not game.debug then
        return
    end

    local camera = self.world.camera
    local map = self.world.active_map

    if game.debug_twiddles.show_shapes then
        love.graphics.push()
        camera:apply()
        for _, actor in ipairs(map.actors) do
            love.graphics.setColor(1, 1, 0, 0.5)
            actor:draw_shape('fill')
            if actor.pos then
                love.graphics.setColor(1, 0, 0)
                love.graphics.circle('fill', actor.pos.x, actor.pos.y, 2)
                love.graphics.setColor(1, 1, 1)
                love.graphics.circle('line', actor.pos.x, actor.pos.y, 2)
            end
        end
        love.graphics.pop()
    end

    if game.debug_twiddles.show_collision then
        love.graphics.push('all')
        camera:apply()
        for hit, collision in pairs(game.debug_hits) do
            if collision.contact_type > 0 then
                -- Collision: red
                love.graphics.setColor(1, 0, 0, 0.5)
            elseif collision.contact_type < 0 then
                -- Overlap separation: blue
                love.graphics.setColor(0, 0.25, 1, 0.5)
            else
                -- Touch: green
                love.graphics.setColor(0, 0.75, 0, 0.5)
            end
            hit:draw('fill')
            --love.graphics.setColor(1, 1, 0)
            --local x, y = hit:bbox()
            --love.graphics.print(("%0.2f"):format(d), x, y)

            love.graphics.setColor(1, 0, 1)
            local x0, y0, x1, y1 = collision.shape:bbox()
            local x, y = math.floor((x0 + x1) / 2), math.floor((y0 + y1) / 2)
            for _, normal in pairs{collision.left_normal, collision.right_normal} do
                if normal then
                    local normal1 = normal:normalized()
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
        end
        for _, ray in ipairs(game.debug_rays) do
            local start, direction, distance, hit, blocks = unpack(ray)
            distance = distance or 1024
            love.graphics.setColor(1, 0, 0, 0.5)
            love.graphics.line(start.x, start.y, start.x + direction.x * distance, start.y + direction.y * distance)
            if hit then
                love.graphics.circle('fill', hit.x, hit.y, 4)
            end

            if game.debug_twiddles.show_blockmap then
                love.graphics.setColor(1, 0, 0, 1)
                -- FIXME yikes
                local blocksize = map.collider.blockmap.blocksize
                for i, ab in pairs(blocks) do
                    local a, b = unpack(ab)
                    love.graphics.print(tostring(i), (a + 0.5) * blocksize, (b + 0.5) * blocksize)
                end
            end
        end
        love.graphics.pop()
    end

    if game.debug and game.debug_twiddles.show_blockmap then
        love.graphics.push('all')
        love.graphics.setColor(1, 1, 1, 0.25)
        love.graphics.setColor(1, 0.5, 0.5, 0.75)
        love.graphics.scale(game.scale, game.scale)

        local blockmap = map.collider.blockmap
        local blocksize = blockmap.blocksize
        local x0 = -camera.x % blocksize
        local y0 = -camera.y % blocksize
        local w, h = game:getDimensions()
        for x = x0, w, blocksize do
            love.graphics.line(x, 0, x, h)
        end
        for y = y0, h, blocksize do
            love.graphics.line(0, y, w, y)
        end

        for x = x0, w, blocksize do
            for y = y0, h, blocksize do
                local a, b = blockmap:to_block_units(camera.x + x, camera.y + y)
                love.graphics.print((" %d, %d"):format(a, b), x, y)
            end
        end

        love.graphics.pop()
    end
end

--------------------------------------------------------------------------------
-- World scene, which draws the game world (as stored in a World)

local WorldScene = BaseScene:extend{
    __tostring = function(self) return "worldscene" end,

    -- State
    music = nil,

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

function WorldScene:init(world, ...)
    BaseScene.init(self, ...)

    -- FIXME? i'd rather rely on enter() for this, but the world is drawn via
    -- SceneFader /before/ enter() is called for the first time
    self:_refresh_canvas()

    self.layers = {}
    if game.debug then
        table.insert(self.layers, DebugLayer(world))
    end

    self.world = world
    self.camera = self.world.camera
    self.player = self.world.player

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
    game:time_push('update')

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
    -- FIXME this actually completely breaks Cherry Kisses, because it allows
    -- several dialogue scenes to pile up in the same frame, before gamestate
    -- can kick in and block the next update.  (note that this is a problem in
    -- general.)  even ignoring that, this is still bogus because it doesn't
    -- update input between the updates!  and my physics code no longer needs
    -- this anyway.  if i still want this, it should be hoisted waaaayy up,
    -- like to Game, and only after i have a better answer for Gamestate and
    -- particularly multiple pushes per frame
    --[[
    local updatect = math.max(1, math.min(MAX_UPDATES,
        math.ceil(dt * MIN_FRAMERATE)))
    local subdt = dt / updatect
    for i = 1, updatect do
        self.world:update(subdt)
    end
    ]]
    self.world:update(dt)

    love.audio.setPosition(self.player.pos.x, self.player.pos.y, 0)
    local facing = self.player:facing_to_vector()
    love.audio.setOrientation(facing.x, facing.y, 0, 0, 0, 1)

    for _, layer in ipairs(self.layers) do
        if layer.update then
            layer:update(dt)
        end
    end

    game:time_pop('update')
    game:time_maybe_print_summary()
end


function WorldScene:draw()
    game:time_push('draw')
    local w, h = game:getDimensions()
    love.graphics.push('all')
    love.graphics.setCanvas{self.canvas, stencil=true}
    love.graphics.clear()
    -- Since we're drawing to a canvas, any external transform shenanigans
    -- don't make sense here, so reset to origin.  They'll be restored when we
    -- draw the final canvas, which is important for e.g. capturing our output
    -- onto another canvas
    -- FIXME since we ALREADY draw to a canvas it's a little silly to have to
    -- capture onto another one
    love.graphics.origin()
    self.world:draw()
    for _, layer in ipairs(self.layers) do
        layer:draw()
    end
    love.graphics.pop()

    self:_draw_final_canvas()
    game:time_pop('draw')
end

function WorldScene:_draw_final_canvas()
    love.graphics.push('all')
    game:transform_viewport()
    love.graphics.draw(self.canvas, 0, 0)
    love.graphics.pop()
end

function WorldScene:resize(w, h)
    self:_refresh_canvas()
end

function WorldScene:mousepressed(x, y, button, istouch)
    if game.debug and button == 2 then
        self.player:move_to(Vector(
            x / game.scale + self.camera.x,
            y / game.scale + self.camera.y))
        self.player:get('move'):set_velocity(Vector())
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
        self:remove_actor(self.player)
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

    -- XXX revisiting is currently a bit half-assed; it was originally made for
    -- NEON PHASE's void, where the player object on the new map was completely
    -- different and we didn't want the old one moved.  meanwhile, isaac and
    -- fox flux explicitly want to throw away the old map, but anise wants to
    -- preserve them while keeping the usual moving behavior.  find a way to
    -- reconcile all of this
    local map, revisiting = self.world:load_map(tiled_map, '')

    local player_start
    if Vector.isvector(spot_name) then
        player_start = spot_name
    elseif spot_name then
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
    self.player:move_to(player_start:clone())
    map:add_actor(self.player)  -- XXX problem for neon phase

    -- World:push also updates the camera, so do it after moving the player
    self.world:push(map)
    self.current_map = map

    local map_music_path = tiled_map:prop('music')
    if map_music_path then
        self.map_music = love.audio.newSource(map_music_path, 'stream')
    else
        self.map_music = nil
    end

    -- Rez the player if necessary
    -- FIXME in general this seems like it does not remotely belong here, but
    -- also that seems like the same general question as stashing maps vs not.
    -- note that part of the reason for the order of this function is that
    -- there used to be an update(0), and if the player hadn't moved and rezzed
    -- by then, it would still be touching the thing that killed it and would
    -- instantly die again oops
    if self.player.is_dead then
        -- TODO should this be a more general 'reset'?
        self.player:resurrect()
    end
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
end

function WorldScene:leave_submap()
    self:remove_actor(self.player)

    self.world:pop()
    self.current_map = self.world.active_map
    self.submap = nil

    self:add_actor(self.player)
end

function WorldScene:add_actor(actor)
    self.current_map:add_actor(actor)
end

function WorldScene:remove_actor(actor)
    self.current_map:remove_actor(actor)
end


return WorldScene
