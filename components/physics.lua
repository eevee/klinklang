local Vector = require 'klinklang.vendor.hump.vector'

local Component = require 'klinklang.components.base'
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



-- XXX shouldn't need this stuff here...
local CARGO_CARRYING = 'carrying'
local CARGO_PUSHING = 'pushing'
local CARGO_COULD_PUSH = 'pushable'
local CARGO_BLOCKED = 'blocked'

-- Physical existence: the ability to interact with the rest of the world,
-- mostly via collision
local Move = Component:extend{
    slot = 'move',
    priority = 100,

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

    -- State --
    velocity = nil,
    pending_velocity = nil,
    pending_force = nil,
}

function Move:init(actor, args)
    Move.__super.init(self, actor, args)

    self.min_speed = args.min_speed
    self.max_speed = args.max_speed
    self.skip_zero_nudge = args.skip_zero_nudge
    self.is_juggernaut = args.is_juggernaut

    -- Intrinsic velocity as of the last time we moved.  Please don't modify!
    self.velocity = Vector()
    -- TODO effective overall velocity?
    -- Velocity to be used the next time we move.  May include modifications
    -- from other sources, made since the last actual move.  You should make
    -- any velocity change calculations based on 'velocity', but apply them
    -- here.  Or, ideally...
    self.pending_velocity = Vector()
    -- ...make them here.  This is an /acceleration/ to be applied next frame,
    -- and will be integrated appropriately.  ONLY use this for continuous
    -- acceleration (like gravity); DO NOT use it for instantaneous velocity
    -- changes!
    -- FIXME not a force, please rename
    self.pending_force = Vector()
end

-- API for outside code to affect this actor's velocity.
-- By default, this just adds to velocity, but SentientActor makes use of it
-- for variable jump logic.
-- XXX wait that's not true any more lol whoops
function Move:push(dv)
    self.pending_velocity = self.pending_velocity + dv
end

function Move:accelerate(da)
    self.pending_force = self.pending_force + da
end

function Move:update(dt)
    -- Stash our current velocity, before gravity and friction and other
    -- external forces.  This is (more or less) the /attempted/ movement for a
    -- sentient actor, and lingering momentum for any mobile actor, which is
    -- later used for figuring out which objects a pusher was 'trying' to push
    -- FIXME this is used for cargo sigh
    local attempted_velocity = self.velocity

    -- XXX then gravity applies here

    -- This is basically vt + ½at², and makes the results exactly correct, as
    -- long as pending_force contains constant sources of acceleration (like
    -- gravity).  It avoids problems like jump height being eroded too much by
    -- the first tic of gravity at low framerates.  Not quite sure what it's
    -- called, but it's similar to Verlet integration and the midpoint method.
    local dv = self.pending_force * dt
    local frame_velocity = self.pending_velocity + 0.5 * dv
    self.velocity = self.pending_velocity + dv
    self.pending_force = Vector()

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
    -- FIXME restore this of course
    --local fluidres = self:get_fluid_resistance()
    local multiplier = 1

    local attempted = frame_velocity * (dt / multiplier)
    if attempted == Vector.zero and self.skip_zero_nudge then
        return
    end

    -- Collision time!
    local movement, hits = self:nudge(attempted)

    self.actor:each('after_collisions', movement, hits)

    -- Trim velocity as necessary, based on our last slide
    -- FIXME this is clearly wrong and we need to trim it as we go, right?
    if self.velocity ~= Vector.zero then
        self.velocity = Collision:slide_along_normals(hits, self.velocity)
    end

    self.pending_velocity = self.velocity
end

local function _is_vector_almost_zero(v)
    return math.abs(v.x) < 1e-8 and math.abs(v.y) < 1e-8
end

-- Lower-level function passed to the collider to determine whether another
-- object blocks us
-- FIXME now that they're next to each other, these two methods look positively silly!  and have a bit of a symmetry problem: the other object can override via the simple blocks(), but we have this weird thing
function Move:on_collide_with(collision)
    -- Moving away is always fine
    if collision.contact_type < 0 then
        return true
    end

    -- FIXME doubtless need to fix overlap collision with a pushable
    -- One-way platforms only block us when we collide with an
    -- upwards-facing surface.  Expressing that correctly is hard.
    -- FIXME un-xxx this and get it off the shape
    -- FIXME make this less about gravity and more about a direction
    -- FIXME why is this here and not in blocks()??  oh because blocks didn't always take collision, and still isn't documented as such
    if collision.shape._xxx_is_one_way_platform then
        if collision.overlapped or not collision:faces(Vector(0, -1)) then
            return true
        end
    end

    -- Otherwise, fall back to trying blocks()
    return not collision.their_owner:blocks(self.actor, collision)
end

function Move:_collision_callback(collision, pushers, already_hit)
    local obstacle = collision.their_owner

    -- Only announce a hit once per frame
    -- XXX this is once per /nudge/, not once per frame.  should this be made
    -- to be once per frame (oof!), removed entirely, or just have the comment
    -- fixed?
    local hit_this_actor = already_hit[obstacle]
    if obstacle and not hit_this_actor then
        -- FIXME movement is fairly misleading and i'm not sure i want to
        -- provide it, at least not in this order
        obstacle:on_collide(self.actor, movement, collision)
        already_hit[obstacle] = true
    end

    -- Debugging
    if game and game.debug and game.debug_twiddles.show_collision then
        game.debug_hits[collision.shape] = collision
    end

    -- FIXME again, i would love a better way to expose a normal here.
    -- also maybe the direction of movement is useful?
    local passable = self.actor:collect('on_collide_with', collision)

    -- Check for carrying
    local tote = self:get('tote')
    if obstacle and self.actor.can_carry and tote then
        if tote.cargo[obstacle] and tote.cargo[obstacle].state == CARGO_CARRYING then
            -- If the other obstacle is already our cargo, ignore collisions with
            -- it for now, since we'll move it at the end of nudge()
            -- FIXME this is /technically/ wrong if the carrier is blockable, but so
            -- far all of mine are not.  one current side effect is that if you're
            -- on a crate on a platform moving up, and you hit a ceiling, then you
            -- get knocked off the crate rather than the crate being knocked
            -- through the platform.
            return true
        elseif obstacle.is_portable and
            not passable and not collision.overlapped and
            -- TODO gravity
            collision:faces(Vector(0, 1)) and
            not pushers[obstacle]
        then
            -- If we rise into a portable obstacle, pick it up -- push it the rest
            -- of the distance we're going to move.  On its next ground check,
            -- it should notice us as its carrier.
            -- FIXME this isn't quite right, since we might get blocked later
            -- and not actually move this whole distance!  but chances are they
            -- will be too so this isn't a huge deal
            local nudge = collision.attempted * (1 - math.max(0, collision.contact_start))
            if not _is_vector_almost_zero(nudge) then
                obstacle:get('move'):nudge(nudge, pushers)
            end
            return true
        end
    end

    -- Check for pushing
    -- FIXME i'm starting to think this belongs in nudge(), not here, since we don't even know how far we'll successfully move yet
    if obstacle and
        -- It has to be pushable, of course
        self.actor.can_push and obstacle.is_pushable and
        tote and
        -- It has to be in our way (including slides, to track pushable)
        (not passable or passable == 'slide') and
        -- We can't be overlapping...?
        -- FIXME should pushables that we overlap be completely permeable, or what?  happens with carryables too
        not collision.overlapped and
        -- We must be on the ground to push something
        -- FIXME wellll, arguably, aircontrol should factor in.  also, objects
        -- with no gravity are probably exempt from this
        -- FIXME hm, what does no gravity component imply here?
        self:get('fall') and self:get('fall').grounded and
        -- We can't push the ground
        self.actor.ptrs.ground ~= obstacle and
        -- We can only push things sideways
        -- FIXME this seems far too restrictive, but i don't know what's
        -- correct here.  also this is wrong for no-grav objects, which might
        -- be a hint
        -- FIXME this is still wrong.  maybe we should just check this inside the body
        --(not collision.left_normal or collision.left_normal * obstacle:get_gravity() >= 0) and
        --(not collision.right_normal or collision.right_normal * obstacle:get_gravity() >= 0) and
        --(not collision.right_normal or math.abs(collision.right_normal:normalized().y) < 0.25) and
        --(not collision.left_normal or math.abs(collision.left_normal:normalized().y) < 0.25) and
        --(not collision.right_normal or math.abs(collision.right_normal:normalized().y) < 0.25) and
        -- If we already pushed this object during this nudge, it must be
        -- blocked or on a slope or otherwise unable to keep moving, so let it
        -- block us this time
        already_hit[obstacle] ~= 'nudged' and
        -- Avoid a push loop, which could happen in pathological cases
        not pushers[obstacle]
    then
        -- Try to push them along the rest of our movement, which is everything
        -- left after we first touched
        local nudge = collision.attempted * (1 - math.max(0, collision.contact_start))
        -- You can only push along the ground, so remove any component along
        -- the ground normal
        nudge = nudge - nudge:projectOn(self:get('fall').ground_normal)
        -- Only push in the direction the collision occurred!  If several
        -- directions, well, just average them
        local axis
        if collision.left_normal and collision.right_normal then
            axis = (collision.left_normal + collision.right_normal) / 2
        else
            axis = collision.left_normal or collision.right_normal
        end
        if axis then
            nudge = nudge:projectOn(axis)
        else
            nudge = Vector.zero
        end

        -- Snag any existing manifest so we can update it
        -- XXX if we get rid of manifest.velocity then this might not matter, just overwrite it?  but note that we do use expiring == nil to detect new pushes specifically
        local manifest = tote.cargo[obstacle]
        if manifest then
            manifest.expiring = false
        else
            manifest = {}
            tote.cargo[obstacle] = manifest
        end
        manifest.normal = axis

        if _is_vector_almost_zero(nudge) then
            -- We're not actually trying to push this thing, whatever it is, so
            -- do nothing.  But mark down that we /could/ push this object; if
            -- we get pushed from the other side, we need to know about this
            -- object so we can include it in recursive friction and the like.
            manifest.state = CARGO_COULD_PUSH
        else
            -- Actually push the object!
            -- After we do this, its cargo should be populated with everything
            -- /it's/ pushing, which will help us figure out how much to cut
            -- our velocity in our own update()
            print("about to nudge", obstacle, collision.attempted, nudge, obstacle.is_pushable, obstacle.is_portable)
            local actual = obstacle:get('move'):nudge(nudge, pushers)
            -- If we successfully moved it, ask collision detection to
            -- re-evaluate this collision
            if not _is_vector_almost_zero(actual) then
                passable = 'retry'
            end
            -- Mark as pushing even if it's blocked.  For sentient pushers,
            -- this lets them keep their push animation and avoids flickering
            -- between pushing and not; non-sentient pushers will lose their
            -- velocity, not regain it, and be marked as pushable next time.
            manifest.state = CARGO_PUSHING
            already_hit[obstacle] = 'nudged'
        end
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
function Move:nudge(movement, pushers, xxx_no_slide)
    if self.actor.shape == nil then
        error(("Can't nudge actor %s without a collision shape"):format(self.actor))
    end
    if movement.x ~= movement.x or movement.y ~= movement.y then
        error(("Refusing to nudge actor %s by NaN vector %s"):format(self.actor, movement))
    end

    game:time_push('nudge')

    pushers = pushers or {}
    pushers[self.actor] = true

    local collider = self.actor.map.collider
    local shape = self.actor.shape

    -- Set up the hit callback, which also tells other actors that we hit them
    local already_hit = {}
    local pass_callback = function(collision)
        return self:_collision_callback(collision, pushers, already_hit)
    end

    -- Main movement loop!  Try to slide in the direction of movement; if that
    -- fails, then try to project our movement along a surface we hit and
    -- continue, until we hit something head-on or run out of movement.
    local total_movement = Vector.zero
    local hits
    local stuck_counter = 0
    while true do
        local successful
        game:time_push('sweep')
        successful, hits = collider:sweep(shape, movement, pass_callback)
        game:time_pop('sweep')
        shape:move(successful:unpack())
        total_movement = total_movement + successful

        if xxx_no_slide then
            break
        end
        local remaining = movement - successful
        -- FIXME these values are completely arbitrary and i cannot justify them
        if math.abs(remaining.x) < 1/256 and math.abs(remaining.y) < 1/256 then
            break
        end

        -- Find the allowed slide direction that's closest to the direction of movement.
        local slid
        movement, slid = Collision:slide_along_normals(hits, remaining)
        if not slid then
            break
        end

        if math.abs(movement.x) < 1/256 and math.abs(movement.y) < 1/256 then
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

    self.actor.pos = self.actor.pos + total_movement

    -- If we pushed anything, then most likely we caught up with it and now it
    -- has a collision that looks like we hit it.  But we did manage to move
    -- it, so we don't want that to count when cutting our velocity!
    -- So we'll...  cheat a bit, and pretend it's passable for now.
    -- FIXME oh boy i don't like this, but i don't want to add a custom prop
    -- here that Collision has to know about either?
    for _, collision in ipairs(hits) do
        if already_hit[collision.their_owner] == 'nudged' then
            print('! found a nudge', collision.their_owner)
            collision.passable = 'pushed'
        end
    end

    -- Move our cargo along with us, independently of their own movement
    -- FIXME this means our momentum isn't part of theirs!!  i think we could
    -- compute effective momentum by comparing position to the last frame, or
    -- by collecting all nudges...?  important for some stuff like glass lexy
    -- FIXME doesn't check can_carry, because it needs to handle both
    -- XXX this should be in Tote, of course, but where exactly?
    local tote = self:get('tote')
    if tote and not _is_vector_almost_zero(total_movement) then
        for obstacle, manifest in pairs(tote.cargo) do
            if manifest.state == CARGO_CARRYING and self.actor.can_carry then
                obstacle:get('move'):nudge(total_movement, pushers)
            end
        end
    end

    game:time_pop('nudge')

    pushers[self.actor] = nil
    return total_movement, hits
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
    -- FIXME this seems very high, means a velocity < 8 effectively doesn't move at all.  it's a third of the default player accel damn
    friction_decel = 256,
}

function Fall2D:init(actor, args)
    Fall2D.__super.init(self, actor, args)

    self.friction_decel = args.friction_decel
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
    -- Friction multiplier of the ground, or 1 if we're in midair, maybe?
    ground_friction = 1,
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

-- Return the mass of ourselves, plus everything we're pushing or carrying
function Fall:_get_total_friction(direction, _seen)
    direction = direction:normalized()
    if not _seen then
        _seen = {}
    elseif _seen[self] then
        print("!!! FOUND A CARGO LOOP in _get_total_friction", self.actor)
        for k in pairs(_seen) do print('', k) end
        return Vector.zero
    end
    _seen[self] = true

    local friction = self:get('fall'):get_friction(direction)

    local tote = self:get('tote')
    if tote then
        for cargum, manifest in pairs(tote.cargo) do
            if manifest.state ~= CARGO_CARRYING and manifest.normal * direction < 0 then
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
            if manifest.state == CARGO_CARRYING then
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

    -- TODO this feels like it does not belong here, but i don't know how to untangle them better
    local climb = self:get('climb')
    if not (climb and climb.is_climbing) then
        move:accelerate(self:get_base_gravity() * multiplier)
    end

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
    local pending_velocity = move.pending_velocity + move.pending_force * dt
    local friction_force = self:get_friction(pending_velocity)
    -- Add up all the friction of everything we're pushing (recursively, since
    -- those things may also be pushing/carrying things)
    -- FIXME each cargo is done independently, so there's a risk of counting
    -- twice?  is there a reason we can't just call _get_total_friction on
    -- ourselves here?
    -- XXX uhh how do we get cargo to override this or whatever
    local tote = self:get('tote')
    if tote then
        for cargum, manifest in pairs(tote.cargo) do
            if (manifest.state == CARGO_PUSHING or manifest.state == CARGO_COULD_PUSH) and manifest.normal * attempted_velocity < -1e-8 then
                local cargo_friction_force = cargum:get('fall'):_get_total_friction(-manifest.normal)
                friction_force = friction_force + cargo_friction_force -- FIXME * tote.push_resistance_multiplier
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
        move:push(friction_delta:trimmed(pending_velocity * friction_delta1))
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
                    if obstacle.can_carry and self.actor.is_portable then
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
    -- FIXME do i want this...?  actor.ptrs.ground = actor
    self.ground_friction = friction or 1
    self.ground_terrain = terrain

    -- XXX this all super doesn't belong here, /surely/
    -- XXX i'm not sure this is even necessary
    -- XXX cargo_of is very suspicious also
    if self.actor.ptrs.cargo_of and self.actor.ptrs.cargo_of ~= carrier then
        self.actor.ptrs.cargo_of:get('tote').cargo[self.actor] = nil
        self.actor.ptrs.cargo_of = nil
    end
    -- TODO i still feel like there should be some method for determining whether we're being carried
    -- TODO still seems rude that we inject ourselves into their cargo also
    if carrier then
        local tote = carrier:get('tote')
        if tote then
            local manifest = tote.cargo[self.actor]
            if manifest then
                manifest.expiring = false
            else
                manifest = {}
                tote.cargo[self.actor] = manifest
            end
            manifest.state = CARGO_CARRYING
            manifest.normal = carrier_normal

            self.actor.ptrs.cargo_of = carrier
        end
    end
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

function SentientFall:check_for_ground(...)
    SentientFall.__super.check_for_ground(self, ...)

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
    if self.actor.ptrs.cargo_of then
        local carrier = self.actor.ptrs.cargo_of
        local manifest = carrier:get('tote').cargo[self.actor]
        if manifest and manifest.normal * gravity - max_slope_dot > 1e-8 then
            carrier.cargo[self] = nil
            self.actor.ptrs.cargo_of = nil
        end
    end
end

function SentientFall:update(dt)
    -- Slope resistance: a sentient actor will resist sliding down a slope
    if not self.grounded then
        SentientFall.__super.update(self, dt)
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
    -- FIXME one wonders if this is really a part of walking and should be included in there, though it'll complicate things since it reacts to the velocity from the previous frame...  if you fall onto a slope you'll never stop under your own power, gravity comes next...
    local slope = self.ground_normal:perpendicular()
    if slope * gravity > 0 then
        slope = -slope
    end
    local slope_resistance = -(gravity * slope)
    local move = self.actor:get('move')
    move:accelerate(slope_resistance * slope)

    -- Do this BEFORE the super call, so that friction can take it into account
    SentientFall.__super.update(self, dt)
end

function SentientFall:after_collisions(movement, collisions)
    local was_on_ground = self.grounded

    SentientFall.__super.after_collisions(self, movement, collisions)

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
        self.actor:get('jump').decision == 0 and not self.actor:get('climb').is_climbing and
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
            local drop_movement, hits = move:nudge(drop, nil, true)
            movement = movement + drop_movement
            self:check_for_ground(hits)
            -- FIXME update outer movement + hits??

            if self.grounded then
                -- Now we're on the ground, so flatten our velocity to indicate
                -- we're walking along it.  Or equivalently, remove the part
                -- that's trying to launch us upwards.
                -- FIXME should this use push?
                move.velocity = move.velocity - move.velocity:projectOn(self.ground_normal)
            end
        end
    end

    if self.grounded then
        self.was_launched = false
    end
end


return {
    Exist = Exist,
    Move = Move,
    Fall2D = Fall2D,
    Fall = Fall,
    SentientFall = SentientFall,
}
