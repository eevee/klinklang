local Object = require 'klinklang.object'

-- TODO expand on this
local Jukebox = Object:extend{}

function Jukebox:_play_sound(sound, once, pos)
    if type(sound) == 'string' then
        sound = game.resource_manager:load(sound)
    end

    if not once then
        sound = sound:clone()
    end

    if pos and sound:getChannelCount() == 1 then
        sound:setPosition(pos.x, pos.y, 0)
        -- TODO maybe this oughta go in, i dunno, loading code
        -- note that the player position is Outwards so this needs to take that into account too
        sound:setAttenuationDistances(32 * 12, 32 * 32)
    end

    return sound, sound:play()
end

function Jukebox:play_sound(sound, pos)
    return self:_play_sound(sound, false, pos)
end

function Jukebox:play_sound_once(sound, pos)
    return self:_play_sound(sound, true, pos)
end


return Jukebox
