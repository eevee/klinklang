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


return Collision
