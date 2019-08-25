local Object = require 'klinklang.object'


local Component = Object:extend{
    slot = nil,  -- for unique components, the name of their slot
    -- Lower happens earlier.  Some built-in priorities:
    -- -100: think
    -- 100: move
    -- TODO do i want a fucking dep graph, or to keep priority the same
    -- per-slot, orrrrr
    priority = 0,

    actor = nil,
}

function Component:init(actor, args)
    self.actor = actor
end

function Component:__tostring()
    return ("<Component %s>"):format(self.slot)
end

function Component:get(slot)
    return self.actor:get(slot)
end

-- Callbacks

-- Regular update, called once per frame
function Component:update(actor, dt)
end

function Component:on_collide_with(collision)
end

function Component:after_collisions(actor, movement, collisions)
end


return Component
