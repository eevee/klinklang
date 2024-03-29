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
    -- Cut the tween loose, too
    self.volume_tween = nil

    self.path = path
    if path then
        self.track = self.jukebox:_load_music(path)
        self:_play()
    end
end

function JukeboxMusicHandle:play()
    if self.in_stack and self.track then
        self.playing = true
        self:_play()
    end
end

function JukeboxMusicHandle:pause(fadeout)
    self.playing = false
    self:_pause(fadeout)
end

function JukeboxMusicHandle:pop(fadeout)
    self:_pause(fadeout)
    self.jukebox:_pop_handle(self, fadeout)
end

function JukeboxMusicHandle:_play()
    self:_cancel_fade()
    if self.track and self.playing then
        self.track:play()
    end
end

function JukeboxMusicHandle:_pause(fadeout)
    self:_fade(1, 0, fadeout or self.jukebox.fade_duration)
end

function JukeboxMusicHandle:_fade(from, to, ttl)
    self:_cancel_fade()

    if not self.track then
        return
    end

    if ttl == 0 then
        if to == 0 then
            self.track:pause()
        end
        return
    end

    -- We might change tracks while this is running, so hold a ref to the current one
    local source = self.track
    local channel = self.channel
    local tbl = { volume = from }
    local tween = self.jukebox.flux:to(tbl, ttl, { volume = to })
        :onupdate(function()
            self.jukebox:_update_volume(source, channel, tbl.volume)
        end)
        :oncomplete(function()
            if to == 0 then
                source:pause()
                self.jukebox:_update_volume(source, channel)
            end
            if self.volume_tween == tween then
                self.volume_tween = nil
            end
        end)
    self.volume_tween = tween
end

function JukeboxMusicHandle:_cancel_fade()
    if self.volume_tween then
        self.volume_tween:stop()
        self.volume_tween = nil
        if self.track then
            self.jukebox:_update_volume(self.track, self.channel)
        end
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

function Jukebox:push_music(path, channel, fadeout)
    if self.current_music then
        self.current_music:_pause(fadeout)
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

function Jukebox:_pop_handle(handle, fadeout, fadein)
    if self.current_music == handle then
        self.music_stack[#self.music_stack] = nil
        self.current_music = self.music_stack[#self.music_stack]
        if self.current_music then
            self.current_music:_play(fadein)
        end
    else
        util.warn("Trying to pop a music track that's not on top of the stack" .. "\n" .. debug.traceback())
    end
end

function Jukebox:set_volume(volume, channel)
    if channel == nil then
        self.overall_volume = volume
    else
        self.channel_volumes[channel] = volume
    end

    for _, handle in ipairs(self.music_stack) do
        if handle.track then
            self:_update_volume(handle.track, handle.channel)
        end
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

    sound:setVolume(self.overall_volume)

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
