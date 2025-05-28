-- some glue code needs this, might as well generate it dynamically here:
-- NOTICE if you ever remove ffi from the cartridge API then this will break ...
updateCounterAddr=ramaddr'updateCounter'
spriteSheetAddr=ramaddr'bank' + romaddr'spriteSheet'
tilemapAddr=ramaddr'bank' + romaddr'tilemap'
framebufferAddr=ramaddr'framebuffer'
userDataAddr=ramaddr'userData'
mode(1)	-- set to 8bpp-indexed framebuffer
p8ton9btnmap={[0]=2,0,3,1,7,5}
p8color=6
camx,camy=0,0	-- map's layers needs an optimized pathway which needs the camera / clip info ...
textx,texty=0,0
lastlinex,lastlieny=0,0
resetmat=||do
	matident()
	matscale(2,2)
end
resetmat()
p8_camera=|x,y|do
	resetmat()
	if not x then
		camx,camy=0,0
	else
		mattrans(-x,-y)
		camx,camy=x,y
	end
end
p8_clip=|x,y,w,h,rel|do
--DEBUG:assert(not rel, 'TODO')
	if not x then
		clip(0,0,255,255)
	else
		x=math.floor(x)
		y=math.floor(y)
		if x<0 then w+=x x=0 end
		if y<0 then h+=y y=0 end
		w=math.min(math.floor(w),128)
		h=math.min(math.floor(h),128)
		clip(x<<1,y<<1,(w<<1)-1,(h<<1)-1)
	end
end
p8_fillp=|p|fillp(p)	-- TODO swizzle the bits accordingly, pico8's is in order, I'm using the 4x4 Bayer dither-matrix
p8palRemap={}
p8palette={
	0x0000,
	0xa8a3,
	0xa88f,
	0xaa00,
	0x9955,
	0xa54b,
	0xe318,
	0xf7df,
	0xa41f,
	0x829f,
	0x93bf,
	0x9b80,
	0xfea5,
	0xcdd0,
	0xd5df,
	0xd73f,
}
--[[
pico8 has palette-0 for modifying sprites that are drawn
and palette-1 for modifying colors on screen already ...
so how about I ... ... I guess when I draw colors then I ...
wait is pico8 actually changing the index itself as it draws it out with palette-0?
and not just changing the associated palette values?
and only afterwards with palette-1 it does change the palette's rgb?
hmm weird.

so all these pal(from,to) commands are supposed to be visible only in what's drawn even past the pal() to reset colors.
maybe to reproduce this I should disable all resets?
nah but the changes accumulate ...
I could collect unique streams of pal(...) calls post-pal() reset. and associate each one to one of my upper-4-bit palettes ...

lol or i could manually write sprites to temp regions before drawing them ...
--]]
p8_pal=|from,to,remapping|do
	if not from then
		for i=0,15 do
			pal(i,p8palette[i+1])
		end
		if next(p8palRemap) then p8palRemap={} end
		p8PalChanged=false
	elseif type(from)=='number' then
		-- sometimes 'to' is nil ... default to zero?
		to=tonumber(to) or 0
if remapping==2 then trace"TODO pal(from,to,2)" end
		from=math.floor(from)
		to=math.floor(to)
		if from>=0 and from<16 and to>=0 and to<16 then
			if remapping==1 then
				pal(to,p8palette[from+1])
			else
				p8palRemap[from]=to
			end
		end
		p8PalChanged=true
	elseif type(from)=='table' then
		remapping=to
if remapping==2 then trace"TODO pal(map,2)" end
		for from,to in pairs(from) do
			from=math.floor(from)
			to=math.floor(to)
			if from>=0 and from<=16 and to>=0 and to<16 then
				from=bit.band(from,0xf)
				if remapping==1 then
					pal(to,p8palette[from+1])
				else
					p8palRemap[from]=to
				end
			end
		end
		p8PalChanged=true
	else
trace'pal idk'
trace(type(from),type(to),type(remapping))
trace(from,to,remapping)
		-- I think these just return?
	end
end
p8_setpalt=|c,t|do
	c=math.floor(c)
--DEBUG:assert.ge(c, 0)
--DEBUG:assert.lt(c, 16)
--DEBUG:assert.type(t,'boolean')
	if t~=false then	-- true <-> transparent <-> clear alpha
		pal(c, pal(c)&0x7fff)
	else	-- false <-> opaque <-> set alpha
		pal(c, pal(c)|0x8000)
	end
end
p8_palt=|...|do
	local n=select('#',...)
	if n<=1 then
		-- looks like pico8 is reversing the bit order so they can be read left-to-right (but ofc then you always have to provide all 16 digits ...)
		local ts=math.floor(... or 0x8000)	-- bitfield of transparencies in reverse-order
		for c=0,15 do
			p8_setpalt(15-c,ts&(1<<c)~=0)
		end
	elseif n==2 then
		p8_setpalt(...)
	end
end
p8peek=|addr,n|do
	if n then
--DEBUG:assert.le(n, 8192)
		local results = {}
		for i=1,n do
			results[i]=p8peek(addr+i-1)
		end
		return table.unpack(results)
	end
	if addr>=0 and addr<0x2000 then	-- gfx and map2
--[[
pico8 memory from 0..0x1000 is spritesheet 128x64
from 0x1000..0x2000 is shared spritesheet/tilemap 128x64
so the spritesheet gets 128x128 contiguous memory
pico8 x 0..128 = addrs 0..63 / bits 0..5 = numo9 addrs be 0..127 (bits 1..6) for me, i'm reading two peeks into its one.
pico8 y 0..128 (bits 6..12) will be 0..256 (bits 8..14) for me
--]]
		local x=(addr&0x3f)<<1
		local yhi=(addr&0x1fc0)<<2
		addr=x|yhi
		local value=peekw(spriteSheetAddr+addr)
		return (value&0xf)|((value&0xf00)>>4)
		-- TODO addr>=0x1000 and addr <0x2000 then ALSO write to the tilemapTex
--pico8 memory from $6000 to $8000 is the 4bpp screen
-- I've got 'video mode 1' which is 8bpp indexed, so I can use mine for picso ...
	elseif addr>=0x2000 and addr<0x3000 then	-- map
		addr-=0x2000
		local x=addr&0x7f
		local y=(addr>>7)&0x1f
		addr=(x<<1)|(y<<9)
		local value=peekw(tilemapAddr+addr)
		return (value&0x0f)|((value>>1)&0xf0)
	elseif addr>=0x3000 and addr<0x3100 then
		return sprFlags[addr&0xff]
	elseif addr>=0x4300 and addr<0x5600 then	-- user data
		return peek(addr-0x4300+userDataAddr)
	elseif addr>=0x6000 and addr<0x8000 then
		addr-=0x6000
		local x=(addr&0x3f)<<1		-- lo 6 bits=x coord, to be shifted << 1
		local yhi=(addr&0x1fc0)<<2	-- next 7 bits=y coord, to be shifted << 8
		addr=x|yhi
		local value=peekw(framebufferAddr+addr)
		return (value&0x000f)|((value&0x0f00)>>4)
	end
trace(('TODO peek $%x'):format(addr))
	return 0
end
p8poke=|addr,value,...|do
--DEBUG:assert.eq(select('#', ...), 0, 'TODO')
	if addr>=0 and addr<0x2000 then				-- sprites & sprite+tilemap shared
		local x=(addr&0x3f)<<1		-- x coord
		local yhi=(addr&0x1fc0)<<2	-- y coord << 8
		addr=x|yhi
		pokew(spriteSheetAddr+addr,(value&0xf)|((value&0xf0)<<4))
		if addr>=0x1000 then					-- sprite+tilemap shared
			-- shared mem, also write to the map lower
			addr-=0x1000
			local x=addr&0x7f				-- 7 bits x
			local y=((addr>>7)&0x1f)|0x20	-- 5 bits y
			addr=(x<<1)|(y<<9)
			pokew(tilemapAddr+addr,(value&0xf)|((value&0xf0)<<1))
		end
	elseif addr>=0x2000 and addr<0x3000 then	-- tilemap
		addr-=0x2000
		local x=addr&0x7f			-- 7 bits x
		local y=(addr>>7)&0x1f	-- 5 bits y
		addr=(x<<1)|(y<<9)
		pokew(tilemapAddr+addr,(value&0xf)|((value&0xf0)<<1))
	elseif addr>=0x3000 and addr<0x3100 then
		sprFlags[addr&0xff] = value
	elseif addr>=0x4300 and addr<0x5600 then	-- user data
		poke(addr-0x4300+userDataAddr,value)
	elseif addr>=0x6000 and addr<0x8000 then
		-- only valid for 8bpp-indexed video mode
		addr-=0x6000
		local x=(addr&0x3f)<<1		-- x coord
		local yhi=(addr&0x1fc0)<<2	-- y coord << 8
		addr=x|yhi
		pokew(framebufferAddr+addr,(value&0xf)|((value&0xf0)<<4))
	else
trace(('TODO poke $%x $%x'):format(addr, value))
	end
end

--[[ TODO technically ... if pico8 is fixed 32bpp ... then I should be floor(x*2^16) to both args before performing ops, then x/2^16 back afterwards.
p8bit={
	band=|a,b|bit.band(a or 0, b or 0),
	bor=|a,b|bit.bor(a or 0, b or 0),
	bxor=|a,b|bit.bxor(a or 0, b or 0),
	bnot=|a|bit.bnot(a or 0),
	shl=|a,b|bit.lshift(a or 0, b or 0),
	shr=|a,b|bit.rshift(a or 0, b or 0),
	lshr=|a,b|bit.arshift(a or 0, b or 0),
	rotl=|a,b|bit.rol(a or 0, b or 0),
	rotr=|a,b|bit.ror(a or 0, b or 0),
}
--]]
-- [[
bitfrom=|x|math.floor((x or 0)*2^16+.5)
bitto=|x|((x or 0)/2^16)	-- don't re-offset.  leave 0 at 0.
p8bit={
	band=|a,b|bitto(bit.band(bitfrom(a), bitfrom(b))),
	bor=|a,b|bitto(bit.bor(bitfrom(a), bitfrom(b))),
	bxor=|a,b|bitto(bit.bxor(bitfrom(a), bitfrom(b))),
	bnot=|a|bitto(bit.bnot(bitfrom(a))),
	shl=|a,b|bitto(bit.lshift(bitfrom(a), bitfrom(b))),
	shr=|a,b|bitto(bit.rshift(bitfrom(a), bitfrom(b))),
	lshr=|a,b|bitto(bit.arshift(bitfrom(a), bitfrom(b))),
	rotl=|a,b|bitto(bit.rol(bitfrom(a), bitfrom(b))),
	rotr=|a,b|bitto(bit.ror(bitfrom(a), bitfrom(b))),
}
--]]

setfenv(1, {
	getfenv=getfenv,	-- for code that uses _ENV...
	setfenv=setfenv,
	getmetatable=getmetatable,
	setmetatable=setmetatable,
	type=type,
	unpack=table.unpack,
	printh=trace,
	assert=assert,

	-- pico8's bit ops works dif than luajits ... nils are converted to 0s
	band=p8bit.band,
	bor=p8bit.bor,
	bxor=p8bit.bxor,
	bnot=p8bit.bnot,
	shl=p8bit.shl,
	shr=p8bit.shr,
	lshr=p8bit.lshr,
	rotl=p8bit.rotl,
	rotr=p8bit.rotr,
	bit=p8bit,

	--min=math.min,	-- some games complain about passing nils ... is that from other parse errors? or is that really pico8 functionality?
	--max=math.max,
	min=|a,b|do
		if a==nil then return b end
		if b==nil then return a end
		return math.min(a,b)
	end,
	max=|a,b|do
		if a==nil then return b end
		if b==nil then return a end
		return math.max(a,b)
	end,
	mid=|a,b,c|do
		if b<a then a,b=b,a end
		if c<b then
			b,c=c,b
			if b<a then a,b=b,a end
		end
		return b
	end,
	flr=math.floor,
	ceil=math.ceil,
	cos=|x|math.cos(x*2*math.pi),
	sin=|x|-math.sin(x*2*math.pi),
	atan2=|x,y|math.atan2(-y,x)/(2*math.pi),
	sqrt=math.sqrt,
	abs=math.abs,
	sgn=|x|x<0 and -1 or 1,
	rnd=|x|do
		if type(x)=='table' then
			return table.pickRandom(x)
		end
		return (x or 1)*math.random()
	end,
	srand=math.randomseed,
	add=table.insert,
	del=|t,v|do
		for i,u in ipairs(t) do
			if u==v then
				table.remove(t,i)
				return
			end
		end
	end,
	deli=table.remove,
	count=|t|#t,
	pairs=|t|(t==nil? (coroutine.wrap(||nil)):(pairs(t))),
	all=|t|coroutine.wrap(||do
		if not t then return end
		for _,x in ipairs(t) do
			coroutine.yield(x)
		end
	end),
	foreach=|t,f|do
		if not t then return end
		for _,o in ipairs(t) do f(o) end
	end,
	tostr=tostring,
	tonum=tonumber,
	chr=string.char,
	ord=|...|do
		if select('#', ...)==3 then
			local a,b,c=...
			return string.byte(a,b,b+c-1)
		end
		return string.byte(...)
	end,
	sub=|...|do
		local a,b,c=...
		local tc = type(c)
		if tc ~= 'nil' and tc ~= 'number' then
			return string.sub(a,b,b)
		end
		return string.sub(...)
	end,
	split=|str,sep,num|do
		if type(sep)=='number' then
			-- "When separator is a number n, the string is split into n-character groups"
			error"TODO"
		end
		local t = string.split(str, sep or ',')
		if num == nil then num=true end	-- TODO use select('#', ...) ?
		if num then
			for i=1,#t do t[i] = tonumber(t[i]) or t[i] end
		end
		return t
	end,
	yield=coroutine.yield,
	cocreate=coroutine.create,
	coresume=coroutine.resume,
	costatus=coroutine.status,

	t=time,
	time=time,

	flip=||nil,
	cls=cls,
	clip=p8_clip,
	camera=p8_camera,
	pset=|x,y,c|do
		x=math.floor(x)
		y=math.floor(y)
		if x<0 or x>=128 or y<0 or y>=128 then return end
		c=math.floor(c or p8color)
		pset(x,y,c)
	end,
	pget=|x,y|do
		x=math.floor(x)
		y=math.floor(y)
		return (x<0 or x>=128 or y<0 or y>=128) and 0 or pget(x,y)
	end,
	sset=|x,y,c|do
		x=math.floor(x)
		y=math.floor(y)
		if x<0 or x>=128 or y<0 or y >= 128 then return end
		c=math.floor(c or p8color)
		poke(spriteSheetAddr+((x|(y<<8))),c)
	end,
	sget=|x,y|do
		x=math.floor(x)
		y=math.floor(y)
		return (x<0 or x>=128 or y<0 or y>=128) and 0 or peek(spriteSheetAddr+((x|(y<<8))))
	end,
	rect=|x0,y0,x1,y1,c|rectb(x0,y0,x1-x0+1,y1-y0+1,c or p8color),
	rectfill=|x0,y0,x1,y1,c|rect(x0,y0,x1-x0+1,y1-y0+1,c or p8color),
	circ=|x,y,r,c|ellib(x-r,y-r,(r<<1)+1,(r<<1)+1,c or p8color),
	circfill=|x,y,r,c|elli(x-r,y-r,(r<<1)+1,(r<<1)+1,c or p8color),
	oval=|x0,y0,x1,y1,c|ellib(x0,y0,x1-x0+1,y1-y0+1,c or p8color),
	ovalfill=|x0,y0,x1,y1,c|elli(x0,y0,x1-x0+1,y1-y0+1,c or p8color),
	line=|...|do
		local x0,y0,col,x1,y1=lastlinex,lastliney,p8color
		local n=select('#',...)
		if n==2 then
			x1,y1=...
		elseif n==3 then
			x1,y1,col=...
			col=col or p8color
		elseif n==4 then
			x0,y0,x1,y1=...
		elseif n==5 then
			x0,y0,x1,y1,col=...
			col=col or p8color
		end
--DEBUG:assert.type(x0,'number')
--DEBUG:assert.type(y0,'number')
--DEBUG:assert.type(x1,'number')
--DEBUG:assert.type(y1,'number')
		x0=math.floor(x0)
		y0=math.floor(y0)
		x1=math.floor(x1)
		y1=math.floor(y1)
		col=math.floor(col)
		line(x0,y0,x1,y1,col)
		lastlinex,lastliney=x1,y1
	end,
	print=|...|do
		local n=select('#',...)
		local s,x,y,c
		if n==1 or n==2 then
			s,c=...
			x,y=textx,texty
		elseif n==3 or n==4 then
			s,x,y,c=...
		else
			trace'print IDK'
		end
		if not s then return 0 end
		s=tostring(s)
		if s:sub(-1)=='\0' then
			s=s:sub(1,-2)
		else
			textx=0
			texty=math.max(y+8,122)
		end
		c=c or p8color
		return text(s,x,y,c or p8color)
	end,
	pal=p8_pal,
	palt=p8_palt,
	btn=|...|do
		if select('#', ...) == 0 then
			local result=0
			for i=0,5 do
				result |= btn(p8ton9btnmap[i]) and 1<<i or 0
			end
			return result
		end
		local b,pl=...
		b=math.floor(b)
		-- TODO if pl is not player-1 (0? idk?) then return
		--if pl then pl=math.floor(pl) end
		local pb=p8ton9btnmap[b]
		if pb then return btn(pb) end
		error'here'
	end,
	btnp=|b, ...|do
		local pb=p8ton9btnmap[b]
		if not pb then return end
		return btnp(pb, ...)
	end,
	-- TODO this but in a section of RAM where I copy the sprite-flags
	-- TODO shouldn't all script variables be located in RAM
	-- TODO TODO am I turning this into an emulator?
	-- TODO TODO TODO can I implement Lua in SNES?
	fget=|...|do
		local i, f
		local n=select('#',...)
		if n==1 then
			local i=...
			i=math.floor(i)
--DEBUG:assert.ge(i,0)
--DEBUG:assert.lt(i,256)
			return sprFlags[i]
		elseif n==2 then
			local i,f=...
			i=math.floor(i)
			f=math.floor(f)
--DEBUG:assert.ge(i,0)
--DEBUG:assert.lt(i,256)
--DEBUG:assert.ge(f,0)
--DEBUG:assert.lt(f,8)
			return (1&(sprFlags[i]>>f)) ~= 0
		else
			error'here'
		end
	end,
	fset=|...|do
		local n=select('#',...)
		if n==2 then
			local i,val=...
			i=math.floor(i)
			val=math.floor(val)
--DEBUG:assert.ge(i,0)
--DEBUG:assert.lt(i,256)
--DEBUG:assert.ge(val,0)
--DEBUG:assert.lt(val,256)
			sprFlags[i]=val
		elseif n==3 then
			local i,f,val=...
			i=math.floor(i)
			f=math.floor(f)
			val=math.floor(val)
--DEBUG:assert.ge(i,0)
--DEBUG:assert.lt(i,256)
			local flag=1<<f
			local mask=~flag
			sprFlags[i]&=mask
			if val==true then
				sprFlags[i]|=flag
			elseif val == false then
			else
				error'here'
			end
		else
			error'here'
		end
	end,
	mget=|x,y|do
		x=math.floor(x)
		y=math.floor(y)
		if x<0 or y<0 or x>=128 or y>=128 then return 0 end
		local i=mget(x,y)
		return (i&0xf)|((i>>1)&0xf0)
	end,
	mset=|x,y,i|do
		x=math.floor(x)
		y=math.floor(y)
		i=math.floor(i)
		mset(x,y,(i&0xf)|((i&0xf0)<<1))
	end,
	map=|tileX,tileY,screenX,screenY,tileW,tileH,layers|do
		tileX=math.floor(tileX)
		tileY=math.floor(tileY)
		tileW=math.floor(tileW or 1)
		tileH=math.floor(tileH or 1)
		screenX=math.ceil(screenX or 0)
		screenY=math.ceil(screenY or 0)

-- [=[ this would be faster to run, but my map() routine doesn't skip tile index=0 like pico8's does
-- but wait, now that I started writing blank to tile index 0 in the converted cartridge ...
		if not layers and not p8PalChanged then
			return map(tileX,tileY,tileW,tileH,screenX,screenY,0,false,0)
		end
--]=]

		-- manually do some clipping to my tile hunting bounds
		-- this improves fps by 100x or so
		-- idk if I should bother have a typical map() call do this bounds testing because it's all handled in hardware anyways

		-- manually hunt through the tilemap,
		-- get the tile,
		-- get the sprFlags of the tile
		-- if they intersect (all? any?) then draw this sprite
		-- this drops the fps from 5000 down to 30 ... smh
		-- then I add some bounds testing and it goes back up to 3000

		local camScreenX=math.floor(screenX-camx)
		local camScreenY=math.floor(screenY-camy)

		if camScreenX+8<0 then
			local shift=(-8-camScreenX)>>3
--DEBUG:assert.ge(shift,0)
			screenX+=shift<<3
			camScreenX+=shift<<3
			tileX+=shift
			tileW-=shift
		end
		if camScreenY+8<0 then
			local shift=(-8-camScreenY)>>3
--DEBUG:assert.ge(shift,0)
			screenY+=shift<<3
			camScreenY+=shift<<3
			tileY+=shift
			tileH-=shift
		end

		if camScreenX+(tileW<<3) > 128 then
			local shift=(camScreenX+(tileW<<3) - 128)>>3
--DEBUG:assert.ge(shift,0)
			tileW-=shift
		end
		if camScreenY+(tileH<<3) > 128 then
			local shift=(camScreenY+(tileH<<3) - 128)>>3
--DEBUG:assert.ge(shift,0)
			tileH-=shift
		end

		if tileX<0 then
			local shift=-tileX
			tileX=0
			tileW-=shift
			screenX+=shift>>3
		end
		if tileY<0 then
			local shift=-tileY
			tileY=0
			tileH-=shift
			screenY-=shift>>3
		end
		if tileW<=0 or tileH<=0 then return end
		if tileW>127-tileX then tileW=127-tileX end
		if tileH>127-tileY then tileH=127-tileY end

		if camScreenX>128
		or camScreenY>128
		or camScreenX+(tileW<<3)+128 <= 0
		or camScreenY+(tileH<<3)+128 <= 0
		then
			return
		end

		local ssy=screenY
		for ty=tileY,tileY+tileH-1 do
			local ssx=screenX
			for tx=tileX,tileX+tileW-1 do
				local i=mget(tx,ty)
				if i>0 then
					i=(i&0xf)|((i>>1)&0xf0)
					if not layers
					or sprFlags[i]&layers==layers
					then
						map(tx,ty,1,1,ssx,ssy,0,false,0)
					end
				end
				ssx+=8
			end
			ssy+=8
		end
	end,
	spr=|n,x,y,w,h,flipX,flipY|do
		n=math.floor(n)
--DEBUG:assert.ge(n,0)
--DEBUG:assert.lt(n,256)
		local nx=n&0xf
		local ny=n>>4
		n=nx|(ny<<5)
		w=math.floor(w or 1)
		h=math.floor(h or 1)
		local scaleX,scaleY=1,1
		if flipX then scaleX=-1 x+=w<<3 end
		if flipY then scaleY=-1 y+=h<<3 end
		-- here, if pal() has changed anything since the last pal() reset
		-- then we're going to have to manually remap colors.
		if p8PalChanged then
			for j=0,(h<<3)-1 do
				for i=0,(w<<3)-1 do
					-- draw it to x=0,y=128 in our unused spritesheet area
					-- use hi pal=1 so we don't get any transparency changes from pal-0
					local c = peek(spriteSheetAddr + ((nx<<3) + i) + (((ny<<3) + j) << 8))
					c = (p8palRemap[c] or c) -- + 16		-- offset by 16 to use next palette over, with its alphas intact ... I'm still not sure how palette-remapping and transprency works together
					poke(spriteSheetAddr + i + ((j + 128) << 8), c)
				end
			end
			n = 0x200
		end
		spr(n,x,y,w,h,0,-1,0,0xf,scaleX,scaleY)
	end,
	sspr=|sheetX,sheetY,sheetW,sheetH,destX,destY,destW,destH,flipX,flipY|do
		destW = destW or sheetW
		destH = destH or sheetH
		if flipX then
--			destX+=sheetW	-- shouldn't be done -- causes skipping of sprites
			sheetX+=sheetW	-- I can't tell if it's wrong or not
			sheetW=-sheetW
		end
		if flipY then
--			destY+=sheetH
			sheetY+=sheetH
			sheetH=-sheetH
		end
		quad(destX,destY,destW,destH,
			sheetX/256, sheetY/256,
			sheetW/256, sheetH/256,
			0,	-- sprite sheet ... TODO eventually for pico8 glue, use only 1 sheet, no separate sprites and tiles like tic80
			0,-1,0,0xf)
	end,
	color=|c|do p8color=math.floor(c or 6) end,
	fillp=p8_fillp,

	menuitem=||trace'TODO menuitem',

	run=run,
	stop=stop,
	reset=||do
		p8_camera()
		p8_clip()
		p8_pal()
		p8_fillp(0)
	end,

	music=|n, fadeLen, mask|do
		n = tonumber(n)	-- sometimes it's passed as a string ... smh
		if n==-1 then
			music(-1)
			return
		end
		music(n+128, 4, 4)
	end,
	sfx=|n,ch,ofs,len|do
		music(n, 0, ch)	-- store pico8 waveforms as my sfx, store its sfx and music as my music
	end,

	reload=|...|do
		if select('#',...)==0 then
			reset()	-- reset entire rom->ram
		else
			local dst,src,len
trace('TODO reload', dst, src, len)
		end
	end,
	cstore=|dst,src,len|do
trace'TODO cstore'
	end,
	memcpy=|dst,src,len|do
		for i=0,len-1 do
			p8poke(dst+i,p8peek(src+i))
		end
	end,
	memset=|dst,val,len|do
		for i=0,len-1 do
			p8poke(dst+i,val)
		end
	end,
	peek=p8peek,
	poke=p8poke,
	peek2=||error'TODO',
	poke2=||error'TODO',
	peek4=||error'TODO',
	poke4=||error'TODO',

	-- persistent data:
	cartdata=||nil,
	dget=||0,
	dset=||nil,
	serial=||nil,

	__numo9_finished=|_init, _update, _update60, _draw|do
		_init()
		-- pico8 needs a draw before any updates
		if _update then _update() end
		if _update60 then _update60() end
		update=||do
			if _update
			and peek(updateCounterAddr)&1==0 -- run at 30fps
			then
				_update()
			end
			if _update60 then _update60() end
			if _draw then _draw() end
		end
	end,
})
