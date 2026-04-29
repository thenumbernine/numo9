local assert = require 'ext.assert'

local numo9_rom = require 'numo9.rom'
local spriteSize = numo9_rom.spriteSize

local UIWidget = require 'numo9.ui.widget'


local UILabel = UIWidget:subclass()
UILabel.tag = 'label'

function UILabel:init(args)
	UILabel.super.init(self, args)

	self.text = self.text ~= nil and tostring(self.text) or ''
end

function UILabel:draw()
	local owner = self.owner
	local app = owner.app

	UILabel.super.draw(self)

	self.size.x = app:drawMenuText(self.text, 0, 0, self.fgColorIndex, self.bgColorIndex)
	self.size.y = spriteSize.y
end

return UILabel
