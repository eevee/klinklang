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
}

function React:on_interact(activator)
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

    -- State --
    -- Normalized vector of the direction the actor is trying to move.  For a 1D actor (as determined by having a Fall rather than a Fall2D), this should be zero in the direction of gravity.
    -- TODO boy that's hokey and also doesn't play nicely with PlayerThink
    decision = Vector.zero,
}

-- TODO air acceleration doesn't make sense for 2D, maybe?
function Walk:init(actor, args)
    Walk.__super.init(self, actor)

    self.base_acceleration = args.base_acceleration
    self.ground_multiplier = args.ground_multiplier
    self.air_multiplier = args.air_multiplier
    self.stop_multiplier = args.stop_multiplier
    self.speed_cap = args.speed_cap
end

function Walk:decide(dx, dy)
    self.decision = Vector(dx, dy)
    if self.decision:len2() ~= 1 then
        self.decision:normalizeInplace()
    end
end

function Walk:update(dt)
    -- Walking, in a way that works for both 1D and 2D behavior.  Treat the
    -- player's input (even zero) as a desired velocity, and try to accelerate
    -- towards it, capping if necessary.

    local speed_cap = self.speed_cap
    local fall = self:get('fall')
    local tote = self:get('tote')
    if tote then
        -- Slow our walk when pushing something.
        -- This is a little hokey, but modelling walking as accelerating to a
        -- max speed is already a huge handwave, so this is kind of an adapter
        -- to that.  The idea is, if walking accelerates us by A to a max speed
        -- S, then when pushing against a frictional force that accelerates us
        -- backwards at A/4, our max speed should be reduced by S/4.
        -- This feels better than any other model I've tried; your walk speed
        -- slows linearly with how much stuff you're pushing.
        local total_friction_force = fall:_get_total_friction(self.decision)
        local total_friction_accel_len = total_friction_force:len() / self.actor.mass
        -- TODO hm there's also a reduction of 11.5, 20.5 (mass 2, mass 4) from somewhere else
        speed_cap = speed_cap * (1 - total_friction_accel_len / self.base_acceleration)
        --print('speed cap reduction', 1 - total_friction_accel_len / self.base_acceleration, speed_cap)
    end
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
    -- XXX genericize this, somehow
    -- XXX also this is wrong anyway, there's a Fall2D component
    if fall then
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
        current = current:projectOn(ground_axis)
    else
        -- For 2D, just move in the input direction
        goal_direction = self.decision
    end

    -- Figure out slowdown due to pushing
    -- TODO probably replace with friction or whatever
    local function get_total_pushed_mass(actor, _seen)
        _seen = _seen or {}
        if _seen[actor] then
            return 0
        end
        _seen[actor] = true

        local total_pushed_mass = 0
        local move = actor:get('move')
        for contact, info in pairs(move.pushable_contacts) do
            if info.normal * goal_direction < 0 then
                -- TODO recurse
                total_pushed_mass = total_pushed_mass + info.mass + get_total_pushed_mass(contact, _seen)
            end
        end

        return total_pushed_mass
    end
    local total_pushed_mass = get_total_pushed_mass(self.actor)
    local MAX_CAPACITY = 9
    local push_multiplier = math.max(0, 1 - total_pushed_mass / (MAX_CAPACITY - self.actor.mass))
    --print('** total pushed mass', total_pushed_mass, "push multiplier", push_multiplier)
    speed_cap = speed_cap * push_multiplier

    local goal = goal_direction * speed_cap
    local delta = goal - current
    local delta_len = delta:len()
    local accel_cap = self.base_acceleration * dt
    -- Normally, pushing more stuff decreases your acceleration, but in the limiting case of pushing /too much/, push_multiplier is zero and you'll never decelerate to a standstill!
    -- TODO wait, you should be stopped when you run into the two things already?
    if push_multiplier > 0 then
        accel_cap = accel_cap * push_multiplier
    end
    -- Collect multipliers that affect our walk acceleration
    local multiplier = 1
    -- In the air (or on a steep slope), we're subject to air control
    if in_air then
        multiplier = multiplier * self.air_multiplier
    else
        multiplier = multiplier * self.ground_multiplier
    end
    if grip > 1 then
        -- Muddy: slow our acceleration
        multiplier = multiplier / grip
    elseif grip < 1 then
        -- Icy: also slow our acceleration
        multiplier = multiplier * grip
    end

    -- XXX trying to reduce accel from pushing again...
    local move = self:get('move')
    if move and move._last_pushed_mass and move._last_pushed_mass ~= 0 then
        --multiplier = multiplier * self.actor.mass / move._last_pushed_mass
    end

    -- When inputting no movement at all, an actor is considered to be
    -- /de/celerating, since they clearly want to stop.  Deceleration can
    -- have its own multiplier, and this "skid" factor interpolates between
    -- full decel and full accel using the dot product.
    -- Slightly tricky to normalize them, since they could be zero.
    local skid_dot = delta * current
    if math.abs(skid_dot) > 1e-8 then
        -- If the dot product is nonzero, then both vectors must be
        skid_dot = skid_dot / current:len() / delta_len
    end
    local skid = util.lerp((skid_dot + 1) / 2, self.stop_multiplier, 1)
    multiplier = multiplier * skid

    -- Cap it
    multiplier = math.min(multiplier, accel_cap / delta_len)

    -- Put it all together, and we're done
    -- TODO would be really nice to express this as an acceleration, but i think that would require dividing by dt somewhere  :S  plus it's a bit goofy to integrate something with a cap.
    --print('WALK:', delta * (multiplier / dt), 'from', goal, current, delta, skid, multiplier, dt, 'and btw speed cap', speed_cap, 'current', current)
    --self:get('move'):add_velocity(delta * (skid * multiplier))
    self:get('move'):add_accel(delta * (multiplier / dt))
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

    -- State --
    -- 2 when initially jumping, 1 when continuing a jump, 0 when abandoning a jump
    -- TODO probably split out the "still jumping" state, which might even let us ditch was_launched
    decision = 0,
    -- The number of jumps this actor has made so far without touching the
    -- ground, including an initial fall
    consecutive_jump_count = 0,
}

-- FIXME needs to accept max jumps
function Jump:init(actor, args)
    Jump.__super.init(self, actor, args)

    self.speed = args.speed or 0
    self.abort_multiplier = args.abort_multiplier or 0
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
    if fall.grounded then
        self.consecutive_jump_count = 0
    end

    -- Jumping
    -- This uses the Sonic approach: pressing jump immediately sets (not
    -- increases!) the player's y velocity, and releasing jump lowers the y
    -- velocity to a threshold
    if self.decision == 2 then
        self.decision = 1
        if move.velocity.y <= -self.speed then
            -- Already moving upwards at jump speed, so nothing to do
            return
        end

        -- You can "jump" off a ladder, but you just let go.  Only works if
        -- you're holding a direction or straight down
        -- FIXME move this to controls, get it out of here
        local climb = self:get('climb')
        if climb and climb.is_climbing then
            if climb.decision > 0 or self:get('walk').decision ~= Vector.zero then
                -- Drop off
                climb.is_climbing = false
            end
            return
        end

        if self.consecutive_jump_count == 0 and not fall.ground_shallow and not climb.is_climbing then
            -- If we're in mid-air for some other reason, act like we jumped to
            -- get here, for double-jump counting purposes
            self.consecutive_jump_count = 1
        end
        if self.consecutive_jump_count >= self.max_jumps then
            -- No more jumps left
            return
        end

        -- Perform the actual jump
        move.pending_velocity.y = -self.speed
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
        climb.is_climbing = false
        climb.climbing = nil
        climb.decision = 0
        return true
    elseif self.decision == 0 then
        -- We released jump at some point, so cut our upwards velocity
        if not fall.grounded and not fall.was_launched then
            move.pending_velocity.y = math.max(move.pending_velocity.y, -self.speed * self.abort_multiplier)
        end
    end
end


-- Climb
-- TODO this should disable gravity, but that's currently done in Fall, which seems...  extreeeemely hokey to me.  honestly this seems like it completely changes the physics "mode", but that's not a concept i really have anywhere yet
local Climb = Component:extend{
    slot = 'climb',

    -- Configuration --
    -- Speed of movement while climbing
    speed = 128,

    -- State --
    is_climbing = false,
}

function Climb:init(actor, args)
    Climb.__super.init(self, actor, args)

    self.speed = args.speed
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

function Climb:on_collide_with(collision)
    -- Ignore collision with one-way platforms when climbing ladders, since
    -- they tend to cross (or themselves be) one-way platforms
    if collision.their_owner.one_way_direction and self.is_climbing then
        return true
    end
end

function Climb:after_collisions(movement, collisions)
    -- Check for whether we're touching something climbable
    for _, collision in ipairs(collisions) do
        local obstacle = collision.their_owner
        -- TODO i wonder if climbability should be a component, the way interactability is
        if obstacle and obstacle.is_climbable then
            -- The reason for the up/down distinction is that if you're standing at
            -- the top of a ladder, you should be able to climb down, but not up
            -- FIXME these seem like they should specifically grab the highest and lowest in case of ties...
            -- FIXME aha, shouldn't this check if we're overlapping /now/?
            -- FIXME this is super not gonna work for "climbing" sideways
            if collision.overlapped or collision:faces(Vector(0, -1)) then
                self.actor.ptrs.climbable_down = obstacle
                self.on_climbable_down = collision
            end
            if collision.overlapped or collision:faces(Vector(0, 1)) then
                self.actor.ptrs.climbable_up = obstacle
                self.on_climbable_up = collision
            end
        end

        -- If we're climbing downwards and hit something (i.e., the ground), let go
        -- FIXME more generally, we should stop climbing if we're not touching a climbable actor any more?
        -- FIXME gravity hardcoded
        if self.is_climbing and self.decision > 0 and not collision.passable and collision:faces(Vector(0, -1)) then
            self.is_climbing = false
            self.climbing = nil
            -- FIXME is this necessary?
            self.decision = 0
        end
    end
end

function Climb:update(dt)
    local move = self:get('move')

    -- Immunity to gravity while climbing is handled via get_gravity_multiplier
    -- FIXME not any more it ain't
    -- FIXME down+jump to let go, but does that belong here or in input handling?  currently it's in both and both are awkward
    -- TODO does climbing make sense in no-gravity mode?
    if self.decision then
        if math.abs(self.decision) == 2 or (math.abs(self.decision) == 1 and self.is_climbing) then
            -- Trying to grab a ladder for the first time.  See if we're
            -- actually touching one!
            -- FIXME Note that we might already be on a ladder, but not moving.  unless we should prevent that case in decide_climb?
            if self.decision < 0 and self.actor.ptrs.climbable_up then
                self.actor.ptrs.climbing = self.actor.ptrs.climbable_up
                self.is_climbing = true
                self.climbing = self.on_climbable_up
                self.decision = -1
            elseif self.decision > 0 and self.actor.ptrs.climbable_down then
                self.actor.ptrs.climbing = self.actor.ptrs.climbable_down
                self.is_climbing = true
                self.climbing = self.on_climbable_down
                self.decision = 1
            else
                -- There's nothing to climb!
                self.is_climbing = false
            end
        end
        -- FIXME handle all yon cases, including the "is it possible" block above
        if self.is_climbing then
            -- We have no actual velocity...  unless...  sigh
            -- TODO part of the point of this is to undo movement from Walk, which (a) makes it a /separate/ hack from disabling gravity, ugh, and (b) doesn't make sense if we're on something we can climb widely
            if self.xxx_useless_climb then
                move.pending_velocity = move.pending_velocity:projectOn(gravity)
            else
                -- XXX should there be a thing to forcibly set velocity?  how
                -- would that affect other components that later try to modify
                -- it?
                move.pending_velocity = Vector()
            end

            -- Slide us gradually towards the center of a ladder
            -- FIXME gravity dependant...?  how do ladders work in other directions?
            local x0, _y0, x1, _y1 = self.climbing.shape:bbox()
            local ladder_center = (x0 + x1) / 2
            -- FIXME uhh, is this the point that should even be snapped...?
            local dx = ladder_center - self.actor.pos.x
            local max_dx = self.speed * dt
            dx = util.sign(dx) * math.min(math.abs(dx), max_dx)

            -- FIXME oh i super hate this var lol, it exists only for fox flux's slime lexy
            -- OH FUCK I CAN JUST USE A DIFFERENT CLIMBING COMPONENT ? ??? ?
            if self.xxx_useless_climb then
                -- Can try to climb, but is just affected by gravity as normal
                move:nudge(Vector(dx, 0))
            elseif self.decision < 0 then
                -- Climbing is done with a nudge, rather than velocity, to avoid
                -- building momentum which would then launch you off the top
                local climb_distance = self.speed * dt

                -- Figure out how far we are from the top of the ladder
                local ladder = self.on_climbable_up
                local separation = ladder.left_separation or ladder.right_separation
                if separation then
                    local distance_to_top = separation * Vector(0, -1)
                    if distance_to_top > 0 then
                        climb_distance = math.min(distance_to_top, climb_distance)
                    end
                end
                move:nudge(Vector(dx, -climb_distance))
            elseif self.decision > 0 then
                move:nudge(Vector(dx, self.speed * dt))
            end

            -- Never flip a climbing sprite, since they can only possibly face in
            -- one direction: away from the camera!
            self.facing = 'right'

            -- We're not on the ground, but this still clears our jump count
            -- FIXME this seems like it wants to say, i'm /kinda/ on the ground.  i'm stable.
            -- FIXME regardless it probably shouldn't be here, there should be a "hit the ground" message
            self:get('jump').consecutive_jump_count = 0
        end
    end

    -- Clear these pointers so collision detection can repopulate them
    self.actor.ptrs.climbable_up = nil
    self.actor.ptrs.climbable_down = nil
    self.actor.on_climbable_up = nil
    self.actor.on_climbable_down = nil
end


-- Use an object
local Interact = Component:extend{
    slot = 'interact',
}

function Interact:decide()
    self.decision = true
end

function Interact:update(dt)
    if not self.decision then
        return
    end

    self.decision = false

    -- FIXME ah, default behavior.
end


local Think = Component:extend{
    slot = 'think',
    priority = -100,
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
        climb:decide(read_key_axis('ascend', 'descend'))
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
        if game.input:pressed('use') then
            interact:decide()
        end
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
}
