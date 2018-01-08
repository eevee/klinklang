local Vector = require 'vendor.hump.vector'

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
    max_screen_size = Vector(960, 540),  -- half of 1080p; 30 x ~17 32x32 tiles

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
    local w, h = love.graphics.getDimensions()
    self.scale = math.ceil(math.max(
        w / self.max_screen_size.x,
        h / self.max_screen_size.y))
    local width = math.ceil(w / self.scale)
    local height = math.ceil(h / self.scale)
    self.size = Vector(width, height)
    self.screen = AABB(0, 0, w, h)
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
