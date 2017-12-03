--[[
Read a map in Tiled's JSON format.
]]

local anim8 = require 'vendor.anim8'
local Vector = require 'vendor.hump.vector'

local Object = require 'klinklang.object'
local util = require 'klinklang.util'
local whammo_shapes = require 'klinklang.whammo.shapes'
local SpriteSet = require 'klinklang.sprite'


-- TODO no idea how correct this is
-- n.b.: a is assumed to hold a /filename/, which is popped off first
local function relative_path(a, b)
    a = a:gsub("[^/]+$", "")
    while b:find("^%.%./") do
        b = b:gsub("^%.%./", "")
        a = a:gsub("[^/]+/?$", "")
    end
    if not a:find("/$") then
        a = a .. "/"
    end
    return a .. b
end


-- FIXME get this outta here lol
local function _xxx_oneway_aware_shape_clone(shape)
    local cloned = shape:clone()
    cloned._xxx_is_one_way_platform = shape._xxx_is_one_way_platform
    return cloned
end


--------------------------------------------------------------------------------
-- TiledTile
-- What a ridiculous name!

local TiledTile = Object:extend{
    _parsed_collision = false,
    _collision = nil,
}

function TiledTile:init(tileset, id)
    self.tileset = tileset
    self.id = id
end

function TiledTile:__tostring()
    return ("<TiledTile #%d from %s>"):format(self.id, self.tileset.path)
end

function TiledTile:prop(key, default)
    -- TODO what about the tilepropertytypes
    local proptable = self.tileset.raw.tileproperties
    if not proptable then
        return default
    end

    local props = proptable[self.id]
    if props == nil then
        return default
    end

    return props[key]
end

local function tiled_shape_to_whammo_shape(object)
    local shape
    if object.polygon then
        local points = {}
        for i, pt in ipairs(object.polygon) do
            -- Sometimes Tiled repeats the first point as the last point, and
            -- sometimes it does not.  Duplicate points create zero normals,
            -- which are REALLY BAD (and turn the player's position into nan),
            -- so strip them out
            local j = i + 1
            if j > #object.polygon then
                j = 1
            end
            local nextpt = object.polygon[j]
            if pt.x ~= nextpt.x or pt.y ~= nextpt.y then
                table.insert(points, pt.x + object.x)
                table.insert(points, pt.y + object.y)
            end
        end
        -- FIXME really this should be in Polygon, somehow?
        -- FIXME also MultiShape should avoid nesting.  but MultiShape should do a lot of things
        if love.math.isConvex(points) then
            shape = whammo_shapes.Polygon(unpack(points))
        else
            shape = whammo_shapes.MultiShape()
            for _, triangle in ipairs(love.math.triangulate(points)) do
                shape:add_subshape(whammo_shapes.Polygon(unpack(triangle)))
            end
        end
    else
        -- TODO do the others, once whammo supports them
        shape = whammo_shapes.Box(
            object.x, object.y, object.width, object.height)
    end

    -- FIXME this is pretty bad, right?  the collision system shouldn't
    -- need to know about this?  unless it should??  (a problem atm is
    -- that it gets ignored on a subshape)
    if object.properties and object.properties['one-way platform'] then
        shape._xxx_is_one_way_platform = true
    end

    return shape
end

-- Returns the collision shape.  Does NOT take the anchor into account; that's
-- the caller's problem.  Note also that this returns the same shape object on
-- every call, so you should clone it if you plan to modify it.
function TiledTile:get_collision()
    if self._parsed_collision then
        return self._collision
    end
    self._parsed_collision = true

    -- Shortcut for a totally solid tile
    if self:prop('solid') then
        self._collision = whammo_shapes.Box(
            0, 0, self.tileset.tilewidth, self.tileset.tileheight)
        -- FIXME this is slightly inconsistent with the way it works with shapes?
        if self:prop('one-way platform') then
            self._collision._xxx_is_one_way_platform = true
        end
        return self._collision
    end

    local objects
    if self.tileset.raw.tiles then
        local tiledata = self.tileset.raw.tiles[self.id]
        if tiledata and tiledata.objectgroup then
            objects = tiledata.objectgroup.objects
        end
    end
    if not objects then
        return
    end

    local shape
    for _, obj in ipairs(objects) do
        if obj.type == "anchor" then
            -- known but not relevant here
        elseif obj.type == "" or obj.type == "collision" then
            -- collision shape
            local new_shape = tiled_shape_to_whammo_shape(obj)

            if shape then
                if not shape:isa(whammo_shapes.MultiShape) then
                    shape = whammo_shapes.MultiShape(shape)
                end
                shape:add_subshape(new_shape)
            else
                shape = new_shape
            end
        else
            -- FIXME maybe need to return a table somehow, because i want to keep this for wire points?
            error(
                ("Don't know how to handle shape type %s on tile %s")
                :format(obj.type, self))
        end
    end

    self._collision = shape
    return shape
end

-- Finds the anchor for a tile, as given by an 'anchor' object.  Returns nil,
-- NOT a zero vector, if no anchor is found; this allows the caller to
-- distinguish between a missing anchor and an explicit origin anchor and
-- substitute another default if desired.
function TiledTile:get_anchor()
    -- TODO this is ugly and duplicated from get_collision
    local objects
    if self.tileset.raw.tiles then
        local tiledata = self.tileset.raw.tiles[self.id]
        if tiledata and tiledata.objectgroup then
            objects = tiledata.objectgroup.objects
        end
    end
    if not objects then
        return
    end

    for _, obj in ipairs(objects) do
        if obj.type == "anchor" then
            return Vector(obj.x, obj.y)
        end
    end

    return
end


--------------------------------------------------------------------------------
-- TiledTileset

local TiledTileset = Object:extend{}

function TiledTileset:init(path, data, resource_manager)
    self.path = path
    if not data then
        data = util.strict_json_decode(love.filesystem.read(path))
    end
    -- FIXME get rid of this
    self.raw = data

    -- Copy some basics
    local iw, ih = data.imagewidth, data.imageheight
    local tw, th = data.tilewidth, data.tileheight
    self.imagewidth = iw
    self.imageheight = ih
    self.tilewidth = tw
    self.tileheight = th
    self.tilecount = data.tilecount
    self.columns = data.columns

    -- Fetch the image
    local imgpath = relative_path(path, data.image)
    self.image = resource_manager:load(imgpath)

    -- Double-check the image size matches
    local aiw, aih = self.image:getDimensions()
    if iw ~= aiw or ih ~= aih then
        error((
            "Tileset at %s claims to use a %d x %d image, but the actual " ..
            "image at %s is %d x %d -- if you resized the image, open the " ..
            "tileset in Tiled, and it should offer to fix this automatically"
            ):format(path, iw, ih, imgpath, aiw, aih))
    end

    -- Create a quad for each tile
    -- NOTE: This is NOT (quite) a Lua array; it's a map from Tiled's tile ids
    -- (which start at zero) to quads
    -- FIXME create the Tile objects here and let them make their own damn quads
    self.tiles = {}
    self.quads = {}
    for relid = 0, self.tilecount - 1 do
        self.tiles[relid] = TiledTile(self, relid)

        -- TODO support spacing, margin
        local row, col = util.divmod(relid, self.columns)
        self.quads[relid] = love.graphics.newQuad(
            col * tw, row * th, tw, th, iw, ih)

        -- While we're in here: JSON necessitates that the keys for per-tile
        -- data are strings, but they're intended as numbers, so fix them up
        -- TODO surely this could be done as its own loop on the outside
        for _, key in ipairs{'tiles', 'tileproperties', 'tilepropertytypes'} do
            local tbl = data[key]
            if tbl then
                tbl[relid] = tbl["" .. relid]
                tbl["" .. relid] = nil
            end
        end
    end

    -- Read named sprites (and their animations, if appropriate)
    -- FIXME this scheme is nice, except, there's no way to use the same frame
    -- for two poses?
    -- FIXME if the same spriteset name appears in two tilesets, the latter
    -- will silently overwrite the former
    local spritesets = {}
    local default_anchors = {}
    local grid = anim8.newGrid(tw, th, iw, ih, data.margin, data.margin, data.spacing)
    for id = 0, self.tilecount - 1 do
        -- Tile IDs are keyed as strings, because JSON
        --id = "" .. id
        -- FIXME uggh
        if data.tileproperties and data.tileproperties[id] and data.tileproperties[id]['sprite name'] then
            -- Collect the frames, as a list of quads
            local args = {}
            if data.tiles and data.tiles[id] and data.tiles[id].animation then
                args.frames = {}
                args.durations = {}
                for _, animation_frame in ipairs(data.tiles[id].animation) do
                    table.insert(args.frames, self.quads[animation_frame.tileid])
                    table.insert(args.durations, animation_frame.duration / 1000)
                end
                if data.tileproperties[id]['animation stops'] then
                    args.onloop = 'pauseAtEnd'
                elseif data.tileproperties[id]['animation loops to'] then
                    local f = data.tileproperties[id]['animation loops to']
                    args.onloop = function(anim) anim:gotoFrame(f) end
                end
            else
                args.frames = {self.quads[id]}
                args.durations = 1
            end

            -- Other misc properties
            -- FIXME this is a bad name, since it doesn't have to be an animation
            if data.tileproperties[id]['animation flipped'] then
                args.flipped = true
            end
            if data.tileproperties[id]['sprite left view'] then
                args.leftwards = true
            end

            local shape = self.tiles[id]:get_collision()
            local anchor = self.tiles[id]:get_anchor()

            -- Add the above args as a pose for the sprite name (or names,
            -- separated by newlines)
            for full_sprite_name in data.tileproperties[id]['sprite name']:gmatch("[^\n]+") do
                local sprite_name, pose_name = full_sprite_name:match("^(.+)/(.+)$")
                local spriteset = spritesets[sprite_name]
                if not spriteset then
                    spriteset = SpriteSet(sprite_name, self.image)
                    spritesets[sprite_name] = spriteset
                end

                args.name = pose_name
                if shape then
                    args.shape = _xxx_oneway_aware_shape_clone(shape)
                end
                if anchor then
                    if shape then
                        args.shape:move(-anchor.x, -anchor.y)
                    end
                    if not default_anchors[sprite_name] then
                        default_anchors[sprite_name] = anchor
                    end
                    args.anchor = anchor
                else
                    args.anchor = default_anchors[sprite_name] or Vector()
                end

                spriteset:add_pose(args)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- TiledMapLayer
-- Thin wrapper around a Tiled JSON layer.
-- TODO this direly needs a bit more of an api, but not sure what it would be

local TiledMapLayer = Object:extend{
    offsetx = 0,
    offsety = 0,
}

function TiledMapLayer:init(name, width, height)
    self.name = name
    self.width = width
    self.height = height

    self.type = 'tilelayer'

    self.objects = {}
    self.properties = {}
end

function TiledMapLayer.parse_json(class, data, resource_manager, base_path, tiles_by_gid)
    local self = class(data.name, data.width, data.height)

    -- XXX i only support these for images atm, but i /think/ they work for tiles as well...?
    self.offsetx = data.offsetx or 0
    self.offsety = data.offsety or 0

    self.type = data.type
    if self.type == 'imagelayer' then
        local imgpath = relative_path(base_path, data.image)
        self.image = resource_manager:load(imgpath)
    end

    self.objects = data.objects or {}
    for _, object in ipairs(self.objects) do
        -- TODO probably convert this into...  something.  like parse the shape immediately?
        if object.gid then
            -- TODO what if the gid is bogus?
            object.tile = tiles_by_gid[object.gid]
        end
    end

    self.properties = data.properties or {}
    if data.data then
        self.tilegrid = {}
        for i, gid in ipairs(data.data) do
            -- DO NOT use nil here, since it effectively truncates the list
            self.tilegrid[i] = tiles_by_gid[gid] or false
        end
    end

    self.submap = self:prop('submap')

    return self
end

function TiledMapLayer:prop(key, default)
    local value = self.properties[key]
    if value == nil then
        return default
    end
    -- TODO this would be a good place to do type-casting based on the...  type
    return value
end

--------------------------------------------------------------------------------
-- TiledMap

-- FIXME mark private stuff...... as private
local TiledMap = Object:extend{
    player_start = nil,

    camera_margin_top = 0,
    camera_margin_bottom = 0,
    camera_margin_left = 0,
    camera_margin_right = 0,
}

function TiledMap:init(width, height, tilewidth, tileheight)
    self.width = width
    self.height = height
    self.tilewidth = tilewidth
    self.tileheight = tileheight

    self.layers = {}
    self.properties = {}

    -- TODO i can't figure out how much of this should be here vs worldscene
    self.actor_templates = {}
    self.named_spots = {}
    self.music_zones = {}
    -- TODO maybe it should be possible to name arbitrary shapes
    self.named_tracks = {}
    -- Used for drawing
    self.sprite_batches = {}
end

function TiledMap.parse_json_file(class, path, resource_manager)
    local data = util.strict_json_decode(love.filesystem.read(path))

    local self = class(
        data.width * data.tilewidth, data.height * data.tileheight,
        data.tilewidth, data.tileheight
    )

    self.path = path

    -- Copy some basics
    local props = data.properties or {}
    self.camera_margin_left = props['camera margin'] or props['camera margin left'] or 0
    self.camera_margin_right = props['camera margin'] or props['camera margin right'] or 0
    self.camera_margin_top = props['camera margin'] or props['camera margin top'] or 0
    self.camera_margin_bottom = props['camera margin'] or props['camera margin bottom'] or 0
    self.properties = props

    -- Load tilesets
    self._tiles_by_gid = {}
    for _, tilesetdef in pairs(data.tilesets) do
        local tileset
        if tilesetdef.source then
            -- External tileset; load it
            local tspath = relative_path(path, tilesetdef.source)
            tileset = resource_manager:get(tspath)
            if not tileset then
                tileset = TiledTileset(tspath, nil, resource_manager)
                resource_manager:add(tspath, tileset)
            end
        else
            tileset = TiledTileset(path, tilesetdef, resource_manager)
        end

        self:add_tileset(tileset, tilesetdef.firstgid)
    end

    -- Load layers
    for _, raw_layer in ipairs(data.layers) do
        self:add_layer(TiledMapLayer:parse_json(raw_layer, resource_manager, path, self._tiles_by_gid))
    end

    return self
end

function TiledMap:add_tileset(tileset, firstgid)

    -- TODO spacing, margin
    if firstgid then
        for relid = 0, tileset.tilecount - 1 do
            -- TODO gids use the upper three bits for flips, argh!
            -- see: http://doc.mapeditor.org/reference/tmx-map-format/#data
            -- also fix below
            self._tiles_by_gid[firstgid + relid] = tileset.tiles[relid]
        end
    end
end

function TiledMap:add_layer(layer)
    table.insert(self.layers, layer)

    -- Detach any automatic actor tiles
    -- TODO this is largely copy/pasted from below
    -- FIXME i think these are deprecated for layers maybe?
    local width, height = layer.width, layer.height
    if layer.type == 'tilelayer' then
        for t, tile in ipairs(layer.tilegrid) do
            if tile then
                local class = tile:prop('actor')
                if class then
                    local ty, tx = util.divmod(t - 1, width)
                    table.insert(self.actor_templates, {
                        name = class,
                        submap = layer.submap,
                        position = Vector(
                            tx * self.tilewidth,
                            (ty + 1) * self.tileheight - tile.tileset.tileheight),
                    })
                    layer.tilegrid[t] = false
                end
            end
        end
    elseif layer.type == 'objectgroup' then
        for _, object in ipairs(layer.objects) do
            if object.tile then
                -- This is a "tile" object
                local class = object.tile:prop('actor')
                if class then
                    table.insert(self.actor_templates, {
                        name = class,
                        submap = layer.submap,
                        position = Vector(object.x, object.y - object.tile.tileset.tileheight),
                        properties = object.properties,
                    })
                end
            -- FIXME this should probably be the default case rather than one more exception
            elseif object.type == 'trigger' or object.type == 'ladder' or object.type == 'water zone' or object.type == 'map slice' then
                table.insert(self.actor_templates, {
                    name = object.type,
                    submap = layer.submap,
                    position = Vector(object.x, object.y),
                    properties = object.properties,
                    shape = tiled_shape_to_whammo_shape(object),
                })
            elseif object.type == 'player start' then
                self.player_start = Vector(object.x, object.y)
            elseif object.type == 'spot' then
                local point = Vector(object.x, object.y)
                self.named_spots[object.name] = point
                if not self.player_start then
                    self.player_start = point
                end
            elseif object.type == 'music zone' then
                local shape = tiled_shape_to_whammo_shape(object)
                self.music_zones[shape] = resource_manager:load(object.properties.music)
            elseif object.type == 'track' then
                local points = {}
                for _, rawpoint in ipairs(object.polyline) do
                    table.insert(points, Vector(object.x + rawpoint.x, object.y + rawpoint.y))
                end
                self.named_tracks[object.name] = points
            end
        end
    end
end

function TiledMap:prop(key, default)
    local value = self.properties[key]
    if value == nil then
        return default
    end
    -- TODO this would be a good place to do type-casting based on the...  type
    return value
end

function TiledMap:add_to_collider(collider, submap_name)
    -- TODO injecting like this seems...  wrong?  also keeping references to
    -- the collision shapes /here/?  this object should be a dumb wrapper and
    -- not have any state i think.  maybe return a structure of shapes?
    -- or, alternatively, create shapes on the fly from the blockmap...?
    -- FIXME ok so also we have to do a lot of stupid garbage here to avoid
    -- keep duplicate copies of the entire collision around just because we
    -- were loaded a second time
    if not self.shapes then
        self.shapes = {}
    end

    -- Add borders around the map itself, so nothing can leave it
    if not self.shapes.border then
        local margin = 16
        self.shapes.border = {
            -- Top
            whammo_shapes.Box(0, -margin, self.width, margin),
            -- Bottom
            whammo_shapes.Box(0, self.height, self.width, margin),
            -- Left
            whammo_shapes.Box(-margin, 0, margin, self.height),
            -- Right
            whammo_shapes.Box(self.width, 0, margin, self.height),
        }
    end
    for _, border in ipairs(self.shapes.border) do
        collider:add(border)
    end

    for _, layer in ipairs(self.layers) do
        if layer:prop('exclude from collision') then
            -- Skip
        elseif layer.type == 'tilelayer' and layer.submap == submap_name then
            local width, height = layer.width, layer.height
            local data = layer.data
            if not self.shapes[layer] then
                self.shapes[layer] = {}
                for t, tile in ipairs(layer.tilegrid) do
                    if tile then
                        local shape = tile:get_collision()
                        if shape then
                            local ty, tx = util.divmod(t - 1, width)
                            shape = _xxx_oneway_aware_shape_clone(shape)
                            shape:move(
                                tx * self.tilewidth,
                                (ty + 1) * self.tileheight - tile.tileset.tileheight)
                            self.shapes[layer][shape] = tile
                        end
                    end
                end
            end
            for shape, tile in pairs(self.shapes[layer]) do
                collider:add(shape, tile)
            end
        elseif layer.type == 'objectgroup' and layer.submap == submap_name then
            for _, obj in ipairs(layer.objects) do
                if self.shapes[obj] then
                    collider:add(self.shapes[obj])
                elseif obj.type == 'collision' then
                    local shape = tiled_shape_to_whammo_shape(obj)
                    self.shapes[obj] = shape
                    collider:add(shape)
                end
            end
        end
    end
end

-- Draw the whole map
function TiledMap:draw(layer_name, submap_name, origin, width, height)
    -- TODO origin unused.  is it in tiles or pixels?
    -- TODO width and height also unused
    for _, layer in pairs(self.layers) do
        if layer.name == layer_name and layer.submap == submap_name then
            if layer.type == 'tilelayer' then
                self:draw_layer(layer)
            elseif layer.type == 'imagelayer' then
                love.graphics.draw(layer.image, layer.offsetx, layer.offsety)
            end
        end
    end
end

-- Draw a particular layer using sprite batches
function TiledMap:draw_layer(layer)
    -- NOTE: This batched approach means that the map /may not/ render
    -- correctly if an oversized tile overlaps other tiles.  But I don't do
    -- that, and it seems like a bad idea anyway, so.
    -- TODO consider benchmarking this (on a large map) against recreating a
    -- batch every frame but with only visible tiles?
    local tw, th = self.tilewidth, self.tileheight
    local batches = self.sprite_batches[layer]
    if not batches then
        batches = {}
        self.sprite_batches[layer] = batches

        local width, height = layer.width, layer.height
        local data = layer.data
        for t, tile in ipairs(layer.tilegrid) do
            if tile then
                local tileset = tile.tileset
                local batch = batches[tileset]
                if not batch then
                    batch = love.graphics.newSpriteBatch(
                        tileset.image, width * height, 'static')
                    batches[tileset] = batch
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
    for tileset, batch in pairs(batches) do
        love.graphics.draw(batch)
    end
end

function TiledMap:draw_parallax_background(camera, sw, sh)
    local mw, mh = self.width, self.height
    for _, layer in ipairs(self.layers) do
        local y_anchor = layer:prop('parallax anchor y')
        if layer.type == 'imagelayer' and y_anchor then
            -- TODO it would be nice to have explicit pixel limits on how far
            -- apart the pieces can go, but this was complicated enough, so
            local x_rate = layer:prop('parallax rate x') or 0
            local y_rate = layer:prop('parallax rate y') or 0
            local scale = layer:prop('parallax scale') or 1
            local iw, ih = layer.image:getDimensions()
            iw = iw * scale
            ih = ih * scale
            local x0 = camera.x * x_rate
            local y_amount = 0
            if mh > sh then
                y_amount = camera.y / (mh - sh)
            end
            local y_camera_offset = y_rate * (y_amount - y_anchor)
            local y = (mh - ih) * y_anchor + (mh - sh) * y_camera_offset

            -- x0 is the offset from the left edge of the map; find the
            -- rightmost x position before the camera area
            local x1 = x0 + math.floor((camera.x - x0) / iw) * iw
            -- TODO this ignores the layer's own offsets?  do they make sense here?
            for x = x1, x1 + sw + iw, iw do
                love.graphics.draw(layer.image, x, y, 0, scale)
            end
        end
    end
end


return {
    TiledMap = TiledMap,
    TiledMapLayer = TiledMapLayer,
    TiledTileset = TiledTileset,
    TiledTile = TiledTile,
    tiled_shape_to_whammo_shape = tiled_shape_to_whammo_shape,
}
