sprFlags={
0x00,0x02,0x02,0x02,0x00,0x00,0x12,0x02,0x02,0x02,0x00,0x00,0x00,0x00,0x02,0x02,
0x02,0x02,0x00,0x00,0x00,0x00,0x02,0x01,0x00,0x00,0x02,0x02,0x00,0x00,0x00,0x00,
0x02,0x02,0x02,0x02,0x02,0x00,0x00,0x00,0x00,0x42,0x00,0x00,0x00,0x00,0x02,0x02,
0x12,0x42,0x02,0x02,0x02,0x02,0x42,0x42,0x00,0x00,0x00,0x00,0x02,0x00,0x02,0x02,
0x60,0x70,0x60,0x60,0x70,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
0x20,0x02,0x20,0x00,0x60,0x00,0x00,0x00,0x04,0x04,0x0c,0x0c,0x04,0x20,0x00,0x00,
0xa0,0x00,0x00,0x60,0xa0,0xa0,0xa0,0xa0,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
0xa0,0x00,0x08,0x08,0xb0,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x02,
0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
}

-- begin compat layer
fbMem=0x050200
palMem=0x040000
updateCounterMem=0x070244
p8ton9btnmap={[0]=2,3,0,1,7,5}
defaultColor=6
camx,camy=0,0	-- map's layers needs an optimized pathway which needs the camera / clip info ...
textx,texty=0,0
lastlinex,lastlieny=0,0
resetmat=[]do
	matident()
	matscale(2,2)
end
resetmat()
p8_camera=[x,y]do
	resetmat()
	if not x then
		camx,camy=0,0
	else
		mattrans(-x,-y)
		camx,camy=x,y
	end
end
p8_clip=[x,y,w,h,rel]do
assert(not rel, 'TODO')
	if not x then
		clip(0,0,255,255)
	else
		x=math.floor(x)
		y=math.floor(y)
		if x<0 then
			w+=x
			x=0
		end
		if y<0 then
			h+=y
			y=0
		end
		w=math.min(math.floor(w),128)
		h=math.min(math.floor(h),128)
		clip(2*x,2*y,2*w-1,2*h-1)
	end
end
p8_fillp=[p]nil
p8_pal=[from,to,pal]do
	if not from then
		--[[ preserve transparency
		pokel(palMem,   0x28a30000|(peekl(palMem   )&0x80008000))
		pokel(palMem+4, 0x2a00288f|(peekl(palMem+4 )&0x80008000))
		pokel(palMem+8, 0x254b1955|(peekl(palMem+8 )&0x80008000))
		pokel(palMem+12,0x77df6318|(peekl(palMem+12)&0x80008000))
		pokel(palMem+16,0x029f241f|(peekl(palMem+16)&0x80008000))
		pokel(palMem+20,0x1b8013bf|(peekl(palMem+20)&0x80008000))
		pokel(palMem+24,0x4dd07ea5|(peekl(palMem+24)&0x80008000))
		pokel(palMem+28,0x573f55df|(peekl(palMem+28)&0x80008000))
		--]]
		-- [[ reset transparency too
		pokel(palMem,   0xa8a30000)
		pokel(palMem+4, 0xaa00a88f)
		pokel(palMem+8, 0xa54b9955)
		pokel(palMem+12,0xf7dfe318)
		pokel(palMem+16,0x829fa41f)
		pokel(palMem+20,0x9b8093bf)
		pokel(palMem+24,0xcdd0fea5)
		pokel(palMem+28,0xd73fd5df)
		--]]
	elseif type(from)=='number' then
		-- sometimes 'to' is nil ... default to zero?
		to=tonumber(to) or 0
if pal then trace"TODO pal(from,to,pal)" end
		from=math.floor(from)
		to=math.floor(to)
		if from>=0 and from<16 and to>=0 and to<16 then
			--[[ preserve transparency?
			pokew(palMem+(to<<1),(peekw(palMem+32+(from<<1))&0x7fff)|(peekw(palMem+(from<<1))&0x8000))
			--]]
			-- [[
			pokew(palMem+(to<<1),peekw(palMem+32+(from<<1)))
			--]]
		end
	elseif type(from)=='table' then
		pal=to
if pal then trace"TODO pal(map,pal)" end
		for from,to in pairs(from) do
			from=math.floor(from)
			to=math.floor(to)
			if from>=0 and from<16 and to>=0 and to<16 then
				--[[ preserve transparency?
				pokew(palMem+(to<<1),(peekw(palMem+32+(from<<1))&0x7fff)|(peekw(palMem+(from<<1))&0x8000))
				--]]
				-- [[
				pokew(palMem+(to<<1),peekw(palMem+32+(from<<1)))
				--]]
			end
		end
	else
trace'pal idk'
trace(type(from),type(to),type(pal))
trace(from,to,pal)
		-- I think these just return?
	end
end
p8_getTransparency=[c,t]do
	c=math.floor(c)
assert(c >= 0 and c < 16)
	return peekw(palMem+(c<<1))&0x8000~=0
end
p8_setTransparency=[c,t]do
	c=math.floor(c)
assert(c >= 0 and c < 16)
	local addr=palMem+(c<<1)
assert(type(t)=='boolean')
	if t~=false then	-- true <-> transparent <-> clear alpha
		pokew(addr,peekw(addr)&0x7fff)
	else	-- false <-> opaque <-> set alpha
		pokew(addr,peekw(addr)|0x8000)
	end
end
p8_palt=[...]do
	local n=select('#',...)
	if n<=1 then
		local ts=math.floor(... or 0x0001)	-- bitfield of transparencies in reverse-order
		for c=0,15 do
			p8_setTransparency(c,ts&(1<<c)~=0)
		end
	elseif n==2 then
		p8_setTransparency(...)
	end
end
setfenv(1, {
	printh=trace,
	assert=assert,
	band=bit.band,
	bor=bit.bor,
	bxor=bit.bxor,
	bnot=bit.bnot,
	shl=bit.lshift,
	shr=bit.rshift,
	lshr=bit.arshift,
	rotl=bit.rol,
	rotr=bit.ror,
	min=math.min,
	max=math.max,
	mid=[a,b,c]do
		if b<a then a,b=b,a end
		if c<b then
			b,c=c,b
			if b<a then a,b=b,a end
		end
		return b
	end,
	flr=math.floor,
	ceil=math.ceil,
	cos=[x]math.cos(x*2*math.pi),
	sin=[x]-math.sin(x*2*math.pi),
	atan2=[x,y]math.atan2(-y,x)/(2*math.pi),
	sqrt=math.sqrt,
	abs=math.abs,
	sgn=[x]x<0 and -1 or 1,
	rnd=[x]do
		if type(x)=='table' then
			return table.pickRandom(x)
		end
		return (x or 1)*math.random()
	end,
	srand=math.randomseed,
	add=table.insert,
	del=table.removeObject,
	deli=table.remove,
	pairs=[t]do
		if t==nil then return coroutine.wrap([]nil) end
		return pairs(t)
	end,
	all=[t]coroutine.wrap([]do
		for _,x in ipairs(t) do
			coroutine.yield(x)
		end
	end),
	foreach=[t,f]do
		for _,o in ipairs(t) do f(o) end
	end,
	tostr=tostring,
	tonum=tonumber,
	chr=string.char,
	ord=string.byte,
	sub=string.sub,
	split=string.split,
	yield=coroutine.yield,
	cocreate=coroutine.create,
	coresume=coroutine.resume,
	costatus=coroutine.status,

	t=time,
	time=time,

	flip=[]nil,
	cls=cls,
	clip=p8_clip,
	camera=p8_camera,
	pset=[x,y,col]do
		x=math.floor(x)
		y=math.floor(y)
		col=math.floor(col or defaultColor)
		pokew(fbMem+((x|(y<<8))<<1),peekw(palMem+(col<<1)))
	end,
	rect=[x0,y0,x1,y1,col]do
		col=col or defaultColor	-- TODO `or=` operator for logical-inplace-or?
		rectb(x0,y0,x1-x0+1,y1-y0+1,col)
	end,
	rectfill=[x0,y0,x1,y1,col]do
		col=col or defaultColor
		rect(x0,y0,x1-x0+1,y1-y0+1,col)
	end,
	circ=[x,y,r,col]do
		col=col or defaultColor
		ellib(x-r,y-r,2*r+1,2*r+1,col)
	end,
	circfill=[x,y,r,col]do
		col=col or defaultColor
		elli(x-r,y-r,2*r+1,2*r+1,col)
	end,
	circ=[x,y,r,col]do
		col=col or defaultColor
		ellib(x-r,y-r,2*r+1,2*r+1,col)
	end,
	circfill=[x,y,r,col]do
		col=col or defaultColor
		elli(x-r,y-r,2*r+1,2*r+1,col)
	end,
	oval=[x0,y0,x1,y1,col]do
		col=col or defaultColor
		elli(x0,y0,x1-x0+1,y1-y0+1,col)
	end,
	ovalb=[x0,y0,x1,y1,col]do
		col=col or defaultColor
		ellib(x0,y0,x1-x0+1,y1-y0+1,col)
	end,
	line=[...]do
		local x0,y0,col,x1,y1=lastlinex,lastliney,defaultColor
		local n=select('#',...)
		if n==2 then
			x1,y1=...
		elseif n==3 then
			x1,y1,col=...
			col=col or defaultColor
		elseif n==4 then
			x0,y0,x1,y1=...
		elseif n==5 then
			x0,y0,x1,y1,col=...
			col=col or defaultColor
		end
		assert(type(x0)=='number')
		assert(type(y0)=='number')
		assert(type(x1)=='number')
		assert(type(y1)=='number')
		x0=math.floor(x0)
		y0=math.floor(y0)
		x1=math.floor(x1)
		y1=math.floor(y1)
		col=math.floor(col)
		line(x0,y0,x1,y1,col)
		lastlinex,lastliney=x1,y1
	end,
	print=[...]do
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
		if s:sub(-1)=='\0' then
			s=s:sub(1,-2)
		else
			textx=0
			texty=math.max(y+8,122)
		end
		c=c or defaultColor
		text(s,x,y,c or defaultColor)
		return #s*8
	end,
	pal=p8_pal,
	palt=p8_palt,
	btn=[...]do
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
	btnp=[b, ...]do
		local pb=p8ton9btnmap[b]
		if not pb then return end
		return btnp(pb, ...)
	end,
	-- TODO this but in a section of RAM where I copy the sprite-flags
	-- TODO shouldn't all script variables be located in RAM
	-- TODO TODO am I turning this into an emulator?
	-- TODO TODO TODO can I implement Lua in SNES?
	fget=[...]do
		local i, f
		local n=select('#',...)
		if n==1 then
			local i=...
			i=math.floor(i)
assert(i>=0 and i<256)
			return sprFlags[i+1]
		elseif n==2 then
			local i,f=...
			i=math.floor(i)
			f=math.floor(f)
assert(i>=0 and i<256)
assert(f>=0 and f<8)
			return (1 & (sprFlags[i+1] >> f)) ~= 0
		else
			error'here'
		end
	end,
	fset=[...]do
		local n=select('#',...)
		if n==2 then
			local i,val=...
			i=math.floor(i)
			val=math.floor(val)
assert(i>=0 and i<256)
assert(val>=0 and val<256)
			sprFlags[i+1]=val
		elseif n==3 then
			local i,f,val=...
			i=math.floor(i)
			f=math.floor(f)
			val=math.floor(val)
assert(i>=0 and i<256)
			local flag=1<<f
			local mask=~flag
			sprFlags[i+1] &= mask
			if val==true then
				sprFlags[i+1] |= flag
			elseif val == false then
			else
				error'here'
			end
		else
			error'here'
		end
	end,
	mget=[x,y]do
		x=math.floor(x)
		y=math.floor(y)
		if x<0 or y<0 or x>=128 or y>=128 then return 0 end
		local i=mget(x,y)
		return (i&0xf)|((i>>1)&0xf0)
	end,
	mset=[x,y,i]do
		i=math.floor(i)
		mset(x,y,(i&0xf)|((i&0xf0)<<1))
	end,
	map=[tileX,tileY,screenX,screenY,tileW,tileH,layers]do
--trace('map', 	tileX,tileY,screenX,screenY,tileW,tileH,layers)
		tileX=math.floor(tileX)
		tileY=math.floor(tileY)
		tileW=math.floor(tileW or 1)
		tileH=math.floor(tileH or 1)
		screenX=math.floor(screenX or 0)
		screenY=math.floor(screenY or 0)

-- [=[ this would be faster to run, but my map() routine doesn't skip tile index=0 like pico8's does
		if not layers then
			return map(tileX,tileY,tileW,tileH,screenX,screenY,0)
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

		-- [[
		if camScreenX+8<0 then
			local shift=(-8-camScreenX)>>3
assert(shift>=0)
			screenX+=shift<<3
			camScreenX+=shift<<3
			tileX+=shift
			tileW-=shift
		end
		if camScreenY+8<0 then
			local shift=(-8-camScreenY)>>3
assert(shift>=0)
			screenY+=shift<<3
			camScreenY+=shift<<3
			tileY+=shift
			tileH-=shift
		end
		--]]

		-- [[
		if camScreenX+(tileW<<3) > 128 then
			local shift=(camScreenX+(tileW<<3) - 128)>>3
assert(shift>=0)
			tileW-=shift
		end
		if camScreenY+(tileH<<3) > 128 then
			local shift=(camScreenY+(tileH<<3) - 128)>>3
assert(shift>=0)
			tileH-=shift
		end
		--]]
		-- [[
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
		--]]
		-- [[
		if tileW<=0 or tileH<=0 then return end
		if tileW>127-tileX then tileW=127-tileX end
		if tileH>127-tileY then tileH=127-tileY end
		--]]

		-- [[
		if camScreenX>128
		or camScreenY>128
		or camScreenX+tileW*8+128 <= 0
		or camScreenY+tileH*8+128 <= 0
		then
			return
		end
		--]]

		local ssy=screenY
		for ty=tileY,tileY+tileH-1 do
			local ssx=screenX
			for tx=tileX,tileX+tileW-1 do
				local i=mget(tx,ty)
				if i>0 then
					i=(i&0xf)|((i>>1)&0xf0)
					if not layers
					or sprFlags[i+1]&layers==layers
					then
						map(tx,ty,1,1,ssx,ssy,0)
					end
				end
				ssx+=8
			end
			ssy+=8
		end
	end,
	spr=[n,x,y,w,h,flipX,flipY]do
		n=math.floor(n)
		assert(n >= 0 and n < 256)
		n=(n&0xf)|((n&0xf0)<<1)
		w=math.floor(w or 1)
		h=math.floor(h or 1)
		local scaleX,scaleY=1,1
		if flipX then scaleX=-1 x+=w*8 end
		if flipY then scaleY=-1 y+=h*8 end
		spr(n,x,y,w,h,0,-1,0,0xf,scaleX,scaleY)
	end,
	sspr=[sheetX,sheetY,sheetW,sheetH,destX,destY,destW,destH,flipX,flipY]do
		destW = destW or sheetW
		destH = destH or sheetH
		quad(destX,destY,destW,destH,
			sheetX/256, sheetY/256,
			sheetW/256, sheetH/256,
			0,-1,0,0xf)
	end,
	color=[c]do defaultColor=math.floor(c or 6) end,

	fillp=p8_fillp,
	reset=[]do
		p8_camera()
		p8_clip()
		p8_pal()
		p8_fillp(0)
	end,
	music=[]nil,	-- TODO
	sfx=[]nil,		-- TODO
	reload=[dst,src,len]do	-- copy from rom to ram
trace'TODO reload'
		if not dst then
			-- reload everything ... from 'disk' ?  from a separate storage location ... ?
		else
		end
	end,
	memcpy=[dst,src,len]do
trace'TODO memcpy'
		-- copy from ram to ram
		-- in jelpi this is only used for copying the current level over the first level's area
	end,

	menuitem=[]trace'TODO menuitem',

	__numo9_finished=[_init, _update, _update60, _draw]do
		_init()
		-- pico8 needs a draw before any updates
		if _update then _update() end
		if _update60 then _update60() end
		update=[]do
			if _update
			and peek(updateCounterMem)&1==0  -- run at 30fps
			then
				_update()
			end
			if _update60 then _update60() end
			if _draw then _draw() end
		end
	end,
})
