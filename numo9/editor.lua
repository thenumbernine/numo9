--[[
This will be the code editor
--]]
local class = require 'ext.class'

-- TODO make the editor a rom itself
-- TODO make roms that hold all the necessary stuff

local EditCode = class()

function EditCode:init(args)
	self.app = assert(args.app)
end

return EditCode
