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

	self.size.x = self.owner.app:drawMenuText(self.text, self.pos.x, self.pos.y, fg, bg)
	self.size.y = spriteSize.y
end

--[[do return end

	local owner = self.owner
	local app = owner.app

	local lastMousePixelX, lastMousePixelY = app.ram.lastMousePos:unpack()
	local mousePixelX, mousePixelY = app.ram.mousePos:unpack()
	local mouseX, mouseY = app:invTransform(mousePixelX, mousePixelY)
	local mouseMoved = mousePixelX ~= lastMousePixelX or mousePixelY ~= lastMousePixelY
	local mouseOver = mouseX >= self.pos.x
		and mouseX < self.pos.x + self.size.x
		and mouseY >= self.pos.y 
		and mouseY < self.pos.y + self.size.y

	if mouseOver and mouseMoved then
		owner.menuTabIndex = self.menuTabIndex
	end
	if self.tooltip and mouseOver then
		owner:setTooltip(self.tooltip, mouseX - 12, mouseY - 12, 12, 6)
	end

	local didCapture
	if (mouseOver and app:keyp'mouse_left')
	or (owner.execMenuTab and onThisMenuItem)
	then
		owner.menuTabIndex = owner.menuTabCounter
		-- only clear it once its been handled
		owner.execMenuTab = false

		if self.events.click then self.events.click(self, e) end

		didCapture = true
	end

	return didCapture
end
--]]

return UIButton
