local whammo_shapes = require 'klinklang.whammo.shapes'

local function tag(name, attrs)
    local parts = {name}
    for key, value in pairs(attrs) do
        table.insert(parts, key .. '="' .. tostring(value) .. '"')
    end
    return '<' .. table.concat(parts, ' ') .. ' />'
end

local function dump_map_to_svg(map, filename)
    -- TODO give this some css, show current physics state of this stuff.  also
    -- it would be nice to be able to see the passage of updates, somehow, even
    -- if only when a particular switch is passed to busted
    local parts = {}
    table.insert(parts, '<?xml version="1.0" encoding="UTF-8"?>')
    table.insert(parts, '<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">')
--<svg xmlns:xlink="http://www.w3.org/1999/xlink" version="1.1" viewBox="-800 -400 1600 800" width="100%" height="100%">
    table.insert(parts, ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="%d %d %d %d">'):format(-64, -64, map.width + 128, map.height + 128))
    table.insert(parts, '<style>path, rect { fill: #f444; }</style>')
    for shape in pairs(map.collider.shapes) do
        if shape:isa(whammo_shapes.Box) then
            table.insert(parts, tag('rect', {x = shape.x0, y = shape.y0, width = shape.width, height = shape.height}))
        elseif shape:isa(whammo_shapes.Polygon) then
            local d = {}
            for i, point in ipairs(shape.points) do
                if i == 1 then
                    table.insert(d, 'M')
                else
                    table.insert(d, 'L')
                end
                table.insert(d, tostring(point.x))
                table.insert(d, tostring(point.y))
            end
            table.insert(d, 'z')
            table.insert(parts, tag('path', {d = table.concat(d, ' ')}))
        end
    end
    table.insert(parts, tag('rect', {x1 = 0, y1 = 0, width = map.width, height = map.height, fill = 'none', stroke = '#999'}))
    table.insert(parts, '</svg>')

    local f = io.open(filename, 'w')
    f:write(table.concat(parts, '\n'))
    f:close()
end

local function dump_svg_on_error(map, f)
    local status, err = xpcall(f, debug.traceback)
    if not status then
        -- TODO catch this breaking
        pcall(dump_map_to_svg, map, 'klinklang-test-failure.svg')
        error(err)
    end
end

return {
    dump_svg_on_error = dump_svg_on_error,
    dump_map_to_svg = dump_map_to_svg,
}
