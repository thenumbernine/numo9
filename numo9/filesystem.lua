local path = require 'ext.path'
local table = require 'ext.table'
local class = require 'ext.class'
local string = require 'ext.string'
local asserttype = require 'ext.assert'.type
local assertindex = require 'ext.assert'.index


local File = class()

function File:init(args)
	self.fs = assertindex(args, 'fs')
	self.name = asserttype(assertindex(args, 'name'), 'string')
	assert(self.name ~= '.' and self.name ~= '..', "you picked a bad name")
	-- dirs and data aren't exclusive in my filesystem...
	self.isdir = args.isdir
	self.data = args.data
	self.chs = {}	-- everyone gets a chs[..] = parent
	self.chs['.'] = self
	if args.root then
		self.chs['..'] = self
	else
		self.chs['..'] = assertindex(args, 'parent')
	end
end

function File:add(node, overwrite)
	assert(self.isdir)
	-- TODO assert only 'file' nodes get children ... but meh why bother
	if self.chs[node.name] and not overwrite then
		return nil, 'already exists'
	end
	self.chs[node.name] = node
	node.chs['..'] = self
end

function File:path()
	local fs = self.fs
	local s = self.name
	local n = self.chs['..']
	while n ~= fs.root do
		s = n.name..'/'..s
	end
	return '/'..s
end

local FileSystem = class()

function FileSystem:init(args)
	self.app = assert(args.app)
	local root = File{
		fs = self,
		name = '',
		isdir = true,
		root = true,
	}
	self.root = root
	self.cwd = root
	root.parent = root
end

function FileSystem:ls()
	local app = self.app
	for name,f in pairs(self.cwd.chs) do
		if f.isdir then name = '['..name..']' end
		app.con:print('  '..name)
	end
	app.con:print()
end

function FileSystem:get(pathToFile)
	local parts = string.split(pathToFile, '/')
	local f = self.cwd
	if parts[1] == '' then	-- initial / ...
		f = self.root
		parts:remove(1)
	end
	for _,part in ipairs(parts) do
		local nextd = self.cwd.chs[part]
		if not nextd then
			return nil, tostring(part).." not found"
		end
		f = nextd
	end
	return f
end

function FileSystem:create(pathToFile, typeIsDir)
	asserttype(pathToFile, 'string')
--DEBUG:print('pathToFile', pathToFile)
	local parts = string.split(pathToFile, '/')
--DEBUG:print('parts', require 'ext.tolua'(parts))
	local name = parts:remove()
	local dir, msg = self:get(parts:concat'/')
	if not dir.isdir then return nil, tostring(pathToFile)..' no such dir' end
--DEBUG:print('at', dir:path(), 'adding', name)
	return self:add({
		isdir = not not typeIsDir or nil,
		name = name,
		parent = dir,
	}, true)
end

function FileSystem:cd(dir)
	local app = self.app
	-- should `cd` alone print cwd or goto root?
	-- tic80's logic is that the prompt shows cwd already - sounds good
	if not dir then
		self.cwd = self.root
		return
	end
	local f, msg = self:get(dir)
	if not f then return nil, msg end
	if not f.isdir then return nil, dir.." is not a dir" end
	self.cwd = f
end

function FileSystem:mkdir(name)
--DEBUG:print('mkdir', name)
	local app = self.app
	local f, msg = self:create(name, true)
	if not f then return nil, msg end
end

-- args forwarded to File ctor
--  except that .fs and .parent are added
function FileSystem:add(args, ...)
	args.fs = self
	args.parent = args.parent or self.cwd
	local f = File(args)
	self.cwd:add(f, ...)
	return f
end

-- TODO specify src path, maybe dest path too idk
function FileSystem:addFromHost(fn, ...)
	local d, msg = path(fn):read()
	if not d then return nil, msg end
	local f, msg = self:create(fn)
	if not f then return nil, msg end
	f.data = d
	return f
end

return FileSystem
