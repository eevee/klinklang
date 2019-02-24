local tick = require 'klinklang.vendor.tick'
local Gamestate = require 'klinklang.vendor.hump.gamestate'
local Vector = require 'klinklang.vendor.hump.vector'

local AABB = require 'klinklang.aabb'
local actors_base = require 'klinklang.actors.base'
local BaseScene = require 'klinklang.scenes.base'
local Object = require 'klinklang.object'
local BorderImage = require 'klinklang.ui.borderimage'
local TextScroller = require 'klinklang.ui.textscroller'


-- TODO some general stuff i've been wanting:
-- - consolidate into Speaker objects
--   - remove all the places i do speaker.x or self.default_x
--   - implement all the StackedSprite API stuff even for single sprites (e.g. set_talking)
-- - do...  something...?  to make passing speakers in easier and more consistent...
-- - document this because i forget how it works rather a lot.  also better error checking or something idk

-- TODO maybe this should be a /speaker/ object?
local StackedSprite = Object:extend{
    is_talking = false,
}

-- TODO defaults, explicit posing, named pose shortcuts, persistent additions like neon's weight, while_talking
function StackedSprite:init(data)
    if type(data) == 'string' then
        local sprite = game.sprites[data]:instantiate()
        self.sprites = { default = sprite }
        self.sprite_order = {'default'}
        self.sprite_poses = { default = sprite.pose }
        self.sprite_talking_map = { default = {} }
        self.sprite_metaposes = {}
        -- FIXME this seems really stupid for the extremely common case
        for pose_name in pairs(sprite.spriteset.poses) do
            self.sprite_metaposes[pose_name] = { default = pose_name }
        end
    else
        self.sprites = {}
        self.sprite_order = {}
        self.sprite_poses = {}
        self.sprite_talking_map = {}
        self.sprite_metaposes = data
        for _, datum in ipairs(data) do
            local sprite = game.sprites[datum.sprite_name]:instantiate()
            self.sprites[datum.name] = sprite
            table.insert(self.sprite_order, datum.name)
            if datum.default == false then
                self.sprite_poses[datum.name] = false
            elseif datum.default then
                sprite:set_pose(datum.default)
                self.sprite_poses[datum.name] = datum.default
            else
                self.sprite_poses[datum.name] = sprite.pose
            end
            self.sprite_talking_map[datum.name] = datum.while_talking or {}
        end
    end
end

function StackedSprite:change_pose(pose)
    if pose == false then
        for name, sprite in pairs(self.sprites) do
            self.sprite_poses[name] = false
        end
        return
    end

    if type(pose) == 'string' or #pose == 0 then
        pose = {pose}
    end

    for _, metapose_name in ipairs(pose) do
        local metapose
        if type(metapose_name) == 'table' then
            metapose = metapose_name
        else
            metapose = self.sprite_metaposes[metapose_name]
        end
        for layer_name, subpose in pairs(metapose) do
            -- TODO consult current is_talking
            self.sprite_poses[layer_name] = subpose
            if subpose ~= false then
                self.sprites[layer_name]:set_pose(subpose)
            end
        end
    end
end

function StackedSprite:set_talking(is_talking)
    if is_talking ~= self.is_talking then
        for name, sprite in pairs(self.sprites) do
            local pose = self.sprite_poses[name]
            if is_talking then
                local talking_pose = self.sprite_talking_map[name][pose]
                if talking_pose ~= nil then
                    pose = talking_pose
                end
            end

            -- FIXME wait, what if you want to use 'false' for talking?  i
            -- store only the current not-talking pose in sprite_poses...
            if pose ~= false then
                sprite:set_pose(pose)
            end
        end
    end

    self.is_talking = is_talking
end

-- TODO this should help, right
function StackedSprite:_set_sprite_pose()
end

-- FIXME what if the subsprites are different dimensions, oh goodness
function StackedSprite:getDimensions()
    return self.sprites[self.sprite_order[1]]:getDimensions()
end

for _, func in ipairs{'set_scale', 'set_facing', 'update', 'draw'} do
    StackedSprite[func] = function(self, ...)
        for _, sprite in pairs(self.sprites) do
            sprite[func](sprite, ...)
        end
    end
end

function StackedSprite:draw_anchorless(pos)
    for _, name in ipairs(self.sprite_order) do
        if self.sprite_poses[name] then
            self.sprites[name]:draw_anchorless(pos)
        end
    end
end


local DialogueMenu = Object:extend{
    -- State
    -- List of items in the menu
    items = nil,
    -- Current cursor position
    cursor = nil,
    top = nil,
    top_line = nil,
}

function DialogueMenu:init(kwargs)
    self.items = kwargs.items
    self.box = kwargs.box
    self.text_box = kwargs.text_box
    self.font = kwargs.font or love.graphics.getFont()
    self.font_prescale = kwargs.font_prescale or 1
    -- FIXME i am real inconsistent about what text/shadow colors are called
    self.shadow_color = kwargs.shadow
    self.text_color = kwargs.color
    -- FIXME also this, though it would break stuff
    self.background = kwargs.background

    -- TODO i sure do repeat this a lot; can i encapsulate it, somehow
    self.font_height = math.ceil(self.font:getHeight() * self.font:getLineHeight() / self.font_prescale)
    self.max_lines = math.floor(self.text_box.height / self.font_height)
    self.margin_y = math.floor((self.text_box.height - self.max_lines * self.font_height) / 2)

    for _, item in ipairs(self.items) do
        local _textwidth, lines = self.font:getWrap(item.text, self.text_box.width * self.font_prescale)
        local texts = {}
        for i, line in ipairs(lines) do
            texts[i] = love.graphics.newText(self.font, line)
        end
        item.texts = texts
        item.lines = lines
    end

    self.cursor = 1
    self.top = 1
    self.top_line = 1
end

function DialogueMenu:cursor_up()
    if self.cursor == 1 then
        return
    end

    -- Move up just enough to see the entirety of the newly-selected item.
    -- If it's already visible, we're done; otherwise, just put it at the top
    if self.top >= self.cursor - 1 then
        self.top = self.cursor - 1
        self.top_line = 1
    end

    self.cursor = self.cursor - 1
end

function DialogueMenu:cursor_down()
    if self.cursor == #self.items then
        return
    end

    -- Move down just enough to see the entirety of the newly-selected item.
    -- First, figure out where it is relative to the top of the dialogue box
    local relative_row = #self.items[self.top].lines - self.top_line + 1
    for l = self.top + 1, self.cursor do
        relative_row = relative_row + #self.items[l].lines
    end
    relative_row = relative_row + math.min(self.max_lines, #self.items[self.cursor + 1].lines)

    for i = 1, relative_row - self.max_lines do
        self.top_line = self.top_line + 1
        if self.top_line > #self.items[self.top].lines then
            self.top = self.top + 1
            self.top_line = 1
        end
    end

    self.cursor = self.cursor + 1
end

function DialogueMenu:accept()
    return self.items[self.cursor].value
end

function DialogueMenu:draw()
    self.background:fill(self.box)

    local lines = 0
    local is_bottom = false
    for m = self.top, #self.items do
        local item = self.items[m]
        local start_line = 1
        if m == self.top then
            start_line = self.top_line
        end
        local end_line = start_line
        local lineno = lines
        for l = start_line, #item.lines do
            end_line = l
            if m == #self.items and l == #item.lines then
                is_bottom = true
            end
            lines = lines + 1
            if lines >= self.max_lines then
                break
            end
        end
        self:draw_item(item, start_line, end_line, lineno, m == self.cursor)
        if lines >= self.max_lines then
            break
        end
    end

    -- Draw little triangles to indicate scrollability
    -- FIXME magic numbers here...  should use sprites?  ugh
    love.graphics.setColor(1, 1, 1)
    if not (self.top == 1 and self.top_line == 1) then
        self:draw_up_arrow()
    end
    if not is_bottom then
        self:draw_down_arrow()
    end
end

function DialogueMenu:draw_item(item, line0, line1, lineno, is_selected)
    -- Center the text within the available space
    local x = self.text_box.x
    local y = self.text_box.y + self.margin_y + self.font_height * lineno

    if is_selected then
        local numlines = line1 - line0 + 1
        love.graphics.setColor(1, 1, 1, 0.25)
        -- FIXME magic numbers; this used to use the text margin, but that
        -- seems bad too?  maybe should ADD a margin when computing text here
        -- idk
        love.graphics.rectangle(
            'fill',
            self.text_box.x - 4,
            y,
            self.text_box.width + 8,
            self.font_height * numlines)
    end

    local scale = 1 / self.font_prescale
    for l = line0, line1 do
        -- Draw the text, twice: once for a drop shadow, then the text itself
        love.graphics.setColor(self.shadow_color)
        love.graphics.draw(item.texts[l], x, y + 1, 0, scale)

        love.graphics.setColor(self.text_color)
        love.graphics.draw(item.texts[l], x, y, 0, scale)

        y = y + self.font_height
    end
end

function DialogueMenu:draw_up_arrow()
    local x = self.text_box.x
    local y = self.text_box.y
    love.graphics.polygon('fill', x, y - 4, x + 2, y, x - 2, y)
end

function DialogueMenu:draw_down_arrow()
    local x = self.text_box.x
    local y = self.text_box.y + self.text_box.height
    love.graphics.polygon('fill', x, y + 4, x + 2, y, x - 2, y)
end



local DialogueScene = BaseScene:extend{
    __tostring = function(self) return "dialoguescene" end,

    text_margin_x = 16,
    text_margin_y = 12,
    dialogue_height = 80,
    text_scroll_speed = 64,
    background_opacity = 0.5,
    override_sprite_bottom = nil,

    -- Mapping of position names to actual locations.  Feel free to override
    named_positions = {
        ['flush left'] = 0,
        ['far left'] = 1/16,
        ['left'] = 1/4,
        ['right'] = 3/4,
        ['far right'] = 15/16,
        ['flush right'] = 1,
    },

    -- Default speaker settings; set in a subclass (or just monkeypatch)
    -- FIXME this should be a default SPEAKER object
    default_background = nil,
    default_color = {1, 1, 1},
    default_shadow = {0, 0, 0, 0.5},
    inactive_speaker_color = {0.75, 0.75, 0.75},
}

-- TODO as with DeadScene, it would be nice if i could formally eat keyboard input
-- FIXME document the shape of speakers/script, once we know what it is
-- FIXME fonts with line heights < 1 (like m5x7) don't actually work well here, most notably in menus.  i think the text draws the same but lies about its height or something, so any excess ascender space is still there, which goofs things up?  should probably draw such text so that it's centered within its allocated space, i.e. every line is offset upwards by (1 - lineheight) * font height / 2?
-- TODO this really has just three big parts (text, menu, portraits) and maybe it would be good if those were all their own objects that this merely coordinated?
function DialogueScene:init(...)
    local args
    if select('#', ...) == 1 then
        args = ...
    else
        local speakers, script = ...
        args = {
            speakers = speakers,
            script = script,
        }
        print("WARNING: you're using the old DialogueScene args format, fixplz")
    end

    BaseScene.init(self)

    self.callback_args = args.callback_args or {}

    self.wrapped = nil
    self.tick = tick.group()

    -- FIXME should pass font in as an argument, somewhere
    self.font = love.graphics.getFont()
    self.font_prescale = 1
    self.font_height = math.ceil(self.font:getHeight() * self.font:getLineHeight())

    -- TODO a good start, but
    self.speakers = {}
    local claimed_positions = {}
    local seeking_position = {}
    for name, config in pairs(args.speakers) do
        local speaker = {
            name = name,
        }
        self.speakers[name] = speaker

        -- FIXME maybe speakers should only provide a spriteset so i'm not
        -- changing out from under them
        if config.isa and config:isa(actors_base.BareActor) then
            print('warning: passing actors to DialogueScene is deprecated!')
            local actor = config
            config = {
                position = actor.dialogue_position,
                color = actor.dialogue_color,
                shadow = actor.dialogue_shadow,
                font_prescale = actor.dialogue_font_prescale,
                sprite = actor.dialogue_sprite_name or actor.dialogue_sprites,
                background = actor.dialogue_background,
                chatter_sfx = actor.dialogue_chatter_sound,
                font = actor.dialogue_font,
            }
        end

        -- Sprite: may be a sprite name, a list of StackedSprite configuration,
        -- or an instantiated sprite
        -- FIXME always a stacked sprite!!
        if type(config.sprite) == 'string' then
            -- Sprite name
            speaker.sprite = game.sprites[config.sprite]:instantiate()
        elseif type(config.sprite) == 'table' then
            if config.sprite.isa then
                -- Probably a sprite
                speaker.sprite = config.sprite
            else
                -- Stacked sprite
                speaker.sprite = StackedSprite(config.sprite)
            end
        else
            -- TODO wait, isn't it allowed to not have a sprite?
            --error(("Can't make speaker '%s' a sprite from: %s"):format(name, config.sprite))
        end

        -- Store position for now, so conflicts can be resolved below
        if type(config.position) == 'table' then
            -- This is a list of preferred positions; the speaker will actually
            -- get the first one not otherwise spoken for
            seeking_position[name] = config.position
        elseif config.position then
            claimed_positions[config.position] = true
            -- Note that this may still be a string; it'll be fixed below
            speaker.position = config.position
        elseif speaker.sprite then
            error(("Speaker %s has a sprite but no position"):format(name))
        end

        speaker.color = config.color or self.default_color
        speaker.shadow_color = config.shadow_color or self.default_shadow

        -- FIXME make this always be a sliced and diced bg
        if config.background == nil then
            speaker.background = self.default_background
        elseif type(config.background) == 'string' then
            speaker.background = game.resource_manager:load(config.background)
        else
            speaker.background = config.background
        end
        -- Convert plain images to border images
        if speaker.background and speaker.background.typeOf and speaker.background:typeOf('Texture') then
            local w, h = speaker.background:getDimensions()
            -- Default to assuming the middle half is the center
            speaker.background = BorderImage(
                speaker.background,
                AABB(w / 4, h / 4, w / 2, h / 2))
        end

        if type(config.chatter_sfx) == 'string' then
            -- XXX why is this get, not load?
            speaker.chatter_sfx = game.resource_manager:get(config.chatter_sfx)
        else
            speaker.chatter_sfx = config.chatter_sfx
        end

        -- Font stuff is a bit tricky, since we don't want to mix a speaker's font
        -- with the default prescale, or vice versa
        if type(config.font) == 'string' then
            -- Note that this uses get, not load, so that it can grab named fonts
            -- TODO is that goofy, it feels goofy
            speaker.font = game.resource_manager:get(config.font)
        else
            speaker.font = config.font
        end
        if speaker.font then
            speaker.font_prescale = config.font_prescale or 1
        else
            speaker.font = self.font
            speaker.font_prescale = self.font_prescale
        end
        speaker.font_height = math.ceil(speaker.font:getHeight() * speaker.font:getLineHeight() / speaker.font_prescale)

        -- FIXME this is redundant with StackedSprite, but oh well
        speaker.visible = true
    end

    -- Resolve position preferences and assign positions
    while true do
        local new_positions = {}
        local any_remaining = false
        for name, positions in pairs(seeking_position) do
            any_remaining = true
            for _, position in ipairs(positions) do
                if not claimed_positions[position] then
                    -- Detect and avoid ambiguous conflicts
                    -- TODO maybe there are some better rules for this, like if
                    -- one only has one pref left but the other has two
                    if new_positions[position] then
                        error(("position conflict: %s and %s both want %s, please resolve manually")
                            :format(name, new_positions[position], position))
                    end
                    new_positions[position] = name
                    break
                end
            end
        end
        if not any_remaining then
            break
        end

        for position, name in pairs(new_positions) do
            self.speakers[name] = position
            seeking_position[name] = nil
            claimed_positions[position] = true
        end
    end
    -- Finally, convert position names to numbers
    for name, speaker in pairs(self.speakers) do
        if speaker.position and type(speaker.position) == 'string' then
            if not self.named_positions[speaker.position] then
                error(("Speaker %s has an unrecognized position: %s"):format(name, speaker.position))
            end
            speaker.position_name = speaker.position
            speaker.position = self.named_positions[speaker.position]
        end

        if speaker.sprite and (speaker.position < 0 or (speaker.position > 0.5 and speaker.position <= 1)) then
            speaker.sprite:set_facing('left')
        end
    end

    self.script = args.script
    assert(self.script, "Can't play dialogue without a script")
    self.labels = {}  -- name -> index
    for i, step in ipairs(self.script) do
        if step.label then
            if self.labels[step.label] then
                error(("Duplicate label: %s"):format(step.label))
            end
            self.labels[step.label] = i
        end
    end

    -- State of the current phrase
    self.curphrase = 1
    self.scroller = nil  -- TextScroller that holds the actual text
    self.phrase_speaker = nil
    self.chatter_enabled = true

    self.state = 'start'
    self.hesitating = false

    self.script_index = 0
end

-- Assigns self.text_box, self.dialogue_box, etc., based on the game resolution
function DialogueScene:recompute_layout()
    local w, h = game:getDimensions()

    local screen = AABB(0, 0, game:getDimensions())
    -- XXX what was this for?
    --self.dialogue_box = screen:get_chunk(0, -self.dialogue_height):with_margin(64, 0)
    --self.dialogue_box.y = self.dialogue_box.y - 32
    self.dialogue_box = screen:get_chunk(0, -self.dialogue_height)

    self.text_box = self.dialogue_box:with_margin(self.text_margin_x, self.text_margin_y)

    -- FIXME it would be nice to do this automatically again, albeit with some
    -- wiggle room for portraits like cerise who can clip off the top of the
    -- screen without causing any problems (maybe even use the collision
    -- box...?)
    --self.speaker_height = 128
    --self.speaker_scale = math.ceil((h - self.dialogue_height) / self.speaker_height)
    self.speaker_scale = 1

    for _, speaker in pairs(self.speakers) do
        if speaker.sprite then
            speaker.sprite:set_scale(self.speaker_scale)
        end
    end
end

function DialogueScene:enter(previous_scene, is_bottom)
    -- FIXME this is such a stupid fucking hack but gamestate doesn't distinguish between being pushed on top of something vs being "pushed" on top of their dummy state that's fucking broken!!
    if previous_scene and not previous_scene.xxx_eevee_fuck_ass then
        self.wrapped = previous_scene
        -- This is so if we're faded out by SceneFader, it'll fade the music from
        -- the scene below us
        self.music = self.wrapped.music
    end

    -- Recalculate stuff that depends on screen size first
    self:recompute_layout()

    self:run_from(1)
end

function DialogueScene:update(dt)
    -- Let the player hold the B button for max dialogue speed, but stop at
    -- menus
    -- FIXME this causes a character or two to show while trying to execute a
    -- scenefade
    -- FIXME put this in baton
    local holding_b = love.keyboard.isScancodeDown('d')
    for i, joystick in ipairs(love.joystick.getJoysticks()) do
        if joystick:isGamepad() then
            if joystick:isGamepadDown('b') then
                holding_b = true
                break
            end
        end
    end
    if game.debug and holding_b then
        if self.hesitate_delay then
            self.hesitate_delay:stop()
            self.hesitating = false
        end
        self:advance()
    end

    -- Do some things
    if dt > 0 and not self.hesitating then
        if game.input:pressed('accept') then
            if self.menu then
                local label = self.menu:accept()
                self.menu = nil
                self.state = 'waiting'
                self:run_from(label)
            elseif not self.hesitating then
                self:advance()
            end
        elseif game.input:pressed('up') then
            if self.menu then
                self.menu:cursor_up()
            end
        elseif game.input:pressed('down') then
            if self.menu then
                self.menu:cursor_down()
            end
        end
    end

    self.tick:update(dt)

    for _, speaker in pairs(self.speakers) do
        if speaker.sprite then
            speaker.sprite:update(dt)
        end
    end

    if self.state == 'speaking' then
        self.scroller:update(dt)
        if self.scroller.waiting then
            self.state = 'waiting'
            self.phrase_timer = 0
            self:_hesitate()
            -- TODO would be fine if always stacked...
            if self.phrase_speaker.sprite and self.phrase_speaker.sprite.set_talking then
                self.phrase_speaker.sprite:set_talking(false)
            end
        end
    end
end

function DialogueScene:evaluate_condition(condition)
    if condition == nil then
        return true
    elseif type(condition) == 'string' then
        return game.progress.flags[condition]
    else
        return condition(unpack(self.callback_args))
    end
end

function DialogueScene:_hesitate(time)
    -- Just in case this is a very short phrase, or the player tried to fill
    -- out the box just before it finished naturally (and missed), wait for a
    -- brief time before allowing a button press to go through.
    time = time or 0.1
    self.hesitating = true
    if self.hesitate_delay then
        self.hesitate_delay:stop()
    end
    self.hesitate_delay = self.tick:delay(function()
        self.hesitating = false
        self.hesitate_delay = nil
    end, time)
end

function DialogueScene:_say_phrase(step, phrase_index)
    self.curphrase = phrase_index

    local text = self.script[self.script_index][phrase_index]
    if type(text) == 'function' then
        text = text()
    end

    -- TODO wait does this actually need to know the color?  can't i do the shadow bit myself from outside?
    -- TODO uh, i think this broke chatter sounds  :(
    self.scroller = TextScroller(
        self.phrase_speaker.font,
        self.phrase_speaker.font_prescale,
        text,
        self.text_scroll_speed,
        self.text_box.width,
        self.text_box.height,
        self.phrase_speaker.color,
        self.phrase_speaker.shadow_color)

    self.state = 'speaking'
    -- TODO if stacked...
    if self.phrase_speaker.sprite and self.phrase_speaker.sprite.set_talking then
        self.phrase_speaker.sprite:set_talking(true)
    end
end

function DialogueScene:show_menu(step)
    self.state = 'menu'
    self:_hesitate(0.25)

    local items = {}
    for _, item in ipairs(step.menu) do
        if self:evaluate_condition(item.condition) then
            table.insert(items, {
                value = item[1],
                text = item[2],
            })
        end
    end

    local speaker = self.speakers[step.speaker]
    self.menu = DialogueMenu{
        items = items,
        box = self.menu_box,
        text_box = self.menu_text_box,
        -- TODO should this just get a speaker?
        background = speaker.background,
        shadow = speaker.shadow_color,
        color = speaker.color,
        font = speaker.font,
        font_prescale = speaker.font_prescale,
    }
end

-- Advance the script, including advancing through a current multi-part step
function DialogueScene:advance()
    if self.state == 'speaking' then
        -- Advance in mid-scroll: fill the textbox
        self.scroller:fill()
        self.state = 'waiting'
        self:_hesitate()
        -- TODO if stacked...
        if self.phrase_speaker.sprite and self.phrase_speaker.sprite.set_talking then
            self.phrase_speaker.sprite:set_talking(false)
        end
        return
    elseif self.state == 'menu' then
        -- We're at a menu prompt and can't advance without other input
        -- TODO unclear if this check belongs here
        return
    end

    -- State should be 'waiting' if we got here
    -- First see if the scroller is waiting for us to do something
    -- TODO shouldn't i know what i'm waiting /for/
    if self.scroller and self.scroller.waiting then
        local step = self.script[self.script_index]
        if not self.scroller.finished then
            -- We paused in the middle of a phrase (because it was too long),
            -- so just continue from here
            self.state = 'speaking'
            self.scroller:resume()
            -- TODO if stacked...
            if self.phrase_speaker.sprite and self.phrase_speaker.sprite.set_talking then
                self.phrase_speaker.sprite:set_talking(true)
            end
            return
        elseif self.curphrase < #step then
            -- Advance to the next phrase in the current step
            self:_say_phrase(step, self.curphrase + 1)
            return
        elseif step.menu then
            self:show_menu(step)
            return
        end
    end

    self:run_from(self.script_index + 1)
end

-- Jump to the given index/label in the script and continue running from the
-- beginning of that step
function DialogueScene:run_from(script_index)
    local next_script_index = script_index
    -- Resolve labels
    if type(next_script_index) == 'string' then
        next_script_index = self.labels[next_script_index]
    end

    while true do
        self.script_index = next_script_index
        if self.script_index > #self.script then
            -- TODO actually not sure what should happen here
            self.state = 'done'
            Gamestate.pop()
            return
        end
        next_script_index = self.script_index + 1
        local step = self.script[self.script_index]

        -- Early stage
        -- Flags
        if step.set then
            game.progress.flags[step.set] = true
        end
        -- Run arbitrary code
        if step.execute then
            -- FIXME you could reasonably have this alongside a jump, etc
            if self:evaluate_condition(step.condition) then
                step.execute(unpack(self.callback_args))
            end
        end
        -- Change poses
        if step.pose ~= nil then
            -- TODO this is super hokey at the moment dang
            local speaker = self.speakers[step.speaker]
            -- XXX why do i need this?
            speaker.pose = step.pose
            if speaker.sprite then
                -- FIXME uhh, passing a direct speaker doesn't give a SpeakerSprite
                if speaker.sprite.change_pose then
                    speaker.sprite:change_pose(step.pose)
                elseif step.pose == false then
                    speaker.visible = false
                else
                    speaker.visible = true
                    speaker.sprite:set_pose(step.pose)
                end
            end
        end

        -- Middle stage: talking and whatnot
        if #step > 0 then
            self.phrase_speaker = self.speakers[step.speaker]
            self:_say_phrase(step, 1)
            return
        elseif step.menu then
            self:show_menu(step)
            return
        end

        -- Late stage: what to do next
        if step.bail then
            self.state = 'done'
            Gamestate.pop()
            return
        elseif step.pause then
            -- TODO this is kind of hacky, but fixes the problem that an
            -- 'execute' that starts a SceneFader doesn't otherwise pause the
            -- script, so the fade might see the first character of the next
            -- line (or, worse, the dialogue might try to close!)
            self.state = 'waiting'
            self:_hesitate()
            return
        elseif step.jump then
            -- FIXME would be nice to scan the script for bad jumps upfront
            if self:evaluate_condition(step.condition) then
                next_script_index = self.labels[step.jump]
            end
        end
    end
end

function DialogueScene:draw()
    self:draw_backdrop()

    love.graphics.push('all')
    game:transform_viewport()

    -- Draw the dialogue box, which is slightly complicated because it involves
    -- drawing the ends and then repeating the middle bit to fit the screen
    -- size
    -- TODO get ridda this, put it in the menu bit too
    self:_draw_background(self.dialogue_box)

    -- Print the text
    -- FIXME this is unnecessary if the menu goes on top of the box
    if true then
        -- There may be more available lines than will fit in the textbox; if
        -- so, only show the last few lines
        -- FIXME should prompt to scroll when we hit the bottom, probably
        self.scroller:draw(self.text_box.x, self.text_box.y)

        -- Draw a small chevron if we're waiting
        -- FIXME more magic numbers
        if self.state == 'waiting' then
            self:_draw_chevron()
        end
    end
    if self.menu then
        self.menu:draw()
    end

    -- Draw the speakers
    -- FIXME the draw order differs per run!
    love.graphics.setColor(1, 1, 1)
    for _, speaker in pairs(self.speakers) do
        if speaker.sprite and speaker.visible then
            self:_draw_speaker(speaker)
        end
    end

    love.graphics.pop()
end

function DialogueScene:draw_backdrop()
    if self.wrapped then
        self.wrapped:draw()
    end

    love.graphics.setColor(0, 0, 0, self.background_opacity)
    love.graphics.rectangle('fill', 0, 0, love.graphics.getDimensions())
    love.graphics.setColor(1, 1, 1)
end

-- TODO this should definitely be 'textbox', right?  'background' sounds like
-- the entire scene background
function DialogueScene:_draw_background(box)
    local background = self.phrase_speaker.background
    if not background then
        return
    end

    -- FIXME isaac scaled the box by 2, oof
    background:fill(box)
end

function DialogueScene:_draw_chevron()
    local size = 4
    local x = self.text_box.x + self.text_box.width
    local y = math.floor(self.text_box.y + self.text_box.height)
    love.graphics.setColor(self.phrase_speaker.color)
    love.graphics.polygon('fill', x, y + size, x - size, y, x + size, y)
end

function DialogueScene:_draw_speaker(speaker)
    local sprite = speaker.sprite
    local sw, sh = sprite:getDimensions()
    local x
    if speaker.position < 0 then
        -- Number of pixels in from right margin (mainly useful for putting a
        -- portrait of a fixed size at a specific place on/in the dialogue box)
        x = self.dialogue_box.x + self.dialogue_box.width + speaker.position - sw
    elseif speaker.position < 1 then
        -- Proportionate distance from left
        x = math.floor(self.dialogue_box.x + (self.dialogue_box.width - sw) * speaker.position + 0.5)
    else
        -- Number of pixels in from left margin
        x = self.dialogue_box.x + speaker.position
    end

    local pos = Vector(x, (self.override_sprite_bottom or self.dialogue_box.y) - sh)
    if self.phrase_speaker == speaker then
        love.graphics.setColor(1, 1, 1)
    else
        love.graphics.setColor(self.inactive_speaker_color)
    end
    sprite:draw_anchorless(pos)
end

function DialogueScene:resize(w, h)
    -- FIXME adjust wrap width, reflow current text, etc.
    self:recompute_layout()

    -- FIXME maybe should have a wrapperscene base class that automatically
    -- passes resize events along?
    if self.wrapped and self.wrapped.resize then
        self.wrapped:resize(w, h)
    end
end

return DialogueScene
