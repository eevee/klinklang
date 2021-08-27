local Vector = require 'klinklang.vendor.hump.vector'

local Component = require 'klinklang.components.base'
local Object = require 'klinklang.object'
local Collision = require 'klinklang.whammo.collision'


local function _is_vector_almost_zero(v)
    return math.abs(v.x) < 1e-8 and math.abs(v.y) < 1e-8
end

local Manifest = Object:extend{
    normal = nil,
    left_normal = nil,
    right_normal = nil,
    state = nil,  -- 'carrying' or 'pushable'
    sticky = true,
    new = nil,
    expiring = nil,
}

function Manifest:init()
    self.new = true
end

function Manifest:is_moved_in_direction(direction)
    if self.state == 'carrying' then
        return true
    end
    if self.left_normal and self.right_normal and self.left_normal ~= self.right_normal then
        -- FIXME
        return false
    else
        return (self.left_normal or self.right_normal) * direction < 0
    end
end


-- Can push and/or carry other objects.  Carrying is used by e.g. moving
-- platforms; pushing is used by, primarily, the player.  Either way, the
-- general idea is that some other attached object is subject to any of our own
-- movement.
-- TODO how do we indicate objects that /can be/ pushed or carried?  another component, or just flags on Move?
-- TODO in general i would love for this to be more robust?  atm there are a lot of adhoc decisions about ordering and whatnot that just kinda, happened to work.  tests!!
local Tote = Component:extend{
    slot = 'tote',
    -- XXX i think this needs to happen right after movement, but primarily so that detach logic has the right velocity to work with?  but if i move more cargo code here i can see it happening more
    priority = 101,

    -- TODO figure these out
    --push_resistance_multiplier = 1,
    push_momentum_multiplier = 1,
    -- Map of everything this actor is currently pushing/carrying.  Keys are
    -- the other actors; values are a manifest.  TODO document manifest
    cargo = nil,
}

function Tote:init(actor, args)
    Tote.__super.init(self, actor, args)

    -- FIXME explain how this works, somewhere, as an overview
    -- XXX this used to be in on_enter, which seems like a better idea tbh
    self.cargo = setmetatable({}, { __mode = 'k' })

    -- TODO merge with cargo
    self.pushable_contacts = {}
end

function Tote:on_collide_with(collision, passable, pushers)
    local obstacle = collision.their_owner
    if not obstacle then
        return
    end

    -- If we already pushed this thing once, then don't try to push it again in the same nudge, but
    -- mark the collision as no-slide to preserve velocity
    -- XXX shouldn't this be named pushees, then?
    if pushers[obstacle] then
        collision.no_slide = true
        return
    end

    if collision.overlapped then
        return
    end

    -- Check for something we can carry
    -- FIXME really need to distinguish these cases.  i guess by gravity.  of the obstacle!
    local obstacle_gravity_direction = Vector(0, 1)
    if self.actor.can_carry and obstacle.is_portable and
        -- It has to be in our way (slides are OK!)
        not passable and
        -- It has to be held onto us, either by the force of gravity OR by some manual effect
        (
            (self.cargo[obstacle] and self.cargo[obstacle] == 'carrying') or
            (obstacle_gravity_direction and collision:faces(obstacle_gravity_direction))
        )
    then
        -- This is pretty simple: move it along the rest of our movement, which is the fraction left
        -- after we first touched, then retry the move.  We don't care about normals or anything!
        local nudge = collision.attempted * (1 - math.max(0, collision.contact_start))
        obstacle:get('move'):nudge(nudge, pushers)
        pushers[obstacle] = true
        self:attach(obstacle, 'carrying', collision.left_normal or collision.right_normal)
        return 'retry'
    end

    -- Otherwise, check for something we can push
    if
        -- It has to be pushable, of course
        self.actor.can_push and obstacle.is_pushable and
        -- It has to be in our way (including slides, to track pushable)
        passable ~= true and
        -- We must be on the ground to push something
        -- TODO here's a fun one: what happens with two objects with gravity in different directions?
        (not self:get('fall') or self:get('fall').grounded) and
        -- We can't push the ground
        self.actor.ptrs.ground ~= obstacle
    then
        -- Try to push them along the rest of our movement, which is everything left after we first
        -- touched
        local nudge = collision.attempted * (1 - math.max(0, collision.contact_start))
        -- You can only push along the ground, so remove any component along the ground normal
        -- FIXME if i'm already ON the ground to be pushing anyway, then...?
        --nudge = nudge - nudge:projectOn(self:get('fall').ground_normal)
        -- Only push in the direction the collision occurred!  If several
        -- directions, well, just average them
        local axis
        if collision.left_normal and collision.right_normal then
            axis = (collision.left_normal + collision.right_normal) / 2
        else
            axis = collision.left_normal or collision.right_normal
        end
        if axis then
            -- A more complicated check: if we're trying to push something that's moving faster than
            -- we are *against* us, that's not a real push, so give up here.  When it pushes us,
            -- it'll absorb our velocity (maybe?).
            -- TODO this doesn't take into account transitive pushes or moving
            -- platforms etc.  it should use "real" velocity for both of us
            -- TODO absorbing velocity doesn't work super well for,
            -- hypothetically, objects that have a constant velocity, but those
            -- might need special handling anyway since they are rude
            local our_dot = self:get('move').velocity * axis
            local their_dot = obstacle:get('move').velocity * axis
            -- (Remember, these dots are against a vector pointing *towards*
            -- us, so we've moving faster if ours is more negative!)
            if their_dot < our_dot then
                return passable
            end

            -- FIXME rethink this.  if i am pushing a thing uphill, that's the direction i'm pushing it in, regardless of the direction of the normals, right?  but this is also what prevents us from kicking a box as we run on top of it.
            nudge = nudge:projectOn(axis)

            local their_fall = obstacle:get('fall')
            if their_fall and their_fall.ground_normal then
                nudge = nudge - nudge:projectOn(their_fall.ground_normal)
            end
        else
            nudge = Vector.zero
        end

        local total_mass = self:get_total_pushed_mass(obstacle, axis)
        if self.actor.is_player then
            -- Reduce our movement relative to our max push power
            -- FIXME definitely un-hardcode this
            -- FIXME oops, this only makes sense if the player is the original source of the push
            nudge = nudge * math.max(0, 1 - total_mass / 8)
        end
        print('total trying to push', total_mass)
        print('PUSHING:', self.actor, 'pushing', obstacle, 'axis', axis, 'distance', nudge, 'out of', collision.attempted, collision.contact_start)

        -- XXX this happens even for objects on top of us, which we're carrying!  it appears i just
        -- removed the sideways-y "can i push this" check entirely and relied on it to happen ad hoc
        local manifest = self:attach(obstacle, 'pushable', axis)

        if collision.contact_type == 0 or _is_vector_almost_zero(nudge) then
            -- We're not actually trying to push this thing, so do nothing
            print('. skipping because not pushing in that direction')
        else
            pushers[obstacle] = true
            -- Actually push the object!
            print(". nudging pushable", obstacle, collision.attempted, nudge, obstacle.is_pushable, obstacle.is_portable)
            local actual, hits = obstacle:get('move'):nudge(
                nudge, pushers, not obstacle.is_pushable_uphill)
            print(". and it moved", actual, direction)
            if not _is_vector_almost_zero(actual) then
                passable = 'retry'
                manifest.just_pushed = true
            end
            -- Mark as pushing even if it's blocked.  For sentient pushers, this lets them keep
            -- their push animation and avoids flickering between pushing and not; non-sentient
            -- pushers will lose their velocity, not regain it, and be marked as pushable next time.
            --manifest.state = CARGO_PUSHING

            -- Marking the collision as no-slide will preserve our velocity.  It also fixes the case
            -- where we're pushing e.g. a boulder uphill while we're still on flat ground, in which
            -- case the boulder doesn't actually move as far as we asked it to, but only because of
            -- sliding and not because it was actually blocked; in that case we want to treat the
            -- movement as a success.
            -- TODO nudge has a bit of a hack specifically to avoid infinite
            -- looping because of this, but i'm not sure what cleaner way there
            -- is to fix it
            collision.no_slide = true
        end
    end

    return passable
end

function Tote:after_collisions(movement, collisions, pushers)
    -- Move our cargo along with us, independently of their own movement
    -- FIXME this means our momentum isn't part of theirs!!  i think we could compute effective
    -- momentum by comparing position to the last frame, or by collecting all nudges...?  important
    -- for some stuff like glass lexy
    -- FIXME this crashes if the cargo has disappeared  :I  try putting a cardboard box on a spring and taking it
    if not _is_vector_almost_zero(movement) then
        for cargum, manifest in pairs(self.cargo) do
            if manifest.state == 'carrying' and self.actor.can_carry and not pushers[cargum] then
                print('. nudging to move cargo at end of parent nudge')
                cargum:get('move'):nudge(movement, pushers)
            end
        end
    end

    -- Delete any pushables that weren't just added during this past nudge
    for cargum, manifest in pairs(self.cargo) do
        manifest.just_pushed = false

        if manifest.new then
            manifest.new = nil
        elseif manifest.state == 'pushable' then
            -- XXX do i expire cargo?  i can't reasonably do that here, it's mostly added from Fall
            self:detach(cargum)
        end
    end
end

function Tote:attach(cargum, state, normal)
    local manifest = self.cargo[cargum]
    if not manifest then
        manifest = Manifest()
        self.cargo[cargum] = manifest
    end
    manifest.new = true
    -- Carrying can't be demoted to pushable
    if manifest.state ~= 'carrying' then
        manifest.state = state
    end
    manifest.normal = normal

    if state == 'carrying' then
        cargum.ptrs.cargo_of = self.actor
    end

    return manifest
end

function Tote:detach(cargum)
    if cargum.ptrs.cargo_of == self.actor then
        cargum.ptrs.cargo_of = nil
    end
    self.cargo[cargum] = nil
end

-- Return the total mass of an object we're trying to push, plus everything it would push transitively
function Tote:get_total_pushed_mass(obstacle, axis, _seen)
    _seen = _seen or {}
    if _seen[obstacle] then
        return 0
    end

    local total_pushed_mass = 0
    local tote = obstacle:get('tote')
    if tote then
        total_pushed_mass = tote:get_total_carried_mass(_seen)
        for cargum, manifest in pairs(tote.cargo) do
            if not _seen[contact] and manifest.state == 'pushable' and manifest.normal * axis > 0 then
                total_pushed_mass = total_pushed_mass + tote:get_total_pushed_mass(cargum, axis, _seen)
            end
        end
    else
        _seen[obstacle] = true
        total_pushed_mass = obstacle.mass
    end

    return total_pushed_mass
end

-- Return the total mass of ourselves, plus everything we're carrying transitively
function Tote:get_total_carried_mass(_seen)
    _seen = _seen or {}
    if _seen[self.actor] then
        return 0
    end
    _seen[self.actor] = true

    local total_mass = self.actor.mass
    for cargum, manifest in pairs(self.cargo) do
        if manifest.state == 'carrying' then
            local tote = cargum:get('tote')
            if tote then
                total_mass = total_mass + tote:get_total_carried_mass(_seen)
            else
                total_mass = total_mass + cargum.mass
                _seen[cargum] = true
            end
        end
    end
    return total_mass
end


-- Return the mass of ourselves, plus everything we're pushing or carrying
function Tote:_get_total_mass(direction, _seen)
    if not _seen then
        _seen = {}
    elseif _seen[self] then
        return 0
    end
    _seen[self] = true

    local total_mass = self.actor.mass
    for cargum, manifest in pairs(self.cargo) do
        if manifest:is_moved_in_direction(direction) then
            local tote = cargum:get('tote')
            if tote then
                total_mass = total_mass + tote:_get_total_mass(direction, _seen)
            else
                total_mass = total_mass + cargum.mass
                _seen[cargum] = true
            end
        end
    end
    return total_mass
end



return {
    Manifest = Manifest,
    Tote = Tote,
}
