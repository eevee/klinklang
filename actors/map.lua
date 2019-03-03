local Vector = require 'klinklang.vendor.hump.vector'

local AABB = require 'klinklang.aabb'
local actors_base = require 'klinklang.actors.base'
local tiledmap = require 'klinklang.tiledmap'
local util = require 'klinklang.util'
local whammo_shapes = require 'klinklang.whammo.shapes'


-- This is a special kind of actor: it doesn't have a position!  Since this is
-- a fixed part of the map, rather than instantiating one for every occurrence
-- of the tile, we just keep a single instance around and reuse that whenever
-- necessary.  Naturally, it cannot have any state.  It's mainly useful for
-- reading a standard set of properties and responding to collisions.
local TiledMapTile = actors_base.BareActor:extend{
    name = 'map tile',
    permeable = nil,
    terrain = nil,
    fluid = nil,

    PROPS_USED = {'permeable', 'terrain', 'fluid'},
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

    self.animated_tiles = {}  -- animated tileid -> { batch id and x/y, timer, frame, frames = { quad, duration } }
end

local function _are_tiles_merge_compatible(a, b)
    for _, prop in ipairs(TiledMapTile.PROPS_USED) do
        if a:prop(prop) ~= b:prop(prop) then
            return false
        end
    end

    -- FIXME i really need a better way to track one-way collision
    if a:get_collision()._xxx_is_one_way_platform ~=
        a:get_collision()._xxx_is_one_way_platform
    then
        return false
    end

    return true
end

function TiledMapLayer:_make_shapes_and_actors()
    if self.shapes then
        return
    end
    self.shapes = {}

    -- A very common case is to have big regions of tiles that are all
    -- completely solid.  The naïve approach produces a separate shape for
    -- every single one of those tiles, which increases the size of the
    -- blockmap and requires more collision checks in general.  Merging
    -- adjacent collision shapes improves things almost for free.
    -- For now, we do the easy thing and only merge horizontal runs.  It's
    -- possible to merge in both directions, but certainly more complicated,
    -- and subject to diminishing returns.
    -- NOTE: If it ever becomes possible to change the map at runtime, we'll
    -- need to handle breaking these adjacent blocks back up!
    -- FIXME: need to combine across different tiles, if the props are compatible
    -- FIXME: this loses 'one-way' status!  argh
    local merged_aabb  -- our running shape
    local merged_tile  -- map tile of the first shape
    local MAX_TILE_MERGE = 32

    local function reify_merged_shape()
        if merged_aabb then
            local merged_shape = whammo_shapes.Box(0, 0, merged_aabb.width, merged_aabb.height)

            -- FIXME i really, really need a better way to track one-way collision
            if merged_tile:get_collision()._xxx_is_one_way_platform then
                merged_shape._xxx_is_one_way_platform = true
            end

            merged_shape:move(merged_aabb.x, merged_aabb.y)
            self.shapes[merged_shape] = merged_tile
            merged_aabb = nil
            merged_tile = nil
        end
    end

    if self.layer.type == 'tilelayer' then
        local width = self.layer.width
        for t, tile in ipairs(self.layer.tilegrid) do
            if not tile then
                reify_merged_shape()
                goto continue
            end

            if self.tile_actors[tile] == nil then
                self.tile_actors[tile] = TiledMapTile(tile)
            end

            -- FIXME would be nice to have an arbitrary number of shapes per tile!
            -- then they could be part oneway, part not, or whatever.
            local shape = tile:get_collision()
            if not shape then
                reify_merged_shape()
                goto continue
            end

            local ty, tx = util.divmod(t - 1, width)
            local x = tx * self.tiled_map.tilewidth
            local y = (ty + 1) * self.tiled_map.tileheight - tile.tileset.tileheight

            if tile:has_solid_collision() and
                tile.tileset.tilewidth == self.tiled_map.tilewidth and
                tile.tileset.tileheight == self.tiled_map.tileheight
            then
                -- Merge candidate!  See if we're compatible
                if merged_aabb and merged_aabb.y == y and
                    merged_aabb.width < MAX_TILE_MERGE * tile.tileset.tilewidth and
                    _are_tiles_merge_compatible(tile, merged_tile)
                then
                    -- Good to go! Tack it on and keep going
                    merged_aabb.width = merged_aabb.width + tile.tileset.tilewidth
                    goto continue
                else
                    -- Incompatible, but might be compatible with the /next/
                    -- tile, so keep it for now.  This also marks the end of
                    -- the current merged row, so add it if it exists
                    reify_merged_shape()

                    merged_aabb = AABB(x, y, tile.tileset.tilewidth, tile.tileset.tileheight)
                    merged_tile = tile
                end
            else
                reify_merged_shape()

                shape = tiledmap._xxx_oneway_aware_shape_clone(shape)
                shape:move(x, y)
                self.shapes[shape] = tile
            end

            ::continue::
        end

        -- Remember to add any lingering final shape!
        reify_merged_shape()
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

    -- TODO maybe just merge this with the thing above?
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
            -- convert tile offsets to pixels
            local x = tx * tw
            local y = (ty + 1) * th - tileset.tileheight
            local batchid = batch:add(tileset.quads[tile.id], x, y)

            local animation
            if tile.tileset.raw.tiles[tile.id] then
                animation = tile.tileset.raw.tiles[tile.id].animation
            end
            if animation then
                if not self.animated_tiles[tile] then
                    local frames = {}
                    for _, framedef in ipairs(animation) do
                        table.insert(frames, {
                            quad = tile.tileset.quads[framedef.tileid],
                            duration = framedef.duration / 1000,
                        })
                    end
                    self.animated_tiles[tile] = {
                        timer = 0,
                        frame = 1,
                        frames = frames,
                    }
                end
                table.insert(self.animated_tiles[tile], {
                    batchid = batchid,
                    x = x,
                    y = y,
                })
            end
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
end

function TiledMapLayer:on_leave()
    -- Undo what we did above: remove the collisions
    if self.layer.type == 'tilelayer' and self.shapes then
        for shape in pairs(self.shapes) do
            self.map.collider:remove(shape)
        end
    end

    TiledMapLayer.__super.on_leave(self)
end

function TiledMapLayer:update(dt)
    for tile, anim in pairs(self.animated_tiles) do
        anim.timer = anim.timer + dt
        local bumped = false
        while anim.timer > anim.frames[anim.frame].duration do
            bumped = true
            anim.timer = anim.timer - anim.frames[anim.frame].duration
            anim.frame = anim.frame + 1
            if anim.frame > #anim.frames then
                anim.frame = 1
            end
        end

        if bumped then
            local batch = self.sprite_batches[tile.tileset]
            for _, tileinst in ipairs(anim) do
                batch:set(
                    tileinst.batchid,
                    anim.frames[anim.frame].quad,
                    tileinst.x,
                    tileinst.y)
            end
        end
    end
end

function TiledMapLayer:draw()
    self:_make_batches()
    for tileset, batch in pairs(self.sprite_batches) do
        love.graphics.draw(batch)
    end
end


-- FIXME parallax is kind of a mess, maybe rethink a bit
local TiledMapImage = actors_base.BareActor:extend{
    _type_name = 'TiledMapImage',
}

function TiledMapImage:init(layer, z)
    self.image = layer.image
    -- FIXME this isn't used and also it's not super clear how it'd jive with parallax
    self.offset = Vector(layer.offsetx, layer.offsety)
    self.z = z

    -- By default, the background repeats horizontally if this is a parallax
    -- layer, which is indicated by the presence of this prop
    -- TODO probably could use better twiddles here
    self.repeat_x = layer:prop('parallax anchor y') ~= nil

    -- Gather parallax properties, if available
    self.anchor_y = layer:prop('parallax anchor y') or 0
    self.rate_x = layer:prop('parallax rate x') or 0
    self.rate_y = layer:prop('parallax rate y') or 0
    -- TODO this seems like it would be fine for non-parallax cases too
    self.scale = layer:prop('parallax scale') or 1

    local iw, ih = self.image:getDimensions()
    self.image_width = iw * self.scale
    self.image_height = ih * self.scale
end

function TiledMapImage:draw()
    -- TODO these do seem a LITTLE invasive
    local camera = self.map.world.camera
    local mh = self.map.tiled_map.height

    -- TODO it would be nice to have explicit pixel limits on how far
    -- apart the pieces can go, but this was complicated enough, so
    -- TODO probably comment and variableize this better
    local iw = self.image_width
    local ih = self.image_height
    local x0 = camera.x * self.rate_x
    local y_amount = 0
    if mh > camera.height then
        y_amount = camera.y / (mh - camera.height)
    end
    local y_camera_offset = self.rate_y * (y_amount - self.anchor_y)
    local y = (mh - ih) * self.anchor_y + (mh - camera.height) * y_camera_offset

    -- x0 is the offset from the left edge of the map; find the
    -- rightmost x position before the camera area
    local x1 = x0 + math.floor((camera.x - x0) / iw) * iw
    -- TODO this ignores the layer's own offsets?  do they make sense here?
    for x = x1, x1 + camera.width + iw, iw do
        love.graphics.draw(self.image, x, y, 0, self.scale)
    end
end


return {
    TiledMapLayer = TiledMapLayer,
    TiledMapImage = TiledMapImage,
}
