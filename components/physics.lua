local Vector = require 'klinklang.vendor.hump.vector'

local Component = require 'klinklang.components.base'
local components_cargo = require 'klinklang.components.cargo'
local Collision = require 'klinklang.whammo.collision'

-- Physical presence: this thing has a shape and thus exists physically in the
-- map (and its collider)
local Exist = Component:extend{
    slot = 'exist',

    shape = nil,
}

function Exist:init(actor, args)
    Exist.__super.init(self, actor, args)

    self.shape = args.shape
end

function Exist:on_enter(map)
    map.collider:add(self.shape, self.actor)
end

function Exist:on_leave()
    self.actor.map.collider:remove(self.shape)
end


-- Physical existence: the ability to interact with the rest of the world,
-- mostly via collision
local Move = Component:extend{
    slot = 'move',
    priority = -1000,  -- very first thing we do, so our position is sensible for everyone else

    -- Note that all values are given in units of pixels and seconds.

    -- Configuration --
    -- Slowest and fastest speeds an object may move.  Objects moving slower
    -- than min_speed will be stopped; objects moving faster than max_speed
    -- will be capped.
    min_speed = 1,
    max_speed = 1536,
    -- If true, zero nudges are ignored, meaning that collision callbacks
    -- aren't fired.  Appropriate for fixed objects like platforms or
    -- decorations, but not so much for players and critters.
    skip_zero_nudge = false,
    -- If true, this object is unstoppable and cannot be blocked by anything
    -- for any reason.
    -- TODO this used to be is_blockable = false, but i don't remember why i want it, and anyway i could just extend this component a bit?
    -- TODO this means they won't be blocked by the map edges, either...  is that a problem
    is_juggernaut = false,
    -- If we hit a slope, stop there; never try to finish moving along the slope
    never_slide = false,
    -- Scale applied to all movement this object does; its velocity will be
    -- computed the same, but its actual distance traveled will be multiplied
    -- by this.  Obvious use is to set it < 1 for underwater.
    multiplier = 1,

    -- State --
    -- TODO document this better thanks
    -- Intrinsic velocity this actor had, as of the last time it moved
    -- (including during collision callbacks during its movement).  You should
    -- use this any time you care about an actor's velocity.  DO NOT modify
    -- this; it'll break other code and won't change the actor's velocity!
    -- Note that this doesn't include extrinsic movement from e.g. platforms.
    velocity = nil,
    -- Velocity this actor will have after the next move.  May still be in the
    -- process of being updated by other components, so is generally not
    -- reliable to inspect.
    pending_velocity = nil,
    -- Acceleration to apply to this actor just before the next move.  This
    -- generally ought to include only constant acceleration (e.g. gravity...
    -- actually, mostly just gravity), or the velocity integration might get
    -- fucked up.
    pending_accel = nil,
    -- Velocity this actor will use to do the actual next movement.
    pending_integrated_velocity = nil,
}

function Move:init(actor, args)
    Move.__super.init(self, actor, args)

    self.min_speed = args.min_speed
    self.max_speed = args.max_speed
    self.skip_zero_nudge = args.skip_zero_nudge
    self.is_juggernaut = args.is_juggernaut
    self.never_slide = args.never_slide
    self.multiplier = args.multiplier

    -- Intrinsic velocity as of the last time we moved.  Please don't modify!
    self.velocity = Vector()
    -- TODO effective overall velocity?
    -- Velocity to be used the next time we move.  May include modifications
    -- from other sources, made since the last actual move.  You should make
    -- any velocity change calculations based on 'velocity', but apply them
    -- here.  Or, ideally...
    self.pending_velocity = Vector()
    self._pending_velocity_was_reset = false
    self.pending_extrinsic_velocity = Vector()
    self.extrinsic_velocity = Vector()
    -- ...make them here.  This is an /acceleration/ to be applied next frame,
    -- and will be integrated appropriately.  ONLY use this for continuous
    -- acceleration (like gravity); DO NOT use it for instantaneous velocity
    -- changes!
    self.pending_accel = Vector()
    self.pending_integrated_velocity = Vector()
    self.pending_friction = Vector()
end

-- API for outside code to affect this actor's velocity.
-- By default, this just adds to velocity, but SentientActor makes use of it
-- for variable jump logic.
-- XXX wait that's not true any more lol whoops
function Move:push(dv)
    print('push is deprecated')
    self:add_velocity(dv)
end

function Move:add_velocity(dv)
    self.pending_velocity:addi(dv)
end

-- Set velocity in some direction to the given value, unless it's already higher
function Move:max_out_velocity(v)
    local aligned = self.pending_velocity:projectOn(v)
    if aligned * v > 0 and aligned:len2() > v:len2() then
        -- Already higher, leave it alone
        return
    end
    self.pending_velocity:subi(aligned)
    self.pending_velocity:addi(v)
    -- This is a little dubious since we're /mixing/ previous with current pending velocity, but
    -- without this we lose the "max" guarantee.  Consider being bounced by a shroom while walking
    -- up its sloped side: you have upwards velocity from the slope, the shroom bounces you, and
    -- when all's said and done you have more upwards velocity than the max
    self._pending_velocity_was_reset = true
end

-- Same as above, but for minimizing
function Move:clamp_velocity(v)
    local aligned = self.pending_velocity:projectOn(v)
    if aligned * v > 0 and aligned:len2() < v:len2() then
        return
    end
    self.pending_velocity:subi(aligned)
    self.pending_velocity:addi(v)
    self._pending_velocity_was_reset = true
end

function Move:set_velocity(v)
    self.pending_velocity = v
    self._pending_velocity_was_reset = true
end

-- Add velocity to this actor that will be included in its movement, but will NOT be considered part
-- of its "natural" velocity (self.velocity).  Consider a conveyor belt, where the floor itself is
-- moving, which alters your movement relative to the world, but where your walking speed and the
-- like should still be considered as relative to the movement of the floor.
function Move:add_extrinsic_velocity(dv)
    self.pending_extrinsic_velocity:addi(dv)
end

function Move:get_world_velocity()
    return self.velocity + self.extrinsic_velocity
end

function Move:add_accel(da)
    self.pending_accel:addi(da)
end

function Move:add_friction(friction)
    self.pending_friction:addi(friction)
end

function Move:update(dt)
    -- Check if our reference frame changed; if so, we want to adjust our "natural" velocity by this
    -- difference, but either way the entire extrinsic velocity should be part of our motion
    -- FIXME finish this idea.  i would prefer reference frame be explicit rather than built up
    -- every frame, but i don't know what kind of structure would provide that.  also the above
    -- comment is kind of incoherent
    local reference_frame_change = self.pending_extrinsic_velocity - self.extrinsic_velocity

    -- This is basically vt + ½at², and makes the results exactly correct, as
    -- long as pending_accel contains constant sources of acceleration (like
    -- gravity).  It avoids problems like jump height being eroded too much by
    -- the first tic of gravity at low framerates.  Not quite sure what it's
    -- called, but it's similar to Verlet integration and the midpoint method.
    local dv = self.pending_accel * dt
    -- intrinsic only!
    --print("\27[33m** MOVE **", self.actor, self.pending_velocity, self.pending_extrinsic_velocity, reference_frame_change, "\27[0m")
    -- TODO should friction apply /before/ acceleration, maybe?  otherwise if you're moving slowly up a slope, gravity pulls you down, and then friction pushes you back /up/ which is kind of weird?  comes up when pushing things...
    -- TODO shouldn't this be pending_extrinsic_velocity?  or no, because pending_velocity is
    -- relative to our previous extrinsic velocity?
    local frame_velocity = self.pending_velocity + self.extrinsic_velocity + 0.5 * dv
    --print('. initial frame velocity', frame_velocity)
    self.velocity = self.pending_velocity - reference_frame_change + dv
    -- Friction is very sensitive to small numbers that can become zero
    if self.pending_friction:len2() > 1e-8 and dt > 1e-8 then
        local friction_decel = self.pending_friction * dt
        local friction_direction = friction_decel:trimmed(1)

        -- FIXME this only counts against intrinsic velocity, when it should really count against floor-relative velocity, urgh
        local frame_dot = frame_velocity * friction_direction * 0.5
        local frame_friction = friction_decel:trimmed(frame_dot)
        --print('. frame friction', frame_friction)
        if frame_dot > 0 then
            frame_velocity:subi(frame_friction)
        else
            frame_velocity:addi(frame_friction)
        end

        local perma_dot = self.velocity * friction_direction
        local perma_friction = friction_decel:trimmed(perma_dot)
        if perma_dot > 0 then
            self.velocity:subi(perma_friction)
        else
            self.velocity:addi(perma_friction)
        end
    end
    local reference_frame = self.pending_extrinsic_velocity
    self.pending_velocity = Vector()
    self._pending_velocity_was_reset = false
    self.extrinsic_velocity = self.pending_extrinsic_velocity
    self.pending_extrinsic_velocity = Vector()
    self.pending_accel = Vector()
    self.pending_friction = Vector()

    local speed = self.velocity:len()
    if speed < self.min_speed then
        self.velocity.x = 0
        self.velocity.y = 0
    elseif speed > self.max_speed then
        self.velocity:trimInplace(self.max_speed)
    end

    -- FIXME how does terminal velocity apply to integration?  if you get
    -- launched Very Fast the integration will take some of it into account
    -- still

    local attempted = frame_velocity * (dt * self.multiplier)
    if attempted == Vector.zero and self.skip_zero_nudge then
        return
    end

    -- Very very special case: when something is on flat ground and not moving horizontally, try to
    -- round it to the nearest pixel.  This fixes camera jitter on the player and makes it possible
    -- to (juuust barely) push an object so it'll fall down a hole exactly the same width.
    local fall = self:get('fall')
    if fall and math.abs(attempted.x) < 1e-6 and fall.grounded and fall.ground_normal == Vector(0, -1) then
        local offset = self.actor.pos.x
        local carrier = self.actor.ptrs.cargo_of
        if carrier then
            offset = offset - carrier.pos.x
        end

        offset = offset - math.floor(offset)
        if offset > 0.5 then
            offset = offset - 1
        end

        -- FIXME ah, this causes a crate to try to push back against you while you're pushing it, because it thinks it's not moving
        --attempted.x = -offset
    end

    -- Collision time!
    -- XXX pending_velocity isn't read-reliable in this window, but i don't know how it could be since this is where we calculate it anyway
    --print('. resolved new velocity as', self.velocity, 'and frame velocity as', frame_velocity)
    --print('. performing main nudge', attempted)
    local movement, all_hits = self:nudge(attempted)
    --print('. finished main nudge', movement)

    -- Trim velocity as necessary, based on our slides
    -- FIXME this is clearly wrong and we need to trim it as we go, right?
    -- XXX note that this happens /after/ the velocity redist from pushing...
    for _, hits in ipairs(all_hits) do
        if self.velocity == Vector.zero then
            break
        end
        self.velocity = Collision:slide_along_normals(hits, self.velocity)
    end

    -- Add the final slid velocity to next frame's velocity, /unless/
    -- set_velocity was called during nudge()
    if not self._pending_velocity_was_reset then
        self.pending_velocity:addi(self.velocity)
    end
end

local function _is_vector_almost_zero(v)
    return math.abs(v.x) < 1e-8 and math.abs(v.y) < 1e-8
end

-- Lower-level glue function passed to the collider; acts as a conduit between the collider's dumb
-- shape-pushing logic and the higher-level actor code
function Move:_collision_callback(collision, pushers)
    local obstacle = collision.their_owner

    -- Debugging
    if game and game.debug and game.debug_twiddles.show_collision then
        game.debug_hits[collision.shape] = collision
    end

    -- FIXME again, i would love a better way to expose a normal here.
    -- also maybe the direction of movement is useful?
    local passable = not self.actor.map:check_blocking(self.actor, collision.their_owner, collision)

    -- It's possible, but discouraged, for on_collide_with to override passable; this is only really
    -- used by Tote, which can force a retry
    -- FIXME can we have it assign to collision.passable instead?
    local passable2 = self.actor:collect('on_collide_with', collision, passable, pushers)
    if passable2 ~= nil then
        passable = passable2
    end

    -- Announce to whatever we hit
    -- XXX this used to be once per nudge only, but the way i'm using it for fox flux's signs
    -- requires doing it on each hit!  hope that doesn't break anything lol!!
    -- It is again possible, but discouraged, for on_collide to override passable; this is helpful
    -- for very complex blocking logic, such as that in fox flux's signs, which does a raycast (!)
    -- FIXME movement argument is gone
    -- FIXME we don't know success state until after this function returns, which is annoying
    passable2 = obstacle:on_collide(self.actor, nil, collision, passable)
    if passable2 ~= nil then
        passable = passable2
    end

    if self.is_juggernaut and not passable then
        return true
    else
        return passable
    end
end

-- Move some distance, respecting collision.
-- No other physics like gravity or friction happen here; only the actual movement.
-- FIXME a couple remaining bugs:
-- - player briefly falls when standing on a crate moving downwards -- one frame?
-- - what's the difference between carry and push, if a carrier can push?
-- FIXME i do feel like more of this should be back in whammo; i don't think the below loop is especially necessary to have here, for example
function Move:nudge(movement, no_slide, pushers)
    if self.actor.shape == nil then
        error(("Can't nudge actor %s without a collision shape"):format(self.actor))
    end
    if movement.x ~= movement.x or movement.y ~= movement.y then
        error(("Refusing to nudge actor %s by NaN vector %s"):format(self.actor, movement))
    end

    local tote = self:get('tote')
    game:time_push('nudge')

    pushers = pushers or {}
    pushers[self.actor] = pushers[self.actor] or {}

    local collider = self.actor.map.collider
    local shape = self.actor.shape

    -- Set up the hit callback, which also tells other actors that we hit them
    local pass_callback = function(collision)
        return self:_collision_callback(collision, pushers)
    end

    -- Main movement loop!  Try to slide in the direction of movement; if that
    -- fails, then try to project our movement along a surface we hit and
    -- continue, until we hit something head-on or run out of movement.
    local total_movement = Vector()
    local all_hits = {}
    local stuck_counter = 0
    while true do
        game:time_push('sweep')
        local successful, hits = collider:sweep(shape, movement, pass_callback)
        game:time_pop('sweep')
        table.insert(all_hits, hits)
        -- XXX save a bit of effort, don't do this if it's zero, or maybe make shape:move do that
        shape:move(successful:unpack())
        total_movement:addi(successful)

        if no_slide or self.never_slide then
            break
        end
        local remaining = movement - successful
        -- Skip movement that's less than a tiny fraction of a pixel.
        -- This is somewhat arbitrary, but it should avoid some issues where something moves one
        -- pixel every few seconds (which looks bad), and it fixes strange behavior like trying to
        -- walk up a slope into a vertical wall and constantly doing tiny jumps due to sliding
        -- FIXME maybe should be framerate-sensitive?  otherwise this is a bad solution to walking
        -- up a wall
        if remaining:len2() < 1/64 then  -- i.e., remaining is less than 1/8
            break
        end

        -- Find the allowed slide direction that's closest to the direction of movement.
        local slid
        movement, slid = Collision:slide_along_normals(hits, remaining)
        -- Give up here if...
        if
            -- we were blocked...
            not slid or
            -- we have barely any movement left...
            (math.abs(movement.x) < 1/256 and math.abs(movement.y) < 1/256) or
            -- or our movement didn't change at all.
            -- (This one happens when we're pushing an object and it doesn't
            -- move, but we set no_slide on the collision.  Hmm.  FIXME?)
            movement == remaining
        then
            break
        end

        -- Automatically break if we don't move for three iterations -- not
        -- moving once is okay because we might slide, but three indicates a
        -- bad loop somewhere
        if _is_vector_almost_zero(successful) then
            stuck_counter = stuck_counter + 1
            if stuck_counter >= 3 then
                if game.debug then
                    print("!!!  BREAKING OUT OF LOOP BECAUSE WE'RE STUCK, OOPS", self.actor, movement, remaining)
                end
                break
            end
        end
    end

    self.actor.pos:addi(total_movement)

    game:time_pop('nudge')
    --print('> end nudge', total_movement)

    self.actor:each('after_collisions', total_movement, all_hits[#all_hits], pushers)

    return total_movement, all_hits
end


-- Affected by gravity.  This is where the test for "is on the ground" lives.
-- This also includes friction code, since friction is only modelled against
-- the ground.
-- This base class is effectively a dummy case for top-down style (or,
-- occasionally, objects in a sidescroller that completely ignore gravity); it
-- applies simple friction and reports that the object is always 'grounded'.
-- TODO dunno how much i've thought that through
local Fall2D = Component:extend{
    slot = 'fall',

    -- Configuration --
    -- Base acceleration (not force) caused by friction.  Note that friction
    -- only comes into play against the ground.
    -- Actors with Walk generally want to set this to 0, since walking makes
    -- use of friction to work!
    friction_decel = 256,
    -- Multiplier for friction.  You generally want to adjust this, rather than
    -- friction_decel.  Greater than 1 is muddy, less than 1 is icy.
    -- This is multiplied with the ground's 'grip_multiplier', if any.
    -- Note that the Walk behavior also makes use of this
    grip = 1,

    -- State --
    grounded = nil,
}

function Fall2D:init(actor, args)
    Fall2D.__super.init(self, actor, args)

    self.friction_decel = args.friction_decel
    self.grip = args.grip
end

function Fall2D:get_friction(normalized_direction)
    -- In top-down mode, everything is always on flat ground, so
    -- friction is always the full amount, away from velocity
    -- FIXME should be carried mass...?
    return normalized_direction:normalized() * (-self.friction_decel * self.actor.mass)
end


-- Gravity for the sidescroller case.  Rather more complicated.
local Fall = Fall2D:extend{
    slot = 'fall',
    priority = 99,

    -- Configuration --
    -- Multiplier applied to the normal acceleration due to gravity.
    multiplier = 1,
    -- Same, but only when moving downwards.  Note that this AND the above
    -- multiplier both apply.
    multiplier_down = 1,

    -- State --
    -- TODO list them here
    ground_normal = nil,
    -- Friction multiplier of the ground, or 1 if we're in midair, maybe?
    ground_friction = 1,
    ground_grip = 1,
    ground_terrain = nil,
}

function Fall:init(actor, args)
    Fall.__super.init(self, actor, args)

    -- FIXME are these actually used for anything interesting?  pooltoy i guess, but i think by far the most common use is just to disable gravity, which...  is...  much easier now...
    self.multiplier = args.multiplier
    self.multiplier_down = args.multiplier

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
function Fall:get_friction(normalized_direction)
    if self.ground_normal then
        local gravity1 = self:get_base_gravity():normalized()
        -- Get the strength of the normal force by dotting the ground normal
        -- with gravity
        local normal_strength = gravity1 * self.ground_normal * self:_get_carried_mass()
        local friction = self.ground_normal:perpendicular() * (self.friction_decel * self.grip * self.ground_grip * self.ground_friction * normal_strength)
        -- TODO i commented this out at some point and can't remember why, or why it's here
        do return friction end
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

-- Return the mass of ourselves, plus everything we're pushing or carrying
function Fall:_get_total_friction(direction, _seen)
    direction = direction:normalized()
    if not _seen then
        _seen = {}
    elseif _seen[self.actor] then
        print("!!! FOUND A CARGO LOOP in _get_total_friction", self.actor)
        for k in pairs(_seen) do print('', k) end
        return Vector.zero
    end
    _seen[self.actor] = true

    local friction = self:get_friction(direction)

    local tote = self:get('tote')
    if tote then
        for cargum, manifest in pairs(tote.cargo) do
            if manifest:is_moved_in_direction(direction) then
            --if manifest.state ~= CARGO_CARRYING and manifest.normal * direction < 0 then
                friction = friction + cargum:get('fall'):_get_total_friction(direction, _seen)
            end
        end
    end
    --print("- " .. tostring(self), friction:projectOn(direction), self:_get_total_mass(direction), friction:projectOn(direction) / self:_get_total_mass(direction), __v)
    return friction
end

-- XXX this is only used here; how is it different from _get_total_mass?  that one also includes stuff we're pushing, but if this is used for friction...?
function Fall:_get_carried_mass(_seen)
    if not _seen then
        _seen = {}
    elseif _seen[self] then
        print("!!! FOUND A CARGO LOOP in _get_carried_mass", self)
        for k in pairs(_seen) do print('', k) end
        return 0
    end
    _seen[self] = true

    local mass = self.actor.mass
    local tote = self:get('tote')
    if tote then
        for cargum, manifest in pairs(tote.cargo) do
            if manifest.state == 'carrying' then
                mass = mass + cargum:get('fall'):_get_carried_mass(_seen)
            end
        end
    end
    return mass
end

function Fall:update(dt)
    Fall.__super.update(self, dt)

    -- Apply gravity
    -- TODO factor the ground_friction constant into this, and also into slope
    -- resistance
    local move = self:get('move')
    local multiplier = self.multiplier
    -- TODO gravity dependence
    if move.velocity.y >= 0 then
        multiplier = multiplier * self.multiplier_down
    end

    -- Also apply any on-ground gravity caused by cargo
    -- XXX i don't know if this is right at all
    local tote = self:get('tote')
    if tote then
        for cargum, manifest in pairs(tote.cargo) do
        end
    end

    move:add_accel(self:get_base_gravity() * multiplier)

    -- FIXME this was a good idea but components break it, so, now what?  is it
    -- ok if this doesn't include deliberate movement?
    local attempted_velocity = move.velocity

    -- Friction -- the general tendency for objects to decelerate when gliding
    -- against something else.  It always pushes against the direction of
    -- motion, but never so much that it would reverse the motion.
    -- This is complicated somewhat by pushing; when we're pushing something,
    -- our velocity is the velocity of the entire system, so we're affected by
    -- the friction of everything we're pushing, too.  Unlike most of this
    -- physics code, mass actually matters here, so express this as force.
    -- FIXME this very much seems like it should be a pending force, but that
    -- makes capping it a whole lot trickier
    -- FIXME this is /completely/ irrelevant for something with constant
    -- velocity (like a moving platform) or something immobile
    -- XXX there's cargo stuff in here
    -- XXX frame_velocity and attempted_velocity don't exist yet, figure that out
    -- XXX i think this might need to happen just before Move, so that friction can be capped appropriately?
    -- XXX or...  just after Move?
    local pending_velocity = move.pending_velocity + move.pending_accel * dt
    local friction_force = self:get_friction(pending_velocity)
    -- Add up all the friction of everything we're pushing (recursively, since
    -- those things may also be pushing/carrying things)
    -- FIXME each cargo is done independently, so there's a risk of counting
    -- twice?  is there a reason we can't just call _get_total_friction on
    -- ourselves here?
    -- XXX uhh how do we get cargo to override this or whatever
    local tote = self:get('tote')
    tote = nil
    if tote then
        for cargum, manifest in pairs(tote.cargo) do
            -- FIXME if Walkers tend to have zero friction of their own, won't they be really bad at resisting pushers ramming into them
            -- FIXME handle corners better here
            if manifest:is_moved_in_direction(pending_velocity) then
            --if (manifest.state == CARGO_PUSHING or manifest.state == CARGO_COULD_PUSH) and manifest.normal * pending_velocity < -1e-8 and not (manifest.left_normal and manifest.right_normal) then
                local cargo_friction_force = cargum:get('fall'):_get_total_friction(-manifest.normal)
                -- XXX this doesn't work against a corner because it thinks we're moving downwards into it fuckin hell
                friction_force:addi(cargo_friction_force)  -- FIXME * tote.push_resistance_multiplier
                -- TODO maybe friction should come last, when we know exactly what the state of the world is?
            end
        end
    end
    -- Apply the friction to ourselves.  Note that both our ongoing velocity
    -- and our instantaneous frame velocity need updating, since friction has
    -- the awkward behavior of never reversing motion
    if friction_force ~= Vector.zero then
        -- FIXME should this project on velocity, project on our ground, or not project at all?
        -- FIXME hey um what about the force of pushing a thing uphill
        local total_mass
        if tote then
            total_mass = tote:_get_total_mass(attempted_velocity)
        else
            total_mass = self.actor.mass
        end
        local friction_delta = friction_force * (dt / total_mass)
        local friction_delta1 = friction_delta:normalized()
        -- FIXME if you're trying to skid to a halt, you'll now be hit by BOTH Walk's decel AND friction.
        -- (a) this is arguably wrong because walk decel is friction anyway
        -- (b) this ultimately pushes you against your old velocity, so maybe this should trim to pending velocity?  but we don't really know what that is, either, since there's also pending force.  also we can't guarantee this happens last, but it /can't/ overshoot.  so what do i do?  causes an ugly jitter sometimes if something is oscillating across a pixel boundary
        --print('friction', friction_delta, friction_delta:trimmed(pending_velocity * friction_delta1), 'vs', pending_velocity)
        --print('... total frictional force', friction_force, 'total mass', total_mass)
        move:add_friction(friction_force / total_mass)
        --move:add_velocity(friction_delta:trimmed(pending_velocity * friction_delta1))
        --frame_velocity = frame_velocity + friction_delta:trimmed(frame_velocity * friction_delta1)
    end
end

function Fall:after_collisions(movement, collisions)
    self:check_for_ground(collisions)
end

function Fall:check_for_ground(hits)
    local gravity = self:get_base_gravity()

    -- Ground test: did we collide with something facing upwards?
    -- Find the normal that faces /most/ upwards, i.e. most away from gravity.
    -- FIXME is that right?  isn't ground the flattest thing you're on?
    -- FIXME what if we hit the ground, then slid off of it?
    local mindot = 0  -- 0 is vertical, which we don't want
    local normal
    local obstacle
    local friction
    local grip
    local terrain
    local carrier
    local carrier_normal
    for _, collision in ipairs(hits) do
        -- Super special case: if we're standing on a platform that moves upwards, it'll nudge us
        -- upwards (either as part of its own movement, or afterwards), this method will be called,
        -- we'll no longer be colliding with anything downwards (since we're moving up!), and we'll
        -- become detached from it.  If we see this case, abort immediately, which will leave all
        -- the ground twiddles as they were.
        if collision.their_owner and
            collision.their_owner == self.actor.ptrs.cargo_of and
            collision.overlapped and
            math.abs(collision.contact_end - 1) < 1e-6
        then
            return
        end

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
                    grip = obstacle.grip_multiplier
                    terrain = obstacle.terrain_type
                    if obstacle.can_carry and self.actor.is_portable then
                        carrier = obstacle
                        carrier_normal = norm
                    end
                else
                    -- TODO should we use the friction from every ground we're on...?  that would be bad if we were straddling.  geometric mean?
                    friction = nil
                    grip = nil
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
                    if not (obstacle and obstacle == self.actor.ptrs.ground) then
                        obstacle = obstacle2
                    end

                    -- Use the HIGHEST of any friction multiplier we're touching
                    -- FIXME should friction just be a property of terrain type?  where would that live, though?
                    if friction and obstacle2.friction_multiplier then
                        friction = math.max(friction, obstacle2.friction_multiplier)
                    else
                        friction = obstacle2.friction_multiplier
                    end
                    if grip and obstacle2.grip_multiplier then
                        grip = math.max(grip, obstacle2.grip_multiplier)
                    else
                        grip = obstacle2.grip_multiplier
                    end

                    -- FIXME what does this do for straddling?  should do
                    -- whichever was more recent, but that seems like a Whole
                    -- Thing.  also should this live on TiledMapTile instead of
                    -- being a general feature?
                    terrain = obstacle2.terrain_type or terrain

                    -- Prefer to stay on the same carrier
                    if obstacle2.can_carry and self.actor.is_portable and not (carrier and carrier == self.actor.ptrs.cargo_of) then
                        carrier = obstacle2
                        carrier_normal = norm
                    end
                end
            end
        end
    end

    self.grounded = not not normal
    self.ground_normal = normal
    self.actor.ptrs.ground = obstacle
    self.ground_friction = friction or 1
    self.ground_grip = grip or 1
    self.ground_terrain = terrain

    -- XXX this all super doesn't belong here, /surely/
    -- XXX i'm not sure this is even necessary
    -- XXX cargo_of is very suspicious also
    -- XXX this doesn't expire naturally...
    if self.actor.ptrs.cargo_of and self.actor.ptrs.cargo_of ~= carrier then
        self.actor.ptrs.cargo_of:get('tote'):detach(self.actor)
    end
    -- TODO i still feel like there should be some method for determining whether we're being carried
    -- TODO still seems rude that we inject ourselves into their cargo also
    if carrier then
        local tote = carrier:get('tote')
        if tote then
            tote:attach(self.actor, 'carrying', carrier_normal)
        end
    end
end

function Fall:is_slope_steep(ground_normal)
    return false
end


-- Gravity for sentient actors; includes extra behavior for dealing with slopes
local SentientFall = Fall:extend{
    -- Configuration --
    -- Steepest slope that an actor can stand on.  If they stand on anything
    -- steeper, 'grounded' will be false, and they'll be treated as though
    -- they're in midair
    max_slope = Vector(1, -1):normalized(),

    -- State --
    -- TODO with 'grounded', not sure if i need this
    ground_shallow = false,
}

function SentientFall:init(actor, args)
    SentientFall.__super.init(self, actor, args)

    self.max_slope = args.max_slope
end

function SentientFall:check_for_ground(collisions)
    SentientFall.__super.check_for_ground(self, collisions)

    local gravity = self:get_base_gravity()
    local max_slope_dot = self.max_slope * gravity
    -- Sentient actors get an extra ground property, indicating whether the
    -- ground they're on is shallow enough to stand on; if not, they won't be
    -- able to jump, they won't have slope resistance, and they'll pretty much
    -- act like they're falling
    -- FIXME ah i set this to (2, -1) for someone and it doesn't actually work.  what
    self.ground_shallow = self.ground_normal and not (self.ground_normal * gravity - max_slope_dot > 1e-8)
    if self.grounded and not self.ground_shallow then
        -- For generic purposes, we're not standing on the ground any more...
        -- with one exception: if we're blocked on both sides, then we're
        -- wedged between two steep slopes, so we can't fall any more, which is
        -- a pretty solid definition of being grounded!
        -- TODO i wonder if in that case we should even consider the "normal"
        -- to be straight up?
        local blocked_left, blocked_right
        for _, collision in ipairs(collisions) do
            if collision.passable ~= true then
                if collision.left_normal then
                    blocked_left = true
                end
                if collision.right_normal then
                    blocked_right = true
                end
            end
        end
        if blocked_left and blocked_right then
            self.ground_shallow = false
        else
            self.grounded = false
        end
    end

    -- Also they don't count as cargo if the contact normal is too steep
    -- TODO this is kind of weirdly inconsistent given that it works for
    -- non-sentient actors...?  should max_slope get hoisted just for this?
    if self.actor.ptrs.cargo_of then
        local carrier = self.actor.ptrs.cargo_of
        local manifest = carrier:get('tote').cargo[self.actor]
        if manifest and manifest.normal * gravity - max_slope_dot > 1e-8 then
            carrier:get('tote'):detach(self.actor)
        end
    end
end

function SentientFall:is_slope_steep(ground_normal)
    local gravity = self:get_base_gravity()
    return ground_normal * gravity - self.max_slope * gravity > 1e-8
end

function SentientFall:after_collisions(movement, collisions)
    local prev_ground_normal = self.ground_normal

    SentientFall.__super.after_collisions(self, movement, collisions)

    local gravity = self:get_base_gravity()

    -- Ground adherence
    -- If we walk up off the top of a hill, our momentum will carry us into the
    -- air, which looks very silly; a sentient actor would simply step down
    -- onto the downslope.  So if we're only a very short distance above the
    -- ground, AND we were on the ground before moving, AND our movement was
    -- exactly along the ground (i.e. perpendicular to the previous ground
    -- normal), then stick us to the floor.
    -- TODO this will activate even if we're artificially launched horizontally
    -- TODO i suspect this could be avoided with the same (not yet written)
    -- logic that would keep critters from walking off of ledges?  or if
    -- the loop were taken out of collider.slide and put in here, so i could
    -- just explicitly slide in a custom direction
    -- FIXME we seem to do rapid drops when walking atop a circle now...  sigh
    -- FIXME the real logic here is: if i'm //walking// (i.e. this is a normal move update) and nothing else had pushed me away from the ground since last frame, then stick to the ground.  it would be lovely to actually implement that
    -- FIXME ah another problem, this `if` doesn't trigger at all if i walk on a slope into a wall and get slid straight up it
    if prev_ground_normal and not self.ground_normal and
        math.abs(prev_ground_normal * movement) < 1e-6 and
        self.multiplier > 0 and self.multiplier_down > 0
    then
        -- How far to try dropping is pretty fuzzy, but a decent assumption is
        -- that we can't make more than a quarter-turn in one step, so
        -- effectively: rotate our movement by 90 degrees and take the
        -- downwards part
        -- FIXME gravity direction dependent
        local drop = Vector(0, math.abs(movement.x))

        -- Try dropping our shape, just to see if we /would/ hit anything, but
        -- without firing any collision triggers or whatever.  Try moving a
        -- little further than our max, just because that's an easy way to
        -- distinguish exactly hitting the ground from not hitting anything.
        -- TODO this all seems a bit ad-hoc, like the sort of thing that oughta be on Map
        local prelim_movement = self.actor.map.collider:sweep(self.actor.shape, drop * 1.1, function(collision)
            if collision.contact_type <= 0 then
                return true
            end
            local obstacle = collision.their_owner
            if obstacle == self.actor then
                return true
            end
            if obstacle then
                return not obstacle:blocks(self.actor, collision)
            else
                return false
            end
        end)

        if prelim_movement:len2() <= drop:len2() then
            local move = self.actor:get('move')
            -- We hit the ground!  Do that again, but for real this time.
            local _, all_hits = move:nudge(drop, true)
            self:check_for_ground(all_hits[#all_hits])
            -- FIXME update outer movement + hits??

            if self.grounded then
                -- Now we're on the ground, so flatten our velocity to indicate
                -- we're walking along it.  Or equivalently, remove the part
                -- that's trying to launch us upwards.
                -- This is a LITTLE tricky, because if we're being called from
                -- Move:update, then our actual movement was down into the old
                -- ground (due to gravity), and that will be slid away before
                -- our velocity change here is applied.  So we need to take
                -- that into account first.
                -- XXX if we AREN'T being called from Move:update, then...?
                move:add_velocity(-move.velocity:projectOn(prev_ground_normal:perpendicular()):projectOn(self.ground_normal))
            end
        end
    end
end


return {
    Exist = Exist,
    Move = Move,
    Fall2D = Fall2D,
    Fall = Fall,
    SentientFall = SentientFall,
}
