local string = require 'ext.string'
local path = require 'ext.path'
local table = require 'ext.table'
local tolua = require 'ext.tolua'
local BlobDataAbs = require 'numo9.blob.dataabs'

local BlobCode = BlobDataAbs:subclass()

BlobCode.filenamePrefix = 'code'
BlobCode.filenameSuffix = '.lua'

-- static method:
function BlobCode:loadFile(filepath, basepath, blobIndex)
--DEBUG:print'loading code...'
	local code = assert(filepath:read())

	-- [[ preproc here ... replace #include's with included code ...
	-- or what's another option ... I could have my own virtual filesystem per cartridge ... and then allow 'require' functions ... and then worry about where to mount the cartridge ...
	-- that sounds like a much better idea.
	-- so here's a temp fix ...
	local includePaths = table{
		basepath,
		path'include',
	}
	local included = {}
	local function insertIncludes(s)
		return string.split(s, '\n'):mapi(function(l)
			local loc = l:match'^%-%-#include%s+(.*)$'
			if loc then
				if included[loc] then
					return '-- ALREADY INCLUDED: '..l
				end
				included[loc] = true
				for _,incpath in ipairs(includePaths) do
					local d = incpath(loc):read()
					if d then
						return table{
							'----------------------- BEGIN '..loc..'-----------------------',
							insertIncludes(d),
							'----------------------- END '..loc..'  -----------------------',
						}:concat'\n'
					end
				end
				error("couldn't find "..loc.." in include paths: "..tolua(includePaths:mapi(function(p) return p.path end)))
			else
				return l
			end
		end):concat'\n'
	end
	code = insertIncludes(code)
	--]]

	return BlobCode(code)
end

return BlobCode
