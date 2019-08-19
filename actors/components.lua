local Vector = require 'klinklang.vendor.hump.vector'

local Object = require 'klinklang.object'
local util = require 'klinklang.util'


local Component = Object:extend{
    slot = nil,  -- for unique components, the name of their slot
}

function Component:after_collisions(actor, movement, collisions)
end

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




local Fall2D = Component:extend{
    slot = 'fall',
}

function Fall2D:init(friction_decel)
    self.friction_decel = friction_decel
end

function Fall2D:get_friction(actor, normalized_direction)
    -- In top-down mode, everything is always on flat ground, so
    -- friction is always the full amount, away from velocity
    return normalized_direction:normalized() * (-self.friction_decel * actor:_get_carried_mass())
end


local Fall = Fall2D:extend{
    slot = 'fall',

    terminal_speed = 1536,
}

function Fall:init(...)
    Fall.__super.init(self, ...)

    -- FIXME are these actually used for anything interesting?  pooltoy i guess, but i think by far the most common use is just to disable gravity, which...  is...  much easier now...
    self.multiplier = 1
    self.multiplier_down = 1

    -- TODO should have a gravity prop that gets early_updated or something
end

function Fall:get_base_gravity()
    -- TODO move gravity to, like, the world, or map, or somewhere?  though it
    -- might also vary per map, so maybe something like Map:get_gravity(shape)?
    -- but variable gravity feels like something that would be handled by
    -- zones, which should already participate in collision, so........  i
    -- dunno think about this later
    -- TODO should this return a zero vector if has_gravity() is on?  seems
    -- reasonable, but also you shouldn't be checking for gravity at all if
    -- has_gravity is off, but,
    -- FIXME i think Game needs a 'constants' or something
    return Vector(0, 768)
end

-- XXX this is a FORCE, NOT acceleration!  and it is NOT trimmed to velocity
function Fall:get_friction(actor, normalized_direction)
    if self.ground_normal then
        local gravity1 = self:get_base_gravity():normalized()
        -- Get the strength of the normal force by dotting the ground normal
        -- with gravity
        local normal_strength = gravity1 * self.ground_normal * actor:_get_carried_mass()
        local friction = self.ground_normal:perpendicular() * (self.friction_decel * self.ground_friction * normal_strength)
        local dot = friction * normalized_direction
        if math.abs(dot) < 1e-8 then
            -- Something went wrong and friction is perpendicular to movement?
            return Vector.zero
        elseif friction * normalized_direction > 0 then
            return -friction
        else
            return friction
        end
    else
        --local friction = -self.friction_decel * normalized_direction:normalized() * actor.mass
        -- FIXME need some real air resistance; as written, the above also reverses gravity, oops
        return Vector.zero
    end
end

function Fall:act(actor, dt)
    -- TODO factor the ground_friction constant into this, and also into slope
    -- resistance
    local multiplier = self.multiplier
    if actor.velocity.y >= 0 then
        multiplier = multiplier * self.multiplier_down
    end

    actor.pending_force = actor.pending_force + self:get_base_gravity() * multiplier
end

function Fall:after_collisions(actor, movement, collisions)
    self:check_for_ground(actor, collisions)
end

function Fall:check_for_ground(actor, hits)
    local gravity = self:get_base_gravity()

    -- Ground test: did we collide with something facing upwards?
    -- Find the normal that faces /most/ upwards, i.e. most away from gravity.
    -- FIXME is that right?  isn't ground the flattest thing you're on?
    -- FIXME what if we hit the ground, then slid off of it?
    local mindot = 0  -- 0 is vertical, which we don't want
    local normal
    local obstacle
    local friction
    local terrain
    local carrier
    local carrier_normal
    for _, collision in ipairs(hits) do
        -- This is a little tricky, but to be standing on something, (a) it
        -- must have blocked us OR we slid along it, and (b) we must not have
        -- moved past it
        if (not collision.passable or collision.passable == 'slide') and collision.success_state <= 0 then
            -- Find the most upwards-facing normal
            local norm, dot
            if collision.left_normal and collision.right_normal then
                local left_normal = collision.left_normal:normalized()
                local left_dot = left_normal * gravity
                local right_normal = collision.right_normal:normalized()
                local right_dot = right_normal * gravity
                if left_dot < right_dot then
                    norm = left_normal
                    dot = left_dot
                else
                    norm = right_normal
                    dot = right_dot
                end
            else
                norm = (collision.left_normal or collision.right_normal):normalized()
                dot = norm * gravity
            end

            -- FIXME wait, hang on, does this even make sense?  you could be
            -- resting on multiple things and they're all equally valid.  i
            -- guess think about the case with boulder on wedge and ground
            if dot < mindot then
                -- New winner, easy peasy!
                mindot = dot
                normal = norm
                obstacle = collision.their_owner
                if obstacle then
                    friction = obstacle.friction_multiplier
                    terrain = obstacle.terrain_type
                    if obstacle.can_carry and actor.is_portable then
                        carrier = obstacle
                        carrier_normal = norm
                    end
                else
                    -- TODO should we use the friction from every ground we're on...?
                    friction = nil
                    terrain = nil
                    -- Don't clear carrier, that's still valid
                end
            elseif dot == mindot and dot < 0 then
                -- Deal with ties.  (Note that dot must be negative so as to
                -- not tie with the initial mindot of 0, which would make
                -- vertical walls seem like ground!)

                local obstacle2 = collision.their_owner
                if obstacle2 then
                    -- Prefer to stay on the same ground actor
                    if not (obstacle and obstacle == actor.ptrs.ground) then
                        obstacle = obstacle2
                    end

                    -- Use the HIGHEST of any friction multiplier we're touching
                    -- FIXME should friction just be a property of terrain type?  where would that live, though?
                    if friction and obstacle2.friction_multiplier then
                        friction = math.max(friction, obstacle2.friction_multiplier)
                    else
                        friction = obstacle2.friction_multiplier
                    end

                    -- FIXME what does this do for straddling?  should do
                    -- whichever was more recent, but that seems like a Whole
                    -- Thing.  also should this live on TiledMapTile instead of
                    -- being a general feature?
                    terrain = obstacle2.terrain_type or terrain

                    -- Prefer to stay on the same carrier
                    if obstacle2.can_carry and actor.is_portable and not (carrier and carrier == actor.ptrs.cargo_of) then
                        carrier = obstacle2
                        carrier_normal = norm
                    end
                end
            end
        end
    end

    self.grounded = not not normal
    self.ground_normal = normal
    -- FIXME do i want this...?  actor.ptrs.ground = actor
    self.ground_friction = friction or 1
    self.ground_terrain = terrain

    if actor.ptrs.cargo_of and actor.ptrs.cargo_of ~= carrier then
        actor.ptrs.cargo_of.cargo[actor] = nil
        actor.ptrs.cargo_of = nil
    end
    -- TODO i still feel like there should be some method for determining whether we're being carried
    -- TODO still seems rude that we inject ourselves into their cargo also
    if carrier then
        local manifest = carrier.cargo[actor]
        if manifest then
            manifest.expiring = false
        else
            manifest = {}
            carrier.cargo[actor] = manifest
        end
        manifest.state = CARGO_CARRYING
        manifest.normal = carrier_normal

        actor.ptrs.cargo_of = carrier
    end
end


-- Gravity for sentient actors; includes extra behavior for dealing with slopes
local SentientFall = Fall:extend{}

function SentientFall:init(max_slope, ...)
    SentientFall.__super.init(self, ...)
    self.max_slope = max_slope
end

function SentientFall:check_for_ground(actor, ...)
    SentientFall.__super.check_for_ground(self, actor, ...)

    local gravity = self:get_base_gravity()
    local max_slope_dot = self.max_slope * gravity
    -- Sentient actors get an extra ground property, indicating whether the
    -- ground they're on is shallow enough to stand on; if not, they won't be
    -- able to jump, they won't have slope resistance, and they'll pretty much
    -- act like they're falling
    self.ground_shallow = self.ground_normal and not (self.ground_normal * gravity - max_slope_dot > 1e-8)
    if not self.ground_shallow then
        self.grounded = false
    end

    -- Also they don't count as cargo if the contact normal is too steep
    -- TODO this is kind of weirdly inconsistent given that it works for
    -- non-sentient actors...?  should max_slope get hoisted just for this?
    if actor.ptrs.cargo_of then
        local carrier = actor.ptrs.cargo_of
        local manifest = carrier.cargo[actor]
        if manifest and manifest.normal * gravity - max_slope_dot > 1e-8 then
            carrier.cargo[self] = nil
            actor.ptrs.cargo_of = nil
        end
    end
end

function SentientFall:act(actor, dt)
    SentientFall.__super.act(self, actor, dt)

    -- Slope resistance: a sentient actor will resist sliding down a slope
    if not self.grounded then
        return
    end

    local gravity = self:get_base_gravity()
    -- Slope resistance always pushes upwards along the slope.  It has no
    -- cap, since it should always exactly oppose gravity, as long as the
    -- slope is shallow enough.
    -- Skip it entirely if we're not even moving in the general direction
    -- of gravity, though, so it doesn't interfere with jumping.
    -- FIXME this doesn't take into account the gravity multiplier /or/
    -- fluid resistance, and in general i don't love that it can get out of
    -- sync like that  :S
    local slope = self.ground_normal:perpendicular()
    if slope * gravity > 0 then
        slope = -slope
    end
    local slope_resistance = -(gravity * slope)
    actor.pending_force = actor.pending_force + slope_resistance * slope
end

function SentientFall:after_collisions(actor, movement, collisions)
    local was_on_ground = self.grounded

    SentientFall.__super.after_collisions(self, actor, movement, collisions)

    -- Ground adherence
    -- If we walk up off the top of a hill, our momentum will carry us into the
    -- air, which looks very silly; a sentient actor would simply step down
    -- onto the downslope.  So if we're only a very short distance above the
    -- ground, AND we were on the ground before moving, AND we're not trying to
    -- jump, then stick us to the floor.
    -- TODO i suspect this could be avoided with the same (not yet written)
    -- logic that would keep critters from walking off of ledges?  or if
    -- the loop were taken out of collider.slide and put in here, so i could
    -- just explicitly slide in a custom direction
    -- FIXME ah, no was_on_ground here
    if was_on_ground and not self.ground_normal and
        not self.was_launched and
        actor.jump_component.decision == 0 and not actor.climb_component.is_climbing and
        self.multiplier > 0 and self.multiplier_down > 0
    then
        local gravity = self:get_base_gravity()
        -- How far should we drop?  I'm so glad you asked!
        -- There are two components: the slope we just launched off of ("top"),
        -- and the one we're trying to drop onto ("bottom").
        -- The top part is easy; it's the vertical component of however far we
        -- just moved.  (This might point UP, if we're walking downhill!)
        local top_drop = -movement:projectOn(gravity)
        -- The bottom part, we don't know.  But we know the steepest slope we
        -- can stand on, so we can just use that.
        -- Please trust this grody vector math, I spent ages coming up with it.
        local bottom_drop = - ((movement + top_drop) * self.max_slope) / (gravity * self.max_slope) * gravity
        -- The bottom part might end up pointing the wrong way, because
        -- max_slope is a normal and can arbitrarily point either left or right
        -- FIXME wait max slope is gravity-dependant, rrgh!
        local drop
        if bottom_drop * gravity < 0 then
            drop = top_drop - bottom_drop
        else
            drop = top_drop + bottom_drop
        end

        -- Try dropping our shape, just to see if we /would/ hit anything, but
        -- without firing any collision triggers or whatever.  Try moving a
        -- little further than our max, just because that's an easy way to
        -- distinguish exactly hitting the ground from not hitting anything.
        -- TODO this all seems a bit ad-hoc, like the sort of thing that oughta be on Map
        local prelim_movement = actor.map.collider:sweep(actor.shape, drop * 1.1, function(collision)
            if collision.contact_type <= 0 then
                return true
            end
            local obstacle = collision.their_owner
            if obstacle == actor then
                return true
            end
            if obstacle then
                return not obstacle:blocks(actor, collision)
            else
                return false
            end
        end)

        if prelim_movement:len2() <= drop:len2() then
            -- We hit the ground!  Do that again, but for real this time.
            local drop_movement, hits = actor:nudge(drop, nil, true)
            movement = movement + drop_movement
            self:check_for_ground(actor, hits)
            -- FIXME update outer movement + hits??

            if self.grounded then
                -- Now we're on the ground, so flatten our velocity to indicate
                -- we're walking along it.  Or equivalently, remove the part
                -- that's trying to launch us upwards.
                actor.velocity = actor.velocity - actor.velocity:projectOn(self.ground_normal)
            end
        end
    end

    if self.grounded then
        self.was_launched = false
    end
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

function Walk:act(actor, dt)
    -- Walking, in a way that works for both 1D and 2D behavior.  Treat the
    -- player's input (even zero) as a desired velocity, and try to accelerate
    -- towards it, capping if necessary.

    -- First figure out our target velocity
    local goal
    local current
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
        current = actor.velocity:projectOn(ground_axis)
    else
        -- For 2D, just move in the input direction
        -- FIXME this shouldn't normalize the movement vector, but i can't do it in decide_move for reasons described there
        goal = self.decision:normalized() * self.max_speed
        current = actor.velocity
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
    if actor.can_push and goal ~= Vector.zero then
        local total_mass = actor:_get_total_mass(goal)
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
    actor.velocity = actor.velocity + delta * (skid * walk_accel_multiplier)
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

function Jump:act(actor)
    if actor.gravity_component.grounded then
        self.consecutive_jump_count = 0
    end

    -- Jumping
    -- This uses the Sonic approach: pressing jump immediately sets (not
    -- increases!) the player's y velocity, and releasing jump lowers the y
    -- velocity to a threshold
    if self.decision == 2 then
        self.decision = 1
        if actor.velocity.y <= -self.jump_speed then
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
        actor.velocity.y = -self.jump_speed
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
            actor.velocity.y = math.max(actor.velocity.y, -self.abort_speed)
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

function Climb:act(actor, dt)
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

function Interact:act(actor, dt)
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

function PlayerThink:act(actor, dt)
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
    Fall = Fall,
    Fall2D = Fall2D,
    SentientFall = SentientFall,
    Think = Think,
    PlayerThink = PlayerThink,
}
