--[[
code editor
--]]
local UITextArea = require 'numo9.ui.textarea'

local EditCode = require 'numo9.ui':subclass()	-- the UI/editor page

function EditCode:init(args)
	EditCode.super.init(self, args)

	self.codeBlobIndex = 0

	self.uiTextArea = UITextArea{
		edit = self,
		-- internal
		setText = function(uiTextArea, text)
			self.currentCodeBlob.data = text
		end,
		getText = function(uiTextArea)
			return self.currentCodeBlob.data
		end,
	}
	
	self:refreshText()
end

-- external, called by app upon openCart
function EditCode:refreshText()
	self:setCodeBlobIndex(0)
	self.uiTextArea:refreshText()
end

-- called internally, upon init or when the user changes the current code blob
function EditCode:setCodeBlobIndex(i)
	self.codeBlobIndex = i
	self.currentCodeBlob = self.app.blobs.code[self.codeBlobIndex+1]
end

function EditCode:update()
	EditCode.super.update(self)
	
	-- ui controls

	self:setCodeBlobIndex(self.codeBlobIndex)

	if self:guiButton('N', 120, 0, self.uiTextArea.useLineNumbers) then
		self.uiTextArea.useLineNumbers = not self.uiTextArea.useLineNumbers
	end

	self.uiTextArea:update()

	self:drawTooltip()

	-- draw ui menubar last so it draws over the rest of the page
	self:guiBlobSelect(80, 0, 'code', self, 'codeBlobIndex')
end

function EditCode:event(e)
	-- don't call super, which handles arrows to change tab focus
	-- TODO do handle it somehow
	-- also TODO - handle key input of editor through :event() here instead of through :update()
end

local function prevNewline(s, i)
	while i >= 0 do
		i = i - 1
		if s:sub(i,i) == '\n' then return i end
	end
	return 1
end

return EditCode
