-- Components for sentient actor behavior
local Vector = require 'klinklang.vendor.hump.vector'

local util = require 'klinklang.util'
local Component = require 'klinklang.components.base'


-- TODO a sprite component
-- sprites are basically already components tbh, although they should absorb facing too
-- also it's a bit goofy that poses (and thus also sprites) have physics shapes associated with them, meaning your physics shape can change from a thing you do to your sprite?  don't know how i feel about that.  oh maybe they should just be differently named shapes that code can then alter at specific times?  that's more effort though, hm.
-- configuration: sprite?


-- Health and damage
local Ail = Component:extend{
    slot = 'ail',
}

function Ail:init(actor, args)
    Ail.__super.init(self, actor)

    self.maximum = args.max_health

    self.current = self.maximum
    self.is_dead = false
end

function Ail:damage(amount, type, source)
    if self.current == nil or self.is_dead then
        return
    end

    self.current = math.max(0, self.current - amount)
    if self.current <= 0 then
        self.is_dead = true
        self:on_die(source)
    end
end

function Ail:on_die(killer)
    self.actor:destroy()
end


-- Respond to a generic "interact" action
local React = Component:extend{
    slot = 'react',

    -- The activator must be...
    -- ...a player
    player_only = false,
    -- ...very close to us on the y-axis
    -- TODO super unclear what this means if gravity is different between two things
    y_aligned_only = false,
    -- ...standing on the ground
    grounded_only = false,
    -- ...something custom (which must return false, not nil)
    extra_constraint = function() end,

    -- Not used here, but may be useful for other components
    hidden = false,
}

function React:init(actor, args)
    React.__super.init(self, actor)

    self.player_only = args.player_only
    self.y_aligned_only = args.y_aligned_only
    self.grounded_only = args.grounded_only
    self.extra_constraint = args.extra_constraint
    self.hidden = args.hidden
end

function React:is_valid_activator(actor)
    if self.player_only and not actor.is_player then
        return false
    end

    if self.y_aligned_only then
        local offset = self.actor.pos.y - actor.pos.y
        -- Note that they must be exactly aligned OR ABOVE us; slightly below is no good, it causes
        -- some very bad results when e.g. opening a fox flux treasure chest on a platform, which
        -- then starts a cutscene that moves the player!
        -- (Also remember we might be a billionth of a pixel inside stuff.)
        if offset < -1e-6 or 4 < offset then
            return false
        end
    end

    if self.grounded_only then
        local fall = actor:get('fall')
        if fall and not fall.grounded then
            return false
        end
    end

    if self.extra_constraint and self.extra_constraint(self, actor) == false then
        return false
    end

    return true
end

function React:on_interact(activator)
    if not self:is_valid_activator(activator) then
        return
    end

    -- FIXME hm.  this seems like it'd be different for every actor type, which
    -- suggests it's data?  i don't know, i just want to be able to write this
    -- in a simple way
    self.actor:on_use(activator)
end




-- Active decisions

-- Walking, either left/right or in all four directions
local Walk = Component:extend{
    slot = 'walk',

    -- Configuration --
    -- Base acceleration while walking, which controls how long it takes to get
    -- up to speed (and how long it takes to stop).  Note that this implicitly
    -- controls how much an actor can push, since it has to overcome the extra
    -- friction.  The maximum pushing mass (INCLUDING this actor's) is
    -- Fall.friction_decel / Walk.base_acceleration.
    base_acceleration = 2048,
    -- Maximum speed from walking.  If the actor is moving this fast (or
    -- faster) in the direction it's attempting to walk, walking has no effect
    speed_cap = 256,
    -- Multiplier for base_acceleration while grounded
    ground_multiplier = 1,
    -- Multiplier for base_acceleration while airborne (i.e., air control)
    air_multiplier = 0.25,
    -- Multiplier for base_acceleration while moving against the actor's
    -- current velocity direction; stacks with the above two
    stop_multiplier = 1,
    -- Whether to use free 2D movement (for something that flies, or everything
    -- in a top-down game); if false, use 1D platformer movement
    use_2d_movement = false,

    -- State --
    -- Normalized vector of the direction the actor is trying to move.  For a 1D actor (as
    -- determined by having a Fall rather than a Fall2D), y should be zero.
    decision = Vector.zero,
    -- Raw, un-normalized vector of the direction the actor is trying to move.  Use this for
    -- detecting when, e.g., a 1D actor is trying to "move down" in some other sense.
    raw_decision = Vector.zero,
}

-- TODO air acceleration doesn't make sense for 2D, maybe?
function Walk:init(actor, args)
    Walk.__super.init(self, actor)

    self.base_acceleration = args.base_acceleration
    self.speed_cap = args.speed_cap
    self.ground_multiplier = args.ground_multiplier
    self.air_multiplier = args.air_multiplier
    self.stop_multiplier = args.stop_multiplier
    self.use_2d_movement = args.use_2d_movement
end

function Walk:decide(dx, dy)
    self.raw_decision = Vector(dx, dy)

    self.decision = Vector(dx, dy)
    if not self.use_2d_movement then
        self.decision.y = 0
    end
    if self.decision:len2() ~= 1 then
        self.decision:normalizeInplace()
    end
end

function Walk:update(dt)
    -- Walking, in a way that works for both 1D and 2D behavior.  Treat the
    -- player's input (even zero) as a desired velocity, and try to accelerate
    -- towards it, capping if necessary.

    -- We divide by dt later, so...
    if dt <= 0 then
        return
    end

    local speed_cap = self.speed_cap
    local fall = self:get('fall')
    local grip = 1
    if fall and fall.grounded then
        grip = fall.ground_grip * fall.grip
        -- For muddy surfaces (grip > 1), slow our max speed here, AND slow our
        -- acceleration below
        if grip > 1 then
            speed_cap = speed_cap / grip
        end
    end

    -- First figure out our target velocity
    local goal_direction
    local current = self:get('move').velocity
    local in_air = false
    if self.use_2d_movement then
        -- For 2D, just move in the input direction
        goal_direction = self.decision
    else
        -- For 1D, find the direction of the ground, so walking on a slope
        -- will attempt to walk *along* the slope, not into it.
        -- This sounds wrong at a glance -- surely, someone can't walk as fast
        -- uphill as they can on flat ground -- but it feels good to play, and
        -- it's balanced out by the fact that moving 100px along a slope still
        -- makes less horizontal progress than moving 100px along flat ground!
        -- Plus, that would slow the actor down when going downhill, too!
        local ground_axis
        if fall.grounded then
            ground_axis = fall.ground_normal:perpendicular()
        else
            -- We're in the air, so movement is horizontal
            ground_axis = Vector(1, 0)
            in_air = true
        end
        goal_direction = ground_axis * self.decision.x
        -- If we're upside-down, flip the x direction to keep the controls intuitive
        if ground_axis.x < 0 then
            goal_direction = goal_direction * -1
        end
        current = current:projectOn(ground_axis)
    end

    local goal = goal_direction * speed_cap
    local delta = goal - current
    local delta_len = delta:len()

    -- Compute our (maximum) acceleration
    local accel_cap = self.base_acceleration
    -- In the air (or on a steep slope), we're subject to air control
    if in_air then
        accel_cap = accel_cap * self.air_multiplier
    else
        accel_cap = accel_cap * self.ground_multiplier
    end
    -- TODO i wonder if these should also affect our max speed?  maybe try it out
    if grip > 1 then
        -- Muddy: slow our acceleration
        accel_cap = accel_cap / grip
    elseif grip < 1 then
        -- Icy: also slow our acceleration
        accel_cap = accel_cap * grip
    end

    -- When inputting no movement at all, an actor is considered to be
    -- /de/celerating, since they clearly want to stop.  Deceleration can
    -- have its own multiplier, and this "skid" factor interpolates between
    -- full decel and full accel using the dot product.
    -- Slightly tricky to normalize them, since they could be zero.
    local skid_dot = delta * current
    if math.abs(skid_dot) > 1e-8 then
        -- If the dot product is nonzero, then both vectors must be nonzero too
        skid_dot = skid_dot / current:len() / delta_len
    end
    local skid = util.lerp((skid_dot + 1) / 2, self.stop_multiplier, 1)
    accel_cap = accel_cap * skid

    -- FIXME this kicks in even if we're above our max speed, is that a problem
    if not self.use_2d_movement and fall.ground_shallow and self.decision.x == 0 then
        -- We're trying to stand still on the ground; express this as friction so it opposes any
        -- slope we're on and is capped correctly.
        -- Note that having this here and not as a general force means you must have walk
        -- acceleration that's enough to counteract gravity, or you won't be able to get up slopes.
        local uphill_direction = fall.ground_normal:perpendicular()
        if uphill_direction.y > 0 then
            uphill_direction = -uphill_direction
        end
        self:get('move'):add_friction(uphill_direction * accel_cap)
    else
        -- We're trying to change our velocity by `delta`, and we could do it in this single frame
        -- if we accelerated by `delta / dt`!  But our acceleration has a limit, so take that into
        -- account too, and we're done
        local desired_accel_len = delta_len / dt
        local allowed_fraction = math.min(1, accel_cap / desired_accel_len)
        local final_accel = delta * (allowed_fraction / dt)
        self:get('move'):add_accel(final_accel)
    end
end


-- Leap into the air
local Jump = Component:extend{
    slot = 'jump',

    -- Configuration --
    -- Upwards speed granted by a jump.  Note that upwards speed is SET to
    -- this; it's not added!
    -- TODO would be much simpler to accept height here, but as it stands this
    -- default has to live in actors.base so it can see default gravity, sigh
    speed = 0,
    -- When abandoning a jump, the actor's vertical speed will be set to this
    -- times speed
    abort_multiplier = 0.25,
    -- Sound effect to play when jumping
    sound = nil,
    -- Number of consecutive jumps that can be made before hitting the ground:
    -- 1 for regular jumping, 2 for a double jump, Math.huge for flappy bird
    max_jumps = 1,
    -- How long after walking off a cliff we should still be allowed to jump
    coyote_duration = 0.1,
    -- How early before hitting the ground we can press the jump button
    buffer_window = 0.1,

    -- State --
    -- 2 when initially jumping, 1 when continuing a jump, 0 when abandoning a jump
    -- TODO probably split out the "still jumping" state, which might even let us ditch was_launched
    decision = 0,
    -- The number of jumps this actor has made so far without touching the
    -- ground, including an initial fall
    consecutive_jump_count = 0,
    -- Whether we think we're currently in the air due to jumping
    is_jumping = false,
    -- How long it's been since we were last on the ground
    coyote_timer = 0,
    -- How long it's been since we last attempted to jump (i.e. decision == 2)
    buffer_timer = 0,
}

-- FIXME needs to accept max jumps
function Jump:init(actor, args)
    Jump.__super.init(self, actor, args)

    self.speed = args.speed or 0
    self.abort_multiplier = args.abort_multiplier or 0.25
    self.sound = args.sound or nil
    if type(self.sound) == 'string' then
        self.sound = game.resource_manager:get(self.sound)
    end
    self.max_jumps = args.max_jumps or 1
end

function Jump:decide(whether)
    if whether == true then
        self.decision = 2
    else
        self.decision = 0
    end
end

function Jump:update(dt)
    local move = self:get('move')
    local fall = self:get('fall')

    -- Update "coyote time", which allows for jumping within a small window after walking off an
    -- edge.  This should only count up after we *walked* over the edge; if at any point we jump or
    -- are launched upwards, coyote time ends.  Unfortunately, the latter condition is a little
    -- tricky to define; if we walk off the top of a slope, then surely coyote time applies, but
    -- something like a spring should surely not count.  As a heuristic, coyote time ends if at any
    -- point we are moving upwards "too fast".
    local in_coyote_time = false
    if fall.grounded then
        self.coyote_timer = 0
    elseif self.is_jumping or move.velocity.y < -64 then
        -- Disable the timer until we next land, by setting it far beyond the duration
        self.coyote_timer = self.coyote_duration + 100
    else
        self.coyote_timer = self.coyote_timer + dt
        in_coyote_time = self.coyote_timer <= self.coyote_duration
    end

    if fall.grounded or in_coyote_time then
        self.consecutive_jump_count = 0
        self.is_jumping = false
    end
    -- TODO gravity
    if move.velocity.y >= 0 then
        self.is_jumping = false
    end

    -- Jump buffering: allow pressing jump just before hitting the ground in order
    if self.decision == 2 then
        self.buffer_timer = 0
    else
        self.buffer_timer = self.buffer_timer + dt
    end

    -- Some things cannot be jumped on.  (Originally for the fox flux bouncy shroom, where a
    -- frame-perfect jump plays a sound and allows jump cancel, neither of which makes sense.)
    if self.actor.ptrs.ground and self.actor.ptrs.ground.is_unjumpable then
        return
    end

    -- Perform the actual jump, if appropriate
    -- This uses the Sonic approach: pressing jump immediately sets (not
    -- increases!) the player's y velocity, and releasing jump lowers the y
    -- velocity to a threshold
    if self:attempting_jump() then
        self.decision = 1
        if move.velocity.y <= -self.speed then
            -- Already moving upwards at jump speed, so nothing to do
            return
        end

        if self.consecutive_jump_count == 0 and not fall.ground_shallow and not in_coyote_time then
            -- If we're in mid-air for some other reason, act like we jumped to
            -- get here, for double-jump counting purposes
            self.consecutive_jump_count = 1
        end
        if self.consecutive_jump_count >= self.max_jumps then
            -- No more jumps left
            return
        end

        -- Perform the actual jump
        return self:do_normal_jump()
    elseif self.decision == 0 then
        -- We released jump at some point, so cut our upwards velocity
        if not fall.grounded and self.is_jumping then
            move.pending_velocity.y = math.max(move.pending_velocity.y, -self.speed * self.abort_multiplier)
        end
    end
end

function Jump:attempting_jump()
    if self.decision == 2 then
        return true
    elseif self.decision == 1 and self.buffer_timer <= self.buffer_window then
        return true
    else
        return false
    end
end

function Jump:do_normal_jump()
    self:get('move'):max_out_velocity(Vector(0, -self.speed))
    self.consecutive_jump_count = self.consecutive_jump_count + 1
    self.is_jumping = true
    if self.decision == 2 then
        self.decision = 1
    end

    if self.sound then
        -- FIXME oh boy, this is gonna be a thing that i have to care about in a lot of places huh
        local sfx = self.sound:clone()
        if sfx:getChannelCount() == 1 then
            sfx:setRelative(true)
        end
        sfx:play()
    end

    return true
end

function Jump:do_special_jump(speed, affect_decision)
    local move = self:get('move')
    self:get('move'):max_out_velocity(Vector(0, -speed))
    self.consecutive_jump_count = self.consecutive_jump_count + 1
    self.is_jumping = true
    if self.decision == 2 and affect_decision ~= false then
        self.decision = 1
    end

    if self.sound then
        -- TODO Game needs a Jukebox mixer thing
        self.sound:clone():play()
    end

    return true
end


-- Climb
-- FIXME remaining issues:
-- - if you're already holding up/down when you first touch a climbable, you currently ignore it,
-- but you should totally grab on (but that would break down+jump to fall off)
-- - normalize v/h movement?  somehow?
local Climb = Component:extend{
    slot = 'climb',
    priority = -1001,  -- needed before basic physics to override one-way collision

    -- Configuration --
    -- Speed of movement while climbing
    speed = 128,
    sideways_speed = 64,
    -- Speed of the jump done off a ladder
    jump_speed = 0,
    -- How far sideways we can climb to reach an adjacent climbable
    -- Note that if at any point the actor is not touching any climbables at all, they will stop
    -- climbing regardless, so be mindful of the gaps between adjacent ladders!
    sideways_margin = 32,

    -- State --
    is_climbing = false,
    is_moving = false,
    is_aligned = false,  -- whether the actor is centered on a ladder
    enable_oneway_passthru = false,  -- set only during our own nudging
}

function Climb:init(actor, args)
    Climb.__super.init(self, actor, args)

    self.speed = args.speed
    self.sideways_speed = args.sideways_speed
    self.jump_speed = args.jump_speed
end

-- Decide to climb.  Negative for up, positive for down, zero to stay in place,
-- nil to let go.
function Climb:decide(direction)
    -- Like jumping, climbing has multiple states: we use -2/+2 for the initial attempt, and -1/+1
    -- to indicate we're still climbing.  Unlike jumping, this may still be called every frame, so
    -- updating it is a bit fiddlier.
    -- The idea is that you can jump into a ladder while already holding [ascend] and you'll latch
    -- onto it, BUT if you jump OFF of a ladder while already holding [ascend], that input is
    -- ignored until you release and press it again; otherwise, you'd regrab the ladder immediately.
    if direction == 0 or direction == nil then
        self.decision = direction
    elseif direction > 0 then
        -- Either we're climbing, OR we THINK we're climbing because we're still holding a key from
        -- last time we were holding a ladder.
        if self.is_climbing or self.decision == 1 or self.decision == -1 then
            self.decision = 1
        else
            self.decision = 2
        end
    else
        if self.is_climbing or self.decision == 1 or self.decision == -1 then
            self.decision = -1
        else
            self.decision = -2
        end
    end
end

function Climb:is_blocked_by(obstacle)
    -- Ignore collision with one-way platforms when climbing ladders, since they tend to cross (or
    -- themselves be) one-way platforms
    if self.enable_oneway_passthru and obstacle.one_way_direction then
        return false
    end
end

function Climb:after_collisions(movement, collisions)
    if self.is_climbing then
        -- Check for whether we're touching something climbable
        local touching_climbable = false

        for _, collision in ipairs(collisions) do
            local obstacle = collision.their_owner
            -- TODO i wonder if climbability should be a component, the way interactability is
            if obstacle and obstacle.is_climbable then
                touching_climbable = true
            end

            -- If we're climbing downwards and hit something (i.e., the ground), let go.  But only if
            -- we're actually centered, else it's tricky to climb down through a gap in solid floor
            -- FIXME gravity hardcoded
            if self.is_aligned and not collision.passable and collision:faces(Vector(0, -1)) then
                self:stop_climbing()
            end
        end

        -- Emergency escape hatch: if you're not touching anything climbable, stop climbing!
        if not touching_climbable then
            self:stop_climbing()
        end
    end
end

function Climb:_begin_climbing()
    if self.is_climbing then
        return
    end

    self.is_climbing = true
    self.is_aligned = false
    self.actor:set_modal_component(self, {
        walk = false,
        jump = false,
        fall = false,
        [false] = true,
    })

    -- We're not on the ground, but this still clears our jump count
    local jump = self:get('jump')
    if jump then
        jump.consecutive_jump_count = 0
    end
end

function Climb:stop_climbing()
    if not self.is_climbing then
        return
    end

    self.is_climbing = false
    self.is_aligned = false
    self.climbing = nil
    if self.actor.component_modality == self then
        self.actor:set_modal_component(nil, nil)
    end
end

function Climb:update(dt)
    local jump = self:get('jump')

    self.is_moving = false

    local climb_x = 0
    if self.is_climbing then
        climb_x = self:get('walk').raw_decision.x
    end

    -- TODO does climbing make sense in no-gravity mode?
    if self.decision == nil then
        -- Decision API says let go
        self:stop_climbing()
    elseif self.is_climbing and jump and jump.decision == 2 then
        -- Jump to let go
        self:stop_climbing()
        -- If holding descend, simply drop; otherwise do a jump.  (This is presumed to be a very
        -- short jump, so it doesn't support releasing early like Jump does.)
        if self.decision > 0 then
            jump:decide(false)
            -- Start from our downwards climbing speed; it's a bit weird to transition from climbing
            -- downwards to falling /more slowly/
            self:get('move'):set_velocity(Vector(0, self.speed))
        else
            jump:do_special_jump(self.jump_speed)
            -- Add a little bit of horizontal speed to get you away from the ladder, in the
            -- direction you're trying to move
            if climb_x ~= 0 then
                self:get('move'):add_velocity(Vector(self.sideways_speed * climb_x, 0))
            end
        end
    elseif
        -- Either climbing, or trying to climb
        (self.is_climbing or math.abs(self.decision) == 2) and
        -- And indicating some kind of desire for motion
        -- (Note that horizontal movement does not ever initiate a climb)
        (climb_x ~= 0 or self.decision ~= 0 or not self.is_aligned)
    then
        local motion_y = util.sign(self.decision) * self.speed * dt
        local test_motion = Vector(climb_x * self.sideways_margin, motion_y)
        local actor_x0, actor_y0, actor_x1, actor_y1 = self.actor.shape:bbox()
        local actor_width = actor_x1 - actor_x0
        local actor_center = self.actor.pos.x
        local touching_climbable = false
        local min_y = math.huge
        local max_y = -math.huge
        local sideways_ok = false
        local check_oneway = false
        -- Don't care about success, only about what's there
        local successful, hits = self.actor.map.collider:sweep(self.actor.shape, test_motion)
        for _, collision in ipairs(hits) do
            if collision.their_owner.is_climbable then
                -- ???
                if collision.overlapped or collision.contact_type > 0 then
                    touching_climbable = true

                    -- Vertical movement: don't climb so far that we're no longer touching anything, so
                    -- track the vertical extent of what's climbable
                    local x0, y0, x1, y1 = collision.their_shape:bbox()
                    min_y = math.min(min_y, y0)
                    max_y = math.max(max_y, y1)

                    -- Horizontal movement: if there's something to climb in that direction, allow
                    -- moving towards it, even if we can't immediately reach it.
                    -- Remember that we snap to the center of a ladder, so the question here is
                    -- whether there's a shape in the direction we're moving whose center is still
                    -- beyond our own position.
                    if not sideways_ok then
                        -- If we're on something wider than ourselves, it's a "trellis", and we can
                        -- always climb horizontally as long as we're touching it
                        -- (Note this doesn't have the same edge clamping as vertical movement, but
                        -- if we have Walk then we can move sideways normally anyway.)
                        if collision.overlapped and x1 - x0 > actor_width then
                            sideways_ok = true
                        else
                            local center = (x0 + x1) / 2
                            if (center - actor_center) * climb_x > 0 then
                                sideways_ok = true
                            end
                        end
                    end
                end
            end
        end

        if not touching_climbable then
            -- Nothing we can do here!
            return
        end
        if math.abs(self.decision) == 2 then
            self.decision = self.decision / 2
        end

        -- If we might hit a one-way platform, we only want to pass through it if there's
        -- something climbable on the other side.  Now that we know the vertical extent of the
        -- climbables we'll touch, check if any one-ways are beyond them, and if so, clamp
        local abandon_climb = false
        for _, collision in ipairs(hits) do
            if not collision.overlapped and collision.contact_type >= 0 and
                collision.their_owner.one_way_direction and
                collision:faces(collision.their_owner.one_way_direction) and
                self.actor.map:check_blocking(self.actor, collision.their_owner, collision)
            then
                local _, obstacle_y0, _, obstacle_y1 = collision.their_shape:bbox()
                if motion_y > 0 and obstacle_y0 >= max_y then
                    motion_y = math.min(motion_y, obstacle_y0 - actor_y1)
                    -- In this special case, of landing on a one-way platform partway down a ladder,
                    -- we need to stop climbing here
                    abandon_climb = true
                    -- Remember, these are in collided order, so we can stop as soon as we find
                    -- one that should block us
                    break
                end
            end
        end

        -- Cap vertical movement
        local orig_motion_y = motion_y
        if self.decision > 0 then
            motion_y = math.min(motion_y, max_y - actor_y0)
        elseif motion_y < 0 then
            motion_y = math.max(motion_y, min_y - actor_y1)
        end
        -- If we did just cap it, it's because we're going off the edge of what we're climbing, so
        -- stop climbing after this motion
        if orig_motion_y ~= motion_y then
            abandon_climb = true
        end

        -- Deal with horizontal movement
        local motion_x = 0
        local is_centering = false
        if sideways_ok then
            motion_x = climb_x * self.sideways_speed * dt
        -- Stupid problem: if you stand at a ladder on the ground and press down, all this code runs
        -- and tries to climb downwards for you, including doing a centering nudge, and then you
        -- immediately hit the ground so you let go.  Solution: don't center on the initial grab
        elseif self.is_climbing then
            -- Try to center on whatever we're grabbing
            local primary_distance = math.huge
            local primary_center
            -- FIXME gravity dependant...?  how do ladders work in other directions??
            for _, collision in ipairs(hits) do
                if collision.overlapped and collision.their_owner.is_climbable then
                    local x0, _, x1, _ = collision.their_shape:bbox()
                    local center = (x0 + x1) / 2
                    local distance = math.abs(actor_center - center)
                    if distance < primary_distance then
                        primary_center = center
                        primary_distance = distance
                    end
                end
            end

            if primary_center then
                local dx = primary_center - self.actor.pos.x
                local max_dx = self.sideways_speed * dt
                if math.abs(dx) < max_dx then
                    self.is_aligned = true
                end
                is_centering = true
                motion_x = util.sign(dx) * math.min(math.abs(dx), max_dx)
            else
                self.is_aligned = true
            end
        end

        -- TODO normalize movement?  how, with different speeds?  oops
        if motion_x ~= 0 or motion_y ~= 0 then
            if self.decision > 0 then
                self.enable_oneway_passthru = true
            end
            self:_begin_climbing()
            if self:do_climb(motion_x, motion_y, is_centering) then
                self.is_moving = true
            else
                self:stop_climbing()
            end
            self.enable_oneway_passthru = false

            if abandon_climb then
                self:stop_climbing()
            end
        end
    end
end

-- This is split out so fox flux's slime can override it
function Climb:do_climb(dx, dy, is_centering)
    local move = self:get('move')

    -- Discard any velocity from last frame; climbing controls your velocity
    move:set_velocity(Vector())

    if dx == 0 and dy == 0 then
        return
    end

    -- Climbing is done with a nudge, rather than velocity, to avoid building momentum which would
    -- then launch you off the top
    local successful = move:nudge(Vector(dx, dy))

    if successful.x ~= 0 or successful.y ~= 0 then
        return true
    end
end


-- Use an object, whatever that may mean.
-- This component does nothing on its own; you need to use or write a subclass
-- that implements get_mechanism() and returns the object to interact with.
local Interact = Component:extend{
    slot = 'interact',
}

function Interact:decide(whether)
    if whether == nil then
        self.decision = true
    else
        self.decision = whether
    end
end

function Interact:get_mechanism()
    -- Implement me!  Should return an actor with a React component, or nil.
end

function Interact:update(dt)
    if not self.decision then
        return
    end

    self.decision = false

    local mechanism = self:get_mechanism()
    if mechanism then
        local react = mechanism:get('react')
        if react then
            react:on_interact(self.actor)
        end
    end
end


-- Use an object that we overlap.  Intended for side-view platformers.
local TouchInteract = Interact:extend{
    -- TODO this should be a weak pointer!
    touched_mechanism = nil,
}

function TouchInteract:after_collisions(movement, collisions)
    -- Persistently track the mechanism we're touching, if any.  This avoids
    -- consulting collision on interaction (which isn't a big deal), but more
    -- importantly, if we're touching two things simultaneously, we can
    -- remember and stick with the one we touched first.

    -- The first mechanism we touched, and how far away it was
    local mechanism = nil
    local mechanism_contact = math.huge

    for _, collision in pairs(collisions) do
        local actor = collision.their_owner
        local react = actor:get('react')
        if collision.success_state <= 0 and react and react:is_valid_activator(self.actor) then
            if actor == self.touched_mechanism then
                -- We're still touching the same mechanism, so don't let
                -- anything else replace it!
                return
            end

            -- Pick the mechanism we hit first
            -- TODO perhaps this should handle ties, and zero 'attempted', with a tiebreaker!
            if collision.contact_start < mechanism_contact then
                mechanism = actor
                mechanism_contact = collision.contact_start
            end
        end
    end

    self.touched_mechanism = mechanism
end

function TouchInteract:get_mechanism()
    if not self.touched_mechanism then
        return nil
    elseif not self.touched_mechanism.map then
        -- If it's not part of the map any more, we can't use it!
        return nil
    else
        return self.touched_mechanism
    end
end


local Think = Component:extend{
    slot = 'think',
    priority = -9999,  -- needed before anything else, even physics
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

function PlayerThink:update(dt)
    local ail = self:get('ail')
    if ail and ail.is_dead then
        return
    end

    -- Converts player input to decisions.
    -- Note that actions come in two flavors: instant actions that happen WHEN
    -- a button is pressed, and continuous actions that happen WHILE a button
    -- is pressed.  The former check 'down'; the latter check 'pressed'.
    -- FIXME reconcile this with a joystick; baton can do that for me, but then
    -- it considers holding left+right to be no movement at all, which is bogus
    local walk = self:get('walk')
    if walk then
        walk:decide(read_key_axis('left', 'right'), read_key_axis('up', 'down'))
    end

    local climb = self:get('climb')
    if climb then
        local climb_direction = read_key_axis('ascend', 'descend')
        if climb_direction then
            -- read_key_axis can return nil when ambiguous, which Climb treats specially; if it
            -- does, preserve our previous direction the way Walk does automatically
            climb:decide(climb_direction)
        end
    end

    -- Jumping is slightly more subtle.  The initial jump is an instant action,
    -- but /continuing/ to jump is a continuous action.
    local jump = self:get('jump')
    if jump then
        if game.input:pressed('jump') then
            jump:decide(true)
        end
        if not game.input:down('jump') then
            jump:decide(false)
        end
    end

    local interact = self:get('interact')
    if interact then
        if game.input:pressed('interact') then
            interact:decide()
        end
    end
end


return {
    Ail = Ail,
    Interact = Interact,
    TouchInteract = TouchInteract,
    React = React,
    Walk = Walk,
    Jump = Jump,
    Climb = Climb,
    Think = Think,
    PlayerThink = PlayerThink,
}
