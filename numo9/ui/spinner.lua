local assert = require 'ext.assert'
local vec2d = require 'vec-ffi.vec2d'

local numo9_rom = require 'numo9.rom'
local spriteSize = numo9_rom.spriteSize

local UIWidget = require 'numo9.ui.widget'
local UIButton = require 'numo9.ui.button'


local UISpinner = UIWidget:subclass()

function UISpinner:init(args)
	UISpinner.super.init(self, args)

	self.setValue = assert.index(args, 'setValue')

	self.children:insert(UIButton{
		owner = args.owner,
		text = '<',
		pos = vec2d(0, 0),
		events = {
			click = function()
				self.setValue(-1)
			end,
		},
	})

	local fontWidth = 5
	local spacing = 1

	self.children:insert(UIButton{
		owner = args.owner,
		text = '>',
		pos = vec2d(fontWidth + spacing, 0),
		events = {
			click = function()
				self.setValue(1)
			end,
		},
	})
end

function UISpinner:draw()
	UIButton.super.draw(self)

	self.ssbbox:empty()
	for _,ch in ipairs(self.children) do
		self.ssbbox:stretch(ch.ssbbox)
	end
end

return UISpinner
