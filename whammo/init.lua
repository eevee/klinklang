local Object = require 'klinklang.object'
local Blockmap = require 'klinklang.whammo.blockmap'


local PRECISION = 1e-8


local Collider = Object:extend{
    _NOTHING = {},
}

function Collider:init(blocksize)
    -- Weak map of shapes to their "owners", where "owner" can mean anything
    -- and is the special value _NOTHING to mean no owner
    self.shapes = setmetatable({}, {__mode = 'k'})
    self.blockmap = Blockmap(blocksize)
end

function Collider:add(shape, owner)
    if owner == nil then
        owner = self._NOTHING
    end
    self.blockmap:add(shape)
    self.shapes[shape] = owner
end

function Collider:remove(shape)
    if self.shapes[shape] ~= nil then
        self.blockmap:remove(shape)
        self.shapes[shape] = nil
    end
end

function Collider:get_owner(shape)
    local owner = self.shapes[shape]
    if owner == self._NOTHING then
        owner = nil
    end
    return owner
end


-- Sort collisions in the order we come into contact with them
-- FIXME can this be made deterministic in the case of ties?  order added to the collider, maybe?
local function _collision_sort(a, b)
    if a.contact_start == b.contact_start then
        -- In the case of a tie, prefer overlaps first, since we're "more"
        -- touching them
        return a.overlapped and not b.overlapped
    end
    return a.contact_start < b.contact_start
end

-- Perform sweep/continuous collision detection: attempt to move the given
-- shape the given distance, and return everything it would hit, in order.
-- If a callback is provided, it'll be called with each collision in order; if
-- it returns falsey, the shape won't try to move any further.  The return
-- value is available on the returned Collisions as 'passable'.
-- The callback may also return one of two special strings:
-- - "retry" means the callback altered the other shape in some way, and this
--   specific collision should be retried.  This is useful for e.g. pushable
--   objects.  A returned Collision should never have this as its 'passable',
--   since the retried collision will replace it.
-- - "slide" means the other object is considered solid, but doesn't block this
--   one because the movement is a slide.  This function has no special
--   handling for "slide" (treating it simply as true), but it's used in
--   Collision:slide_along_normals() and may be helpful in game code.
-- Note that if no callback is provided, the default behavior is to assume
-- nothing is blocking!  Also note that if the callback returns false, but the
-- movement is a slide, the value 'slide' is used instead.
-- Returns the successful movement and a table mapping encountered shapes to
-- the resulting Collision.
function Collider:sweep(shape, attempted, pass_callback)
    if shape == nil then
        error("Can't sweep a nil shape")
    end
    if not pass_callback then
        pass_callback = function() return true end
    end

    local collisions = {}
    local neighbors = self.blockmap:neighbors(shape, attempted:unpack())
    for neighbor in pairs(neighbors) do
        if neighbor.subshapes then
            -- This is a MultiShape!  Split it up into its component shapes.
            -- FIXME this has some goofass side effects like owner not working,
            -- but that's fine until i can nuke this crap once and for all
            for _, subshape in ipairs(neighbor.subshapes) do
                local collision = shape:sweep_towards(subshape, attempted)
                if collision then
                    table.insert(collisions, collision)
                end
            end
        else
            local collision = shape:sweep_towards(neighbor, attempted)
            if collision then
                table.insert(collisions, collision)
            end
        end
    end

    -- Look through the objects we'll hit, in the order we'll /touch/ them, and
    -- stop at the first that blocks us
    table.sort(collisions, _collision_sort)
    local allowed_fraction
    local seen = {}
    local hits = {}
    local our_owner = self:get_owner(shape)
    for i, collision in ipairs(collisions) do
        -- Put owners on the collision, so they're available to the callback
        collision.our_owner = our_owner
        collision.their_owner = self:get_owner(collision.their_shape)

        -- If we've already hit something, and this collision is further away,
        -- stop here.  (This means we call the callback for ALL of a set of
        -- shapes the same distance away, even if the first one blocks us.)
        if allowed_fraction ~= nil and allowed_fraction < collision.contact_start then
            break
        end

        -- Check if the other shape actually blocks us
        local passable = pass_callback(collision)
        if passable == 'retry' then
            -- Special case: the other object just moved, so keep moving
            -- and re-evaluate when we hit it again.  Useful for pushing.
            if i > 1 and collisions[i - 1].their_shape == collision.their_shape then
                -- To avoid loops, don't retry a shape twice in a row
                passable = false
            else
                local new_collision = shape:sweep_towards(collision.their_shape, attempted)
                if new_collision then
                    for j = i + 1, #collisions + 1 do
                        if j > #collisions or not _collision_sort(collisions[j], new_collision) then
                            table.insert(collisions, j, new_collision)
                            break
                        end
                    end
                end
            end
        end
        -- Special case, important for slide_along_normals and other cases: if
        -- the object is solid but this is a slide, it's still passable
        if not passable and collision.contact_type == 0 then
            passable = 'slide'
        end
        collision.passable = passable

        -- If we're hitting the object and it's not passable, mark this as the
        -- furthest we can go, and we'll stop when we see something further
        if not passable then
            -- Overlaps report a negative start, but we're already at zero, so
            allowed_fraction = math.max(0, collision.contact_start)
        end

        -- Log contacts in the order we encounter them
        -- FIXME should this use owner instead?  should we just return collisions instead of building a new list?
        if seen[collision.their_shape] == nil then
            seen[collision.their_shape] = true
            table.insert(hits, collision)
        end
    end

    local successful
    if allowed_fraction == nil or allowed_fraction >= 1 then
        -- Nothing stands in our way, so allow the full movement
        successful = attempted
        allowed_fraction = 1
    else
        successful = attempted * allowed_fraction
    end

    -- Tell all the collisions about the movement results
    -- TODO maybe this belongs on a "set of collisions" type?
    for _, collision in ipairs(hits) do
        collision.successful = successful
        collision.success_fraction = allowed_fraction

        -- Mark whether we're still touching the thing
        if math.abs(allowed_fraction - collision.contact_start) < PRECISION or
            math.abs(allowed_fraction - collision.contact_end) < PRECISION
        then
            -- Exactly at contact_start/end means we should be touching
            collision.success_state = 0
        elseif allowed_fraction < collision.contact_start or
            allowed_fraction > collision.contact_end
        then
            -- Outside the contact range, we're not touching any more
            collision.success_state = 1
        else
            -- Otherwise, we're in the middle, which means we're overlapping...
            -- unless this is a slide
            if not collision.overlapped and collision.contact_type == 0 then
                collision.success_state = 0
            else
                collision.success_state = -1
            end
        end
    end

    return successful, hits
end

function Collider:slide(...)
    print("warning: Collider:slide is now Collider:sweep")
    return self:sweep(...)
end

-- Fires a ray from the given point in the given direction.  Each candidate
-- shape is passed to the filter callback (not necessarily in order!), which
-- returns true to continue examining the shape or false to skip it.
-- Distance may be a cap on how far the ray can travel, given in multiples of
-- the direction vector, NOT in units!  (Of course, if direction is a unit
-- vector, these are equivalent.)  It may also be nil.  Note that objects
-- passed to the filter callback may be outside the desired range, since the
-- filter callback is used to skip the math that determines how far away it is!
-- Returns the nearest object hit and the closest point of contact.
-- Don't add, remove, or alter any shapes from the callback function, or the
-- results are undefined.
-- TODO maybe rename slide as cast, and use some of these ideas to early-exit
-- FIXME there are actually THREE kinds of objects of interest: ignore, return, and stop the ray!  this can't do the latter atm
function Collider:raycast(start, direction, distance, filter_func)
    -- TODO this, too, could be an iterator!  although the filter function is still nice
    if not filter_func then
        filter_func = function() return true end
    end

    local nearest_dot = math.huge
    local nearest_point = nil
    local nearest_shape = nil
    local blocks = self.blockmap:raycast(
        start.x, start.y, direction.x, direction.y)
    local seen_shapes = {}
    for _, ab in pairs(blocks) do
        -- TODO would be nice to break early when we reach a block that's
        -- definitely outside the distance range, but that's a little fiddly
        -- since the nearest corner of the block depends on the direction
        local a, b = unpack(ab)
        local block = self.blockmap:raw_block(a, b)
        for shape in pairs(block) do
            -- TODO this doesn't work so good if there's no owner!  but that should
            -- be vanishingly rare now.  maybe only occurs when hitting either a
            -- loose polygon or the edge of the map?
            if not seen_shapes[shape] and filter_func(self:get_owner(shape)) then
                local pt, dot = shape:intersection_with_ray(start, direction)
                if dot < nearest_dot then
                    nearest_dot = dot
                    nearest_point = pt
                    nearest_shape = shape
                end
            end
            seen_shapes[shape] = true
        end

        -- If the closest hit point we've seen is inside the block we just
        -- checked, then nothing can be closer, and we're done
        if nearest_point then
            local nearest_a, nearest_b = self.blockmap:to_block_units(
                nearest_point:unpack())
            if a == nearest_a and b == nearest_b then
                break
            end
        end
    end

    table.insert(game.debug_rays, {start, direction, distance, nearest_point, blocks})

    if distance then
        -- This is the dot product with the most distant acceptable point
        local maximum_dot = (start + direction * distance) * direction
        if nearest_dot > maximum_dot then
            return nil, nil
        end
    end

    return nearest_shape, nearest_point
end

return {
    Collider = Collider,
}
