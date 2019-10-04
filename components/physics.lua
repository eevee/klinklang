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



-- XXX shouldn't need this stuff here...
local CARGO_CARRYING = 'carrying'
local CARGO_PUSHING = 'pushing'
local CARGO_COULD_PUSH = 'pushable'
local CARGO_BLOCKED = 'blocked'

-- Physical existence: the ability to interact with the rest of the world,
-- mostly via collision
local Move = Component:extend{
    slot = 'move',
    priority = -1000,

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
    -- Extra movement to apply
    pending_nudge = nil,
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
    self.pending_extrinsic_velocity = Vector()
    -- ...make them here.  This is an /acceleration/ to be applied next frame,
    -- and will be integrated appropriately.  ONLY use this for continuous
    -- acceleration (like gravity); DO NOT use it for instantaneous velocity
    -- changes!
    self.pending_accel = Vector()
    self.pending_nudge = Vector()
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
    self.pending_velocity = self.pending_velocity + dv
end

function Move:add_extrinsic_velocity(dv)
    self.pending_extrinsic_velocity = self.pending_extrinsic_velocity + dv
end

function Move:add_accel(da)
    self.pending_accel = self.pending_accel + da
end

function Move:add_friction(friction)
    self.pending_friction = self.pending_friction + friction
end

function Move:add_movement(ds)
    self.pending_nudge = self.pending_nudge + ds
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
    -- long as pending_accel contains constant sources of acceleration (like
    -- gravity).  It avoids problems like jump height being eroded too much by
    -- the first tic of gravity at low framerates.  Not quite sure what it's
    -- called, but it's similar to Verlet integration and the midpoint method.
    local dv = self.pending_accel * dt
    -- intrinsic only!
    print("\27[33m** MOVE **", self.actor, self.pending_velocity, self.pending_extrinsic_velocity, "\27[0m")
    -- TODO should friction apply /before/ acceleration, maybe?  otherwise if you're moving slowly up a slope, gravity pulls you down, and then friction pushes you back /up/ which is kind of weird?  comes up when pushing things...
    local frame_velocity = self.pending_velocity - self.pending_extrinsic_velocity + 0.5 * dv
    print('. initial frame velocity', frame_velocity)
    self.velocity = self.pending_velocity + dv
    -- FIXME this is used to figure out how much push velocity to claim as extrinsic, but it should really only be in the push direction?  maybe?
    local intrinsic_fraction = (self.velocity - self.pending_extrinsic_velocity):len() / self.velocity:len()
    if self.pending_friction ~= Vector.zero and dt ~= 0 then
        local friction_decel = self.pending_friction * dt
        local friction_direction = friction_decel:trimmed(1)

        -- FIXME this only counts against intrinsic velocity, when it should really count against floor-relative velocity, urgh
        local frame_friction = friction_decel:trimmed(frame_velocity * friction_direction * 0.5)
        print('. frame friction', frame_friction)
        if frame_velocity * friction_direction > 0 then
            frame_velocity = frame_velocity - frame_friction
        else
            frame_velocity = frame_velocity + frame_friction
        end

        local perma_friction = friction_decel:trimmed(self.velocity * friction_direction)
        if self.velocity * friction_direction > 0 then
            self.velocity = self.velocity - perma_friction
        else
            self.velocity = self.velocity + perma_friction
        end
    end
    -- XXX frame_velocity = frame_velocity + self.pending_extrinsic_velocity
    -- TODO am i keeping this?
    self.absolute_velocity = self.velocity + self.pending_extrinsic_velocity
    local extvel = self.pending_extrinsic_velocity
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
    -- FIXME restore this of course
    --local fluidres = self:get_fluid_resistance()
    local multiplier = 1

    local attempted = frame_velocity * (dt / multiplier)
    if attempted == Vector.zero and self.skip_zero_nudge then
        return
    end

    -- Collision time!
    print('. resolved new velocity as', self.velocity, 'and frame velocity as', frame_velocity)
    print('. performing main nudge', attempted)
    local movement, all_hits, pushers = self:nudge(attempted, nil, false, 1)
    print('. finished main nudge', movement)

    -- Trim velocity as necessary, based on our last slide
    -- FIXME this is clearly wrong and we need to trim it as we go, right?
    -- XXX note that this happens /after/ the velocity redist from pushing...
    local v0 = self.velocity
    for _, hits in ipairs(all_hits) do
        if self.velocity == Vector.zero then
            break
        end
        self.velocity = Collision:slide_along_normals(hits, self.velocity)
        frame_velocity = Collision:slide_along_normals(hits, frame_velocity)
    end

    local vellen2 = self.velocity:len2()
    -- FIXME this isn't right, surely, since it includes extrinsic velocity??
    local our_intrinsic_velocity = self.velocity
    print('. our "intrinsic" velocity:', our_intrinsic_velocity)
    local total_momentum = self.velocity * self.actor.mass
    local total_mass = self.actor.mass
    for pusher, pushinfo in pairs(pushers) do
        if pusher ~= self.actor then
            local move = pusher:get('move')
            local their_velocity = move.velocity
            -- XXX is this right?
            their_velocity = move.pending_velocity
            if pushinfo.contact_normal then
                -- Compute momentum in our direction of movement
                -- TODO how does this work transitively?  is this even right for slopes?
                --their_velocity = their_velocity:projectOn(pushinfo.contact_normal)
                their_velocity = their_velocity:projectOn(our_intrinsic_velocity)
                -- XXX idea here is to not steal velocity from a faster object
                -- TODO i don't know how this works transitively
                -- TODO also we include /our/ entire velocity despite that gravity didn't really contribute
                local their_dot = their_velocity * pushinfo.contact_normal
                local our_dot = our_intrinsic_velocity * pushinfo.contact_normal
                -- Contact normal points towards us, so if their velocity is
                -- more negative, they're trying to move (relatively) away
                if their_dot < our_dot then
                    pushinfo.is_faster = true
                    their_velocity:trimInplace(our_dot)
                end
            end
            -- FIXME probably need to consider "Extra" only in their compelled movement direction
            pushinfo.extra_velocity = move.velocity - their_velocity
            -- XXX is this right?
            pushinfo.extra_velocity = move.pending_velocity - their_velocity
            -- FIXME i'm very fuzzy on this point!  which part is "extra"?
            pushinfo.extra_velocity = Vector()
            print('.. pushed:', pusher, move.velocity, pushinfo.fraction, pushinfo.extra_velocity)
            --total_momentum = total_momentum + their_velocity * pusher.mass
            -- XXX this is a REVERSE projection!
            -- XXX could just, uh, calculate momentum as a scalar multiple of our current velocity tbh
            -- XXX possible div by zero here
            -- FIXME need to expand their velocity below too
            if their_velocity == Vector.zero then
                total_mass = total_mass + pusher.mass
            else
                local v = our_intrinsic_velocity
                local w = move.pending_velocity
                local n = pushinfo.contact_normal
                local d = pushinfo.movement_direction
                --return (v * n) * (d * d) / ((d * n) * (v * d))
                -- FIXME check that this is right
                --[[
                local scaled_mass = pusher.mass * (w * w) / (w * v)
                if pushinfo.contact_normal then
                    scaled_mass = scaled_mass * (v * n) / (w * n)
                end
                ]]
                local momentum_weight = (v * n) * (w * w) / ((w * n) * (v * w))
                total_momentum = total_momentum + their_velocity * momentum_weight * pusher.mass

                local mass_weight = (v * n) * (d * d) * (v * d) --[[ * (n * n) ]] / (v * v) / math.pow(d * n, 3)
                --# = (v_a * contact_normal) * (b_new_direction * b_new_direction) * (v_a * b_new_direction) * (contact_normal * contact_normal) / (v_a * v_a) / (b_new_direction * contact_normal)**3
                total_mass = total_mass + pusher.mass * mass_weight
            end
        end
    end
    if total_mass ~= 0 then
        -- Velocity of the entire system
        local new_velocity = total_momentum / total_mass
        -- How much of our intrinsic velocity was responsible for the pushing we did
        local our_applied_velocity = our_intrinsic_velocity * (self.actor.mass / total_mass)
        print(".. setting everyone's velocity to", new_velocity, "from momentum and mass", total_momentum, total_mass)
        for pusher, pushinfo in pairs(pushers) do
            -- TODO this seems like the effect might vary depending on update order, urgh
            local move = pusher:get('move')
            if pusher ~= self.actor then
                -- The pushed object might be on different geometry, if e.g.
                -- we're on flat ground and trying to push it up a slope, so
                -- slide the velocity we give it along its actual movement
                -- TODO this is pretty hokey and outright wrong for more
                -- complex slides, but is hopefully close enough and avoids
                -- preserving the entire set of collisions for everything that
                -- was pushed
                local slid_new_velocity
                local slid_frame_velocity
                if pushinfo.movement_direction then
                    --slid_new_velocity = new_velocity:projectOn(pushinfo.movement)
                    -- XXX reverse projection again
                    slid_new_velocity = pushinfo.movement_direction * new_velocity:len2() / (new_velocity * pushinfo.movement_direction)

                    slid_new_velocity = pushinfo.movement_direction * ((new_velocity * pushinfo.contact_normal) / (pushinfo.movement_direction * pushinfo.contact_normal))
                    -- FIXME scaling frame velocity like this seems highly questionable and i don't remember why i did it, also division by zero risk
                    slid_frame_velocity = pushinfo.movement_direction * frame_velocity:len2() / (frame_velocity * pushinfo.movement_direction) * intrinsic_fraction * new_velocity:len() / frame_velocity:len() --(new_velocity:len() / our_intrinsic_velocity:len())
                    print("// new velocity", new_velocity, "our 'intrinsic' velocity", our_intrinsic_velocity, "frame velocity", frame_velocity, "intrinsic fraction", intrinsic_fraction)
                    --scaled_mass = scaled_mass * (our_intrinsic_velocity * pushinfo.contact_normal) / (their_velocity * pushinfo.contact_normal)
                else
                    slid_new_velocity = new_velocity
                    slid_frame_velocity = frame_velocity
                end
                -- TODO should this subtract velocity or pending?  with regular velocity, pushing a crate into an ice block sends the ice block flying: it gets pending velocity from the initial hit AND gets extra velocity when the crate next moves (before the ice block has!) because the crate thinks its velocity is zero.  so that's wrong.
                -- XXX BUT with PENDING i get a weird test result with gravity but also that's a separate problem.
                --move.velocity = new_velocity
                print('... adding velocity', pusher, slid_new_velocity - move.pending_velocity + pushinfo.extra_velocity, 'to make', slid_new_velocity)
                print('... their current is', move.velocity, 'their pending is', move.pending_velocity, 'and their extra is', pushinfo.extra_velocity)
                move:add_velocity(slid_new_velocity - move.pending_velocity + pushinfo.extra_velocity)
                --move:add_extrinsic_velocity(new_velocity)
                -- FIXME some current problems:
                -- - pushing crate into ice sends ice flying?  unsure why
                -- - standing on top of a moving crate kinda jitters sometimes
                -- - friction doesn't actually work, because a pushed crate has zero intrinsic velocity.  oops!
                -- - landing on an object conveys some momentum!  when it carries you as cargo, it averages in your velocity too, gack
                --   - this is probably the next thing to figure out: isn't the crate's velocity extrinsic and also your frame of ref?
                --   - two types of extrinsic velocity, oh no!!  wait are there really?  being pushed by a crate adds to your world (and even ref) velocity without requiring any extra movement from you.  
                -- - when on a crate, your gravity doesn't contribute to its friction OR to its movement down a slope
                -- - suspect straddle doesn't work quite right either

                -- the idea here is that if we're pushing something that's moving (away from us) /faster/ than we are, then the push was ONLY an artifact of update order and doesn't make much physical sense.  In this case, we should only claim the velocity amount equivalent to how much we moved them, so they perform the rest of their faster move
                -- TODO this feels weird like, the behavior doesn't transition smoothly from "almost as fast" to "same speed"
                if pushinfo.fraction and pushinfo.is_faster then
                    print('... and adding as extrinsic', slid_frame_velocity * pushinfo.fraction)
                    -- FIXME is this still relevant with the change from applied to new?
                    move:add_extrinsic_velocity(slid_frame_velocity * pushinfo.fraction)
                else
                    print('... and adding as extrinsic', slid_frame_velocity)
                    -- XXX i am not sure which of these is correct!
                    --move:add_extrinsic_velocity(our_applied_velocity)
                    move:add_extrinsic_velocity(slid_frame_velocity)
                end
            else
                move.velocity = new_velocity
            end
            --[[
            sigh.  okay.
            - i move at 160, hit a thing.  set myself to 80, it to 80
            - its turn.  it ends up with velocity 0, pending velocity 80, because of the goofy way extrinsic works.  fuck
            * push floor, wind, ladder, etc: set reference frame, the movement you are attached to.  friction and walk speed are relative to this.
            * being pushed: contributes to our overall velocity, but /was already taken care of elsewhere/
            --]]
        end
    end
    self._last_pushed_mass = total_mass

    -- FIXME ho hum, this means add_velocity doens't work from on_collide_with or after_collisions.  should this be zero and get added?  no, stuff relies on altering it directly...  man, fuck
    self.pending_velocity = self.velocity
end

local function _is_vector_almost_zero(v)
    return math.abs(v.x) < 1e-8 and math.abs(v.y) < 1e-8
end

-- Lower-level function passed to the collider to determine whether another
-- object blocks us
-- FIXME now that they're next to each other, these two methods look positively silly!  and have a bit of a symmetry problem: the other object can override via the simple blocks(), but we have this weird thing
function Move:on_collide_with(collision)
    -- FIXME i would LOVE to move this into Actor:blocks(), but there's some
    -- universal logic here that would get clobbered by objects trying to be
    -- solid by having their blocks() just always return true.  maybe i want an
    -- is_blocking prop, or even just collision layers
    -- FIXME if i do that, i should see if it's feasible to also move a lot of
    -- on_collide_with stuff into the obstacle's blocks()

    -- Moving away is always fine
    if collision.contact_type < 0 then
        return true
    end

    -- One-way platforms only block when the collision hits a surface
    -- facing the specified direction
    -- FIXME doubtless need to fix overlap collision with a pushable
    if collision.their_owner.one_way_direction then
        if collision.overlapped or not collision:faces(collision.their_owner.one_way_direction) then
            return true
        end
    end

    -- XXX this should go in Tote, really, but it comes /after/ Move so it can do cargo bookkeeping
    --[[
    local tote = self:get('tote')
    if tote then
        if tote.cargo[collision.their_owner] then
            tote.cargo[collision.their_owner].expiring = false
            return true
        end
    end
    ]]

    -- Otherwise, fall back to trying blocks()
    return not collision.their_owner:blocks(self.actor, collision)
end

function Move:_collision_callback(collision, pushers, already_hit, fraction)
    local obstacle = collision.their_owner

    -- Only announce a hit once per frame
    -- XXX this is once per /nudge/, not once per frame.  should this be made
    -- to be once per frame (oof!), removed entirely, or just have the comment
    -- fixed?
    -- XXX is this even necessary?  on_collide doesn't do a /lot/.  but guarantees would be nice too.
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



    local their_fall = obstacle:get('fall')
    if obstacle and
        -- It has to be pushable, of course
        self.actor.can_push and obstacle.is_pushable and
        -- It has to be in our way (including slides, to track pushable)
        (not passable or passable == 'slide') and
        -- We can't be overlapping...?
        -- FIXME should pushables that we overlap be completely permeable, or what?  happens with carryables too
        not collision.overlapped and
        -- We must be on the ground to push something
        -- FIXME wellll, arguably, aircontrol should factor in.  also, objects
        -- with no gravity are probably exempt from this
        -- FIXME hm, what does no gravity component imply here?
        -- FIXME oh here's a fun one: what happens with two objects with gravity in different directions?
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
        (not their_fall or not collision:faces(-their_fall:get_base_gravity())) and
        -- Must be moving in the normal direction
        collision.contact_type > 0 and
        -- If we already pushed this object during this nudge, it must be
        -- blocked or on a slope or otherwise unable to keep moving, so let it
        -- block us this time
        already_hit[obstacle] ~= 'nudged' and
        -- Avoid a push loop, which could happen in pathological cases
        not pushers[obstacle]
    then
        print('PUSHING:', self.actor, 'pushing', obstacle)
        -- Try to push them along the rest of our movement, which is everything
        -- left after we first touched
        local this_fraction = fraction and fraction * (1 - math.max(0, collision.contact_start))
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
        local tote = self:get('tote')
        --[[
        local manifest = tote.cargo[obstacle]
        if manifest then
            print('unexpiring', obstacle)
            manifest.expiring = false
        else
            print('attaching', obstacle, 'to', self.actor, 'in collision')
            manifest = components_cargo.Manifest()
            tote.cargo[obstacle] = manifest
        end
        manifest.normal = axis
        manifest.left_normal = collision.left_normal
        manifest.right_normal = collision.right_normal
        ]]

        if collision.contact_type == 0 or _is_vector_almost_zero(nudge) then
            -- We're not actually trying to push this thing, whatever it is, so
            -- do nothing.  But mark down that we /could/ push this object; if
            -- we get pushed from the other side, we need to know about this
            -- object so we can include it in recursive friction and the like.
            --manifest.state = CARGO_COULD_PUSH
        else
            pushers[obstacle] = {
                fraction = this_fraction,
                contact_normal = axis,
            }
            -- Actually push the object!
            -- After we do this, its cargo should be populated with everything
            -- /it's/ pushing, which will help us figure out how much to cut
            -- our velocity in our own update()
            print(". nudging pushable", obstacle, collision.attempted, nudge, obstacle.is_pushable, obstacle.is_portable)
            local actual, _, _, _, direction = obstacle:get('move'):nudge(nudge, pushers, 3, this_fraction)
            -- XXX i think this should be done...  afterwards?  we should re-nudge the whole system
            -- If we successfully moved it, ask collision detection to
            -- re-evaluate this collision
            if not _is_vector_almost_zero(actual) then
                pushers[obstacle].movement_direction = direction
                passable = 'retry'
            end
            -- Mark as pushing even if it's blocked.  For sentient pushers,
            -- this lets them keep their push animation and avoids flickering
            -- between pushing and not; non-sentient pushers will lose their
            -- velocity, not regain it, and be marked as pushable next time.
            --manifest.state = CARGO_PUSHING
            already_hit[obstacle] = 'nudged'
            --collision.passable = 'pushed'
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
function Move:nudge(movement, pushers, xxx_no_slide, fraction)
    if self.actor.shape == nil then
        error(("Can't nudge actor %s without a collision shape"):format(self.actor))
    end
    if movement.x ~= movement.x or movement.y ~= movement.y then
        error(("Refusing to nudge actor %s by NaN vector %s"):format(self.actor, movement))
    end
    print('> nudge', self.actor, movement)

    local tote = self:get('tote')
    --[[
    if tote then
        return self:_tote_nudge(movement, pushers, xxx_no_slide)
    end
    ]]
    game:time_push('nudge')

    pushers = pushers or {}
    pushers[self.actor] = pushers[self.actor] or {}
    if fraction then
        pushers[self.actor].fraction = fraction
    end

    local collider = self.actor.map.collider
    local shape = self.actor.shape

    -- Set up the hit callback, which also tells other actors that we hit them
    local already_hit = {}
    local pass_callback = function(collision)
        return self:_collision_callback(collision, pushers, already_hit, fraction)
    end

    -- Main movement loop!  Try to slide in the direction of movement; if that
    -- fails, then try to project our movement along a surface we hit and
    -- continue, until we hit something head-on or run out of movement.
    local total_movement = Vector.zero
    local all_hits = {}
    local stuck_counter = 0
    local last_attempted
    while true do
        game:time_push('sweep')
        last_attempted = movement
        local successful, hits = collider:sweep(shape, movement, pass_callback)
        game:time_pop('sweep')
        table.insert(all_hits, hits)
        shape:move(successful:unpack())
        total_movement = total_movement + successful

        if xxx_no_slide == true then
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
        if xxx_no_slide == 3 and movement:len2() > 0 then
            -- XXX hacky, but, pushes want to actually move the thing until it's out of the way
            movement = movement * (remaining:len() / movement:len())
        end

        if math.abs(movement.x) < 1/256 and math.abs(movement.y) < 1/256 then
            break
        end

        print('> continuing nudge with remainder', movement)

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
    for _, hits in ipairs(all_hits) do
        for _, collision in ipairs(hits) do
            if already_hit[collision.their_owner] == 'nudged' then
                collision.passable = 'pushed'
            end
        end
    end

    -- Move our cargo along with us, independently of their own movement
    -- FIXME this means our momentum isn't part of theirs!!  i think we could
    -- compute effective momentum by comparing position to the last frame, or
    -- by collecting all nudges...?  important for some stuff like glass lexy
    -- FIXME doesn't check can_carry, because it needs to handle both
    -- XXX this should be in Tote, of course, but where exactly?
    if tote and not _is_vector_almost_zero(total_movement) then
        for obstacle, manifest in pairs(tote.cargo) do
            if manifest.state == CARGO_CARRYING and self.actor.can_carry then
                print('. nudging to move cargo at end of parent nudge')
                obstacle:get('move'):nudge(total_movement, pushers)
            end
        end
    end

    game:time_pop('nudge')
    print('> end nudge', total_movement)

    --pushers[self.actor] = nil

    self.actor:each('after_collisions', total_movement, all_hits[#all_hits])

    -- FIXME possibly ridiculous
    -- FIXME last_attempted isn't a GREAT way to communicate this but it's so pushers know the rough direction the pushee ends up moving
    return total_movement, all_hits, pushers, fraction, last_attempted
end

function Move:_tote_nudge(movement, pushers, xxx_no_slide)
    print('*** multi nudge ***  attempting', movement)
    game:time_push('nudge')

    pushers = pushers or {}
    pushers[self.actor] = true

    local collider = self.actor.map.collider
    local tote = self:get('tote')
    local actors = {}
    local shapes = {}
    for cargum, manifest in pairs(tote.cargo) do
        -- FIXME should recurse, Sigh
        -- FIXME once again, a corner problem.
        if manifest:is_moved_in_direction(movement) then
        --if manifest.state == 'carrying' or movement * manifest.normal < 0 then
            print('- ' .. tostring(cargum), manifest.left_normal, manifest.right_normal)
            actors[cargum] = cargum.shape
            -- FIXME is this correct?  i mean, we're trying to move them all, right, so it can't be wrong?
            --manifest.expiring = false
            -- FIXME which one, though
            local contact_normal = manifest.left_normal or manifest.right_normal
            shapes[cargum.shape] = {
                normal = contact_normal,
                -- FIXME i'm not sure this is right.  on the one hand, pushing
                -- a crate uphill should definitely do the full movement on the
                -- crate, even though the contact normal isn't in the direction
                -- of movement.  on the other hand, jumping while pushing a
                -- crate should absolutely not lift the crate with you.
                movement = contact_normal and movement:projectOn(contact_normal) or movement,
                total_movement = Vector(),
            }
        end
    end

    -- Set up the hit callback, which also tells other actors that we hit them
    local already_hit = {}
    local pass_callback = function(collision)
        return self:_collision_callback(collision, pushers, already_hit)
    end

    -- Main movement loop!  Try to slide in the direction of movement; if that
    -- fails, then try to project our movement along a surface we hit and
    -- continue, until we hit something head-on or run out of movement.
    local total_movement = Vector.zero
    local last_hits
    local all_hits = {}
    local stuck_counter = 0
    while true do
        game:time_push('sweep')
        print('* sweep round *, movement', movement)
        local successful, hits = collider:sweep(self.actor.shape, movement, pass_callback)
        last_hits = hits
        table.insert(all_hits, hits)
        local our_fraction = successful * movement / movement:len2()
        local min_fraction = our_fraction
        for shape, s in pairs(shapes) do
            local shape_succ, shape_hits = collider:sweep(shape, s.movement, pass_callback)
            s.successful = shape_succ
            s.collisions = shape_hits
            local fraction = shape_succ * movement / movement:len2()
            -- FIXME this is wrong when not moving directly against it
            --local fraction = shape_succ * s.movement / s.movement:len2()
            print('- bringing along:', shape, s.movement, shape_succ, fraction)
            s.fraction = fraction
            if fraction < min_fraction then
                min_fraction = fraction
            end
        end
        game:time_pop('sweep')
        -- TODO fraction
        if min_fraction < our_fraction then
            print(movement, min_fraction, our_fraction)
            print('main successful', successful)
            successful = movement * min_fraction
            print('overall successful', successful)
            for i, hit in ipairs(hits) do
                if hit.contact_start > min_fraction then
                    hits[i] = nil
                end
            end
        end
        self.actor.shape:move(successful:unpack())
        local any_done = false
        for shape, s in pairs(shapes) do
            local relfrac = s.movement * movement / movement:len2()
            print("movement, relfrac, min frac:", s.movement, relfrac, min_fraction)
            if min_fraction > 0 then
                if min_fraction == relfrac then
                    any_done = true
                end
                local actual_move = s.movement * (min_fraction / relfrac)
                s.remaining = s.movement - actual_move
                print("remaining", s.remaining, actual_move)
                s.total_movement = s.total_movement + actual_move
                shape:move(actual_move:unpack())
            else
                s.remaining = s.movement
            end
        end
        total_movement = total_movement + successful

        if any_done then
            break
        end

        if xxx_no_slide then
            break
        end
        local remaining = movement - successful
        -- FIXME these values are completely arbitrary and i cannot justify them
        if math.abs(remaining.x) < 1/256 and math.abs(remaining.y) < 1/256 then
            break
        end

        -- Find the allowed slide direction that's closest to the direction of movement.
        local any_slid
        movement, any_slid = Collision:slide_along_normals(hits, remaining)
        for shape, s in pairs(shapes) do
            local slid
            s.movement, slid = Collision:slide_along_normals(s.collisions, s.remaining)
            print('-- sliding bringalong', shape, s.remaining, '=>', s.movement, slid)
            if slid then
                any_slid = true
            end
        end
        if not any_slid then
            print('break no slide', movement)
            break
        end

        if math.abs(movement.x) < 1/256 and math.abs(movement.y) < 1/256 then
            print('break no move')
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

    game:time_pop('nudge')

    pushers[self.actor] = nil

    self.actor.pos = self.actor.pos + total_movement
    -- FIXME
    self.actor:each('after_collisions', total_movement, last_hits)
    for actor in pairs(actors) do
        actor.pos = actor.pos + shapes[actor.shape].total_movement
        -- FIXME
        actor:each('after_collisions', shapes[actor.shape].total_movement, shapes[actor.shape].collisions)
    end

    -- If we pushed anything, then most likely we caught up with it and now it
    -- has a collision that looks like we hit it.  But we did manage to move
    -- it, so we don't want that to count when cutting our velocity!
    -- So we'll...  cheat a bit, and pretend it's passable for now.
    -- FIXME oh boy i don't like this, but i don't want to add a custom prop
    -- here that Collision has to know about either?
    --[[
    for _, collision in ipairs(hits) do
        if already_hit[collision.their_owner] == 'nudged' then
            collision.passable = 'pushed'
        end
    end
    ]]

    -- NOTE: that entire cargo nudge block is now gone, wahoo

    print('*** END multi nudge ***  successful', total_movement)
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
    -- Friction multiplier of the ground, or 1 if we're in midair, maybe?
    ground_friction = 1,
    ground_grip = 1,
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

    -- Also apply any on-ground gravity caused by cargo
    -- XXX i don't know if this is right at all
    local tote = self:get('tote')
    if tote then
        for cargum, manifest in pairs(tote.cargo) do
        end
    end

    -- TODO this feels like it does not belong here, but i don't know how to untangle them better
    local climb = self:get('climb')
    if not (climb and climb.is_climbing) then
        move:add_accel(self:get_base_gravity() * multiplier)
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
                friction_force = friction_force + cargo_friction_force -- FIXME * tote.push_resistance_multiplier
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
    -- FIXME do i want this...?  actor.ptrs.ground = actor
    self.ground_friction = friction or 1
    self.ground_grip = grip or 1
    self.ground_terrain = terrain

    -- XXX this all super doesn't belong here, /surely/
    -- XXX i'm not sure this is even necessary
    -- XXX cargo_of is very suspicious also
    -- XXX this doesn't expire naturally...
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
                print('attaching', self.actor, 'to', carrier, 'in ground')
                local components_cargo = require 'klinklang.components.cargo'
                manifest = components_cargo.Manifest()
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
    move:add_accel(slope_resistance * slope)

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
        (not self:get('jump') or self:get('jump').decision == 0) and
        (not self:get('climb') or not self:get('climb').is_climbing) and
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
            local drop_movement, all_hits = move:nudge(drop, nil, true)
            movement = movement + drop_movement
            self:check_for_ground(all_hits[#all_hits])
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
