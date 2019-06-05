--[[
Collision type, used and returned by Shape collision stuff.
]]
local Vector = require 'klinklang.vendor.hump.vector'

local Object = require 'klinklang.object'


local Collision = Object:extend{
    -- (Vector) How far this shape attempted to move
    attempted = nil,
    -- FIXME not right for slides!  maybe fraction SHOULD be inf for those??  wait, do i even use fraction?  IS FRACTION EVEN THE RIGHT THING ANYWHERE, EVEN IN SWEEP_TOWARDS??
    -- (number) How much of 'attempted' this shape could move before coming into contact
    -- with the other shape, as a fraction >= 0
    fraction = nil,
    -- (Vector) How far this shape could move before contact, i.e. attempted * fraction
    movement = nil,
    -- (bool) Whether the shapes already overlapped, BEFORE the movement
    overlapped = nil,

    -- (number) How much of 'attempted' this shape could move before coming
    -- into contact with the other shape, as a fraction >= 0
    -- NOTE: If 'attempted' is a zero vector, this is meaningless.
    contact_start = nil,
    -- (number) How much of 'attempted' this shape would need to move before
    -- passing out its other side, as a fraction >= 0
    -- NOTE: If 'attempted' is a zero vector, this is meaningless.
    contact_end = nil,
    -- (number) The type of contact resulting from the attempted movement:
    -- negative if moving apart, zero if sliding exactly against one another,
    -- positive if collision
    -- NOTE: Negative can only occur for overlapping shapes; separate shapes
    -- moving apart don't return a Collision at all.
    contact_type = nil,
    -- FIXME if 'attempted' is a zero vector, how do you figure out whether they're already touching or not?  oh i guess contact_type > 0 is no longer plausible

    -- Collisions have two normals in order to handle corner-corner collisions:
    -- one on the left and one on the right.  For head-on collisions, both will
    -- exist and be the same; for corner collisions, both will exist and be
    -- different; for any other collision, only one will exist.
    -- Note that at least one will always exist EXCEPT when contact_type < 0,
    -- i.e. when the shapes overlap and are moving apart.
    -- XXX should this be normalized?  Probably
    -- (Vector) The normal vector of the closest surface on our left side, when
    -- looking along the direction of movement.  If the other shape is solid,
    -- this is what stops us from moving more leftward
    left_normal = nil,
    -- (Vector) Same, but for the right side
    right_normal = nil,

    amount = nil,
    touchdist = nil,
    touchtype = nil,

    -- TODO get rid of these later?
    left_normal_dot = nil,
    right_normal_dot = nil,

    -- TODO shapes, points, etc.

    -- Properties added to collisions that come out of Collider:sweep()
    -- (bool/string) Whether the collision allows us to continue moving.  May
    -- also be one of two special strings; see sweep() documentation
    -- NOTE: This is NOT whether the other object is solid; it very well may
    -- be, but if this is a slide or a separating overlap, this should still be
    -- true.  Do NOT use this to check whether the object is solid!
    passable = nil,
    -- (?) The registered owners of the respective shapes
    our_owner = nil,
    their_owner = nil,
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
    local minleftdot = 0
    local minleftnorm
    local minrightdot = 0
    local minrightnorm
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
    -- FIXME this is not the case for MultiShape of course, which needs fixing
    -- so that each of its sub-parts is a separate collision...  unless the
    -- collision table gets a flag indicating it was a corner collision or not?
    -- FIXME wait, are these dot products even correct for an arbitrary vector
    -- like this?  should i be taking new ones?
    -- FIXME the "two different collisions" case is wrong; if you run smack into something, you'll get the same normal on both sides.  the trouble is that this is used to slide velocity, which is not necessarily pointing in the same direction as the movement was to get these normals.  this SHOULD still be enough information, i just need to use it a bit better

    for _, collision in pairs(collisions) do
        -- FIXME probably only consider "slide" when the given vector is not in fact perpendicular?
        if not collision.passable or collision.passable == 'slide' then
            --print('slide', collision, collision.touchtype, collision.blocks, collision.shape, collision.left_normal, collision.right_normal)
            -- TODO comment stuff in shapes.lua
            -- TODO explain why i used <= below (oh no i don't remember, but i think it was related to how this is done against the last slide only)
            -- FIXME i'm now using normals compared against our /last slide/ on our /velocity/ and it's unclear what ramifications that could have (especially since it already had enough ramifications to need the <=) -- think about this i guess lol

            if collision.left_normal then
                if collision.left_normal_dot <= minleftdot then
                    minleftdot = collision.left_normal_dot
                    minleftnorm = collision.left_normal
                end
                -- If we have a left normal but NOT a right normal, then we're
                -- blocked on the left side
                if not collision.right_normal then
                    blocked_left = true
                end
            end
            if collision.right_normal then
                if collision.right_normal_dot <= minrightdot then
                    minrightdot = collision.right_normal_dot
                    minrightnorm = collision.right_normal
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
        if minleftdot == 0 and minrightdot == 0 then
            return direction, true
        end
        return Vector(), false
    end

    -- Otherwise, we can probably slide
    local axis
    if minleftnorm and minrightnorm then
        -- We hit a corner somewhere!  If we also hit a wall, then we have to
        -- slide in that direction.  Otherwise, we pick the normal with the
        -- BIGGEST dot, which is furthest away from the direction and thus the
        -- least disruptive.  In the case of a tie, this was a perfect corner
        -- collision, so we give up and stop.
        if blocked_left then
            axis = minleftnorm
        elseif blocked_right then
            axis = minrightnorm
        elseif minrightdot > minleftdot then
            axis = minrightnorm
        elseif minleftdot > minrightdot then
            axis = minleftnorm
        else
            return Vector(), false
        end
    else
        axis = minleftnorm or minrightnorm
    end

    if axis then
        return direction - direction:projectOn(axis), true
    else
        return direction, true
    end
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

function Collision:print()
    local fmt = "%20s: %s"
    for _, key in ipairs{
        'attempted', 'overlapped', 'our_shape', 'their_shape',
        'contact_start', 'contact_end', 'contact_type', 'distance',
        'left_normal', 'right_normal', 'left_separation', 'right_separation',
    } do
        print(fmt:format(key, self[key]))
    end
    if self.passable ~= nil then
        for _, key in ipairs{
            'passable',
            'successful', 'success_fraction', 'success_state',
        } do
            print(fmt:format(key, self[key]))
        end
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
