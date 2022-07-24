-- Basic drawing utilities that build directly atop LÖVE primitives.

-- Create a Text object that will render text with an outline, a drop shadow, or both.
-- There are a lot of arguments so they are named.
-- 
-- text - The Text object to update.
-- font - The font to use to create a new Text, if `text` is not given.  Defaults to current font.
-- string - The text (lowercase) to contain.  Either a string, or a table of color/string pairs.
-- shadow - Offset of the drop shadow.  Defaults to 0.
-- shadowcolor - Color of the drop shadow.  Defaults to black.
-- outlinecolor - Color of the outline.  If given, the outline will be 1px wide.
-- align - Text alignment.  Defaults to left.  Ignored if `width` is not given.
-- width - Where the text will wrap.  Defaults to infinite.
local function make_outlined_text(args)
    local text
    if args.text then
        text = args.text
        text:clear()
    elseif args.font then
        text = love.graphics.newText(args.font)
    else
        text = love.graphics.newText(love.graphics.getFont())
    end

    local string = args.string
    if string == '' then
        -- avoid a segfault, whoops
        return text
    end
    local width = args.width
    local align = args.align or 'left'
    local color = args.color
    local shadow = args.shadow or 0
    local shadowcolor = args.shadowcolor or {0, 0, 0}
    local outline, outlinecolor = 0
    if args.outlinecolor then
        outline = 1
        outlinecolor = args.outlinecolor
    end

    local plain_string
    if type(string) == 'string' or type(string) == 'number' then
        plain_string = string
        if color then
            string = {color, string}
        end
    else
        local bits = {}
        for i = 1, #string do
            if i % 2 == 0 then
                bits[i / 2] = string[i]
            end
        end
        plain_string = table.concat(bits, "")
    end

    local x0 = outline
    local y0 = x0

    local draw
    if width then
        draw = function(what, x, y)
            text:addf(what, width, align, x, y)
        end
    else
        draw = function(what, x, y)
            text:add(what, x, y)
        end
    end

    if outlinecolor then
        local outline_string = {outlinecolor, plain_string}
        draw(outline_string, x0, y0 - 1)
        for dy = 0, shadow do
            draw(outline_string, x0 - 1, y0 + dy)
            draw(outline_string, x0 + 1, y0 + dy)
        end
        draw(outline_string, x0, y0 + shadow + 1)
    end

    if shadow > 0 then
        draw({shadowcolor, plain_string}, x0, y0 + shadow)
    end

    draw(string, x0, y0)

    return text
end


return {
    make_outlined_text = make_outlined_text,
}
