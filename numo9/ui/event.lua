local table = require 'ext.table'
local class = require 'ext.class'

local Event = class()

Event.init = table.union

function Event:stopPropagation()
	self.stopPropagationValue = true
end

function Event:preventDefault()
	self.preventDefaultValue = true
end

return Event
