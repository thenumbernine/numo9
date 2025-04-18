local table = require 'ext.table'

local CartBrowser = require 'numo9.ui':subclass()

function CartBrowser:update()
	local app = self.app
	local fs = app.fs
	-- cycle through vfs and find .n9 carts in this dir and ...
	-- ... make textures for their icons ...
	-- ... and then have buttons on :update()
	local x = 0
	local y = 0
	local fgColor = 13
	local bgColor = 0
	app:drawMenuText(fs.cwd:path(), x, y, fgColor, bgColor)
	y = y + 8
	x = x + 8
	for _,name in ipairs(table.keys(fs.cwd.chs):sort()) do
		local f = fs.cwd.chs[name]
		if f.isdir then 				-- dir
			app:drawMenuText('['..name..']', x, y, fgColor, bgColor)
		elseif name:match'%.n9$' then	-- cart file
			app:drawMenuText('*'..name, x, y, fgColor, bgColor)
		else							-- non-cart file
			app:drawMenuText(' '..name, x, y, fgColor, bgColor)
		end
		y = y + 8
	end
end

return CartBrowser
