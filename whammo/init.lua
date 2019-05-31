local Vector = require 'klinklang.vendor.hump.vector'

local Object = require 'klinklang.object'
local util = require 'klinklang.util'
local Blockmap = require 'klinklang.whammo.blockmap'
local shapes = require 'klinklang.whammo.shapes'

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
    owner = self.shapes[shape]
    if owner == self._NOTHING then
        owner = nil
    end
    return owner
end


-- Sort collisions in the order we'll come into contact with them (whether or
-- not we'll actually hit them as a result)
local function _collision_sort(a, b)
    if a.touchdist == b.touchdist then
        return a.touchtype < b.touchtype
    end
    return a.touchdist < b.touchdist
end

-- FIXME consider renaming this and the other method to "sweep"
function Collider:slide(shape, attempted, pass_callback)
    if shape == nil then
        error("Can't slide a nil shape")
    end

    local hits = {}
    local collisions = {}
    local neighbors = self.blockmap:neighbors(shape, attempted:unpack())
    for neighbor in pairs(neighbors) do
        local collision = shape:slide_towards(neighbor, attempted)
        if collision then
            --print(("< got move %f = %s, touchtype %d, clock %s"):format(collision.amount, collision.movement, collision.touchtype, collision.clock))
            collision.shape = neighbor
            table.insert(collisions, collision)
        end
    end

    -- Look through the objects we'll hit, in the order we'll /touch/ them,
    -- and stop at the first that blocks us
    table.sort(collisions, _collision_sort)
    local allowed_amount
    for i, collision in ipairs(collisions) do
        collision.attempted = attempted

        --print("checking collision...", collision.movement, collision.amount, "at", collision.shape:bbox())
        -- If we've already found something that blocks us, and this
        -- collision requires moving further, then stop here.  This allows
        -- for ties
        if allowed_amount ~= nil and allowed_amount < collision.amount then
            break
        end

        -- Check if the other shape actually blocks us
        local passable = pass_callback and pass_callback(collision)
        if passable == 'retry' then
            -- Special case: the other object just moved, so keep moving
            -- and re-evaluate when we hit it again.  Useful for pushing.
            if i > 1 and collisions[i - 1].shape == collision.shape then
                -- To avoid loops, don't retry a shape twice in a row
                passable = false
            else
                local new_collision = shape:slide_towards(collision.shape, attempted)
                if new_collision then
                    new_collision.shape = collision.shape
                    for j = i + 1, #collisions + 1 do
                        if j > #collisions or not _collision_sort(collisions[j], new_collision) then
                            table.insert(collisions, j, new_collision)
                            break
                        end
                    end
                end
            end
        end

        -- Overlapping objects are a little tricky!  You can only move OUT of a
        -- (blocking) object you overlap, which means you may or may not be
        -- able to move even if the object is impassable.
        -- FIXME this feels like a bit of a mess, especially being duplicated below but without the == 0 case?  is that even right?  does anyone know
        local blocks = not passable
        if collision.touchtype < 0 then
            blocks = blocks and collision.amount < 1
        end

        -- If we're hitting the object and it's not passable, stop here
        if allowed_amount == nil and not passable and (
            collision.touchtype > 0 or (collision.touchtype < 0 and collision.amount < 1))
        then
            allowed_amount = collision.amount
            --print("< found first collision:", collision.movement, "amount:", collision.amount, self:get_owner(collision.shape))
        end

        -- Log the last contact with each shape
        collision.passable = passable
        collision.blocks = blocks
        hits[collision.shape] = collision
    end

    if allowed_amount == nil or allowed_amount >= 1 then
        -- We don't hit anything this time!  Apply the remaining unopposed
        -- movement
        return attempted, hits
    else
        return attempted * allowed_amount, hits
    end
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
