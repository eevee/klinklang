local Vector = require 'klinklang.vendor.hump.vector'

local whammo = require 'klinklang.whammo'
local Collision = require 'klinklang.whammo.collision'
local whammo_shapes = require 'klinklang.whammo.shapes'

-- FIXME this code doesn't test normals, barely tests contacts, doesn't test separation or penetration...

-- Default blocking behavior: block on actual collisions, i.e. contact_type > 0
local function default_pass_callback(collision)
    return collision.contact_type <= 0
end

local function do_simple_slide(collider, shape, movement)
    local successful, hits = collider:sweep(shape, movement, default_pass_callback)
    shape:move(successful:unpack())
    if successful == movement then
        return successful, hits
    end

    -- Just slide once; should be enough for testing purposes
    -- XXX it seems weird to have tests that rely largely on how well this
    -- utility function works.  i would love some tests for the actor stuff
    -- (though i'd need to ditch worldscene, ideally)
    local remaining, slid = Collision:slide_along_normals(hits, movement - successful)
    if slid then
        local successful2
        successful2, hits = collider:sweep(shape, remaining, default_pass_callback)
        shape:move(successful2:unpack())
        return successful + successful2, hits
    else
        return successful, hits
    end
end

local function run_simple_test(args)
    local collider = whammo.Collider(400)
    local obstacle = whammo_shapes.Box(args.obstacle.x, args.obstacle.y, 100, 100)
    collider:add(obstacle)

    local player = whammo_shapes.Box(args.player.x, args.player.y, 100, 100)
    local successful, hits = collider:sweep(player, args.attempted, default_pass_callback)
    assert.are.equal(args.successful, successful)

    -- FIXME need a better way to separate input from expected output
    local collision = hits[obstacle]
    if not args.touchtype then
        assert.are.equal(nil, collision)
    else
        assert.are.equal(args.touchtype, collision.touchtype)
        assert.are.equal(args.contact_start, args.attempted * collision.contact_start)
        if args.contact_end == nil then
            -- Multiplying here would just give NaNs
            assert.are.equal(math.huge, collision.contact_end)
        else
            assert.are.equal(args.contact_end, args.attempted * collision.contact_end)
        end
        assert.are.equal(args.contact_type, collision.contact_type)
        assert.are.equal(args.left_normal, collision.left_normal)
        assert.are.equal(args.right_normal, collision.right_normal)

        player:move(successful:unpack())
        local first, second = collision:get_contact()
        if args.contact_edge == nil then
            assert.are.equal(nil, first)
        elseif #args.contact_edge == 1 then
            assert.are.equal(args.contact_edge[1], first)
            assert.are.equal(args.contact_edge[1], second)
        else
            assert.are.equal(args.contact_edge[1], first)
            assert.are.equal(args.contact_edge[2], second)
        end
    end
end

describe("Collision", function()
    -- Simple cases using AABBs, basically to make sure the output is correct

    it("handles non-collision moving directly away", function()
        --[[
            PPPP    OOOO
            PPPP <- OOOO
            PPPP    OOOO
            PPPP    OOOO
        ]]
        run_simple_test{
            player = Vector(0, 0),
            obstacle = Vector(200, 0),
            attempted = Vector(-200, 0),

            successful = Vector(-200, 0),
        }
    end)

    it("handles head-on collision", function()
        --[[
            PPPP    OOOO
            PPPP -> OOOO
            PPPP    OOOO
            PPPP    OOOO
        ]]
        run_simple_test{
            player = Vector(0, 0),
            obstacle = Vector(200, 0),
            attempted = Vector(200, 0),

            successful = Vector(100, 0),
            touchtype = 1,
            contact_start = Vector(100, 0),
            contact_end = Vector(300, 0),
            contact_type = 1,
            contact_edge = {Vector(200, 0), Vector(200, 100)},
            left_normal = Vector(-1, 0),
            right_normal = Vector(-1, 0),
        }
    end)

    it("handles off-angle collision", function()
        --[[
            PPPP    OOOO
            PPPP \  OOOO
            PPPP  ┘ OOOO
            PPPP    OOOO
        ]]
        -- A little hard to tell from the diagram, but the player is moving at
        -- (2, 1) and hits the obstacle halfway down.
        run_simple_test{
            player = Vector(0, 0),
            obstacle = Vector(200, 0),
            attempted = Vector(200, 100),

            successful = Vector(100, 50),
            touchtype = 1,
            contact_start = Vector(100, 50),
            contact_end = Vector(200, 100),
            contact_type = 1,
            contact_edge = {Vector(200, 50), Vector(200, 100)},
            left_normal = Vector(-1, 0),
            right_normal = nil,
        }
    end)

    it("handles near-miss collision", function()
        --[[
            PPPP    OOOO
            PPPP \  OOOO
            PPPP  ┘ OOOO
            PPPP    OOOO
        ]]
        -- This time the player exactly scrapes the corner of the obstacle.
        run_simple_test{
            player = Vector(0, 0),
            obstacle = Vector(200, 0),
            attempted = Vector(200, 200),

            successful = Vector(200, 200),
            touchtype = 0,
            contact_start = Vector(100, 100),
            contact_end = Vector(100, 100),
            contact_type = 0,
            -- TODO hm, well, here's a limitation of get_contact: it can't
            -- tell me what the contact would've been partway along.  but maybe
            -- that's not interesting anyway?
            contact_edge = nil,
            left_normal = Vector(-200, 200),
            right_normal = nil,
        }
    end)

    -- TODO various slides
    -- TODO convert that "don't hit at all" case to this format
    -- TODO corner-corner hits with different angles

    it("identifies normals in a motionless corner touch", function()
        --[[
            PPPP
            PPPP
            PPPP
            PPPP
                ####
                ####
                ####
                ####
        ]]
        -- No movement!
        run_simple_test{
            player = Vector(0, 0),
            obstacle = Vector(100, 100),
            attempted = Vector(0, 0),

            successful = Vector(0, 0),
            touchtype = 0,
            contact_start = Vector(0, 0),
            contact_end = nil,
            contact_type = 0,
            contact_edge = nil,
            -- FIXME wait, hang on.  there's no notion of "left" or "right" if you're not moving!  should this use...  the axis instead maybe?  if you were LOOKING that way??
            left_normal = Vector(0, -1),
            right_normal = Vector(-1, 0),
        }
    end)


    it("allows separating straight out from an overlap", function()
        --[[
            PPPPOOO
         <- PPPPOOO
            PPPPOOO
            PPPPOOO
        ]]
        run_simple_test{
            player = Vector(0, 0),
            obstacle = Vector(75, 0),
            attempted = Vector(-100, 0),

            successful = Vector(-100, 0),
            touchtype = -1,
            contact_start = Vector(0, 0),
            contact_end = Vector(-25, 0),
            contact_type = -1,
            contact_edge = nil,
            left_normal = nil,
            right_normal = nil,
        }
    end)

    it("allows separating at an odd angle from an overlap", function()
        --[[
            PPPPOOO
         ┌  PPPPOOO
          \ PPPPOOO
            PPPPOOO
        ]]
        run_simple_test{
            player = Vector(0, 0),
            obstacle = Vector(75, 0),
            attempted = Vector(-100, -100),

            successful = Vector(-100, -100),
            touchtype = -1,
            contact_start = Vector(0, 0),
            contact_end = Vector(-25, -25),
            contact_type = -1,
            contact_edge = nil,
            left_normal = nil,
            right_normal = nil,
        }
    end)

    it("allows sliding within an overlap", function()
        --[[
            PPPPOOO
          | PPPPOOO
          v PPPPOOO
            PPPPOOO
        ]]
        run_simple_test{
            player = Vector(0, 0),
            obstacle = Vector(75, 0),
            attempted = Vector(0, 50),

            successful = Vector(0, 50),
            touchtype = -1,
            contact_start = Vector(0, 0),
            contact_end = Vector(0, 100),
            contact_type = 0,
            contact_edge = nil,
            left_normal = Vector(-1, 0),
            right_normal = nil,
        }
    end)

    it("allows sliding in all four directions within a corner overlap", function()
        --[[
             <->
            PPPP
          ^ PPPP
          | PPPP##
          v PPPP##
              ####
              ####
        ]]
        -- Try all directions, just in case order matters, which it absolutely
        -- has on multiple attempts to get this right.
        -- Moving outwards...
        -- Up:
        run_simple_test{
            player = Vector(0, 0),
            obstacle = Vector(50, 50),
            attempted = Vector(0, -100),

            successful = Vector(0, -100),
            touchtype = -1,
            contact_start = Vector(0, 0),
            contact_end = Vector(0, -50),
            -- You could argue that this is either a slide or a separation, but
            -- since the movement /causes/ the normal on the right to become
            -- blocking, I call it a slide along that normal
            -- FIXME decide on this
            contact_type = 0,
            contact_edge = nil,
            left_normal = nil,
            right_normal = Vector(-1, 0),
        }
        -- Left:
        run_simple_test{
            player = Vector(0, 0),
            obstacle = Vector(50, 50),
            attempted = Vector(-100, 0),

            successful = Vector(-100, 0),
            touchtype = -1,
            contact_start = Vector(0, 0),
            contact_end = Vector(-50, 0),
            contact_type = 0,
            contact_edge = nil,
            left_normal = Vector(0, -1),
            right_normal = nil,
        }
        -- Moving inwards (as a slide):
        -- Down:
        run_simple_test{
            player = Vector(0, 0),
            obstacle = Vector(50, 50),
            attempted = Vector(0, 100),

            successful = Vector(0, 0),
            touchtype = -1,
            contact_start = Vector(0, 0),
            contact_end = Vector(0, 150),
            contact_type = 1,
            contact_edge = nil,
            left_normal = Vector(-1, 0),
            right_normal = Vector(0, -1),
        }
        -- Right:
        run_simple_test{
            player = Vector(0, 0),
            obstacle = Vector(50, 50),
            attempted = Vector(100, 0),

            successful = Vector(0, 0),
            touchtype = -1,
            contact_start = Vector(0, 0),
            contact_end = Vector(150, 0),
            contact_type = 1,
            contact_edge = nil,
            left_normal = Vector(-1, 0),
            right_normal = Vector(0, -1),
        }
    end)

    it("allows sliding in only one direction within an unequal corner overlap", function()
        --[[
             ->
            PPPP
          | PPPP
          v PPPP
            PPPP##
              ####
              ####
              ####
        ]]
        -- Down, should be blocked because it would increase overlap in the
        -- minimal direction:
        run_simple_test{
            player = Vector(0, 0),
            obstacle = Vector(50, 75),
            attempted = Vector(0, 100),

            successful = Vector(0, 0),
            touchtype = -1,
            contact_start = Vector(0, 0),
            contact_end = Vector(0, 175),
            contact_type = 1,
            contact_edge = nil,
            left_normal = Vector(0, -1),
            right_normal = Vector(0, -1),
        }
        -- Right, should be allowed as a slide:
        run_simple_test{
            player = Vector(0, 0),
            obstacle = Vector(50, 75),
            attempted = Vector(100, 0),

            successful = Vector(100, 0),
            touchtype = -1,
            contact_start = Vector(0, 0),
            contact_end = Vector(150, 0),
            contact_type = 0,
            contact_edge = nil,
            left_normal = nil,
            right_normal = Vector(0, -1),
        }
    end)

    it("identifies normals in a motionless corner overlap", function()
        --[[
            PPPP
            PPPP
            PPPP##
            PPPP##
              ####
              ####
        ]]
        -- No movement!
        run_simple_test{
            player = Vector(0, 0),
            obstacle = Vector(50, 50),
            attempted = Vector(0, 0),

            successful = Vector(0, 0),
            touchtype = -1,
            contact_start = Vector(0, 0),
            contact_end = nil,
            contact_type = 0,
            contact_edge = nil,
            -- FIXME wait, hang on.  there's no notion of "left" or "right" if you're not moving!  should this use...  the axis instead maybe?  if you were LOOKING that way??
            left_normal = Vector(0, -1),
            right_normal = Vector(-1, 0),
        }
    end)

    it("prevents worsening an overlap", function()
        --[[
            PPPPOOO
         -> PPPPOOO
            PPPPOOO
            PPPPOOO
        ]]
        run_simple_test{
            player = Vector(0, 0),
            obstacle = Vector(75, 0),
            attempted = Vector(100, 0),

            successful = Vector(0, 0),
            touchtype = -1,
            contact_start = Vector(0, 0),
            contact_end = Vector(175, 0),
            contact_type = 1,
            -- FIXME what /is/ the contact "edge" for overlaps?  should it be a shape??  that sounds very hard.
            contact_edge = nil,
            left_normal = Vector(-1, 0),
            right_normal = Vector(-1, 0),
        }
    end)

    it("prevents worsening an overlap at an odd angle", function()
        --[[
            PPPPOOO
         \  PPPPOOO
          ┘ PPPPOOO
            PPPPOOO
        ]]
        run_simple_test{
            player = Vector(0, 0),
            obstacle = Vector(75, 0),
            attempted = Vector(100, 100),

            successful = Vector(0, 0),
            touchtype = -1,
            contact_start = Vector(0, 0),
            contact_end = Vector(100, 100),
            contact_type = 1,
            contact_edge = nil,
            left_normal = Vector(-1, 0),
            right_normal = nil,
        }
    end)

    it("prevents worsening a corner overlap", function()
        --[[
           ↘
            PPPP
            PPPP
            PPPP##
            PPPP##
              ####
              ####
        ]]
        -- This is specifically to check that the normals are both there
        run_simple_test{
            player = Vector(0, 0),
            obstacle = Vector(50, 50),
            attempted = Vector(100, 100),

            successful = Vector(0, 0),
            touchtype = -1,
            contact_start = Vector(0, 0),
            contact_end = Vector(150, 150),
            contact_type = 1,
            -- FIXME what /is/ the contact "edge" for overlaps?  should it be a shape??  that sounds very hard.
            contact_edge = nil,
            left_normal = Vector(-1, 0),
            right_normal = Vector(0, -1),
        }
    end)

    it("prevents worsening an overlap via sliding", function()
        --[[
            PPPP
          | PPPP
          v PPPP
            PPPP##
              ####
              ####
              ####
        ]]
        -- Make sure that minimum penetration stuff works!
        run_simple_test{
            player = Vector(0, 0),
            obstacle = Vector(50, 75),
            attempted = Vector(0, 100),

            successful = Vector(0, 0),
            touchtype = -1,
            contact_start = Vector(0, 0),
            contact_end = Vector(0, 175),
            contact_type = 1,
            -- FIXME what /is/ the contact "edge" for overlaps?  should it be a shape??  that sounds very hard.
            contact_edge = nil,
            left_normal = Vector(0, -1),
            right_normal = Vector(0, -1),
        }
    end)
    it("prevents worsening an overlap via sliding 2", function()
        --[[
            PPPP
          / PPPP
         └  PPPP
            PPPP##
              ####
              ####
              ####
        ]]
        -- Very shallow movement, an obscure case that revealed a gaping hole
        -- in overlap handling when I found it
        run_simple_test{
            player = Vector(0, 0),
            obstacle = Vector(50, 75),
            attempted = Vector(-50, 10),

            successful = Vector(0, 0),
            touchtype = -1,
            contact_start = Vector(0, 0),
            contact_end = Vector(-50, 10),
            contact_type = 1,
            -- FIXME what /is/ the contact "edge" for overlaps?  should it be a shape??  that sounds very hard.
            contact_edge = nil,
            left_normal = Vector(0, -1),
            right_normal = nil,
        }
    end)


    ----------------------------------------------------------------------------
    -- Classic miscellaneous ad-hoc tests

    it("should handle orthogonal movement", function()
        --[[
            +--------+
            | player |
            +--------+
            | floor  |
            +--------+
            movement is straight down; should do nothing
        ]]
        local collider = whammo.Collider(400)
        local floor = whammo_shapes.Box(0, 100, 100, 100)
        collider:add(floor)

        local player = whammo_shapes.Box(0, 0, 100, 100)
        local successful, hits = collider:sweep(player, Vector(0, 50), default_pass_callback)
        assert.are.equal(Vector(0, 0), successful)
        assert.are.equal(1, hits[floor].touchtype)

        assert.are.equal(0, hits[floor].contact_start)
        assert.are.equal(4, hits[floor].contact_end)
        assert.are.equal(1, hits[floor].contact_type)

        -- Check contacts
        local first, second = hits[floor]:get_contact()
        assert.are.equal(Vector(100, 100), first)
        assert.are.equal(Vector(0, 100), second)
    end)
    it("should handle diagonal almost-parallel movement", function()
        -- This one is hard to ASCII-art, but the numbers are smaller!
        -- The player is moving towards a shallow slope at an even shallower
        -- angle, and should hit the slope partway up it.  My math used to be
        -- all kinds of bad and didn't correctly handle this case.
        local collider = whammo.Collider(4)
        local floor = whammo_shapes.Polygon(0, 0, 0, -2, 3, -1)
        collider:add(floor)

        local player = whammo_shapes.Box(4, -3, 2, 2)
        local successful, hits = collider:sweep(player, Vector(-3, -0.5), default_pass_callback)
        assert.are.equal(Vector(-2, -1/3), successful)
        assert.are.equal(1, hits[floor].touchtype)

        -- Check normals
        assert.are.equal(Vector(1, -3), hits[floor].left_normal)
        assert.are.equal(nil, hits[floor].right_normal)

        -- Check contacts
        player:move(successful:unpack())
        local first, second = hits[floor]:get_contact()
        assert.are.equal(Vector(2, -4/3), first)
        assert.are.equal(Vector(2, -4/3), second)
    end)
    it("should stop at the first obstacle", function()
        --[[
                +--------+
                | player |
                +--------+
            +--------+
            | floor1 |+--------+ 
            +--------+| floor2 | 
                      +--------+
            movement is straight down; should hit floor1 and stop
        ]]
        local collider = whammo.Collider(400)
        local floor1 = whammo_shapes.Box(0, 150, 100, 100)
        collider:add(floor1)
        local floor2 = whammo_shapes.Box(100, 200, 100, 100)
        collider:add(floor2)

        local player = whammo_shapes.Box(50, 0, 100, 100)
        local successful, hits = collider:sweep(player, Vector(0, 150), default_pass_callback)
        assert.are.equal(Vector(0, 50), successful)
        assert.are.equal(1, hits[floor1].touchtype)
        assert.are.equal(nil, hits[floor2])

        -- Check contacts
        player:move(successful:unpack())
        local first, second = hits[floor1]:get_contact()
        assert.are.equal(Vector(100, 150), first)
        assert.are.equal(Vector(50, 150), second)
    end)
    it("should allow sliding past an obstacle", function()
        --[[
            +--------+
            |  wall  |
            +--------+
                     +--------+
                     | player |
                     +--------+
            movement is straight up; shouldn't collide
        ]]
        local collider = whammo.Collider(400)
        local wall = whammo_shapes.Box(0, 0, 100, 100)
        collider:add(wall)

        local player = whammo_shapes.Box(100, 150, 100, 100)
        local successful, hits = collider:sweep(player, Vector(0, -150), default_pass_callback)
        assert.are.equal(Vector(0, -150), successful)
        assert.are.equal(0, hits[wall].touchtype)

        -- Check contacts
        player:move(successful:unpack())
        local first, second = hits[wall]:get_contact()
        assert.are.equal(Vector(100, 100), first)
        assert.are.equal(Vector(100, 0), second)
    end)
    it("should allow sliding through a perfect gap", function()
        --[[
                        +--------+
                        |  wall  |
            +--------+  +--------+
            | player |
            +--------+  +--------+
                        | floor  |
                        +--------+
            movement is due right
        ]]
        local collider = whammo.Collider(4 * 100)
        local wall = whammo_shapes.Box(150, 0, 100, 100)
        collider:add(wall)
        local floor = whammo_shapes.Box(150, 200, 100, 100)
        collider:add(floor)

        local player = whammo_shapes.Box(0, 100, 100, 100)
        local move = Vector(300, 0)
        local successful, hits = collider:sweep(player, move, default_pass_callback)
        assert.are.equal(move, successful)
        assert.are.equal(0, hits[floor].touchtype)
        assert.are.equal(0, hits[wall].touchtype)

        -- Check contacts
        player:move(successful:unpack())
        local wall_contact = hits[floor]:get_contact()
        assert.are.equal(nil, wall_contact)
        local floor_contact = hits[floor]:get_contact()
        assert.are.equal(nil, floor_contact)
    end)
    it("should handle diagonal movement into lone corners", function()
        --[[
            +--------+
            |  wall  |
            +--------+
                       +--------+
                       | player |
                       +--------+
            movement is up and to the left (more left); should slide left along
            the ceiling
        ]]
        local collider = whammo.Collider(400)
        local wall = whammo_shapes.Box(0, 0, 100, 100)
        collider:add(wall)

        local player = whammo_shapes.Box(200, 150, 100, 100)
        local successful, hits = do_simple_slide(collider, player, Vector(-200, -100))
        assert.are.equal(Vector(-200, -50), successful)
        assert.are.equal(0, hits[wall].touchtype)

        -- Check contacts
        local first, second = hits[wall]:get_contact()
        assert.are.equal(Vector(0, 100), first)
        assert.are.equal(Vector(100, 100), second)
    end)
    it("should handle diagonal movement into corners with walls", function()
        --[[
            +--------+
            | wall 1 |
            +--------+--------+
            | wall 2 | player |
            +--------+--------+
            movement is up and to the left; should slide along the wall upwards
        ]]
        local collider = whammo.Collider(400)
        local wall1 = whammo_shapes.Box(0, 0, 100, 100)
        collider:add(wall1)
        local wall2 = whammo_shapes.Box(0, 100, 100, 100)
        collider:add(wall2)

        local player = whammo_shapes.Box(100, 100, 100, 100)
        local successful, hits = do_simple_slide(collider, player, Vector(-50, -50))
        assert.are.equal(Vector(0, -50), successful)
        assert.are.equal(0, hits[wall1].touchtype)
        assert.are.equal(0, hits[wall2].touchtype)
    end)
    it("should handle movement blocked in multiple directions", function()
        --[[
            +--------+--------+
            | wall 1 | wall 2 |
            +--------+--------+
            | wall 3 | player |
            +--------+--------+
            movement is up and to the left; should not move at all
        ]]
        local collider = whammo.Collider(400)
        local wall1 = whammo_shapes.Box(0, 0, 100, 100)
        collider:add(wall1)
        local wall2 = whammo_shapes.Box(100, 0, 100, 100)
        collider:add(wall2)
        local wall3 = whammo_shapes.Box(0, 100, 100, 100)
        collider:add(wall3)

        local player = whammo_shapes.Box(100, 100, 100, 100)
        local successful, hits = collider:sweep(player, Vector(-50, -50), default_pass_callback)
        assert.are.equal(Vector(0, 0), successful)
        assert.are.equal(1, hits[wall1].touchtype)
        assert.are.equal(1, hits[wall2].touchtype)
        assert.are.equal(1, hits[wall3].touchtype)
    end)
    it("should slide you down when pressed against a corner", function()
        --[[
                     +--------+
            +--------+ player |
            |  wall  +--------+
            +--------+
            movement is down and to the left; should slide down along the wall
            at full speed
        ]]
        local collider = whammo.Collider(400)
        local wall = whammo_shapes.Box(0, 50, 100, 100)
        collider:add(wall)

        local player = whammo_shapes.Box(100, 0, 100, 100)
        local successful, hits = do_simple_slide(collider, player, Vector(-100, 50))
        assert.are.equal(Vector(0, 50), successful)
        assert.are.equal(0, hits[wall].touchtype)
    end)
    it("should slide you down when pressed against a wall", function()
        --[[
            +--------+
            | wall 1 +--------+
            +--------+ player |
            | wall 2 +--------+
            +--------+
            movement is down and to the left; should slide down along the wall
            at full speed
        ]]
        local collider = whammo.Collider(400)
        local wall1 = whammo_shapes.Box(0, 0, 100, 100)
        collider:add(wall1)
        local wall2 = whammo_shapes.Box(0, 100, 100, 100)
        collider:add(wall2)

        local player = whammo_shapes.Box(100, 50, 100, 100)
        local successful, hits = do_simple_slide(collider, player, Vector(-50, 100))
        assert.are.equal(Vector(0, 100), successful)
        assert.are.equal(0, hits[wall1].touchtype)
        assert.are.equal(0, hits[wall2].touchtype)
    end)
    it("should slide you along slopes", function()
        --[[
            +--------+
            | player |
            +--------+
            | ""--,,_
            | floor  +    (this is actually a triangle)
            +--------+
            movement is straight down; should slide rightwards along the slope
        ]]
        local collider = whammo.Collider(400)
        local floor = whammo_shapes.Polygon(0, 100, 100, 150, 0, 150)
        collider:add(floor)

        local player = whammo_shapes.Box(0, 0, 100, 100)
        local successful, hits = do_simple_slide(collider, player, Vector(0, 100))
        assert.are.equal(Vector(40, 20), successful)
        assert.are.equal(0, hits[floor].touchtype)
    end)
    it("should slide you along slopes, even with touching corners, slant up", function()
        -- Same as above, except the bottom of the "player" box slants up and
        -- to the right
        local collider = whammo.Collider(400)
        local floor = whammo_shapes.Polygon(0, 100, 100, 150, 0, 150)
        collider:add(floor)

        local player = whammo_shapes.Polygon(0, 0, 0, 100, 100, 90, 100, 0)
        local successful, hits = do_simple_slide(collider, player, Vector(0, 100))
        assert.are.equal(Vector(40, 20), successful)
        assert.are.equal(0, hits[floor].touchtype)
    end)
    it("should slide you along slopes, even with touching corners, slant down", function()
        -- Same as above, except the bottom of the "player" box slants down and
        -- to the right
        local collider = whammo.Collider(400)
        local floor = whammo_shapes.Polygon(0, 100, 100, 150, 0, 150)
        collider:add(floor)

        local player = whammo_shapes.Polygon(0, 0, 0, 100, 100, 110, 100, 0)
        local successful, hits = do_simple_slide(collider, player, Vector(0, 100))
        assert.are.equal(Vector(40, 20), successful)
        assert.are.equal(0, hits[floor].touchtype)
    end)
    it("should not put you inside slopes", function()
        --[[
            +--------+
            | player |
            +--------+
            | ""--,,_
            | floor  +    (this is actually a triangle)
            +--------+
            movement is straight down; should slide rightwards along the slope
        ]]
        local collider = whammo.Collider(64)
        -- Unlike above, this does not make a triangle with nice angles; the
        -- results are messy floats.
        -- Also, if it weren't obvious, this was taken from an actual game.
        local floor = whammo_shapes.Polygon(400, 552, 416, 556, 416, 560, 400, 560)
        collider:add(floor)

        local player = whammo_shapes.Box(415 - 8, 553 - 29, 13, 28)
        local successful, hits = collider:sweep(player, Vector(0, 2), default_pass_callback)
        assert.are.equal(1, hits[floor].touchtype)

        -- We don't actually care about the exact results; we just want to be
        -- sure we aren't inside the slope on the next tic
        local successful, hits = collider:sweep(player, Vector(0, 10), default_pass_callback)
        assert.are.equal(1, hits[floor].touchtype)
    end)
    --[==[ TODO i...  am not sure how to make this work yet
    it("should quantize correctly", function()
        --[[
            +-----+--------+
            |wall/| player |
            |   / +--------+
            |  /
            | /
            |/
            +-------+
            | floor |
            +-------+
            movement is exactly parallel to the wall.  however, the floor is
            not pixel-aligned, so the final position won't be either, and we'll
            need to back up to find a valid pixel.  we should NOT end up inside
            the wall.

            FIXME for bonus points, do this in all eight directions
        ]]
        local collider = whammo.Collider(64)
        local wall = whammo_shapes.Polygon(0, 0, 100, 0, 0, 200)
        collider:add(wall)
        -- yes, the floor overlaps the wall, it's fine
        local floor = whammo_shapes.Box(0, 199.5, 200, 200)
        collider:add(floor)

        local player = whammo_shapes.Box(100, 0, 100, 100)
        local successful, hits = collider:sweep(player, Vector(-100, 200), default_pass_callback)
        --assert.are.equal(Vector(-49, 98), successful)
        assert.are.equal(1, hits[wall].touchtype)
        assert.are.equal(1, hits[floor].touchtype)
        local successful, hits = collider:sweep(player, Vector(-100, 200), default_pass_callback)
        local successful, hits = collider:sweep(player, Vector(-100, 200), default_pass_callback)
        local successful, hits = collider:sweep(player, Vector(-100, 200), default_pass_callback)
    end)
    ]==]
    it("should not round you into a wall", function()
        --[[
            +-----+
            |wall/
            |   /   +--------+
            |  /    | player |
            | /     +--------+
            |/
            +
            movement is left and down; should slide along the wall and NOT be
            inside it on the next frame
        ]]
        local collider = whammo.Collider(64)
        -- Unlike above, this does not make a triangle with nice angles; the
        -- results are messy floats.
        -- Also, if it weren't obvious, this was taken from an actual game.
        local x, y = 492, 1478
        local wall = whammo_shapes.Polygon(x + 0, y + 0, x - 18, y + 62, x - 18, y + 0)
        collider:add(wall)
        local floor = whammo_shapes.Box(510 - 62, 1540, 62, 14)
        collider:add(floor)

        local player = whammo_shapes.Box(491.125 - 8, 1537.75 - 29, 13, 28)
        local successful, hits = collider:sweep(player, Vector(-1, 2.25), default_pass_callback)
        assert.are.equal(1, hits[wall].touchtype)

        -- We don't actually care about the exact results; we just want to be
        -- sure we aren't inside the slope on the next tic
        local successful, hits = collider:sweep(player, Vector(-0.875, 2.375), default_pass_callback)
        assert.are.equal(1, hits[wall].touchtype)
    end)
    it("should not register slides against objects out of range", function()
        --[[
            +--------+
            | player |
            +--------+    +--------+--------+
                          | floor1 | floor2 |
                          +--------+--------+
            movement is directly right; should not be blocked at all, should
            slide on floor 1, should NOT slide on floor 2
        ]]
        local collider = whammo.Collider(400)
        local floor1 = whammo_shapes.Box(150, 100, 100, 100)
        collider:add(floor1)
        local floor2 = whammo_shapes.Box(250, 100, 100, 100)
        collider:add(floor2)

        local player = whammo_shapes.Box(0, 0, 100, 100)
        local successful, hits = collider:sweep(player, Vector(100, 0), default_pass_callback)
        assert.are.equal(Vector(100, 0), successful)
        assert.are_equal(0, hits[floor1].touchtype)
        assert.are_equal(nil, hits[floor2])
    end)
    it("should count touches even when not moving", function()
        --[[
                     +--------+
                     | player |
            +--------+--------+--------+
            | floor1 | floor2 | floor3 |
            +--------+--------+--------+
            movement is nowhere; should touch all three floors
            at full speed
        ]]
        local collider = whammo.Collider(400)
        local floor1 = whammo_shapes.Box(0, 100, 100, 100)
        collider:add(floor1)
        local floor2 = whammo_shapes.Box(100, 100, 100, 100)
        collider:add(floor2)
        local floor3 = whammo_shapes.Box(200, 100, 100, 100)
        collider:add(floor3)

        local player = whammo_shapes.Box(100, 0, 100, 100)
        local successful, hits = collider:sweep(player, Vector(0, 0), default_pass_callback)
        assert.are.equal(Vector(0, 0), successful)
        assert.are.equal(0, hits[floor1].touchtype)
        assert.are.equal(0, hits[floor2].touchtype)
        assert.are.equal(0, hits[floor3].touchtype)
    end)
    it("should ignore existing overlaps", function()
        --[[
                    +--------+
            +-------++player |
            | floor ++-------+
            +--------+
            movement is to the left; shouldn't block us at all
        ]]
        -- FIXME update this test
        local collider = whammo.Collider(400)
        local floor = whammo_shapes.Box(0, 100, 100, 100)
        collider:add(floor)

        local player = whammo_shapes.Box(80, 80, 100, 100)
        local successful, hits = collider:sweep(player, Vector(-200, 0), default_pass_callback)
        --assert.are.equal(Vector(-200, 0), successful)
        assert.are.equal(Vector(0, 0), successful)
        assert.are.equal(-1, hits[floor].touchtype)

        local c = hits[floor]
        print("normals we got:", c.left_normal, c.right_normal)
        print("other stuff:", c.separation)

        -- Now try moving out of it
        local successful, hits = collider:sweep(player, Vector(200, 0), default_pass_callback)
        assert.are.equal(Vector(200, 0), successful)
        assert.are.equal(-1, hits[floor].touchtype)
        local c = hits[floor]
        print("normals we got:", c.left_normal, c.right_normal)
        print("other stuff:", c.separation)
    end)

    it("should not let you fall into the floor", function()
        --[[
            Actual case seen when playing:
            +--------+
            | player |
            +--------+--------+
            | floor1 | floor2 |
            +--------+--------+
            movement is right and down (due to gravity)
        ]]
        local collider = whammo.Collider(4 * 32)
        local floor1 = whammo_shapes.Box(448, 384, 32, 32)
        collider:add(floor1)
        local floor2 = whammo_shapes.Box(32, 256, 32, 32)
        collider:add(floor2)

        local player = whammo_shapes.Box(443, 320, 32, 64)
        local successful, hits = do_simple_slide(collider, player, Vector(4.3068122830999, 0.73455352286288))
        assert.are.equal(Vector(4.3068122830999, 0), successful)
        -- XXX this is 0 because the last movement was a slide, but obviously
        -- you DID collide with it...  within the game that's tested with the
        -- callback though
        assert.are.equal(0, hits[floor1].touchtype)
    end)

    it("should allow near misses", function()
        --[[
            Actual case seen when playing:
                    +--------+
                    | player |
                    +--------+

            +--------+
            | floor  |
            +--------+
            movement is right and down, such that the player will graze but not
            actually collide with the floor
        ]]
        local collider = whammo.Collider(4 * 100)
        local floor = whammo_shapes.Box(0, 250, 100, 100)
        collider:add(floor)

        local player = whammo_shapes.Box(0, 0, 100, 100)
        local move = Vector(150, 150)
        local successful, hits = collider:sweep(player, move, default_pass_callback)
        assert.are.equal(move, successful)
        assert.are.equal(nil, hits[floor])
    end)

    -- FIXME clean up these fuckin tests
    it("should indicate whether we slid past something", function()
        --[[
            +--------+
            | player |
            +--------+          +--------+
                               /  floor   \
                              +------------+
            movement is due right, such that we graze the floor
        ]]
        local collider = whammo.Collider(400)
        --local floor = whammo_shapes.Box(200, 100, 100, 100)
        -- This floor is a trapezoid so the initial touch and the eventual
        -- un-touch are along different axes.  The top runs from 200 to 300.
        local floor = whammo_shapes.Polygon(200, 100, 300, 100, 350, 200, 150, 200)
        collider:add(floor)

        local player = whammo_shapes.Box(0, 0, 100, 100)
        for _, case in ipairs{{400}} do
            local attempted_x = unpack(case)
            local attempted = Vector(attempted_x, 0)
            local successful, hits = collider:sweep(player, attempted, default_pass_callback)
            assert.are.equal(attempted, successful)

            local collision = hits[floor]
            assert.are.equal(0, collision.touchtype)

            assert.are.equal(Vector(100, 0), attempted * collision.contact_start)
            assert.are.equal(Vector(300, 0), attempted * collision.contact_end)
            assert.are.equal(0, collision.contact_type)

            --[[
            -- Check contacts
            local first, second = hits[floor]:get_contact()
            assert.are.equal(Vector(100, 100), first)
            assert.are.equal(Vector(0, 100), second)
            ]]
        end
    end)

    it("should indicate whether we slid past something 2", function()
        --[[
            +--------+
            | player |
            +--------+          +--------+
                               /  floor   \
                              +------------+
            movement is due right, such that we graze the floor
        ]]
        local collider = whammo.Collider(400)
        --local floor = whammo_shapes.Box(200, 100, 100, 100)
        -- This floor is a trapezoid so the initial touch and the eventual
        -- un-touch are along different axes.  The top runs from 200 to 300.
        local floor = whammo_shapes.Polygon(200, 100, 300, 100, 350, 200, 150, 200)
        collider:add(floor)

        local player = whammo_shapes.Polygon(50, 0, 100, 50, 50, 100, 0, 50)
        player:move(200, 0)
        for _, case in ipairs{{400}} do
            local attempted_x = unpack(case)
            local attempted = Vector(attempted_x, 0)
            local successful, hits = collider:sweep(player, attempted, default_pass_callback)
            assert.are.equal(attempted, successful)

            local collision = hits[floor]
            assert.are.equal(0, collision.touchtype)

            assert.are.equal(Vector(0, 0), attempted * collision.contact_start)
            assert.are.equal(Vector(50, 0), attempted * collision.contact_end)
            assert.are.equal(0, collision.contact_type)

            --[[
            -- Check contacts
            local first, second = hits[floor]:get_contact()
            assert.are.equal(Vector(100, 100), first)
            assert.are.equal(Vector(0, 100), second)
            ]]
        end
    end)

    it("blah blah", function()
        local collider = whammo.Collider(400)
        --local floor = whammo_shapes.Box(200, 100, 100, 100)
        -- This floor is a trapezoid so the initial touch and the eventual
        -- un-touch are along different axes.  The top runs from 200 to 300.
        local floor = whammo_shapes.Polygon(0, 0, 300, 200, 0, 200)
        collider:add(floor)

        -- Should be exactly touching the floor
        local player = whammo_shapes.Box(150, 0, 100, 100)
        local attempted = Vector(75, 50)
        local successful, hits = collider:sweep(player, attempted, default_pass_callback)
        assert.are.equal(attempted, successful)

        local collision = hits[floor]

        assert.are.equal(Vector(0, 0), attempted * collision.contact_start)
        assert.are.equal(Vector(150, 100), attempted * collision.contact_end)
        assert.are.equal(0, collision.contact_type)

        --[[
        -- Check contacts
        local first, second = hits[floor]:get_contact()
        assert.are.equal(Vector(100, 100), first)
        assert.are.equal(Vector(0, 100), second)
        ]]
    end)

    it("blah blah blah", function()
        local collider = whammo.Collider(400)
        --local floor = whammo_shapes.Box(200, 100, 100, 100)
        local floor = whammo_shapes.Polygon(100, 200, 300, 300, 100, 300)
        collider:add(floor)

        -- Will come into the floor at a 45° angle and hit its top corner with our own corner, but the floor is shallower than that
        local player = whammo_shapes.Box(0, 0, 100, 100)
        local attempted = Vector(200, 200)
        local successful, hits = collider:sweep(player, attempted, default_pass_callback)
        assert.are.equal(Vector(100, 100), successful)

        local collision = hits[floor]

        assert.are.equal(nil, collision.left_normal)
        assert.are.equal(Vector(100, -200), collision.right_normal)

        assert.are.equal(Vector(100, 100), attempted * collision.contact_start)
        assert.are.equal(Vector(300, 300), attempted * collision.contact_end)
        assert.are.equal(1, collision.contact_type)

    end)
end)
