local Vector = require 'klinklang.vendor.hump.vector'

local AABB = require 'klinklang.aabb'
local Object = require 'klinklang.object'
local ResourceManager = require 'klinklang.resources'
local SpriteSet = require 'klinklang.sprite'

local GameProgress = Object:extend{}

local Game = Object:extend{
    scale = 1,
    debug = false,
    input = nil,
    resource_manager = nil,
    -- FIXME this seems ugly, but the alternative is to have sprite.lua implicitly depend here
    sprites = SpriteSet._all_sprites,
    is_dirty = false,
    native_size = Vector(960, 540),  -- half of 1080p; 30 x ~17 32x32 tiles
    minimum_size = Vector(832, 448),  -- allow cropping ~2x4 tiles (optional)

    size = nil,  -- vector of the game's intrinsic size
    scale = nil,  -- how much the game is scaled up on display
    screen = nil,  -- aabb of the drawable area on screen
}

function Game:init()
    self.resource_manager = ResourceManager()

    self.debug_twiddles = {
        show_blockmap = true,
        show_collision = true,
        show_shapes = true,
    }
    self.debug_hits = {}
    self.debug_rays = {}

    self.progress = {
        flags = {},
    }

    self:_determine_scale()
end


--------------------------------------------------------------------------------
-- Game resolution

function Game:_determine_scale()
    local sw, sh = love.graphics.getDimensions()
    -- FIXME do something globally useful when the window is too small!
    -- This scales as large as possible without exceeding the min size.
    -- In the face of ambiguity (e.g. when min size is much smaller than native
    -- size, there's a choice between more cropping or more letterboxing), it
    -- prefers showing more of the game.
    local target_size = self.minimum_size or self.native_size
    self.scale = math.floor(math.min(sw / target_size.x, sh / target_size.y))

    local gw = math.min(math.ceil(sw / self.scale), self.native_size.x)
    local gh = math.min(math.ceil(sh / self.scale), self.native_size.y)
    self.size = Vector(gw, gh)
    self.screen = AABB(
        math.floor((sw - gw * self.scale) / 2),
        math.floor((sh - gh * self.scale) / 2),
        gw * self.scale,
        gh * self.scale)
end

function Game:getDimensions()
    return self.size:unpack()
end

function Game:transform_viewport()
    love.graphics.setScissor(self.screen:xywh())
    love.graphics.translate(self.screen.x, self.screen.y)
    love.graphics.scale(self.scale, self.scale)
end


--------------------------------------------------------------------------------
-- Progress tracking

-- FIXME should these be methods on a progress object?
function Game:flag(flag)
    return self.progress.flags[flag]
end

function Game:set_flag(flag)
    self.is_dirty = true
    self.progress.flags[flag] = true
end


return Game
