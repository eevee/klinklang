local anim8 = require 'klinklang.vendor.anim8'
local Vector = require 'klinklang.vendor.hump.vector'

local Object = require 'klinklang.object'

--------------------------------------------------------------------------------
-- SpriteSet
-- Contains a number of 'poses', each of which is an anim8 animation.  Can
-- switch between them and draw with a simplified API.

local Sprite
local SpriteSet = Object:extend{
    _all_sprites = {},
}

function SpriteSet:init(name, image)
    self.name = name
    self.poses = {}
    self.default_pose = nil
    self.image = image

    SpriteSet._all_sprites[name] = self
end

-- Adds a new pose, which may be animated.  All frames are presumed to be the
-- same size, and all frames of all poses must be part of the same image.
-- Adding a new pose with the same name is an error, EXCEPT in the case of
-- adding a left view to a pose that only has a right view defined (or vice
-- versa).
-- Arguments:
--   name: The name of the pose, used with Sprite:set_pose.
--   anchor: When Sprite:draw_at is called, the sprite will be positioned such
--      that this point (a Vector) on the sprite appears at the desired
--      position.
--   shape: An optional collision shape.  Somewhat clumsy at the moment.
-- FIXME i think the 'inheritance' behavior for side-view is totally accidental since it don't work for top-down.  maybe copy shape + anchor from default pose if it doesn't yet exist?  but urgh wait, i want to avoid changing collision shape as much as humanly possible, so i really do only want one of them, but it only gets copied around because (a) i generate both left+right right from the beginning and (b) changing pose doesn't change shape by default.  i should do something about all this, sometime.
--   frames: A list of Quads defining how to cut out each frame.
--   durations: Frame durations, in seconds.  Passed directly to anim8.
--   onloop: Behavior for the end of the loop.  Passed directly to anim8.
--   flipped: If true, the frames face to the left, and will be flipped when
--      the sprite faces right (rather than the other way around).
--   symmetrical: If true, the pose is taken to be explicitly symmetrical, meaning it will be used
--      as-is for both left and right facings (with no flipping).  Useful for, e.g., a pose in a
--      sidescroller that faces directly towards or away from the camera (which may not actually be
--      symmetrical).
-- FIXME that behavior exists for a reason but also is kind of absurd
-- FIXME it is now possible to have only SOME facings for a particular sprite, oof
function SpriteSet:add_pose(args)
    local pose_name = args.name
    local anchor = args.anchor
    local shape = args.shape
    local frames = args.frames
    local durations = args.durations
    local onloop = args.onloop
    local flipped = args.flipped
    local symmetrical = args.symmetrical
    local facing = args.facing or 'right'
    local source_tile = args.source_tile

    local pose
    if self.poses[pose_name] then
        pose = self.poses[pose_name]
        if pose[facing] and pose[facing].explicit then
            error(("Pose %s already exists for sprite %s"):format(pose_name, self.name))
        end
    else
        pose = {}
        self.poses[pose_name] = pose
    end

    -- FIXME this is pretty hokey and seems really specific to platformers
    local anim = anim8.newAnimation(frames, durations, onloop)
    local normal_data = {
        animation = anim,
        shape = shape,
        anchor = anchor,
        source_tile = source_tile,
    }

    if facing == 'up' or facing == 'down' then
        normal_data.explicit = true
        pose[facing] = normal_data
    else  -- left or right
        -- FIXME this assumes the frames are all the same size; either avoid
        -- requiring that (which may be impossible) or explicitly enforce it
        local left_data, right_data
        local _, _, w, _ = frames[1]:getViewport()
        if symmetrical then
            left_data, right_data = normal_data, normal_data
            normal_data.explicit = true
        else
            local flipped_shape
            if shape then
                flipped_shape = shape:flipx(0)
            end
            flipped_data = {
                animation = anim:clone():flipH(),
                shape = flipped_shape,
                anchor = Vector(w - anchor.x, anchor.y),
                source_tile = source_tile,
            }

            -- Handle flippedness
            if flipped then
                left_data, right_data = normal_data, flipped_data
            else
                left_data, right_data = flipped_data, normal_data
            end

            -- Handle asymmetry
            if facing == 'left' then
                left_data.explicit = true
            else
                right_data.explicit = true
            end
        end

        -- Assign the pose facings
        if not pose.left or not pose.left.explicit then
            pose.left = left_data
        end
        if not pose.right or not pose.right.explicit then
            pose.right = right_data
        end
    end

    if not self.default_pose then
        self.default_pose = pose_name
    end
end

-- A Sprite is a definition; call this to get an instance with state, which can
-- draw itself and remember its current pose
function SpriteSet:instantiate(...)
    return Sprite(self, ...)
end

Sprite = Object:extend{}

function Sprite:init(spriteset, pose_name, facing)
    self.spriteset = spriteset
    self.scale = 1
    self.speed = 1
    self.pose = nil
    self.facing = facing or 'right'
    self.changed_this_frame = false
    self.anim = nil
    self.loop_callback = nil

    if pose_name and spriteset.poses[pose_name] == nil then
        self:_gripe_no_such_pose(pose_name)
    end
    self:_set_pose(pose_name or spriteset.default_pose)
end

-- Change to the given pose.
-- If given, the callback will be called the next time the animation reaches its end, /or/ the next
-- time the pose is changed.  It will be passed an argument that's true if the pose was changed.
function Sprite:set_pose(pose, callback)
    if pose == self.pose then
        -- "Changing" to the same pose shouldn't restart it
        if callback then
            if self.anim.status == 'paused' and self.anim.timer == self.anim.totalDuration then
                -- Special case: if we're already at this pose, and it's stopped at the end, run the
                -- new callback now; otherwise it will likely never run!
                callback()
            else
                self:_add_loop_callback(callback)
            end
        end
    elseif self.spriteset.poses[pose] then
        self:_set_pose(pose)
        if callback then
            self:_add_loop_callback(callback)
        end
    else
        self:_gripe_no_such_pose(pose)
    end
end

function Sprite:_gripe_no_such_pose(pose)
    local all_poses = {}
    for pose_name in pairs(self.spriteset.poses) do
        table.insert(all_poses, pose_name)
    end
    table.sort(all_poses)
    error(("No such pose '%s' for %s (available: %s)"):format(
        pose, self.spriteset.name, table.concat(all_poses, ", ")))
end

-- Internal method that actually changes the pose.
-- Doesn't check whether the pose exists, and changing to the current pose will restart it.
function Sprite:_set_pose(pose)
    -- If we still have a pending callback, run it now
    self:run_loop_callback(true)

    self.pose = pose
    local data = self.spriteset.poses[pose][self.facing]
    -- TODO we could avoid cloning so much if we just kept the timer on ourselves?
    self.anim = data.animation:clone()
    self.anim.onLoop = function(anim, loops)
        self:run_loop_callback(false)
        local f = data.animation.onLoop
        if type(f) == 'function' then
            f(anim, loops)
        elseif f then
            anim[f](anim, loops)
        end
    end
    self.anchor = data.anchor
    self.shape = data.shape

    -- If update() sees this flag is set, it clears the flag and skips the
    -- update, so that changing the pose and then updating won't skip part of
    -- the new pose's first frame.  All of the draw methods clear this flag, so
    -- changing the pose after updating won't skip the next frame's update.
    self.changed_this_frame = true
end

-- Set a function to be called whenever the current pose reaches its end.
-- If the pose is changed before that happens, the callback is abandoned.
-- TODO this could probably be neater?
function Sprite:_add_loop_callback(callback)
    if self.loop_callback then
        local old = self.loop_callback
        self.loop_callback = function(interrupted)
            callback(interrupted)
            old(interrupted)
        end
    else
        self.loop_callback = callback
    end
end

function Sprite:run_loop_callback(interrupted)
    if self.loop_callback then
        -- Delete it FIRST, since it could try to set the pose itself, which would then recurse!
        -- TODO what on earth should happen in that case?  should the callback win and we abort the current set_pose?
        local cb = self.loop_callback
        self.loop_callback = nil
        cb(interrupted)
    end
end

function Sprite:set_facing(facing)
    if facing ~= self.facing then
        self.facing = facing
        -- Restart the animation if we're changing direction
        self:_set_pose(self.pose)
    end
end

function Sprite:set_scale(scale)
    self.scale = scale
end

function Sprite:set_speed(speed)
    self.speed = speed
end

function Sprite:getDimensions()
    local w, h = self.anim:getDimensions()
    return w * self.scale, h * self.scale
end

function Sprite:update(dt)
    if self.changed_this_frame then
        self.changed_this_frame = false
        return
    end

    self.anim:update(dt * self.speed)
end

function Sprite:draw_at(x, y)
    if type(x) == 'table' then
        x, y = x:unpack()
    end
    self.changed_this_frame = false
    -- TODO hm, how do i auto-batch?  shame there's nothing for doing that
    -- built in?  seems an obvious thing
    self.anim:draw(
        self.spriteset.image,
        math.floor(x - self.anchor.x * self.scale + 0.5),
        math.floor(y - self.anchor.y * self.scale + 0.5),
        0, self.scale, self.scale)
end

function Sprite:draw_anchorless(x, y)
    if type(x) == 'table' then
        x, y = x:unpack()
    end
    self.changed_this_frame = false
    self.anim:draw(
        self.spriteset.image,
        math.floor(x + 0.5),
        math.floor(y + 0.5),
        0, self.scale, self.scale)
end


return SpriteSet
