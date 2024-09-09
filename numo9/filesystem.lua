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

function File:add(node)
	assert(self.isdir)
	-- TODO assert only 'file' nodes get children ... but meh why bother
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

function FileSystem:get(dir)
	local parts = string.split(dir, '/')
	local f = self.cwd
	if parts[1] == '' then	-- initial / ...
		f = self.root
		parts:remove(1)
	end
	for _,part in ipairs(parts) do
		local nextd = self.cwd.chs[part]
		if not nextd then
			return nil, "dir not found"
		end
		f = nextd
	end
	return f
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
	local app = self.app
	if self.cwd.chs[name] then
		app.con:print(' ... already exists')
		return
	end
	self:add{
		name = assert(name),
		isdir = true,
	}
end

-- args forwarded to File ctor
--  except that .fs and .parent are added
function FileSystem:add(args)
	args.fs = self
	args.parent = self.cwd
	local f = File(args)
	self.cwd:add(f)
	return f
end

-- TODO specify src path, maybe dest path too idk
function FileSystem:addFromHost(fn)
	local d, msg = path(fn):read()
	if not d then return nil, msg end
	return self:add{
		name = fn,
		data = d,
	}
end

return FileSystem
