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

-- Stops any world behavior the component is in the middle of.  This is generally called when a
-- component is about to be removed or the actor's state is about to be reset to some known basic
-- state, and it should undo any temporary changes the component has made — e.g., for Climb this
-- lets go of a ladder, and for fox flux it cancels special moves in progress.  (It should also
-- reset decisions, so the actor doesn't immediately perform the action again in the same frame.)
-- As a subtler example, Jump:stop() cancels the jump, which actively alters the actor's velocity,
-- because that's the expected behavior of "stopping a jump", no matter what causes it to happen.
-- Note that this is NOT for undoing modifications made when the component is first added to the
-- actor; that sort of lifecycle behavior is not (currently) part of this interface.
function Component:stop()
end

-- Regular update, called once per frame
function Component:update(actor, dt)
end

function Component:on_collide_with(collision)
end

function Component:after_collisions(actor, movement, collisions)
end


return Component
