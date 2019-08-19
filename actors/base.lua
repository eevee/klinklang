local Vector = require 'klinklang.vendor.hump.vector'

local Object = require 'klinklang.object'
local components = require 'klinklang.actors.components'
local components_cargo = require 'klinklang.components.cargo'
local components_physics = require 'klinklang.components.physics'
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
            self.exist_component = components_physics.Exist(self.shape)
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
    self.move_component = components_physics.Move()
    if self.can_push or self.can_carry then
        self.tote_component = components_cargo.Tote()
    end
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

function MobileActor:update(dt)
    MobileActor.__super.update(self, dt)

    -- XXX first part of Move:update

    -- Gravity
    if self.gravity_component then
        self.gravity_component:update(self, dt)
    end

    -- XXX second part of Move:update

    self.move_component:update(self, dt)

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

    if self.think_component then
        self.think_component:update(self, dt)
    end

    self.walk_component:update(self, dt)

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
    self.jump_component:update(self, dt)

    -- Climbing
    self.climb_component:update(self, dt)

    -- Apply physics
    local movement, hits = SentientActor.__super.update(self, dt)

    -- Update the pose
    self:update_pose()

    -- Use whatever's now in front of us
    -- TODO shouldn't this be earlier?
    self.interactor_component:update(self, dt)

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
    if self.health_component and self.health_component.is_dead then
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
