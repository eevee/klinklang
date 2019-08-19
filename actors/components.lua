local Vector = require 'klinklang.vendor.hump.vector'

local Object = require 'klinklang.object'
local util = require 'klinklang.util'
local Component = require 'klinklang.components.base'
local components_physics = require 'klinklang.components.physics'


-- TODO a sprite component
-- sprites are basically already components tbh, although they should absorb facing too
-- also it's a bit goofy that poses (and thus also sprites) have physics shapes associated with them, meaning your physics shape can change from a thing you do to your sprite?  don't know how i feel about that.  oh maybe they should just be differently named shapes that code can then alter at specific times?  that's more effort though, hm.
-- configuration: sprite?


-- Health and damage
local Ail = Component:extend{
    slot = 'ail',
}

function Ail:init(max_health)
    self.maximum = max_health

    self.current = max_health
    self.is_dead = false
end

function Ail:damage(actor, amount, type, source)
    if self.current == nil or self.is_dead then
        return
    end

    self.current = math.max(0, self.current - amount)
    if self.current <= 0 then
        self.is_dead = true
        self:on_die(actor, source)
    end
end

function Ail:on_die(actor, killer)
    actor:destroy()
end


-- Respond to a generic "interact" action
local React = Component:extend{
    slot = 'react',
}

function React:on_interact(actor, activator)
    -- FIXME hm.  this seems like it'd be different for every actor type, which
    -- suggests it's data?  i don't know, i just want to be able to write this
    -- in a simple way
    actor:on_use(activator)
end




-- Active decisions

-- Walking, either left/right or in all four directions
local Walk = Component:extend{
    decision = Vector.zero,
}

-- TODO air acceleration doesn't make sense for 2D, maybe?
function Walk:init(ground_acceleration, air_acceleration, deceleration_multiplier, max_speed)
    self.ground_acceleration = ground_acceleration
    self.air_acceleration = air_acceleration
    self.deceleration_multiplier = deceleration_multiplier
    self.max_speed = max_speed
end

function Walk:decide(dx, dy)
    self.decision = Vector(dx, dy)
    self.decision:normalizeInplace()
end

function Walk:update(actor, dt)
    -- Walking, in a way that works for both 1D and 2D behavior.  Treat the
    -- player's input (even zero) as a desired velocity, and try to accelerate
    -- towards it, capping if necessary.

    -- First figure out our target velocity
    local goal
    local current = actor.move_component.velocity
    local in_air = false
    if actor.gravity_component then
        -- For 1D, find the direction of the ground, so walking on a slope
        -- will attempt to walk *along* the slope, not into it
        local ground_axis
        if actor.gravity_component.grounded then
            ground_axis = actor.gravity_component.ground_normal:perpendicular()
        else
            -- We're in the air, so movement is horizontal
            ground_axis = Vector(1, 0)
            in_air = true
        end
        goal = ground_axis * self.decision.x * self.max_speed
        current = current:projectOn(ground_axis)
    else
        -- For 2D, just move in the input direction
        -- FIXME this shouldn't normalize the movement vector, but i can't do it in decide_move for reasons described there
        goal = self.decision:normalized() * self.max_speed
    end

    local delta = goal - current
    local delta_len = delta:len()
    local accel
    -- In the air (or on a steep slope), we're subject to air control
    if in_air then
        accel = self.air_acceleration
    else
        accel = self.ground_acceleration
    end
    local accel_cap = accel * dt
    -- Collect factors that affect our walk acceleration
    local walk_accel_multiplier = 1
    if delta_len > accel_cap then
        walk_accel_multiplier = accel_cap / delta_len
    end
    -- If we're pushing something, then treat our movement as a force
    -- that's now being spread across greater mass
    -- XXX should this check can_push, can_carry?  can we get rid of total_mass i don't like it??
    if actor.tote_component and goal ~= Vector.zero then
        local total_mass = actor.tote_component:_get_total_mass(actor, goal)
        walk_accel_multiplier = walk_accel_multiplier * actor.mass / total_mass
    end

    -- When inputting no movement at all, an actor is considered to be
    -- /de/celerating, since they clearly want to stop.  Deceleration can
    -- have its own multiplier, and this "skid" factor interpolates between
    -- full decel and full accel using the dot product.
    -- Slightly tricky to normalize them, since they could be zero.
    local skid_dot = delta * current
    if skid_dot ~= 0 then
        -- If the dot product is nonzero, then both vectors must be
        skid_dot = skid_dot / current:len() / delta_len
    end
    local skid = util.lerp((skid_dot + 1) / 2, self.deceleration_multiplier, 1)

    -- Put it all together, and we're done
    actor.move_component:push(delta * (skid * walk_accel_multiplier))
end


-- Leap into the air
local Jump = Object:extend{
    consecutive_jump_count = 0,
    decision = 0,
}

-- FIXME needs to accept max jumps
function Jump:init(jump_speed, abort_speed, sound)
    self.jump_speed = jump_speed
    self.abort_speed = abort_speed
    self.sound = sound
end

function Jump:decide(whether)
    if whether == true then
        self.decision = 2
    else
        self.decision = 0
    end
end

function Jump:update(actor, dt)
    if actor.gravity_component.grounded then
        self.consecutive_jump_count = 0
    end

    -- Jumping
    -- This uses the Sonic approach: pressing jump immediately sets (not
    -- increases!) the player's y velocity, and releasing jump lowers the y
    -- velocity to a threshold
    local move = actor.move_component
    if self.decision == 2 then
        self.decision = 1
        if move.velocity.y <= -self.jump_speed then
            -- Already moving upwards at jump speed, so nothing to do
            return
        end

        -- You can "jump" off a ladder, but you just let go.  Only works if
        -- you're holding a direction or straight down
        -- FIXME move this to controls, get it out of here
        if actor.is_climbing then
            if actor.decision_climb > 0 or actor.decision_move ~= Vector.zero then
                -- Drop off
                actor.is_climbing = false
            end
            return
        end

        if self.consecutive_jump_count == 0 and not actor.gravity_component.ground_shallow and not actor.is_climbing then
            -- If we're in mid-air for some other reason, act like we jumped to
            -- get here, for double-jump counting purposes
            self.consecutive_jump_count = 1
        end
        if self.consecutive_jump_count >= actor.max_jumps then
            -- No more jumps left
            return
        end

        -- Perform the actual jump
        move.pending_velocity.y = -self.jump_speed
        self.consecutive_jump_count = self.consecutive_jump_count + 1

        if self.sound then
            -- FIXME oh boy, this is gonna be a thing that i have to care about in a lot of places huh
            local sfx = self.sound:clone()
            if sfx:getChannelCount() == 1 then
                sfx:setRelative(true)
            end
            sfx:play()
        end

        -- If we were climbing, we shouldn't be now
        actor.is_climbing = false
        actor.climbing = nil
        actor.decision_climb = 0
        return true
    elseif self.decision == 0 then
        -- We released jump at some point, so cut our upwards velocity
        if not actor.gravity_component.grounded and not actor.was_launched then
            move.pending_velocity.y = math.max(move.pending_velocity.y, -self.abort_speed)
        end
    end
end


-- Climb
local Climb = Component:extend{}

function Climb:init(speed)
    self.speed = speed

    self.is_climbing = false
end

-- Decide to climb.  Negative for up, positive for down, zero to stay in place,
-- nil to let go.
function Climb:decide(direction)
    -- Like jumping, climbing has multiple states: we use -2/+2 for the initial
    -- attempt, and -1/+1 to indicate we're still climbing.  Unlike jumping,
    -- this may still be called every frame, so updating it is a bit fiddlier.
    if direction == 0 or direction == nil then
        self.decision = direction
    elseif direction > 0 then
        if self.decision > 0 then
            self.decision = 1
        else
            self.decision = 2
        end
    else
        if self.decision < 0 then
            self.decision = -1
        else
            self.decision = -2
        end
    end
end

function Climb:after_collisions(actor, movement, collisions)
    -- Check for whether we're touching something climbable
    -- FIXME we might not still be colliding by the end of the movement!  this
    -- should use, now that that's only final hits -- though we need them to be
    -- in order so we can use the last thing touched.  same for mechanisms!
    for _, collision in ipairs(collisions) do
        local obstacle = collision.their_owner
        if obstacle and obstacle.is_climbable then
            -- The reason for the up/down distinction is that if you're standing at
            -- the top of a ladder, you should be able to climb down, but not up
            -- FIXME these seem like they should specifically grab the highest and lowest in case of ties...
            -- FIXME aha, shouldn't this check if we're overlapping /now/?
            if collision.overlapped or collision:faces(Vector(0, -1)) then
                actor.ptrs.climbable_down = obstacle
                actor.on_climbable_down = collision
            end
            if collision.overlapped or collision:faces(Vector(0, 1)) then
                actor.ptrs.climbable_up = obstacle
                actor.on_climbable_up = collision
            end
        end

        -- If we're climbing downwards and hit something (i.e., the ground), let go
        if self.is_climbing and self.decision > 0 and not collision.passable and collision:faces(Vector(0, -1)) then
            self.is_climbing = false
            self.climbing = nil
            -- FIXME is this necessary?
            self.decision = 0
        end
    end
end

function Climb:update(actor, dt)
    -- Immunity to gravity while climbing is handled via get_gravity_multiplier
    -- FIXME not any more it ain't
    -- FIXME down+jump to let go, but does that belong here or in input handling?  currently it's in both and both are awkward
    -- TODO does climbing make sense in no-gravity mode?
    if self.decision then
        if math.abs(self.decision) == 2 or (math.abs(self.decision) == 1 and self.is_climbing) then
            -- Trying to grab a ladder for the first time.  See if we're
            -- actually touching one!
            -- FIXME Note that we might already be on a ladder, but not moving.  unless we should prevent that case in decide_climb?
            if self.decision < 0 and actor.ptrs.climbable_up then
                actor.ptrs.climbing = actor.ptrs.climbable_up
                self.is_climbing = true
                self.climbing = self.on_climbable_up
                self.decision = -1
            elseif self.decision > 0 and actor.ptrs.climbable_down then
                actor.ptrs.climbing = actor.ptrs.climbable_down
                self.is_climbing = true
                self.climbing = self.on_climbable_down
                self.decision = 1
            else
                -- There's nothing to climb!
                self.is_climbing = false
            end
            if self.is_climbing then
                -- If we just grabbed a ladder, snap us instantly to its center
                local x0, _y0, x1, _y1 = self.climbing.shape:bbox()
                local ladder_center = (x0 + x1) / 2
                --self:nudge(Vector(ladder_center - self.pos.x, 0), nil, true)
            end
        end
        -- FIXME handle all yon cases, including the "is it possible" block above
        if self.is_climbing then
            -- We have no actual velocity...  unless...  sigh
            if self.xxx_useless_climb then
                actor.velocity = actor.velocity:projectOn(gravity)
            else
                actor.velocity = Vector()
            end

            -- Slide us gradually towards the center of a ladder
            -- FIXME gravity dependant...?  how do ladders work in other directions?
            local x0, _y0, x1, _y1 = self.climbing.shape:bbox()
            local ladder_center = (x0 + x1) / 2
            local dx = ladder_center - self.pos.x
            local max_dx = self.climb_speed * dt
            dx = util.sign(dx) * math.min(math.abs(dx), max_dx)

            -- FIXME oh i super hate this var lol, it exists only for fox flux's slime lexy
            -- OH FUCK I CAN JUST USE A DIFFERENT CLIMBING COMPONENT ? ??? ?
            if self.xxx_useless_climb then
                -- Can try to climb, but is just affected by gravity as normal
                actor:nudge(Vector(dx, 0))
            elseif self.decision < 0 then
                -- Climbing is done with a nudge, rather than velocity, to avoid
                -- building momentum which would then launch you off the top
                local climb_distance = self.climb_speed * dt

                -- Figure out how far we are from the top of the ladder
                local ladder = self.on_climbable_up
                local separation = ladder.left_separation or ladder.right_separation
                if separation then
                    local distance_to_top = separation * Vector(0, -1)
                    if distance_to_top > 0 then
                        climb_distance = math.min(distance_to_top, climb_distance)
                    end
                end
                actor:nudge(Vector(dx, -climb_distance))
            elseif self.decision > 0 then
                actor:nudge(Vector(dx, self.speed * dt))
            end

            -- Never flip a climbing sprite, since they can only possibly face in
            -- one direction: away from the camera!
            self.facing = 'right'

            -- We're not on the ground, but this still clears our jump count
            -- FIXME this seems like it wants to say, i'm /kinda/ on the ground.  i'm stable.
            -- FIXME regardless it probably shouldn't be here, there should be a "hit the ground" message
            actor.jump_component.consecutive_jump_count = 0
        end
    end

    -- Clear these pointers so collision detection can repopulate them
    actor.ptrs.climbable_up = nil
    actor.ptrs.climbable_down = nil
    actor.on_climbable_up = nil
    actor.on_climbable_down = nil
end


-- Use an object
local Interact = Component:extend{}

function Interact:decide()
    self.decision = true
end

function Interact:update(actor, dt)
    if not self.decision then
        return
    end

    self.decision = false

    -- FIXME ah, default behavior.
end


local Think = Component:extend{
    slot = 'think',
}

local PlayerThink = Think:extend{}

-- Given two baton inputs, returns -1 if the left is held, 1 if the right is
-- held, and 0 if neither is held.  If BOTH are held, returns either the most
-- recently-pressed, or nil to indicate no change from the previous frame.
local function read_key_axis(a, b)
    local a_down = game.input:down(a)
    local b_down = game.input:down(b)
    if a_down and b_down then
        local a_pressed = game.input:pressed(a)
        local b_pressed = game.input:pressed(b)
        if a_pressed and b_pressed then
            -- Miraculously, both were pressed simultaneously, so stop
            return 0
        elseif a_pressed then
            return -1
        elseif b_pressed then
            return 1
        else
            -- Neither was pressed this frame, so we don't know!  Preserve the
            -- previous frame's behavior
            return nil
        end
    elseif a_down then
        return -1
    elseif b_down then
        return 1
    else
        return 0
    end
end

function PlayerThink:update(actor, dt)
    if actor.health_component and actor.health_component.is_dead then
        return
    end

    -- Converts player input to decisions.
    -- Note that actions come in two flavors: instant actions that happen WHEN
    -- a button is pressed, and continuous actions that happen WHILE a button
    -- is pressed.  The former check 'down'; the latter check 'pressed'.
    -- FIXME reconcile this with a joystick; baton can do that for me, but then
    -- it considers holding left+right to be no movement at all, which is bogus
    local walk_x = read_key_axis('left', 'right')
    local walk_y = read_key_axis('up', 'down')
    actor.walk_component:decide(walk_x, walk_y)

    local climb = read_key_axis('ascend', 'descend')
    actor.climb_component:decide(climb)

    -- Jumping is slightly more subtle.  The initial jump is an instant action,
    -- but /continuing/ to jump is a continuous action.
    if game.input:pressed('jump') then
        actor.jump_component:decide(true)
    end
    if not game.input:down('jump') then
        actor.jump_component:decide(false)
    end

    if game.input:pressed('use') then
        actor.interactor_component:decide()
    end
end


return {
    Ail = Ail,
    Interact = Interact,
    React = React,
    Walk = Walk,
    Jump = Jump,
    Climb = Climb,
    Think = Think,
    PlayerThink = PlayerThink,
    -- XXX back compat, please remove
    Fall = components_physics.Fall,
    Fall2D = components_physics.Fall2D,
    SentientFall = components_physics.SentientFall,
}
