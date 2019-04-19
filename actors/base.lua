local Vector = require 'klinklang.vendor.hump.vector'

local Object = require 'klinklang.object'
local util = require 'klinklang.util'
local whammo_shapes = require 'klinklang.whammo.shapes'

-- FIXME rather not
local tiledmap = require 'klinklang.tiledmap'

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
}

function Actor:init(position)
    self.pos = position

    -- Table of weak references to other actors
    self.ptrs = setmetatable({}, { __mode = 'v' })

    -- TODO arrgh, this global.  sometimes i just need access to the game.
    -- should this be done on enter, maybe?
    -- FIXME should show a more useful error if this is missing
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

    self.health = self.max_health
end

-- Called once per update frame; any state changes should go here
function Actor:update(dt)
    self.timer = self.timer + dt
    self.sprite:update(dt)
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
    -- TODO separate code from twiddles
    velocity = nil,

    -- Passive physics parameters
    -- Units are pixels and seconds!
    min_speed = 1,
    -- FIXME i feel like this is not done well.  floating should feel floatier
    -- FIXME friction should probably be separate from deliberate deceleration?
    friction_decel = 512,
    ground_friction = 1,
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
    is_portable = false,  -- Can this be carried?
    can_carry = false,  -- Can this carry?
    mass = 1,  -- Pushing a heavier object will slow you down
    cargo = nil,  -- Set of currently-carried objects

    -- Physics state
    on_ground = false,
}

function MobileActor:init(...)
    MobileActor.__super.init(self, ...)

    self.velocity = Vector()
end

function MobileActor:on_enter(...)
    MobileActor.__super.on_enter(self, ...)
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
    if self.velocity.y > 0 then
        mult = mult * self.gravity_multiplier_down
    end
    return mult
end

-- Lower-level function passed to the collider to determine whether another
-- object blocks us
-- FIXME now that they're next to each other, these two methods look positively silly!  and have a bit of a symmetry problem: the other object can override via the simple blocks(), but we have this weird thing
function MobileActor:on_collide_with(actor, collision)
    if collision.touchtype < 0 then
        -- Objects we're overlapping are always passable
        return true
    end

    -- One-way platforms only block us when we collide with an
    -- upwards-facing surface.  Expressing that correctly is hard.
    -- FIXME un-xxx this and get it off the shape
    -- FIXME make this less about gravity and more about a direction
    if collision.shape._xxx_is_one_way_platform then
        if not any_normal_faces(collision, -self:get_gravity()) then
            return true
        end
    end

    -- Otherwise, fall back to trying blocks(), if the other thing is an actor
    -- TODO is there any reason not to just merge blocks() with on_collide()?
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
    local hit_this_actor = already_hit[actor]
    if actor and not hit_this_actor then
        -- FIXME movement is fairly misleading and i'm not sure i want to
        -- provide it, at least not in this order
        actor:on_collide(self, movement, collision)
        already_hit[actor] = true
    end

    -- Debugging
    if game.debug and game.debug_twiddles.show_collision then
        game.debug_hits[collision.shape] = collision
    end

    -- FIXME again, i would love a better way to expose a normal here.
    -- also maybe the direction of movement is useful?
    local passable = self:on_collide_with(actor, collision)

    -- Pushing
    if actor and self.cargo and self.cargo[actor] then
        -- If the other actor is already our cargo, ignore it for now, since
        -- we'll move it at the end of our movement
        -- FIXME this is /technically/ wrong if the carrier is blockable, but so
        -- far all of mine are not.  one current side effect is that if you're
        -- on a crate on a platform moving up, and you hit a ceiling, then you
        -- get knocked off the crate rather than the crate being knocked
        -- through the platform.
        return true
    end
    if actor and not pushers[actor] and collision.touchtype >= 0 and not passable and (
        (actor.is_pushable and self.can_push) or
        -- This allows a carrier to pick up something by rising into it
        -- FIXME check that it's pushed upwards?
        -- FIXME this is such a weird fucking case though
        (actor.is_portable and self.can_carry))
    then
        local nudge = collision.attempted - collision.movement
        -- Only push in the direction the collision occurred!  If several
        -- directions, well, just average them
        local axis = Vector()
        local normalct = 0
        for normal in pairs(collision.normals) do
            normalct = normalct + 1
            axis = axis + normal
        end
        if normalct > 0 then
            nudge = nudge:projectOn(axis / normalct)
        else
            nudge = Vector.zero
        end
        if already_hit[actor] == 'nudged' or _is_vector_almost_zero(nudge) then
            -- If we've already pushed this object once, or we're not actually
            -- trying to push it, do nothing...  but pretend it's solid, so we
            -- don't, say, fall through it
            passable = false
            --already_hit[actor] = 'blocked'
        else
            -- TODO the mass thing is pretty cute, but it doesn't chain --
            -- the player moves the same speed pushing one crate as pushing
            -- five of them
            local actual = actor:nudge(nudge * math.min(1, self.mass / actor.mass), pushers)
            if _is_vector_almost_zero(actual) then
                -- Cargo is blocked, so we can't move either
                already_hit[actor] = 'blocked'
                passable = false
            else
                already_hit[actor] = 'nudged'
                passable = 'retry'
            end
        end
    end

    -- Ground test: did we collide with something facing upwards?
    -- Find the normal that faces /most/ upwards, i.e. most away from gravity.
    -- This has to be done HERE because after all collisions are resolved, we
    -- slide any remaining velocity, which means we no longer know that we
    -- actually HIT the ground rather than merely sliding along it!
    if self:has_gravity() and not passable and collision.touchtype > 0 then
        local mindot = 0  -- 0 is vertical, which we don't want
        local ground  -- normalized ground normal
        local ground_actor  -- actor carrying us, if any
        local new_friction
        local normals = {collision.left_normal, collision.right_normal}
        local gravity = self:get_gravity()
        for i = 1, 2 do
            local normal = normals[i]
            if normal then
                local normal1 = normal:normalized()
                local dot = normal1 * gravity
                if dot < mindot then
                    mindot = dot
                    ground = normal1
                end
                if dot < mindot or (dot == mindot and not ground_actor) then
                    ground_actor = self.map.collider:get_owner(collision.shape)
                    if ground_actor and type(ground_actor) == 'table' and ground_actor.isa then
                        local friction
                        if ground_actor:isa(Actor) then
                            -- TODO? friction = ground_actor.friction
                        elseif ground_actor:isa(tiledmap.TiledTile) then
                            friction = ground_actor:prop('friction')
                        end
                        if not new_friction or (friction and friction > new_friction) then
                            new_friction = friction
                        end
                    end
                    -- FIXME what does this do for straddling?  should do
                    -- whichever was more recent, but that seems like a Whole
                    -- Thing.  also should this live on TiledMapTile instead of
                    -- being a general feature?
                    if ground_actor and ground_actor.terrain then
                        -- FIXME defer this too
                        self.new_terrain = ground_actor.terrain
                    end
                    if ground_actor and not ground_actor.can_carry then
                        ground_actor = nil
                    end
                end
            end
        end
        if ground then
            self.new_ground_normal = ground
            self.new_ground_friction = new_friction or 1
        end
        -- FIXME this can go wrong if our carrier is removed from the map.  or
        -- we're removed from the map, for that matter!  can fix this now though
        -- FIXME wait, does this still go here
        if self.ptrs.cargo_of ~= ground_actor then
            if self.ptrs.cargo_of then
                self.ptrs.cargo_of.cargo[self] = nil
                self.ptrs.cargo_of = nil
            end
            if ground_actor then
                ground_actor.cargo[self] = true
                self.ptrs.cargo_of = ground_actor
            end
        end
    end

    if not self.is_blockable and not passable then
        return true
    else
        return passable
    end
end

-- This function has the glorious and awkward honor of having to handle literal
-- corner cases.  To do that, it splits the normals into two: those on our left
-- (ccw), and those on our right (cw).  When we hit a corner, its two sides are
-- handled separately.  When we hit a wall, that makes one slide direction
-- impossible, so we mark it as such.
local function slide_along_normals(hits, direction)
    local minleftdot = 0
    local minleftnorm
    local minrightdot = 0
    local minrightnorm
    local blocked_left = false
    local blocked_right = false

    -- Each collision tracks two normals: the nearest surface blocking movement
    -- on the left, and the nearest on the right (relative to the direction of
    -- movement).  Most collisions only have one or the other, meaning we hit a
    -- wall on that side.  If a single collision has BOTH normals, that means
    -- this is a corner-corner collision, which is ambiguous: we could slide
    -- either way, and we'll pick whichever is closest to our direction of
    -- movement.
    -- If there are two DIFFERENT collisions, one with only a left normal and
    -- one with only a right normal, then we're stuck: we're completely blocked
    -- by separate objects on both sides, like being wedged into the corner of
    -- a room.
    -- However, if there's a collision with ONLY (e.g.) a left normal and
    -- another collision with BOTH normals, we're fine: the corner-corner
    -- collision allows us to move either direction, so we'll use whichever
    -- left normal is most oppressive.
    -- Of course, if there are a zillion collisions that all have only left
    -- normals, that's also fine, and we'll slide along the most oppressive of
    -- those, too.
    -- FIXME this is not the case for MultiShape of course, which needs fixing
    -- so that each of its sub-parts is a separate collision...  unless the
    -- collision table gets a flag indicating it was a corner collision or not?

    for _, collision in pairs(hits) do
        if collision.touchtype >= 0 and not collision.passable then
            -- TODO comment stuff in shapes.lua
            -- TODO explain why i used <= below (oh no i don't remember, but i think it was related to how this is done against the last slide only)
            -- FIXME i'm now using normals compared against our /last slide/ on our /velocity/ and it's unclear what ramifications that could have (especially since it already had enough ramifications to need the <=) -- think about this i guess lol

            if collision.left_normal then
                if collision.left_normal_dot <= minleftdot then
                    minleftdot = collision.left_normal_dot
                    minleftnorm = collision.left_normal
                end
                -- If we have a left normal but NOT a right normal, then we're
                -- blocked on the left side
                if not collision.right_normal then
                    blocked_left = true
                end
            end
            if collision.right_normal then
                if collision.right_normal_dot <= minrightdot then
                    minrightdot = collision.right_normal_dot
                    minrightnorm = collision.right_normal
                end
                if not collision.left_normal then
                    blocked_right = true
                end
            end
        end
    end

    -- If we're blocked on both sides, we can't possibly move at all
    if blocked_left and blocked_right then
        -- ...UNLESS we're blocked by walls parallel to us (i.e. dot of 0), in
        -- which case we can perfectly slide between them!
        if minleftdot == 0 and minrightdot == 0 then
            return direction, true
        end
        return Vector(), false
    end

    -- Otherwise, we can probably slide
    local axis
    if minleftnorm and minrightnorm then
        -- We hit a corner somewhere!  If we also hit a wall, then we have to
        -- slide in that direction.  Otherwise, we pick the normal with the
        -- BIGGEST dot, which is furthest away from the direction and thus the
        -- least disruptive.  In the case of a tie, this was a perfect corner
        -- collision, so we give up and stop.
        if blocked_left then
            axis = minleftnorm
        elseif blocked_right then
            axis = minrightnorm
        elseif minrightdot > minleftdot then
            axis = minrightnorm
        elseif minleftdot > minrightdot then
            axis = minleftnorm
        else
            return Vector(), false
        end
    else
        axis = minleftnorm or minrightnorm
    end

    if axis then
        return direction - direction:projectOn(axis), true
    else
        return direction, true
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
        successful, hits = self.map.collider:slide(self.shape, movement, pass_callback)
        self.shape:move(successful:unpack())
        self.pos = self.pos + successful
        total_movement = total_movement + successful

        if xxx_no_slide then
            break
        end
        local remaining = movement - successful
        -- FIXME these values are completely arbitrary and i cannot justify them
        if math.abs(remaining.x) < 1/16 and math.abs(remaining.y) < 1/16 then
            break
        end

        -- Find the allowed slide direction that's closest to the direction of movement.
        local slid
        movement, slid = slide_along_normals(hits, remaining)
        if not slid then
            break
        end

        if math.abs(movement.x) < 1/16 and math.abs(movement.y) < 1/16 then
            break
        end

        -- Automatically break if we don't move for three iterations -- not
        -- moving once is okay because we might slide, but three indicates a
        -- bad loop somewhere
        if _is_vector_almost_zero(successful) then
            stuck_counter = stuck_counter + 1
            if stuck_counter >= 3 then
                if game.debug then
                    -- FIXME interesting!  i get this when jumping against the
                    -- crate in a corner in tech-1; i think because clocks
                    -- can't handle single angles correctly, so this is the
                    -- same problem as walking down a hallway exactly your own
                    -- height
                    print("!!!  BREAKING OUT OF LOOP BECAUSE WE'RE STUCK, OOPS", self, movement, slide, remaining)
                end
                break
            end
        end
    end

    -- Move our cargo along with us, independently of their own movement
    -- FIXME this means our momentum isn't part of theirs!!  i think we could
    -- compute effective momentum by comparing position to the last frame, or
    -- by collecting all nudges...?  important for some stuff like glass lexy
    if self.can_carry and self.cargo and not _is_vector_almost_zero(total_movement) then
        for actor in pairs(self.cargo) do
            actor:nudge(total_movement, pushers)
        end
    end

    pushers[self] = nil
    return total_movement, hits
end

-- Updates the various "ground we're on" properties to match the values found
-- in the collision callback.
-- TODO maybe this should just track a ground_actor?  though that would be
-- strictly worse than the current behavior, which separately tracks friction
-- and terrain when straddling two objects
function MobileActor:update_ground()
    self.ground_normal = self.new_ground_normal
    self.ground_friction = self.new_ground_friction
    self.on_ground = not not self.ground_normal
    self.on_terrain = self.new_terrain
end

function MobileActor:update(dt)
    -- Passive adjustments
    if math.abs(self.velocity.x) < self.min_speed then
        self.velocity.x = 0
    end

    -- Friction -- the general tendency for everything to decelerate.
    -- It always pushes against the direction of motion, but never so much that
    -- it would reverse the motion.  Note that taking the dot product with the
    -- horizontal produces the normal force.
    -- Include the dt factor from the beginning, to make capping easier.
    -- Also, doing this before anything else ensures that it only considers
    -- deliberate movement and momentum, not gravity.
    -- TODO i don't like that this can make it impossible to move if friction
    -- is too high?  can friction be expressed in a way that makes that more
    -- difficult?
    local vellen = self.velocity:len()
    if vellen > 1e-8 then
        local decel_vector
        if not self:has_gravity() then
            decel_vector = self.velocity * (-self.friction_decel * dt / vellen)
            decel_vector:trimInplace(vellen)
        elseif self.ground_normal then
            decel_vector = self.ground_normal:perpendicular() * (self.friction_decel * dt)
            if decel_vector * self.velocity > 0 then
                decel_vector = -decel_vector
            end
            decel_vector = decel_vector:projectOn(self.velocity)
            decel_vector:trimInplace(vellen)
        else
            local vel1 = self.velocity / vellen
            decel_vector = -self.friction_decel * dt * vel1
            -- FIXME need some real air resistance; as written, this also reverses gravity, oops
            decel_vector = Vector.zero
        end
        self.velocity = self.velocity + decel_vector * self.ground_friction
    end

    -- Stash the velocity from before we add ambient acceleration.  This makes
    -- the integration more accurate by excluding abrupt changes (e.g.,
    -- jumping) from smoothing
    local last_velocity = self.velocity

    local fluidres = self:get_fluid_resistance()

    -- TODO factor the ground_friction constant into this, and also into slope
    -- resistance
    -- Gravity
    if self:has_gravity() then
        self.velocity = self.velocity + self:get_gravity() * (self:get_gravity_multiplier() * dt)
    end
    self.velocity.y = math.min(self.velocity.y, terminal_velocity / fluidres)

    ----------------------------------------------------------------------------
    -- Super call
    MobileActor.__super.update(self, dt)

    -- This looks a bit funny, but it makes simulation of constant gravity
    -- /exactly/ correct (modulo terminal velocity and whatnot), AND it avoids
    -- problems like jump height being eroded too much by the first tic of
    -- gravity at low framerates.  Not quite sure what it's called, but it's
    -- similar to Verlet integration and the midpoint method.
    local ds = (self.velocity + last_velocity) * (dt * 0.5)

    if ds == Vector.zero and self.may_skip_nudge then
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
    local goalpos = self.pos + ds / fluidres
    --[[
    if self.velocity.x ~= 0 then
        goalpos.x = math.floor(goalpos.x * 8 + 0.5) / 8
    end
    if self.velocity.y ~= 0 then
        goalpos.y = math.floor(goalpos.y * 8 + 0.5) / 8
    end
    ]]
    local movement = goalpos - self.pos

    self.new_ground_normal = nil
    self.new_ground_friction = 1
    self.new_terrain = nil

    -- Collision time!
    local movement, hits = self:nudge(movement)

    self:update_ground()

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
        self.velocity = slide_along_normals(hits, self.velocity)
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
    xaccel = 1536,
    deceleration = 0.5,
    max_speed = 192,
    climb_speed = 128,
    -- Pick a jump velocity that gets us up 2 tiles, plus a margin of error
    jumpvel = get_jump_velocity(TILE_SIZE * 2.25),
    jumpcap = 0.25,
    -- Multiplier for xaccel while airborne.  MUST be greater than the ratio of
    -- friction to xaccel, or the player won't be able to move while floating!
    aircontrol = 0.5,
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
        if collision.touchtype < 0 or any_normal_faces(collision, Vector(0, -1)) then
            self.ptrs.climbable_up = actor
        end
        if collision.touchtype < 0 or any_normal_faces(collision, Vector(0, 1)) then
            self.ptrs.climbable_down = actor
        end
    end

    -- Ignore collision with one-way platforms when climbing ladders, since
    -- they tend to cross (or themselves be) one-way platforms
    if collision.shape._xxx_is_one_way_platform and self.decision_climb then
        return true
    end

    return SentientActor.__super.on_collide_with(self, actor, collision)
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
            if self.too_steep then
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
    elseif not self.too_steep then
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

    -- Apply physics
    local was_on_ground = self.on_ground
    local movement, hits = SentientActor.__super.update(self, dt)

    -- Ground sticking
    -- FIXME this is still clearly visible (and annoying), AND it messes with
    -- attempts to nudge the player upwards artificially!
    -- If we walk up off the top of a slope, our momentum will carry us into
    -- the air, which looks very silly.  A conscious actor would step off the
    -- ramp.  So if we're only a very short distance above the ground, we were
    -- on the ground before moving, and we're not trying to jump, then stick us
    -- to the floor.
    -- Note that we commit to the short drop even if we don't actually hit the
    -- ground!  Since a nudge can cause both pushes and callbacks, there's no
    -- easy way to do a hypothetical slide without just doing it twice.  This
    -- should be fine, though, since it ought to only happen for a single
    -- frame, and is only a short distance.
    -- TODO this doesn't do velocity sliding afterwards, though that's not such
    -- a big deal since it'll happen the next frame
    -- TODO i suspect this could be avoided with the same (not yet written)
    -- logic that would keep critters from walking off of ledges?  or if
    -- the loop were taken out of collider.slide and put in here, so i could
    -- just explicitly slide in a custom direction
    if self:has_gravity() and
        was_on_ground and not self.on_ground and
        self.decision_jump_mode == 0 and self.decision_climb == nil and
        self.gravity_multiplier > 0 and self.gravity_multiplier_down > 0
    then
        -- If we run uphill along our steepest uphill slope and it immediately
        -- becomes our steepest downhill slope, we'll need to drop the
        -- x-coordinate of the normal, twice
        -- FIXME take max_speed into account here too so you can still be
        -- launched -- though i think that will look mighty funny since the
        -- drop will still happen
        -- FIXME this is actually completely ridiculous; no cap means it can
        -- drop you a huge amount
        -- FIXME also it interferes with the spring, argghh
        -- FIXME consider cloning our shape, moving it, testing for collision, and doing the drop only if you find something?
        local drop = Vector(0, math.abs(movement.x) * math.abs(self.max_slope.x) * 2)
        local drop_movement
        drop_movement, hits = self:nudge(drop, nil, true)
        movement = movement + drop_movement
        self:update_ground()
    end

    -- Handle our own passive physics
    if self:has_gravity() and self.on_ground then
        self.jump_count = 0
        self.in_mid_jump = false

        self.too_steep = (
            self.ground_normal * gravity - self.max_slope * gravity > 1e-8)

        -- Slope resistance -- an actor's ability to stay in place on an incline
        -- It always pushes upwards along the slope.  It has no cap, since it
        -- should always exactly oppose gravity, as long as the slope is shallow
        -- enough.
        -- Skip it entirely if we're not even moving in the general direction
        -- of gravity, though, so it doesn't interfere with jumping.
        if not self.too_steep then
            local slope = self.ground_normal:perpendicular()
            local gravity = self:get_gravity()
            if slope * gravity > 0 then
                slope = -slope
            end
            local slope_resistance = -(gravity * slope)
            self.velocity = self.velocity + slope_resistance * dt * slope
        end
    else
        self.too_steep = nil
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
        if self.jump_count == 0 and not self.on_ground then
            self.jump_count = 1
        end
        if self.jump_count < self.max_jumps or (self.decision_climb and not self.xxx_useless_climb) then
            -- TODO maybe jump away from the ground, not always up?  then could
            -- allow jumping off of steep slopes
            local jumped
            if self.too_steep then
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
function SentientActor:use()
end

-- Figure out a new pose and switch to it.  Default behavior is based on player
-- logic; feel free to override.
function SentientActor:update_pose()
    self.sprite:set_facing(self.facing)
    local pose = self:determine_pose()
    if pose then
        self.sprite:set_pose(pose)
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
    elseif self.on_ground or not self:has_gravity() then
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
    slide_along_normals = slide_along_normals,
}
