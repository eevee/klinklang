local Vector = require 'klinklang.vendor.hump.vector'

local actors_base = require 'klinklang.actors.base'
local Object = require 'klinklang.object'
local util = require 'klinklang.util'

local Component = require 'klinklang.components.base'


-- TODO consolidate groups of (static) wires into circuits, which take over the
-- management for all of them.  it'd work the same way but conceptually be a
-- lot simpler, and power wouldn't be able to warble back and forth when there
-- are two sources and one of them turns off.  would also make it plausible to
-- use this system to connect teleporters since you could ask "ok what all is
-- connected to this circuit".  or, similarly, only show power flowing when
-- there's actually something at the other end?  (nb: when you do this, delete
-- the coinciding nodes!)
local Circuit

local _weak_keys = { __mode = 'k' }
local Node = Object:extend{
    _is_emitting = false,
    is_powered = false,
}
function Node:init(owner, anchor, offset)
    self.owner = owner
    self.absolute_position = anchor + offset
    self.connections = setmetatable({}, _weak_keys)
end

function Node:coincides(other)
    return self.absolute_position == other.absolute_position
end

function Node:connect(other)
    if self.connections[other] then
        return
    end

    self:_connect(other)
    other:_connect(self)
end

function Node:_connect(other)
    self.connections[other] = true

    -- If we're emitting, try to emit to them.  If the other way around,
    -- they're responsible for doing it to us
    if self._is_emitting then
    end
end

-- An actor with Conduct has some number of wiring nodes, which connect to
-- matching nodes on other Conduct actors.  A connection can be receiving
-- power, in which case (a) this actor is powered, and (b) this actor cannot
-- send power back the same way.
-- An actor may also be a 'generator', meaning it's a power source and is thus
-- always powered.
-- Multiple nodes may all connect to each other, and two actors may be
-- connected to each other two different ways through two pairs of nodes.
-- However, it is assumed that a single actor will never have two nodes in the
-- same position.
local Conduct = Component:extend{
    slot = 'conduct',

    powered = false,
}

function Conduct:init(actor, args)
    Conduct.__super.init(self, actor, args)
    self.is_generator = args.is_generator

    self.powered = self.is_generator
    self.nodes = {}
    self.connections = {}
end

-- Read wiring nodes from an actor's TiledTile.  It's passed to the
-- constructor, so we can't get it from down here.  Sorry!
function Conduct:load_nodes_from_tile(tile)
    if tile.extra_shapes and tile.extra_shapes['wiring node'] then
        for _, offset in ipairs(tile.extra_shapes['wiring node']) do
            if tile.anchor then
                offset = offset - tile.anchor
            end
            self:add_node(offset)
        end
    end
end

function Conduct:add_node(offset)
    -- FIXME this assumes we never move, for now
    table.insert(self.nodes, Node(self, offset, self.actor.pos))
end

function Conduct:on_enter(map)
    -- FIXME get neighbors from the collider (but wait, how; wires may not have
    -- collision so they wouldn't be in the collider at all!)
    for _, actor in ipairs(map.actors) do
        local conduct = actor:get('conduct')
        if actor == self.actor or not conduct then
            goto continue
        end

        for i, our_node in ipairs(self.nodes) do
            for j, their_node in ipairs(conduct.nodes) do
                if our_node:coincides(their_node) then
                    self:connect(conduct, our_node, their_node)
                end
            end
        end

        ::continue::
    end
end

function Conduct:connect(other, our_node, their_node)
    self:_connect(other, our_node, their_node)
    other:_connect(self, their_node, our_node)

    -- Only check this after connections are made in both directions; if we do
    -- it in _connect it'll break!
    if self.powered then
        other:set_receiving(our_node, true)
    elseif other.powered then
        -- This is an elseif because if we were already powered, we're not
        -- actually receiving from them!
        self:set_receiving(their_node, true)
    end
end

function Conduct:_connect(other, our_node, their_node)
    self.connections[their_node] = {
        our_node = our_node,
        -- This is populated momentarily, in connect()
        receiving = false,
    }
end

function Conduct:_set_powered(powered)
    if powered == self.powered then
        return
    end

    self.powered = powered

    if self.actor.on_power_change then
        self.actor:on_power_change(powered)
    end

    -- Propagate the signal, and do it last, because it might recurse and
    -- change our power state again
    for other_node, info in pairs(self.connections) do
        -- But don't emit power if they're already powering /us/
        if not (powered and self.connections[other_node].receiving) then
            other_node.owner:set_receiving(info.our_node, powered)
        end
    end
end

function Conduct:set_receiving(their_node, receiving)
    if self.connections[their_node].receiving == receiving then
        return
    end
    self.connections[their_node].receiving = receiving

    if receiving then
        -- Check if we just switched from unpowered to powered
        self:_set_powered(true)
    else
        -- Check if we just switched from powered to unpowered, which is
        -- slightly more complicated
        self:_check_reception()
        -- If we're still powered, then since we're no longer receiving from
        -- /them/, they can now receive from us
        if self.powered then
            their_node.owner:set_receiving(self.connections[their_node].our_node, true)
        end
    end
end

function Conduct:set_generator(is_generator)
    if is_generator == self.is_generator then
        return
    end

    self.is_generator = is_generator
    if is_generator then
        self:_set_powered(true)
    else
        self:_check_reception()
    end
end

-- If we're already powered, check whether we still ought to be
function Conduct:_check_reception()
    if not self.powered then
        -- Obviously nothing will change here
        return
    end
    if self.is_generator then
        -- We're self-powered, so we don't care
        return
    end

    for other_node, info in pairs(self.connections) do
        if info.receiving then
            -- Another node is powering us, we're OK
            return
        end
    end

    -- Looks like we're all alone!
    self:_set_powered(false)
end


return {
    Conduct = Conduct,
}
