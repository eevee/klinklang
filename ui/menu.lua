-- FIXME this would be pretty handy if it were finished and fleshed out!
local Vector = require 'klinklang.vendor.hump.vector'

local AABB = require 'klinklang.aabb'
local Object = require 'klinklang.object'
local ElasticFont = require 'klinklang.ui.elasticfont'

local Menu = Object:extend{}

function Menu:init(choices)
    self.choices = choices
    self.cursor = 1
    self.cursor_sprite = game.sprites['menu cursor']:instantiate()

    self.font = ElasticFont:coerce(choices.font)
    self.cursor_indent = choices.cursor_indent or 0

    self.width = 0
    self.height = 0
    for _, choice in ipairs(self.choices) do
        choice.text = self.font:render_elastic(choice.label)
        choice.text_width = self.font:get_width(choice.label)
        -- FIXME hmm assumes one line, but there's no wrapping support here anyway
        choice.text_height = self.font.full_height
        self.width = math.max(self.width, choice.text_width)
        self.height = self.height + choice.text_height
    end

    self.width = self.width + self.cursor_indent
end

function Menu:update(dt)
    self.cursor_sprite:update(dt)
end

-- TODO would these args make more sense as constructor args, or
function Menu:draw(args)
    local anchorx = math.floor(args.x)
    local anchory = math.floor(args.y)
    local xalign = args.xalign or 'center'
    local yalign = args.yalign or 'top'
    local margin = args.margin or 0
    local marginx = args.marginx or margin
    local marginy = args.marginy or margin
    local bgcolor = args.bgcolor or nil
    local background = args.background or nil
    local shadow = args.shadow or 2
    local shadowcolor = args.shadowcolor or nil
    local textcolor = args.textcolor or {1, 1, 1}
    local selectedcolor = args.selectedcolor or textcolor

    -- FIXME hardcoded, bleh
    local cursor_width = 16

    local w, h = love.graphics.getDimensions()
    local mw = self.width + marginx * 2 + cursor_width
    local mh = self.height + marginy * 2
    local x = anchorx
    if xalign == 'center' then
        x = x - math.ceil(mw / 2)
    elseif xalign == 'right' then
        x = x - mw
    end
    local y = anchory
    if yalign == 'middle' then
        y = y - math.ceil(mh / 2)
    elseif yalign == 'bottom' then
        y = y - mh
    end

    love.graphics.push('all')

    if background then
        background:fill(AABB(x, y, mw, mh))
    elseif bgcolor then
        love.graphics.setColor(bgcolor)
        love.graphics.rectangle('fill', x, y, mw, mh)
    end

    x = x + marginx + cursor_width
    y = y + marginy + self.font.line_offset
    for i, choice in ipairs(self.choices) do
        local dx = 0
        if i == self.cursor then
            dx = self.cursor_indent
        end

        if shadowcolor then
            love.graphics.setColor(shadowcolor)
            choice.text:draw(x + dx, y + shadow)
        end
        if i == self.cursor then
            love.graphics.setColor(selectedcolor)
        else
            love.graphics.setColor(textcolor)
        end
        choice.text:draw(x + dx, y)

        local th = choice.text_height
        if i == self.cursor then
            love.graphics.setColor(1, 1, 1)
            self.cursor_sprite:draw_at(Vector(x + dx - cursor_width, y + th / 2 - self.font.line_offset))
        end
        y = y + th
    end
    love.graphics.pop()
end

-- API

function Menu:up()
    self.cursor = self.cursor - 1
    if self.cursor <= 0 then
        self.cursor = #self.choices
    end
end

function Menu:down()
    self.cursor = self.cursor + 1
    if self.cursor > #self.choices then
        self.cursor = 1
    end
end

function Menu:accept()
    self.choices[self.cursor].action()
end


return Menu
