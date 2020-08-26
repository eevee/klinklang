--[[
Argh!  The dreaded util module.  You know what to expect.
]]
local ffi = require 'ffi'

local Vector = require 'klinklang.vendor.hump.vector'
local json = require 'klinklang.vendor.dkjson'

local Object = require 'klinklang.object'

-- I hate silent errors
local function strict_json_decode(str)
    local obj, pos, err = json.decode(str)
    if err then
        error(err)
    else
        return obj
    end
end


ffi.cdef[[
int isatty(int);
]]

local function warn(...)
    local chunks = {}
    if package.config:sub(1, 1) == '/' and ffi.C.isatty(2) then
        -- Quick and dirty way to check whether we're on a Unix (that's the
        -- path separator, which would be \ on Windows), which strongly implies
        -- stdout (if it's a terminal) understands ansi color codes
        table.insert(chunks, "\x1b[33;1mwarning:\x1b[0m ")
    else
        table.insert(chunks, "warning: ")
    end

    for i, chunk in ipairs{...} do
        if i > 1 then
            table.insert(chunks, " ")
        end
        table.insert(chunks, tostring(chunk))
    end
    table.insert(chunks, "\n")

    io.stderr:write(unpack(chunks))
end


--------------------------------------------------------------------------------
-- Conspicuous mathematical omissions

local function sign(n)
    if n == 0 then
        return 0
    elseif n == math.abs(n) then
        return 1
    else
        return -1
    end
end

local function clamp(n, min, max)
    if n < min then
        return min
    elseif n > max then
        return max
    else
        return n
    end
end

local function divmod(n, b)
    return math.floor(n / b), n % b
end

-- Like divmod, but 1-based rather than zero-based.  For example, divmod1(24,
-- 12) would return (2, 12), because the 24th hour is actually the 12th in the
-- second set of 12.
local function divmod1(n, b)
    return math.floor((n - 1) / b) + 1, (n - 1) % b + 1
end

local function random_float(a, b)
    return a + love.math.random() * (b - a)
end

local function lerp(t, a, b)
    return (1 - t) * a + t * b
end


--------------------------------------------------------------------------------
-- LÖVE-specific helpers

-- Returns true if any of alt, ctrl, or super are held.  Useful as a very rough
-- heuristic for whether a keypress is intended as a global shortcut.
local function any_modifier_keys()
    return love.keyboard.isDown('lalt', 'ralt', 'lctrl', 'rctrl', 'lgui', 'rgui')
end

-- Find files recursively
local function _find_files_impl(stack)
    while true do
        local row
        while true do
            row = stack[#stack]
            if row == nil then
                -- Done!
                return
            end
            row.cursor = row.cursor or 1
            if row.cursor > #row then
                stack[#stack] = nil
            else
                break
            end
        end

        local fn = row[row.cursor]
        local path = fn
        if row.base then
            path = row.base .. '/' .. path
        end
        row.cursor = row.cursor + 1

        -- Ignore dot files
        if not fn:match("^%.") then
            local info = love.filesystem.getInfo(path)
            if not info then
                -- Probably the root didn't exist
            elseif info.type == 'file' then
                if not stack.pattern or fn:match(stack.pattern) then
                    return path, fn
                end
            elseif info.type == 'directory' then
                if stack.recurse ~= false then
                    local new_row = love.filesystem.getDirectoryItems(path)
                    new_row.base = path
                    new_row.cursor = 1
                    table.insert(stack, new_row)
                end
            end
        end
    end
end

local function find_files(args)
    return _find_files_impl, {args, pattern = args.pattern, recurse = args.recurse, n = 1}
end

-- Thin wrapper around love.filesystem.read that aborts immediately if the file
-- can't be read for any reason.
local function strict_read_file(path)
    local blob, err = love.filesystem.read(path)
    if blob == nil then
        error(err)
    end
    return blob
end


return {
    strict_json_decode = strict_json_decode,
    warn = warn,

    sign = sign,
    clamp = clamp,
    divmod = divmod,
    divmod1 = divmod1,
    lerp = lerp,
    random_float = random_float,

    any_modifier_keys = any_modifier_keys,
    find_files = find_files,
    strict_read_file = strict_read_file,
}
