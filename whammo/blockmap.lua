--[[
A spatial hash.
]]

local Object = require 'klinklang.object'

local Blockmap = Object:extend()

function Blockmap:init(blocksize)
    self.blocksize = blocksize
    self.wiggle_margin = blocksize / 64
    self.blocks = {}
    self.bboxes = setmetatable({}, {__mode = 'k'})
    self.min_x = math.huge
    self.max_x = -math.huge
    self.min_y = math.huge
    self.max_y = -math.huge
end

function Blockmap:to_block_units(x, y)
    return math.floor(x / self.blocksize), math.floor(y / self.blocksize)
end

function Blockmap:block(x, y)
    return self:raw_block(self:to_block_units(x, y))
end

function Blockmap:raw_block(a, b)
    local column = self.blocks[a]
    if not column then
        column = {}
        self.blocks[a] = column
    end
    
    local block = column[b]
    if not block then
        block = setmetatable({}, {__mode = 'k'})
        column[b] = block
    end

    return block
end

function Blockmap:add(obj)
    obj:remember_blockmap(self)
    local x0, y0, x1, y1 = obj:bbox()

    -- Pad the bbox very slightly, so that e.g. objects lying exactly on a grid
    -- line count as being in both cells.  Helps avoid literal edge and corner
    -- cases when trying to find objects.
    x0 = x0 - self.wiggle_margin
    y0 = y0 - self.wiggle_margin
    x1 = x1 + self.wiggle_margin
    y1 = y1 + self.wiggle_margin

    local a0, b0 = self:to_block_units(x0, y0)
    local a1, b1 = self:to_block_units(x1, y1)
    for a = a0, a1 do
        for b = b0, b1 do
            local block = self:raw_block(a, b)
            block[obj] = true
        end
    end
    -- XXX why not store as blocks
    self.bboxes[obj] = {x0, y0, x1, y1}

    self.min_x = math.min(self.min_x, x0)
    self.max_x = math.max(self.max_x, x1)
    self.min_y = math.min(self.min_y, y0)
    self.max_y = math.max(self.max_y, y1)
end

function Blockmap:remove(obj)
    obj:forget_blockmap(self)
    local x0, y0, x1, y1 = unpack(self.bboxes[obj])
    local a0, b0 = self:to_block_units(x0, y0)
    local a1, b1 = self:to_block_units(x1, y1)
    for a = a0, a1 do
        for b = b0, b1 do
            local block = self:raw_block(a, b)
            block[obj] = nil
        end
    end
    self.bboxes[obj] = nil
end

function Blockmap:update(obj)
    -- XXX could be more efficient i guess
    self:remove(obj)
    self:add(obj)
end

function Blockmap:neighbors(obj, dx, dy)
    local x0, y0, x1, y1 = obj:extended_bbox(dx, dy)

    -- XXX could put the wiggle margin here and save some effort for grid-aligned objects, though
    -- raycast behavior would need touching up for when a ray goes along a line or through a corner
    local a0, b0 = self:to_block_units(x0, y0)
    local a1, b1 = self:to_block_units(x1, y1)
    local ret = {}
    for a = a0, a1 do
        local column = self.blocks[a]
        if column then
            for b = b0, b1 do
                -- Get the block manually, to avoid creating one if not necessary
                local block = column[b]
                if block then
                    for neighbor in pairs(block) do
                        ret[neighbor] = true
                    end
                end
            end
        end
    end

    -- Objects do not neighbor themselves
    ret[obj] = nil

    return ret
end

-- Casts a ray from the given point in the given direction.  Returns a list of
-- {a, b} pairs containing coordinates of all the blocks the ray passes
-- through, in order.
-- TODO i'd love if this were an iterator, but turning the loops into closures is a bit ugly
function Blockmap:raycast(x, y, dx, dy)
    -- TODO if the ray starts outside the grid (extremely unlikely), we should
    -- find the point where it ENTERS the grid, otherwise the 'while'
    -- conditions below will stop immediately
    local a, b = self:to_block_units(x, y)

    if dx == 0 and dy == 0 then
        -- Special case: the ray goes nowhere, so only return this block
        return {{a, b}}
    end

    -- Use a modified Bresenham.  Use mirroring to move everything into the
    -- first quadrant, then split it into two octants depending on whether dx
    -- or dy increases faster, and call that the main axis.  Track an "error"
    -- value, which is the (negative) distance between the ray and the next
    -- grid line parallel to the main axis, but scaled up by dx.  Every
    -- iteration, we move one cell along the main axis and increase the error
    -- value by dy (the ray's slope, scaled up by dx); when it becomes
    -- positive, we can subtract dx (1) and move one cell along the minor axis
    -- as well.  Since the main axis is the faster one, we'll never traverse
    -- more than one cell on the minor axis for one cell on the main axis, and
    -- this readily provides every cell the ray hits in order.
    -- Based on: http://www.idav.ucdavis.edu/education/GraphicsNotes/Bresenhams-Algorithm/Bresenhams-Algorithm.html

    -- Setup: map to the first quadrant.  The "offsets" are the distance
    -- between the starting point and the next grid point.
    local step_a = 1
    local offset_x = 1 - (x / self.blocksize - a)
    if dx < 0 then
        dx = -dx
        step_a = -step_a
        offset_x = 1 - offset_x
    end
    -- Zero offset means we're on a grid line, so we're actually a full cell
    -- away from the next grid line
    if offset_x == 0 then
        offset_x = 1
    end
    local step_b = 1
    local offset_y = 1 - (y / self.blocksize - b)
    if dy < 0 then
        dy = -dy
        step_b = -step_b
        offset_y = 1 - offset_y
    end
    if offset_y == 0 then
        offset_y = 1
    end

    local err = dy * offset_x - dx * offset_y

    local results = {}
    local min_a, min_b = self:to_block_units(self.min_x, self.min_y)
    local max_a, max_b = self:to_block_units(self.max_x, self.max_y)
    if dx > dy then
        -- Main axis is x/a
        while min_a <= a and a <= max_a and min_b <= b and b <= max_b do
            table.insert(results, {a, b})

            if err > 0 then
                err = err - dx
                b = b + step_b
                table.insert(results, {a, b})
            end
            err = err + dy
            a = a + step_a
        end
    else
        err = -err
        -- Main axis is y/b
        while min_a <= a and a <= max_a and min_b <= b and b <= max_b do
            table.insert(results, {a, b})

            if err > 0 then
                err = err - dy
                a = a + step_a
                table.insert(results, {a, b})
            end
            err = err + dx
            b = b + step_b
        end
    end

    return results
end

return Blockmap
