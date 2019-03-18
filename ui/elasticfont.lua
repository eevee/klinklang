-- Wraps a LÖVE Font in a slightly nicer interface, which in particular,
-- supports transparent scaling.  (With vanilla LÖVE, scaling requires keeping
-- the font path around and reloading it from scratch.)
-- TODO the one thing i'm wary of here is having two different interfaces and being unclear about which is which.
local Object = require 'klinklang.object'

local ElasticText = Object:extend{
}

function ElasticText:init(elastic_font, string)
    self.elastic_font = elastic_font
    self.string = string
    self:update_render()
end

function ElasticText:update_render()
    self.text = self.elastic_font:render(self.string)
end

function ElasticText:get_width()
    return math.ceil(self.text:getWidth() / self.elastic_font.scale)
end

-- TODO should this use the font's line offset too??  that seems slightly out of scope
function ElasticText:draw(x, y, rot, sx, sy, ...)
    local scale = self.elastic_font.scale
    love.graphics.draw(self.text, x, y, rot, (sx or 1) / scale, (sy or sx or 1) / scale, ...)
end


-- FIXME document a little, explain how to use correctly.  also note this assumes the font's proportions scale very close to linearly, since it does all its math with unscaled sizes
local ElasticFont = Object:extend{
    scale = 1,
    frozen = false,
    rendered_texts = nil,
}

-- FIXME support image fonts, which can't actually be rescaled like this whoops
-- FIXME support scaling filter...?
-- FIXME kind of awkward signature here, maybe just take a table
function ElasticFont:init(path, size, line_height, props)
    self.path = path
    self.size = size
    self.line_height = line_height or 1
    self.props = props

    local font = love.graphics.newFont(self.path, self.size)
    font:setLineHeight(self.line_height)
    self.original_font = font
    self.font = font

    self.full_height = math.ceil(font:getHeight() * self.line_height)
    self.line_offset = math.floor(font:getHeight() * (font:getLineHeight() - 1) * 0.75)

    self.rendered_texts = setmetatable({}, { __mode = 'k' })
end

-- Create an ElasticFont from a LÖVE Font.  Note that this won't actually be
-- elastic, as there's no way to resize a LÖVE font once it's been created;
-- such a font will ignore calls to set_scale, always have a scale of 1, and
-- never re-render any ElasticTexts.  Rendering it scaled up will simply scale
-- like a bitmap.  This mode exists mainly for compatibility, so the same code
-- can accept either a LÖVE Font or an ElasticFont.
-- FIXME honestly couldn't this just be a different type then?  but /much/ of the interface is the same...  i guess figure this out once you support image fonts and the default font and whatnot
function ElasticFont.from_font(class, font)
    -- FIXME ehhh
    local self = setmetatable({}, class)
    self.original_font = font
    self.font = font
    self.frozen = true
    self.line_height = font:getLineHeight()
    -- FIXME duplicated
    self.full_height = math.ceil(font:getHeight() * self.line_height)
    self.line_offset = math.floor(font:getHeight() * (font:getLineHeight() - 1) * 0.75)
    -- FIXME don't even need this really, since we can't re-render them
    self.rendered_texts = {}
    return self
end

-- Takes either an ElasticFont or a LÖVE Font, and returns an ElasticFont.  See
-- from_font for downsides.  If passed nil, this will use the current LÖVE font
-- as returned by getFont().
function ElasticFont.coerce(class, maybe_font)
    if maybe_font == nil then
        return class:from_font(love.graphics.getFont())
    elseif type(maybe_font) == 'table' then
        if maybe_font.typeOf and maybe_font:typeOf('Font') then
            return class:from_font(maybe_font)
        elseif maybe_font.isa and maybe_font:isa(class) then
            return maybe_font
        end
    end

    error(("Can't coerce '%s' into an ElasticFont"):format(maybe_font))
end

function ElasticFont:__tostring()
    return ("<ElasticFont '%s' %s>"):format(self.path, self.size)
end

-- FIXME i crash if scale is zero, which is kind of a more general problem honestly
function ElasticFont:set_scale(scale)
    if self.frozen or scale == self.scale then
        return
    end

    self.scale = scale
    if scale == 1 then
        self.font = self.original_font
    else
        self.font = love.graphics.newFont(self.path, self.size * scale)
        self.font:setLineHeight(self.line_height)
    end

    for text, _ in pairs(self.rendered_texts) do
        text:update_render()
    end
end

-- Returns the UNSCALED width of the given text.
function ElasticFont:get_width(string)
    return self.original_font:getWidth(string)
end

-- Wraps text to an UNSCALED width, a la Font:getWrap.
function ElasticFont:wrap(string, width)
    return self.original_font:getWrap(string, width)
end

-- Create an ElasticText from a string.
function ElasticFont:render_elastic(string)
    local text = ElasticText(self, string)
    self.rendered_texts[text] = true
    return text
end

-- Create a plain LÖVE Text from a string.
function ElasticFont:render(string)
    return love.graphics.newText(self.font, string)
end

return ElasticFont
