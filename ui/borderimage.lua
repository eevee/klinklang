-- Type that can draw an image with "borders", in the style of CSS image
-- borders.  The image has a rectangular region in the middle that's repeated,
-- and that implicitly defines a 3x3 grid for drawing the borders as well.
local AABB = require 'klinklang.aabb'
local Object = require 'klinklang.object'


local BorderImage = Object:extend{
    -- Path to the image, if provided
    path = nil,
    -- Image
    image = nil,
    -- AABB describing the center
    center = nil,

    -- State
    -- Margins, as defined by the center bounding box.  Note that left and top
    -- are the same as the corresponding properties on the AABB.
    margin_left = nil,
    margin_right = nil,
    margin_top = nil,
    margin_bottom = nil,
    -- These are the nine quads describing the parts of the image
    quad_tl = nil,
    quad_tr = nil,
    quad_bl = nil,
    quad_br = nil,
    quad_top = nil,
    quad_bottom = nil,
    quad_left = nil,
    quad_right = nil,
    quad_center = nil,
}


-- Takes an image (or a path to one, in which case it'll be loaded lazily) and
-- an AABB defining the center region.  If the AABB isn't provided, the entire
-- image will be the center region.  The center region MUST be nonzero.
function BorderImage:init(path_or_image, center)
    if type(path_or_image) == 'string' then
        self.path = path_or_image
    else
        self.image = path_or_image
    end

    self.center = center

    -- Everything else is done in _lazy_init
end

-- Initialize, if it hasn't been done already.  This is usually called for you.
function BorderImage:load()
    if self.margin_top then
        return
    end

    if not self.image then
        self.image = love.graphics.newImage(self.path)
    end
    if not self.center then
        self.center = AABB:from_drawable(self.image)
    end

    local w, h = self.image:getDimensions()
    local x0, x1, x2, x3 = 0, self.center.left, self.center.right, w
    local y0, y1, y2, y3 = 0, self.center.top, self.center.bottom, h

    -- TODO shrink center (or maybe just error) if it extends beyond the bounds
    -- of the image?
    self.margin_left = x1 - x0
    self.margin_right = x3 - x2
    self.margin_top = y1 - y0
    self.margin_bottom = y3 - y2

    local function quad(x_start, y_start, x_end, y_end)
        if x_start == x_end or y_start == y_end then
            return nil
        end

        return love.graphics.newQuad(
            x_start, y_start,
            x_end - x_start, y_end - y_start,
            w, h)
    end

    self.quad_tl = quad(x0, y0, x1, y1)
    self.quad_top = quad(x1, y0, x2, y1)
    self.quad_tr = quad(x2, y0, x3, y1)

    self.quad_left = quad(x0, y1, x1, y2)
    self.quad_center = quad(x1, y1, x2, y2)
    self.quad_right = quad(x2, y1, x3, y2)

    self.quad_bl = quad(x0, y2, x1, y3)
    self.quad_bottom = quad(x1, y2, x2, y3)
    self.quad_br = quad(x2, y2, x3, y3)
end

-- Draws this image such that it fills the given AABB.
-- TODO isaac's descent also scaled the box up!  how do i do that here?
-- TODO this could be done faster with a mesh and texture coordinates!!
function BorderImage:fill(box)
    self:load()

    local w, h = box.width, box.height
    local inner_w = w - self.margin_left - self.margin_right
    local inner_h = h - self.margin_top - self.margin_bottom
    -- TODO this stretches.  how do i tile instead?  would be nice as an option
    -- i guess.  also i think css border images have a third option that tiles
    -- to an integer multiple then scales the rest of the way?
    local center_scale_x = inner_w / self.center.width
    local center_scale_y = inner_h / self.center.height
    local x0 = box.left
    local x1 = box.left + self.margin_left
    local x2 = box.right - self.margin_right
    local y0 = box.top
    local y1 = box.top + self.margin_top
    local y2 = box.bottom - self.margin_bottom
    
    -- TODO what do i do if the box is smaller than the combined margins

    local function draw(quad, ...)
        if quad then
            love.graphics.draw(self.image, quad, ...)
        end
    end

    -- Draw corners
    draw(self.quad_tl, x0, y0)
    draw(self.quad_tr, x2, y0)
    draw(self.quad_bl, x0, y2)
    draw(self.quad_br, x2, y2)

    -- Draw edges
    draw(self.quad_left, x0, y1, 0, 1, center_scale_y)
    draw(self.quad_right, x2, y1, 0, 1, center_scale_y)
    draw(self.quad_top, x1, y0, 0, center_scale_x, 1)
    draw(self.quad_bottom, x1, y2, 0, center_scale_x, 1)

    -- Draw center
    draw(self.quad_center, x1, y1, 0, center_scale_x, center_scale_y)
end


return BorderImage
