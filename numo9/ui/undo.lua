local table = require 'ext.table'
local class = require 'ext.class'
local math = require 'ext.math'
local getTime = require 'ext.timer'.getTime

local Undo = class()

Undo.lastPushTime = -math.huge
function Undo:init(args)
	self.get = args.get
	self.changed = args.changed
	self.buffer = table()
	self.index = 0
end

-- and a separate call for copy/paste that always inserts into here
function Undo:push()
	self.lastPushTime = getTime()
	-- erase subsequent undo stack
	for i=self.index+1,#self.buffer do
		self.buffer[i] = nil
	end
	-- add this entry and set it as the current undo location
	self.buffer:insert(self.get())
	self.index = #self.buffer
end

function Undo:pop(redo)
	-- if we are push-undo-ing from the top of the undo stack and the text doesn't match the top stack text then insert it at the top
	-- that way if the pushUndoTyping hadn't yet recorded it and we then get a 'redo' we will go back to the top
	if self.index == #self.buffer
	and self.index > 0
	and self.changed(self.buffer:last())
	then
		self:push()
	end
	self.index = math.clamp(self.index + (redo and 1 or -1), 0, #self.buffer)
	return self.buffer[self.index]
end

-- push undo
-- a separate one for typing that doesn't insert if the last insert was within a few milliseconds
Undo.undoDelayTime = 1
function Undo:pushContinuous()
	if getTime() - self.lastPushTime < self.undoDelayTime then return end
	self:push()
end

return Undo
