--[[
code editor
--]]
local ffi = require 'ffi'
local table = require 'ext.table'

local UITextArea = require 'numo9.ui.textarea'
local UIButton = require 'numo9.ui.button'
local UIBlobSelect = require 'numo9.ui.blobselect'

local numo9_rom = require 'numo9.rom'
local clipMax = numo9_rom.clipMax

local EditCode = require 'numo9.ui':subclass()	-- the UI/editor page
EditCode.blobType = 'code'
EditCode.blobIndexField = 'codeBlobIndex'
EditCode.blobField = 'currentCodeBlob'

function EditCode:init(args)
	EditCode.super.init(self, args)

	self[self.blobIndexField] = 0

	-- TODO turn this into a widget...
	self.uiTextArea = UITextArea{
		edit = self,
	}

	-- TODO make EditCode a widget
	self.children = table()
	self.childrenInOrder = table()

	self.children:insert(UIButton{
		owner = self,
		text = 'N',
		pos = {120, 0},
		tooltip = 'line numbers',
		-- ok `isset` makes it more like a checkbox I admit...
		isset = function()
			return self.uiTextArea.useLineNumbers
		end,
		events = {
			click = function()
				self.uiTextArea.useLineNumbers = not self.uiTextArea.useLineNumbers
			end,
		},
	})

	self.children:insert(UIBlobSelect{
		owner = self,
		pos = {80, 0},
		blobName = self.blobType,
		valueTable = self,
		valueKey = self.blobIndexField,
	})

	self:onCartLoad()
end

-- external, called by app upon openCart
function EditCode:onCartLoad()
	self:setBlobIndex(0)
	self.uiTextArea:refreshText()
end

-- called internally, upon init or when the user changes the current code blob
-- updates the text field to the blob associated with .blobType, .blobField, .blobIndexField
function EditCode:setBlobIndex(i)
	self[self.blobIndexField] = i
	self[self.blobField] = self.app.blobs[self.blobType][self[self.blobIndexField]+1]

	-- update textarea underlying vec as well ...
	self.uiTextArea.vec = self[self.blobField].vec
end

function EditCode:update()
	EditCode.super.update(self)

	-- ui controls

	self:setBlobIndex(self[self.blobIndexField])


	-- for the text editor, align to the left
	-- TODO this isnt needed if I just make the text editor rect customizable
	-- [[ same as matMenuReset but without the translate
	local app = self.app
	local ar = app.ram.screenWidth / app.ram.screenHeight
	app:matident(0)
	app:matident(1)
	app:matident(2)
	app:matortho(0, app.ram.screenWidth, app.ram.screenHeight, 0)
	app:matscale(app.width / app.menuSizeInSprites.x, app.height / app.menuSizeInSprites.y)
	--]]

	self.uiTextArea:update()

	-- [[ here and numo9/edit/sheet
	app:matMenuReset()

	for i,ch in ipairs(self.children) do
		self.childrenInOrder[i] = ch
	end
	for i=#self.children+1,#self.childrenInOrder do
		self.childrenInOrder[i] = nil
	end
	self.childrenInOrder:sort(function(a,b)
		return a.zIndex > b.zIndex
	end)
	-- ui draw:
	app:setClipRect(0, 0, clipMax, clipMax)
	for _,ch in ipairs(self.childrenInOrder) do
		ch:drawRecurse()
	end
	app:setClipRect(0, 0, clipMax, clipMax)

	for _,ch in ipairs(self.childrenInOrder) do
		ch:update()
	end

	self:drawTooltip()
	--]]
end

function EditCode:event(e)
	-- don't call super, which handles arrows to change tab focus
	-- TODO do handle it somehow
	-- also TODO - handle key input of editor through :event() here instead of through :update()

	-- ui events:
	for _,ch in ipairs(self.children) do
		if ch:event(e) then return true end
	end
end

return EditCode
