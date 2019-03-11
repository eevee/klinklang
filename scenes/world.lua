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
                love.graphics.setColor(1, 1, 0, 0.5)
                actor.shape:draw('fill')
            end
            if actor.pos then
                love.graphics.setColor(1, 0, 0)
                love.graphics.circle('fill', actor.pos.x, actor.pos.y, 2)
                love.graphics.setColor(1, 1, 1)
                love.graphics.circle('line', actor.pos.x, actor.pos.y, 2)
            end
        end
    end

    if game.debug_twiddles.show_collision then
        for hit, collision in pairs(game.debug_hits) do
            if collision.touchtype > 0 then
                -- Collision: red
                love.graphics.setColor(1, 0, 0, 0.5)
            elseif collision.touchtype < 0 then
                -- Overlap: blue
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
                local blocksize = worldscene.world.active_map.collider.blockmap.blocksize
                for i, ab in pairs(blocks) do
                    local a, b = unpack(ab)
                    love.graphics.print(tostring(i), (a + 0.5) * blocksize, (b + 0.5) * blocksize)
                end
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

-- Given two baton inputs, returns -1 if the left is held, 1 if the right is
-- held, and 0 if neither is held.  If BOTH are held, returns either the most
-- recently-pressed, or nil to indicate no change from the previous frame.
local function read_key_axis(a, b)
    local a_down = game.input:down(a)
    local b_down = game.input:down(b)
    if a_down and b_down then
        local a_pressed = game.input:pressed(a)
        local b_pressed = game.input:pressed(b)
        if a_pressed and b_pressed then
            -- Miraculously, both were pressed simultaneously, so stop
            return 0
        elseif a_pressed then
            return -1
        elseif b_pressed then
            return 1
        else
            -- Neither was pressed this frame, so we don't know!  Preserve the
            -- previous frame's behavior
            return nil
        end
    elseif a_down then
        return -1
    elseif b_down then
        return 1
    else
        return 0
    end
end

function WorldScene:read_player_input(dt)
    -- Converts player input to decisions.
    -- Note that actions come in two flavors: instant actions that happen WHEN
    -- a button is pressed, and continuous actions that happen WHILE a button
    -- is pressed.  The former check 'down'; the latter check 'pressed'.
    -- FIXME reconcile this with a joystick; baton can do that for me, but then
    -- it considers holding left+right to be no movement at all, which is bogus
    local walk_x = read_key_axis('left', 'right')
    local walk_y = read_key_axis('up', 'down')
    self.player:decide_move(walk_x, walk_y)

    -- FIXME this is such a fucking mess lmao
    -- TODO up+jump doesn't work correctly, but it's a little fiddly, since
    -- you should only resume climbing once you reach the peak of the jump?
    local climb = read_key_axis('ascend', 'descend')
    if climb == 1 then
        -- Only start climbing down if this is a NEW press, so that down+jump
        -- doesn't immediately regrab on the next frame
        if not game.input:pressed('descend') then
            climb = nil
        end
    end
    if climb == 0 then
        self.player:decide_pause_climbing()
    elseif climb ~= nil then
        self.player:decide_climb(climb)
    end

    -- Jumping is slightly more subtle.  The initial jump is an instant action,
    -- but /continuing/ to jump is a continuous action.
    if game.input:pressed('jump') then
        -- Down + jump also means let go
        if game.input:down('descend') then
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
    -- FIXME this definitely shouldn't be in the worldscene; change me to decide_use or something
    if false and dt > 0 and game.input:pressed('use') then
        if self.player.is_locked then
            -- Do nothing
        elseif self.player.form == 'stone' then
            -- Do nothing
            -- FIXME oh this absolutely does not belong here
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
end

function WorldScene:update(dt)
    -- FIXME could get rid of this entirely if actors had to go through me to
    -- collide
    game.debug_hits = {}
    game.debug_rays = {}

    self:read_player_input(dt)

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
    local facing = self.player:facing_to_vector()
    love.audio.setOrientation(facing.x, facing.y, 0, 0, 0, 1)

    for _, layer in ipairs(self.layers) do
        if layer.update then
            layer:update(dt)
        end
    end
end


function WorldScene:draw()
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

    -- FIXME why is this here and not a layer?  is it because of the camera coord inconsistency with layers?
    if game.debug and game.debug_twiddles.show_blockmap then
        self:_draw_blockmap()
    end
end

-- Note: pos is the center of the hint; sprites should have their anchors at
-- their centers too
function WorldScene:_draw_use_key_hint(anchor)
    -- FIXME move this into fox flux as an actor (like neon phase), see if
    -- there's anything useful that can be factored out of it i guess?
    do return end
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
    love.graphics.setColor(1, 1, 1, 0.25)
    love.graphics.setColor(1, 0.5, 0.5, 0.75)
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
    love.graphics.push('all')
    game:transform_viewport()
    love.graphics.draw(self.canvas, 0, 0)
    love.graphics.pop()
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
