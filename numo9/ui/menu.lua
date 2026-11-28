local numo9_rom = require 'numo9.rom'
local spriteSize = numo9_rom.spriteSize

local UIWidget = require 'numo9.ui.widget'

local UIMenu = UIWidget:subclass()
UIMenu.tag = 'menu'

function UIMenu:init(args)
	UIMenu.super.init(self, args)

	self.size.y = spriteSize.y
	self.overflow = 'hidden'
	self.popupOpen = false
end

function UIMenu:update(...)
	UIMenu.super.update(self, ...)

	self.size:set(0,0)
	self.ssbbox:empty()

	-- also in UIBlobSelect
	local function stretch(ch)
		self.ssbbox:stretch(ch.ssbbox)
		self.size.x = math.max(self.size.x, ch.pos.x + ch.size.x)
		self.size.y = math.max(self.size.y, ch.pos.y + ch.size.y)
	end

	-- assuming children[1] is the label...
	if self.children[1] then
		stretch(self.children[1])
	end
	if self.popupOpen then
		for i=2,#self.children do
			stretch(self.children[i])
		end
	end
end

function UIMenu:onMouseOver(...)
	UIMenu.super.onMouseOver(self, ...)
	self.popupOpen = true
	self:updatePopup()
end
function UIMenu:onMouseOut(...)
	UIMenu.super.onMouseOut(self, ...)
	self.popupOpen = false
	self:updatePopup()
end

function UIMenu:onFocus(...)
	UIMenu.super.onFocus(self, ...)
	self.popupOpen = true
	self:updatePopup()
end
function UIMenu:onBlur(...)
	UIMenu.super.onBlur(self, ...)
	self.popupOpen = false
	self:updatePopup()
end

function UIMenu:updatePopup()
	if self.popupOpen then
		if self.owner.currentPopup
		and self.owner.currentPopup ~= self
		then
			self.owner.currentPopup.popupOpen = false
			self.owner.currentPopup:updatePopup()
		end
		self.owner.currentPopup = self
	else
		if self.owner.currentPopup == self then
			self.owner.currentPopup = nil
		end
	end

	self.size.y = (self.popupOpen and #self.children or 1) * spriteSize.y
	self.zIndex = self.popupOpen and 1 or 0

	-- TODO overflow:hidden
	-- clip drawing children
	-- and clip input events too
end

return UIMenu
