local assert = require 'ext.assert'
local vec2d = require 'vec-ffi.vec2d'

local numo9_rom = require 'numo9.rom'
local spriteSize = numo9_rom.spriteSize

local UIWidget = require 'numo9.ui.widget'


local UIButton = UIWidget:subclass()

function UIButton:init(args)
	UIButton.super.init(self, args)

	self.text = assert.index(args, 'text')
	self.tooltip = args.tooltip

	-- function for determining whether to highlight or not
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
	if isset and self.onThisMenuItem then
		fg, bg = 0xc, 9
	elseif isset then
		fg, bg = 0xc, 8
	elseif self.onThisMenuItem then
		fg, bg = 0xd, 9
	else
		fg, bg = 0xd, 8
	end

	self.size.x = app:drawMenuText(self.text, self.pos.x, self.pos.y, fg, bg)
	self.size.y = spriteSize.y

	if self.hasFocus and self.tooltip then
		local mousePixelX, mousePixelY = app.ram.mousePos:unpack()
		local mouseX, mouseY = app:invTransform(mousePixelX, mousePixelY)
		owner:setTooltip(self.tooltip, mouseX - 12, mouseY - 12, 12, 6)
	end
end

return UIButton
