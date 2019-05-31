--[[
Collision type, used and returned by Shape collision stuff.
]]
local Object = require 'klinklang.object'


local Collision = Object:extend{
    movement = nil,
    amount = nil,
    touchdist = nil,
    touchtype = nil,

    left_normal = nil,
    right_normal = nil,
    -- TODO get rid of these later?
    left_normal_dot = nil,
    right_normal_dot = nil,
}

function Collision:init()
    error("Collision has no constructor, sorry")
end

-- There's no init(); this blesses an existing collision table
function Collision.bless(class, collision)
    return setmetatable(collision, class)
end

-- Construction API


--------------------------------------------------------------------------------
-- Consumer API

-- NOTE: this is very rough, doesn't work for overlaps, may or may not work for
-- concave shapes, and assumes the movement has already happened and the
-- objects are now touching!
function Collision:get_contact()
    if self.touchtype < 0 then
        -- Someday...
        return
    end
    -- FIXME this kinda flickers when standing next to a corner?

    -- This is clockwise from the normal, so it'll order comments
    -- counter-clockwise around us
    local contact = self.axis:perpendicular()
    local our_second, our_first = self.our_shape:find_edge(self.our_point, self.axis)
    local their_first, their_second = self.their_shape:find_edge(self.their_point, self.axis)

    local our_first_dot = our_first * contact
    local our_second_dot = our_second * contact
    local their_first_dot = their_first * contact
    local their_second_dot = their_second * contact
    -- These are already ordered from left to right (when looking along the
    -- normal, i.e. counter-clockwise around us), so there are only four cases:
    -- No overlap
    if our_second_dot < their_first_dot or their_second_dot < our_first_dot then
        -- No overlap
        print('no contact?')
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
        --print("contact:", first, second)
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
