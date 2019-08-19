local Object = require 'klinklang.object'


local Component = Object:extend{
    slot = nil,  -- for unique components, the name of their slot
}

function Component:update(actor, dt)
end

function Component:after_collisions(actor, movement, collisions)
end


return Component
