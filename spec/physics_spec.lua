-- TODO
-- - declarative tests?  define them entirely within a Tiled map or something, including what to do and what should happen
-- - interactive LÖVE playback of a single test?

-- FIXME ideally, don't do this
_G.love = {
}
-- FIXME this either
_G.game = {
    -- FIXME deep in components
    time_push = function() end,
    time_pop = function() end,
}

local Vector = require 'klinklang.vendor.hump.vector'

local actors_base = require 'klinklang.actors.base'
local actors_map = require 'klinklang.actors.map'
local components_cargo = require 'klinklang.components.cargo'
local specutil = require 'klinklang.spec.util'
local whammo_shapes = require 'klinklang.whammo.shapes'
local world_mod = require 'klinklang.world'


local WALK_SPEED = 160
local WALK_ACCEL = 640
local JUMP_SPEED = 160
local FRICTION = 80

local Player = actors_base.SentientActor:extend{
    name = 'test player',
    svg_color = '#00f',

    COMPONENTS = {
        walk = {
            base_acceleration = WALK_ACCEL,
            speed_cap = WALK_SPEED,
        },
        jump = {
            speed = JUMP_SPEED,
        },
        fall = {
            friction_decel = 0,
        },
        [components_cargo.Tote] = {},
    },

    can_push = true,
    is_portable = true,

    -- 20x20 square, anchored at the bottom center
    shape = whammo_shapes.Box(-10, -20, 20, 20),
}

function Player:init(pos)
    self.shape = self.shape:clone()
    self.shape:move_to(pos:unpack())

    Player.__super.init(self, pos)
end


local Semisolid = actors_base.Actor:extend{
    name = 'test semisolid',
    svg_color = '#fa6',

    COMPONENTS = {},

    one_way_direction = Vector(0, -1),

    -- 100x100 square, anchored at the bottom center
    shape = whammo_shapes.Box(-50, -100, 100, 100),
}

function Semisolid:init(pos)
    self.shape = self.shape:clone()
    self.shape:move_to(pos:unpack())

    Semisolid.__super.init(self, pos)
end

function Semisolid:blocks()
    return true
end


local Crate = actors_base.MobileActor:extend{
    name = 'test crate',
    svg_color = '#f80',

    COMPONENTS = {
        [components_cargo.Tote] = {},
        fall = {
            friction_decel = FRICTION,
        },
    },

    can_push = true,
    can_carry = true,
    is_portable = true,
    is_pushable = true,

    -- 40x40 square, anchored at the bottom center
    shape = whammo_shapes.Box(-20, -40, 40, 40),
}

function Crate:init(pos)
    self.shape = self.shape:clone()
    self.shape:move_to(pos:unpack())

    Crate.__super.init(self, pos)
end


local Platform = actors_base.MobileActor:extend{
    name = 'test platform',
    svg_color = '#666',

    COMPONENTS = {
        [components_cargo.Tote] = {},
        fall = false,
    },

    can_carry = true,

    -- 100x20 rectangle, anchored at the top center
    shape = whammo_shapes.Box(-50, 0, 100, 20),
}

function Platform:init(pos)
    self.shape = self.shape:clone()
    self.shape:move_to(pos:unpack())

    Platform.__super.init(self, pos)

    self:get('move'):add_velocity(Vector(0, -40))
end


local function assert_are_equalish(expected, actual)
    if math.abs(expected - actual) > 1e-8 then
        assert.are.equal(expected, actual)
    end
end


local DT = 1/4

describe("Sentient actors", function()
    it("stay still on a slope", function()
        -- FIXME might be nice to get data from a test map, or otherwise
        -- describe maps in a more readable way
        local player = Player(Vector(100 - 10, 100))

        local world = world_mod.World(player)
        local map = world_mod.Map(world, 200, 200)
        -- FIXME i realize i am not actually sure how the player ends up in the map normally??
        map:add_actor(player)

        map:add_actor(actors_map.MapCollider(whammo_shapes.Polygon(0, 200, 200, 0, 200, 200)))

        -- FIXME need to do one update because the player won't realize it's on the ground to start with
        -- FIXME fix that, seriously, christ
        map:update(DT)
        -- FIXME now that we know we're on the ground, reset our velocity to
        -- zero.  otherwise, Walk will try to move uphill AND slope resistance
        -- will try to counteract gravity, when all i wanted to know was
        -- whether we were on the ground already.  this is so bad
        player:get('move').pending_velocity = Vector()
        player:get('move').velocity = Vector()

        specutil.dump_svg_on_error(map, function()
            local original_pos = player.pos
            for _ = 1, 4 do
                map:update(DT)
                assert.are.equal(player.pos, original_pos)
            end
        end)
    end)
end)

describe("A Tote actor", function()
    it("notice they have cargo", function()
        -- FIXME might be nice to get data from a test map, or otherwise
        -- describe maps in a more readable way
        local player = Player(Vector(100, 100))
        player.is_portable = true

        local platform = actors_base.MobileActor(Vector(100, 100))
        platform:set_shape(whammo_shapes.Box(-50, 0, 100, 100))
        local tote = components_cargo.Tote(platform)
        platform.can_carry = true
        platform.components['tote'] = tote

        local world = world_mod.World(player)
        local map = world_mod.Map(world, 200, 200)
        -- FIXME i realize i am not actually sure how the player ends up in the map normally??
        map:add_actor(player)
        map:add_actor(platform)

        -- Do one sync update so the player knows it's on the platform
        -- FIXME fix that too?
        map:update(DT)

        specutil.dump_svg_on_error(map, function()
            -- Check that the player gets, basically, carried around
            local player_pos = player.pos
            local delta = Vector(50, 0)
            platform:get('move'):nudge(delta)
            assert.are.equal(player.pos, player_pos + delta)

            player_pos = player_pos + delta
            delta = Vector(0, -50)
            platform:get('move'):nudge(delta)
            assert.are.equal(player.pos, player_pos + delta)
        end)
    end)
    it("can't push heavy objects", function()
        local player = Player(Vector(90, 100))
        local crate = Crate(Vector(120, 100))
        crate.mass = 100

        local world = world_mod.World(player)
        local map = world_mod.Map(world, 200, 100)
        map:add_actor(player)
        map:add_actor(crate)

        -- Do one sync update so the player knows it's on the ground, etc
        -- FIXME
        map:update(DT)

        specutil.dump_svg_on_error(map, function()
            -- Try to push the crate
            player:get('walk'):decide(1, 0)
            map:update(DT)
            assert.are.equal(Vector(120, 100), crate.pos)
            map:update(DT)
            assert.are.equal(Vector(120, 100), crate.pos)
            map:update(DT)
            assert.are.equal(Vector(120, 100), crate.pos)
        end)
    end)
    it("pushes objects on a flat plane", function()
        -- FIXME might be nice to get data from a test map, or otherwise
        -- describe maps in a more readable way
        local player = Player(Vector(50, 100))
        local crate = Crate(Vector(100, 100))

        local world = world_mod.World(player)
        local map = world_mod.Map(world, 200, 100)
        -- FIXME i realize i am not actually sure how the player ends up in the map normally??
        map:add_actor(player)
        map:add_actor(crate)

        local p_move = player:get('move')
        local c_move = crate:get('move')

        -- Do one sync update so the player knows it's on the ground, etc
        -- FIXME
        map:update(DT)

        -- Currently, they're arranged like so:
        -- .....pppppppp.....ccccccccccccccc.....
        --     40      60   80             120
        specutil.dump_svg_on_error(map, function()
            -- Try to push the box 20px, by moving 40px right
            print() print()
            player:get('walk'):decide(1, 0)
            --crate:get('fall').friction_decel = 0  -- FIXME once this is all sorted out
            p_move.velocity = Vector(160, 0)
            p_move.pending_velocity = Vector(160, 0)
            map:update(DT)
            -- NOTE: Ideally, hitting the box mid-frame would cut our physics
            -- in various ways, but that's hard
            assert.are.equal(Vector(120, 100), crate.pos)
            assert.are.equal(crate.pos.x - 30, player.pos.x)
            assert.are.equal(100, player.pos.y)
            -- Hitting the crate (mass 1) halved our speed
            assert.are.equal(Vector(80, 0), p_move.velocity)

            -- Push it for one more frame
            map:update(DT)
            local player_speed = WALK_SPEED / 2
            local max_speed = WALK_SPEED * (1 - FRICTION / WALK_ACCEL)
            -- TODO blah blah.
            -- TODO 150 is a bit weird but is because the player is trying to speed back up again
            assert.are.equal(Vector(150, 100), crate.pos)
            assert.are.equal(crate.pos.x - 30, player.pos.x)
            assert.are.equal(100, player.pos.y)

            -- Now push it another 40px, but jump at the same time
            print()
            print()
            print()
            print()
            print()
            player:get('jump'):decide(true)
            map:update(DT)
            -- Good luck doing the math this time
            assert(crate.pos.x > 150)
            assert.are.equal(100, crate.pos.y)
            assert.are.equal(crate.pos.x - 30, player.pos.x)
            assert.are.equal(100, player.pos.y)

            -- TODO more stuff to check:
            -- - push trains
            -- - push when one thing is on top of another
            -- - impact of push on velocity
            -- - friction exactly too much to push
            -- - pushing when there's something on your other side
            -- - pushing up a slope
            -- - crate and ice block coming apart
            -- FIXME probably don't use nudge here (or above) anyway, it's
            -- internal-ish and not reliable; there's just no way yet to add a
            -- one-off chunk of movement to a move
        end)
    end)
    it("can do stuff idk lemme lone", function()
        -- FIXME might be nice to get data from a test map, or otherwise
        -- describe maps in a more readable way
        local player = Player(Vector(50, 100))
        local tote = components_cargo.Tote(player)
        player.can_push = true
        player.components['tote'] = tote

        local crate1 = Crate(Vector(100, 100))
        local crate2 = Crate(Vector(140, 100))

        local world = world_mod.World(player)
        local map = world_mod.Map(world, 200, 200)
        -- Floor
        map:add_actor(actors_map.MapCollider(whammo_shapes.Box(0, 100, 200, 100)))
        -- FIXME i realize i am not actually sure how the player ends up in the map normally??
        map:add_actor(player)
        map:add_actor(crate1)
        map:add_actor(crate2)

        -- Do one sync update so the player knows it's on the ground, etc
        -- FIXME
        map:update(DT)

        local p_move = player:get('move')

        -- Currently, they're arranged like so:
        -- .....pppppppp.....111111111111111222222222222222.....
        --     40      60   80             120           160
        specutil.dump_svg_on_error(map, function()
            -- Try to push both boxes 20px, by moving 40px right
            p_move:nudge(Vector(40, 0))
            assert.are.equal(crate1.pos, Vector(120, 100))
            assert.are.equal(crate2.pos, Vector(160, 100))
            -- TODO more stuff to check:
            -- - push trains
            -- - push when one thing is on top of another
            -- - impact of push on velocity
            -- - friction exactly too much to push
            -- - pushing when there's something on your other side
            -- - pushing up a slope
            -- - crate and ice block coming apart
            -- FIXME probably don't use nudge here (or above) anyway, it's
            -- internal-ish and not reliable; there's just no way yet to add a
            -- one-off chunk of movement to a move
        end)
    end)
    it("can do stuff idk lemme lone 2", function()
        -- FIXME might be nice to get data from a test map, or otherwise
        -- describe maps in a more readable way
        -- put player ON TOP of boxes
        local player = Player(Vector(80, 60))
        local tote = components_cargo.Tote(player)
        player.can_push = true
        player.is_portable = true
        player.components['tote'] = tote

        -- Disable friction for simplicity here
        player.components['fall'].friction_decel = 0

        local crate1 = Crate(Vector(100, 100))
        local crate2 = Crate(Vector(140, 100))

        local world = world_mod.World(player)
        local map = world_mod.Map(world, 200, 200)
        -- Floor
        map:add_actor(actors_map.MapCollider(whammo_shapes.Box(0, 100, 200, 100)))
        -- FIXME i realize i am not actually sure how the player ends up in the map normally??
        map:add_actor(player)
        map:add_actor(crate1)
        map:add_actor(crate2)

        -- Do one sync update so the player knows it's on the ground, etc
        -- FIXME
        map:update(DT)

        local p_move = player:get('move')

        -- Currently, they're arranged like so:
        -- .....pppppppp.....111111111111111222222222222222.....
        --     40      60   80             120           160
        specutil.dump_svg_on_error(map, function()
            -- Try to push both boxes 20px, by moving 40px right
            --p_move:add_velocity(Vector(60, 0))
            player:get('walk'):decide(1, 0)
            map:update(1/4)
            print(p_move.velocity)
            assert.are.equal(crate1.pos, Vector(100, 100))
            assert.are.equal(crate2.pos, Vector(140, 100))
            -- TODO more stuff to check:
            -- - push trains
            -- - push when one thing is on top of another
            -- - impact of push on velocity
            -- - friction exactly too much to push
            -- - pushing when there's something on your other side
            -- - pushing up a slope
            -- - crate and ice block coming apart
            -- FIXME probably don't use nudge here (or above) anyway, it's
            -- internal-ish and not reliable; there's just no way yet to add a
            -- one-off chunk of movement to a move
        end)
    end)
    it("push a transitive stack without disturbing it", function()
        --[[
                  33
                  33
                1122
               P1122

            Pushing should not move #3, relative to #2.
            (The original problem I had here was that the push would first
            cause #1 to collide with #3, pick it up as a platform, and nudge
            it; but then #1 would collide with #2 and push it, but #2 still
            thought it was carrying #3 and nudged it AGAIN.)
        ]]
        local player = Player(Vector(90, 200))

        local crate1 = Crate(Vector(120, 200))
        local crate2 = Crate(Vector(160, 200))
        local crate3 = Crate(Vector(160, 160))

        local world = world_mod.World(player)
        local map = world_mod.Map(world, 400, 200)
        -- FIXME i realize i am not actually sure how the player ends up in the map normally??
        map:add_actor(player)
        map:add_actor(crate1)
        map:add_actor(crate2)
        map:add_actor(crate3)

        -- Do one sync update so the player knows it's on the ground, etc
        -- FIXME
        map:update(DT)

        local p_move = player:get('move')

        specutil.dump_svg_on_error(map, function()
            print()
            print()
            -- Walk right into the two crates
            player:get('walk'):decide(1, 0)
            map:update(1/4)
            print(p_move.velocity)
            print('player now at', player.pos)
            print('crates now at', crate1.pos, crate2.pos, crate3.pos)
            assert.are.equal(crate2.pos.x, crate3.pos.x)
            -- TODO more stuff to check:
            -- - push trains
            -- - push when one thing is on top of another
            -- - impact of push on velocity
            -- - friction exactly too much to push
            -- - pushing when there's something on your other side
            -- - pushing up a slope
            -- - crate and ice block coming apart
            -- FIXME probably don't use nudge here (or above) anyway, it's
            -- internal-ish and not reliable; there's just no way yet to add a
            -- one-off chunk of movement to a move
        end)
    end)
    it("pick up an object when rising into it from below", function()
        --[[
                11
                11

            pppppppppp

            The platform should pick up the crate.
            (Actors only have one "ground" actor they consider themselves to be
            standing on, and that complicates cargo logic somewhat.)
        ]]
        local platform = Platform(Vector(100, 215))
        local platform_pos0 = platform.pos
        local crate_pos0 = Vector(100, 200)
        local crate = Crate(crate_pos0)

        local world = world_mod.World(nil)
        local map = world_mod.Map(world, 400, 200)
        map:add_actor(platform)
        map:add_actor(crate)

        -- Sync update
        -- FIXME
        map:update(DT)
        -- Platform is now 5 below the crate (205)
        -- FIXME hey i'd love to have a way to do like...  "do an update, i expect these movements"?  hell, eventually, it would be nice to define tests completely declaratively.  with tiled, even.

        specutil.dump_svg_on_error(map, function()
            print()
            print()
            -- Do a partial move: it's trying to move 10, 5 of it is
            -- unobstructed, but the other 5 requires picking up the crate
            map:update(DT)
            -- Platform rose 5 up into the crate and should now be holding it
            -- Platform should now be holding the crate
            assert.are.equal(platform.pos.y, 195)
            assert.are.equal(platform.pos.y, crate.pos.y)

            -- Do a full move; both should move up another 10
            print()
            print()
            print()
            print()
            print()
            map:update(DT)
            assert.are.equal(platform.pos.y, 185)
            assert.are.equal(platform.pos.y, crate.pos.y)
        end)
    end)
    it("ignore objects they're walking onto", function()
        --[[
               P
            ssss11
            ssss11

            Moving right should not push the crate.
            (Corner case.)
        ]]
        local player = Player(Vector(90, 160))
        local semisolid = Semisolid(Vector(100, 260))
        local crate = Crate(Vector(120, 200))

        local world = world_mod.World(nil)
        local map = world_mod.Map(world, 400, 200)
        map:add_actor(player)
        map:add_actor(semisolid)
        map:add_actor(crate)

        -- Sync update
        -- FIXME?
            player:get('walk'):decide(1, 0)
        map:update(DT)

        specutil.dump_svg_on_error(map, function()
            map:update(DT)
            assert.are.equal(crate.pos.x, 120)
            assert.are_not.equal(player.pos.x, 90)
        end)
    end)
    it("push objects as a system", function()
        --[[
              CCCC
              CCCC   #
              CCCC  ##
            PPCCCC ###
            PP  ######

            Moving right should push the crate, but that will move it up the
            slope (thus changing its trajectory partway), AND the player will
            hit the small ledge partway through the movement.
        ]]
        -- TODO ok lemme think.
        -- [step 0: you move until you hit a thing]
        -- step 1: you try to move.  you hit the crate.  which is your cargo, too, which is fine
        -- step 2: you and the crate BOTH try to move, but different amounts??
        --  at this point we have 
        local player = Player(Vector(90, 200))
        local crate = Crate(Vector(120, 190))

        local world = world_mod.World(nil)
        local map = world_mod.Map(world, 400, 200)
        map:add_actor(player)
        map:add_actor(crate)
        map:add_actor(actors_map.MapCollider(whammo_shapes.Box(120, 190, 80, 10)))
        map:add_actor(actors_map.MapCollider(whammo_shapes.Polygon(150, 190, 200, 140, 200, 190)))

        -- Sync update
        -- FIXME?
        map:update(DT)

        specutil.dump_svg_on_error(map, function()
            print() print() print()
            player:get('move'):nudge(Vector(40, 0))
            assert.are.equal(player.pos, Vector(110, 200))
            assert.are.equal(crate.pos, Vector(140, 180))
        end)
    end)
    it("pushes objects onto a slope", function()
        --[[
            PPCCCC   #
            PPCCCC  ##
            PPCCCC ###
            PPCCCC####
        ]]
        local player = Player(Vector(90, 200))
        player.is_pushable = true
        -- Player has to be tall or it'll slip under the crate!
        player:set_shape(whammo_shapes.Box(-10, -80, 20, 80))
        local crate = Crate(Vector(120, 200))
        -- Crate currently has the hardcoded gravity of 768, which is more than
        -- the player's walk acceleration, so it /cannot/ push up a slope.
        -- Adjust that here, but TODO would be nice to unhardcode of course.
        crate:get('fall').multiplier = 200/768

        local world = world_mod.World(nil)
        local map = world_mod.Map(world, 400, 200)
        map:add_actor(player)
        map:add_actor(crate)
        map:add_actor(actors_map.MapCollider(whammo_shapes.Polygon(150, 200, 350, 0, 350, 200)))

        -- Sync update
        -- FIXME?
        player:get('walk'):decide(1, 0)
        map:update(DT)

        specutil.dump_svg_on_error(map, function()
            print() print() print()
            --player:get('move'):nudge(Vector(40, 0))
            map:update(DT)
            --assert.are.equal(Vector(96.25, 200), player.pos)
            --assert.are.equal(Vector(126.25, 200), crate.pos)
            print() print() print() print('===', player.pos, crate.pos) print() print() print()
            map:update(DT)
            print() print() print() print('===', player.pos, crate.pos) print() print() print()
            map:update(DT)
            print() print() print() print('===', player.pos, crate.pos) print() print() print()
            -- FIXME actually test something here
            map:update(DT)
            print() print() print() print('===', player.pos, crate.pos) print() print() print()
            map:update(DT)
            map:update(DT)
            map:update(DT)
            error()
        end)
    end)

    it("pushes objects uphill", function()
        --[[
              CCCC
              CCCC  #
            PPCCCC ##
            PPCCCC###
            PP   ####
            PP  #####
            PP ######
            PP#######
             ########
        ]] 
        local player = Player(Vector(10, 380))
        -- Player has to be tall or it'll slip under the crate!
        player:set_shape(whammo_shapes.Box(-10, -80, 20, 80))
        local crate = Crate(Vector(40, 340))

        local world = world_mod.World(player)
        local map = world_mod.Map(world, 400, 400)
        map:add_actor(player)
        map:add_actor(crate)
        map:add_actor(actors_map.MapCollider(whammo_shapes.Polygon(0, 400, 400, 0, 400, 400)))

        -- Sync update
        -- FIXME?  even more annoying now that this is on a slope
        player:get('walk'):decide(1, 0)
        map:update(DT)
        -- FIXME now that we know we're on the ground, reset our velocity to
        -- zero.  otherwise, Walk will try to move uphill AND slope resistance
        -- will try to counteract gravity, when all i wanted to know was
        -- whether we were on the ground already.  this is so bad
        player:get('move').pending_velocity = Vector()
        player:get('move').velocity = Vector()

        specutil.dump_svg_on_error(map, function()
            local _ds = {}
            -- Pushing the crate should, of course, move it uphill.  Push for a
            -- couple frames to get up to max speed
            local last_player_pos = player.pos
            for _ = 1, 4 do
                map:update(DT)
                -- Some movement should happen
                assert(player.pos.x > last_player_pos.x)
                -- Crate and player should stay together
                assert_are_equalish(30, crate.pos.x - player.pos.x)

                table.insert(_ds, player.pos - last_player_pos)
                last_player_pos = player.pos
            end
            local normal_push_speed = player:get('move').velocity:len()

            -- Now remove the crate's friction, and we should move faster
            crate:get('fall').friction_decel = 0
            for _ = 1, 4 do
                map:update(DT)
                assert(player.pos.x > last_player_pos.x)
                assert_are_equalish(30, crate.pos.x - player.pos.x)

                table.insert(_ds, player.pos - last_player_pos)
                last_player_pos = player.pos
            end
            local frictionless_push_speed = player:get('move').velocity:len()

            -- Now remove the crate entirely, and we should move faster still;
            -- we wouldn't on flat ground, because zero friction means pushing
            -- the crate is effortless, but on a slope we still need to counter
            -- its gravity!
            map:remove_actor(crate)
            for _ = 1, 4 do
                map:update(DT)
                assert(player.pos.x > last_player_pos.x)

                table.insert(_ds, player.pos - last_player_pos)
                last_player_pos = player.pos
            end
            local lone_speed = player:get('move').velocity:len()
            print() print() for _, d in ipairs(_ds) do print(d) end

            print()
            print()
            print("normal push speed", normal_push_speed)
            print("frictionless push speed", frictionless_push_speed)
            print("lone walk speed", lone_speed)
            assert(frictionless_push_speed > normal_push_speed)
            -- FIXME FIXME FIXME!  gah, the /movement/ is greater, but the speed is the same!  i suspect the push is being projected on the normal, which becomes a nudge on the crate, which is projected on the slope, which loses some power.  but really it should be like
            --          alone           crate, no friction          crate
            -- slope    ~28.284 (40)    20.142 (28.5)               17.955 (25.5)
            -- flat     40              40                          31.25
            assert(lone_speed > frictionless_push_speed)
        end)
    end)

    it("pushes transitively", function()
        --[[
                11  22
            P   11  22

            Second crate is slippier
        ]] 
        local player = Player(Vector(30, 200))
        local crate1 = Crate(Vector(60, 200))
        local crate2 = Crate(Vector(100, 200))
        crate2:get('fall').friction_decel = FRICTION / 4

        local world = world_mod.World(player)
        local map = world_mod.Map(world, 400, 200)
        -- Add the player last so the update order doesn't match the push order
        map:add_actor(crate1)
        map:add_actor(crate2)
        map:add_actor(player)

        specutil.dump_svg_on_error(map, function()
            player:get('walk'):decide(1, 0)
            -- Update once to set the player's velocity
            map:update(DT)

            local crate1x = crate1.pos.x
            -- As the player walks, the crates should move in lockstep
            for _ = 1, 4 do
                map:update(DT)
                assert_are_equalish(player.pos.x + 30, crate1.pos.x)
                assert_are_equalish(crate1.pos.x + 40, crate2.pos.x)
                assert(crate1.pos.x > crate1x)
                crate1x = crate1.pos.x
            end

            -- Removing the player should cause the lower-friction second crate
            -- to slide ahead faster
            map:remove_actor(player)
            -- Allow one update for the crates to realize they're no longer
            -- being pushed
            map:update(DT)

            local crate2x = crate2.pos.x
            for _ = 1, 4 do
                print(_)
                map:update(DT)
                assert(crate1.pos.x > crate1x)
                assert(crate2.pos.x > crate2x)
                -- Second crate should have moved further
                assert(crate2.pos.x - crate1.pos.x > crate2x - crate1x)
                crate1x = crate1.pos.x
                crate2x = crate2.pos.x
            end
        end)
    end)

    it("doesn't send transitive cargo flying", function()
        -- This test checks for a particular circumstance:
        -- 1. The player runs into a crate, picking it up at max speed
        -- 2. The player + crate run into an ice block, picking it up
        -- 3. The ice block flies off ahead of both of them (!)
        -- The cause was the use of current velocity for calculating how much
        -- momentum to spread around, when it should've been pending velocity.
        -- Because of that, the player added some velocity to the (stationary)
        -- ice block, then the crate added MORE velocity to what it thought was
        -- STILL a stationary ice block, before the ice block had updated!
        local player = Player(Vector(10, 200))
        local crate1 = Crate(Vector(100, 200))
        local crate2 = Crate(Vector(200, 200))
        crate2:get('fall').friction_decel = FRICTION / 4

        local world = world_mod.World(nil)
        local map = world_mod.Map(world, 400, 200)
        map:add_actor(crate1)
        map:add_actor(crate2)
        -- XXX if player goes first, crate1 gets ahead of ti...
        map:add_actor(player)

        -- Sync update
        -- FIXME?
        player:get('walk'):decide(1, 0)
        map:update(DT)

        specutil.dump_svg_on_error(map, function()
            -- Loop until the first frame that picks up the ice block
            local crate2_x0 = crate2.pos.x
            for i = 1, 20 do
                map:update(DT)
                if crate2.pos.x > crate2_x0 then
                    break
                elseif i == 20 then
                    error("Ice block seems stuck!")
                end
            end

            -- Then update once more; this left the ice block with excessive velocity
            -- (Note that this problem only appears at reasonable framerates;
            -- at our test framerate of 4, the player and crate immediately
            -- catch up before the block can really get away from them)
            map:update(1/64)
            -- And one final update allows the ice block to get away
            map:update(1/64)

            -- So assert that that didn't happen
            assert_are_equalish(crate1.pos.x, crate2.pos.x - 40)
        end)
    end)
end)
