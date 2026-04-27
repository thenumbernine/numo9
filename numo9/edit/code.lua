--[[
code editor
--]]
local ffi = require 'ffi'
local table = require 'ext.table'

local UITextArea = require 'numo9.ui.textarea'
local UIButton = require 'numo9.ui.button'
local UIBlobSelect = require 'numo9.ui.blobselect'

local numo9_rom = require 'numo9.rom'
local spriteSize = numo9_rom.spriteSize


local EditCode = require 'numo9.ui':subclass()	-- the UI/editor page
EditCode.blobType = 'code'
EditCode.blobIndexField = 'codeBlobIndex'
EditCode.blobField = 'currentCodeBlob'

function EditCode:init(args)
	EditCode.super.init(self, args)

	self[self.blobIndexField] = 0

	-- TODO make EditCode a widget

	self:setupNewUISceneGraph()

	-- TODO offset correctly, and handle input correctly
	self.uiTextArea = UITextArea{
		owner = self,
		pos = {0, spriteSize.y},
		size = {9999, 256},
	}
	self:addChild(self.uiTextArea)

	self:addChild(UIButton{
		owner = self,
		text = 'N',
		pos = {120, 0},
		tooltip = 'line numbers',
		-- `isset` makes it more like a checkbox I admit...
		isset = function()
			return self.uiTextArea.useLineNumbers
		end,
		events = {
			click = function()
				self.uiTextArea.useLineNumbers = not self.uiTextArea.useLineNumbers
			end,
		},
	})

	self:addChild(UIBlobSelect{
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
	self:setFocusWidget(self.uiTextArea)
end

-- called internally, upon init or when the user changes the current code blob
-- updates the text field to the blob associated with .blobType, .blobField, .blobIndexField
function EditCode:setBlobIndex(i)
	self[self.blobIndexField] = i
	self[self.blobField] = self.app.blobs[self.blobType][self[self.blobIndexField]+1]

	-- update textarea underlying vec as well ...
	-- TODO more proper way would be to memcpy back and forth and keep the two buffers separate ....
	self.uiTextArea.vec = self[self.blobField].vec
end

function EditCode:update()
	EditCode.super.update(self)

	-- ui controls

	self:setBlobIndex(self[self.blobIndexField])

	self.uiTextArea.size:set(self.uiTextArea.parent.size)
	self.uiTextArea.size.y = self.uiTextArea.size.y - spriteSize.y

	-- TODO gotta do this to align children to the the immediate-mode radio-buttons for switching blob type
	-- until I switch those immediate-mode radio-buttons
	-- but to do that I have to switch all editor tabs to the new sytsem.
	for _,ch in ipairs(self.uiRoot.children) do
		if ch ~= self.uiTextArea then
			if not ch.origPosX then ch.origPosX = ch.pos.x end
			ch.pos.x = ch.origPosX - self.uiRoot.pos.x
		end
	end

	self:updateAndDrawNewUISceneGraph()
end

function EditCode:event(e)
	return self:handleEventNewUISceneGraph(e, true)
end

return EditCode
