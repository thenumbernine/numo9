local isa=[cl,o]o.isaSet[cl]
local classmeta = {__call=[cl,...]do
	local o=setmetatable({},cl)
	return o, o?:init(...)
end}
local class
class=[...]do
	local t=table(...)
	t.super=...
	--t.supers=table{...}
	t.__index=t
	t.subclass=class
	t.isaSet=table(table{...}
		:mapi([cl]cl.isaSet)
		:unpack()
	):setmetatable(nil)
	t.isaSet[t]=true
	t.isa=isa
	setmetatable(t,classmeta)
	return t
end
