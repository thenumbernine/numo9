framebufferAddr=ramaddr'framebuffer'
persistentDataAddr=blobaddr'persist'
assert.ge(blobsize'persist', 1024)
matAddr = ramaddr'mvMat'
assert.eq(ramsize'mvMat', 16*4, "expected mvmat to be 32bit")	-- need to assert this for my peek/poke push/pop. need to peek/poke vs writing to app.ram directly so it is net-reflected.

spriteSheetAddr=blobaddr('sheet', 0)
tileSheetAddr=blobaddr('sheet', 1)
tilemapAddr=blobaddr'tilemap'
paletteAddr=blobaddr'palette'

local matstack=table()
local matpush=||do
	local t={}
	for i=0,15 do
		t[i+1] = peekl(matAddr + (i<<2))
	end
	matstack:insert(t)
end
local matpop=||do
	local t = matstack:remove(1)
	if not t then return end
	for i=0,15 do
		pokel(matAddr + (i<<2), t[i+1])
	end
end

mode(1)	-- set to 8bpp-indexed framebuffer
screenWidth=240
screenHeight=136
borderColor=0
mouseCursor=1
fontParams={[0]=0,0,0,0,0,0,0,0}
musicState={[0]=0,0,0}
ticpeek=|addr,bits|do
	bits=bits or 8
	if bits==1 then
		return (ticpeek(addr>>3)>>(addr&7))&1
	elseif bits==2 then
		return (ticpeek(addr>>2)>>((addr&3)<<1))&3
	elseif bits==4 then
		return (ticpeek(addr>>1)>>((addr&1)<<2))&0xf
	elseif bits~=8 then
		error('bits must be 1,2,4,8.  got '..tostring(bits))
	end
	if addr>=0 and addr<0x3fc0 then	-- framebuffer
		local x=addr%120
		local y=(addr-x)/120
		addr=(x<<1)|(y<<8)
		local value=peekw(framebufferAddr+addr)
		return (value&0x000f)|((value&0x0f00)>>4)
	elseif addr>=0x3fc0 and addr<0x3ff0 then
		local offset =  addr - 0x3fc0 
		local channel = offset % 3
		local index = (offset - channel) / 3
		local rgba = peekw(paletteAddr + (index << 1))
		local value = (rgba >> (5 * channel)) & 0x1f
		return (value << 3) | (value >> 2)
	elseif addr==0x3ff8 then
		return borderColor
	elseif addr==0x3ffb then
		return mouseCursor
	elseif addr>=0x4000 and addr<0x6000 then	-- tilesheet
		local x = (addr & 0x3f) << 1		-- x coord
		local yhi = (addr & 0x1fc0) << 2	-- y coord << 8
		addr = x | yhi
		local value=peekw(tileSheetAddr+addr)
		return (value&0xf)|((value&0xf00)>>4)	-- read the lo nibble from one pixel, the hi from the next
	elseif addr>=0x6000 and addr<0x8000 then	-- spritesheet
		local x = (addr & 0x3f) << 1		-- x coord
		local yhi = (addr & 0x1fc0) << 2	-- y coord << 8
		addr = x | yhi
		local value=peekw(spriteSheetAddr+addr)
		return (value&0xf)|((value&0xf00)>>4)	-- read the lo nibble from one pixel, the hi from the next
	elseif addr>=0x8000 and addr<0xff80 then	-- tilemap
		addr-=0x8000
		local x=addr%240
		local y=(addr-x)/240
		addr=(x|(y<<8))<<1
		local value=peekw(tilemapAddr+addr)
		return (value&0x0f)|((value>>1)&0xf0)
	elseif addr>=0x13ffc and addr<0x14000 then
		-- TODO what's the music state? currently playing track?
		return musicState[addr-0x13ffc]
	--[[
	elseif addr>=0x14604 and addr<0x149fc then
		font, size 1016 bytes
	--]]
	elseif addr>=0x149fc and addr<0x14a04 then
		return fontParams[addr-0x149fc]
	else
trace(('TODO peek $%x'):format(addr))
	end
end
ticpoke=|addr,value,bits|do
	bits=bits or 8
	assert.type(value,'number')
	if bits==1 then
		local by=addr>>3
		local bi=addr&7
		local fl=1<<bi
		return ticpoke(by,(ticpeek(by)&~fl)|(value<<bi))
	elseif bits==2 then
		local by=addr>>2
		local bi=(addr&3)<<2
		local fl=3<<bi
		return ticpoke(by,(ticpeek(by)&~fl)|(value<<bi))
	elseif bits==4 then
		local by=addr>>1
		local bi=(addr&1)<<4
		local fl=0xf<<bi
		return ticpoke(by,(ticpeek(by)&~fl)|(value<<bi))
	elseif bits~=8 then
		error('bits must be 1,2,4,8.  got '..tostring(bits))
	end
	if addr>=0 and addr<0x3fc0 then	-- framebuffer
		local x=addr%120
		local y=(addr-x)/120
		addr=(x<<1)|(y<<8)
		pokew(framebufferAddr+addr,(value&0xf)|((value&0xf0)<<4))
	elseif addr>=0x3fc0 and addr<0x3ff0 then
		local offset = addr - 0x3fc0
		local channel = offset % 3
		local index = (offset - channel) / 3
		local dstaddr = paletteAddr + (index << 1)
		local rgba = peekw(dstaddr)
		local shift = channel * 5
		local value5 = (value >> 3) & 0x1f
		pokew(dstaddr, (rgba & ~(0x1f << shift)) | (value5 << shift))
	elseif addr==0x3ff8 then
		borderColor = value
	elseif addr==0x3ffb then
		mouseCursor = value
	elseif addr>=0x4000 and addr<0x6000 then	-- tilesheet
		local x = (addr & 0x3f) << 1		-- x coord
		local yhi = (addr & 0x1fc0) << 2	-- y coord << 8
		addr = x | yhi
		pokew(tileSheetAddr + addr, (value&0xf)|((value&0xf0)<<4))	-- write the lo nibble to one pixel , the hi to the next
	elseif addr>=0x6000 and addr<0x8000 then	-- spritesheet
		local x = (addr & 0x3f) << 1		-- x coord
		local yhi = (addr & 0x1fc0) << 2	-- y coord << 8
		addr = x | yhi
		pokew(spriteSheetAddr + addr, (value&0xf)|((value&0xf0)<<4))	-- write the lo nibble to one pixel , the hi to the next
	elseif addr>=0x8000 and addr<0xff80 then	-- tilemap
		addr-=0x8000
		local x=addr%240
		local y=(addr-x)/240
		addr=(x|(y<<8))<<1
		pokew(tilemapAddr+addr,(value&0xf)|((value&0xf0)<<1))
	elseif addr>=0x13ffc and addr<0x14000 then
		-- TODO what's the music state? currently playing track?
		musicState[addr-0x13ffc]=value
	--[[
	elseif addr>=0x14604 and addr<0x149fc then
		font, size 1016 bytes
	--]]
	elseif addr>=0x149fc and addr<0x14a04 then
		fontParams[addr-0x149fc] = value
	else
trace(('TODO poke $%x '):format(addr)..tostring(value))
	end
end
-- default to 0 ... does tic80 really need this?
ticbit={
	band=|a,b|bit.band(a or 0, b or 0),
	bor=|a,b|bit.bor(a or 0, b or 0),
	bxor=|a,b|bit.bxor(a or 0, b or 0),
	bnot=|a|bit.bnot(a or 0),
	lshift=|a,b|bit.lshift(a or 0, b or 0),
	rshift=|a,b|bit.rshift(a or 0, b or 0),
	arshift=|a,b|bit.arshift(a or 0, b or 0),
	rol=|a,b|bit.rol(a or 0, b or 0),
	ror=|a,b|bit.ror(a or 0, b or 0),
}
ticton9btnmap={[0]=3,1,2,0,4,5,6,7}
local newG = {
	btn=|b|btn(ticton9btnmap[b&7],b>>3),
	btnp=|b,...|btnp(ticton9btnmap[b&7],b>>3,...),
	circ=|x,y,r,...|elli(x-r,y-r,(r<<1)+1,(r<<1)+1,...),
	circb=|x,y,r,...|ellib(x-r,y-r,(r<<1)+1,(r<<1)+1,...),
	clip=clip,
	cls=cls,
	elli=|x,y,a,b,c|elli(x-a,y-b,(a<<1)+1,(b<<1)+1,c),
	ellib=|x,y,a,b,c|ellib(x-a,y-b,(a<<1)+1,(b<<1)+1,c),
	exit=stop,
	fget=|i,f|do
		i=math.floor(i)
		f=math.floor(f)
		return (1&((sprFlags[i] or 0)>>f))~=0
	end,
	--font(text x y chromakey char_width char_height fixed=false scale=1 alt=false) -> width`
	font=|s,x,y,k,w,h,fixed,scale,alt|do
		if not warning_font then
			warning_font = true
			trace('TODO font')
		end
		return text(s,x,y,w*scale/8,h*scale/8)
	end,
	fset=|i,f,v|do
		i=math.floor(i)
		f=math.floor(f)
		v=math.floor(v)
		local flag=1<<f
		local mask=~flag
		if not sprFlags[i] then sprFlags[i]=0 end
		sprFlags[i]&=mask
		if v==true then
			sprFlags[i]|=flag
		elseif v==false then
		else
			error'here'
		end
	end,
	key=key,	-- TODO tic80<->numo9 mapping
	keyp=keyp,	-- "
	line=line,
	map=|tileX,tileY,tileW,tileH,screenX,screenY,colorkey,scale,remap|do
		-- https://github.com/nesbox/TIC-80/wiki/map
		tileX=tileX or 0
		tileY=tileY or 0
		tileW=tileW or 30
		tileH=tileH or 17
		screenX=screenX or 0
		screenY=screenY or 0
		if colorkey then
			if not warning_map_colorkey then
				warning_map_colorkey = true
				trace'TODO map colorkey'
			end
		end
		scale = scale or 1
		if remap then
			if not warning_map_remap then
				warning_map_remap = true
				trace'TODO map remap'
			end
			-- if my tilemap address is relocatable then I could implement this as just every single frame copying it into a temporary buffer and then rendering that
			-- or I could implement remap() myself, but it seems like it would be incredibly slow
			-- or I could just implement its functionality in-shader using a tilemap-"palette" that maps to another tilemap entry
			-- ... that'd be useful for just remapping all tiles of a certain value per-frame, but remap() supports custom functionality based on x and y as well ...
		end
		if scale ~= 1 then
			matpush()
			matscale(scale,scale,scale)
			map(tileX,tileY,tileW,tileH,screenX,screenY)
			matpop()
		else
			map(tileX,tileY,tileW,tileH,screenX,screenY)
		end
	end,
	memcpy=|dst,src,len|do
		for i=0,len-1 do
			ticpoke(dst+i,ticpeek(src+i))
		end
	end,
	memset=|dst,val,len|do
		for i=0,len-1 do
			ticpoke(dst+i,val)
		end
	end,
	mget=|x,y|mget(x,y) or 0,	-- TODO what's the default for mget?
	mset=|x,y,v|mset(x,y,v),
	music=||do
		if not warning_music then
			warning_music = true
			trace'TODO music'
		end
	end,
	peek=ticpeek,
	peek1=|i|ticpeek(i,1),
	peek2=|i|ticpeek(i,2),
	peek4=|i|ticpeek(i,4),
	pix=|x,y,c|do
		if c then
			-- TODO pget pset?
			x=math.floor(x)
			y=math.floor(y)
			if x<0 or x>=screenWidth or y<0 or y>=screenHeight then return end
			c=math.floor(c)
			poke(spriteSheetAddr+((x|(y<<8))),c)
		else
			x=math.floor(x)
			y=math.floor(y)
			return x<0 or x>=screenWidth or y<0 or y>=screenHeight and 0 or peek(spriteSheetAddr+((x|(y<<8))))
		end
	end,
	pmem=|i,v|do
		if v then
			pokel(persistentDataAddr+(i<<2),v)
		else
			return peekl(persistentDataAddr+(i<<2))
		end
	end,
	poke=ticpoke,
	poke1=|i,v|ticpoke(i,v,1),
	poke2=|i,v|ticpoke(i,v,2),
	poke4=|i,v|ticpoke(i,v,4),
	print=|s,x,y,color,fixed,scale,smallfont|do
		return text(s,x,y,scale,scale)
	end,
	rect=rect,
	rectb=rectb,
	reset=reset,
	sfx=||do
		if not warning_sfx then
			warning_sfx = true
			trace'TODO sfx'
		end
	end,
	spr=|n,x,y,colorkey,scale,flip,rotate,w,h|do
		-- https://github.com/nesbox/TIC-80/wiki/spr
		rotate = rotate or 0
		n=math.floor(n)
		local bankno=bit.rshift(n, 8)
		n&=0xff
		local nx=n&0xf
		local ny=(n>>4)&0xf
		local sheet=n>>8
		n=nx|(ny<<5)|(sheet<<10)
		w=math.floor(w or 1)
		h=math.floor(h or 1)
		local scaleX,scaleY=scale,scale
		if flipX then x+=w*scale*8 scaleX=-scale end
		if flipY then y+=h*sclae*8 scaleY=-scale end
		-- TODO here multiple bank sprites ... hmm ...
		-- how should I chop up banks myself ...
		if rotate ~= 0 then
			local spriteHalfSize = 4
			matpush()
			mattrans(x+spriteHalfSize*w,y+spriteHalfSize*h)
			matrot(math.rad(90*rotate))
			spr(n,-spriteHalfSize*w,-spriteHalfSize*h,w,h,0,-1,0,0xf,scaleX,scaleY)
			matpop()
		else
			spr(n,x,y,w,h,0,-1,0,0xf,scaleX,scaleY)
		end
	end,
	sync=|| do
		if not warning_sync then
			warning_sync=true
			trace'TODO sync'
		end
	end,
	time=|| 1000*time(),
	trace=trace,
	tri=tri,
	trib=|| do
		if not warning_trib then
			warning_trib=true
			trace'TODO trib'
		end
	end,
	textri=|x1,y1,x2,y2,x3,y3,u1,v1,u2,v2,u3,v3,use_map,transparentIndex|do
		-- https://github.com/nesbox/TIC-80/wiki/textri
		ttri3d(
			x1,y1,0,u1,v1,
			x2,y2,0,u2,v2,
			x3,y3,0,u3,v3,
			use_map and 1 or 0,
			nil,
			transparentIndex)
	end,
	ttri=|x1, y1, x2, y2, x3, y3, u1, v1, u2, v2, u3, v3, texsrc, transparentIndex, z1, z2, z3|do
		-- https://github.com/nesbox/TIC-80/wiki/ttri
		ttri3d(
			x1, y1, z1 or 0, u1, v1,
			x2, y2, z2 or 0, u2, v2,
			x3, y3, z3 or 0, u3, v3,
			texsrc,
			nil,
			transparentIndex)
	end,
	tstamp=tstamp,
	vbank=|| do
		-- https://github.com/nesbox/TIC-80/wiki/vbank
		if not warned_vbank then
			warned_vbank = true
			trace'TODO vbank'
		end
	end,

--[[
	getfenv=getfenv,
	setfenv=setfenv,
	unpack=table.unpack,
--]]
	getmetatable=getmetatable,
	setmetatable=setmetatable,
	assert=assert,
	pairs=pairs,
	ipairs=ipairs,
	type=type,
	bit=ticbit,
	math=math,				-- TODO original math
	table=table,			-- TODO original table
	string=string,			-- TODO original string
	coroutine=coroutine,	-- TODO original coroutine
	langfix={	-- needed for langfix to work
		idiv=|a,b| tonumber(langfix.idiv(a,b)),
	},

	__numo9_finished=|boot, tic, ovr, scn, bdr|do
		local _ = boot?()
		if tic then tic() end
		update=||do
			if tic then tic() end
			if ovr then ovr() end
			--if scn then scn() end
			--if bdr then bdr() end
		end
	end,
}
newG._G = newG
setfenv(1, newG)
