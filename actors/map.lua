local Vector = require 'vendor.hump.vector'

local actors_base = require 'klinklang.actors.base'
local util = require 'klinklang.util'


local TiledMapLayer = actors_base.BareActor:extend{
    -- lazily created by _make_batches
    sprite_batches = nil,
}

function TiledMapLayer:init(layer, map, z)
    self.layer = layer
    self.map = map
    self.z = z
end

function TiledMapLayer:_make_batches()
    -- NOTE: This batched approach means that the map /may not/ render
    -- correctly if an oversized tile overlaps other tiles.  But I don't do
    -- that, and it seems like a bad idea anyway, so.
    -- TODO consider benchmarking this (on a large map) against recreating a
    -- batch every frame but with only visible tiles?
    self.sprite_batches = {}

    local tw, th = self.map.tilewidth, self.map.tileheight

    local width, height = self.layer.width, self.layer.height
    local data = self.layer.data
    for t, tile in ipairs(self.layer.tilegrid) do
        if tile then
            local tileset = tile.tileset
            local batch = self.sprite_batches[tileset]
            if not batch then
                batch = love.graphics.newSpriteBatch(
                    tileset.image, width * height, 'static')
                self.sprite_batches[tileset] = batch
            end
            local ty, tx = util.divmod(t - 1, width)
            batch:add(
                tileset.quads[tile.id],
                -- convert tile offsets to pixels
                tx * tw,
                (ty + 1) * th - tileset.tileheight)
        end
    end
end

function TiledMapLayer:update(dt)
    -- TODO maybe someday this will handle animated tiles!
end

function TiledMapLayer:draw()
    if not self.sprite_batches then
        self:_make_batches()
    end
    for tileset, batch in pairs(self.sprite_batches) do
        love.graphics.draw(batch)
    end
end


return {
    TiledMapLayer = TiledMapLayer,
}
