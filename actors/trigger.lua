local Gamestate = require 'klinklang.vendor.hump.gamestate'
local Vector = require 'klinklang.vendor.hump.vector'

local actors_base = require 'klinklang.actors.base'
local util = require 'klinklang.util'
local whammo_shapes = require 'klinklang.whammo.shapes'
local DialogueScene = require 'klinklang.scenes.dialogue'
local SceneFader = require 'klinklang.scenes.fader'


local TriggerZone = actors_base.BareActor:extend{
    name = 'trigger',
}

function TriggerZone:init(pos, props, shapes)
    self.pos = pos
    -- FIXME?  could just split this up into multiple zones
    self.shape = shapes[1]

    self.props = props or {}
    if props then
        self.action = props.action
        self.activation = props.activation
    end
    if not self.action then
        self.action = 'submap'
    end
    if not self.activation then
        self.activation = 'use'
    end

    if self.activation == 'use' then
        self.is_usable = true
    end
end

function TriggerZone:on_enter(...)
    TriggerZone.__super.on_enter(self, ...)

    if self.props.flag and game:flag(self.props.flag) then
        -- XXX this used to not call super in the first place before
        -- destroying itself, but, that seems rude.  otoh now there's a
        -- chance of firing on the first frame, which is, bad
        self:destroy()
    end
end

function TriggerZone:blocks()
    return false
end

function TriggerZone:on_collide(activator)
    if activator.is_player and self.activation == 'touch' then
        self:execute_trigger(activator)
    end
end

function TriggerZone:on_use(activator)
    if activator.is_player and self.activation == 'use' then
        self:execute_trigger(activator)
    end
end

function TriggerZone:execute_trigger(activator)
    -- TODO turn these into, idk, closures or something interesting?
    if self.action == 'change map' then
        Gamestate.push(SceneFader(worldscene, true, 0.33, {255, 130, 206}, function()
            -- FIXME need to manually delete the map for fox flux and isaac or
            -- we'll collect them forever, yeargh.  but need to NOT do this for
            -- anise and neon phase?  double yeargh
            self.map.world.live_maps[self.map.tiled_map] = nil

            local map = game.resource_manager:load(self.props.map)
            worldscene:load_map(map, self.props.spot)
        end))
    elseif self.action == 'enter submap' then
        worldscene:enter_submap(self.props.submap)
    elseif self.action == 'leave submap' then
        worldscene:leave_submap()
    elseif self.action == 'broadcast' then
        for _, actor in ipairs(self.map.actors) do
            if actor[self.props.message] then
                actor[self.props.message](actor, activator, self.props)
            end
        end
    elseif self.action == 'conversation' then
        local actors_npcs = require 'foxflux.actors.npcs'
        local Gamestate = require 'klinklang.vendor.hump.gamestate'
        local DialogueScene = require 'klinklang.scenes.dialogue'
        local conversations = require 'foxflux.conversations'
        local convo = conversations.pick_conversation(self.props.conversation, activator.form)
        Gamestate.push(DialogueScene({
            lexy = activator,
            cerise = actors_npcs.Cerise,
            narrator = {
                background = game.resource_manager:load('assets/images/dialoguebox-narrator.png'),
            },
        }, convo))
    end

    if self.props.once then
        -- FIXME should also prevent triggering again this frame
        self:destroy()
    end
end


return TriggerZone
