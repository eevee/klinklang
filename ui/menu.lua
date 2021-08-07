-- FIXME this would be pretty handy if it were finished and fleshed out!
local Vector = require 'klinklang.vendor.hump.vector'

local AABB = require 'klinklang.aabb'
local Object = require 'klinklang.object'
local Edges = require 'klinklang.ui.edges'
local ElasticFont = require 'klinklang.ui.elasticfont'

local Menu = Object:extend{}

function Menu:init(args)
    self.anchorx = math.floor(args.x)
    self.anchory = math.floor(args.y)
    self.xalign = args.xalign or 'center'
    self.yalign = args.yalign or 'top'
    self.margin = args.margin or 0
    self.marginx = args.marginx or self.margin
    self.marginy = args.marginy or self.margin
    self.minimum_size = args.minimum_size or Vector()
    self.maximum_size = args.maximum_size or Vector(
        game.size.x - self.marginx * 2, game.size.y - self.marginy * 2)
    if not args.itempadding then
        self.itempadding = Edges()
    elseif type(args.itempadding) == 'number' then
        self.itempadding = Edges(args.itempadding)
    else
        self.itempadding = args.itempadding
    end
    self.bgcolor = args.bgcolor or nil
    self.background = args.background or nil
    self.shadow = args.shadow or 2
    self.shadowcolor = args.shadowcolor or nil
    self.textcolor = args.textcolor or {1, 1, 1}
    self.selectedcolor = args.selectedcolor or self.textcolor
    self.selectedbgcolor = args.selectedbgcolor or nil
    self.selectedradius = args.selectedradius or 0
    if args.cursor_sprite then
        self.cursor_sprite = game.sprites['menu cursor']:instantiate()
        self.cursor_width = self.cursor_sprite:getDimensions()
    else
        self.cursor_sprite = nil
        self.cursor_width = 0
    end

    self.default_prerender = args.default_prerender or self.prerender_item
    self.default_draw = args.default_draw or self.draw_item
    self.default_hover = args.default_hover or self.hover_item
    self.default_action = args.default_action or function() error("No action configured") end

    self.font = ElasticFont:coerce(args.font)
    self.cursor_indent = args.cursor_indent or 0

    self.items = {}
    -- Prerender each item; they should be as wide as they need to be, but no wider than
    -- self.maximum_size.x.  They should also assign their own .inner_width and .inner_height, based
    -- on the rendering width they used.  Note that "inner" sizes DO NOT include an item's padding
    -- or the menu's margin.
    self.inner_width = math.max(0, self.minimum_size.x - self.marginx * 2)
    self.inner_height = 0
    for i, item in ipairs(args) do
        self.items[i] = item
        ;(item.prerender or self.default_prerender)(self, item)
        self.inner_width = math.max(self.inner_width, item.inner_width + self.itempadding:horiz())
        self.inner_height = self.inner_height + item.inner_height + self.itempadding:vert()
    end
    self.inner_width = self.inner_width + self.cursor_indent
    self.inner_height = math.max(self.inner_height, self.minimum_size.y)

    self.cursor = 1
    self:_hover()
end

function Menu:update(dt)
    if self.cursor_sprite then
        self.cursor_sprite:update(dt)
    end
end

-- TODO would these args make more sense as constructor args, or
function Menu:draw(args)
    local w, h = love.graphics.getDimensions()
    local mw = self.inner_width + self.marginx * 2 + self.cursor_width
    local mh = self.inner_height + self.marginy * 2
    local x = self.anchorx
    if self.xalign == 'center' then
        x = x - math.ceil(mw / 2)
    elseif self.xalign == 'right' then
        x = x - mw
    end
    local y = self.anchory
    if self.yalign == 'middle' then
        y = y - math.ceil(mh / 2)
    elseif self.yalign == 'bottom' then
        y = y - mh
    end

    love.graphics.push('all')

    if self.background then
        self.background:fill(AABB(x, y, mw, mh))
    elseif self.bgcolor then
        love.graphics.setColor(self.bgcolor)
        love.graphics.rectangle('fill', x, y, mw, mh)
    end

    x = x + self.marginx + self.cursor_width
    y = y + self.marginy + self.font.line_offset
    for i, item in ipairs(self.items) do
        (item.draw or self.default_draw)(self, item, x, y, i == self.cursor)
        y = y + item.inner_height + self.itempadding:vert()
    end
    love.graphics.pop()
end

-- Default item handling; assumes text under the 'label' key and a function under 'action'

function Menu:prerender_item(item)
    -- FIXME wrapping support?  would require this to be different
    item.text = self.font:render_elastic(item.label)
    item.inner_width = self.font:get_width(item.label)
    item.inner_height = self.font.full_height
end

function Menu:draw_item(item, x, y, selected)
    local inner_x = x + self.itempadding.left
    if selected then
        inner_x = inner_x + self.cursor_indent
    end
    local inner_y = y + self.itempadding.top
    local h = item.inner_height + self.itempadding:vert()

    if selected and self.selectedbgcolor then
        love.graphics.setColor(self.selectedbgcolor)
        love.graphics.rectangle('fill', x, y, self.inner_width, h, self.selectedradius, self.selectedradius, 4)
    end

    if self.shadowcolor then
        love.graphics.setColor(self.shadowcolor)
        item.text:draw(inner_x, inner_y + self.shadow)
    end
    if selected then
        love.graphics.setColor(self.selectedcolor)
    else
        love.graphics.setColor(self.textcolor)
    end
    item.text:draw(inner_x, inner_y)

    if selected then
        love.graphics.setColor(1, 1, 1)
        if self.cursor_sprite then
            self.cursor_sprite:draw_at(Vector(inner_x - self.cursor_width, inner_y + h / 2 - self.font.line_offset))
        end
    end
end

function Menu:hover_item(item)
    -- Do nothing
end


-- API

function Menu:_hover()
    local item = self.items[self.cursor]
    ;(item.hover or self.default_hover)(self, item)
end

function Menu:up()
    local prev = self.cursor

    self.cursor = self.cursor - 1
    if self.cursor <= 0 then
        self.cursor = #self.items
    end

    if prev ~= self.cursor then
        self:_hover()
    end
end

function Menu:down()
    local prev = self.cursor

    self.cursor = self.cursor + 1
    if self.cursor > #self.items then
        self.cursor = 1
    end

    if prev ~= self.cursor then
        self:_hover()
    end
end

function Menu:accept()
    local item = self.items[self.cursor]
    ;(item.action or self.default_action)(self, item)
end


return Menu
