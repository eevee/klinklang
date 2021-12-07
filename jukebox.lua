local Object = require 'klinklang.object'

-- TODO expand on this
local Jukebox = Object:extend{}

function Jukebox:play_sound(sound, pos)
    if type(sound) == 'string' then
        sound = game.resource_manager:load(sound)
    end

    sound = sound:clone()
    if pos and sound:getChannelCount() == 1 then
        sound:setPosition(pos.x, pos.y, 0)
        -- TODO maybe this oughta go in, i dunno, loading code
        -- note that the player position is Outwards so this needs to take that into account too
        sound:setAttenuationDistances(32 * 12, 32 * 32)
    end

    sound:play()
end


return Jukebox
