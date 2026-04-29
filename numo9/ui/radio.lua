local assert = require 'ext.assert'
local vec2d = require 'vec-ffi.vec2d'

local UIWidget = require 'numo9.ui.widget'
local UIButton = require 'numo9.ui.button'


local UIRadio = UIWidget:subclass()
UIRadio.tag = 'radio'

function UIRadio:init(args)
	UIRadio.super.init(self, args)

	self.options = assert.index(args, 'options')
	self.getSelected = assert.index(args, 'getSelected')
	self.setSelected = assert.index(args, 'setSelected')

	local x = 0
	for _,option in ipairs(self.options) do
		self:addChild(UIButton{
			owner = self.owner,
			pos = vec2d(x,0),
			text = option:sub(1,1):upper(),
			tooltip = option,
			isset = function()
				return self.getSelected() == option
			end,
			events = {
				click = function()
					self.setSelected(option)
				end,
			},
		})
		x = x + 6
	end
end

return UIRadio
