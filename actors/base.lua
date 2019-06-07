local Vector = require 'klinklang.vendor.hump.vector'

local Object = require 'klinklang.object'
local util = require 'klinklang.util'
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

    -- If true, the player can "use" this object, calling on_use(activator)
    is_usable = false,

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

-- Called when this actor is used (only possible if is_usable is true)
function BareActor:on_use(activator)
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

    -- Optional, used by damage() but has very little default behavior
    health = nil,
    -- Starting value for health
    max_health = nil,
    -- The default behavior is to instantly vanish on death, but just in case,
    -- this flag is also set (in damage(), NOT die()!) to avoid the silly
    -- problem of taking damage while dead
    is_dead = false,

    -- Indicates this is an object that responds to the use key
    is_usable = false,

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

    self.health = self.max_health
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

function Actor:damage(amount, source)
    if self.health == nil or self.is_dead then
        return
    end

    self.health = self.health - amount
    if self.health <= 0 then
        self.is_dead = true
        self:die(source)
    end
end

function Actor:die(killer)
    self:destroy()
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
    on_ground = false,
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

-- Essentially: is the vertical axis gravity, or another direction of movement?
-- If this returns true, then the actor will use platformer behavior: vertical
-- movement is ignored, jumping is enabled, and contact with the ground is
-- tracked.
-- If this returns false, then the actor will use top-down RPG behavior: free
-- vertical movement is possible, gravity is not applied at all, jumping is
-- disabled, and ground contact is ignored.  (I call this "top-down mode", but
-- it's also useful in a platformer for flying critters which also have free
-- vertical movement.)
function MobileActor:has_gravity()
    return true
end

function MobileActor:get_gravity()
    -- TODO move gravity to, like, the world, or map, or somewhere?  though it
    -- might also vary per map, so maybe something like Map:get_gravity(shape)?
    -- but variable gravity feels like something that would be handled by
    -- zones, which should already participate in collision, so........  i
    -- dunno think about this later
    -- TODO should this return a zero vector if has_gravity() is on?  seems
    -- reasonable, but also you shouldn't be checking for gravity at all if
    -- has_gravity is off, but,
    return gravity
end

-- TODO again, a prop would be nice
-- TODO this can probably just be merged into get_gravity, right?  Well.....
-- maybe not since get_gravity is called in several places so it should be as
-- quick as possible.  honestly i would like if it were only checked once per
-- frame or something but
function MobileActor:get_gravity_multiplier()
    local mult = self.gravity_multiplier
    if self.velocity.y >= 0 then
        mult = mult * self.gravity_multiplier_down
    end
    return mult
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

-- XXX this is a FORCE, NOT acceleration!  and it is NOT trimmed to velocity
function MobileActor:get_friction(normalized_direction)
    local friction
    if not self:has_gravity() then
        -- In top-down mode, everything is always on flat ground, so
        -- friction is always the full amount, away from velocity
        friction = normalized_direction:normalized() * (-self.friction_decel * self:_get_carried_mass())
    elseif self.ground_normal then
        local gravity1 = self:get_gravity():normalized()
        -- Get the strength of the normal force by dotting the ground normal
        -- with gravity
        local normal_strength = gravity1 * self.ground_normal * self:_get_carried_mass()
        friction = self.ground_normal:perpendicular() * (self.friction_decel * self.ground_friction * normal_strength)
        local dot = friction * normalized_direction
        if math.abs(dot) < 1e-8 then
            -- Something went wrong and friction is perpendicular to movement?
            friction = Vector.zero
        elseif friction * normalized_direction > 0 then
            friction = -friction
        end
    else
        friction = -self.friction_decel * normalized_direction:normalized() * self.mass
        -- FIXME need some real air resistance; as written, the above also reverses gravity, oops
        friction = Vector.zero
    end
    return friction
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

    local friction = self:get_friction(direction)

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
        if collision.overlapped or not collision:faces(-self:get_gravity()) then
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
        self.ground_normal and
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
        nudge = nudge - nudge:projectOn(self.ground_normal)
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
            local collision = hits[actor.shape]
            if collision then
                collision.passable = 'pushed'
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

function MobileActor:check_for_ground(attempted, hits)
    if not self:has_gravity() then
        -- TODO maybe clear out all the ground stuff?
        return
    end

    local gravity = self:get_gravity()

    -- Ground test: did we collide with something facing upwards?
    -- Find the normal that faces /most/ upwards, i.e. most away from gravity.
    -- FIXME is that right?  isn't ground the flattest thing you're on?
    -- FIXME what if we hit the ground, then slid off of it?
    local mindot = 0  -- 0 is vertical, which we don't want
    local normal
    local actor
    local friction
    local terrain
    local carrier
    local carrier_normal
    for _, collision in pairs(hits) do
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
                actor = self.map.collider:get_owner(collision.shape)
                if actor then
                    friction = actor.friction_multiplier
                    terrain = actor.terrain_type
                    if actor.can_carry and self.is_portable then
                        carrier = actor
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

                local actor2 = self.map.collider:get_owner(collision.shape)
                if actor2 then
                    -- Prefer to stay on the same ground actor
                    if not (actor and actor == self.ptrs.ground) then
                        actor = actor2
                    end

                    -- Use the HIGHEST of any friction multiplier we're touching
                    -- FIXME should friction just be a property of terrain type?  where would that live, though?
                    if friction and actor2.friction_multiplier then
                        friction = math.max(friction, actor2.friction_multiplier)
                    else
                        friction = actor2.friction_multiplier
                    end

                    -- FIXME what does this do for straddling?  should do
                    -- whichever was more recent, but that seems like a Whole
                    -- Thing.  also should this live on TiledMapTile instead of
                    -- being a general feature?
                    terrain = actor2.terrain_type or terrain

                    -- Prefer to stay on the same carrier
                    if actor2.can_carry and self.is_portable and not (carrier and carrier == self.ptrs.cargo_of) then
                        carrier = actor2
                        carrier_normal = norm
                    end
                end
            end
        end
    end

    self.ground_normal = normal
    self.on_ground = not not normal
    self.ptrs.ground = actor
    self.ground_friction = friction or 1
    self.on_terrain = terrain

    if self.ptrs.cargo_of and self.ptrs.cargo_of ~= carrier then
        self.ptrs.cargo_of.cargo[self] = nil
        self.ptrs.cargo_of = nil
    end
    -- TODO i still feel like there should be some method for determining whether we're being carried
    -- TODO still seems rude that we inject ourselves into their cargo also
    if carrier then
        local manifest = carrier.cargo[self]
        if manifest then
            manifest.expiring = false
        else
            manifest = {}
            carrier.cargo[self] = manifest
        end
        manifest.state = CARGO_CARRYING
        manifest.normal = carrier_normal

        self.ptrs.cargo_of = carrier
    end
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
    -- TODO factor the ground_friction constant into this, and also into slope
    -- resistance
    if self:has_gravity() then
        self.pending_force = self.pending_force + self:get_gravity() * self:get_gravity_multiplier()
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
    local friction_force = self:get_friction(self.velocity)
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

    -- FIXME how does terminal velocity apply to integration?  if you get
    -- launched Very Fast the integration will take some of it into account
    -- still
    -- FIXME ah, gravity dependence
    local fluidres = self:get_fluid_resistance()
    self.velocity.y = math.min(self.velocity.y, terminal_velocity / fluidres)

    local attempted = frame_velocity * (dt / fluidres)
    if attempted == Vector.zero and self.may_skip_nudge then
        return Vector(), {}
    end

    -- Collision time!
    local movement, hits = self:nudge(attempted)

    self:check_for_ground(attempted, hits)

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
    decision_jump_mode = 0,
    decision_walk = 0,
    decision_move = Vector(),
    decision_climb = 0,
    decision_use = false,
    -- Flag indicating that we were deliberately pushed upwards since the last
    -- time we were on the ground; disables ground adherence and the jump
    -- velocity capping behavior
    was_launched = false,
    jump_count = 0,
    is_climbing = false,
    is_dead = false,
    is_locked = false,
}

-- Decide to start walking in the given direction.  -1 for left, 1 for right,
-- or 0 to stop walking.  Persists until changed.
function SentientActor:decide_walk(direction)
    self:decide_move(direction, nil)
end

-- Decide to start walking in the given direction.  Should be a unit vector,
-- unless you explicitly want a multiplier on movement acceleration (which will
-- still be capped by max_speed).  Persists until changed.
-- Arguments are separate so one or either can be 'nil', which is interpreted
-- as no change.
-- FIXME there should be a better way to override this (can i move freely up
-- and down) than by twiddling input
-- FIXME making this a unit vector is greatly at odds with the 'nil' support
function SentientActor:decide_move(vx, vy)
    self.decision_move = Vector(
        vx or self.decision_move.x,
        vy or self.decision_move.y)
    if vx then
        self.decision_walk = vx
    end
end

-- Decide to jump.
function SentientActor:decide_jump()
    if self.is_floating then
        return
    end

    -- Jumping has three states:
    -- 2: starting to jump
    -- 1: continuing a jump
    -- 0: not jumping (i.e., falling)
    self.decision_jump_mode = 2
end

-- Decide to abandon an ongoing jump, if any, which may reduce the jump height.
function SentientActor:decide_abandon_jump()
    self.decision_jump_mode = 0
end

-- Decide to climb.  Negative for up, positive for down, zero to stay in place,
-- nil to let go.
-- XXX i feel like perhaps i need to distinguish between "starting to climb" and "continuing to climb"
-- FIXME wait what is "nil"?  when can that happen?  there's no button for letting go??  check world i guess
function SentientActor:decide_climb(direction)
    -- Like jumping, climbing has multiple states: we use -2/+2 for the initial
    -- attempt, and -1/+1 to indicate we're still climbing.  Unlike jumping,
    -- this may still be called every frame, so updating it is a bit fiddlier.
    if direction == 0 or direction == nil then
        self.decision_climb = direction
    elseif direction > 0 then
        if self.decision_climb > 0 then
            self.decision_climb = 1
        else
            self.decision_climb = 2
        end
    else
        if self.decision_climb < 0 then
            self.decision_climb = -1
        else
            self.decision_climb = -2
        end
    end
end

-- If already climbing, stop, but keep holding on
function SentientActor:decide_pause_climbing()
    if self.decision_climb ~= nil then
        self.decision_climb = 0
    end
end

-- "Use" something (whatever that means)
function SentientActor:decide_use()
    self.decision_use = true
end

function SentientActor:get_gravity_multiplier()
    if self.is_climbing and not self.xxx_useless_climb then
        return 0
    end
    return SentientActor.__super.get_gravity_multiplier(self)
end

function SentientActor:push(dv)
    SentientActor.__super.push(self, dv)

    if dv * self:get_gravity() < 0 then
        self.was_launched = true
    end
end

function SentientActor:on_collide_with(actor, collision)
    -- Check for whether we're touching something climbable
    -- FIXME we might not still be colliding by the end of the movement!  this
    -- should use, now that that's only final hits -- though we need them to be
    -- in order so we can use the last thing touched.  same for mechanisms!
    if actor and actor.is_climbable then
        -- The reason for the up/down distinction is that if you're standing at
        -- the top of a ladder, you should be able to climb down, but not up
        -- FIXME these seem like they should specifically grab the highest and lowest in case of ties...
        -- FIXME aha, shouldn't this check if we're overlapping /now/?
        if collision.overlapped or collision:faces(Vector(0, -1)) then
            self.ptrs.climbable_down = actor
            self.on_climbable_down = collision
        end
        if collision.overlapped or collision:faces(Vector(0, 1)) then
            self.ptrs.climbable_up = actor
            self.on_climbable_up = collision
        end
    end

    -- Ignore collision with one-way platforms when climbing ladders, since
    -- they tend to cross (or themselves be) one-way platforms
    if collision.shape._xxx_is_one_way_platform and self.is_climbing then
        return true
    end

    local passable = SentientActor.__super.on_collide_with(self, actor, collision)

    -- If we're climbing downwards and hit something (i.e., the ground), let go
    if self.is_climbing and self.decision_climb > 0 and not passable and collision:faces(Vector(0, -1)) then
        self.is_climbing = false
        self.climbing = nil
        self.decision_climb = 0
    end

    return passable
end

function SentientActor:check_for_ground(...)
    SentientActor.__super.check_for_ground(self, ...)

    local gravity = self:get_gravity()
    local max_slope_dot = self.max_slope * gravity
    -- Sentient actors get an extra ground property, indicating whether the
    -- ground they're on is shallow enough to stand on; if not, they won't be
    -- able to jump, they won't have slope resistance, and they'll pretty much
    -- act like they're falling
    self.ground_shallow = self.ground_normal and not (self.ground_normal * gravity - max_slope_dot > 1e-8)

    -- Also they don't count as cargo if the contact normal is too steep
    -- TODO this is kind of weirdly inconsistent given that it works for
    -- non-sentient actors...?  should max_slope get hoisted just for this?
    if self.ptrs.cargo_of then
        local carrier = self.ptrs.cargo_of
        local manifest = carrier.cargo[self]
        if manifest and manifest.normal * gravity - max_slope_dot > 1e-8 then
            carrier.cargo[self] = nil
            self.ptrs.cargo_of = nil
        end
    end
end

function SentientActor:update(dt)
    if self.is_dead or self.is_locked then
        -- Ignore conscious decisions; just apply physics
        -- FIXME used to stop climbing here, why?  so i fall off ladders during transformations i guess?
        -- FIXME i think "locked" only makes sense for the player?
        return SentientActor.__super.update(self, dt)
    end

    -- Walking, in a way that works for both 1D and 2D behavior.  Treat the
    -- player's input (even zero) as a desired velocity, and try to accelerate
    -- towards it, capping at xaccel if necessary.
    -- (anonymous block because there are a lot of variables)
    do
        -- First figure out our target velocity
        local goal
        local current
        if self:has_gravity() then
            -- For 1D, find the direction of the ground, so walking on a slope
            -- will attempt to walk *along* the slope, not into it
            local ground_axis
            if self.ground_shallow then
                ground_axis = self.ground_normal:perpendicular()
            else
                -- We're in the air, so movement is horizontal
                ground_axis = Vector(1, 0)
            end
            goal = ground_axis * self.decision_move.x * self.max_speed
            current = self.velocity:projectOn(ground_axis)
        else
            -- For 2D, just move in the input direction
            -- FIXME this shouldn't normalize the movement vector, but i can't do it in decide_move for reasons described there
            goal = self.decision_move:normalized() * self.max_speed
            current = self.velocity
        end

        local delta = goal - current
        local delta_len = delta:len()
        local accel_cap = self.xaccel * dt
        -- Collect factors that affect our walk acceleration
        local walk_accel_multiplier = 1
        if delta_len > accel_cap then
            walk_accel_multiplier = accel_cap / delta_len
        end
        if self:has_gravity() then
            -- In the air (or on a steep slope), we're subject to air control
            if not self.ground_shallow then
                walk_accel_multiplier = walk_accel_multiplier * self.aircontrol
            end
        end
        -- If we're pushing something, then treat our movement as a force
        -- that's now being spread across greater mass
        -- XXX should this check can_push, can_carry?  can we get rid of total_mass i don't like it??
        if self.can_push and goal ~= Vector.zero then
            local total_mass = self:_get_total_mass(goal)
            walk_accel_multiplier = walk_accel_multiplier * self.mass / total_mass
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
        local skid = util.lerp((skid_dot + 1) / 2, self.deceleration, 1)

        -- Put it all together, and we're done
        self.velocity = self.velocity + delta * (skid * walk_accel_multiplier)
    end

    -- Update facing -- based on the input, not the velocity!
    -- FIXME should this have memory the same way conflicting direction keys do?
    if self:has_gravity() or math.abs(self.decision_move.x) > math.abs(self.decision_move.y) then
        if self.decision_move.x < 0 then
            self.facing = 'left'
        elseif self.decision_move.x > 0 then
            self.facing = 'right'
        end
    else
        if self.decision_move.y < 0 then
            self.facing = 'up'
        elseif self.decision_move.y > 0 then
            self.facing = 'down'
        end
    end

    -- Jumping
    self:handle_jump(dt)

    -- Climbing
    -- Immunity to gravity while climbing is handled via get_gravity_multiplier
    -- FIXME down+jump to let go, but does that belong here or in input handling?  currently it's in both and both are awkward
    -- TODO does climbing make sense in no-gravity mode?
    if self.decision_climb then
        if math.abs(self.decision_climb) == 2 or (math.abs(self.decision_climb) == 1 and self.is_climbing) then
            -- Trying to grab a ladder for the first time.  See if we're
            -- actually touching one!
            -- FIXME Note that we might already be on a ladder, but not moving.  unless we should prevent that case in decide_climb?
            if self.decision_climb < 0 and self.ptrs.climbable_up then
                self.ptrs.climbing = self.ptrs.climbable_up
                self.is_climbing = true
                self.climbing = self.on_climbable_up
                self.decision_climb = -1
            elseif self.decision_climb > 0 and self.ptrs.climbable_down then
                self.ptrs.climbing = self.ptrs.climbable_down
                self.is_climbing = true
                self.climbing = self.on_climbable_down
                self.decision_climb = 1
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
                self.velocity = self.velocity:projectOn(gravity)
            else
                self.velocity = Vector()
            end

            -- Slide us gradually towards the center of a ladder
            -- FIXME gravity dependant...?  how do ladders work in other directions?
            local x0, _y0, x1, _y1 = self.climbing.shape:bbox()
            local ladder_center = (x0 + x1) / 2
            local dx = ladder_center - self.pos.x
            local max_dx = self.climb_speed * dt
            dx = util.sign(dx) * math.min(math.abs(dx), max_dx)

            -- FIXME oh i super hate this var lol, it exists only for fox flux's slime lexy
            if self.xxx_useless_climb then
                -- Can try to climb, but is just affected by gravity as normal
                self:nudge(Vector(dx, 0))
            elseif self.decision_climb < 0 then
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
                self:nudge(Vector(dx, -climb_distance))
            elseif self.decision_climb > 0 then
                self:nudge(Vector(dx, self.climb_speed * dt))
            end

            -- Never flip a climbing sprite, since they can only possibly face in
            -- one direction: away from the camera!
            self.facing = 'right'

            -- We're not on the ground, but this still clears our jump count
            self.jump_count = 0
        end
    end
    -- Clear these pointers so collision detection can repopulate them
    self.ptrs.climbable_up = nil
    self.ptrs.climbable_down = nil
    self.on_climbable_up = nil
    self.on_climbable_down = nil

    -- Slope resistance: a sentient actor will resist sliding down a slope
    if self:has_gravity() and self.on_ground then
        local gravity = self:get_gravity()
        -- Slope resistance always pushes upwards along the slope.  It has no
        -- cap, since it should always exactly oppose gravity, as long as the
        -- slope is shallow enough.
        -- Skip it entirely if we're not even moving in the general direction
        -- of gravity, though, so it doesn't interfere with jumping.
        -- FIXME this doesn't take into account the gravity multiplier /or/
        -- fluid resistance, and in general i don't love that it can get out of
        -- sync like that  :S
        if self.ground_shallow then
            local slope = self.ground_normal:perpendicular()
            if slope * gravity > 0 then
                slope = -slope
            end
            local slope_resistance = -(gravity * slope)
            self.pending_force = self.pending_force + slope_resistance * slope
        end
    end

    -- Apply physics
    local was_on_ground = self.ground_normal
    local movement, hits = SentientActor.__super.update(self, dt)

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
    if self:has_gravity() and
        was_on_ground and not self.on_ground and
        not self.was_launched and
        self.decision_jump_mode == 0 and not self.is_climbing and
        self.gravity_multiplier > 0 and self.gravity_multiplier_down > 0
    then
        local gravity = self:get_gravity()
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
        local prelim_movement = self.map.collider:sweep(self.shape, drop * 1.1, function(collision)
            if collision.contact_type <= 0 then
                return true
            end
            local actor = self.map.collider:get_owner(collision.shape)
            if actor == self then
                return true
            end
            if actor then
                return not actor:blocks(self, collision)
            else
                return false
            end
        end)

        if prelim_movement:len2() <= drop:len2() then
            -- We hit the ground!  Do that again, but for real this time.
            local drop_movement
            drop_movement, hits = self:nudge(drop, nil, true)
            movement = movement + drop_movement
            self:check_for_ground(drop_movement, hits)

            if self.on_ground then
                -- Now we're on the ground, so flatten our velocity to indicate
                -- we're walking along it.  Or equivalently, remove the part
                -- that's trying to launch us upwards.
                self.velocity = self.velocity - self.velocity:projectOn(self.ground_normal)
            end
        end
    end

    -- Handle our own passive physics
    if self:has_gravity() and self.on_ground then
        self.jump_count = 0
        self.was_launched = false
    end

    -- Update the pose
    self:update_pose()

    -- Use whatever's now in front of us
    if self.decision_use then
        self:use()
        self.decision_use = false
    end

    return movement, hits
end

function SentientActor:handle_jump(dt)
    if not self:has_gravity() then
        return
    end

    -- Jumping
    -- This uses the Sonic approach: pressing jump immediately sets (not
    -- increases!) the player's y velocity, and releasing jump lowers the y
    -- velocity to a threshold
    if self.decision_jump_mode == 2 then
        self.decision_jump_mode = 1
        if self.velocity.y <= -self.jumpvel then
            -- Already moving upwards at jump speed, so nothing to do
            return
        end

        -- You can "jump" off a ladder, but you just let go.  Only works if
        -- you're holding a direction or straight down
        if self.is_climbing then
            if self.decision_climb > 0 or self.decision_move ~= Vector.zero then
                -- Drop off
                self.is_climbing = false
            end
            return
        end

        if self.jump_count == 0 and not self.ground_shallow and not self.is_climbing then
            -- If we're in mid-air for some other reason, act like we jumped to
            -- get here, for double-jump counting purposes
            self.jump_count = 1
        end
        if self.jump_count >= self.max_jumps then
            -- No more jumps left
            return
        end

        -- Perform the actual jump
        self.velocity.y = -self.jumpvel
        self.jump_count = self.jump_count + 1

        if self.jump_sound then
            -- FIXME oh boy, this is gonna be a thing that i have to care about in a lot of places huh
            local sfx = game.resource_manager:get(self.jump_sound):clone()
            if sfx:getChannelCount() == 1 then
                sfx:setRelative(true)
            end
            sfx:play()
        end

        -- If we were climbing, we shouldn't be now
        self.is_climbing = false
        self.climbing = nil
        self.decision_climb = 0
    elseif self.decision_jump_mode == 0 then
        -- We released jump at some point, so cut our upwards velocity
        if not self.on_ground and not self.was_launched then
            self.velocity.y = math.max(self.velocity.y, -self.jumpvel * self.jumpcap)
        end
    end
end

-- Use something, whatever that means
-- TODO a basic default implementation might be nice!
-- TODO i think that would require a basic default implementation of /finding/
-- an item to use, too, which could be either overlap or raycast
function SentientActor:use()
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
    if self.is_dead then
        return 'die'
    elseif self.is_floating then
        return 'fall'
    elseif self.is_climbing then
        if self.decision_climb < 0 then
            return 'climb'
        elseif self.decision_climb > 0 then
            return 'descend'
        else
            return 'hold'
        end
    elseif not self:has_gravity() or (self.ground_normal and self.ground_shallow) then
        if self.decision_move ~= Vector.zero then
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
