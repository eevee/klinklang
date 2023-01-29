local Gamestate = require 'klinklang.vendor.hump.gamestate'

local Object = require 'klinklang.object'
local util = require 'klinklang.util'

local BaseScene = Object:extend{
    scene_init = function() end,

    -- You may assign this to chain scenes together; when this one closes itself (with :close(), at
    -- least), it will switch to this instead of popping.
    next_scene = nil,
    -- The scene underneath us, if any.
    wrapped_scene = nil,
}

function BaseScene:init()
    -- Avoid conflict with Gamestate's 'init' hook
    self.init = self.scene_init
end


----------------------------------------------------------------------------------------------------
-- Gamestate lifecycle

-- A very annoying thing about Gamestate is that it calls :enter(old_scene) both for switching and
-- for popping, so we have no way of knowing whether the scene being passed in is actually still on
-- the stack -- and that's kind of important when we want to draw on top of it!

-- So here are some little adjustments to help smooth things out and tell what's actually going on.

function BaseScene:enter(old_scene)
    -- Called from a push() or a switch().
    if self.in_stack then
        util.warn(("same scene seems to be in the stack twice: %s"):format(self))
        Gamestate._dump()
        print(debug.traceback())
    end
    self.in_stack = true

    -- We rely on our own flag to tell us which happened.  If the old scene is not in the stack,
    -- then it was just switched out, and it should know what the wrapped scene is
    if not old_scene then
        self.wrapped_scene = nil
    elseif old_scene.xxx_eevee_fuck_ass then
        -- This is the bottommost default Gamestate, which irritatingly has no properties but an
        -- __index that always errors, so I have patched it to make it detectable
        self.wrapped_scene = nil
    elseif old_scene.in_stack then
        self.wrapped_scene = old_scene
    else
        self.wrapped_scene = old_scene.wrapped_scene
    end
end

function BaseScene:resume(old_scene)
    -- Called when a pop() causes us to become the topmost scene again.
end

function BaseScene:leave()
    -- Called from a switch() or a pop().  Either way, we are no longer in the stack at all.
    self.in_stack = false
end


-- Honestly the entire Gamestate API doesn't match how I even attempt to use it, and
-- I should really just replace it, but that might break a lot of things so I've been taking my
-- sweet time getting around to it.

-- The things that can actually happen are:
-- - This scene becomes active (because it was just pushed, OR whatever was on top was removed)
-- - This scene becomes inactive (because something was pushed on top of it)
-- - This scene is removed from the stack (because it was either popped or switched)

function BaseScene:close()
    if self.next_scene then
        Gamestate.switch(self.next_scene)
    else
        Gamestate.pop()
    end
end

function BaseScene:resize()
end

return BaseScene
