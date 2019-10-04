local Vector = require 'klinklang.vendor.hump.vector'

local Component = require 'klinklang.components.base'
local Object = require 'klinklang.object'
local Collision = require 'klinklang.whammo.collision'


local CARGO_CARRYING = 'carrying'
local CARGO_PUSHING = 'pushing'
local CARGO_COULD_PUSH = 'pushable'
local CARGO_BLOCKED = 'blocked'

local function _is_vector_almost_zero(v)
    return math.abs(v.x) < 1e-8 and math.abs(v.y) < 1e-8
end

local Manifest = Object:extend{
    normal = nil,
    left_normal = nil,
    right_normal = nil,
    state = nil,
    sticky = true,
    new = nil,
    expiring = nil,
}

function Manifest:init()
    self.new = true
end

function Manifest:is_moved_in_direction(direction)
    if self.state == CARGO_CARRYING then
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
end

function Tote:x_on_collide_with(collision)
    local obstacle = collision.their_owner
    local fall = obstacle:get('fall')
    do return end
    -- FIXME urgh it seems like the toter should figure out everything attached
    -- to it while /it/ specifically is moving, but that's not the case with
    -- resting on platforms: those are determined by the cargo, in
    -- Fall:check_for_ground.  there are two big reasons for this:
    -- 1. an actor only ever considers ONE other actor to be its ground, and Fall is what chooses that; we'd have to do something invasive, maybe, and can't really be sure on collision until we know it's checked for its own ground
    -- 2. we don't get called when moving /away/ from an actor, because that's not a collision
    if fall and collision:faces(-fall:get_base_gravity()) then
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
                    manifest = Manifest()
                    tote.cargo[self.actor] = manifest
                end
                manifest.state = CARGO_CARRYING
                manifest.normal = carrier_normal

                self.actor.ptrs.cargo_of = carrier
            end
        end
    end
end

function Tote:after_collisions(movement, collisions)
    -- TODO ALRIGHT SO, what Tote really does is collect movement and share it
    -- movement can be "sticky", in which case it applies regardless of direction vs normal (a moving platform, but NOT a crate)
    do return end
    local pushable_contact_start = 1
    for _, collision in ipairs(collisions) do
        -- Check for pushing
        -- FIXME i'm starting to think this belongs in nudge(), not here, since we don't even know how far we'll successfully move yet
        local obstacle = collision.their_owner
        local their_fall = obstacle:get('fall')
        local passable = collision.passable
        -- Check for carrying
        local tote = self:get('tote')
        if obstacle and self.actor.can_carry then
            if self.cargo[obstacle] and self.cargo[obstacle].state == CARGO_CARRYING then
                -- If the other obstacle is already our cargo, ignore collisions with
                -- it for now, since we'll move it at the end of nudge()
                -- FIXME this is /technically/ wrong if the carrier is blockable, but so
                -- far all of mine are not.  one current side effect is that if you're
                -- on a crate on a platform moving up, and you hit a ceiling, then you
                -- get knocked off the crate rather than the crate being knocked
                -- through the platform.
                -- FIXME this should no longer be a problem, since cargo moves as a block, but i don't know what the implication is for platforms trying to carry a too-large thing
                --  XXX? return true
            elseif obstacle.is_portable and
                not passable and not collision.overlapped and
                collision.contact_type > 0 and
                -- TODO gravity
                collision:faces(Vector(0, 1)) and
                -- XXX? not pushers[obstacle]
                true
            then
                -- If we rise into a portable obstacle, pick it up -- push it the rest
                -- of the distance we're going to move.  On its next ground check,
                -- it should notice us as its carrier.
                -- FIXME this isn't quite right, since we might get blocked later
                -- and not actually move this whole distance!  but chances are they
                -- will be too so this isn't a huge deal
                -- FIXME and lastly, if something is straddling two platforms both moving up, there's a risk they'll squabble endlessly
                -- FIXME ok that is actually happening in practice but only on the way /down/...  sigh, christ
                local nudge = collision.attempted * (1 - math.max(0, collision.contact_start))
                if not _is_vector_almost_zero(nudge) then
                    print('. nudging portable new cargo from below')
                    print('... because the normals are', collision.left_normal, collision.right_normal)
                    -- FIXME this is causing us to move objects that wouldn't consider themselves to be resting on us, especially in the case of sideways corner collisions
                    --obstacle:get('move'):nudge(nudge, pushers)
                end
                if collision.contact_start > 0 and collision.contact_start < pushable_contact_start then
                    pushable_contact_start = collision.contact_start
                end
                -- FIXME DON'T DO THIS if it would conflict with their sense of ground
                local manifest = self.cargo[obstacle]
                if manifest then
                    print('unexpiring', obstacle)
                    manifest.expiring = false
                else
                    print('attaching', obstacle, 'to', self.actor, 'in collision')
                    manifest = Manifest()
                    self.cargo[obstacle] = manifest
                end
                -- FIXME what is correct here anyway, the direction closer to movement?  or, keep both?
                manifest.normal = collision.left_normal or collision.right_normal
                manifest.left_normal = collision.left_normal
                manifest.right_normal = collision.right_normal
                manifest.state = CARGO_CARRYING
                collision.passable = 'pushed'
                -- XXX? return true
            end
        end
        if obstacle and
            false and
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
            -- If we already pushed this object during this nudge, it must be
            -- blocked or on a slope or otherwise unable to keep moving, so let it
            -- block us this time
            -- XXX? already_hit[obstacle] ~= 'nudged' and
            -- Avoid a push loop, which could happen in pathological cases
            -- XXX? not pushers[obstacle]
            true
        then
            print('PUSHING:', self.actor, 'pushing', obstacle)
            -- Try to push them along the rest of our movement, which is everything
            -- left after we first touched
            if collision.contact_start > 0 and collision.contact_start < pushable_contact_start then
                pushable_contact_start = collision.contact_start
            end
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
            local manifest = self.cargo[obstacle]
            if manifest then
                print('unexpiring', obstacle)
                manifest.expiring = false
            else
                print('attaching', obstacle, 'to', self.actor, 'in collision')
                manifest = Manifest()
                self.cargo[obstacle] = manifest
            end
            manifest.normal = axis
            manifest.left_normal = collision.left_normal
            manifest.right_normal = collision.right_normal

            if collision.contact_type == 0 or _is_vector_almost_zero(nudge) then
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
                print(". nudging pushable", obstacle, collision.attempted, nudge, obstacle.is_pushable, obstacle.is_portable)
                -- XXX? local actual = obstacle:get('move'):nudge(nudge)
                -- XXX i think this should be done...  afterwards?  we should re-nudge the whole system
                -- If we successfully moved it, ask collision detection to
                -- re-evaluate this collision
                --[[
                if not _is_vector_almost_zero(actual) then
                    -- XXX? passable = 'retry'
                end
                ]]
                -- Mark as pushing even if it's blocked.  For sentient pushers,
                -- this lets them keep their push animation and avoids flickering
                -- between pushing and not; non-sentient pushers will lose their
                -- velocity, not regain it, and be marked as pushable next time.
                manifest.state = CARGO_PUSHING
                -- XXX? already_hit[obstacle] = 'nudged'
                collision.passable = 'pushed'
            end
        end
    end

    if pushable_contact_start < 1 then
        -- FIXME this is wrong for a transitive push...
        self:get('move'):nudge(collisions[1].attempted * (1 - pushable_contact_start))
    end
end

function Tote:update(dt)
    -- XXX when is this supposed to run, and why?
    local move = self:get('move')
    do return end
    -- FIXME uhh, really not clear how this oughta work.  move is only really used for push, which is a "non-sticky" behavior.  but i also want to use cargo for e.g. conveyor belts.  does it make sense to have push logic for something that doesn't move?
    -- FIXME should there be two kinds of toting, push and carry?  or, i guess, sticky and non-sticky?  hm
    -- FIXME this is all very confusing
    local total_momentum, attempted_velocity
    if move then
        total_momentum = move.velocity * self.actor.mass
        -- FIXME this used to be velocity /before/ gravity+friction but /after/ everything else, so it would have both sentient movement and leftover momentum, for detecting "tried to push something but it was too heavy"
        attempted_velocity = move.velocity
    end
    local total_mass = self.actor.mass or 0
    local any_new = false
    for cargum, manifest in pairs(self.cargo) do
        local detach = false
        if manifest.expiring then
            -- We didn't push or carry this actor this frame, so we must have
            -- come detached from it.
            print('v expired')
            detach = true
        elseif cargum.map ~= self.actor.map then
            -- The actor is no longer even in the map!
            -- FIXME this seems like a general problem, with ptrs too.  i rely
            -- on gc to take care of it normally, but this tripped me up in a
            -- test
            detach = true
        elseif move and manifest.state == CARGO_COULD_PUSH and attempted_velocity * manifest.normal < -1e-8 then
            -- If we didn't push something, but we *tried* and *could've*, then
            -- chances are we're a sentient actor trying to push something
            -- whose friction we just can't overcome.  Treating that as a push,
            -- even though we didn't actually move it, avoids state flicker
            manifest.state = CARGO_PUSHING
        elseif move and manifest.state == CARGO_PUSHING and manifest.velocity then
            -- If we slow down, the momentum of whatever we're pushing might
            -- keep it going.  Figure out whether this is the case by comparing
            -- our actual velocity (which is the velocity of the whole system)
            -- with the velocity of this cargo, remembering to account for the
            -- friction it *would've* experienced on its own this frame
            local cargo_friction_force = cargum:get('fall'):_get_total_friction(-manifest.normal)
            local tote = cargum:get('tote')
            local cargo_mass
            if tote then
                cargo_mass = tote:_get_total_mass(manifest.velocity)
            else
                cargo_mass = cargum.mass
            end
            local friction_delta = cargo_friction_force / cargo_mass * dt
            local cargo_dot = (manifest.velocity + friction_delta) * manifest.normal
            --print('projected cargo velocity:', manifest.velocity, '+', friction_delta, '=', manifest.velocity + friction_delta)
            local system_dot = move.velocity * manifest.normal
            --print('current system velocity:', move.velocity)
            if system_dot - cargo_dot > 1e-8 then
                -- We're moving more slowly than the rest of the system; we
                -- might be a sentient actor turning away, or just heavier or
                -- more frictional than whatever we're pushing.  Detach.
                --print('v too slow', system_dot, cargo_dot)
                --detach = true
            end
        end

        -- Detach any cargo that's no longer connected.
        -- NOTE: This is FRAMERATE DEPENDENT; detaching always takes one frame
        if detach then
            print('detaching', cargum, 'from', self.actor)
            self.cargo[cargum] = nil

            if manifest.state == CARGO_PUSHING then
                -- If we were pushing, impart it with our velocity (which
                -- doesn't need any mass scaling, because our velocity was the
                -- velocity of the whole system).
                print("granting velocity", manifest.velocity:projectOn(manifest.normal) * self.push_momentum_multiplier)
                cargum:get('move'):add_velocity(manifest.velocity:projectOn(manifest.normal) * self.push_momentum_multiplier)

                -- If the object was transitively pushing something else,
                -- transfer our velocity memory too.  This isn't strictly
                -- necessary, but it avoids waiting an extra frame for the
                -- object to realize it's doing the pushing before deciding
                -- whether to detach itself as well.
                local tote = cargum:get('tote')
                if tote then
                    for actor2, manifest2 in pairs(tote.cargo) do
                        if manifest2.state == CARGO_PUSHING and not manifest2.velocity then
                            manifest2.velocity = manifest.velocity
                        end
                    end
                end
            end
            -- Just in case we were carrying them, undo their cargo_of
            if cargum.ptrs.cargo_of == self.actor then
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

                local actor_move = actor:get('move')
                local momentum = actor_move.velocity * actor.mass
                -- FIXME this should be transitive, but that's complicated with loops, sigh
                -- FIXME should this only *collect* velocity in the push direction?
                -- FIXME what if they're e.g. on a slope and keep accumulating more momentum?
                -- FIXME how is this affected by something being pushed from both directions?
                -- XXX does this velocity mutation belong here in the first place?  feels like it'll be ignored?
                actor_move.velocity = actor_move.velocity - actor_move.velocity:projectOn(direction)
                local tote = actor:get('tote')
                if tote then
                    for other_actor, manifest in pairs(actor:get('tote').cargo) do
                        if manifest.state == CARGO_PUSHING then
                            -- FIXME should this be direction, or other_manifest.normal?
                            -- FIXME should this also apply to pushable?
                            momentum = momentum + get_total_momentum(other_actor, direction)
                        end
                    end
                end
                return momentum
            end
            if false and move and (manifest.state == CARGO_PUSHING --[[or manifest.state == CARGO_CARRYING]]) then
                local tote = cargum:get('tote')
                local cargo_mass
                if tote then
                    cargo_mass = tote:_get_total_mass(attempted_velocity)
                else
                    cargo_mass = cargum.mass
                end
                total_mass = total_mass + cargo_mass
                if manifest.new then
                    -- This is a new push
                    any_new = true
                    manifest.new = nil
                    -- Absorb the momentum of the pushee
                    total_momentum = total_momentum + get_total_momentum(cargum, manifest.normal)
                    -- The part of our own velocity parallel to the push gets
                    -- capped, but any perpendicular movement shouldn't (since
                    -- it's not part of this push anyway).  Fake that by
                    -- weighting the perpendicular part as though it belonged
                    -- to this cargo.
                    local parallel = move.velocity:projectOn(manifest.normal)
                    local perpendicular = move.velocity - parallel
                    total_momentum = total_momentum + perpendicular * cargo_mass
                else
                    -- This is an existing push; ignore its velocity and tack on our own
                    total_momentum = total_momentum + move.velocity * cargo_mass
                end
            end
        end
    end
    if move and any_new and total_mass ~= 0 then
        local v0 = move.pending_velocity
        move.pending_velocity = total_momentum / total_mass
        -- This is a LITTLE unkosher, but otherwise Walk still thinks we're moving too fast
        -- XXX yet another case of doing very subtle things to the 'pending' values...
        move.velocity = move.pending_velocity
        print('adjusting velocity for', self.actor, 'from', v0, 'to', move.pending_velocity)
    end

    -- XXX slide_along_normals used to go here.  what are the implications of having it happen before any of this

    -- XXX i hate that i have to iterate three times, but i need to stick the POST-conservation velocity in here
    -- Finally, mark all cargo as potentially expiring (if we haven't seen it
    -- again by next frame), and remember our push velocity so we know whether
    -- we slowed enough to detach them next frame
    -- XXX i wonder if i actually need manifest.velocity?  it's only used for that detachment, but...  i already know my own pre-friction (and post-friction) velocity...  how and why do friction and conservation fit in here?
    for _, manifest in pairs(self.cargo) do
        manifest.expiring = true
        if move and manifest.state == CARGO_PUSHING then
            manifest.velocity = move.pending_velocity
        else
            manifest.velocity = nil
        end
        print('', _, manifest.state, manifest.normal)
    end
end

function Tote:attach(cargum)
end

function Tote:detach(cargum)
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
        --if manifest.state == CARGO_CARRYING or manifest.normal * direction < 0 then
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
