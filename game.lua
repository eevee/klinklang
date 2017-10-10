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
end


--------------------------------------------------------------------------------
-- Game resolution

function Game:_determine_scale()
    -- Default resolution is 640 × 360, which is half of 720p and a third
    -- of 1080p and equal to 40 × 22.5 tiles.  With some padding, I get
    -- these as the max viewport size.
    -- TODO this doesn't specify any /minimum/ size...  but it could
    local w, h = love.graphics.getDimensions()
    local MAX_WIDTH = 960  -- 30 tiles
    local MAX_HEIGHT = 540  -- almost 17 tiles
    self.scale = math.ceil(math.max(w / MAX_WIDTH, h / MAX_HEIGHT))
end

function Game:getDimensions()
    return math.ceil(love.graphics.getWidth() / self.scale), math.ceil(love.graphics.getHeight() / self.scale)
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
