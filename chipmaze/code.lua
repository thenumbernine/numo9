mget16=[i,j]do
	local m = mget(i,j)
	return ((m&0x1e)>>1)|((m&0x3c0)>>2)
end
mset16=[i,j,m] mset(i,j,((m&0xf)<<1)|((m&0xf0)<<2))

local buttons={up=3, down=1, left=2, right=0, a=4, b=5, x=6, y=7}
local dirs={up=3, down=1, left=2, right=0}
local oppdir=[x] x ~ 2
local dirvec={[0]={1,0}, [1]={0,1}, [2]={-1,0}, [3]={0,-1}}

-- index in the tilesheet
local tiles={
	empty=0,
	water=1,
	stone=2,
	goal=3,
	pushblock=4,
	checkpoint=5,
	uparrow=6,
	downarrow=7,
	leftarrow=8,
	rightarrow=9,
	water_uparrow=10,
	water_downarrow=11,
	water_leftarrow=12,
	water_rightarrow=13,
	block_uparrow=16,
	block_downarrow=17,
	block_leftarrow=18,
	block_rightarrow=19,
	enemy1=20,
}

local tileflags={
	-- [[ or you can merge tileflags and tiles and just make these flags into exclusive field values 0-6
	-- and the arrows can be in bits 0x18 or 0x30 or so
	-- and that brings us right back to the original implementation... glad I kept it ...
	-- maybe put water=1 and pushblock=2 so that arrows are 8,9,a,b, water-arrows are 18,19,1a,1b, and push-block arrows are 28,29,2a,2b
	water=1,
	solid=2,
	pushable=4,
	checkpoint=8,
	goal=0x10,			-- since goals can't be pushed (they trigger beforehand), you could have goal == checkpoint|pushable ...
	arrow=0x20,
	--]]
	arrowud=0x40,		-- \_ if arrow is set then these two bits to find which way it points
	arrowlr=0x80,		-- /
}
local arrowdirpropbit = 6	-- this is the bit index of arrowud
assert.eq(1<<arrowdirpropbit, tileflags.arrowud)
assert.eq(tileflags.arrowud<<1, tileflags.arrowlr)

-- would be really convenient to have a separate editor for visual tile vs property tile ... just like the zeta2d engine has ...
local tilePropForIndex={
	[tiles.empty]=0,
	[tiles.water]=tileflags.water,
	[tiles.stone]=tileflags.solid,
	[tiles.goal]=tileflags.goal,
	[tiles.pushblock]=tileflags.pushable,
	[tiles.checkpoint]=tileflags.checkpoint,
	[tiles.uparrow]=tileflags.arrow,
	[tiles.downarrow]=tileflags.arrow|tileflags.arrowud,
	[tiles.leftarrow]=tileflags.arrow|tileflags.arrowlr,
	[tiles.rightarrow]=tileflags.arrow|tileflags.arrowud|tileflags.arrowlr,
	[tiles.water_uparrow]=tileflags.water|tileflags.arrow,
	[tiles.water_downarrow]=tileflags.water|tileflags.arrow|tileflags.arrowud,
	[tiles.water_leftarrow]=tileflags.water|tileflags.arrow|tileflags.arrowlr,
	[tiles.water_rightarrow]=tileflags.water|tileflags.arrow|tileflags.arrowud|tileflags.arrowlr,
	[tiles.block_uparrow]=tileflags.pushable|tileflags.arrow,
	[tiles.block_downarrow]=tileflags.pushable|tileflags.arrow|tileflags.arrowud,
	[tiles.block_leftarrow]=tileflags.pushable|tileflags.arrow|tileflags.arrowlr,
	[tiles.block_rightarrow]=tileflags.pushable|tileflags.arrow|tileflags.arrowud|tileflags.arrowlr,
	-- more evil things you can do by mixing bitflags ...
	-- * one way goals
	-- * goals or checkpoints underwater
	-- * goals or checkpoints under water and over one way arrows ...
}
local tileIndexForProp = table.map(tilePropForIndex, [v,k](k,v)):setmetatable(nil)

local mapw, maph = 40, 30

level=1
levelMax=11	-- 11 sanctioned levels
levelMax=18	-- and another 7 custom levels

local passwords = table{
	"wywq",
	"yhcb",
	"hepo",
	"gycw",
	"hhee",
	"ggcx",
	"pcjl",
	"aenn",
	"fgun",
	"winc",
	"jtcj",
}
local levelForPassword = passwords:mapi([pass, level](level, pass))

restartAtCheckpoint=[]do
	-- copy the level location into location 0 ...
	local mx = (level) % 6
	local my = (level-mx) / 6
	for i=0,mapw-1 do
		for j=0,maph-1 do
			mset(i,j,mget(i + mapw * mx, j + maph * my))
		end
	end

	x,y=xs,ys
	xn,yn=xs,ys
	dir=dirs.down
end

resetLevel=[]do
	xs,ys=0,0
	restartAtCheckpoint()
end

getpress=[]do
	for i=0,7 do
		if btnp(i) then return i end
	end
end
waitforpress=[]do
	while true do
		flip()
		local b = getpress()
		if b then return b end
	end
end

resetLevel()

inSplash=true
splashMenuY=0
splashInputPass=table{0,0,0,0}
splashMenuPassX=0
update=[]do
	if inSplash then
		while true do
			cls(0x10)
			local x,y = 24, 48
			local txt=[s]do text(s,x,y,0xc,-1) y+=8 end
			txt'ChopMaze'
			txt'A game by Jon Moore, ported by Chris Moore'
			txt'Push blocks over water'
			txt'Get through the maze'
			txt''
			txt'  Start'
			txt'  Password'
			local b = getpress()
			if b == 0 then splashMenuY -= 1 end
			if b == 1 then splashMenuY += 1 end
			splashMenuY %= 2
			text('>', x, splashMenuY*8+48+5*8, 0xc, -1)
			if b==4 or b==5 then
				if splashMenuY==0 then
					-- start game
					inSplash = false
					return
				else
					flip() -- clear keypress
					while true do
						cls(0x10)
						-- password screen
						y=48
						txt'Enter the four letter password'
						local splashInputPassStr = splashInputPass
							:mapi([x]string.char(x+('a'):byte())):concat()
						txt(splashInputPassStr )
						txt((' '):rep(splashMenuPassX)..'^')
						b = getpress()
						local changeLetter = [d]do
							splashInputPass[splashMenuPassX+1] += d
							splashInputPass[splashMenuPassX+1] %= 26
						end
						if b == 0 then changeLetter(1) end
						if b == 1 then changeLetter(-1) end
						if b == 2 then splashMenuPassX -= 1 end
						if b == 3 then splashMenuPassX += 1 end
						if b== 4 or b==5 then
							level = levelForPassword[splashInputPassStr] or 1
							inSplash = false
							resetLevel()
							return
						end
						splashMenuPassX %= 4
						flip()
					end
				end
			end
			flip()
		end
	end

	-- draw scrolling screen
	do
		local mw = 16
		local mh = 16
		local ulx = x - 7
		local uly = y - 7
		local dx = 0
		local dy = 0
		if ulx < 0 then
			ulx = 0
		end
		if uly < 0 then
			uly = 0
		end
		if ulx + mw > mapw then
			ulx = mapw - mw
		end
		if uly + mh > maph then
			uly = maph - mh
		end
		map(ulx, uly, mw, mh, 0, 0, 0, true)
		spr(dir<<1, (x-ulx)<<4, (y-uly)<<4, 2, 2)
	end

	-- get input
	xn,yn = x,y
	for d=0,3 do
		if btnp(d) then
			xn = math.clamp(x+dirvec[d][1], 0, mapw-1)
			yn = math.clamp(y+dirvec[d][2], 0, maph-1)
			dir = d
			break
		end
	end
	if xn==x and yn==y then return end

	-- check interaction with the world
	local m = mget16(xn,yn)
	local tp = tilePropForIndex[m]
	if tp&tileflags.water ~= 0 then
		text("UH-OH!!! You can't swim in this game!", 15, 15)
		text(" press JP-X to reset level...", 15, 23)
		text(" press any other key to start at checkpoint.", 15, 31)
		if waitforpress() == buttons.x then
			xs,ys=0,0
		end
		restartAtCheckpoint()
		return
	elseif tp&tileflags.solid ~= 0 then
		xn,yn=x,y
	elseif tp&tileflags.checkpoint ~= 0 then
		xs,ys=xn,yn
	elseif tp&tileflags.goal ~= 0 then
		xs,ys=0,0
		local texty=15
		local textrow=[s] do text(s, 0, texty) texty += 8 end
		textrow"Contragulations!!!                          "
		textrow"You beat this level.                        "
		if level > levelMax then
		  	textrow" . . . And you also beat all of the levels! "
			waitforpress()
			level=1
		else
			textrow("Here's the password for level "..level..":")
			level+=1
            textrow("Get ready for level "..level.."!!!              ")
		end
		textrow" press any key..."
		waitforpress()
		resetLevel()
		return
	
	elseif tp&tileflags.pushable ~= 0 then
		local arrowdir = m - tiles.block_uparrow
		if arrowdir >= 0 and arrowdir < 4 
		and dir == oppdir(arrowdir)
		then
			xn, yn = x,y 
		else
			local bx = xn + dirvec[dir][1]
			local by = yn + dirvec[dir][2]
			if bx < 0 or bx >= mapw or by < 0 or by >= maph then
				xn, yn = x,y
			else
				local bm = mget16(bx, by)
				local btp = tilePropForIndex[bm]
				if bm == tiles.empty then
					btp |= tileflags.pushable
					mset16(bx, by, assert.index(tileIndexForProp, btp))
				elseif btp & tileflags.water ~= 0 then
					-- remove the water flag from the dest tile
					btp &= ~tileflags.water
					-- and lookup what tile this is
					mset16(bx, by, assert.index(tileIndexForProp, btp))
				-- handle blocking before arrow movement so that handling arrow doesnt let you walk over a pushable 
				elseif btp & (
					tileflags.solid
					|tileflags.pushable
					|tileflags.checkpoint
					|tileflags.goal
				) ~= 0 then
					xn, yn = x, y
				elseif btp & tileflags.arrow ~= 0 then
					-- add pushable flag to the dest tile
					btp |= tileflags.pushable
					mset16(bx, by, assert.index(tileIndexForProp, btp))
				else
					error'here'
				end
				
				if xn ~= x or yn ~= y then
					-- remove the pushable flag from the source tile
					tp &= ~tileflags.pushable
					mset16(xn, yn, assert.index(tileIndexForProp, tp))
				end
			end
		end

	elseif tp & tileflags.arrow ~= 0 then
		local arrowdir = (tp >> arrowdirpropbit) & 3
		if dir==oppdir(arrowdir) then xn,yn = x,y end
	end
	
	if xn~=x or yn~=y then
		x,y = xn,yn
	end
end
