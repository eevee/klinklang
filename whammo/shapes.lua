--[[
Implementations of various collision shapes and geometric methods on them.
This is where the magic happens.
]]

local Vector = require 'klinklang.vendor.hump.vector'

local Object = require 'klinklang.object'
local Collision = require 'klinklang.whammo.collision'


-- Make locals out of these common built-ins.  Super duper micro optimization,
-- but collision code is very hot, so I'll take what I can get!  Seems to make
-- for a very slight improvement.
local ipairs, pairs, rawequal = ipairs, pairs, rawequal
local abs = math.abs
local NEG_INFINITY = -math.huge
local POS_INFINITY = math.huge


-- Allowed rounding error when comparing whether two shapes are overlapping.
-- If they overlap by only this amount, they'll be considered touching.
local PRECISION = 1e-8

-- Return 0 if n is within PRECISION of 0, otherwise return n.
local function zero_trim(n)
    if abs(n) < PRECISION then
        return 0
    else
        return n
    end
end

-- Aggressively de-dupe these extremely common normals
local XPOS = Vector(1, 0)
local YPOS = Vector(0, 1)


-- Base class for collision shapes.  Note that shapes remember their origin,
-- the point that was 0, 0 when they were initially defined, even as they're
-- moved around; games can use this point as e.g. a position anchor.
-- TODO the origin is actually not very well handled atm
local Shape = Object:extend{
    -- Current position of the origin
    xoff = 0,
    yoff = 0,

    -- These are part of an optimization that works especially well for two
    -- Boxes; by keeping these normals out of the usual returned normals list,
    -- they only need to be checked once (even if they exist for both shapes),
    -- and they don't need to be normalized either
    has_vertical_normal = false,
    has_horizontal_normal = false,
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
    local new = self:_clone()
    new.xoff = self.xoff
    new.yoff = self.yoff
    return new
end

function Shape:_clone()
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

-- Draw this shape using the LÖVE graphics API.  Mode is either 'fill' or
-- 'line', as for LÖVE.
-- Generally only used for debugging, but should be implemented in subtypes.
-- Shouldn't change color or otherwise do anything weird to the draw state.
function Shape:draw(mode)
    error("draw not implemented")
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

-- Return a list of this shape's normals as Vectors.  For pathological cases
-- (like Circle), the other shape and the direction of movement are also
-- provided; in particular, movement is always given as though the other shape
-- were moving towards this one.
-- Note that these DO NOT need to be unit vectors, and in fact unit vectors are
-- discouraged!  Use those big ol' nice numbers; collision code will normalize
-- when necessary.
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
-- This is used in sweep_towards along with the Separating Axis Theorem to do
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
-- This method has absolutely no opinion on whether or not the other shape
-- should stop this one; it only reports the effects of the movement.  Blocking
-- is handled by arguments to Collider:sweep().
-- Note that the shape isn't actually moved; the movement is only simulated.
-- FIXME couldn't there be a much simpler version of this for two AABBs?
-- FIXME incorporate the improvements i made when porting this to rust
-- FIXME maybe write a little benchmark too
function Shape:sweep_towards(other, movement)
    -- We cannot possibly collide if the bboxes don't overlap
    local ax0, ay0, ax1, ay1 = self:extended_bbox(movement:unpack())
    local bx0, by0, bx1, by1 = other:bbox()
    if (ax1 < bx0 or bx1 < ax0) and (ay1 < by0 or by1 < ay0) then
        return
    end

    -- Use the separating axis theoreom, which essentially says that two shapes
    -- overlap iff they appear to overlap from every angle.
    -- More rigorously: using every normal of both shapes in turn as an "axis",
    -- project the shapes onto that axis, by taking the dot product of the
    -- vertices with the axis.  The result will be a segment, and if those
    -- segments overlap, the shapes overlap on that axis.  Visually, consider
    -- the projection of these two boxes onto the x/y axes:
    --
    --          +-----+ → → → → → → → → → A
    --          |  A  |       +---+       & (both)
    --          +-----+ → → → | B | → → → & (both)
    --           ↓ ↓ ↓        +---+       B
    --           ↓ ↓ ↓         ↓ ↓        .
    --      ....AAAAAAA.......BBBBB.....
    --
    -- Here, the shapes appear to overlap when projected onto the vertical axis
    -- (or, if you like, when looking at them from the left side with the
    -- vertical axis as a "wall" behind them), but they DON'T overlap on the
    -- horizontal axis, so they must not overlap!  It really is that simple,
    -- just with some vector math involved.
    -- This code gets a little fancier: it examines the SIZE of the separation
    -- between the shapes to figure out what happens when this shape moves some
    -- distance towards the other.  Instead of merely looking for ANY gap, this
    -- code looks for the BEST gap (and associated axis), where "best" means
    -- "has the greatest distance along the movement vector".
    -- One further wrinkle: if the shapes do in fact overlap, then there won't
    -- be a "best" gap, or any gap at all.  In that case, the "best axis" is
    -- the one along which the shapes overlap the LEAST:
    --          +----+
    --          | +--*----+
    --          +-*--+    |
    --            +-------+
    -- Here, the best axis is the vertical axis, where the shapes only overlap
    -- by an absolute distance of 2, versus 4 for the horizontal axis.
    -- Got all that?  Great, let's go!

    -- Collect the axes (i.e., normals) from both shapes.  As an optimization
    -- for the very common case of boxes hitting boxes, horizontal and vertical
    -- normals are specifically checked for, so they're only tried once.
    -- The move normal is necessary to take into account, well, movement;
    -- otherwise there's no way for the SAT to know that a box could move
    -- diagonally /past/ another box without hitting it.
    local fullaxes = {}
    local use_x_normal = self.has_horizontal_normal or other.has_horizontal_normal
    local use_y_normal = self.has_vertical_normal or other.has_vertical_normal
    local movenormal = movement:perpendicular()
    if movenormal == Vector.zero then
        -- Zero movement is allowed, but makes for a poor normal!
    elseif movenormal.x == 0 then
        -- Use the shared unit normals for movement too, if possible
        use_y_normal = true
    elseif movenormal.y == 0 then
        use_x_normal = true
    else
        table.insert(fullaxes, movenormal)
    end
    if use_x_normal then
        table.insert(fullaxes, XPOS)
    end
    if use_y_normal then
        table.insert(fullaxes, YPOS)
    end
    for _, normal in ipairs(self:normals(other, -movement)) do
        table.insert(fullaxes, normal)
    end
    for _, normal in ipairs(other:normals(self, movement)) do
        table.insert(fullaxes, normal)
    end

    -- Main loop: try every axis in turn and keep track of the best one found,
    -- the one that allows the freest movement.  For regular collisions, that's
    -- the axis with the greatest gap, measured as a fraction of movement
    -- vector.  For overlaps, that's the axis with the shortest absolute
    -- overlap distance.
    -- Also, track a bunch of stuff along the way.

    -- Track the fraction of movement required for the leading edge of this
    -- shape to exactly touch the other shape (closing the small gap between
    -- them, hence "inner"), and similarly the most movement required to ensure
    -- that the trailing edge of this shape passes completely out the *other
    -- side* of the other shape (hence "outer").  These do NOT include results
    -- from parallel slides, where the fractions would be inf and -inf.  (If
    -- we're trying to move parallel to an existing edge contact, this measures
    -- how far back/forward we'd have to move to make that a corner contact.)
    -- Note that for slides and overlaps, the inner fraction might be negative,
    -- indicating that we'd have to move backwards to be touching!
    local max_inner_fraction = NEG_INFINITY
    local min_outer_fraction = POS_INFINITY
    -- Greatest absolute distance between the shapes, in world units.  For
    -- overlaps, this will be negative, and also the minimum separation.
    local max_real_distance = NEG_INFINITY
    -- Tracking normals is tricky, because of literal corner cases: when a
    -- corner hits a corner, the normal is technically undefined, but game code
    -- still needs to know about it.  So track two normals, one on the left and
    -- one on the right (from the point of view of the movement vector), which
    -- is enough to describe a corner-corner collision and let game code decide
    -- how to deal with it.  Only the shallowest normal on each side is
    -- tracked, as that's the one that most restricts movement.
    local max_left_normal_dot = NEG_INFINITY
    local left_normal
    local max_right_normal_dot = NEG_INFINITY
    local right_normal
    -- Similarly, the minimum separation vectors on both sides are tracked.
    -- Mostly useful for resolving overlaps.
    local left_separation
    local right_separation
    -- This describes the type of contact that this movement will cause: -1 if
    -- the shapes move apart (only possible for existing overlaps, otherwise
    -- it's not a collision!); 0 if the shapes will slide parallel; 1 if the
    -- shapes will collide.
    local contact_type = -1
    -- If this shape is trying to slide exactly parallel to the other, this
    -- will be the contact normal of that slide.
    -- TODO i kind of want to remove this somehow.  feels like such a weird ass
    -- special case i don't know.  also what happens if they're initially
    -- touching at corners?
    local slide_axis
    -- TODO figure out what i'm doing with these
    local x_our_pt, x_their_pt, x_contact_axis
    for _, fullaxis in ipairs(fullaxes) do
        -- Much of this work is done with the original unscaled normal for
        -- precision purposes (and for getting nice numbers in debug output),
        -- but we do need a unit vector sometimes
        local axis
        if rawequal(fullaxis, XPOS) or rawequal(fullaxis, YPOS) then
            axis = fullaxis
        else
            axis = fullaxis:normalized()
        end

        -- Project both shapes onto the axis.  This returns the ends of the
        -- resulting span (which are scalar numbers, in the axis's own units),
        -- and two points on the shapes corresponding to those ends.
        -- The rest of this loop is essentially working with a number line:
        --      ....AAAAAAA..........BBBBB.....
        --      min1↑     ↑max1  min2↑   ↑max2
        local min1, max1, minpt1, maxpt1 = self:project_onto_axis(fullaxis)
        local min2, max2, minpt2, maxpt2 = other:project_onto_axis(fullaxis)
        -- The axis might point either from us to them or from them to us, but
        -- we want it pointing towards us (even if it's our axis!), to make it
        -- a collision normal.  That means B should come FIRST, with our side
        -- facing them further left, so the above example needs flipping:
        --      ....BBBBB..........AAAAAAA.....
        --      max2↑   ↑min2  max1↑     ↑min1
        -- Easy enough.  But what if A and B overlap, perhaps completely?
        --      ....BBBBBBBBBBB&&&&&&&&&&&&&BBB.....
        --      min2↑          ↑min1   max1↑  ↑max2
        -- For overlaps, this shape is moving "towards" the other if it would
        -- make the penetration worse.  In this example, moving right would put
        -- A deeper inside B, so the orientation is correct.
        -- To sort this out, compute two distances: the distance from the end
        -- of shape A to the beginning of shape B, and the distance from the
        -- end of shape B to the beginning of shape A.  In the simple separated
        -- case, the "inner" distance will be positive and the "outer" distance
        -- will be negative, so whichever is greater tells us the order.
        --      ....AAAAAAA..........BBBBB.....
        --                |→→→→→→→→→→|
        --          |←←←←←←←←←←←←←←←←←←←←|
        -- Here, A→B (inner) is positive and B→A (outer) is negative, so A
        -- comes first and the axis needs flipping.
        -- Handily, this approach still works for overlaps:
        --      ....BBBBBBBBBBB&&&&&&&&&&&&&BBB.....
        --          |←←←←←←←←←←←←←←←←←←←←←←|
        --                     |←←←←←←←←←←←←←←|
        -- Now both are negative, but the "right" distance is shorter (less
        -- negative, so larger!), so B comes first and no flip is necessary.
        -- Inner distance, and the inner points
        local inner_dist
        local our_point, their_point
        -- Vector difference of the outer points
        local outer_sep
        -- Take the left and right differences, and figure out whether to flip.
        local dist_left = zero_trim(min2 - max1)
        local dist_right = zero_trim(min1 - max2)
        if dist_left >= dist_right then
            -- This shape (1) appears first, so flip, and use the left distance
            inner_dist = dist_left
            outer_sep = maxpt2 - minpt1
            our_point = maxpt1
            their_point = minpt2
            -- Flip the axes so they point towards us and become normals
            axis = -axis
            fullaxis = -fullaxis
        else
            -- Other way around
            inner_dist = dist_right
            outer_sep = minpt2 - maxpt1
            our_point = minpt1
            their_point = maxpt2
        end
        -- Vector difference of the inner points
        local inner_sep = their_point - our_point
        -- Projection of movement onto the axis, in axis units.  This is
        -- negative if we're moving closer, positive if we're separating
        local dot = zero_trim(movement * fullaxis)

        -- If the shapes are touching but moving apart (which doesn't count as
        -- a touch), or not touching but not moving closer together, they can
        -- never collide, so stop here.
        -- Note if BOTH are zero, this is a slide, which counts as touching!
        if (dot > 0 and inner_dist == 0) or (dot >= 0 and inner_dist > 0) then
            -- FIXME if i try to move away from something but can't because
            -- i'm stuck, this won't detect the touch then?  hmm
            return
        end
        -- If we're moving towards them but won't reach them (note these are
        -- both dot products with movement, so same units), stop here.
        if dot < 0 and zero_trim(inner_dist + dot) > 0 then
            return
        end

        -- Time to track whether this axis is better than any seen so far.  The
        -- different criteria for overlaps complicate things a bit, so use some
        -- flags and do the real work last
        local is_best_axis = false      -- i.e., new >= old
        local is_new_best_axis = false  -- i.e., new > old

        -- TODO since this always exists, consider renaming slide_axis to contact_axis or something?  if it exists by the end, it's always equal to x_contact_axis, which happens iff x_contact_axis * movement == 0
        if dot == 0 then
            -- Zero dot means the movement is parallel and this shape can move
            -- infinitely far without changing their distance.  But it does
            -- touch the other shape at some point, and the other axes will
            -- reveal when that is, so we can't stop yet.
            if inner_dist == 0 then
                -- This is a touch, so the allowed movement is infinite in both
                -- directions, so this axis wins hands down.  (Overlaps have
                -- different criteria, handled below, and if inner_dist > 0, we
                -- would've early returned above.)
                is_best_axis = true
                is_new_best_axis = true
            end
        else
            -- Four cases remain: moving closer (dot < 0, inner_dist anything),
            -- or overlapping and separating (dot > 0, inner_dist < 0).

            -- Find the distance between the shapes as a fraction of movement,
            -- or in other words: what multiple of 'movement' would this shape
            -- need to make to be touching the other?  (For overlaps, this
            -- might be negative!)  Do this for both inner and outer contact.
            -- Note that while we can't divide vectors, we can dot them against
            -- a common axis and divide the results.  'inner_dist' is already
            -- 'inner_sep * fullaxis', since they came from the same
            -- projection, and 'dot' is 'movement * fullaxis'.
            -- Also, the direction is already contained in inner_dist's sign, so
            -- discard dot's sign (which can't be zero if we got here).
            local inner_fraction = zero_trim(inner_dist / abs(dot))
            -- But outer_sep might point anywhere, so trust dot's sign here.
            local outer_fraction = zero_trim(outer_sep * fullaxis / dot)
            -- Normally, this shape would be moving towards the other, or we
            -- would've early returned above.  But in the odd (overlap-only)
            -- case that the shapes are moving *apart*, movement is backwards
            -- and the order in which inner/outer contact happens is reversed,
            -- so those fractions need to be swapped
            if dot > 0 then
                inner_fraction, outer_fraction = outer_fraction, -inner_fraction
            end

            min_outer_fraction = math.min(outer_fraction, min_outer_fraction)

            -- Check whether this is the best axis so far, remembering that
            -- nothing can beat a slide axis
            if not slide_axis then
                -- Do a little handwaving to handle float precision issues
                local d = inner_fraction - max_inner_fraction
                is_new_best_axis = d > PRECISION
                is_best_axis = d > -PRECISION
            end
            max_inner_fraction = math.max(inner_fraction, max_inner_fraction)
        end

        -- Track the maximum distance between the shapes, in world units,
        -- independent of movement.  This doesn't tell us anything that the
        -- "inner fraction" doesn't...  EXCEPT for a slide, where the inner
        -- fraction is inf/nan and the max isn't updated.
        -- This is crucial for overlaps, where an axis counts as an "edge" iff
        -- it's the direction with the shortest absolute overlap (or tied).
        -- Reverse the sign, so positive means there's a gap.  Note that this
        -- is equal to -inner_dist / fullaxis:len().
        local real_distance = -zero_trim(inner_sep * axis)
        -- If this is an overlap, the criteria for "freest" axis are completely
        -- different, so explicitly overwrite any "best" decision made above
        if max_real_distance < 0 then
            local d = real_distance - max_real_distance
            is_new_best_axis = d > PRECISION
            is_best_axis = d > -PRECISION
        end
        max_real_distance = math.max(real_distance, max_real_distance)

        -- At last, if this is the best axis, update all the interesting stuff
        if is_best_axis then
            -- If this is a NEW best axis (not a tie), then everything we've
            -- found so far is bogus; throw it away
            if is_new_best_axis then
                left_normal = nil
                right_normal = nil
                left_separation = nil
                right_separation = nil
                max_left_normal_dot = NEG_INFINITY
                max_right_normal_dot = NEG_INFINITY
                contact_type = -1
                slide_axis = nil
            end

            -- If this is a slide, remember it, so a better fraction won't
            -- think it's a new best axis
            if dot == 0 then
                slide_axis = fullaxis
            end

            -- Update whether we're trying to move closer or pull apart.  (The
            -- latter can only happen with overlaps.)  In the case of a tie,
            -- moving closer trumps sliding, etc.
            if dot < 0 then
                contact_type = math.max(1, contact_type)
            elseif dot > 0 then
                contact_type = math.max(-1, contact_type)
            else
                contact_type = math.max(0, contact_type)
            end

            -- Update normals.  If it's facing away from us, it ain't a normal.
            if dot <= 0 then
                -- Update separation stuff while we're here; this is also tied
                -- to the freest actual gap, where a slide axis trumps all else
                x_our_pt = our_point
                x_their_pt = their_point
                x_contact_axis = fullaxis

                -- Determine if this surface is on our left or right using a
                -- cross product.  LÖVE's coordinate system points down, so a
                -- negative cross product means the normal points to the LEFT,
                -- which means the surface is on the RIGHT, and vice versa.
                -- FIXME this doesn't correctly assign normals when motionless and
                -- touching a corner, because the cross product comes out to zero
                -- both times...
                local cross = zero_trim(movement:cross(fullaxis))
                -- Use the normal on each side with the greatest dot product
                -- with movement, which means the one that faces the most
                -- towards us and thus restricts our movement the most
                local ourdot = movement * axis
                if cross >= 0 and ourdot > max_left_normal_dot then
                    left_normal = fullaxis
                    left_separation = inner_sep:projectOn(fullaxis)
                    max_left_normal_dot = ourdot
                end
                if cross <= 0 and ourdot > max_right_normal_dot then
                    right_normal = fullaxis
                    right_separation = inner_sep:projectOn(fullaxis)
                    max_right_normal_dot = ourdot
                end
            end
        end
    end

    -- And, we're done!
    return Collision:bless{
        -- Basic info about the requested movement
        attempted = movement,
        overlapped = max_real_distance < 0,
        our_shape = self,
        their_shape = other,

        contact_start = max_inner_fraction,
        contact_end = min_outer_fraction,
        contact_type = contact_type,
        distance = max_real_distance,

        left_normal = left_normal,
        right_normal = right_normal,
        left_separation = left_separation,
        right_separation = right_separation,
        left_normal_dot = max_left_normal_dot,
        right_normal_dot = max_right_normal_dot,

        our_point = x_our_pt,
        their_point = x_their_pt,
        axis = x_contact_axis,
    }
end

function Shape:slide_towards(...)
    print("warning: Shape:slide_towards is now Shape:sweep_towards")
    return self:sweep_towards(...)
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

function Polygon:_clone()
    -- TODO or do this ridiculous repacking (though the vectors need cloning regardless)
    return Polygon(unpack(self:to_coords()))
end

function Polygon:__tostring()
    local points = {}
    for i, point in ipairs(self.points) do
        points[i] = tostring(point)
    end
    return ("<Polygon %s>"):format(table.concat(points, ', '))
end

-- Return a flat list of this Polygon's coordinates, i.e.:
-- {x0, y0, x1, y1, x2, y2, ...}
-- Mostly used for passing to APIs like love.graphics.polygon.
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
            self.has_vertical_normal = true
        elseif normal.y == 0 then
            self.has_horizontal_normal = true
        else
            table.insert(self._normals, normal)
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

-- Note that the point passed in MUST belong to the polygon!
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
    has_vertical_normal = true,
    has_horizontal_normal = true,
    _normals = {},
}

function Box:init(x, y, width, height)
    Polygon.init(self, x, y, x + width, y, x + width, y + height, x, y + height)
    self.width = width
    self.height = height
end

function Box:_clone()
    return Box(self.x0, self.y0, self.width, self.height)
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


-- A circle.  NOT an ellipse; those are vastly more complicated!
-- FIXME arrange these impls in the right order, also implement intersection_with_ray and circle/circle collision
local Circle = Shape:extend()

function Circle:init(x, y, r)
    Circle.__super.init(self)
    self.x = x
    self.y = y
    self.radius = r
end

function Circle:__tostring()
    return ("<Circle %.2f at (%.2f, %.2f)>"):format(self.radius, self.x, self.y)
end

function Circle:_clone()
    return Circle(self.x, self.y, self.radius)
end

function Circle:bbox()
    return self.x - self.radius, self.y - self.radius, self.x + self.radius, self.y + self.radius
end

function Circle:center()
    return self.x, self.y
end

function Circle:draw(mode)
    love.graphics.circle(mode, self.x, self.y, self.radius)
end

function Circle:flipx()
    return self:clone()
end

function Circle:move(dx, dy)
    self.xoff = self.xoff + dx
    self.yoff = self.yoff + dy
    self.x = self.x + dx
    self.y = self.y + dy
    self:update_blockmaps()
end

function Circle:normals(other, movement)
    -- Getting the normals for a circle is a bit ugly, because it has an
    -- infinite number of them.  We have to use the other shape to narrow down
    -- which ones would actually matter
    local ret = {}
    if movement == Vector.zero then
        return ret
    end

    if other:isa(Polygon) then
        -- A polygon will already report all of its own normals, so the only
        -- extra ones of interest are those caused by one of its vertices
        -- colliding with us.  Unfortunately that means we have to just loop
        -- through all of their points and do a ray/circle intersection.
        local center = Vector(self.x, self.y)
        local r = self.radius
        for _, point in ipairs(other.points) do
            local offset = point - center

            -- These are the coefficients of a quadratic for a parameter t, the
            -- number of rays (movements) it would take for this point to
            -- intersect this circle.
            local a = movement:len2()
            local b = 2 * (offset * movement)
            local c = offset:len2() - r * r

            -- Quadratic formula, etc.  If the discriminant is negative, this
            -- point will never hit us.
            local discriminant = b * b - 4 * a * c
            if discriminant >= 0 then
                -- There would be two solutions, but we only want the first
                -- hit, the smaller one, where the ± resolves to -
                local t = zero_trim((-b - math.sqrt(discriminant)) / (2 * a))
                -- If t is negative, the point is already inside us, which will
                -- become obvious from the polygon's own normals
                if t >= 0 then
                    -- point + movement * t - center
                    local norm = offset + movement * t
                    table.insert(ret, norm)
                end
            end
        end
    elseif other:isa(Circle) then
        -- Call our center and radius P and r, their center Q and s, and the
        -- movement vector D.  Then we will collide at time t, where:
        --   ||P + Dt - Q|| = r + s
        -- That is, the distance between the centers is exactly the sum of the
        -- radii, which means the circles are touching.  The normal will then
        -- be P + Dt - Q.
        -- If we let O = P - Q, we have:
        -- (Ox + Dx t)² + (Oy + Dy t)² = (r + s)²
        -- Ox² + 2 Ox Dx t + Dx² t² + Oy² + 2 Oy Dy t + Dy² t² = (r + s)²
        -- (Dx² + Dy²) t² + 2(Ox Dx + Oy Dy)t + (Ox² + Oy²) - (r + s)² = 0
        -- (D⋅D) t² + 2(O⋅D)t + (O⋅O) - (r + s)² = 0
        -- Note that this ends up looking an awful lot like the code above for
        -- dealing with points, if the other circle's radius were zero.
        local offset = Vector(other.x - self.x, other.y - self.y)
        local total_radius = self.radius + other.radius
        local a = movement:len2()
        local b = 2 * (offset * movement)
        local c = offset:len2() - total_radius * total_radius

        local discriminant = b * b - 4 * a * c
        if discriminant >= 0 then
            -- TODO do we want both solutions, so we know when we'd exit too?
            local t = zero_trim((-b - math.sqrt(discriminant)) / (2 * a))
            -- If t is negative, the circles already overlap, so the overlap
            -- normal is the minimum distance between them, which is along
            -- their current centers
            if t < 0 then
                table.insert(ret, offset)
            else
                table.insert(ret, offset + movement * t)
            end
        end
    end

    return ret
end

-- FIXME implement intersection_with_ray

function Circle:project_onto_axis(axis)
    local scale = self.radius / axis:len()
    local pt0 = Vector(self.x + axis.x * scale, self.y + axis.y * scale)
    local pt1 = Vector(self.x - axis.x * scale, self.y - axis.y * scale)
    local dot0 = pt0 * axis
    local dot1 = pt1 * axis
    if dot0 < dot1 then
        return dot0, dot1, pt0, pt1
    else
        return dot1, dot0, pt1, pt0
    end
end

function Circle:find_edge(start_point, axis)
    -- Circles don't have edges, so we must touch at this one point only
    return start_point, start_point
end


return {
    Box = Box,
    Polygon = Polygon,
    Circle = Circle,
}
