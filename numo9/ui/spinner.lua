local assert = require 'ext.assert'
local vec2d = require 'vec-ffi.vec2d'

local UIWidget = require 'numo9.ui.widget'
local UIButton = require 'numo9.ui.button'


local UISpinner = UIWidget:subclass()

function UISpinner:init(args)
	UISpinner.super.init(self, args)

	local setValue = assert.index(args, 'setValue')

	self:addChild(UIButton{
		owner = args.owner,
		text = '<',
		pos = vec2d(0, 0),
		events = {
			click = function()
				setValue(-1)
			end,
		},
	})

	local fontWidth = 5
	local spacing = 1

	self:addChild(UIButton{
		owner = args.owner,
		text = '>',
		pos = vec2d(fontWidth + spacing, 0),
		events = {
			click = function()
				setValue(1)
			end,
		},
	})
end

function UISpinner:update()
	UIButton.super.update(self)

	self.size:set(0,0)
	self.ssbbox:empty()
	for _,ch in ipairs(self.children) do
		self.ssbbox:stretch(ch.ssbbox)
		self.size.x = math.max(self.size.x, ch.pos.x + ch.size.x)
		self.size.y = math.max(self.size.y, ch.pos.y + ch.size.y)
	end
end

return UISpinner
