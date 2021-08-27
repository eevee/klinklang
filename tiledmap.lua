--[[
Read a map in Tiled's JSON format.
]]

local Vector = require 'klinklang.vendor.hump.vector'

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
    if a ~= "" and not a:find("/$") then
        a = a .. "/"
    end
    return a .. b
end


-- Given a Tiled /thing/ (map, layer, object...), extract its properties as a
-- regular table.  Works with both the "old" and "new" formats.  If there are
-- no properties, returns an empty table.
local function extract_properties(thing, source_path)
    if thing.properties == nil then
        return {}
    elseif thing.propertytypes == nil then
        -- New format: properties is a list of name/type/value
        local props = {}
        for _, prop in ipairs(thing.properties) do
            local value = prop.value
            if prop.type == 'file' and source_path then
                value = util.resolve_path(value, source_path, false)
            end
            props[prop.name] = value
        end
        return props
    else
        -- Old format: properties is a table, so it's usable directly
        return thing.properties
    end
end


local function tiled_shape_to_whammo_shapes(object)
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
        if love.math.isConvex(points) then
            return {whammo_shapes.Polygon(unpack(points))}
        else
            local shapes = {}
            for _, triangle in ipairs(love.math.triangulate(points)) do
                table.insert(shapes, whammo_shapes.Polygon(unpack(triangle)))
            end
            return shapes
        end
    elseif object.ellipse then
        -- Tiled stores these by their bounding boxes, which is super weird.
        -- Also, only circles are supported.
        local radius = math.min(object.width, object.height) / 2
        return {whammo_shapes.Circle(object.x + radius, object.y + radius, radius)}
    else
        -- TODO do the others, once whammo supports them
        return {whammo_shapes.Box(object.x, object.y, object.width, object.height)}
    end
end


--------------------------------------------------------------------------------
-- TiledTile
-- What a ridiculous name!

local TiledTile = Object:extend{
    -- Vector indicating the anchor for this tile, relative to its top left
    -- corner.  Remains nil, NOT a zero vector, if no anchor is defined; this
    -- allows callers to distinguish between a missing anchor and an
    -- explicit origin anchor and substitute another default if desired.
    anchor = nil,
    -- Optional list of whammo shapes associated with this tile.  May be nil if
    -- there are none!  (Otherwise we'd have thousands of empty lists for tiles
    -- not even intended to be used.)
    collision_shapes = nil,
    -- Optional mapping of shape type => list of shapes.  May be nil.
    extra_shapes = nil,
}

function TiledTile:init(tileset, id)
    self.tileset = tileset
    self.id = id

    -- Parse out interesting bits from the tile's object layer
    if self:prop('solid') then
        -- Shortcut for a totally solid tile
        self.collision_shapes = {self.tileset._solid_shape}
    end

    local objects
    local tiledata = self.tileset.rawtiledata[self.id]
    if tiledata and tiledata.objectgroup then
        objects = tiledata.objectgroup.objects
    end
    if objects then
        for _, obj in ipairs(objects) do
            if obj.type == "anchor" then
                -- anchor
                self.anchor = Vector(obj.x, obj.y)
            elseif obj.type == "" or obj.type == "collision" then
                -- collision shape
                local new_shapes = tiled_shape_to_whammo_shapes(obj)
                if self.collision_shapes == nil then
                    self.collision_shapes = new_shapes
                else
                    for _, shape in ipairs(new_shapes) do
                        table.insert(self.collision_shapes, shape)
                    end
                end
            else
                -- Some unrecognized type; game code presumably cares about it
                if not self.extra_shapes then
                    self.extra_shapes = {}
                end
                local extras = self.extra_shapes[obj.type]
                if not extras then
                    extras = {}
                    self.extra_shapes[obj.type] = extras
                end

                if obj.point then
                    table.insert(extras, Vector(obj.x, obj.y))
                else
                    -- TODO unclear what to do here, since e.g. a polygon might
                    -- be a polyline, ellipses aren't supported...
                    -- TODO apparently i once thought to use a box of type
                    -- 'grid center' to declare a 3x3 drawable, but never
                    -- implemented it; that's a good use case
                    error(
                        ("Don't know how to handle shape type %s on tile %s")
                        :format(obj.type, self))
                end
            end
        end
    end
end

function TiledTile:__tostring()
    return ("<TiledTile #%d from %s>"):format(self.id, self.tileset.path)
end

function TiledTile:prop(key, default)
    local props = self.tileset.tileprops[self.id]
    if props == nil then
        return default
    end

    return props[key]
end

function TiledTile:get_quad()
    return self.tileset.quads[self.id]
end

function TiledTile:has_solid_collision()
    if self:prop('solid') then
        return true
    end

    local tw = self.tileset.tilewidth
    local th = self.tileset.tileheight

    local shapes = self.collision_shapes
    return (
        #shapes == 1 and
        shapes[1]:isa(whammo_shapes.Box) and
        shapes[1].x0 == 0 and
        shapes[1].y0 == 0 and
        shapes[1].x1 == tw and
        shapes[1].y1 == th
    )
end


--------------------------------------------------------------------------------
-- TiledTileset

local TiledTileset = Object:extend{}

function TiledTileset:init(path, data, resource_manager)
    self.path = path
    if not data then
        data = util.strict_json_decode(util.strict_read_file(path))
    end

    -- Copy some basics
    local iw, ih = data.imagewidth, data.imageheight
    local tw, th = data.tilewidth, data.tileheight
    self.imagewidth = iw
    self.imageheight = ih
    self.tilewidth = tw
    self.tileheight = th
    self.tilecount = data.tilecount
    self.columns = data.columns
    -- Shared solid tile shape
    self._solid_shape = whammo_shapes.Box(0, 0, self.tilewidth, self.tileheight)

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

    -- Snag tile properties and animations
    self.rawtiledata = {}  -- tileid => raw data
    self.tileprops = {}  -- tileid => {name => value}
    if data.tileproperties == nil and (data.tiles == nil or #data.tiles > 0) then
        -- New format: 'properties' list in the tiles list
        for _, tiledata in pairs(data.tiles or {}) do
            self.rawtiledata[tiledata.id] = tiledata

            if tiledata.properties then
                local props = {}
                self.tileprops[tiledata.id] = props
                for _, prop in ipairs(tiledata.properties) do
                    props[prop.name] = prop.value
                end
            end
        end
    else
        -- Old format: separate dict of props, with string keys that need
        -- converting to numbers
        for tileid, tiledata in pairs(data.tiles or {}) do
            self.rawtiledata[tileid + 0] = tiledata
        end

        for t, props in pairs(data.tileproperties or {}) do
            self.tileprops[t + 0] = props
        end
    end

    -- Create a quad for each tile
    -- NOTE: This is NOT (quite) a Lua array; it's a map from Tiled's tile ids
    -- (which start at zero) to quads
    -- FIXME create the Tile objects here and let them make their own damn quads
    -- FIXME make them lazily?
    self.tiles = {}
    self.quads = {}
    for relid = 0, self.tilecount - 1 do
        self.tiles[relid] = TiledTile(self, relid)

        -- TODO support spacing, margin
        local row, col = util.divmod(relid, self.columns)
        self.quads[relid] = love.graphics.newQuad(
            col * tw, row * th, tw, th, iw, ih)
    end

    -- Read named sprites (and their animations, if appropriate)
    -- FIXME this scheme is nice, except, there's no way to use the same frame
    -- for two poses?
    -- FIXME if the same spriteset name appears in two tilesets, the latter
    -- will silently overwrite the former
    local spritesets = {}
    local default_anchors = {}
    for id = 0, self.tilecount - 1 do
        if self.tileprops[id] and self.tileprops[id]['sprite name'] then
            local args = {}

            local props = self.tileprops[id]
            local tile = self.tiles[id]
            local shapes = tile.collision_shapes
            local anchor = tile.anchor
            args.source_tile = tile

            -- Collect the frames, as a list of quads
            if self.rawtiledata[id] and self.rawtiledata[id].animation then
                args.frames = {}
                args.durations = {}
                for _, animation_frame in ipairs(self.rawtiledata[id].animation) do
                    table.insert(args.frames, self.quads[animation_frame.tileid])
                    table.insert(args.durations, animation_frame.duration / 1000)
                end
                if props['animation stops'] then
                    args.onloop = 'pauseAtEnd'
                elseif props['animation loops to'] then
                    local f = props['animation loops to']
                    args.onloop = function(anim) anim:gotoFrame(f) end
                end
            else
                args.frames = {self.quads[id]}
                args.durations = 1
            end

            -- Other misc properties
            if props['animation flipped'] then
                -- TODO deprecated
                -- TODO also where is this used exactly it seems goofy
                args.flipped = true
            end
            if props['sprite flipped'] then
                args.flipped = true
            elseif props['sprite doesn\'t flip'] then
                args.symmetrical = true
            end

            local facing = 'right'
            if props['sprite facing'] then
                facing = props['sprite facing']
            elseif props['sprite left view'] then
                -- TODO deprecated
                facing = 'left'
            end
            args.facing = facing

            -- Add the above args as a pose for the sprite name (or names,
            -- separated by newlines)
            for full_sprite_name in props['sprite name']:gmatch("[^\n]+") do
                local sprite_name, pose_name = full_sprite_name:match("^(.+)/(.+)$")
                local spriteset = spritesets[sprite_name]
                if not spriteset then
                    spriteset = SpriteSet(sprite_name, self.image)
                    spritesets[sprite_name] = spriteset
                end

                if not default_anchors[sprite_name] then
                    default_anchors[sprite_name] = {}
                end

                args.name = pose_name
                -- FIXME this is less a sprite property and more an actor property
                if shapes and #shapes > 0 then
                    if #shapes > 1 then
                        -- FIXME
                        util.warn(("%s: '%s' has multiple or convex shapes, which aren't yet supported"):format(path, full_sprite_name))
                    end
                    args.shape = shapes[1]:clone()
                end
                if anchor then
                    if args.shape then
                        args.shape:move(-anchor.x, -anchor.y)
                        -- Make this move "permanent" by erasing the offsets
                        args.shape.xoff = 0
                        args.shape.yoff = 0
                    end
                    if not default_anchors[sprite_name][facing] then
                        default_anchors[sprite_name][facing] = anchor
                    end
                    args.anchor = anchor
                else
                    args.anchor = default_anchors[sprite_name][facing] or Vector()
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

function TiledMapLayer.parse_json(class, data, resource_manager, base_path, tiles_by_gid, submap)
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
            -- TODO should use the horizontal flip flag for altering facing
            object.tile = tiles_by_gid[bit.band(object.gid, 0x1fffffff)]
        end
    end

    self.properties = extract_properties(data, base_path)

    if data.data then
        self.tilegrid = {}
        if data.compression or data.encoding then
            -- Packed string
            local blob = love.data.decompress('string', data.compression, love.data.decode('string', data.encoding, data.data))
            local p = 1
            local gid
            for i = 1, data.width * data.height do
                gid, p = love.data.unpack('<I4', blob, p)
                self.tilegrid[i] = tiles_by_gid[gid] or false
            end
        else
            for i, gid in ipairs(data.data) do
                -- DO NOT use nil here, since it effectively truncates the list
                self.tilegrid[i] = tiles_by_gid[gid] or false
            end
        end
    end

    self.submap = self:prop('submap') or submap or ''

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
end

function TiledMap.parse_json_file(class, path, resource_manager)
    local data = util.strict_json_decode(util.strict_read_file(path))

    local self = class(
        data.width * data.tilewidth, data.height * data.tileheight,
        data.tilewidth, data.tileheight
    )

    self.path = path

    -- Copy some basics
    local props = extract_properties(data, path)
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
        -- Handle group layers
        -- FIXME should this actually mean something to the loader?  (note that
        -- atm the group layer itself is not actually loaded as a layer)
        -- FIXME should store the parent/child relationships too
        -- FIXME recurse indefinitely
        local sublayers, submap
        if raw_layer.type == 'group' then
            sublayers = raw_layer.layers
            submap = raw_layer.name
            if submap == 'default' then
                submap = ''
            end
        else
            sublayers = {raw_layer}
            submap = ''
        end
        for _, raw_sublayer in ipairs(sublayers) do
            self:add_layer(TiledMapLayer:parse_json(raw_sublayer, resource_manager, path, self._tiles_by_gid, submap))
        end
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
                    local anchor = tile.anchor or Vector.zero
                    table.insert(self.actor_templates, {
                        name = class,
                        submap = layer.submap,
                        position = anchor + Vector(
                            tx * self.tilewidth,
                            (ty + 1) * self.tileheight - tile.tileset.tileheight),
                        properties = tile.tileset.tileprops[tile.id] or {},
                        tile = tile,
                    })
                    layer.tilegrid[t] = false
                end
            end
        end
    elseif layer.type == 'objectgroup' then
        for _, object in ipairs(layer.objects) do
            if object.tile then
                -- This is a "tile" object
                -- FIXME this is a mess lol, but i want it so tiles can also
                -- have options, e.g. a generic actor knows its sprite name.
                -- also should do this above too
                local props = extract_properties(object, self.path)
                for k, v in pairs(object.tile.tileset.tileprops[object.tile.id] or {}) do
                    if props[k] == nil then
                        props[k] = v
                    end
                end

                local class = props['actor']
                if class then
                    -- FIXME this is not a clone for old maps
                    local anchor = object.tile.anchor or Vector.zero
                    table.insert(self.actor_templates, {
                        id = object.id,
                        name = class,
                        submap = layer.submap,
                        position = anchor + Vector(object.x, object.y - object.tile.tileset.tileheight),
                        properties = props,
                        tile = object.tile,
                    })
                end
            elseif object.type == 'player start' then
                self.player_start = Vector(object.x, object.y)
            elseif object.type == 'spot' then
                local point = Vector(object.x, object.y)
                self.named_spots[object.name] = point
                if not self.player_start then
                    self.player_start = point
                end
            elseif object.type == 'music zone' then
                local shapes = tiled_shape_to_whammo_shapes(object)
                for _, shape in ipairs(shapes) do
                    -- FIXME this is broken, resource_manager isn't down here
                    self.music_zones[shape] = resource_manager:load(object.properties.music)
                end
            elseif object.type == 'track' then
                local points = {}
                for _, rawpoint in ipairs(object.polyline) do
                    table.insert(points, Vector(object.x + rawpoint.x, object.y + rawpoint.y))
                end
                self.named_tracks[object.name] = points
            elseif object.type ~= '' and object.type ~= 'collision' then
                table.insert(self.actor_templates, {
                    id = object.id,
                    name = object.type,
                    submap = layer.submap,
                    position = Vector(object.x, object.y),
                    properties = extract_properties(object, self.path),
                    shapes = tiled_shape_to_whammo_shapes(object),
                    tile = nil,
                })
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

-- Draw the whole map
function TiledMap:draw(layer_name, submap_name, origin, width, height)
    -- TODO origin unused.  is it in tiles or pixels?
    -- TODO width and height also unused
    for _, layer in pairs(self.layers) do
        if layer.name == layer_name and layer.submap == submap_name then
            if layer.type == 'imagelayer' then
                love.graphics.draw(layer.image, layer.offsetx, layer.offsety)
            end
        end
    end
end


return {
    TiledMap = TiledMap,
    TiledMapLayer = TiledMapLayer,
    TiledTileset = TiledTileset,
    TiledTile = TiledTile,
    tiled_shape_to_whammo_shapes = tiled_shape_to_whammo_shapes,
    extract_properties = extract_properties,
}
