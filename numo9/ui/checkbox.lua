--[[
for when the button is just a toggle on click of some boolean flag...
--]]

local UIButton = require 'numo9.ui.button'

local UICheckbox = UIButton:subclass()

--[[
args:
	valueTable
	valueKey
--]]
function UICheckbox:init(args)
	self.valueTable = args.valueTable
	self.valueKey = args.valueKey

	UICheckbox.super.init(self, args)

	-- how to OOP do this to reduce function closures created...
	self:addEventListener('click', self.checkbox_click)
end

function UICheckbox:checkbox_click(e)
	self.valueTable[self.valueKey] = not self.valueTable[self.valueKey]
end

function UICheckbox:isset()
	return self.valueTable[self.valueKey]
end

return UICheckbox
