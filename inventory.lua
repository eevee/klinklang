local Object = require 'klinklang.object'

local Inventory = Object:extend{}

function Inventory:init()
    self.items = {}
    self.item_order = {}
    self.cursor = nil
end

function Inventory:give(name, amount)
    if self.items[name] == nil then
        self.items[name] = amount
        table.insert(self.item_order, name)
        if self.cursor == nil then
            self.cursor = 1
        end
    else
        self.items[name] = self.items[name] + amount
    end
end

function Inventory:take(name, amount)
    local current = self.items[name] or 0
    if current < amount then
        return false
    else
        self.items[name] = current - amount
        return true
    end
end

function Inventory:count(name)
    return self.items[name] or 0
end

return Inventory
