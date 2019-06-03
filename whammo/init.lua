local Object = require 'klinklang.object'
local Blockmap = require 'klinklang.whammo.blockmap'

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
        return a.overlaps and not b.overlaps
    end
    return a.contact_start < b.contact_start
end

-- Perform sweep/continuous collision detection: attempt to move the given
-- shape the given distance, and return everything it would hit, in order.  If
-- the callback is provided, it'll be called with each collision in order; if
-- it returns falsey, the shape won't try to move any further.
-- Note that if no callback is provided, the default behavior is to assume
-- nothing is blocking!  Also note that the callback is allowed to block even
-- in the case of a slide; this function has absolutely no special cases.
-- Returns the successful movement and a table mapping encountered shapes to
-- the resulting Collision.
function Collider:sweep(shape, attempted, pass_callback)
    if shape == nil then
        error("Can't sweep a nil shape")
    end
    if not pass_callback then
        pass_callback = function() return true end
    end

    local hits = {}
    local collisions = {}
    local neighbors = self.blockmap:neighbors(shape, attempted:unpack())
    for neighbor in pairs(neighbors) do
        local collision = shape:sweep_towards(neighbor, attempted)
        if collision then
            --print(("< got move %f = %s, touchtype %d, clock %s"):format(collision.contact_start, collision.movement, collision.touchtype, collision.clock))
            table.insert(collisions, collision)
        end
    end

    --print('-- SWEEP --', self:get_owner(shape), attempted)
    -- Look through the objects we'll hit, in the order we'll /touch/ them, and
    -- stop at the first that blocks us
    table.sort(collisions, _collision_sort)
    local allowed_fraction
    for i, collision in ipairs(collisions) do
        -- TODO add owners in here too so i don't have to keep fetching actors

        --print("checking collision...", collision.movement, collision.contact_start, collision.touchtype, collision.touchdist, "at", collision.their_shape:bbox())
        -- If we've already hit something, and this collision is further away,
        -- stop here.  (This means we call the callback for ALL of a set of
        -- shapes the same distance away, even if the first one blocks us.)
        if allowed_fraction ~= nil and allowed_fraction < collision.contact_start then
            break
        end

        -- Check if the other shape actually blocks us
        local passable = pass_callback(collision)
        --print(i, collision.their_shape, self:get_owner(collision.their_shape), passable)
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

        -- If we're hitting the object and it's not passable, mark this as the
        -- furthest we can go, and we'll stop when we see something further
        -- FIXME ah wait, true slides shouldn't block us!  maybe i need blocks after all?
        if not passable then
            allowed_fraction = collision.contact_start
            --print("< found first collision:", collision.movement, "fraction:", collision.contact_start, self:get_owner(collision.their_shape))
        end

        -- Update some properties on the collision
        collision.passable = passable
        collision.our_owner = self:get_owner(shape)
        collision.their_owner = self:get_owner(collision.their_shape)

        -- Log the last contact with each shape
        hits[collision.their_shape] = collision
    end
    --print('-- END SWEEP --')

    if allowed_fraction == nil or allowed_fraction >= 1 then
        -- Nothing stands in our way, so allow the full movement
        return attempted, hits
    else
        return attempted * allowed_fraction, hits
    end
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
            return nil, math.huge
        end
    end

    return nearest_shape, nearest_point
end

return {
    Collider = Collider,
}
