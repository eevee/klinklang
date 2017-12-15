local Object = require 'klinklang.object'


local AABB = Object:extend{}

function AABB:init(x, y, width, height)
    self.x = x
    self.y = y
    self.width = width
    self.height = height
end

function AABB.from_screen(class)
    return class(0, 0, love.graphics.getDimensions())
end

function AABB.from_drawable(class, drawable)
    return class(0, 0, drawable:getDimensions())
end

function AABB:__tostring()
    return ("<AABB (%f, %f) %f x %f>"):format(self.x, self.y, self.width, self.height)
end

function AABB:with_margin(dx, dy)
    return AABB(self.x + dx, self.y + dy, self.width - dx * 2, self.height - dy * 2)
end

-- Returns x0, y0, x1, y1
function AABB:bounds()
    return self.x, self.y, self.x + self.width, self.y + self.height
end

-- TODO hm this could be done by setting y0 = y1 - new_height
function AABB:get_chunk(dx, dy)
    local x, y, width, height = self:unpack()
    if dx > 0 then
        width = dx
    elseif dx < 0 then
        x = x + width + dx
        width = -dx
    end
    if dy > 0 then
        height = dy
    elseif dy < 0 then
        y = y + height + dy
        height = -dy
    end
    return AABB(x, y, width, height)
end

function AABB:unpack()
    return self.x, self.y, self.width, self.height
end


return AABB
