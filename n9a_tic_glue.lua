mode(1)	-- set to 8bpp-indexed framebuffer
screenWidth=240
screenHeight=136
ticpeek=[addr,bits]do
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
	if addr>=0 and addr<0x4000 then	-- vram
		local x=addr%120
		local y=(addr-x)/120
		addr=(x<<1)|(y<<8)
		local value=peekw(framebufferAddr+addr)
		return (value&0x000f)|((value&0x0f00)>>4)
	elseif addr>=0x8000 and addr<0xff80 then
		addr-=0x8000
		local x=addr%240
		local y=(addr-x)/240
		addr=(x|(y<<8))<<1
		local value=peekw(tilemapAddr+addr)
		return (value&0x0f)|((value>>1)&0xf0)
	end
trace(('TODO peek $%x '):format(addr)..tostring(bits))
end
ticpoke=[addr,value,bits]do
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
	if addr>=0 and addr<0x4000 then	-- vram
		local x=addr%120
		local y=(addr-x)/120
		addr=(x<<1)|(y<<8)
		return pokew(framebufferAddr+addr,(value&0xf)|((value&0xf0)<<4))
	elseif addr>=0x8000 and addr<0xff80 then
		addr-=0x8000
		local x=addr%240
		local y=(addr-x)/240
		addr=(x|(y<<8))<<1
		return pokew(tilemapAddr+addr,(value&0xf)|((value&0xf0)<<1))
	end
trace(('TODO poke $%x '):format(addr)..tostring(bits)..' '..tostring(value))
end
-- default to 0
ticbit={
	band=[a,b]bit.band(a or 0, b or 0),
	bor=[a,b]bit.bor(a or 0, b or 0),
	bxor=[a,b]bit.bxor(a or 0, b or 0),
	bnot=[a]bit.bnot(a or 0),
	shl=[a,b]bit.lshift(a or 0, b or 0),
	shr=[a,b]bit.rshift(a or 0, b or 0),
	lshr=[a,b]bit.arshift(a or 0, b or 0),
	rotl=[a,b]bit.rol(a or 0, b or 0),
	rotr=[a,b]bit.ror(a or 0, b or 0),
}
setfenv(1, {
	btn=[b]btn(b&7,b>>3),
	btnp=[b,...]btnp(b&7,b>>3,...),
	circ=[x,y,r,...]elli(x-r,y-r,(r<<1)+1,(r<<1)+1,...),
	circb=[x,y,r,...]ellib(x-r,y-r,(r<<1)+1,(r<<1)+1,...),
	clip=clip,
	cls=cls,
	elli=[x,y,a,b,c]elli(x-a,y-b,(a<<1)+1,(b<<1)+1,c),
	ellib=[x,y,a,b,c]ellib(x-a,y-b,(a<<1)+1,(b<<1)+1,c),
	exit=stop,
	fget=[i,f]do
		i=math.floor(i)
		f=math.floor(f)
		return (1&((sprFlags[i] or 0)>>f))~=0
	end,
	--font(text x y chromakey char_width char_height fixed=false scale=1 alt=false) -> width`
	font=[s,x,y,k,w,h,fixed,scale,alt]do
		return text(s,x,y,w*scale/8,h*scale/8)	-- TODO
	end,
	fset=[i,f,v]do
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
	map=[tileX,tileY,tileW,tileH,screenX,screenY,colorkey,scale,remap]do
		if colorkey then trace'TODO map colorkey' end
		if scale then trace'TODO map scale' end
		if remap then trace'TODO map remap' end
		map(tileX or 0,tileY or 0,tileW or 30,tileH or 17,screenX or 0,screenY or 0)
	end,
	memcpy=[dst,src,len]do
		for i=0,len-1 do
			ticpoke(dst+i,ticpeek(src+i))
		end
	end,
	memset=[dst,val,len]do
		for i=0,len-1 do
			ticpoke(dst+i,val)
		end
	end,
	mget=[x,y]mget(x,y) or 0,	-- TODO what's the default for mget?
	mset=[x,y,v]mset(x,y,v),
	music=[]do
		trace'TODO music'
	end,
	peek=ticpeek,
	peek1=[i]ticpeek(i,1),
	peek2=[i]ticpeek(i,2),
	peek4=[i]ticpeek(i,4),
	pix=[x,y,c]do
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
	pmem=[i,v]do
		if v then
			pokel(persistentDataAddr+(i<<2),v)
		else
			return peekl(persistentDataAddr+(i<<2))
		end
	end,
	poke=ticpoke,
	poke1=[i,v]ticpoke(i,v,1),
	poke2=[i,v]ticpoke(i,v,2),
	poke4=[i,v]ticpoke(i,v,4),
	print=[s,x,y,color,fixed,scale,smallfont]do
		return text(s,x,y,scale,scale)
	end,
	rect=rect,
	rectb=rectb,
	reset=reset,
	sfx=[] trace'TODO sfx',
	spr=[n,x,y,colorkey,scale,flip,rotate,w,h]do
		if rotate then trace'TODO spr rotate' end
		n=math.floor(n)
		local bankno=bit.rshift(n, 8)
		n&=0xff
		local nx=n&0xf
		local ny=n>>4
		n=nx|(ny<<5)
		w=math.floor(w or 1)
		h=math.floor(h or 1)
		local scaleX,scaleY=scale,scale
		if flipX then x+=w*scale*8 scaleX=-scale end
		if flipY then y+=h*sclae*8 scaleY=-scale end
		-- TODO here multiple bank sprites ... hmm ...
		-- how should I chop up banks myself ...
		spr(n,x,y,w,h,0,-1,0,0xf,scaleX,scaleY)
	end,
	sync=[] trace'TODO sync',
	time=[] 1000*time(),
	trace=trace,
	tri=tri,
	trib=[] trace'TODO trib',
	tstamp=tstamp,
	ttri=[] trace'TODO ttri',
	vbank=[] trace'TODO vbank',

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
	math=math,	-- TODO original math
	table=table,	-- TODO original table
	string=string,	-- TODO original string
	langfix={	-- needed for langfix to work
		idiv=[a,b] tonumber(langfix.idiv(a,b)),
	},

	__numo9_finished=[boot, tic, ovr, scn, bdr]do
		local _ = boot?()
		if tic then tic() end
		update=[]do
			if tic then tic() end
			if ovr then ovr() end
			--if scn then scn() end
			--if bdr then bdr() end
		end
	end,
})
