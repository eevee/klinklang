local utf8 = require 'utf8'

local Object = require 'klinklang.object'
local ElasticFont = require 'klinklang.ui.elasticfont'

-- TODO wishlist:
-- - fancier text that should maybe be its own type
--   - colored text
--   - allow embedding sprites in text
--   - allow dynamic text e.g. wavy or shaky (this would be vastly easier if love let me mess with individual text offsets urgh, atm i think i'd have to just store a zillion text objects)
-- - letters fade in?
-- - can you scroll...  backwards?  or scroll up entire lines?  or whatever?  (XXX THEN I COULD MERGE MENU INTO THIS I THINK??)
-- XXX to fix:
-- - this constructor is terrible
-- - doesn't handle being resized atm, but anise game has no resizing, so...?
-- - the current approach to scrolling too-long text is incredibly bad and there should probably be at least three options available here:
--   1. current thing: wait when box is full, then add one line at a time
--   2. just keep scrolling forever uninterrupted
--   3. scroll a page at a time
--   4. blank and start scrolling the next page
--   honestly with a decent api these could all be implemented right in DialogueScene too

local TextScroller = Object:extend{
    waiting = false,  -- have we run out of space?  FIXME or something else
    finished = false,  -- have we reached the end of the text?
    clock = 0,  -- when this rolls over, show a new character
    line = 1,  -- current line being scrolled (possibly doesn't exist yet)
    byte_offset = 0,  -- in current line
}

function TextScroller:init(font, text, speed, width, height, color, shadow_color)
    self.font = ElasticFont:coerce(font)
    self.text = text
    self.speed = speed
    self.width = width
    self.height = height
    self.color = color
    self.shadow_color = shadow_color

    local line_spacing = self.font.full_height - self.font.height
    self.max_lines = math.floor((self.height + line_spacing) / self.font.full_height)
    self.y0 = math.floor((self.height + line_spacing - self.max_lines * self.font.full_height) / 2)

    local _textwidth, lines = self.font:wrap(text, self.width)
    self.phrase_lines = lines
    self.phrase_texts = {}
end

-- Feel free to replace this to do a thing per character, such as, I dunno, play a voice sound
-- FIXME this is a really stupid interface
function TextScroller:oncharacter(ch)
end

function TextScroller:first_line_offset()
    return math.max(0, #self.phrase_lines - self.max_lines)
end

function TextScroller:resume()
    self.waiting = false
end

-- Fill the available space with as much text as possible
function TextScroller:fill()
    -- TODO what if i'm waiting?
    -- Find the index of the last line that should be visible
    local lastline
    if self.line > self.max_lines then
        lastline = self.line
    else
        lastline = math.min(self.max_lines, #self.phrase_lines)
    end

    for l = self.line, lastline do
        self.phrase_texts[l] = self.font:render_elastic(self.phrase_lines[l])
    end
    self.line = lastline + 1
    self.byte_offset = 0
    self.waiting = true
    if self.line > #self.phrase_lines then
        self.finished = true
    end
end

function TextScroller:update(dt)
    if self.waiting or self.finished then
        return
    end

    self.clock = self.clock + dt * self.speed
    local need_redraw = (self.clock >= 1)
    -- Show as many new characters as necessary, based on time elapsed
    while self.clock >= 1 do
        -- Advance cursor, continuing across lines if necessary.
        -- byte_offset is used as the end of a slice, so we want it to point to
        -- the /end/ of a UTF-8 byte sequence.  To get that, we ask utf8.offset
        -- for the start of the SECOND character after the current one, then
        -- subtract a byte to get the end of the first character.  (The utf8
        -- library apparently saw this use case coming, because it will happily
        -- return one byte past the end of the string as an offset.)
        local second_char_offset = utf8.offset(self.phrase_lines[self.line], 2, self.byte_offset + 1)
        if second_char_offset then
            local char = string.sub(self.phrase_lines[self.line], self.byte_offset + 1, second_char_offset - 1)

            self.byte_offset = second_char_offset - 1

            -- Count a non-whitespace character against the timer
            if not char:match('%s') then
                self.clock = self.clock - 1
            end

            self:oncharacter(char)
        else
            -- There is no second byte, so we've hit the end of the line
            self.phrase_texts[self.line] = self.font:render_elastic(self.phrase_lines[self.line])
            self.line = self.line + 1
            self.byte_offset = 0

            if self.line == #self.phrase_lines + 1 then
                self.waiting = true
                self.finished = true
                break
            end

            -- If we just maxed out the text box, pause before continuing
            -- FIXME this will pause on /every/ extra line; is that right?  this seems not entirely deliberate
            if self.line > self.max_lines then
                self.waiting = true
                break
            end
        end
    end
    -- Re-render the visible part of the current line if the above loop
    -- made any progress.  Note that it's important to NOT do this if we
    -- haven't shown any of the current line yet, or we might shift
    -- everything up just to draw a blank line.
    if need_redraw and self.byte_offset > 0 then
        self.phrase_texts[self.line] = self.font:render_elastic(
            string.sub(self.phrase_lines[self.line], 1, self.byte_offset))
    end
end

function TextScroller:first_visible_line()
    return math.max(1, #self.phrase_texts - self.max_lines + 1)
end

function TextScroller:last_visible_line()
    return math.min(self:first_visible_line() + self.max_lines - 1, #self.phrase_texts)
end

function TextScroller:draw(x, y)
    y = y + self.y0
    -- Don't use self.line here, because it might be a line we haven't started drawing at all yet
    for i = self:first_visible_line(), self:last_visible_line() do
        local text = self.phrase_texts[i]
        -- Draw the text, twice: once for a drop shadow, then the text itself
        love.graphics.setColor(self.shadow_color)
        text:draw(x, y + 1)

        love.graphics.setColor(self.color)
        text:draw(x, y)

        y = y + self.font.full_height
    end
    love.graphics.setColor(1, 1, 1)
end

return TextScroller
