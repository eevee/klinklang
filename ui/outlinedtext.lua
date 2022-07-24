-- Small helper type that draws text with an outline to a Text, automatically rerenders it only when
-- necessary, and can draw that canvas with horizontal alignment of your choice.
-- Despite the name, this type can do both outlines and shadows (and both).
local Object = require 'klinklang.object'
local drawutil = require 'klinklang.ui.drawutil'

local OutlinedText = Object:extend{
    string = nil,
    text = nil,
}

-- TODO allow picking an outline style?
function OutlinedText:init(font, string, color, outlinecolor, shadowcolor, shadow)
    self.text = love.graphics.newText(font)
    self.font = font
    self.color = color
    self.outlinecolor = outlinecolor
    self.shadowcolor = shadowcolor
    self.shadow = shadow or (shadowcolor and 1 or 0)
    if string then
        self:set_string(string)
    end
end

function OutlinedText:_rerender()
    self.text:clear()
    local string = self.string
    drawutil.make_outlined_text{
        text = self.text,
        string = self.string,
        color = self.color,
        shadow = self.shadow,
        shadowcolor = self.shadowcolor,
        outlinecolor = self.outlinecolor,
    }
end

function OutlinedText:set_string(string)
    if string ~= self.string then
        self.string = string
        self:_rerender()
    end
end

function OutlinedText:draw(x, y, align, scale)
    if align == 'right' then
        x = x - self.text:getWidth()
    elseif align == 'center' then
        x = x - math.ceil(self.text:getWidth() / 2)
    end
    love.graphics.draw(self.text, x, y, 0, scale)
end

return OutlinedText
