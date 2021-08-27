local Object = require 'klinklang.object'

-- TODO expand on this
local Jukebox = Object:extend{}

function Jukebox:play_sound(sound)
    if type(sound) == 'string' then
        sound = game.resource_manager:load(sound)
    end

    sound:clone():play()
end


return Jukebox
