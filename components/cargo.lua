local Vector = require 'klinklang.vendor.hump.vector'

local Component = require 'klinklang.components.base'
local Collision = require 'klinklang.whammo.collision'


local CARGO_CARRYING = 'carrying'
local CARGO_PUSHING = 'pushing'
local CARGO_COULD_PUSH = 'pushable'
local CARGO_BLOCKED = 'blocked'

-- Can push and/or carry other objects.  Carrying is used by e.g. moving
-- platforms; pushing is used by, primarily, the player.  Either way, the
-- general idea is that some other attached object is subject to any of our own
-- movement.
-- TODO how do we indicate objects that /can be/ pushed or carried?  another component, or just flags on Move?
local Tote = Component:extend{
    slot = 'tote',

    push_momentum_multiplier = 1,
    cargo = nil,
}

function Tote:init()
    Tote.__super.init()

    -- FIXME explain how this works, somewhere, as an overview
    -- XXX this used to be in on_enter, which seems like a better idea tbh
    self.cargo = setmetatable({}, { __mode = 'k' })
end

function Tote:update(actor, dt)
    local total_momentum = actor.velocity * actor.mass
    local total_mass = actor.mass
    local any_new = false
    for cargum, manifest in pairs(self.cargo) do
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
            local cargo_friction_force = cargum:_get_total_friction(-manifest.normal)
            local cargo_mass = cargum:_get_total_mass(manifest.velocity)
            local friction_delta = cargo_friction_force / cargo_mass * dt
            local cargo_dot = (manifest.velocity + friction_delta) * manifest.normal
            local system_dot = actor.velocity * manifest.normal
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
            self.cargo[cargum] = nil

            if manifest.state == CARGO_PUSHING then
                -- If we were pushing, impart it with our velocity (which
                -- doesn't need any mass scaling, because our velocity was the
                -- velocity of the whole system).
                cargum.velocity = cargum.velocity + manifest.velocity:projectOn(manifest.normal) * self.push_momentum_multiplier

                -- If the object was transitively pushing something else,
                -- transfer our velocity memory too.  This isn't strictly
                -- necessary, but it avoids waiting an extra frame for the
                -- object to realize it's doing the pushing before deciding
                -- whether to detach itself as well.
                if cargum.cargo then
                    for actor2, manifest2 in pairs(cargum.cargo) do
                        if manifest2.state == CARGO_PUSHING and not manifest2.velocity then
                            manifest2.velocity = manifest.velocity
                        end
                    end
                end
            end
            -- Just in case we were carrying them, undo their cargo_of
            if cargum.ptrs.cargo_of == actor then
                cargum.ptrs.cargo_of = nil
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
                local cargo_mass = cargum:_get_total_mass(attempted_velocity)
                total_mass = total_mass + cargo_mass
                if manifest.expiring == nil then
                    -- This is a new push
                    any_new = true
                    -- Absorb the momentum of the pushee
                    total_momentum = total_momentum + get_total_momentum(cargum, manifest.normal)
                    -- The part of our own velocity parallel to the push gets
                    -- capped, but any perpendicular movement shouldn't (since
                    -- it's not part of this push anyway).  Fake that by
                    -- weighting the perpendicular part as though it belonged
                    -- to this cargo.
                    local parallel = actor.velocity:projectOn(manifest.normal)
                    local perpendicular = actor.velocity - parallel
                    total_momentum = total_momentum + perpendicular * cargo_mass
                else
                    -- This is an existing push; ignore its velocity and tack on our own
                    total_momentum = total_momentum + actor.velocity * cargo_mass
                end
            end
        end
    end
    if any_new and total_mass ~= 0 then
        actor.velocity = total_momentum / total_mass
    end
end

function Tote:late_update(actor, dt)
    -- XXX i hate that i have to iterate three times, but i need to stick the POST-conservation velocity in here
    -- Finally, mark all cargo as potentially expiring (if we haven't seen it
    -- again by next frame), and remember our push velocity so we know whether
    -- we slowed enough to detach them next frame
    -- XXX i wonder if i actually need manifest.velocity?  it's only used for that detachment, but...  i already know my own pre-friction (and post-friction) velocity...  how and why do friction and conservation fit in here?
    for _, manifest in pairs(self.cargo) do
        manifest.expiring = true
        if manifest.state == CARGO_PUSHING then
            manifest.velocity = self.velocity
        else
            manifest.velocity = nil
        end
    end
end

-- Return the mass of ourselves, plus everything we're pushing or carrying
function Tote:_get_total_mass(actor, direction, _seen)
    if not _seen then
        _seen = {}
    elseif _seen[self] then
        return 0
    end
    _seen[self] = true

    local total_mass = actor.mass
    for cargum, manifest in pairs(self.cargo) do
        if manifest.state == CARGO_CARRYING or manifest.normal * direction < 0 then
            total_mass = total_mass + cargum.tote_component:_get_total_mass(cargum, direction, _seen)
        end
    end
    return total_mass
end



return {
    Tote = Tote,
}
