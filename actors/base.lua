local Vector = require 'klinklang.vendor.hump.vector'

local Object = require 'klinklang.object'
local components = require 'klinklang.actors.components'
local Collision = require 'klinklang.whammo.collision'


-- ========================================================================== --
-- BareActor
-- An extremely barebones actor, implementing only the bare minimum of the
-- interface.  Most actors probably want to inherit from Actor, which supports
-- drawing from a sprite.  Code operating on arbitrary actors should only use
-- the properties and methods defined here.
local BareActor = Object:extend{
    -- Map I belong to, set in on_enter and cleared in on_leave
    map = nil,

    pos = nil,

    -- Used for debug printing; should only be used for abstract types
    _type_name = 'BareActor',

    -- Table of all known actor types, indexed by name
    name = nil,
    _ALL_ACTOR_TYPES = {},
}

function BareActor:extend(...)
    local class = BareActor.__super.extend(self, ...)
    if class.name ~= nil then
        self._ALL_ACTOR_TYPES[class.name] = class
    end
    return class
end

function BareActor:__tostring()
    return ("<%s %s at %s>"):format(self._type_name, self.name, self.pos)
end

function BareActor:get_named_type(name)
    local class = self._ALL_ACTOR_TYPES[name]
    if class == nil then
        error(("No such actor type %s"):format(name))
    end
    return class
end


-- Main update and draw loops
function BareActor:update(dt)
end

function BareActor:draw()
end

-- Called when the actor is added to the world
function BareActor:on_enter(map)
    self.map = map

    if self.shape then
        map.collider:add(self.shape, self)
    end
end

-- Called when the actor is removed from the world
function BareActor:on_leave()
    if self.shape then
        self.map.collider:remove(self.shape)
    end

    self.map = nil
end

-- Called every frame that another actor is touching this one
-- TODO that seems excessive?
function BareActor:on_collide(actor, movement, collision)
end

-- Determines whether this actor blocks another one.  By default, actors are
-- non-blocking, and mobile actors are blocking
function BareActor:blocks(actor, direction)
    return false
end

function BareActor:damage(amount, source)
end

-- General API stuff for controlling actors from outside
function BareActor:move_to(position)
    self.pos = position
end

-- Doesn't directly destroy the actor, but schedules it to be removed from the
-- map at the end of the next update, at which point GC will take care of it if
-- it has no other references
function BareActor:destroy()
    self.map:delayed_remove_actor(self)
end


-- ========================================================================== --
-- Actor
-- Base class for an actor: any object in the world with any behavior at all.
-- (The world also contains tiles, but those are purely decorative; they don't
-- have an update call, and they're drawn all at once by the map rather than
-- drawing themselves.)
local Actor = BareActor:extend{
    _type_name = 'Actor',
    -- TODO consider splitting me into components

    -- Should be provided in the class
    -- TODO are these part of the sprite?
    shape = nil,
    -- Visuals (should maybe be wrapped in another object?)
    sprite_name = nil,
    -- FIXME the default facing for top-down mode should be /down/...
    facing = 'right',

    -- Makes an actor render floatily and occasionally spawn white particles.
    -- Used for items, as well as the levitation spell
    -- FIXME this is pretty isaac-specific; get it outta here.  it doesn't even
    -- disable gravity any more
    is_floating = false,

    -- Completely general-purpose timer
    timer = 0,

    -- Multiplier for the friction of anything standing on us
    -- XXX does this belong here?  i'm iffy enough about having shape, but this...
    friction_multiplier = 1,
    -- Terrain type, an arbitrary name, also applied to anything standing on us
    terrain_type = nil,
}

function Actor:init(position)
    self.pos = position

    -- Table of weak references to other actors
    self.ptrs = setmetatable({}, { __mode = 'v' })

    -- TODO arrgh, this global.  sometimes i just need access to the game.
    -- should this be done on enter, maybe?
    -- FIXME making the sprite optional feels very much like it should be a
    -- component, but there's the slight weirdness of also getting the physics
    -- shape from the sprite because it's convenient (and often informed by the
    -- appearance)
    if self.sprite_name then
        if not game.sprites[self.sprite_name] then
            error(("No such sprite named %s"):format(self.sprite_name))
        end
        self.sprite = game.sprites[self.sprite_name]:instantiate()

        -- FIXME progress!  but this should update when the sprite changes, argh!
        if self.sprite.shape then
            -- FIXME hang on, the sprite is our own instance, why do we need to clone it at all--  oh, because Sprite doesn't actually clone it, whoops
            self.shape = self.sprite.shape:clone()
            self.shape._xxx_is_one_way_platform = self.sprite.shape._xxx_is_one_way_platform
            self.shape:move_to(position:unpack())
        end
    end
end

-- Called once per update frame; any state changes should go here
function Actor:update(dt)
    self.timer = self.timer + dt
    if self.sprite then
        self.sprite:update(dt)
    end
end

-- Draw the actor
function Actor:draw()
    if self.sprite then
        local where = self.pos:clone()
        if self.is_floating then
            where.y = where.y - (math.sin(self.timer) + 1) * 4
        end
        self.sprite:draw_at(where)
    end
end

-- General API stuff for controlling actors from outside
function Actor:move_to(position)
    self.pos = position
    if self.shape then
        self.shape:move_to(position:unpack())
    end
end

function Actor:set_shape(new_shape)
    if self.shape and self.map then
        self.map.collider:remove(self.shape)
    end
    self.shape = new_shape
    if self.shape then
        if self.map then
            self.map.collider:add(self.shape, self)
        end
        self.shape:move_to(self.pos:unpack())
    end
end

function Actor:set_sprite(sprite_name)
    local facing = self.sprite.facing
    self.sprite_name = sprite_name
    self.sprite = game.sprites[self.sprite_name]:instantiate(nil, facing)
end

local FACING_VECTORS = {
    left = Vector(-1, 0),
    right = Vector(1, 0),
    up = Vector(0, -1),
    down = Vector(0, 1),
}

function Actor:facing_to_vector()
    return FACING_VECTORS[self.facing]
end


-- ========================================================================== --
-- MobileActor
-- Base class for an actor that's subject to standard physics
-- TODO not a fan of using subclassing for this; other options include
-- component-entity, or going the zdoom route and making everything have every
-- behavior but toggled on and off via myriad flags
local TILE_SIZE = 32

-- TODO these are a property of the world and should go on the world object
-- once one exists
local gravity = Vector(0, 768)
local terminal_velocity = 1536

local CARGO_CARRYING = 'carrying'
local CARGO_PUSHING = 'pushing'
local CARGO_COULD_PUSH = 'pushable'
local CARGO_BLOCKED = 'blocked'

local function _is_vector_almost_zero(v)
    return math.abs(v.x) < 1e-8 and math.abs(v.y) < 1e-8
end

local MobileActor = Actor:extend{
    _type_name = 'MobileActor',

    -- Passive physics parameters
    -- Units are pixels and seconds!
    min_speed = 1,
    -- FIXME i feel like this is not done well.  floating should feel floatier
    -- FIXME friction should probably be separate from deliberate deceleration?
    friction_decel = 256,  -- FIXME this seems very high, means a velocity < 8 effectively doesn't move at all.  it's a third of the default player accel damn
    ground_friction = 1,  -- FIXME this is state, dumbass, not a twiddle
    gravity_multiplier = 1,
    gravity_multiplier_down = 1,
    -- If this is false, then other objects will never stop this actor's
    -- movement; however, it can still push and carry them
    is_blockable = true,
    -- If this is true and this actor wouldn't move this tic (i.e. has zero
    -- velocity and no gravity), skip the nudge entirely.  Way faster, but
    -- returns no hits and doesn't call on_collide_with.
    may_skip_nudge = false,
    -- Pushing and platform behavior
    is_pushable = false,
    can_push = false,
    push_resistance_multiplier = 1,
    push_momentum_multiplier = 1,
    is_portable = false,  -- Can this be carried?
    can_carry = false,  -- Can this carry?
    mass = 1,  -- Pushing a heavier object will slow you down

    -- Physics state
    -- FIXME there are others!
    velocity = nil,
    -- Constant forces that should be applied this frame.  Do NOT use for
    -- instantaneous changes in velocity; there's push() for that.  This is
    -- for, e.g., gravity.
    pending_force = nil,
    cargo = nil,  -- Set of currently-carried objects
    total_mass = nil,
}

function MobileActor:init(...)
    MobileActor.__super.init(self, ...)

    self.velocity = Vector()
    self.pending_force = Vector()

    self.gravity_component = components.Fall(self.friction_decel)
end

function MobileActor:on_enter(...)
    MobileActor.__super.on_enter(self, ...)

    -- FIXME explain how this works, somewhere, as an overview
    self.cargo = setmetatable({}, { __mode = 'k' })
end

function MobileActor:blocks(actor, d)
    return true
end

-- Return the relative resistance of whatever fluid the actor is currently
-- inside.  This doesn't affect the actor's velocity, gravity, or anything
-- else; it's only applied to how much the actor's velocity contributes to
-- their movement on this tic, so it effectively applies to walking, jumping,
-- terminal velocity, etc. all simultaneously.  The default is 1; higher values
-- mean a more viscous fluid and will slow down movement.
-- TODO is this a good idea?  now self.velocity is a bit of a fib, since it's
-- not how fast the actor is actually moving.  think of how this affects e.g.
-- glass lexy?  or is that correct?
-- TODO having this as an accessor is annoyingly inconsistent.  probably add
-- support for properties and change this to an attribute
function MobileActor:get_fluid_resistance()
    return 1
end

-- Return the mass of ourselves, plus everything we're pushing or carrying
function MobileActor:_get_total_mass(direction, _seen)
    if not _seen then
        _seen = {}
    elseif _seen[self] then
        return 0
    end
    _seen[self] = true

    local total_mass = self.mass
    for actor, manifest in pairs(self.cargo) do
        if manifest.state == CARGO_CARRYING or manifest.normal * direction < 0 then
            total_mass = total_mass + actor:_get_total_mass(direction, _seen)
        end
    end
    return total_mass
end

function MobileActor:_get_carried_mass(_seen)
    if not _seen then
        _seen = {}
    elseif _seen[self] then
        print("!!! FOUND A CARGO LOOP", self)
        for k in pairs(_seen) do print('', k) end
        return 0
    end
    _seen[self] = true

    local mass = self.mass
    for actor, manifest in pairs(self.cargo) do
        if manifest.state == CARGO_CARRYING then
            mass = mass + actor:_get_carried_mass(_seen)
        end
    end
    return mass
end

-- Return the mass of ourselves, plus everything we're pushing or carrying
function MobileActor:_get_total_friction(direction, _seen)
    direction = direction:normalized()
    if not _seen then
        _seen = {}
    elseif _seen[self] then
        print("!!! FOUND A CARGO LOOP", self)
        for k in pairs(_seen) do print('', k) end
        return Vector.zero
    end
    _seen[self] = true

    local friction = self.gravity_component:get_friction(self, direction)

    for actor, manifest in pairs(self.cargo) do
        if manifest.state ~= CARGO_CARRYING and manifest.normal * direction < 0 then
            friction = friction + actor:_get_total_friction(direction, _seen)
        end
    end
    --print("- " .. tostring(self), friction:projectOn(direction), self:_get_total_mass(direction), friction:projectOn(direction) / self:_get_total_mass(direction), __v)
    return friction
end

-- Lower-level function passed to the collider to determine whether another
-- object blocks us
-- FIXME now that they're next to each other, these two methods look positively silly!  and have a bit of a symmetry problem: the other object can override via the simple blocks(), but we have this weird thing
function MobileActor:on_collide_with(actor, collision)
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
        if collision.overlapped or not collision:faces(Vector(0, 1)) then
            return true
        end
    end

    -- Otherwise, fall back to trying blocks(), if the other thing is an actor
    if actor and not actor:blocks(self, collision) then
        return true
    end

    -- Otherwise, it's solid, and we're blocked!
    return false
end


function MobileActor:_collision_callback(collision, pushers, already_hit)
    local actor = self.map.collider:get_owner(collision.shape)
    if type(actor) ~= 'table' or not Object.isa(actor, BareActor) then
        actor = nil
    end

    -- Only announce a hit once per frame
    -- XXX this is once per /nudge/, not once per frame.  should this be made
    -- to be once per frame (oof!), removed entirely, or just have the comment
    -- fixed?
    local hit_this_actor = already_hit[actor]
    if actor and not hit_this_actor then
        -- FIXME movement is fairly misleading and i'm not sure i want to
        -- provide it, at least not in this order
        actor:on_collide(self, movement, collision)
        already_hit[actor] = true
    end

    -- Debugging
    if game and game.debug and game.debug_twiddles.show_collision then
        game.debug_hits[collision.shape] = collision
    end

    -- FIXME again, i would love a better way to expose a normal here.
    -- also maybe the direction of movement is useful?
    local passable = self:on_collide_with(actor, collision)

    -- Check for carrying
    if actor and self.can_carry then
        if self.cargo[actor] and self.cargo[actor].state == CARGO_CARRYING then
            -- If the other actor is already our cargo, ignore collisions with
            -- it for now, since we'll move it at the end of nudge()
            -- FIXME this is /technically/ wrong if the carrier is blockable, but so
            -- far all of mine are not.  one current side effect is that if you're
            -- on a crate on a platform moving up, and you hit a ceiling, then you
            -- get knocked off the crate rather than the crate being knocked
            -- through the platform.
            return true
        elseif actor.is_portable and
            not passable and not collision.overlapped and
            collision:faces(gravity) and
            not pushers[actor]
        then
            -- If we rise into a portable actor, pick it up -- push it the rest
            -- of the distance we're going to move.  On its next ground check,
            -- it should notice us as its carrier.
            -- FIXME this isn't quite right, since we might get blocked later
            -- and not actually move this whole distance!  but chances are they
            -- will be too so this isn't a huge deal
            local nudge = collision.attempted * (1 - math.max(0, collision.contact_start))
            if not _is_vector_almost_zero(nudge) then
                actor:nudge(nudge, pushers)
            end
            return true
        end
    end

    -- Check for pushing
    -- FIXME i'm starting to think this belongs in nudge(), not here, since we don't even know how far we'll successfully move yet
    if actor and
        -- It has to be pushable, of course
        self.can_push and actor.is_pushable and
        -- It has to be in our way (including slides, to track pushable)
        (not passable or passable == 'slide') and
        -- We can't be overlapping...?
        -- FIXME should pushables that we overlap be completely permeable, or what?  happens with carryables too
        not collision.overlapped and
        -- We must be on the ground to push something
        -- FIXME wellll, arguably, aircontrol should factor in.  also, objects
        -- with no gravity are probably exempt from this
        -- FIXME hm, what does no gravity component imply here?
        self.gravity_component and self.gravity_component.grounded and
        -- We can't push the ground
        self.ptrs.ground ~= actor and
        -- We can only push things sideways
        -- FIXME this seems far too restrictive, but i don't know what's
        -- correct here.  also this is wrong for no-grav objects, which might
        -- be a hint
        -- FIXME this is still wrong.  maybe we should just check this inside the body
        --(not collision.left_normal or collision.left_normal * actor:get_gravity() >= 0) and
        --(not collision.right_normal or collision.right_normal * actor:get_gravity() >= 0) and
        --(not collision.right_normal or math.abs(collision.right_normal:normalized().y) < 0.25) and
        --(not collision.left_normal or math.abs(collision.left_normal:normalized().y) < 0.25) and
        --(not collision.right_normal or math.abs(collision.right_normal:normalized().y) < 0.25) and
        -- If we already pushed this object during this nudge, it must be
        -- blocked or on a slope or otherwise unable to keep moving, so let it
        -- block us this time
        already_hit[actor] ~= 'nudged' and
        -- Avoid a push loop, which could happen in pathological cases
        not pushers[actor]
    then
        -- Try to push them along the rest of our movement, which is everything
        -- left after we first touched
        local nudge = collision.attempted * (1 - math.max(0, collision.contact_start))
        -- You can only push along the ground, so remove any component along
        -- the ground normal
        nudge = nudge - nudge:projectOn(self.gravity_component.ground_normal)
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
        local manifest = self.cargo[actor]
        if manifest then
            manifest.expiring = false
        else
            manifest = {}
            self.cargo[actor] = manifest
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
            print("about to nudge", actor, collision.attempted, nudge, actor.is_pushable, actor.is_portable)
            local actual = actor:nudge(nudge, pushers)
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
            already_hit[actor] = 'nudged'
        end
    end
    if not self.is_blockable and not passable then
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
function MobileActor:nudge(movement, pushers, xxx_no_slide)
    if self.shape == nil then
        error(("Can't nudge actor %s without a collision shape"):format(self))
    end
    if movement.x ~= movement.x or movement.y ~= movement.y then
        error(("Refusing to nudge actor %s by NaN vector %s"):format(self, movement))
    end

    pushers = pushers or {}
    pushers[self] = true

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
        successful, hits = self.map.collider:sweep(self.shape, movement, pass_callback)
        self.shape:move(successful:unpack())
        self.pos = self.pos + successful
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
                    print("!!!  BREAKING OUT OF LOOP BECAUSE WE'RE STUCK, OOPS", self, movement, remaining)
                end
                break
            end
        end
    end

    -- If we pushed anything, then most likely we caught up with it and now it
    -- has a collision that looks like we hit it.  But we did manage to move
    -- it, so we don't want that to count when cutting our velocity!
    -- So we'll...  cheat a bit, and pretend it's passable for now.
    -- FIXME oh boy i don't like this, but i don't want to add a custom prop
    -- here that Collision has to know about either?
    for actor, hit_type in pairs(already_hit) do
        if hit_type == 'nudged' then
            -- FIXME auughhhh
            local collision
            for _, hit in ipairs(hits) do
                if self.map.collider:get_owner(hit.our_shape) == actor then
                    hit.passable = 'pushed'
                end
            end
        end
    end

    -- Move our cargo along with us, independently of their own movement
    -- FIXME this means our momentum isn't part of theirs!!  i think we could
    -- compute effective momentum by comparing position to the last frame, or
    -- by collecting all nudges...?  important for some stuff like glass lexy
    -- FIXME doesn't check can_carry, because it needs to handle both
    local moved = not _is_vector_almost_zero(total_movement)
    for actor, manifest in pairs(self.cargo) do
        if manifest.state == CARGO_CARRYING and moved and self.can_carry then
            actor:nudge(total_movement, pushers)
        end
    end

    pushers[self] = nil
    return total_movement, hits
end

function MobileActor:update(dt)
    MobileActor.__super.update(self, dt)

    -- Passive adjustments
    if math.abs(self.velocity.x) < self.min_speed then
        self.velocity.x = 0
    end

    -- Stash our current velocity, before gravity and friction and other
    -- external forces.  This is (more or less) the /attempted/ movement for a
    -- sentient actor, and lingering momentum for any mobile actor, which is
    -- later used for figuring out which objects a pusher was 'trying' to push
    local attempted_velocity = self.velocity

    -- Gravity
    if self.gravity_component then
        self.gravity_component:act(self, dt)
    end

    -- This is basically vt + ½at², and makes the results exactly correct, as
    -- long as pending_force contains constant sources of acceleration (like
    -- gravity).  It avoids problems like jump height being eroded too much by
    -- the first tic of gravity at low framerates.  Not quite sure what it's
    -- called, but it's similar to Verlet integration and the midpoint method.
    local dv = self.pending_force * dt
    local frame_velocity = self.velocity + 0.5 * dv
    self.pending_force = Vector()
    self.velocity = self.velocity + dv

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
    -- FIXME oh boy oh boy absolutely put this in Fall
    if self.gravity_component then
        local friction_force = self.gravity_component:get_friction(self, self.velocity)
        -- Add up all the friction of everything we're pushing (recursively, since
        -- those things may also be pushing/carrying things)
        -- FIXME each cargo is done independently, so there's a risk of counting
        -- twice?  is there a reason we can't just call _get_total_friction on
        -- ourselves here?
        for actor, manifest in pairs(self.cargo) do
            if (manifest.state == CARGO_PUSHING or manifest.state == CARGO_COULD_PUSH) and manifest.normal * attempted_velocity < -1e-8 then
                local cargo_friction_force = actor:_get_total_friction(-manifest.normal)
                friction_force = friction_force + cargo_friction_force * self.push_resistance_multiplier
            end
        end
        -- Apply the friction to ourselves.  Note that both our ongoing velocity
        -- and our instantaneous frame velocity need updating, since friction has
        -- the awkward behavior of never reversing motion
        if friction_force ~= Vector.zero then
            -- FIXME should this project on velocity, project on our ground, or not project at all?
            -- FIXME hey um what about the force of pushing a thing uphill
            local friction_delta = friction_force * (dt / self:_get_total_mass(attempted_velocity))
            local friction_delta1 = friction_delta:normalized()
            self.velocity = self.velocity + friction_delta:trimmed(self.velocity * friction_delta1)
            frame_velocity = frame_velocity + friction_delta:trimmed(frame_velocity * friction_delta1)
        end
    end

    -- FIXME how does terminal velocity apply to integration?  if you get
    -- launched Very Fast the integration will take some of it into account
    -- still
    -- FIXME ah, gravity dependence
    -- FIXME should be in Fall
    local fluidres = self:get_fluid_resistance()
    self.velocity.y = math.min(self.velocity.y, terminal_velocity / fluidres)

    local attempted = frame_velocity * (dt / fluidres)
    if attempted == Vector.zero and self.may_skip_nudge then
        return Vector(), {}
    end

    -- Collision time!
    local movement, hits = self:nudge(attempted)

    if self.gravity_component then
        self.gravity_component:after_collisions(self, movement, hits)
    end

    local total_momentum = self.velocity * self.mass
    local total_mass = self.mass
    local any_new = false
    for actor, manifest in pairs(self.cargo) do
        local detach = false
        if manifest.expiring then
            -- We didn't push or carry this actor this frame, so we must have
            -- come detached from it.
            detach = true
        elseif manifest.state == CARGO_COULD_PUSH and attempted_velocity * manifest.normal < -1e-8 then
            -- If we didn't push something, but we *tried* and *could've*, then
            -- chances are we're a sentient actor trying to push something
            -- whose friction we just can't overcome.  Treating that as a push,
            -- even though we didn't actually move it, avoids state flicker
            manifest.state = CARGO_PUSHING
        elseif manifest.state == CARGO_PUSHING and manifest.velocity then
            -- If we slow down, the momentum of whatever we're pushing might
            -- keep it going.  Figure out whether this is the case by comparing
            -- our actual velocity (which is the velocity of the whole system)
            -- with the velocity of this cargo, remembering to account for the
            -- friction it *would've* experienced on its own this frame
            local cargo_friction_force = actor:_get_total_friction(-manifest.normal)
            local cargo_mass = actor:_get_total_mass(manifest.velocity)
            local friction_delta = cargo_friction_force / cargo_mass * dt
            local cargo_dot = (manifest.velocity + friction_delta) * manifest.normal
            local system_dot = self.velocity * manifest.normal
            if system_dot > cargo_dot then
                -- We're moving more slowly than the rest of the system; we
                -- might be a sentient actor turning away, or just heavier or
                -- more frictional than whatever we're pushing.  Detach.
                detach = true
            end
        end

        -- Detach any cargo that's no longer connected.
        -- NOTE: This is FRAMERATE DEPENDENT; detaching always takes one frame
        if detach then
            self.cargo[actor] = nil

            if manifest.state == CARGO_PUSHING then
                -- If we were pushing, impart it with our velocity (which
                -- doesn't need any mass scaling, because our velocity was the
                -- velocity of the whole system).
                actor.velocity = actor.velocity + manifest.velocity:projectOn(manifest.normal) * self.push_momentum_multiplier

                -- If the object was transitively pushing something else,
                -- transfer our velocity memory too.  This isn't strictly
                -- necessary, but it avoids waiting an extra frame for the
                -- object to realize it's doing the pushing before deciding
                -- whether to detach itself as well.
                if actor.cargo then
                    for actor2, manifest2 in pairs(actor.cargo) do
                        if manifest2.state == CARGO_PUSHING and not manifest2.velocity then
                            manifest2.velocity = manifest.velocity
                        end
                    end
                end
            end
            -- Just in case we were carrying them, undo their cargo_of
            if actor.ptrs.cargo_of == self then
                actor.ptrs.cargo_of = nil
            end
        else
            -- This is still valid cargo

            -- Deal with conservation of momentum.  Our velocity is really the
            -- velocity of the whole push/carry system, so only new pushes are
            -- interesting here
            local seen = {}
            local function get_total_momentum(actor, direction)
                if seen[actor] then
                    return Vector()
                end
                seen[actor] = true

                local momentum = actor.velocity * actor.mass
                -- FIXME this should be transitive, but that's complicated with loops, sigh
                -- FIXME should this only *collect* velocity in the push direction?
                -- FIXME what if they're e.g. on a slope and keep accumulating more momentum?
                -- FIXME how is this affected by something being pushed from both directions?
                actor.velocity = actor.velocity - actor.velocity:projectOn(direction)
                for other_actor, manifest in pairs(actor.cargo) do
                    if manifest.state == CARGO_PUSHING then
                        -- FIXME should this be direction, or other_manifest.normal?
                        -- FIXME should this also apply to pushable?
                        momentum = momentum + get_total_momentum(other_actor, direction)
                    end
                end
                return momentum
            end
            if manifest.state == CARGO_PUSHING or manifest.state == CARGO_CARRYING then
                local cargo_mass = actor:_get_total_mass(attempted_velocity)
                total_mass = total_mass + cargo_mass
                if manifest.expiring == nil then
                    -- This is a new push
                    any_new = true
                    -- Absorb the momentum of the pushee
                    total_momentum = total_momentum + get_total_momentum(actor, manifest.normal)
                    -- The part of our own velocity parallel to the push gets
                    -- capped, but any perpendicular movement shouldn't (since
                    -- it's not part of this push anyway).  Fake that by
                    -- weighting the perpendicular part as though it belonged
                    -- to this cargo.
                    local parallel = self.velocity:projectOn(manifest.normal)
                    local perpendicular = self.velocity - parallel
                    total_momentum = total_momentum + perpendicular * cargo_mass
                else
                    -- This is an existing push; ignore its velocity and tack on our own
                    total_momentum = total_momentum + self.velocity * cargo_mass
                end
            end
        end
    end
    if any_new and total_mass ~= 0 then
        self.velocity = total_momentum / total_mass
    end

    -- Trim velocity as necessary, based on our last slide
    -- FIXME this is clearly wrong and we need to trim it as we go, right?
    if self.velocity ~= Vector.zero then
        self.velocity = Collision:slide_along_normals(hits, self.velocity)
    end

    -- XXX i hate that i have to iterate three times, but i need to stick the POST-conservation velocity in here
    -- Finally, mark all cargo as potentially expiring (if we haven't seen it
    -- again by next frame), and remember our push velocity so we know whether
    -- we slowed enough to detach them next frame
    -- XXX i wonder if i actually need manifest.velocity?  it's only used for that detachment, but...  i already know my own pre-friction (and post-friction) velocity...  how and why do friction and conservation fit in here?
    for actor, manifest in pairs(self.cargo) do
        manifest.expiring = true
        if manifest.state == CARGO_PUSHING then
            manifest.velocity = self.velocity
        else
            manifest.velocity = nil
        end
    end

    return movement, hits
end

-- API for outside code to affect this actor's velocity.
-- By default, this just adds to velocity, but SentientActor makes use of it
-- for variable jump logic.
function MobileActor:push(dv)
    self.velocity = self.velocity + dv
end


-- ========================================================================== --
-- SentientActor
-- An actor that makes conscious movement decisions.  This is modeled on the
-- player's own behavior, but can be used for other things as well.
-- Note that, unlike the classes above, this class changes the actor's pose.  A
-- sentient actor should have stand, walk, and fall poses at a minimum.

-- Note that this will return the velocity required to EXACTLY reach the given
-- height, which may not even happen due to the imprecise nature of simulating
-- physics discretely; you may want to add padding, some fraction of a tile.
local function get_jump_velocity(height)
    -- Max height of a projectile = vy² / (2g), so vy = √2gh
    return math.sqrt(2 * gravity.y * height)
end

local SentientActor = MobileActor:extend{
    _type_name = 'SentientActor',

    -- Active physics parameters
    -- TODO these are a little goofy because friction works differently; may be
    -- worth looking at that again.
    -- How fast we accelerate when walking.  Note that this implicitly controls
    -- how much stuff we can push, since it has to overcome the extra friction.
    -- As you might expect, our maximum pushing mass (including our own!) is
    -- friction_decel / xaccel.
    xaccel = 2048,
    deceleration = 1,
    max_speed = 256,
    climb_speed = 128,
    -- Pick a jump velocity that gets us up 2 tiles, plus a margin of error
    jumpvel = get_jump_velocity(TILE_SIZE * 2.25),
    jumpcap = 0.25,
    -- Multiplier for xaccel while airborne.  MUST be greater than the ratio of
    -- friction to xaccel, or the player won't be able to move while floating!
    aircontrol = 0.25,
    -- Maximum slope that can be walked up or jumped off of.  MUST BE NORMALIZED
    max_slope = Vector(1, -1):normalized(),
    max_slope_slowdown = 0.7,

    -- Other configuration
    max_jumps = 1,  -- Set to 2 for double jump, etc
    jump_sound = nil,  -- Path!

    -- State
    -- Flag indicating that we were deliberately pushed upwards since the last
    -- time we were on the ground; disables ground adherence and the jump
    -- velocity capping behavior
    was_launched = false,
    is_climbing = false,
    is_dead = false,
    is_locked = false,
}

function SentientActor:init(...)
    SentientActor.__super.init(self, ...)

    self.walk_component = components.Walk(self.xaccel, self.xaccel * self.aircontrol, self.deceleration, self.max_speed)
    self.jump_component = components.Jump(self.jumpvel, self.jumpvel * self.jumpcap, game.resource_manager:get(self.jump_sound))
    self.climb_component = components.Climb(self.climb_speed)
    self.interactor_component = components.Interact()
    self.gravity_component = components.SentientFall(self.max_slope, self.friction_decel)
end

function SentientActor:get_gravity_multiplier()
    if self.is_climbing and not self.xxx_useless_climb then
        return 0
    end
    return SentientActor.__super.get_gravity_multiplier(self)
end

function SentientActor:push(dv)
    SentientActor.__super.push(self, dv)

    if dv * self.gravity_component:get_gravity() < 0 then
        self.was_launched = true
    end
end

function SentientActor:on_collide_with(actor, collision)
    -- Ignore collision with one-way platforms when climbing ladders, since
    -- they tend to cross (or themselves be) one-way platforms
    if collision.shape._xxx_is_one_way_platform and self.is_climbing then
        return true
    end

    local passable = SentientActor.__super.on_collide_with(self, actor, collision)

    return passable
end

function SentientActor:update(dt)
    if self.is_dead or self.is_locked then
        -- Ignore conscious decisions; just apply physics
        -- FIXME used to stop climbing here, why?  so i fall off ladders during transformations i guess?
        -- FIXME i think "locked" only makes sense for the player?
        return SentientActor.__super.update(self, dt)
    end

    self.walk_component:act(self, dt)

    -- Update facing -- based on the input, not the velocity!
    -- FIXME should this have memory the same way conflicting direction keys do?
    -- FIXME where does this live?  on Walk?  on Think?
    if math.abs(self.walk_component.decision.x) > math.abs(self.walk_component.decision.y) then
        if self.walk_component.decision.x < 0 then
            self.facing = 'left'
        elseif self.walk_component.decision.x > 0 then
            self.facing = 'right'
        end
    else
        if self.walk_component.decision.y < 0 then
            self.facing = 'up'
        elseif self.walk_component.decision.y > 0 then
            self.facing = 'down'
        end
    end

    -- Jumping
    self.jump_component:act(self)

    -- Climbing
    self.climb_component:act(self, dt)

    -- Apply physics
    local movement, hits = SentientActor.__super.update(self, dt)

    self.interactor_component:after_collisions(self, movement, hits)
    self.climb_component:after_collisions(self, movement, hits)

    -- Update the pose
    self:update_pose()

    -- Use whatever's now in front of us
    -- TODO shouldn't this be earlier?
    self.interactor_component:act(self, dt)

    return movement, hits
end

-- Figure out a new pose and switch to it.  Default behavior is based on player
-- logic; feel free to override.
-- FIXME do mobile actors really never have poses?
-- FIXME picking a pose is a weird combination of "i just started jumping, so i
-- want to immediately switch to jump pose and keep it there" vs "i want to use
-- the turnaround pose /even though/ i'm walking".  at the moment i just have
-- some hairy code for that, but it would be nice to have a more robust
-- solution that's not also hairy
function SentientActor:update_pose()
    if self.sprite then
        self.sprite:set_facing(self.facing)
        local pose = self:determine_pose()
        if pose then
            self.sprite:set_pose(pose)
        end
    end
end
function SentientActor:determine_pose()
    if self.health_component.is_dead then
        return 'die'
    elseif self.is_floating then
        return 'fall'
    elseif self.climb_component.is_climbing then
        if self.climb_component.decision < 0 then
            return 'climb'
        elseif self.climb_component.decision > 0 then
            return 'descend'
        else
            return 'hold'
        end
    elseif not self.gravity_component or self.gravity_component.grounded then
        if self.walk_component.decision ~= Vector.zero then
            return 'walk'
        end
    elseif self.velocity.y < 0 then
        return 'jump'
    else
        return 'fall'
    end

    return 'stand'
end


return {
    BareActor = BareActor,
    Actor = Actor,
    MobileActor = MobileActor,
    SentientActor = SentientActor,
    get_jump_velocity = get_jump_velocity,
}
