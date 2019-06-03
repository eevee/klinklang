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

-- FIXME probably make this a method on a Collision object or something
local function any_normal_faces(collision, direction)
    if collision.left_normal and collision.left_normal * direction > 0 then
        return true
    end
    if collision.right_normal and collision.right_normal * direction > 0 then
        return true
    end
    return false
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

    self.total_mass = self.mass
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
        if friction * normalized_direction > 0 then
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
function MobileActor:_get_total_friction(direction, _seen, __v)
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
            friction = friction + actor:_get_total_friction(direction, _seen, manifest.velocity)
        end
    end
    --print("- " .. tostring(self), friction:projectOn(direction), self:_get_total_mass(direction), friction:projectOn(direction) / self:_get_total_mass(direction), __v)
    return friction
end

-- Lower-level function passed to the collider to determine whether another
-- object blocks us
-- FIXME now that they're next to each other, these two methods look positively silly!  and have a bit of a symmetry problem: the other object can override via the simple blocks(), but we have this weird thing
function MobileActor:on_collide_with(actor, collision)
    -- Moving away or along is always fine
    if collision.contact_type < 0 then
        return true
    elseif collision.contact_type == 0 then
        return 'slide'
    end

    -- FIXME doubtless need to fix overlap collision with a pushable
    -- One-way platforms only block us when we collide with an
    -- upwards-facing surface.  Expressing that correctly is hard.
    -- FIXME un-xxx this and get it off the shape
    -- FIXME make this less about gravity and more about a direction
    -- FIXME why is this here and not in blocks()??  oh because blocks didn't always take collision, and still isn't documented as such
    if collision.shape._xxx_is_one_way_platform then
        if collision.overlapped or not any_normal_faces(collision, -self:get_gravity()) then
            return true
        end
    end

    -- Otherwise, fall back to trying blocks(), if the other thing is an actor
    if actor and not actor:blocks(self, collision) then
        return true
    end

    -- Otherwise, we're blocked!
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
            any_normal_faces(collision, gravity) and
            not pushers[actor]
        then
            -- If we rise into a portable actor, pick it up -- push it the rest
            -- of the distance we're going to move.  On its next ground check,
            -- it should notice us as its carrier.
            -- FIXME this isn't quite right, since we might get blocked and not
            -- actually move this whole distance!  but chances are they will be
            -- too so this isn't a huge deal
            local nudge = collision.attempted - collision.movement
            if not _is_vector_almost_zero(nudge) then
                actor:nudge(nudge, pushers)
            end
            return true
        end
    end

    -- Check for pushing
    if actor and
        -- It has to be pushable, of course
        self.can_push and actor.is_pushable and
        -- It has to be in our way
        not passable and not collision.overlapped and
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
        (not collision.left_normal or math.abs(collision.left_normal:normalized().y) < 0.25) and
        (not collision.right_normal or math.abs(collision.right_normal:normalized().y) < 0.25) and
        -- If we already pushed this object during this nudge, it must be
        -- blocked or on a slope or otherwise unable to keep moving, so let it
        -- block us this time
        already_hit[actor] ~= 'nudged' and
        -- Avoid a push loop, which could happen in pathological cases
        not pushers[actor]
    then
        local nudge = collision.attempted - collision.movement
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
        -- XXX if we get rid of manifest.velocity then this might not matter, just overwrite it
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
            print("about to nudge", actor, actor.is_pushable, actor.is_portable)
            local actual = actor:nudge(nudge, pushers)
            if _is_vector_almost_zero(actual) then
                -- Cargo is blocked, so we can't move either
                print('oh no, its blocked', actor)
                already_hit[actor] = 'blocked'
                manifest.state = CARGO_BLOCKED
            else
                already_hit[actor] = 'nudged'
                passable = 'retry'
                manifest.state = CARGO_PUSHING
            end
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
    local last_direction = movement
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
        if math.abs(remaining.x) < 1/64 and math.abs(remaining.y) < 1/64 then
            break
        end

        -- Find the allowed slide direction that's closest to the direction of movement.
        local slid
        movement, slid = Collision:slide_along_normals(hits, remaining)
        if not slid then
            break
        end

        if math.abs(movement.x) < 1/64 and math.abs(movement.y) < 1/64 then
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
    for actor, hit_type in pairs(already_hit) do
        if hit_type == 'nudged' then
            local collision = hits[actor.shape]
            if collision then
                collision.pushed = true
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

    -- If we didn't even try to move in the direction of gravity, we shouldn't
    -- count as on the ground, even if we're a projectile sliding along it.
    if attempted * gravity <= 0 then
        -- TODO maybe clear out all the ground stuff?
        return
    end

    -- Ground test: did we collide with something facing upwards?
    -- Find the normal that faces /most/ upwards, i.e. most away from gravity.
    -- FIXME what if we hit the ground, then slid off of it?
    local mindot = 0  -- 0 is vertical, which we don't want
    local normal
    local actor
    local friction
    local terrain
    local carrier
    local carrier_normal
    for _, collision in pairs(hits) do
        if not collision.passable or collision.passable == 'slide' then
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
        manifest.normal = normal

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

    -- XXX this is where friction used to go

    -- This is basically vt + ½at², and makes the results exactly correct, as
    -- long as pending_force contains constant sources of acceleration (like
    -- gravity).  It avoids problems like jump height being eroded too much by
    -- the first tic of gravity at low framerates.  Not quite sure what it's
    -- called, but it's similar to Verlet integration and the midpoint method.
    local dv = self.pending_force * dt
    local displacement = (self.velocity + 0.5 * dv) * dt
    self.pending_force = Vector()
    self.velocity = self.velocity + dv

    -- FIXME how does terminal velocity apply to integration?  if you get
    -- launched Very Fast the integration will take some of it into account
    -- still
    local fluidres = self:get_fluid_resistance()
    self.velocity.y = math.min(self.velocity.y, terminal_velocity / fluidres)

    if displacement == Vector.zero and self.may_skip_nudge then
        return Vector(), {}
    end

    -- Fudge the movement to try ending up aligned to the pixel grid.
    -- This helps compensate for the physics engine's love of gross float
    -- coordinates, and should allow the player to position themselves
    -- pixel-perfectly when standing on pixel-perfect (i.e. flat) ground.
    -- FIXME i had to make this round to the nearest eighth because i found a
    -- place where standing on a gentle slope would make you vibrate back and
    -- forth between pixels.  i don't think that's the case any more, though,
    -- and it would be nice to make this work for pushing as well, so you can
    -- push an object down a gap its own size!  the only problem is that it has
    -- a nontrivial impact on overall speed.  maybe we should only do this when
    -- moving slowly?
    local goalpos = self.pos + displacement / fluidres
    --[[
    if self.velocity.x ~= 0 then
        goalpos.x = math.floor(goalpos.x * 8 + 0.5) / 8
    end
    if self.velocity.y ~= 0 then
        goalpos.y = math.floor(goalpos.y * 8 + 0.5) / 8
    end
    ]]
    local attempted = goalpos - self.pos

    -- If we're a pusher, we need to know how much we're pushing before and
    -- after, so we can scale our velocity to match the change in mass
    -- FIXME get rid of this var, also this breaks detaching a push chain
    local old_total_mass = self:_get_total_mass(attempted_velocity)

    -- Collision time!
    local movement, hits = self:nudge(attempted)

    self:check_for_ground(attempted, hits)

    -- Do some cargo-related bookkeeping.  This is, unfortunately, entangled
    -- with friction, because friction is what controls how much we can push
    -- /and/ when we stop pushing something.
    -- So, first, get our own friction.
    local our_friction_force = self:get_friction(self.velocity)
    local friction_force = our_friction_force
    -- First, check all our push cargo; if we didn't just push it, it's not
    -- cargo any more.  Impart our momentum into it.
    for actor, manifest in pairs(self.cargo) do
        local detach = false
        if manifest.expiring then
            -- We didn't push or carry this actor this frame, so we must have
            -- come detached from it.
            detach = true
        elseif manifest.state == CARGO_PUSHING and manifest.velocity then
            -- Deal with push friction
            local cargo_friction_force = actor:_get_total_friction(-manifest.normal)
            local cargo_mass = actor:_get_total_mass(manifest.velocity)
            local friction_delta = cargo_friction_force / cargo_mass * dt
            local cargo_dot = (manifest.velocity + friction_delta) * manifest.normal
            local actual_dot = self.velocity * manifest.normal
            if actual_dot <= cargo_dot then
                -- We're either trying to move faster (and thus actually
                -- pushing), or moving at the same speed (like two identical
                -- crates sliding together).  Add their friction to the total
                -- and continue as normal.
                friction_force = friction_force + cargo_friction_force * self.push_resistance_multiplier
            else
                -- We're moving more slowly than the rest of the system; we
                -- might be a sentient actor turning away, or just heavier or
                -- more frictional than whatever we're pushing.  Detach.
                detach = true
            end
        end

        -- Detach any cargo that's no longer connected.
        -- NOTE: This work is FRAMERATE DEPENDENT, because it always takes one
        -- frame to detach.
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
        end
    end

    if self.can_push or self.can_carry then
        -- If the mass of this whole push system increased, then conserve
        -- momentum.  (Don't if it decreased, because the max speed of a
        -- sentient actor is still the same, and they shouldn't go flying when
        -- a box disappeared or whatever.)
        -- FIXME lol this sends you flying if you jump while pushing something gdi
        -- TODO can we only update this if we know we pushed something, maybe?
        -- FIXME technically this should happen iff the set of objects /changed/...
        -- FIXME again this is completely irrelevant for a mechanism with fixed speed
        self.total_mass = self:_get_total_mass(attempted_velocity)
        if self.total_mass ~= 0 and self.total_mass > old_total_mass then
            local seen = {}
            local function get_total_momentum(actor)
                if seen[actor] then
                    return Vector()
                end
                seen[actor] = true

                local total_velocity = actor.velocity * actor.mass
                for other_actor, manifest in pairs(actor.cargo) do
                    if manifest.state == CARGO_PUSHING then
                        total_velocity = total_velocity + get_total_momentum(other_actor)
                        -- FIXME this should be transitive, but that's complicated with loops, sigh
                        -- FIXME should only collect velocity in the push direction?
                        other_actor.velocity = other_actor.velocity - other_actor.velocity:projectOn(manifest.normal)
                    end
                end
                return total_velocity
            end
            local total_velocity = get_total_momentum(self)
            -- FIXME this is ugly
            -- FIXME also this doesn't only adjust our velocity along the push direction!!
            self.velocity = self.velocity * (1 - self.push_momentum_multiplier) + total_velocity * (self.push_momentum_multiplier / self.total_mass)
        end
    end

    -- Finally, mark all cargo as potentially expiring (if we haven't seen it
    -- again by next frame), and update the system velocity of pushees.
    for actor, manifest in pairs(self.cargo) do
        manifest.expiring = true
        if manifest.state == CARGO_PUSHING then
            manifest.velocity = self.velocity
        else
            manifest.velocity = nil
        end
    end

    -- Trim velocity as necessary, based on our last slide
    -- FIXME this is clearly wrong and we need to trim it as we go, right?
    -- FIXME this needs to ignore cases where already_hit[owner] == 'nudged'
    -- or...  maybe not?  comment from when i was working on pushing in fox flux:
    --      so if we pushed an object and it was blocked, we'd see 'blocked'
    --      here and add it to the clock.  if we pushed an object and it moved,
    --      we'd see 'nudged' here and ignore it since we can continue moving
    --      in that direction.  but if we pushed an object and it /slid/...?
    --      the best i can think of here is if we trim velocity to movement /
    --      dt, which sounds, slightly crazy
    if self.velocity ~= Vector.zero then
        self.velocity = Collision:slide_along_normals(hits, self.velocity)
    end

    -- Friction -- the general tendency for everything to decelerate.
    -- It always pushes against the direction of motion, but never so much that
    -- it would reverse the motion.
    -- This is implemented with a recursive function so it can take into
    -- account any extra friction from objects we're trying to push.
    -- FIXME this very much seems like it should be a pending force, but that
    -- makes capping it trickier
    -- FIXME because this doesn't know about pending forces, it might still
    -- move you backwards?  how DO i integrate this correctly?
    -- FIXME i don't know how i feel about having this after cargo; maybe see
    -- if things are simpler back the other way
    -- FIXME this is /completely/ irrelevant for something with constant
    -- velocity (like a moving platform) or something immobile
    -- XXX trying to put this last because we need to know cargo to decide whether we need the whole system's friction or not
    if friction_force ~= Vector.zero and self.velocity ~= Vector.zero then
        local friction_decel = friction_force:projectOn(self.velocity) / self.total_mass
        local friction_delta = friction_decel * dt
        friction_delta:trimInplace(self.velocity:len())
        self.velocity = self.velocity + friction_delta
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
    decision_use = false,
    in_mid_jump = false,
    jump_count = 0,
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

-- Decide to climb.  -1 up, 1 down, 0 to stay in place, nil to let go.
function SentientActor:decide_climb(direction)
    self.decision_climb = direction
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
    if self.decision_climb and not self.xxx_useless_climb then
        return 0
    end
    return SentientActor.__super.get_gravity_multiplier(self)
end

function SentientActor:push(dv)
    SentientActor.__super.push(self, dv)

    -- This flag disables trimming our upwards velocity when releasing jump
    if self.in_mid_jump and dv * self:get_gravity() < 0 then
        self.in_mid_jump = false
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
        if collision.overlapped or any_normal_faces(collision, Vector(0, -1)) then
            self.ptrs.climbable_down = actor
        end
        if collision.overlapped or any_normal_faces(collision, Vector(0, 1)) then
            self.ptrs.climbable_up = actor
        end
    end

    -- Ignore collision with one-way platforms when climbing ladders, since
    -- they tend to cross (or themselves be) one-way platforms
    if collision.shape._xxx_is_one_way_platform and self.decision_climb then
        return true
    end

    return SentientActor.__super.on_collide_with(self, actor, collision)
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
    -- TODO why is decision_climb special-cased in so many places here?
    if self.is_dead or self.is_locked then
        -- Ignore conscious decisions; just apply physics
        -- FIXME i think "locked" only makes sense for the player?
        self.decision_climb = nil
        return SentientActor.__super.update(self, dt)
    end

    -- Check whether climbing is possible
    -- FIXME i'd like to also stop climbing when we hit an object?  downwards i mean
    -- TODO does climbing make sense in no-gravity mode?
    if self.decision_climb and not (
        (self.decision_climb <= 0 and self.ptrs.climbable_up) or
        (self.decision_climb >= 0 and self.ptrs.climbable_down))
    then
        self.decision_climb = nil
    end

    local xmult
    local max_speed = self.max_speed
    local xdir = Vector(1, 0)
    if not self:has_gravity() then
        xmult = 1
    elseif self.on_ground then
        local uphill = self.decision_walk * self.ground_normal.x < 0
        -- This looks a bit more convoluted than just moving the player right
        -- and letting sliding take care of it, but it means that walking
        -- /down/ a slope will actually walk us along it
        xdir = self.ground_normal:perpendicular()
        xmult = self.ground_friction
        if uphill then
            if self.ground_shallow then
                xmult = 0
            else
                -- Linearly scale the slope slowdown, based on the y coordinate (of
                -- the normal, which is the x coordinate of the slope itself).
                -- This isn't mathematically correct, but it feels fine.
                local ground_y = math.abs(self.ground_normal.y)
                local max_y = math.abs(self.max_slope.y)
                local slowdown = 1 - (1 - self.max_slope_slowdown) * (1 - ground_y) / (1 - max_y)
                max_speed = max_speed * slowdown
                xmult = xmult * slowdown
            end
        end
    else
        xmult = self.aircontrol
    end

    -- If we're pushing something, then treat our movement as a force that's
    -- now being spread across greater mass
    -- XXX should this check can_push, can_carry?  can we get rid of total_mass i don't like it??
    xmult = xmult * self.mass / self.total_mass

    -- Explicit movement
    if not self:has_gravity() then
        -- The idea here is to treat your attempted direction times your max
        -- speed as a goal, attempt to accelerate your current velocity towards
        -- it, and cap that acceleration at your acceleration speed.
        -- This works as you'd expect for 1D cases, but extends neatly to 2D.
        -- TODO use this for 1D as well!  needs to ignore the gravity axis tho
        -- FIXME this shouldn't normalize the movement vector, but i can't do it in decide_move for reasons described there
        local goal = self.decision_move:normalized() * self.max_speed
        -- NOTE: This is equivalent to delta:trimmed(...), but trimmed() chokes
        -- on zero vectors.
        local delta = goal - self.velocity
        local delta_len = delta:len()
        local accel_cap = self.xaccel * dt
        if delta_len > accel_cap then
            delta = delta * (accel_cap / delta_len)
            delta_len = accel_cap
        end
        -- When inputting no movement at all, an actor is considered to be
        -- /de/celerating, since they clearly want to stop.  Deceleration is
        -- slower then acceleration, and this "skid" factor interpolates
        -- between full decel and full accel using the dot product.
        -- Slightly tricky to normalize them, since they could be zero.
        local skid_dot = delta * self.velocity
        if skid_dot ~= 0 then
            skid_dot = skid_dot / self.velocity:len() / delta_len
        end
        local skid = util.lerp((skid_dot + 1) / 2, self.deceleration, 1)
        -- And we're done.
        self.velocity = self.velocity + delta * skid

        -- Update facing, based on the input, not the velocity
        -- FIXME should this have memory the same way conflicting direction keys do?
        local abs_vx = math.abs(self.decision_move.x)
        local abs_vy = math.abs(self.decision_move.y)
        if abs_vx > abs_vy then
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
    elseif self.decision_walk > 0 then
        -- FIXME hmm is this the right way to handle a maximum walking speed?
        -- it obviously doesn't work correctly in another frame of reference
        if self.velocity.x < max_speed then
            local dx = math.min(max_speed - self.velocity.x, self.xaccel * xmult * dt)
            self.velocity = self.velocity + dx * xdir
        end
        self.facing = 'right'
    elseif self.decision_walk < 0 then
        if self.velocity.x > -max_speed then
            local dx = math.min(max_speed + self.velocity.x, self.xaccel * xmult * dt)
            self.velocity = self.velocity - dx * xdir
        end
        self.facing = 'left'
    elseif self.ground_shallow then
        -- Not walking means we're trying to stop, albeit leisurely
        -- Climbing means you're holding onto something sturdy, so give a deceleration bonus
        if self.decision_climb then
            xmult = xmult * 3
        end
        local dx = math.min(math.abs(self.velocity * xdir), self.xaccel * self.deceleration * xmult * dt)
        local dv = dx * xdir
        if dv * self.velocity < 0 then
            self.velocity = self.velocity + dv
        else
            self.velocity = self.velocity - dv
        end
    end

    self:handle_jump(dt)

    -- Climbing
    -- Immunity to gravity while climbing is handled via get_gravity_multiplier
    if self.decision_climb then
        if self.xxx_useless_climb then
            -- Can try to climb, but is just affected by gravity as normal
        elseif self.decision_climb > 0 then
            -- Climbing is done with a nudge, rather than velocity, to avoid
            -- building momentum which would then launch you off the top
            -- FIXME need to cancel all velocity (and reposition??) when first grabbing the ladder
            self:nudge(Vector(0, -self.climb_speed * dt))
        elseif self.decision_climb < 0 then
            self:nudge(Vector(0, self.climb_speed * dt))
        else
            self.velocity.y = 0
        end

        -- Never flip a climbing sprite, since they can only possibly face in
        -- one direction: away from the camera!
        self.facing = 'right'

        -- FIXME pretty sure this doesn't actually work, since it'll be
        -- overwritten by update() below and never gets to apply to jumping
        self.on_ground = true
        self.ground_normal = Vector(0, -1)
    end
    self.ptrs.climbable_up = nil
    self.ptrs.climbable_down = nil

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
        self.decision_jump_mode == 0 and self.decision_climb == nil and
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
        if bottom_drop * gravity < 0 then
            bottom_drop = -bottom_drop
        end
        -- This factor of 2 solves a subtle problem: on the frame we walk off a
        -- slope, we don't hit anything else, so we don't bother checking for
        -- new collisions and we think we're still on the ground!  So we need
        -- to account for TWO frames' worth of drop, urgh.
        -- FIXME this would be nice to fix somehow
        local drop = (top_drop + bottom_drop) * 2

        -- Try dropping our shape, just to see if we /would/ hit anything, but
        -- without firing any collision triggers or whatever.  Try moving a
        -- little further than our max, just because that's an easy way to
        -- distinguish exactly hitting the ground from not hitting anything.
        local prelim_movement = self.map.collider:sweep(self.shape, drop * 1.1, function(collision)
            local actor = self.map.collider:get_owner(collision.shape)
            if actor == self then
                return true
            end
            if actor then
                return not actor:blocks(self, collision)
            end
            return true
        end)

        if prelim_movement:len2() <= drop:len2() then
            -- We hit the ground!  Do that again, but for real this time.
            local drop_movement
            drop_movement, hits = self:nudge(drop, nil, true)
            movement = movement + drop_movement
            self:check_for_ground(drop, hits)

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
        self.in_mid_jump = false
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
        -- You cannot climb while jumping, sorry
        -- TODO but maybe...  you can hold up + jump, and regrab the ladder only at the apex of the jump?
        self.decision_jump_mode = 1
        if self.jump_count == 0 and not self.ground_shallow then
            self.jump_count = 1
        end
        if self.jump_count < self.max_jumps or (self.decision_climb and not self.xxx_useless_climb) then
            -- TODO maybe jump away from the ground, not always up?  then could
            -- allow jumping off of steep slopes
            local jumped
            if self.ground_normal and not self.ground_shallow then
                self.velocity = self.jumpvel * self.ground_normal
                jumped = true
            elseif self.velocity.y > -self.jumpvel then
                self.velocity.y = -self.jumpvel
                jumped = true
            end

            if jumped then
                self.in_mid_jump = true
                self.jump_count = self.jump_count + 1
                self.decision_climb = nil
                if self.jump_sound then
                    -- FIXME oh boy, this is gonna be a thing that i have to care about in a lot of places huh
                    local sfx = game.resource_manager:get(self.jump_sound):clone()
                    if sfx:getChannelCount() == 1 then
                        sfx:setRelative(true)
                    end
                    sfx:play()
                end
            end
        end
    elseif self.decision_jump_mode == 0 then
        if not self.on_ground and self.in_mid_jump then
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
    elseif self.decision_climb then
        if self.decision_climb < 0 then
            self.sprite.anim:resume()
            return 'climb'
        elseif self.decision_climb > 0 or self.velocity.x ~= 0 then
            -- Include "climbing" sideways
            self.sprite.anim:resume()
            return 'descend'
        else
            -- Not moving; pause the current pose (which must already be climb
            -- or descend, since getting on a ladder requires movement)
            self.sprite.anim:pause()
            return
        end
    elseif not self:has_gravity() or (self.ground_normal and self.ground_shallow) then
        if self.decision_move ~= Vector.zero then
            return 'walk'
        end
    elseif self.in_mid_jump and self.velocity.y < 0 then
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
    any_normal_faces = any_normal_faces,
}
