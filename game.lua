local baton = require 'klinklang.vendor.baton'
local Vector = require 'klinklang.vendor.hump.vector'

local AABB = require 'klinklang.aabb'
local Jukebox = require 'klinklang.jukebox'
local Object = require 'klinklang.object'
local ResourceManager = require 'klinklang.resources'
local SpriteSet = require 'klinklang.sprite'
local tiledmap = require 'klinklang.tiledmap'

local GameProgress = Object:extend{}

local Game = Object:extend{
    jukebox_class = Jukebox,

    debug = false,
    input = nil,
    resource_manager = nil,
    -- FIXME this seems ugly, but the alternative is to have sprite.lua implicitly depend here
    sprites = SpriteSet._all_sprites,
    is_dirty = false,
    native_size = Vector(960, 540),  -- half of 1080p; 30 x ~17 32x32 tiles
    minimum_size = nil,

    size = nil,  -- vector of the game's intrinsic size
    scale = nil,  -- how much the game is scaled up on display
    screen = nil,  -- aabb of the drawable area on screen
}

-- Creates a new Game, the god object representing the game state.
-- Keyword arguments:
--   native_size: a Vector containing the game's preferred size.  Resizing the
--      window will set the game size to the nearest integer multiple of this
--      size.  Defaults to half of 1080p.
--   minimum_size: an optional Vector containing the game's minimum size, which
--      should be smaller than the native size.  This allows a little wiggle
--      room when, e.g., running fullscreen on a 16:10 monitor; the edges can
--      be trimmed rather than forcing some serious letterboxing.  Defaults to
--      nil, which forbids trimming edges.  I've found that making this around
--      15% smaller than the native size allows for the widest range of
--      fullscreen resolutions.
function Game:init(args)
    args = args or {}
    if args.native_size then
        self.native_size = args.native_size
    end
    if args.minimum_size then
        self.minimum_size = args.minimum_size
    end

    self.resource_manager = ResourceManager()
    self:_configure_resource_manager()

    self.debug_twiddles = {
        show_blockmap = false,
        show_collision = false,
        show_shapes = false,
    }
    self.debug_hits = {}
    self.debug_rays = {}

    self.jukebox = self.jukebox_class()

    self.time_stack = {}
    self.time_summary = {}
    self.time_t0 = love.timer.getTime()
    self.time_threshold = 4

    self.progress = {
        flags = {},
    }

    self:_determine_scale()
end

function Game:_configure_resource_manager()
    self.resource_manager:register_default_loaders()
    self.resource_manager:register_loader('tmx.json', function(path)
        return tiledmap.TiledMap:parse_json_file(path, game.resource_manager)
    end)
    self.resource_manager.locked = false  -- TODO make an api for this lol
end

function Game:assign_controls(mapping)
    self.input = baton.new(mapping)
end

function Game:update(dt)
    self.input:update(dt)
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
    self.scale = math.max(1, math.floor(math.min(sw / target_size.x, sh / target_size.y)))

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

-- Note that you should do an 'all' push before calling this, because it also alters the scissor,
-- which will not be undone by either a clear() or by a regular pop!
function Game:transform_viewport()
    love.graphics.translate(self.screen.x, self.screen.y)
    love.graphics.scale(self.scale, self.scale)
    love.graphics.intersectScissor(self.screen:xywh())
end


--------------------------------------------------------------------------------
-- Time tracking
-- XXX extremely something that should be in its own type

function Game:time_push(category)
    table.insert(self.time_stack, { category = category, t0 = love.timer.getTime(), exclude = 0 })
end

function Game:time_pop(category)
    local slice = self.time_stack[#self.time_stack]
    if slice == nil then
        error("Can't pop an empty time stack!")
    elseif slice.category ~= category then
        error(("Tried to pop time category %s but the top is %s!"):format(category, slice.category))
    end

    local dt = love.timer.getTime() - slice.t0 - slice.exclude
    self.time_stack[#self.time_stack] = nil
    local summary = self.time_summary[category]
    if summary == nil then
        summary = { time = 0, count = 0 }
        self.time_summary[category] = summary
    end
    summary.time = summary.time + dt
    summary.count = summary.count + 1

    for _, other_slice in ipairs(self.time_stack) do
        other_slice.exclude = other_slice.exclude + dt
    end
end

function Game:time_maybe_print_summary()
    if #self.time_stack > 0 then
        error("Can't summarize time within a frame")
    end

    local now = love.timer.getTime()
    local elapsed = now - self.time_t0
    if elapsed > self.time_threshold then
        local parts = {}
        local tracked = 0
        for category, summary in pairs(self.time_summary) do
            table.insert(parts, ("%s (%d): %5.2f%%"):format(category, summary.count, summary.time / elapsed * 100))
            tracked = tracked + summary.time
        end
        table.insert(parts, ("%s: %5.2f%%"):format('total', tracked / elapsed * 100))
        print(table.concat(parts, ' / '))
        self.time_t0 = now
        self.time_summary = {}
    end
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
