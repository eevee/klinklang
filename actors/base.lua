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

    COMPONENTS = {},
    components = nil,
    component_order = nil,

    -- Table of all known actor types, indexed by name
    name = nil,
    _ALL_ACTOR_TYPES = {},
}

function BareActor:init()
    self.components = {}
    self.component_order = {}
    for component_type, args in pairs(self.COMPONENTS) do
        local component = component_type(self, args)
        self.components[component_type.slot] = component
        table.insert(self.component_order, component)
    end
    -- TODO could skip this if we did it once in extend?
    table.sort(self.component_order, function(a, b)
        return a.priority < b.priority
    end)
end

local _COMPONENT_BACK_COMPAT_ARGS = {
    -- Mobile
    { 'min_speed',                  'move', 'min_speed' },
    { 'friction_decel',             'fall', 'friction_decel' },
    { 'gravity_multiplier',         'fall', 'multiplier' },
    { 'gravity_multiplier_down',    'fall', 'multiplier' },
    { 'is_blockable',               'move', 'is_juggernaut', function(value) return not value end },
    { 'may_skip_nudge',             'move', 'skip_zero_nudge' },
    -- TODO these don't exist yet, and i don't think any of the code that checks for them is actually in Tote
    --{ 'can_push',                   'tote', 'can_push' },
    --{ 'can_carry',                  'tote', 'can_carry' },
    -- TODO not even sure where these ought to go
    --{ 'is_pushable',                ??? },
    --{ 'is_portable',                ??? },
    -- TODO this should maybe be on something, but it isn't
    --mass

    -- Sentient
    { 'max_slope',                  'fall', 'max_slope' },
    { 'xaccel',                     'walk', 'base_acceleration' },
    { 'deceleration',               'walk', 'stop_multiplier' },
    { 'max_speed',                  'walk', 'speed_cap' },
    { 'aircontrol',                 'walk', 'air_multiplier' },
    { 'jumpvel',                    'jump', 'speed' },
    { 'jumpcap',                    'jump', 'abort_multiplier' },
    -- TODO max_slope_slowdown?  is this still used?
    { 'max_jumps',                  'jump', 'max_jumps' },
    { 'jump_sound',                 'jump', 'sound' },
    { 'climb_speed',                'climb', 'speed' },
}

function BareActor:extend(body)
    -- Backwards compatibility: convert class variables to component arguments
    local any_back_compat
    local subtype_components = body.COMPONENTS
    if subtype_components == nil then
        subtype_components = {}
    end
    for _, arg in ipairs(_COMPONENT_BACK_COMPAT_ARGS) do
        local value = body[arg[1]]
        if value ~= nil then
            any_back_compat = true
            print(("Actor '%s' is using deprecated class attribute '%s' which is now '%s.%s'"):format(
                body.name or self.name, arg[1], arg[2], arg[3]))
            -- XXX this won't work if they specify a component explicitly
            local component_args = subtype_components[arg[2]]
            if component_args == nil then
                component_args = {}
                subtype_components[arg[2]] = component_args
            end
            if arg[4] then
                value = arg[4](value)
            end
            component_args[arg[3]] = value
        end
    end
    if any_back_compat then
        body.COMPONENTS = subtype_components
    end

    -- Create the class
    local class = BareActor.__super.extend(self, body)
    if class.name ~= nil then
        self._ALL_ACTOR_TYPES[class.name] = class
    end

    -- Special behavior for COMPONENTS
    -- TODO instantiate components here?  would separate config from state?
    if self.COMPONENTS ~= class.COMPONENTS then
        local theirs_by_slot = {}
        for component_type in pairs(class.COMPONENTS) do
            -- TODO enforce only one of each slot
            if type(component_type) == 'string' then
                -- Subclasses may also give slot names to implicitly refer to a
                -- superclass's existing component
                theirs_by_slot[component_type] = component_type
            else
                theirs_by_slot[component_type.slot] = component_type
            end
        end

        for component_type, args in pairs(self.COMPONENTS) do
            local theirs = theirs_by_slot[component_type.slot]
            if theirs == nil then
                -- They don't specify this slot at all, so copy ours in
                class.COMPONENTS[component_type] = args
            elseif type(theirs) == 'string' or theirs:isa(component_type) then
                -- They use the same component type (or a subclass), or are
                -- implicitly referring to ours by slot name.  Merge in any of
                -- our arguments, but leave any of theirs alone.
                local their_args = class.COMPONENTS[theirs]
                if their_args == false then
                    -- A value of false means to remove this component
                    class.COMPONENTS[theirs] = nil
                else
                    for key, value in pairs(args) do
                        if their_args[key] == nil then
                            their_args[key] = value
                        end
                    end

                    if type(theirs) == 'string' then
                        -- Fix slot references to use a type
                        class.COMPONENTS[theirs] = nil
                        class.COMPONENTS[component_type] = their_args
                    end
                end
            end
            -- Otherwise, they use a completely different component type, which
            -- should override ours
        end

        -- Finally, check for any attempts to reference a slot that doesn't
        -- exist in the superclass
        for component_type in pairs(class.COMPONENTS) do
            if type(component_type) == 'string' then
                error("Actor subtype references a slot that doesn't exist in the supertype: " .. component_type)
            end
        end
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


-- Component handling
function BareActor:get(slot)
    if not self.components then
        return nil
    end

    -- XXX i guess maybe this should be on Actor, and BareActor can have zero components
    return self.components[slot]
end

function BareActor:each(method, ...)
    if not self.components then
        return
    end

    for _, component in ipairs(self.component_order) do
        component[method](component, ...)
    end
end


-- Main update and draw loops
function BareActor:update(dt)
    self:each('update', dt)
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
function BareActor:blocks(actor, collision)
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

-- Draw the collision shape, for the debug layer
function BareActor:draw_shape(mode)
    if self.shape then
        self.shape:draw(mode)
    end
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
    Actor.__super.init(self)

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
            -- XXX how do i get this in here when it comes from Tiled?
            -- XXX for that matter, how do i get arbitrary tiled arguments in here?  i guess that oughta be a, thing
            --self.exist_component = components_physics.Exist(self.shape)
        end
    end
end

-- Called once per update frame; any state changes should go here
function Actor:update(dt)
    self.timer = self.timer + dt
    if self.sprite then
        self.sprite:update(dt)
    end
    Actor.__super.update(self, dt)
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

local MobileActor = Actor:extend{
    _type_name = 'MobileActor',

    ground_friction = 1,  -- FIXME this is state, dumbass, not a twiddle
    -- Pushing and platform behavior
    is_pushable = false,
    can_push = false,
    push_resistance_multiplier = 1,
    push_momentum_multiplier = 1,
    is_portable = false,  -- Can this be carried?
    can_carry = false,  -- Can this carry?
    mass = 1,  -- Pushing a heavier object will slow you down

    COMPONENTS = {
        [components_physics.Fall] = {
            friction_decel = 256,
        },
        [components_physics.Move] = {},
        --[components_cargo.Tote]
    },
}

function MobileActor:blocks(actor, collision)
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

    -- State
    -- TODO most of this shouldn't be here
    -- Flag indicating that we were deliberately pushed upwards since the last
    -- time we were on the ground; disables ground adherence and the jump
    -- velocity capping behavior
    was_launched = false,
    is_climbing = false,
    is_dead = false,
    is_locked = false,

    COMPONENTS = {
        [components.Walk] = {},
        [components.Jump] = {
            speed = get_jump_velocity(TILE_SIZE * 2.25),
        },
        [components.Climb] = {},
        [components.Interact] = {},
        [components.SentientFall] = {},
    },
}

function SentientActor:get_gravity_multiplier()
    if self.is_climbing and not self.xxx_useless_climb then
        return 0
    end
    return SentientActor.__super.get_gravity_multiplier(self)
end

function SentientActor:push(dv)
    SentientActor.__super.push(self, dv)

    if dv * self:get('fall'):get_gravity() < 0 then
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

    --[[
    if self.think_component then
        self.think_component:update(self, dt)
    end

    self.walk_component:update(self, dt)
    ]]

    -- Update facing -- based on the input, not the velocity!
    -- FIXME should this have memory the same way conflicting direction keys do?
    -- FIXME where does this live?  on Walk?  on Think?
    local walk = self:get('walk')
    if math.abs(walk.decision.x) > math.abs(walk.decision.y) then
        if walk.decision.x < 0 then
            self.facing = 'left'
        elseif walk.decision.x > 0 then
            self.facing = 'right'
        end
    else
        if walk.decision.y < 0 then
            self.facing = 'up'
        elseif walk.decision.y > 0 then
            self.facing = 'down'
        end
    end

    -- Apply physics
    local movement, hits = SentientActor.__super.update(self, dt)

    -- Update the pose
    self:update_pose()

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
    local ail = self:get('ail')
    local climb = self:get('climb')
    local walk = self:get('walk')
    local fall = self:get('fall')
    local move = self:get('move')
    if ail and ail.is_dead then
        return 'die'
    elseif self.is_floating then
        return 'fall'
    elseif climb.is_climbing then
        if climb.decision < 0 then
            return 'climb'
        elseif climb.decision > 0 then
            return 'descend'
        else
            return 'hold'
        end
    elseif not fall or fall.grounded then
        if walk.decision ~= Vector.zero then
            return 'walk'
        end
    elseif move and move.velocity.y < 0 then
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
