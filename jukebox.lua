local flux = require 'klinklang.vendor.flux'

local Object = require 'klinklang.object'
local util = require 'klinklang.util'


-- The Jukebox handles music with a stack, intended to mirror the scene stack.  To preserve the
-- integrity of the stack, pushing onto it returns a Handle, which should be used anytime a scene
-- wants to change the music it's already playing -- that way, if that scene happens to not be on
-- top at the moment, the Jukebox can know that and avoid clobbering the top scene's music.
local JukeboxMusicHandle = Object:extend{}

function JukeboxMusicHandle:init(jukebox, path, channel)
    self.jukebox = jukebox
    self.channel = channel
    self.track = nil
    self.playing = true
    self:change(path)
end

function JukeboxMusicHandle:change(path)
    if path == self.path then
        return
    end

    self:_pause()
    self.track = nil

    self.path = path
    if path then
        self.track = self.jukebox:_load_music(path)
        self:_play()
    end
end

function JukeboxMusicHandle:play()
    if self.in_stack and self.track then
        self.playing = true
        self.track:play()
    end
end

function JukeboxMusicHandle:pause(fadeout)
    self.playing = false
    self:_pause(fadeout)
end

function JukeboxMusicHandle:pop()
    self:_pause()
    self.jukebox:_pop_handle(self)
end

function JukeboxMusicHandle:_play()
    if self.track and self.playing then
        self.track:play()
    end
end

function JukeboxMusicHandle:_pause(fadeout)
    if self.track then
        self.jukebox:_fadeout_music(self.track, self.channel, fadeout)
    end
end


-- TODO expand on this
local Jukebox = Object:extend{
}

function Jukebox:init()
    self.current_music = nil
    self.music_stack = {}
    self.channel_volumes = {}
    self.overall_volume = 1

    self.fade_duration = 1

    self.flux = flux.group()
end

function Jukebox:update(dt)
    self.flux:update(dt)
end

function Jukebox:_update_volume(source, channel, multiplier)
    local volume = self.overall_volume * (multiplier or 1) * (self.channel_volumes[channel] or 1)
    source:setVolume(volume)
    return volume
end

-- Music

function Jukebox:push_music(path, channel)
    if self.current_music then
        self.current_music:_pause()
    end

    local handle = JukeboxMusicHandle(self, path, channel or 'music')
    table.insert(self.music_stack, handle)
    self.current_music = handle
    handle.in_stack = true

    handle:play()

    return handle
end

function Jukebox:_load_music(path, channel)
    local source = love.audio.newSource(path, 'stream')
    source:setLooping(true)
    self:_update_volume(source, channel or 'music')
    return source
end

function Jukebox:_fadeout_music(source, channel, fadeout)
    if fadeout == 0 then
        source:pause()
        return
    end

    local tbl = { volume = 1 }
    self.flux:to(tbl, fadeout or self.fade_duration, { volume = 0 })
        :onupdate(function()
            self:_update_volume(source, channel, tbl.volume)
        end)
        :oncomplete(function()
            source:pause()
            self:_update_volume(source, channel)
        end)
end

function Jukebox:_pop_handle(handle)
    if self.current_music == handle then
        self.music_stack[#self.music_stack] = nil
        self.current_music = self.music_stack[#self.music_stack]
        if self.current_music then
            self.current_music:_play()
        end
    else
        util.warn("Trying to pop a music track that's not on top of the stack" .. "\n" .. debug.traceback())
    end
end

-- One-time sounds

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
