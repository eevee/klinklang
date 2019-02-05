--[[
Argh!  The dreaded util module.  You know what to expect.
]]
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

local function random_float(a, b)
    return a + math.random() * (b - a)
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


return {
    strict_json_decode = strict_json_decode,
    sign = sign,
    clamp = clamp,
    divmod = divmod,
    random_float = random_float,
    any_modifier_keys = any_modifier_keys,
    find_files = find_files,
}
