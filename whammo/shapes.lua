local Vector = require 'klinklang.vendor.hump.vector'

local Object = require 'klinklang.object'
local util = require 'klinklang.util'

-- Allowed rounding error when comparing whether two shapes are overlapping.
-- If they overlap by only this amount, they'll be considered touching.
local PRECISION = 1e-8

-- Aggressively de-dupe these extremely common normals
local XPOS = Vector(1, 0)
local XNEG = Vector(-1, 0)
local YPOS = Vector(0, 1)
local YNEG = Vector(0, -1)


local Shape = Object:extend{
    xoff = 0,
    yoff = 0,
}

function Shape:init()
    self.blockmaps = setmetatable({}, {__mode = 'k'})
end

function Shape:__tostring()
    return "<Shape>"
end

function Shape:remember_blockmap(blockmap)
    self.blockmaps[blockmap] = true
end

function Shape:forget_blockmap(blockmap)
    self.blockmaps[blockmap] = nil
end

function Shape:update_blockmaps()
    for blockmap in pairs(self.blockmaps) do
        blockmap:update(self)
    end
end

-- Extend a bbox along a movement vector (to enclose all space it might cross
-- along the way)
function Shape:extended_bbox(dx, dy)
    local x0, y0, x1, y1 = self:bbox()

    dx = dx or 0
    dy = dy or 0
    if dx < 0 then
        x0 = x0 + dx
    elseif dx > 0 then
        x1 = x1 + dx
    end
    if dy < 0 then
        y0 = y0 + dy
    elseif dy > 0 then
        y1 = y1 + dy
    end

    return x0, y0, x1, y1
end

function Shape:center()
    local x0, y0, x1, y1 = self:bbox()
    return (x0 + x1) / 2, (y0 + y1) / 2
end

function Shape:flipx(axis)
    error("flipx not implemented")
end

function Shape:move(dx, dy)
    error("move not implemented")
end

function Shape:move_to(x, y)
    self:move(x - self.xoff, y - self.yoff)
end

function Shape:draw(mode)
    error("draw not implemented")
end

function Shape:normals()
    error("normals not implemented")
end


-- An arbitrary (CONVEX) polygon
local Polygon = Shape:extend()

-- FIXME i think this blindly assumes clockwise order
function Polygon:init(...)
    Shape.init(self)
    local coords = {...}
    self.points = {Vector(coords[1], coords[2])}
    self.x0 = coords[1]
    self.y0 = coords[2]
    self.x1 = coords[1]
    self.y1 = coords[2]
    for n = 1, #coords - 2, 2 do
        table.insert(self.points, Vector(coords[n + 2], coords[n + 3]))
        if coords[n + 2] < self.x0 then
            self.x0 = coords[n + 2]
        end
        if coords[n + 2] > self.x1 then
            self.x1 = coords[n + 2]
        end
        if coords[n + 3] < self.y0 then
            self.y0 = coords[n + 3]
        end
        if coords[n + 3] > self.y1 then
            self.y1 = coords[n + 3]
        end
    end
    self:_generate_normals()
end

function Polygon:clone()
    -- TODO or do this ridiculous repacking (though the vectors need cloning regardless)
    return Polygon(unpack(self:to_coords()))
end

function Polygon:__tostring()
    return "<Polygon>"
end

function Polygon:to_coords()
    local coords = {}
    for _, point in ipairs(self.points) do
        table.insert(coords, point.x)
        table.insert(coords, point.y)
    end
    return coords
end

function Polygon:flipx(axis)
    local reverse_coords = {}
    for n, point in ipairs(self.points) do
        reverse_coords[#self.points * 2 - (n * 2 - 1)] = axis * 2 - point.x
        reverse_coords[#self.points * 2 - (n * 2 - 2)] = point.y
    end
    return Polygon(unpack(reverse_coords))
end

function Polygon:_generate_normals()
    self._normals = {}
    local prev_point = self.points[#self.points]
    for _, point in ipairs(self.points) do
        -- Note that this assumes points are given clockwise
        local normal = (prev_point - point):perpendicular()
        prev_point = point

        if normal == Vector.zero then
            -- Ignore zero vectors (where did you even come from)
        elseif normal.x == 0 then
            if normal.y > 0 then
                self._normals[YPOS] = YPOS
            else
                self._normals[YNEG] = YNEG
            end
        elseif normal.y == 0 then
            if normal.x > 0 then
                self._normals[XPOS] = XPOS
            else
                self._normals[XNEG] = XNEG
            end
        else
            -- What a mouthful
            self._normals[normal] = normal:normalized()
        end
    end
end

function Polygon:bbox()
    return self.x0, self.y0, self.x1, self.y1
end

function Polygon:move(dx, dy)
    self.xoff = self.xoff + dx
    self.yoff = self.yoff + dy
    self.x0 = self.x0 + dx
    self.x1 = self.x1 + dx
    self.y0 = self.y0 + dy
    self.y1 = self.y1 + dy
    for _, point in ipairs(self.points) do
        point.x = point.x + dx
        point.y = point.y + dy
    end
    self:update_blockmaps()
end

function Polygon:center()
    -- TODO uhh
    return (self.x0 + self.x1) / 2, (self.y0 + self.y1) / 2
end

function Polygon:draw(mode)
    love.graphics.polygon(mode, self:to_coords())
end

function Polygon:normals()
    return self._normals
end

-- TODO implement this for other types
function Polygon:intersection_with_ray(start, direction)
    local perp = direction:perpendicular()
    -- TODO could save a little effort by passing these in too, maybe
    local startdot = start * direction
    local startperpdot = start * perp
    local pt0 = self.points[#self.points]
    local dot0 = pt0 * perp
    local minpt = nil
    local mindot = math.huge
    for _, point in ipairs(self.points) do
        local pt, dot
        local pt1 = point
        local dot1 = pt1 * perp
        if dot0 == dot1 then
            -- This edge is parallel to the ray.  If it's also collinear to the
            -- ray, figure out where it hits
            if dot0 == startperpdot then
                local startdot = start * direction
                local ldot0 = pt0 * direction
                local ldot1 = pt1 * direction
                if (ldot0 <= startdot and startdot <= ldot1) or
                    (ldot1 <= startdot and startdot <= ldot0)
                then
                    -- Ray starts somewhere inside this line, so the start
                    -- point must be the closest point
                    return start, 0
                elseif ldot0 < startdot and ldot1 < startdot then
                    -- Ray starts after this line and misses it entirely;
                    -- do nothing
                elseif ldot0 < ldot1 then
                    pt = pt0
                    dot = ldot0
                else
                    pt = pt1
                    dot = ldot1
                end
            end
        elseif (dot0 <= startperpdot and startperpdot <= dot1) or
            (dot1 <= startperpdot and startperpdot <= dot0)
        then
            pt = pt0 + (pt1 - pt0) * (startperpdot - dot0) / (dot1 - dot0)
            dot = pt * direction
        end
        if pt then
            if dot >= startdot and dot < mindot then
                mindot = dot
                minpt = pt
            end
        end
        pt0 = pt1
        dot0 = dot1
    end
    -- TODO i feel like this doesn't really do the right thing if the start
    -- point is inside the poly?  should it, i dunno, return the point instead,
    -- since that's the first point where the ray intersects the polygon itself
    -- rather than an edge?
    return minpt, mindot
end

function Polygon:project_onto_axis(axis)
    local minpt = self.points[1]
    local maxpt = minpt
    local min = axis * minpt
    local max = min
    for i, pt in ipairs(self.points) do
        if i > 1 then
            local dot = axis * pt
            if dot < min then
                min = dot
                minpt = pt
            elseif dot > max then
                max = dot
                maxpt = pt
            end
        end
    end
    return min, max, minpt, maxpt
end

-- If this shape were to move by a given distance, would it collide with the
-- given other shape?  If no, returns nil.  If yes, even if the two would slide
-- against each other, returns a table with the following keys:
--   movement: Movement vector, trimmed so it won't collide
--   amount: How much of the given movement can be performed before hitting the
--      other shape, from 0 to 1
--   touchdist: Like `amount`, but how much before touching the other shape,
--      which can be different when two shapes slide
--   touchtype: 1 for collision, 0 for slide, -1 for already overlapping
-- FIXME couldn't there be a much simpler version of this for two AABBs?
-- FIXME incorporate the improvements i made when porting this to rust
-- FIXME maybe write a little benchmark too
function Polygon:slide_towards(other, movement)
    -- We cannot possibly collide if the bboxes don't overlap
    local ax0, ay0, ax1, ay1 = self:extended_bbox(movement:unpack())
    local bx0, by0, bx1, by1 = other:bbox()
    if (ax1 < bx0 or bx1 < ax0) and (ay1 < by0 or by1 < ay0) then
        return
    end

    -- Use the separating axis theorem.
    -- 1. Choose a bunch of axes, generally normals of the shapes.
    -- 2. Project both shapes along each axis.
    -- 3. If the projects overlap along ANY axis, the shapes overlap.
    --    Otherwise, they don't.
    -- This code also does a couple other things.
    -- b. It uses the direction of movement as an extra axis, in order to find
    --    the minimum possible movement between the two shapes.
    -- a. It keeps values around in terms of their original vectors, rather
    --    than lengths or normalized vectors, to avoid precision loss
    --    from taking square roots.

    if other.subshapes then
        return self:_multi_slide_towards(other, movement)
    end

    -- Mapping of normal vectors (i.e. projection axes) to their normalized
    -- versions (needed for comparing the results of the projection)
    -- FIXME is the move normal actually necessary, or was it just covering up
    -- my bad math before?
    local movenormal = movement:perpendicular()
    movenormal._is_move_normal = true
    local axes = {}
    if movenormal ~= Vector.zero then
        axes[movenormal] = movenormal:normalized()
    end
    for norm, norm1 in pairs(self:normals()) do
        axes[norm] = norm1
    end
    for norm, norm1 in pairs(other:normals()) do
        axes[norm] = norm1
    end

    local maxleftdot = -math.huge
    local leftnorm
    local maxrightdot = -math.huge
    local rightnorm

    -- Project both shapes onto each axis and look for the minimum distance
    local maxamt = -math.huge
    local maxnumer, maxdenom
    local touchtype = -1
    local slide_axis
    for fullaxis, axis in pairs(axes) do
        local min1, max1, minpt1, maxpt1 = self:project_onto_axis(fullaxis)
        local min2, max2, minpt2, maxpt2 = other:project_onto_axis(fullaxis)
        local dist, sep
        if min1 < min2 then
            -- 1 appears first, so take the distance from 1 to 2
            dist = min2 - max1
            sep = minpt2 - maxpt1
        else
            -- Other way around
            dist = min1 - max2
            -- Note that sep is always the vector from us to them
            sep = maxpt2 - minpt1
            -- Likewise, flip the axis so it points towards them
            axis = -axis
            fullaxis = -fullaxis
        end
        -- Ignore extremely tiny overlaps, which are likely precision errors
        if math.abs(dist) < PRECISION then
            dist = 0
        end
        if dist >= 0 then
            -- This dot product is positive if we're moving closer along this
            -- axis, negative if we're moving away
            local dot = movement * fullaxis
            if math.abs(dot) < PRECISION then
                dot = 0
            end

            if dot < 0 or (dot == 0 and dist > 0) then
                -- Even if the shapes are already touching, they're not moving
                -- closer together, so they can't possibly collide.  Stop here.
                -- FIXME this means collision detection is not useful for finding touches
                return
            elseif dist == 0 and dot == 0 then
                -- Zero dot and zero distance mean the movement is parallel
                -- and the shapes can slide against each other.  But we still
                -- need to check other axes to know if they'll actually touch.
                slide_axis = fullaxis
                -- FIXME this is starting to seem kinda goofy?  why does this need a separate case?
            else
                -- Figure out how much movement is allowed, as a fraction.
                -- Conceptually, the answer is the movement projected onto the
                -- axis, divided by the separation projected onto the same
                -- axis.  Stuff cancels, and it turns out to be just the ratio
                -- of dot products (which makes sense).  Vectors are neat.
                -- Note that slides are meaningless here; a shape could move
                -- perpendicular to the axis forever without hitting anything.
                local numer = sep * fullaxis
                local amount = numer / dot
                if math.abs(amount) < PRECISION then
                    amount = 0
                end

                local use_normal
                -- TODO i think i could avoid this entirely by using a cross
                -- product instead?
                -- FIXME rust has this, find a failing case first:
                --if maxamt > Fixed::min_value() && (amount - maxamt).abs() < PRECISION {
                if math.abs(amount - maxamt) < PRECISION then
                    -- Equal, ish
                    use_normal = true
                elseif amount > maxamt then
                    maxamt = amount
                    maxnumer = numer
                    maxdenom = dot
                    leftnorm = nil
                    rightnorm = nil
                    maxleftdot = -math.huge
                    maxrightdot = -math.huge
                    use_normal = true
                end

                -- FIXME rust does this code even for the move normal (which i'm not sure is necessary)
                if use_normal and not fullaxis._is_move_normal then
                    -- FIXME these are no longer de-duplicated, hmm
                    local normal = -fullaxis

                    local ourdot = -(movement * axis)

                    if ourdot > 0 then
                        -- Do nothing; this normal faces away from us?
                    else
                        -- Determine if this surface is on our left or right.
                        -- The move normal points right from us, so if this dot
                        -- product is positive, the normal also points right of
                        -- us, which means the actual surface is on our left.
                        -- (Remember, LÖVE's coordinate system points down!)
                        local right_dot = movenormal * normal
                        -- TODO explain this better, but the idea is: using the greater dot means using the slope that's furthest away from us, which resolves corners nicely because two normals on one side HAVE to be a corner, they can't actually be one in front of the other
                        -- TODO should these do something on a tie?
                        if right_dot >= -PRECISION and ourdot > maxleftdot then
                            leftnorm = normal
                            maxleftdot = ourdot
                        end
                        if right_dot <= PRECISION and ourdot > maxrightdot then
                            rightnorm = normal
                            maxrightdot = ourdot
                        end
                    end
                end
            end

            -- Update touchtype
            if dist > 0 then
                touchtype = 1
            elseif touchtype < 0 then
                touchtype = 0
            end
        end
    end

    if touchtype < 0 then
        -- Shapes are already colliding
        -- FIXME should have /some/ kind of gentle rejection here; should be
        -- easier now that i have touchdist
        --error("seem to be inside something!!  stopping so you can debug buddy  <3")
        return {
            movement = Vector.zero,
            amount = 0,
            touchdist = 0,
            touchtype = -1,
            left_normal_dot = -math.huge,
            right_normal_dot = -math.huge,
        }
    elseif maxamt > 1 and touchtype > 0 then
        -- We're allowed to move further than the requested distance, AND we
        -- won't end up touching.  (Touching is handled as a slide below!)
        return
    end

    if slide_axis then
        -- This is a slide; we will touch (or are already touching) the other
        -- object, but can continue past it.  (If we wouldn't touch, amount
        -- would exceed 1, and we would've returned earlier.)
        -- touchdist is how far we can move before we touch.  If we're already
        -- touching, then the touch axis will be the max distance, the dot
        -- products above will be zero, and amount will be nonsense.  If not,
        -- amount is correct.
        local touchdist = maxamt
        if touchtype == 1 then
            touchdist = 0
        end
        -- Since we're touching, the slide axis is the only valid normal!  Any
        -- others were near misses that didn't actually collide
        if slide_axis * movenormal < 0 then
            leftnorm = -slide_axis
            maxleftdot = 0
            rightnorm = nil
            maxrightdot = -math.huge
        else
            rightnorm = -slide_axis
            maxrightdot = 0
            leftnorm = nil
            maxleftdot = -math.huge
        end

        return {
            movement = movement,
            amount = 1,
            touchdist = touchdist,
            touchtype = 0,

            _slide = true,
            left_normal = leftnorm,
            right_normal = rightnorm,
            left_normal_dot = maxleftdot,
            right_normal_dot = maxrightdot,
        }
    elseif maxamt == -math.huge then
        -- We don't hit anything at all!
        return
    end

    return {
        -- Minimize rounding error by repeating the same division we used to
        -- get amount, but multiplying first
        movement = movement * maxnumer / maxdenom,
        amount = maxamt,
        touchdist = maxamt,
        touchtype = 1,

        left_normal = leftnorm,
        right_normal = rightnorm,
        left_normal_dot = maxleftdot,
        right_normal_dot = maxrightdot,
    }
end

function Polygon:_multi_slide_towards(other, movement)
    local ret
    for _, subshape in ipairs(other.subshapes) do
        local collision = self:slide_towards(subshape, movement)
        if collision == nil then
            -- Do nothing
        elseif ret == nil then
            -- First result; just accept it
            ret = collision
        else
            -- Need to combine
            if collision.amount < ret.amount then
                ret = collision
            elseif collision.amount == ret.amount then
                ret.touchdist = math.min(ret.touchdist, collision.touchdist)
                if ret.touchtype == 0 then
                    ret.touchtype = collision.touchtype
                end
                if collision.left_normal_dot > ret.left_normal_dot then
                    ret.left_normal_dot = collision.left_normal_dot
                    ret.left_normal = collision.left_normal
                end
                if collision.right_normal_dot > ret.right_normal_dot then
                    ret.right_normal_dot = collision.right_normal_dot
                    ret.right_normal = collision.right_normal
                end
            end
        end
    end

    return ret
end


-- An AABB, i.e., an unrotated rectangle
local Box = Polygon:extend{
    -- Handily, an AABB only has two normals: the x and y axes
    _normals = { [XPOS] = XPOS, [YPOS] = YPOS },
}

function Box:init(x, y, width, height, _xoff, _yoff)
    Polygon.init(self, x, y, x + width, y, x + width, y + height, x, y + height)
    self.width = width
    self.height = height
    self.xoff = _xoff or 0
    self.yoff = _yoff or 0
end

function Box:clone()
    -- FIXME i don't think most shapes clone xoff/yoff correctly, oops...  ARGH this breaks something though
    return Box(self.x0, self.y0, self.width, self.height)
    --return Box(self.x0, self.y0, self.width, self.height, self.xoff, self.yoff)
end

function Box:__tostring()
    return "<Box>"
end

function Box:flipx(axis)
    return Box(axis * 2 - self.x0 - self.width, self.y0, self.width, self.height)
end

function Box:_generate_normals()
end

function Box:center()
    return self.x0 + self.width / 2, self.y0 + self.height / 2
end


local MultiShape = Shape:extend()

function MultiShape:init(...)
    MultiShape.__super.init(self)

    self.subshapes = {}
    for _, subshape in ipairs{...} do
        self:add_subshape(subshape)
    end
end

function MultiShape:__tostring()
    return "<MultiShape>"
end

function MultiShape:add_subshape(subshape)
    -- TODO what if subshape has an offset already?
    table.insert(self.subshapes, subshape)
    self:update_blockmaps()
end

function MultiShape:clone()
    local subclones = {}
    for i, subshape in pairs(self.subshapes) do
        subclones[i] = subshape:clone()
    end
    return MultiShape(unpack(subclones))
end

function MultiShape:bbox()
    local x0, x1 = math.huge, -math.huge
    local y0, y1 = math.huge, -math.huge
    for _, subshape in ipairs(self.subshapes) do
        local subx0, suby0, subx1, suby1 = subshape:bbox()
        x0 = math.min(x0, subx0)
        y0 = math.min(y0, suby0)
        x1 = math.max(x1, subx1)
        y1 = math.max(y1, suby1)
    end
    return x0, y0, x1, y1
end

function MultiShape:flipx(axis)
    local flipped = {}
    for i, subshape in ipairs(self.subshapes) do
        flipped[i] = subshape:flipx(axis)
    end
    return MultiShape(unpack(flipped))
end

function MultiShape:move(dx, dy)
    self.xoff = self.xoff + dx
    self.yoff = self.yoff + dy
    for _, subshape in ipairs(self.subshapes) do
        subshape:move(dx, dy)
    end
    self:update_blockmaps()
end

function MultiShape:draw(...)
    for _, subshape in ipairs(self.subshapes) do
        subshape:draw(...)
    end
end

function MultiShape:normals()
    local normals = {}
    -- TODO maybe want to compute this only once
    for _, subshape in ipairs(self.subshapes) do
        for k, v in pairs(subshape:normals()) do
            normals[k] = v
        end
    end
    return normals
end

function MultiShape:project_onto_axis(...)
    local min, max, minpt, maxpt
    for i, subshape in ipairs(self.subshapes) do
        if i == 1 then
            min, max, minpt, maxpt = subshape:project_onto_axis(...)
        else
            local min2, max2, minpt2, maxpt2 = subshape:project_onto_axis(...)
            if min2 < min then
                min = min2
                minpt = minpt2
            end
            if max2 > max then
                max = max2
                maxpt = maxpt2
            end
        end
    end
    return min, max, minpt, maxpt
end

function MultiShape:intersection_with_ray(...)
    local minpt, mindot
    for i, subshape in ipairs(self.subshapes) do
        if i == 1 then
            minpt, mindot = subshape:intersection_with_ray(...)
        else
            local minpt2, mindot2 = subshape:intersection_with_ray(...)
            if mindot2 < mindot then
                minpt, mindot = minpt2, mindot2
            end
        end
    end
    return minpt, mindot
end


return {
    Box = Box,
    MultiShape = MultiShape,
    Polygon = Polygon,
}
