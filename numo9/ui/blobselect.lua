local assert = require 'ext.assert'

local numo9_rom = require 'numo9.rom'
local spriteSize = numo9_rom.spriteSize

local numo9_blobs = require 'numo9.blobs'
local blobClassForName = numo9_blobs.blobClassForName

local UIWidget = require 'numo9.ui.widget'
local UITextField = require 'numo9.ui.textfield'
local UISpinner = require 'numo9.ui.spinner'
local UIButton = require 'numo9.ui.button'


local UIBlobSelect = UIWidget:subclass()

function UIBlobSelect:init(args)
	local app = self.owner.app

	UIBlobSelect.super.init(self, args)
	
	local blobName = assert.index(args, 'blobName')

	self.size.y = spriteSize.y

	local valueTable = assert.index(args, 'valueTable')
	self.valueTable = valueTable
	local valueKey = assert.index(args, 'valueKey')
	self.popupKey = assert.index(args, 'popupKey')

	local setValue = assert.index(args, 'setValue')	-- setter on blob index change
	local generator = args.generator or function()
		return blobClassForName[blobName]()
	end

	local function doSetValue(newValue)
		if not newValue then return end
		local blobsOfType = app.blobs[blobName]
		newValue = math.clamp(newValue, 0, #blobsOfType-1)
		self.valueTable[self.valueKey] = newValue
		if setValue then setValue(newValue) end
	end

	self.children:insert(UITextField{
		owner = self.owner,
		pos = vec2d(0, 0),
		-- TODO update when the value key changes
		value = tostring(self.valueTable[self.valueKey]),
		events = {
			focus = function(target, e)
				target.value = tostring(self.valueTable[self.valueKey])
			end,
			change = function(target, e)
				doSetValue(tonumber(target.value))
			end,
		},
	})

	self.children:insert(UISpinner{
		owner = self.owner,
		pos = vec2d(2, 10),
		setValue = function(dx)
			doSetValue(valueTable[valueKey] + dx)
		end,
	})

	self.children:insert(UIButton{
		owner = self.owner,
		pos = vec2d(14, 10),
		text = '+',
		events = {
			click = function(target, e)

				local blobsOfType = app.blobs[blobName]
				self.valueTable[self.valueKey] = math.clamp(self.valueTable[self.valueKey], 0, #blobsOfType-1)
				if #blobsOfType == 0 then
					blobsOfType:insert(generator())
					self.valueTable[self.valueKey] = 0
				else
					-- insert after this 0-based blob = +2
					blobsOfType:insert(self.valueTable[self.valueKey]+2, generator())
					self.valueTable[self.valueKey] = self.valueTable[self.valueKey] + 1
				end

				self:updateBlobChanges()
			end,
		},
	})

	self.children:insert(UIButton{
		owner = self.owner,
		pos = vec2d(29, 10),
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

				self.valueTable[self.valueKey] = math.clamp(self.valueTable[self.valueKey], 0, #blobsOfType-1)
				blobsOfType:remove(self.valueTable[self.valueKey]+1)
				self.valueTable[self.valueKey] = math.clamp(self.valueTable[self.valueKey] - 1, 0, #blobsOfType-1)

				self:updateBlobChanges()
			end,
		},
	})
end

function UIBlobSelect:onMouseEnter(...)
	UIBlobSelect.super.onMouseEnter(self, ...)
	self:updatePopup()
end
function UIBlobSelect:onMouseLeave(...)
	UIBlobSelect.super.onMouseLeave(self, ...)
	self:updatePopup()
end

function UIBlobSelect:onFocus(...)
	UIBlobSelect.super.onFocus(self, ...)
	self:updatePopup()
end
function UIBlobSelect:onBlur(...)
	UIBlobSelect.super.onBlur(self, ...)
	self:updatePopup()
end

function UIBlobSelect:updatePopup()
	local popup = self.isHovered or self:hasFocus()
	self.valueTable[self.popupKey] = popup
	self.size.y = (popup and 2 or 1) * spriteSize.y
end

return UIBlobSelect
