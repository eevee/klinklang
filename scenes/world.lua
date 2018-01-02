local Vector = require 'vendor.hump.vector'

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
-- - remove actors, collider, fluct, tick, submap, camera
-- - give actors a reference to the map they're on?  maybe pass it to on_enter?
-- - remove _draw_use_key_hint (fox flux specific?  or maybe neon phase?)
-- - remove the inventory switch Q binding (oh my GOD)
-- - move drawing of the blockmap to DebugLayer
-- - give everything a self.game property maybe??
-- - do something with camera jitter?

--------------------------------------------------------------------------------
-- Layers

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

function WorldScene:init(world, ...)
    BaseScene.init(self, ...)

    -- FIXME? i'd rather rely on enter() for this, but the world is drawn via
    -- SceneFader /before/ enter() is called for the first time
    self:_refresh_canvas()

    self.layers = {}
    if game.debug then
        table.insert(self.layers, DebugLayer(self))
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
    self.world:push(map)
    self.current_map = map
    self.fluct = self.current_map.flux
    self.tick = self.current_map.tick
    self.actors = self.current_map.actors
    self.collider = self.current_map.collider

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
    self.player:move_to(player_start:clone())
    self:add_actor(self.player)  -- XXX problem for neon phase

    local map_music_path = tiled_map:prop('music')
    if map_music_path then
        self.map_music = love.audio.newSource(map_music_path, 'stream')
    else
        self.map_music = nil
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
