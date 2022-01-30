local Object = require 'klinklang.object'

local Edges = Object:extend{}

function Edges:init(...)
    local n = select('#', ...)
    if n == 0 then
        self.top = 0
        self.bottom = 0
        self.left = 0
        self.right = 0
    elseif n == 1 then
        local a = ...
        self.top = a
        self.bottom = a
        self.left = a
        self.right = a
    elseif n == 2 then
        local y, x = ...
        self.top = y
        self.bottom = y
        self.left = x
        self.right = x
    elseif n == 3 then
        local t, x, b = ...
        self.top = t
        self.bottom = b
        self.left = x
        self.right = x
    else
        self.top, self.right, self.bottom, self.left = ...
    end
end

function Edges:horiz()
    return self.left + self.right
end

function Edges:vert()
    return self.top + self.bottom
end

return Edges
