--[[
Implementations of various collision shapes and geometric methods on them.
This is where the magic happens.
]]

local Vector = require 'klinklang.vendor.hump.vector'

local Object = require 'klinklang.object'
local Collision = require 'klinklang.whammo.collision'

-- Allowed rounding error when comparing whether two shapes are overlapping.
-- If they overlap by only this amount, they'll be considered touching.
local PRECISION = 1e-8

-- Aggressively de-dupe these extremely common normals
local XPOS = Vector(1, 0)
local XNEG = Vector(-1, 0)
local YPOS = Vector(0, 1)
local YNEG = Vector(0, -1)


-- Base class for collision shapes.  Note that shapes remember their origin,
-- the point that was 0, 0 when they were initially defined, even as they're
-- moved around; games can use this point as e.g. a position anchor.
-- TODO the origin is actually not very well handled atm
local Shape = Object:extend{
    -- Current position of the origin
    xoff = 0,
    yoff = 0,
}

function Shape:init()
    self.blockmaps = setmetatable({}, {__mode = 'k'})
end

function Shape:__tostring()
    return "<Shape>"
end

-- Return a copy of this shape.
-- Must be implemented in subtypes!
function Shape:clone()
    error("clone not implemented")
end


-- Blockmap API
-- No need to override these.

-- Remember that I'm part of the given Blockmap.
function Shape:remember_blockmap(blockmap)
    self.blockmaps[blockmap] = true
end

-- Forget that I'm part of the given Blockmap.
function Shape:forget_blockmap(blockmap)
    self.blockmaps[blockmap] = nil
end

-- Update my position in each Blockmap I'm part of.
function Shape:update_blockmaps()
    for blockmap in pairs(self.blockmaps) do
        blockmap:update(self)
    end
end


-- Geometry API

-- Return our bounding box as x0, x1, y0, y1.
-- Must be overridden in subtypes!
function Shape:bbox()
    error("bbox not implemented")
end

-- Return a bbox extended along a movement vector, i.e. to enclose all space it
-- might possibly cross along the way.
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

-- Return the center of this shape as x, y.
-- Not (currently?) guaranteed to be exact; the default implementation, which
-- is fine, returns the center of the bounding box.
function Shape:center()
    local x0, y0, x1, y1 = self:bbox()
    return (x0 + x1) / 2, (y0 + y1) / 2
end


-- Mutation API

-- Return a new shape that's been flipped horizontally, across its origin.
function Shape:flipx(axis)
    error("flipx not implemented")
end

-- Move this shape by some amount.
-- Must be implemented in subtypes, must keep xoff/yoff updated, and MUST call
-- update_blockmaps!
-- FIXME unclear whether this is supposed to physically move the original
-- coordinates or remember them as an offset or what
function Shape:move(dx, dy)
    error("move not implemented")
end

-- Move this shape's origin to an absolute position.
-- Default implementation converts the position to relative and calls move().
function Shape:move_to(x, y)
    self:move(x - self.xoff, y - self.yoff)
end


-- Collision API

-- Return a table of this shape's normals, where the keys are the original
-- normal Vectors (hopefully with nice numbers) and the values are unit
-- Vectors.  For pathological cases (like Circle), the other shape and the
-- direction of movement are also provided; in particular, movement is always
-- given as though the other shape were moving towards this one.
-- Must be implemented in subtypes!
function Shape:normals(other, movement)
    error("normals not implemented")
end

-- Given a start point and a direction (both Vectors), return the first point
-- on this shape that the ray intersects and its dot product with the ray
-- direction.
-- Must be implemented in subtypes!
-- TODO unclear what the behavior should be if the ray starts inside the shape
function Shape:intersection_with_ray(start, direction)
    error("intersection_with_ray not implemented")
end

-- Project this shape's outline onto an axis given by a Vector (which doesn't
-- have to be a unit vector), by taking the dot product of its extremes with
-- the axis, and return:
--   min_dot, max_dot, min_point, max_point
-- This is used in slide_towards along with the Separating Axis Theorem to do
-- the core of collision detection.
-- Must be implemented in subtypes!
function Shape:project_onto_axis(axis)
    error("project_onto_axis not implemented")
end

-- Attempt to slide this shape along the given movement vector towards some
-- other shape.  Return a Collision object representing the kind of collision
-- or touch that results.  Return nil if the shapes don't come into contact,
-- including if they're initially touching but then move apart.
-- This is the core of collision detection, and is called by Collider:sweep().
-- Note that the shape isn't actually moved; the movement is only simulated.
-- Must be implemented in subtypes!
function Shape:slide_towards(other, movement)
    error("slide_towards not implemented")
end

-- Given a point and a projection axis resulting from collision detection, find
-- the edge in this shape containing that point that collapses to a single
-- point on the axis, and return it as start_point, end_point.  The returned
-- points should be in clockwise order.
-- This is used by Collision to find contact regions.
-- The point passed in should be a Vector object belonging to this shape, if
-- possible.  Some shapes, like Polygon, rely on this to quickly find the
-- point.
-- Must be implemented in subtypes!
function Shape:find_edge(start_point, axis)
    error("find_edge not implemented")
end


-- Misc API

-- Draw this shape using the LÖVE graphics API.  Mode is either 'fill' or
-- 'line', as for LÖVE.
-- Generally only used for debugging, but should be implemented in subtypes.
-- Shouldn't change color or otherwise do anything weird to the draw state.
function Shape:draw(mode)
    error("draw not implemented")
end


--------------------------------------------------------------------------------
-- Polygon: An arbitrary (CONVEX) polygon

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
    -- The move normal is necessary to take into account, well, movement;
    -- otherwise there's no way for the SAT to know that a box could move
    -- diagonally /past/ another box without hitting it
    local movenormal = movement:perpendicular()
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

    -- Search for the axis that yields the greatest distance between the shapes
    -- (which must then be /the/ greatest distance between them), by projecting
    -- both shapes onto each axis in turn
    local maxamt = -math.huge
    local maxnumer, maxdenom
    local touchtype = -1
    local slide_axis
    local x_our_pt, x_their_pt, x_contact_axis
    for fullaxis, axis in pairs(axes) do
        local min1, max1, minpt1, maxpt1 = self:project_onto_axis(fullaxis)
        local min2, max2, minpt2, maxpt2 = other:project_onto_axis(fullaxis)
        -- The scalar distance between the two shapes, in fullaxis units (so
        -- not useful for comparing between iterations, but useful to compare
        -- to zero)
        local dist
        -- The closest points to the gap/overlap along this axis
        local our_point, their_point
        if min1 < min2 then
            -- 1 appears first, so take the distance from 1 to 2
            dist = min2 - max1
            our_point = maxpt1
            their_point = minpt2
            -- Flip the axes so they point towards us and become normals
            axis = -axis
            fullaxis = -fullaxis
        else
            -- Other way around
            dist = min1 - max2
            our_point = minpt1
            their_point = maxpt2
        end
        -- Vector distance between the two shapes, pointing from us to them, in
        -- world units
        local sep = their_point - our_point

        -- Ignore extremely tiny overlaps, which are likely precision errors
        if math.abs(dist) < PRECISION then
            dist = 0
        end
        if dist >= 0 then
            -- Update touchtype
            if dist > 0 then
                touchtype = 1
            elseif touchtype < 0 and dist >= 0 then
                touchtype = 0
            end

            -- This dot product is negative if we're moving closer along this
            -- axis, positive if we're moving away
            local dot = movement * fullaxis
            if math.abs(dot) < PRECISION then
                dot = 0
            end

            if dist == 0 and dot == 0 then
                -- Zero dot and zero distance mean the movement is parallel
                -- and the shapes can slide against each other.  But calling
                -- code would like to know if (and when) they're going to
                -- touch, and we need to check the other axes to find that out.
                -- FIXME what EXACTLY do we need info-wise from the other axes that we can't get here?  oh i guess the amount here comes out infinite.  maybe what i want is the same separation logic that i need for overlap?
                -- TODO or maybe i should just let the amount testing code below run no matter what, eh
                slide_axis = fullaxis
                x_our_pt = our_point
                x_their_pt = their_point
                x_contact_axis = fullaxis
            elseif dot >= 0 and dist >= 0 then
                -- The shapes are either touching and moving apart (which
                -- doesn't count as a touch), or not touching but not moving
                -- closer together.  Either way, they can't possibly collide,
                -- so stop here.
                -- FIXME if i try to move away from something but can't because
                -- i'm stuck, this won't detect the touch then?  hmm
                return
            else
                -- Figure out how much movement is allowed, as a fraction.
                -- Conceptually, the answer is the movement projected onto the
                -- axis, divided by the separation projected onto the same
                -- axis.  Stuff cancels, and it turns out to be just the ratio
                -- of dot products (which makes sense).  Vectors are neat.
                -- Note that slides are meaningless here; a shape could move
                -- perpendicular to the axis forever without hitting anything.
                local numer = -(sep * fullaxis)
                local amount = numer / math.abs(dot)
                -- TODO if movement is zero (or at least zero in this
                -- direction) then the division will give either positive or
                -- negative infinity, which makes this somewhat less useful for
                -- determining existing overlap, hm
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
                    -- If there's a slide axis, then its axis wins here
                    if not slide_axis then
                        x_our_pt = our_point
                        x_their_pt = their_point
                        x_contact_axis = fullaxis
                    end
                end

                -- FIXME rust does this code even for the move normal (which i'm not sure is necessary, and might even be bad, because the move normal would make it seem like we just hit a flat wall instead of a corner)
                if use_normal and not rawequal(fullaxis, movement) and
                    -- Ignore normals that face away from us
                    dot <= 0 and
                    -- If this is a slide then that's the only valid normal and
                    -- all this work will be ignored anyway
                    not slide_axis
                then
                    -- FIXME normals are no longer de-duplicated, hmm
                    local ourdot = movement * axis

                    -- Determine if this surface is on our left or right.
                    -- The move normal points right from us, so if this dot
                    -- product is positive, the normal also points right of
                    -- us, which means the actual surface is on our left.
                    -- (Remember, LÖVE's coordinate system points down!)
                    local right_dot = movenormal * fullaxis
                    -- TODO explain this better, but the idea is: using the greater dot means using the slope that's furthest away from us, which resolves corners nicely because two normals on one side HAVE to be a corner, they can't actually be one in front of the other
                    -- TODO should these do something on a tie?
                    if right_dot >= -PRECISION and ourdot > maxleftdot then
                        leftnorm = fullaxis
                        maxleftdot = ourdot
                    end
                    if right_dot <= PRECISION and ourdot > maxrightdot then
                        rightnorm = fullaxis
                        maxrightdot = ourdot
                    end
                end
            end
        end
    end

    if maxamt > 1 and touchtype > 0 then
        -- We're allowed to move further than the requested distance, AND we
        -- won't touch.  (Touching is handled as a "slide" below.)  Bail!
        return
    end

    if touchtype < 0 then
        -- Shapes are already overlapping, oops
        -- FIXME should have /some/ kind of gentle rejection here; should be
        -- easier now that i have touchdist
        -- FIXME should definitely return the minimum separation vector
        --error("seem to be inside something!!  stopping so you can debug buddy  <3")
        return Collision:bless{
            --movement = movement * maxnumer / maxdenom,
            --amount = maxamt,
            movement = Vector(),
            amount = 0,
            touchdist = 0,
            touchtype = -1,
            -- FIXME what do these actually mean for an overlap?  also note i
            -- think they end up not populated at all due to that `if dist >=
            -- 0` above
            left_normal = leftnorm,
            right_normal = rightnorm,
            left_normal_dot = maxleftdot,
            right_normal_dot = maxrightdot,
        }
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
        if slide_axis * movenormal > 0 then
            leftnorm = slide_axis
            maxleftdot = 0
            rightnorm = nil
            maxrightdot = -math.huge
        else
            rightnorm = slide_axis
            maxrightdot = 0
            leftnorm = nil
            maxleftdot = -math.huge
        end

        return Collision:bless{
            movement = movement,
            amount = 1,
            touchdist = touchdist,
            touchtype = 0,

            left_normal = leftnorm,
            right_normal = rightnorm,
            left_normal_dot = maxleftdot,
            right_normal_dot = maxrightdot,

            our_shape = self,
            their_shape = other,
            our_point = x_our_pt,
            their_point = x_their_pt,
            axis = slide_axis,
        }
    elseif maxamt == -math.huge then
        -- We don't hit anything at all!
        return
    end

    -- If none of the special cases apply, this is a regular old collision
    -- where we're about to run head-first into something
    return Collision:bless{
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

        our_shape = self,
        their_shape = other,
        our_point = x_our_pt,
        their_point = x_their_pt,
        axis = x_contact_axis,
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

-- Given a point BELONGING TO THE POLYGON and an axis, look for an edge
-- perpendicular to that axis and containing the given point.  Return the
-- endpoints of that edge in clockwise order.
function Polygon:find_edge(start_point, axis)
    local n
    for i, point in ipairs(self.points) do
        -- NOTE: This is very naughty, but it does a bit of magic: when the
        -- collision code returns one of our points, this will still be able to
        -- find it, even if the polygon has moved in the meantime (because
        -- movement mutates our points)!
        if rawequal(point, start_point) then
            n = i
            break
        end
    end
    if not n then
        error("Can't find an edge")
    end

    local first = start_point
    local second = start_point
    local dot = start_point * axis
    local pt
    pt = self.points[(n - 1 - 1) % #self.points + 1]
    if abs(pt * axis - dot) < PRECISION then
        first = pt
    end
    pt = self.points[(n + 1 - 1) % #self.points + 1]
    if abs(pt * axis - dot) < PRECISION then
        second = pt
    end

    return first, second
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
    return ("<Box (%.2f, %.2f) to (%.2f, %.2f)>"):format(self.x0, self.y0, self.x0 + self.width, self.y0 + self.height)
end

function Box:flipx(axis)
    return Box(axis * 2 - self.x0 - self.width, self.y0, self.width, self.height)
end

function Box:_generate_normals()
end

function Box:center()
    return self.x0 + self.width / 2, self.y0 + self.height / 2
end

function Box:project_onto_axis(axis)
    -- AABBs report the unit vectors as their axes, and if those end up here,
    -- we already know what the projection will be: it's just the x or y
    -- coordinates of our bounding boxes.
    if axis == XPOS then
        return self.x0, self.x1, self.points[1], self.points[2]
    elseif axis == YPOS then
        return self.y0, self.y1, self.points[1], self.points[4]
    else
        return Box.__super.project_onto_axis(self, axis)
    end
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
