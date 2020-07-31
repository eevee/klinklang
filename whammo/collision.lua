--[[
Collision type, used and returned by Shape collision stuff.
]]
local Vector = require 'klinklang.vendor.hump.vector'

local Object = require 'klinklang.object'


local Collision = Object:extend{
    -- (Vector) How far this shape attempted to move
    attempted = nil,
    -- (bool) Whether the shapes already overlapped, before any movement
    overlapped = nil,
    -- (Shape) The shapes themselves
    our_shape = nil,
    their_shape = nil,

    -- (number) How much of 'attempted' this shape *could* move before coming
    -- into contact with the other shape, as a fraction
    -- NOTE: If 'attempted' is a zero vector, this is meaningless.
    -- NOTE: This may be negative, if the shapes were already touching or
    -- overlapping!
    contact_start = nil,
    -- (number) How much of 'attempted' this shape would need to move before
    -- passing out its other side, as a fraction >= 0
    -- NOTE: If 'attempted' is a zero vector, this is meaningless.
    contact_end = nil,
    -- (number) The type of contact resulting from the attempted movement:
    -- negative if moving apart, zero if sliding exactly against one another,
    -- positive if collision
    -- NOTE: Negative can only occur for overlapping shapes; separate shapes
    -- moving apart don't produce a Collision at all.
    contact_type = nil,

    -- Collisions have two normals in order to handle corner-corner collisions:
    -- one on the left and one on the right.  For head-on collisions, both will
    -- exist and be the same; for corner collisions, both will exist and be
    -- different; for any other collision, only one will exist.
    -- Note that at least one will always exist EXCEPT when contact_type < 0,
    -- i.e. when the shapes overlap and are moving apart.
    -- XXX should this be normalized?  Probably
    -- (Vector?) The normal vector of the closest surface on our left side,
    -- when looking along the direction of movement.  If the other shape is
    -- solid, this is what stops us from moving more leftward
    left_normal = nil,
    -- (Vector?) Same, but for the right side
    right_normal = nil,
    -- TODO get rid of these later?
    left_normal_dot = nil,
    right_normal_dot = nil,
    -- (Vector?) The shortest distance between the two shapes on the left side
    left_separation = nil,
    -- (Vector?) Same, but for the right side
    right_separation = nil,

    -- TODO still unsure about these, used mainly for contact detection
    our_point = nil,
    their_point = nil,
    axis = nil,

    -- Properties added to collisions that come out of Collider:sweep().  These
    -- WILL NOT EXIST for other collisions!
    -- (bool/string) Whether the collision allows us to continue moving.  May
    -- also be one of two special strings; see sweep() documentation
    passable = nil,
    -- (?) The registered owners of the respective shapes
    -- Note that these are added very early by Collider:sweep(), so unlike the
    -- other properties here, these are available in a pass_callback
    our_owner = nil,
    their_owner = nil,
    -- (Vector) How far this shape ultimately moved
    successful = nil,
    -- (number) How far this shape moved, as a fraction of 'attempted'
    success_fraction = nil,
    -- (number) The type of contact left after the movement: -1 if overlapping,
    -- 0 if touching, 1 if no contact
    success_state = nil,
}

-- Given a set of collisions, slide a movement (or velocity?) vector along them
-- using their normals, and return the slid vector and a bool indicating
-- whether any sliding was necessary.  This works best if the direction of the
-- given vector is "kinda-sorta close to" to direction of movement that
-- produced the collisions; if it's in completely the opposite direction, none
-- of the normals will even face it, and nothing will happen.
-- TODO i observe that most of this has nothing to do with 'direction' and is
-- just about computing axes from a set of collisions.  should a set of
-- collisions be a first-class thing?
function Collision.slide_along_normals(class, collisions, direction)
    local axis = class:get_slide_axis(collisions, direction)
    if axis then
        if axis:cross(direction) == 0 then
            -- Totally blocked, no slide
            return Vector(), false
        else
            return direction - direction:projectOn(axis), true
        end
    else
        return direction, true
    end
end

-- Given a set of collisions and a direction of movement (or velocity), find
-- the axis that allows the most freedom of movement.
-- Returns
--   axis, left_collision, right_collision
-- where 'axis' is either the most oppressive normal or nil if nothing is
-- blocking movement, and the two collisions are the ones slid along.
function Collision.get_slide_axis(_, collisions, direction)
    local min_left_dot = 0
    local min_left_collision
    local min_right_dot = 0
    local min_right_collision
    local blocked_left = false
    local blocked_right = false

    -- Each collision tracks two normals: the nearest surface blocking movement
    -- on the left, and the nearest on the right (relative to the direction of
    -- movement).  Most collisions only have one or the other, meaning we hit a
    -- wall on that side.  If a single collision has BOTH normals, that means
    -- this is a corner-corner collision, which is ambiguous: we could slide
    -- either way, and we'll pick whichever is closest to our direction of
    -- movement.
    -- If there are two DIFFERENT collisions, one with only a left normal and
    -- one with only a right normal, then we're stuck: we're completely blocked
    -- by separate objects on both sides, like being wedged into the corner of
    -- a room.
    -- However, if there's a collision with ONLY (e.g.) a left normal and
    -- another collision with BOTH normals, we're fine: the corner-corner
    -- collision allows us to move either direction, so we'll use whichever
    -- left normal is most oppressive.
    -- Of course, if there are a zillion collisions that all have only left
    -- normals, that's also fine, and we'll slide along the most oppressive of
    -- those, too.
    -- FIXME wait, are these dot products even correct for an arbitrary vector
    -- like this?  should i be taking new ones?
    -- FIXME the "two different collisions" case is wrong; if you run smack into something, you'll get the same normal on both sides.  the trouble is that this is used to slide velocity, which is not necessarily pointing in the same direction as the movement was to get these normals.  this SHOULD still be enough information, i just need to use it a bit better

    for _, collision in ipairs(collisions) do
        -- FIXME probably only consider "slide" when the given vector is not in fact perpendicular?
        -- FIXME hey hey also, should we be using success_state here?
        if (not collision.passable or collision.passable == 'slide') and
            not collision.no_slide
        then
            --print('))) slide', collision, collision.touchtype, collision.blocks, collision.shape, collision.left_normal, collision.right_normal)
            -- TODO comment stuff in shapes.lua
            -- TODO explain why i used <= below (oh no i don't remember, but i think it was related to how this is done against the last slide only)
            -- FIXME i'm now using normals compared against our /last slide/ on our /velocity/ and it's unclear what ramifications that could have (especially since it already had enough ramifications to need the <=) -- think about this i guess lol

            if collision.left_normal then
                if collision.left_normal_dot <= min_left_dot then
                    min_left_dot = collision.left_normal_dot
                    min_left_collision = collision
                end
                -- If we have a left normal but NOT a right normal, then we're
                -- blocked on the left side
                if not collision.right_normal then
                    blocked_left = true
                end
            end
            if collision.right_normal then
                if collision.right_normal_dot <= min_right_dot then
                    min_right_dot = collision.right_normal_dot
                    min_right_collision = collision
                end
                if not collision.left_normal then
                    blocked_right = true
                end
            end
        end
    end

    -- If we're blocked on both sides, we can't possibly move at all
    if blocked_left and blocked_right then
        -- ...UNLESS we're blocked by walls parallel to us (i.e. dot of 0), in
        -- which case we can perfectly slide between them!
        if min_left_dot == 0 and min_right_dot == 0 then
            return nil, min_left_collision, min_right_collision
        end
        return -direction, min_left_collision, min_right_collision
    end

    -- Otherwise, we can probably slide
    local axis
    if min_left_collision and min_right_collision then
        -- We hit a corner somewhere!  If we also hit a wall, then we have to
        -- slide in that direction.  Otherwise, we pick the normal with the
        -- BIGGEST dot, which is furthest away from the direction and thus the
        -- least disruptive.  In the case of a tie, this was a perfect corner
        -- collision, so we give up and stop.
        if blocked_left then
            axis = min_left_collision.left_normal
        elseif blocked_right then
            axis = min_right_collision.right_normal
        elseif min_right_dot > min_left_dot then
            axis = min_right_collision.right_normal
        elseif min_left_dot > min_right_dot then
            axis = min_left_collision.left_normal
        else
            -- They're equal, so we ran smack into a corner.  This will
            -- probably slide the /movement/ to zero, but velocity may be
            -- moving in a different direction
            -- XXX why does this look different from the other corner cases...?
            axis = min_left_collision.left_normal
            --return Vector(), false
        end
    elseif min_left_collision then
        axis = min_left_collision.left_normal
    elseif min_right_collision then
        axis = min_right_collision.right_normal
    end

    return axis, min_left_collision, min_right_collision
end

function Collision:init()
    error("Collision has no constructor, sorry")
end

-- There's no init(); this blesses an existing collision table
function Collision.bless(class, collision)
    -- Populate a few deprecated properties
    -- TODO remove these sometime
    collision.touchdist = collision.contact_start
    collision.shape = collision.their_shape
    if collision.overlapped then
        collision.touchtype = -1
    else
        collision.touchtype = collision.contact_type
    end
    return setmetatable(collision, class)
end

-- Construction API


--------------------------------------------------------------------------------
-- Consumer API

local _CONTACT_TYPE_LABELS = {
    [-1] = 'overlap',
    [0] = 'touch',
    [1] = 'collide',
}
function Collision:print()
    print(("COLLISION: attempted %-20s"):format(self.attempted))
    print(("%9s: %s"):format("us", self.our_owner or self.our_shape))
    print(("%9s: %s"):format("them", self.their_owner or self.their_shape))
    print(("%9s: normal %-20s separation %s"):format("left", self.left_normal or '--', self.left_separation or '--'))
    print(("%9s: normal %-20s separation %s"):format("right", self.right_normal or '--', self.right_separation or '--'))
    print(("%9s: %s (%d), %s by %.2f // %.2f to %.2f"):format("contact", _CONTACT_TYPE_LABELS[self.contact_type], self.contact_type, self.overlapped and 'overlapping' or 'separated', self.distance, self.contact_start, self.contact_end))
    if self.passable ~= nil then
        print(("%9s: passable? %s // successful %.2f %s %s (%d)"):format('results', self.passable, self.success_fraction, self.successful, _CONTACT_TYPE_LABELS[self.success_state], self.success_state))
    end
end

-- Return whether either of our normals faces < 90° of the given direction
-- (i.e., is within the half-plane described by the given normal).  Perfect
-- right angles return false!
-- For example, a typical one-way platform blocks if the collision faces up.
function Collision:faces(direction)
    if self.left_normal and self.left_normal * direction > 0 then
        return true
    end
    if self.right_normal and self.right_normal * direction > 0 then
        return true
    end
    return false
end

-- NOTE: this is very rough, doesn't work for overlaps, may or may not work for
-- concave shapes, and assumes the movement has already happened and the
-- objects are now touching!  blorf
function Collision:get_contact()
    if self.overlapped then
        -- Someday...
        return
    end
    -- FIXME this kinda flickers when standing next to a corner?

    -- FIXME find this out thanks
    --print("is axis redundant?", self.axis, self.left_normal, self.right_normal)

    -- This is counter-clockwise from the normal, so it'll order contacts
    -- clockwise around us
    local contact = -self.axis:perpendicular()
    -- find_edge returns clockwise points, but two shapes against each other
    -- have different winding orders for the same edge (like gears), so swap
    -- their points to make them both ccw relative to us
    local our_first, our_second = self.our_shape:find_edge(self.our_point, self.axis)
    local their_second, their_first = self.their_shape:find_edge(self.their_point, self.axis)

    local our_first_dot = our_first * contact
    local our_second_dot = our_second * contact
    local their_first_dot = their_first * contact
    local their_second_dot = their_second * contact
    -- These are already ordered from left to right (when looking along the
    -- normal, i.e. counter-clockwise around us), so there are only four cases:
    -- No overlap
    if our_second_dot < their_first_dot or their_second_dot < our_first_dot then
        -- No overlap
        return
    else
        local first, second
        if our_first_dot < their_first_dot then
            first = their_first
        else
            first = our_first
        end
        if our_second_dot < their_second_dot then
            second = our_second
        else
            second = their_second
        end
        if game then
            table.insert(game.debug_draws, function()
                love.graphics.setColor(1, 0.25, 1)
                if (first - second):len2() > 1 then
                    love.graphics.line(first.x, first.y, second:unpack())
                else
                    love.graphics.circle('fill', first.x, first.y, 2)
                end
            end)
        end
        return first, second
    end
end


return Collision
