local assert = require 'ext.assert'

local numo9_rom = require 'numo9.rom'
local spriteSize = numo9_rom.spriteSize

local UIWidget = require 'numo9.ui.widget'


local UIButton = UIWidget:subclass()
UIButton.tag = 'button'

function UIButton:init(args)
	UIButton.super.init(self, args)

	assert(self.text, "UIButton expected .text")

	-- function for determining whether to highlight or not
	-- makes this into a checkbox ...
	self.isset = args.isset
end

-- draws, and calculates menuTabIndex
-- TODO separate one from the other? :update() vs :draw() ?
function UIButton:draw()
	local owner = self.owner
	local app = owner.app

	UIButton.super.draw(self)

	local isset
	if self.isset then isset = self:isset() end

	local fg, bg
	if isset and (self.isMouseOver or self.selfOrChildHasFocus) then
		fg, bg = 0xc, 9
	elseif isset then
		fg, bg = 0xc, 8
	elseif (self.isMouseOver or self.selfOrChildHasFocus) then
		fg, bg = 0xd, 9
	else
		fg, bg = 0xd, 8
	end

	self.size.x = app:drawMenuText(self.text, 0, 0, fg, bg)
	self.size.y = spriteSize.y
end

return UIButton
