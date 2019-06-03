--[[
Collision type, used and returned by Shape collision stuff.
]]
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
    -- TODO should this be 'overlapped', to match 'attempted'?
    overlaps = nil,

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

function Collision:init()
    error("Collision has no constructor, sorry")
end

-- There's no init(); this blesses an existing collision table
function Collision.bless(class, collision)
    -- Populate a few deprecated properties
    -- TODO remove these sometime
    collision.touchdist = collision.contact_start
    collision.shape = collision.their_shape
    if collision.overlaps then
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
    local keys = {}
    for key in pairs(self) do
        table.insert(keys, key)
    end
    table.sort(keys)

    for _, key in ipairs(keys) do
        print(("%20s  %s"):format(key, self[key]))
    end
end

-- NOTE: this is very rough, doesn't work for overlaps, may or may not work for
-- concave shapes, and assumes the movement has already happened and the
-- objects are now touching!  blorf
function Collision:get_contact()
    if self.touchtype < 0 then
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
