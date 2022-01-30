-- FIXME this would be pretty handy if it were finished and fleshed out!
local Vector = require 'klinklang.vendor.hump.vector'

local AABB = require 'klinklang.aabb'
local Object = require 'klinklang.object'
local Edges = require 'klinklang.ui.edges'
local ElasticFont = require 'klinklang.ui.elasticfont'

local DEBUG_DRAW = false

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
    if not args.itemspacing then
        self.itemspacing = Vector()
    elseif type(args.itemspacing) == 'number' then
        self.itemspacing = Vector(args.itemspacing, args.itemspacing)
    else
        self.itemspacing = args.itemspacing
    end
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
        self.cursor_indent = args.cursor_indent or 0
    else
        self.cursor_sprite = nil
        self.cursor_width = 0
        self.cursor_indent = 0
    end

    -- How to arrange items:
    local raw_rows = args.rows
    local raw_columns = args.columns
    if raw_rows == 0 then
        raw_rows = nil
    end
    if raw_columns == 0 then
        raw_columns = nil
    end
    if args.order == nil then
        if raw_columns then
            -- With a column count, OR both counts, assume row layout
            self.rows_first = true
        elseif raw_rows then
            -- With only a row count, assume column layout
            self.rows_first = false
        else
            -- With nothing given at all, assume a single column
            self.rows_first = false
            raw_columns = 1
            raw_rows = #args
        end
    elseif args.order == 'rows' then
        self.rows_first = true
        if not raw_columns and not raw_rows then
            raw_rows = 1
        end
    elseif args.order == 'columns' then
        self.rows_first = false
        if not raw_columns and not raw_rows then
            raw_columns = 1
        end
    else
        error("'order' must be 'rows', 'columns', or omitted")
    end
    -- Fill in missing row or column counts.
    -- "Physical" rows/columns means how many the entire grid has.  "Visible" means how many are
    -- actually viewable at a time, taking scrolling into account.  (Only one of these should
    -- differ, at most, e.g. if the layout is rows-first, only rows can scroll!)
    -- And this is scroll position along the cross-axis, given as the first visible row/column.
    self.scroll_position = 1
    -- TODO might be nice if this could update later, though there's no mechanism for adding items
    -- TODO ahh, should this take max size into account when calculating number of columns?  but the
    -- number visible might even be different depending on where in the scroll you are...  and you
    -- may or may not want like, partial visibility of ones cut off...
    if self.rows_first then
        self.physical_columns = raw_columns
        self.visible_columns = raw_columns
        self.physical_rows = math.ceil(#args / self.physical_columns)
        self.visible_rows = raw_rows or self.physical_rows
        self.scroll_max = self.physical_rows - self.visible_rows + 1
    else
        self.physical_rows = raw_rows
        self.visible_rows = raw_rows
        self.physical_columns = math.ceil(#args / self.physical_rows)
        self.visible_columns = raw_columns or self.physical_columns
        self.scroll_max = self.physical_columns - self.visible_columns + 1
    end

    self.default_prerender = args.default_prerender or self.prerender_item
    self.default_draw = args.default_draw or self.draw_item
    self.default_hover = args.default_hover or self.hover_item
    self.default_action = args.default_action or function() error("No action configured") end
    -- Separate callbacks that are unconditionally called (first!), useful for cursor sounds
    self.on_cursor_move = args.on_cursor_move or function() end
    self.on_cursor_accept = args.on_cursor_accept or function() end

    self.font = ElasticFont:coerce(args.font)

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

function Menu:draw()
    local w, h = love.graphics.getDimensions()
    local mw = self.inner_width + self.marginx * 2 + self.cursor_width
    local mh = self.inner_height + self.marginy * 2
    local x0 = self.anchorx
    if self.xalign == 'center' then
        x0 = x0 - math.ceil(mw / 2)
    elseif self.xalign == 'right' then
        x0 = x0 - mw
    end
    local y0 = self.anchory
    if self.yalign == 'middle' then
        y0 = y0 - math.ceil(mh / 2)
    elseif self.yalign == 'bottom' then
        y0 = y0 - mh
    end

    love.graphics.push('all')

    if self.background then
        self.background:fill(AABB(x0, y0, mw, mh))
    elseif self.bgcolor then
        love.graphics.setColor(self.bgcolor)
        love.graphics.rectangle('fill', x0, y0, mw, mh)
    end

    -- FIXME take variable item height/width into account oops (also for cross-axis cursor movement???)
    -- TODO so, items can be variable /height/, then?  i may need to think about this for a dang second
    x0 = x0 + self.marginx
    y0 = y0 + self.marginy
    local x = x0 + self.cursor_width
    local y = y0  -- XXX used to do this but it sucks for non-text: + self.font.line_offset
    local i0 = 1
    if self.rows_first then
        i0 = i0 + (self.scroll_position - 1) * self.physical_columns
    else
        i0 = i0 + (self.scroll_position - 1) * self.physical_rows
    end
    for i = i0, i0 + self.visible_rows * self.visible_columns - 1 do
        local item = self.items[i]
        if item == nil then
            break
        end

        if DEBUG_DRAW then
            love.graphics.push('all')
            if i == self.cursor then
                love.graphics.setColor(1, 0.5, 0)
            else
                love.graphics.setColor(0.5, 0.5, 1)
            end
            love.graphics.rectangle('line', x + 0.5, y + 0.5, item.inner_width - 1, item.inner_height - 1)
            if self.cursor_width > 0 then
                love.graphics.rectangle('line', x - self.cursor_width + 0.5, y + 0.5, self.cursor_width - 1, item.inner_height - 1)
            end
            love.graphics.pop()
        end
        ;(item.draw or self.default_draw)(self, item, x, y, i == self.cursor)

        if self.rows_first then
            if i % self.physical_columns == 0 then
                x = x0 + self.cursor_width
                -- TODO need to know the row's height, not just the item's
                y = y + item.inner_height + self.itempadding:vert() + self.itemspacing.y
            else
                x = x + item.inner_width + self.itempadding:horiz() + self.itemspacing.x
            end
        else
            if i % self.physical_rows == 0 then
                y = y0 -- XXX + self.font.line_offset
                -- TODO need to know the column's width, not just the item's
                x = x + item.inner_width + self.itempadding:horiz() + self.itemspacing.x
            else
                y = y + item.inner_height + self.itempadding:vert() + self.itemspacing.y
            end
        end
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
            -- FIXME this, goofily, presumes the cursor's anchor is centered
            self.cursor_sprite:draw_at(Vector(
                x + self.itempadding.left - self.cursor_width / 2,
                inner_y + h / 2 - self.font.line_offset))
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
        self.on_cursor_move(self)
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
        self.on_cursor_move(self)
        self:_hover()
    end
end

function Menu:move_cursor(dx, dy)
    local cursor = self.cursor
    local overflow_behavior = 'wrap'  -- wrap, stop, off
    local overflow_x, overflow_y = 0, 0

    -- Row/column order have the same logic but with the axes switched, so write the code like this
    -- is rows-first, and transpose for column-first
    local row_ct, col_ct = self.physical_rows, self.physical_columns
    if not self.rows_first then
        row_ct, col_ct = col_ct, row_ct
        dx, dy = dy, dx
    end

    -- Move left/right, one at a time
    if dx < 0 then
        if cursor % col_ct == 1 then
            overflow_x = -1
            if overflow_behavior == 'wrap' then
                cursor = cursor + col_ct - 1
                -- If this is the last row, we might end up beyond the last item
                cursor = math.min(cursor, #self.items)
            end
        else
            cursor = cursor - 1
        end
    elseif dx > 0 then
        if cursor % col_ct == 0 then
            overflow_x = 1
            if overflow_behavior == 'wrap' then
                cursor = cursor - (col_ct - 1)
            end
        else
            cursor = cursor + 1
            -- If this is the last row, we might end up beyond the last item
            if cursor > #self.items then
                cursor = cursor - cursor % col_ct + 1
            end
        end
    end
    -- Move up/down, a chunk at a time
    if dy < 0 then
        if cursor <= col_ct then
            -- First row, move up to the bottom row
            overflow_y = -1
            if overflow_behavior == 'wrap' then
                cursor = cursor + (row_ct - 1) * col_ct
                -- If we move onto the last row, we might end up beyond the last item
                if cursor > #self.items then
                    cursor = cursor - col_ct
                    -- XXX or if you move up into an unfilled cell, should you just snap to the last item?
                    --cursor = #self.items
                end
            end
        else
            cursor = cursor - col_ct
        end
    elseif dy > 0 then
        if cursor > col_ct * (row_ct - 1) then
            -- Last row, wrap around
            -- FIXME or out of the menu...  how does that work with an unfilled second to last row
            overflow_y = 1
            if overflow_behavior == 'wrap' then
                cursor = (cursor - 1) % col_ct + 1
            end
        else
            -- Move down a row
            cursor = cursor + col_ct
            if cursor > #self.items then
                -- Tried to go down into an unfilled row, so just go to the last item
                -- XXX is this right
                cursor = #self.items
            end
        end
    end

    if not self.rows_first then
        overflow_x, overflow_y = overflow_y, overflow_x
    end
    if not (overflow_x == 0 and overflow_y == 0) and overflow_behavior == 'off' then
        -- FIXME in SpriteMenu this was cursor = nil, but we don't really support that?
        cursor = 1
    end

    self:set_cursor(cursor)
    return overflow_x, overflow_y
end

function Menu:set_cursor(cursor)
    local prev = self.cursor
    self.cursor = cursor

    -- Adjust scroll position if necessary
    local block_size, viewport
    if self.rows_first then
        block_size = self.physical_columns
        viewport = self.visible_rows
    else
        block_size = self.physical_rows
        viewport = self.visible_columns
    end
    local new_scroll = math.floor((cursor - 1) / block_size) + 1
    if new_scroll < self.scroll_position then
        self.scroll_position = new_scroll
    elseif new_scroll >= self.scroll_position + viewport then
        self.scroll_position = new_scroll - viewport + 1
    end

    if prev ~= self.cursor then
        self.on_cursor_move(self)
        self:_hover()
    end
end

function Menu:current()
    return self.items[self.cursor]
end

function Menu:accept()
    local item = self.items[self.cursor]
    self.on_cursor_accept(self, item)
    return (item.action or self.default_action)(self, item)
end


return Menu
