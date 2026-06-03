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
			local loc = l:match'^%-%-#include%s+(.-)$'
			if loc then
				loc = loc:match'(.-)%-%-(.*)' or loc	-- trim off comments
				loc = string.trim(loc)
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

-- deduces and stores the .metainfo metadata from this code blob
-- the first code blob has all the master metadata
-- but subsequent codeblobs can have filename metadata
function BlobCode:getMetaInfo()
	-- TODO searching a char* would be more efficient...
	local code = self:toBinStr()

	-- reload the metadata while we're here
	self.metainfo = {}
	do
		local i = 1
		repeat
			local from, to, line, term = code:find('^([^\r\n]*)(\r?\n)', i)
			if not line then break end -- I guess no single-line meta tags with no code afterwards ...
			local k, v = line:match'^%-%-%s*([^%s=]+)%s*=%s*(.-)%s*$'
			if not k then break end
--DEBUG:print('setting metainfo', k, v)
			self.metainfo[k] = v
			i = to + #term
		until false
	end
	return self.metainfo
end

return BlobCode
