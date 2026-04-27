local assert = require 'ext.assert'
local math = require 'ext.math'
local vec2d = require 'vec-ffi.vec2d'

local numo9_rom = require 'numo9.rom'
local spriteSize = numo9_rom.spriteSize

local numo9_blobs = require 'numo9.blobs'
local blobClassForName = numo9_blobs.blobClassForName
local minBlobPerType = numo9_blobs.minBlobPerType

local UIWidget = require 'numo9.ui.widget'
local UITextField = require 'numo9.ui.textfield'
local UISpinner = require 'numo9.ui.spinner'
local UIButton = require 'numo9.ui.button'


local UIBlobSelect = UIWidget:subclass()

function UIBlobSelect:init(args)
	UIBlobSelect.super.init(self, args)
	
	local app = self.owner.app
	
	local blobName = assert.index(args, 'blobName')

	self.size.y = spriteSize.y
	self.overflow = 'hidden'

	local valueTable = assert.index(args, 'valueTable')
	self.valueTable = valueTable
	local valueKey = assert.index(args, 'valueKey')
	self.popupOpen = false

	local setValue = args.setValue	-- setter on blob index change
	local generator = args.generator or function()
		return blobClassForName[blobName]()
	end

	local function doSetValue(newValue)
		if not newValue then return end
		local blobsOfType = app.blobs[blobName]
		newValue = math.clamp(newValue, 0, #blobsOfType-1)
		self.valueTable[valueKey] = newValue
		if setValue then setValue(newValue) end
	end

	self.textfield = UITextField{
		owner = self.owner,
		pos = vec2d(0, 0),
		width = 12,
		-- TODO update when the value key changes
		value = tostring(self.valueTable[valueKey]),
		tooltip = blobName,
		events = {
			focus = function(target, e)
				target.value = tostring(self.valueTable[valueKey])
			end,
			change = function(target, e)
				doSetValue(tonumber(target.value))
			end,
		},
	}
	self:addChild(self.textfield)

	self.spinner = UISpinner{
		owner = self.owner,
		pos = vec2d(2, 10),
		setValue = function(dx)
			doSetValue(valueTable[valueKey] + dx)
		end,
	}
	self:addChild(self.spinner)

	self.addButton = UIButton{
		owner = self.owner,
		pos = vec2d(14, 10),
		text = '+',
		events = {
			click = function(target, e)

				local blobsOfType = app.blobs[blobName]
				self.valueTable[valueKey] = math.clamp(self.valueTable[valueKey], 0, #blobsOfType-1)
				if #blobsOfType == 0 then
					blobsOfType:insert(generator())
					self.valueTable[valueKey] = 0
				else
					-- insert after this 0-based blob = +2
					blobsOfType:insert(self.valueTable[valueKey]+2, generator())
					self.valueTable[valueKey] = self.valueTable[valueKey] + 1
				end

				app:updateBlobChanges()
			end,
		},
	}
	self:addChild(self.addButton)

	self.delButton = UIButton{
		owner = self.owner,
		pos = vec2d(19, 10),
		text = '-',
		isset = function()
			local blobsOfType = app.blobs[blobName]
			local len = #blobsOfType
			return len > (minBlobPerType[blobName] or 0)	-- TODO if not then grey out the - sign?
		end,
		events = {
			click = function(target, e)
				local blobsOfType = app.blobs[blobName]
				local len = #blobsOfType
				if len <= (minBlobPerType[blobName] or 0) then	-- TODO if not then grey out the - sign?
					return
				end

				self.valueTable[valueKey] = math.clamp(self.valueTable[valueKey], 0, #blobsOfType-1)
				blobsOfType:remove(self.valueTable[valueKey]+1)
				self.valueTable[valueKey] = math.clamp(self.valueTable[valueKey] - 1, 0, #blobsOfType-1)

				app:updateBlobChanges()
			end,
		},
	}
	self:addChild(self.delButton)
end

function UIBlobSelect:update(...)
	UIBlobSelect.super.update(self, ...)
	
	-- has to be done in draw so matrices are setup 
	-- (I guess, tho its storedin screen space
	--  so transforming things should always result in pixels, regardless of where it takes place...
	-- ... so long as children are set up too ...)
	self.size:set(0,0)
	self.ssbbox:empty()

	local function stretch(ch)
		self.ssbbox:stretch(ch.ssbbox)
		
		self.size.x = math.max(self.size.x, ch.pos.x + ch.size.x)
		self.size.y = math.max(self.size.y, ch.pos.y + ch.size.y)
	end

	stretch(self.textfield)
	if self.popupOpen then
		stretch(self.spinner)
		stretch(self.addButton)
		stretch(self.delButton)
	end
end

function UIBlobSelect:onMouseOver(...)
	UIBlobSelect.super.onMouseOver(self, ...)
	self.popupOpen = true
	self:updatePopup()
end
function UIBlobSelect:onMouseOut(...)
	UIBlobSelect.super.onMouseOut(self, ...)
	self.popupOpen = false
	self:updatePopup()
end

function UIBlobSelect:onFocus(...)
	UIBlobSelect.super.onFocus(self, ...)
	self.popupOpen = true
	self:updatePopup()
end
function UIBlobSelect:onBlur(...)
	UIBlobSelect.super.onBlur(self, ...)
	self.popupOpen = false
	self:updatePopup()
end

function UIBlobSelect:updatePopup()
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

	self.size.y = (self.popupOpen and 2 or 1) * spriteSize.y
	self.zIndex = self.popupOpen and 1 or 0

	-- TODO overflow:hidden
	-- clip drawing children
	-- and clip input events too
end

return UIBlobSelect
