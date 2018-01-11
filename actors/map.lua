local Vector = require 'vendor.hump.vector'

local actors_base = require 'klinklang.actors.base'
local tiledmap = require 'klinklang.tiledmap'
local util = require 'klinklang.util'


-- This is a special kind of actor: it doesn't have a position!  Since this is
-- a fixed part of the map, rather than instantiating one for every occurrence
-- of the tile, we just keep a single instance around and reuse that whenever
-- necessary.  Naturally, it cannot have any state.  It's mainly useful for
-- reading a standard set of properties and responding to collisions.
local TiledMapTile = actors_base.BareActor:extend{
    permeable = nil,
    terrain = nil,
    fluid = nil,
}

function TiledMapTile:init(tiled_tile)
    self.tiled_tile = tiled_tile
    self.permeable = tiled_tile:prop('permeable')
    self.terrain = tiled_tile:prop('terrain')
    self.fluid = tiled_tile:prop('fluid')
end

function TiledMapTile:blocks()
    return not self.permeable
end

function TiledMapTile:on_collide(actor)
end


-- A completely arbitrary collision shape drawn in Tiled
-- FIXME this isn't actually in yet, but once it is, collision actor should
-- always exist and be an actor!!  WAIT NO THERE'S STILL THE MAP EDGES FUCK
local TiledMapCollision = actors_base.BareActor:extend{}

function TiledMapCollision:init(tiled_object)
    self.tiled_object = tiled_object
    self.pos = Vector()  -- TODO hmm.
    self.shape = tiledmap.tiled_shape_to_whammo_shape(tiled_object)
end


local TiledMapLayer = actors_base.BareActor:extend{
    -- lazily created by _make_batches
    sprite_batches = nil,

}

function TiledMapLayer:init(layer, tiled_map, z)
    self.layer = layer
    self.tiled_map = tiled_map
    self.z = z
    -- TODO i observe that we'll end up duplicating the actors across multiple
    -- layers, multiple maps, etc., but i'm not sure where a global stash of
    -- them would go
    self.tile_actors = {}
end

function TiledMapLayer:_make_shapes_and_actors()
    if self.shapes then
        return
    end
    self.shapes = {}

    if self.layer.type == 'tilelayer' then
        local width, height = self.layer.width, self.layer.height
        for t, tile in ipairs(self.layer.tilegrid) do
            if tile then
                if self.tile_actors[tile] == nil then
                    self.tile_actors[tile] = TiledMapTile(tile)
                end

                -- FIXME would be nice to have arbitrary shapes per tile!
                -- then they could be part oneway, part not, or whatever.
                local shape = tile:get_collision()
                if shape then
                    local ty, tx = util.divmod(t - 1, width)
                    shape = tiledmap._xxx_oneway_aware_shape_clone(shape)
                    shape:move(
                        tx * self.tiled_map.tilewidth,
                        (ty + 1) * self.tiled_map.tileheight - tile.tileset.tileheight)
                    self.shapes[shape] = tile
                end
            end
        end
    elseif self.layer.type == 'objectgroup' then
        -- FIXME this won't actually happen yet because we don't make a Layer
        -- actor out of object layers yet, oof
        for _, obj in ipairs(self.layer.objects) do
            -- TODO could maybe generalize this to do other stuff?  actually i
            -- guess we could even spawn actors from here??  ehh, hm
            if obj.type == 'collision' then
                local actor = TiledMapCollision(obj)
                self.shapes[actor.shape] = actor
            end
        end
    end
end

function TiledMapLayer:_make_batches()
    -- NOTE: This batched approach means that the map /may not/ render
    -- correctly if an oversized tile overlaps other tiles.  But I don't do
    -- that, and it seems like a bad idea anyway, so.
    -- TODO consider benchmarking this (on a large map) against recreating a
    -- batch every frame but with only visible tiles?
    if self.sprite_batches then
        return
    end
    self.sprite_batches = {}

    local tw, th = self.tiled_map.tilewidth, self.tiled_map.tileheight

    local width, height = self.layer.width, self.layer.height
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

function TiledMapLayer:on_enter(map)
    TiledMapLayer.__super.on_enter(self, map)

    -- We don't have a shape of our own, but we DO have a bunch of collision
    -- based on our tiles, so add those here
    if self.layer:prop('exclude from collision') then
        return
    end

    self:_make_shapes_and_actors()

    for shape, tile in pairs(self.shapes) do
        map.collider:add(shape, self.tile_actors[tile])
    end

    -- Also add all our tile actors, once each of course
    for tile, actor in pairs(self.tile_actors) do
        map:add_actor(actor)
    end
end

function TiledMapLayer:on_leave()
    -- Undo what we did above: remove the tile actors, then the collisions
    for tile, actor in pairs(self.tile_actors) do
        map:remove_actor(actor)
    end
    if self.layer.type == 'tilelayer' and self.shapes then
        for shape, tile in pairs(self.shapes) do
            self.map.collider:remove(shape)
        end
    end

    TiledMapLayer.__super.on_leave(self)
end

function TiledMapLayer:update(dt)
    -- TODO maybe someday this will handle animated tiles!
end

function TiledMapLayer:draw()
    self:_make_batches()
    for tileset, batch in pairs(self.sprite_batches) do
        love.graphics.draw(batch)
    end
end


return {
    TiledMapLayer = TiledMapLayer,
}
