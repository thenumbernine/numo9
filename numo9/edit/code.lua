--[[
code editor
--]]
local UITextArea = require 'numo9.ui.textarea'

local EditCode = require 'numo9.ui':subclass()	-- the UI/editor page
EditCode.blobType = 'code'
EditCode.blobIndexField = 'codeBlobIndex'
EditCode.blobField = 'currentCodeBlob'

function EditCode:init(args)
	EditCode.super.init(self, args)

	self[self.blobIndexField] = 0

	self.uiTextArea = UITextArea{
		edit = self,
		-- internal
		setText = function(uiTextArea, text)
			self[self.blobField].data = text
		end,
		getText = function(uiTextArea)
			return self[self.blobField].data
		end,
	}

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
end

function EditCode:update()
	EditCode.super.update(self)

	-- ui controls

	self:setBlobIndex(self[self.blobIndexField])

	if self:guiButton('N', 120, 0, self.uiTextArea.useLineNumbers) then
		self.uiTextArea.useLineNumbers = not self.uiTextArea.useLineNumbers
	end

	-- for the text editor, align to the left
	-- TODO this isnt needed if I just make the text editor rect customizable
	-- [[ same as matMenuReset but without the translate
	local app = self.app
	local ar = app.ram.screenWidth / app.ram.screenHeight
	app:matident(0)
	app:matident(1)
	app:matident(2)
	app:matortho(
		0, app.ram.screenWidth,
		app.ram.screenHeight, 0)
	--local m = math.min(app.width, app.height)
	--app:mattrans((app.width - m) * .5, (app.height - m) * .5)
	app:matscale(app.width / app.menuSizeInSprites.x, app.height / app.menuSizeInSprites.y)
	--]]

	self.uiTextArea:update()


	app:matMenuReset()

	self:drawTooltip()

	-- draw ui menubar last so it draws over the rest of the page
	self:guiBlobSelect(80, 0, self.blobType, self, self.blobIndexField)
end

function EditCode:event(e)
	-- don't call super, which handles arrows to change tab focus
	-- TODO do handle it somehow
	-- also TODO - handle key input of editor through :event() here instead of through :update()
end

return EditCode
