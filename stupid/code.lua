--[[
TODO somehow dialogs don't show up anymore, probably due to transparency issues
--]]
--#include ext/class.lua
--#include ext/range.lua
--#include vec/vec2.lua
--#include vec/box2.lua

math.randomseed(tstamp())
blendColorMem=ramaddr'blendColor'
randomBoxPos=[box] vec2(math.random(box.min.x,box.max.x),math.random(box.min.y,box.max.y))
distLInf=[a,b] math.max(math.abs(a.x-b.x),math.abs(a.y-b.y))
distL1=[a,b] math.abs(a.x-b.x)+math.abs(a.y-b.y)
round=[x,r] math.round(x*r)/r



-- 2D simplex noise
grad3={
	[0]={1,1,0},{-1,1,0},{1,-1,0},{-1,-1,0},
	{1,0,1},{-1,0,1},{1,0,-1},{-1,0,-1},
	{0,1,1},{0,-1,1},{0,1,-1},{0,-1,-1}
}
local p={[0]=151,160,137,91,90,15,
	131,13,201,95,96,53,194,233,7,225,140,36,103,30,69,142,8,99,37,240,21,10,23,
	190, 6,148,247,120,234,75,0,26,197,62,94,252,219,203,117,35,11,32,57,177,33,
	88,237,149,56,87,174,20,125,136,171,168, 68,175,74,165,71,134,139,48,27,166,
	77,146,158,231,83,111,229,122,60,211,133,230,220,105,92,41,55,46,245,40,244,
	102,143,54, 65,25,63,161, 1,216,80,73,209,76,132,187,208, 89,18,169,200,196,
	135,130,116,188,159,86,164,100,109,198,173,186, 3,64,52,217,226,250,124,123,
	5,202,38,147,118,126,255,82,85,212,207,206,59,227,47,16,58,17,182,189,28,42,
	223,183,170,213,119,248,152, 2,44,154,163, 70,221,153,101,155,167, 43,172,9,
	129,22,39,253, 19,98,108,110,79,113,224,232,178,185, 112,104,218,246,97,228,
	251,34,242,193,238,210,144,12,191,179,162,241, 81,51,145,235,249,14,239,107,
	49,192,214, 31,181,199,106,157,184, 84,204,176,115,121,50,45,127, 4,150,254,
	138,236,205,93,222,114,67,29,24,72,243,141,128,195,78,66,215,61,156,180
}
local perm={}
for i=0,511 do perm[i]=p[i & 255] end

dot=[g,...]do
	local sum=0
	for i=1,select('#', ...) do
		sum += select(i, ...) * g[i]
	end
	return sum
end

noise=[xin,yin]do
	local n0, n1, n2 -- Noise contributions from the three corners
	-- Skew the input space to determine which simplex cell we're in
	local F2=0.5*(math.sqrt(3)-1)
	local s=(xin+yin)*F2 -- Hairy factor for 2D
	local i=math.floor(xin+s)
	local j=math.floor(yin+s)
	local G2=(3-math.sqrt(3))/6
	local t=(i+j)*G2
	local X0=i-t -- Unskew the cell origin back to (x,y) space
	local Y0=j-t
	local x0=xin-X0 -- The x,y distances from the cell origin
	local y0=yin-Y0
	-- For the 2D case, the simplex shape is an equilateral triangle.
	-- Determine which simplex we are in.
	local i1, j1 -- Offsets for second (middle) corner of simplex in (i,j) coords
	if x0>y0 then i1=1 j1=0 -- lower triangle, XY order: (0,0)->(1,0)->(1,1)
	else i1=0 j1=1 -- upper triangle, YX order: (0,0)->(0,1)->(1,1)
	end
	-- A step of (1,0) in (i,j) means a step of (1-c,-c) in (x,y), and
	-- a step of (0,1) in (i,j) means a step of (-c,1-c) in (x,y), where
	-- c=(3-sqrt(3))/6
	local x1=x0 - i1 + G2 -- Offsets for middle corner in (x,y) unskewed coords
	local y1=y0 - j1 + G2
	local x2=x0 - 1 + 2 * G2 -- Offsets for last corner in (x,y) unskewed coords
	local y2=y0 - 1 + 2 * G2
	-- Work out the hashed gradient indices of the three simplex corners
	local ii=i & 255
	local jj=j & 255
	local gi0=perm[ii+perm[jj]] % 12
	local gi1=perm[ii+i1+perm[jj+j1]] % 12
	local gi2=perm[ii+1+perm[jj+1]] % 12
	-- Calculate the contribution from the three corners
	local t0=0.5 - x0*x0-y0*y0
	if t0<0 then n0=0
	else
		t0 *= t0
		n0=t0 * t0 * dot(grad3[gi0], x0, y0) -- (x,y) of grad3 used for 2D gradient
	end
	local t1=0.5 - x1*x1-y1*y1
	if t1<0 then n1=0
	else
		t1 *= t1
		n1=t1 * t1 * dot(grad3[gi1], x1, y1)
	end
	local t2=0.5 - x2*x2-y2*y2
	if t2<0 then n2=0
	else
		t2 *= t2
		n2=t2 * t2 * dot(grad3[gi2], x2, y2)
	end
	-- Add contributions from each corner to get the final noise value.
	-- The result is scaled to return values in the interval [-1,1].
	return 70 * (n0 + n1 + n2)
end


-- globals

local screenSize = vec2(256, 256)
local tileSize = vec2(16, 16)
local fontSize = 8
local thisMap
local player
local setMapRequest = nil
local keyCallback

local maps = table()
local storyInfo = {}


-- client prompt stuff

popupMessage=table()
clientMessage=[str] popupMessage:insert(1, str)

clientPromptStack=table()
closeAllPrompts=[]do
	while #clientPromptStack>0 do
		clientPromptStack:last():close()
	end
end

promptKeyCallback=[key]do
	local clientPrompt=clientPromptStack:last()
	keyCallback=nil
	if key=='ok' then
		clientPrompt:onchoose(clientPrompt.options[clientPrompt.index], clientPrompt.index)
	elseif key=='up' then
		clientPrompt:cycle(-1)
	elseif key=='down' then
		clientPrompt:cycle(1)
	elseif key=='left' then
		clientPrompt:cycle(-10)
	elseif key=='right' then
		clientPrompt:cycle(10)
	else
		clientPrompt:close()
	end
	return false
end

--[[
TODO args:
options
onselect
onchoose
onclose
--]]
ClientPrompt=class{
	enabled=true,
	init=[:,options,onchoose,onselect,onclose]do
		local divsHigh=#options
		if divsHigh>9 then divsHigh=9 end
		self.options=table(options)
		self.onchoose=onchoose
		self.onselect=onselect
		self.onclose=onclose
		self.topIndex=0
		self.index=1
		--clientPromptStack:last()?:disable()
		if clientPromptStack:last() and clientPromptStack:last().disable then clientPromptStack:last():disable() end
		clientPromptStack:insert(self)
		keyCallback=promptKeyCallback
		self:refreshPos()
		self:enable()
		self:refreshContent()
	end,
	enable=[:]do
		self.enabled=true
	end,
	disable=[:]do
		self.enabled=false
	end,
	close=[:]do
		local promptIndex=clientPromptStack:find(self)
		if promptIndex then
			if promptIndex == #clientPromptStack
			and promptIndex > 1
			then
				clientPromptStack[promptIndex-1]:enable()
			end
			clientPromptStack:remove(promptIndex)
		end
		--self?:onclose()
		if self.onclose then self:onclose() end
	end,
	refreshPos=[:]do
	end,
	refreshContent=[:]do
		--self?:onselect(self.options[self.index], self.index)
		if self.onselect then self:onselect(self.options[self.index], self.index) end
	end,
	cycle=[:,ofs]do
		self.index+=ofs
		self.index-=1
		self.index%=#self.options
		self.index+=1
		--self.index=math.clamp(self.index,1,#self.options)
		self:refreshContent()
	end,
}

dirs=table{
	{name='e', offset=vec2(1,0)},
	{name='s', offset=vec2(0,1)},
	{name='w', offset=vec2(-1,0)},
	{name='n', offset=vec2(0,-1)},
}

view={
	center=vec2(),
	bbox=box2(),
}

-- spawn classes

GameObj=class{
	init=[:,args]do
		self.pos=vec2()
		if args.pos then
			self.pos.x=math.floor(args.pos.x)
			self.pos.y=math.floor(args.pos.y)
		end
		self:setPos(self.pos.x, self.pos.y) --link to tile
		self.angle=args.angle
		self.onInteract=args.onInteract
		if thisMap then thisMap.objs:insert(self) end
	end,
	clearTile=[:]do
		if thisMap then
			thisMap:removeObjFromTile(self)
		end
	end,
	setPos=[:,x,y]do
		self:clearTile()
		self.pos.x=x
		self.pos.y=y
		if thisMap then
			thisMap:addObjToTile(self)
		end
	end,
	move=[:,dx,dy]do
		local nx=math.floor(self.pos.x+dx)
		local ny=math.floor(self.pos.y+dy)
		if self==player and thisMap.exitMap then
			if nx<0 or ny<0 or nx>=thisMap.size.x or ny>=thisMap.size.y then
				setMapRequest={map=thisMap.exitMap}
				return
			end
		end
		if thisMap.wrap then
			nx=(nx + thisMap.size.x) % thisMap.size.x
			ny=(ny + thisMap.size.y) % thisMap.size.y
		else
			if nx < 0 then nx=0 end
			if ny < 0 then ny=0 end
			if nx >= thisMap.size.x then nx=thisMap.size.x-1 end
			if ny >= thisMap.size.y then ny=thisMap.size.y-1 end
		end

		local tile=thisMap:getTile(nx,ny)
		local tileObjs=thisMap:getTileObjs(nx,ny)
		if tile then
			local blocked=false
			if tileObjs then
				for _,obj in ipairs(tileObjs) do
					if obj~=self
					and obj.solid
					then
						if self.moveIntoObj then
							self:moveIntoObj(obj)	--only player has self
						end
						blocked=true
					end
				end
			end
			if blocked then return true end

			if self.movesInWater then
				if not tile.water then return true end
			else
				if tile.solid or tile.water then return true end
			end
		end

		--do self after moveIntoObj so player can moveIntoObj neighbors while still being stuck
		if self.hasAttribute and self:hasAttribute"Don't Move" then return true end

		self:setPos(nx,ny)
	end,
	postUpdate=[:]do
		self:applyLight()
	end,
	applyLight=[:]do
		if not thisMap.fogColor then return end
		--update fog of war
		local lightRadius=self:getLightRadius()
		if not lightRadius then return end

		thisMap:floodFill{
			pos=self.pos,
			maxDist=lightRadius,
			callback=[tile,dist,tileObjs]do
				local newLight=1.1-dist/lightRadius
				tile.light=math.max(tile.light or 0, newLight)
				if tile.solid then return false end
				if tileObjs then
					for _,obj in ipairs(tileObjs) do
						if obj.blocksLight then return false end
					end
				end
				return true
			end,
		}
	end,
	getLightRadius=[:]self.lightRadius,
	draw=[:]do
		local dx=self.pos.x-view.center.x
		local dy=self.pos.y-view.center.y
		if thisMap.wrap then
			if dx < -thisMap.size.x/2 then dx += thisMap.size.x end
			if dx > thisMap.size.x/2 then dx -= thisMap.size.x end
			if dy < -thisMap.size.y/2 then dy += thisMap.size.y end
			if dy > thisMap.size.y/2 then dy -= thisMap.size.y end
		end
		dx+=view.center.x
		dy+=view.center.y
		local rx,ry= dx,dy
		if rx < view.bbox.min.x or ry < view.bbox.min.y or rx > view.bbox.max.x or ry > view.bbox.max.y then return end
		rx -= view.bbox.min.x
		ry -= view.bbox.min.y
		rx *= tileSize.x
		ry *= tileSize.y
		self:drawLocal(rx, ry)
	end,
	drawLocal=[:,rx,ry]do
		if not self.spriteIndex then return end
		if self.angle then
			local pivotX=rx+tileSize.x/2
			local pivotY=ry+tileSize.y/2

			matident()--push
			mattrans(pivotX, pivotY)
			matrot(self.angle)
			mattrans(-pivotX, -pivotY)
			spr(self.spriteIndex, rx, ry, 2, 2)
			matident()--pop
		else
			spr(self.spriteIndex, rx, ry, 2, 2)
		end
	end,
}

ChestObj=class()

DeadObj=GameObj:subclass{
	spriteIndex=12,	--'objs/dead.png'
	solid=false,
	init=[:,args]do
		DeadObj.super.init(self,args)
		self.life=math.random(10, 100)
	end,
	update=[:]do
		self.life-=1
		if self.life<=0 then self.remove=true end
	end,
}

BattleObj=GameObj:subclass{
	solid=true,
	equipFields=table{'rhand','lhand','body','head','relic1','relic2'},
	hpMax=1,
	mpMax=1,
	gold=0,
	physAttack=1,
	physHitChance=80,
	physEvade=20,
	magicAttack=1,
	magicHitChance=80,
	magicEvade=0,
	inflictChance=1/4,
	inflictAttributes=table(),
	attackOffsets=table{vec2(1,0)},
	damageType='bludgeon',
	init=[:,args]do
		BattleObj.super.init(self,args)
		local classItems=self.items
		self.items=table()
		if classItems then
			for _,item in ipairs(classItems) do
				if type(item)=='string' then item=itemClasses[item] end
				item=item.class and item or item()
				self.items:insert(item)
			end
		end
		self.items:append(args.items)

		self.spells=table()
		self.attributes=table()
		self.hp=self:stat'hpMax'
		self.mp=self:stat'mpMax'
	end,
	stat=[:,field]do
		local value=self[field]
		local srcInfos=table()
		srcInfos:append(
			self.equipFields
				:filter([equipField]self[equipField])
				:mapi([equipField]{equip=equipField, src=self[equipField]})
		)
		srcInfos:append(
			self.attributes:mapi([attribute]{attribute=true, src=attribute})
		)
		--[[ prefix args
		(
			([equipField]{equip=equipField, src=self[equipField]})
			->((
				([equipField]self.equipField)
				->self.equipFields:filter	-- : operator means "insert previous indexes as 1st arg into params before passing into this function"
				-- then the result of this is a table ... which we want a 1st arg :mapi and 2nd arg callback ...
			):mapi),
			([attribute]{attribute=true, src=attribute})
				->self.attributes:mapi
		)->srcInfos:append
		--]]
		for _,srcInfo in ipairs(srcInfos) do
			local src=srcInfo.src
			local srcvalue=src[field]
			if srcvalue then
				if type(value)=='number' then
					value += srcvalue
				elseif type(value)=='table' then
assert.eq(getmetatable(value), table)
					--special case for attackOffsets -=1 mirror left hand on the 'y' axis
					if field == 'attackOffsets' and srcInfo.equip == 'lhand' then
						srcvalue=srcvalue:mapi([ofs]vec2(ofs.x,-ofs.y))
					end
					value:append(srcvalue)
				else	--strings? functions? booleans? override...
					value=srcvalue
				end
			end
		end
		--and now that we've accum'd (+) all our stats
		local baseValue=value
		for _,srcInfo in ipairs(srcInfos)do
			local src=srcInfo.src
			local f=src[field..'Modify']
			if f then
				value=f(src, value, baseValue, self)
			end
		end
		return value
	end,
	getLightRadius=[:]self:stat'lightRadius',
	setAttribute=[:,attrName]do
		self:removeAttribute(attrName)
		PopupText{msg=attrName,pos=self.pos}
		local attrClass=attributes[attrName]
		if not attrClass then
			trace("!! tried to set an unknown attributes", attrName)
		else
			self.attributes:insert(attrClass(self))
		end
	end,
	setAttributes=[:,attrNames]do
		for _,attrName in ipairs(attrNames)do
			self:setAttribute(attrName)
		end
	end,
	removeAttribute=[:,attrName]do
		for i=#self.attributes,1,-1 do
			if self.attributes[i].name==attrName then
				self.attributes:remove(i)
			end
		end
	end,
	removeAttributes=[:,attrNames]do
		for _,attrName in ipairs(attrNames) do
			self:removeAttribute(attrName)
		end
	end,
	hasAttribute=[:,attrName]do
		for _,attribute in ipairs(self.attributes) do
			if attribute.name == attrName then return true end
		end
		return false
	end,
	setEquip=[:,field,item]do
		local currentEquip = self[field]
		if currentEquip  then
			self.items:insert(currentEquip)
			self[field]=nil
		end
		if item then
			if self:canEquip(field,item) then
				self[field]=item
			end
		end
		self.hp=math.min(self.hp,self:stat'hpMax')
		self.mp=math.min(self.mp,self:stat'mpMax')
	end,
	canEquip=[:,field,item]do
		if (item.type=='weapon' or item.type=='shield') and (field=='lhand' or field=='rhand') then return true end
		if item.type=='armor' and field=='body' then return true end
		if item.type=='helm' and field == 'head' then return true end
		if item.type=='relic' and (field=='relic1' or field=='relic2') then return true end
		return false
	end,
	postUpdate=[:]do
		for i=#self.attributes,1,-1 do
			local attribute=self.attributes[i]
			attribute:update(self)
			if attribute.remove then
				self.attributes:remove(i)
			end
		end
		local tileObjs=thisMap:getTileObjs(self.pos:unpack())
		if tileObjs then
			for _,obj in ipairs(tileObjs) do
				if obj~=self then
					if obj.onTouch then obj:onTouch(self) end
				end
			end
		end
		BattleObj.super.postUpdate(self)
	end,
	interact=[:,dx,dy]do
		local nx=math.floor(self.pos.x+dx+thisMap.size.x)%thisMap.size.x
		local ny=math.floor(self.pos.y+dy+thisMap.size.y)%thisMap.size.y
		local tileObjs=thisMap:getTileObjs(nx,ny)
		if tileObjs then
			for _,obj in ipairs(tileObjs)do
				if obj.onInteract then
					obj:onInteract(self)
					return
				end
			end
		end
	end,
	attack=[:,dx,dy]do
		local angle=math.atan2(dy,dx)
		local physAttack=self:stat'physAttack'
		local baseDamageType=self:stat'damageType'
		local attackOffsets=self:stat'attackOffsets'
		local inflictAttributes=self:stat'inflictAttributes'
		local pos=vec2()
		for _,attackOffset in ipairs(attackOffsets) do
			--rotate the offset by the dir (cplxmul)
			pos.x=dx*attackOffset.x-dy*attackOffset.y+self.pos.x
			pos.y=dx*attackOffset.y+dy*attackOffset.x+self.pos.y
			if thisMap:wrapPos(pos) then
				damageType=attackOffset.type or baseDamageType
				if damageType=='slash' then
					PopupSlashAttack{pos=pos, angle=angle}
				elseif damageType=='pierce' then
					PopupPierceAttack{pos=pos, angle=angle}
				elseif damageType=='bludgeon' then
					PopupBludgeonAttack{pos=pos, angle=angle}
				else
					trace("unknown damage type: "..damageType)
				end
				local tileObjs=thisMap:getTileObjs(pos:unpack())
				if tileObjs then
					for _,obj in ipairs(tileObjs)do
						if BattleObj:isa(obj)then
							if self:physHitRoll(obj)then
								local dmg=-physAttack
								obj:adjustPoints('hp',dmg,self)
								if inflictAttributes then
									for _,attr in ipairs(inflictAttributes)do
										if math.random()<self.inflictChance then
											obj:setAttribute(attr)
										end
									end
								end
							else
								PopupText{msg='MISS!', pos=obj.pos}
							end
						end
					end
				end
			end
		end
	end,
	physHitRoll=[:,defender] math.random(100)<=self:stat'physHitChance'-defender:stat'physEvade',
	magicHitRoll=[:,defender] math.random(100)<=self:stat'magicHitChance'-defender:stat'magicEvade',
	adjustPoints=[:,field,amount,inflictor]do
		local color
		if amount>0 then color=(0x1f<<10)|(0xf<<5) end	--rgb(0,127,255)
		local msg=(amount>=0 and'+'or'')..amount..' '..field
		PopupText{msg=msg, pos=self.pos, color=color}
		self[field]+=amount
		if field=='food' then return end

		local fieldMax=field..'Max'
		local fieldMaxValue=self:stat(fieldMax)
		self[field]=math.clamp(self[field],0,fieldMaxValue)
		if self.hp==0 then
			if inflictor and HeroObj:isa(inflictor) then
				if inflictor.gold and self.gold then inflictor.gold+=self.gold end
				if inflictor.items and self.items then inflictor.items=inflictor.items:append(self.items) end
			end
			self:die()
		end
	end,
	die=[:]do
		self.remove=true
		DeadObj{pos=self.pos}
	end,
}

HeroObj=BattleObj:subclass{
	spriteIndex=130,--'objs/hero.png'
	hpMax=25,
	mpMax=25,
	foodMax=5000,
	gold=0,
	nominalTemp=80,
	warmth=28.6,
	physAttack=1,
	physHitChance=70,
	physEvade=10,
	lightRadius=10,
	init=[:,args]do
		HeroObj.super.init(self,args)
		self.hp=self.hpMax
		self.mp=0
		self.food=math.ceil(self.foodMax/2)
		self.temp=self.nominalTemp
	end,
	update=[:]do
		self.food-=1
		if self.food<=0 then
			clientMessage"HUNGRY!!!"
			self:adjustPoints('hp', -math.ceil(self:stat'hpMax'/20))
		elseif self.food>self:stat'foodMax'then
			clientMessage"FATTY FAT FAT!!!"
			local overweight=self.food-self:stat'foodMax'
			if math.random()<self:stat'hpMax'/100 then
				local dmg=overweight/1000
				--dmg*=self:stat'hpMax'/20
				self:adjustPoints('hp',-math.ceil(dmg))
			end
			self.food-=math.ceil(overweight*.1)
		end
		local envTemp=thisMap.temp+self:stat'warmth'
		self.temp+=(envTemp-self.temp)*.1
		if math.abs(self.temp-self.nominalTemp)>50 then
			if self.temp>self.nominalTemp then
				clientMessage"You're too hot!"
			else
				clientMessage"You're too cold!"
			end
			self:adjustPoints('hp',-math.ceil(self:stat'hpMax'/20))
		end
	end,
	move=[:,dx,dy]do
		if not HeroObj.super.move(self,dx,dy) then
			local tile=thisMap:getTile(self.pos:unpack())
			if tile.playerTouch then
				tile:playerTouch(self)
			end
		end
	end,
	moveIntoObj=[:,obj]do
		if obj.onInteract then
			obj:onInteract(self)
		else
			if MonsterObj:isa(obj) then
				self:attack(obj.pos.x-self.pos.x,obj.pos.y-self.pos.y)
			end
		end
	end,
	die=[:]do
		clientMessage"YOU DIED"
		setMapRequest={map='Helpless Village', dontSavePos=true}
		self.attributes=table()
		self.hp=1
		self.mp=0
		self.food=math.ceil(self.foodMax/2)
		self.temp=self.nominalTemp
		self.gold=math.floor(self.gold/2)
		for _,map in ipairs(maps) do
			map.lastPlayerStart=nil
		end
	end,
}

AIObj=BattleObj:subclass{
	spriteIndex=136,--'objs/orc.png'
	update=[:]do
		if not player then return end
		local acted=self:performAction()
		if acted then return end
		local deltax=player.pos.x - self.pos.x
		local deltay=player.pos.y - self.pos.y
		if thisMap.wrap then
			if deltax < -thisMap.size.x/2 then deltax += thisMap.size.x end
			if deltax > thisMap.size.x/2 then deltax -= thisMap.size.x end
			if deltay < -thisMap.size.y/2 then deltay += thisMap.size.y end
			if deltay > thisMap.size.y/2 then deltay -= thisMap.size.y end
		end
		local absdeltax=math.abs(deltax)
		local absdeltay=math.abs(deltay)
		local playerDist=absdeltax+absdeltay
		if type(self.distToHostile)=='number' then
			self.hostile=playerDist<=self.distToHostile
		end

		if type(self.distToRetreat)=='number' then
			self.retreat=playerDist<=self.distToRetreat
		end

		local dx, dy
		if not (self.hostile or self.retreat or self.wander) then return end

		if self.retreat then
			dx=math.sign(-deltax)
			dy=math.sign(-deltay)
		elseif self.hostile then
			dx=math.sign(deltax)
			dy=math.sign(deltay)
		elseif self.wander then
			if math.random()>.2 then return end
			local dir=dirs:pickRandom().offset
			dx=dir.x
			dy=dir.y
		end
		if dx and dy then
			if absdeltax>absdeltay then
				if not self:move(dx,0) then return end
				dx=0
			else
				if not self:move(0,dy) then return end
				dy=0
			end
		end
		local result=self:move(dx, dy)
	end,
	performAction=[:]do
		if self.hostile and distL1(player.pos,self.pos)<=1 then
			self:attack(player.pos.x-self.pos.x,player.pos.y-self.pos.y)
			return true
		end
	end,
}

MonsterObj=AIObj:subclass{
	hostile=true,
}

OrcObj=MonsterObj:subclass{
	hpMax=1,
	gold=1,
	physEvade=10,
	damageType='pierce',
}

ThiefObj=MonsterObj:subclass{
	spriteIndex=206,--'objs/thief.png'
	hpMax=2,
	physEvade=30,
	gold=10,
	performAction=[:]do
		if self.retreat then return end
		if distL1(self.pos, player.pos) <= 1
		and math.random(5)==5
		then
			if #player.items>0 and self:physHitRoll(player) then
				local item=player.items:remove(math.random(#player.items))
				self.items:insert(item)
				clientMessage('Thief Stole '..item.name..'!')
				self.retreat=true
			end
			return true
		else
			return ThiefObj.super.performAction(self)
		end
	end,
}

TroggleObj=MonsterObj:subclass{
	spriteIndex=132,--'objs/imp.png'
	hpMax=4,
	gold=4,
	performAction=[:]do
		if distL1(self.pos,player.pos) <= 3
		and math.random(5)==5
		then
			if self:magicHitRoll(player) then
				player:setAttribute"Don't Move"
			end
		else
			return TroggleObj.super.performAction(self)
		end
	end,
}

FighterObj=MonsterObj:subclass{
	spriteIndex=68,--'objs/fighter.png'
	hpMax=8,
	gold=8,
	physAttack=3,
	physHitChance=80,
}

SnakeObj=MonsterObj:subclass{
	spriteIndex=202,--'objs/snake.png'
	hpMax=1,
	gold=2,
	physEvade=30,
	inflictAttributes=table{'Poison'},
	damageType='pierce',
}

FishObj=MonsterObj:subclass{
	spriteIndex=72,--'objs/fish.png'
	hpMax=1,
	items=table{'Fish Fillet','Fish Fillet','Fish Fillet'},
	physEvade=50,
	wander=true,
	movesInWater=true,
}

DeerObj=MonsterObj:subclass{
	spriteIndex=14,--'objs/deer.png'
	hpMax=1,
	items=table{'Venison'},
	physEvade=50,
	wander=true,
	distToRetreat=10,
}

SeaMonsterObj=MonsterObj:subclass{
	spriteIndex=138,--'objs/seamonster.png'
	hpMax=20,
	gold=100,
	physAttack=5,
	physEvade=50,
	movesInWater=true,
}

EnemyBoatObj=MonsterObj:subclass{
	spriteIndex=2,--'objs/boat.png'
	hpMax=10,
	gold=50,
	physAttack=5,
	physEvade=30,
	movesInWater=true,
}

TownNPCObj=AIObj:subclass{
	onInteract=[:,player]do
		if self.msg then
			clientMessage(self.msg)
		end
	end,
	adjustPoints=[:,...]do
		if select('#',...)>=3 and select(3,...)==player then
			for _,obj in ipairs(thisMap.objs) do
				if TownNPCObj:isa(obj) then
					if GuardObj:isa(obj) then
						obj.hostile=true
					else
						obj.retreat=true
					end
				end
			end
		end
		TownNPCObj.super.adjustPoints(self, ...)
	end,
}

HelperObj=AIObj:subclass{
	solid=false,
	moveTowards=[:,destX,destY]do
		local deltax = destX-self.pos.x
		local deltay = destY-self.pos.y
		local absdeltax = math.abs(deltax)
		local absdeltay = math.abs(deltay)
		local dx = math.sign(deltax)
		local dy = math.sign(deltay)
		if dx and dy then
			if absdeltax > absdeltay then
				if not self:move(dx, 0) then return end
				dx=0	--try the other dir, move on to the rotate-and-test
			else
				if not self:move(0, dy) then return end
				dy=0	--try the other dir, move on to the rotate-and-test
			end
		end
		local result = self:move(dx, dy)
	end,
	update=[:]do
		if self.target then
			if self.target.hp<=0 then
				self.target=nil
			else
				if distL1(self.pos, self.target.pos)<=1 then
					self:attack(self.target.pos.x-self.pos.x,self.target.pos.y-self.pos.y)
				else
					self:moveTowards(self.target.pos.x,self.target.pos.y)
				end
				if self.target.hp<=0 then
					self.target=nil
				end
			end
		end
		if not self.target then
			if player then self:moveTowards(player.pos.x+math.random(-5,5),player.pos.y+math.random(-5,5)) end
			local searchRadius=5
			for y=self.pos.y-searchRadius,self.pos.y+searchRadius do
				for x=self.pos.x-searchRadius,self.pos.x+searchRadius do
					local tileObjs=thisMap:getTileObjs(x,y)
					if tileObjs then
						for _,obj in ipairs(tileObjs) do
							if MonsterObj:isa(obj) and obj.hostile then
								self.target=obj
							end
						end
					end
				end
			end
		end
	end,
}

GuardObj=TownNPCObj:subclass{
	spriteIndex=68,--'objs/fighter.png'
	msg='Stay in school!',
	hpMax=100,
	gold=100,
	physAttack=10,
	physHitChance=100,
	physEvade=60,
}

MerchantObj=TownNPCObj:subclass{
	spriteIndex=134,--'objs/merchant.png'
	hpMax=10,
	init=[:,args]do
		MerchantObj.super.init(self,args)
		if args.store then
			self.store=args.store
			self.itemClasses=assert(args.itemClasses)
			local items = table()
			for i=1,100 do
				local itemClass = self.itemClasses:pickRandom()
				if itemClass then	-- TODO this wasn't in the original
					items:insert(itemClass())
				end
			end

			items:sort([itemA,itemB]
				math.abs(itemA.cost - player.gold) < math.abs(itemB.cost - player.gold)
			)

			local numItems = math.random(10,20)
			for i=1,numItems do
				self.items:insert(items[i])
			end
		end
		self.msg = args.msg
	end,
	onInteract=[:,player]do
		MerchantObj.super.onInteract(self,player)
		local merchant=self
		if self.store then
			ClientPrompt({'Buy','Sell'}, [:,cmd,index]do
				if cmd == 'Buy' then
					local buyOptions = merchant.items:mapi([item,index] item.name.." ("..item.cost.." GP)")
					if #buyOptions == 0 then
						clientMessage"I have nothing to sell you!"
					else
						ClientPrompt(buyOptions, [:,cmd, index]do
							local item = merchant.items[index]
							--TODO 'how many?'
							if player.gold >= item.cost then
								player.gold -= item.cost
								clientMessage'Sold!'
								player.items:insert(item)
							else
								clientMessage"You can't afford that!"
							end
						end, [:,cmd, index]do
							local item = merchant.items[index]
							possibleEquipItem = item
							if EquipItem:isa(item) then
								if WeaponItem:isa(item) then possibleEquipField = 'rhand' end
								if ShieldItem:isa(item) then possibleEquipField = 'lhand' end
								if ArmorItem:isa(item) then possibleEquipField = 'body' end
								if HelmItem:isa(item) then possibleEquipField = 'head' end
								if RelicItem:isa(item) then possibleEquipField = 'relic2' end
							end
						end, [:]do
							possibleEquipField = nil
						end)
					end
				elseif cmd == 'Sell' then
					local sellScale = .5
					local sellOptions = player.items:mapi([item, index]
						item.name.." ("..math.ceil(item.cost * sellScale).." GP)"
					)
					if #sellOptions == 0 then
						clientMessage"You have nothing to sell me!"
					else
						ClientPrompt(sellOptions, [:,cmd,index]do
							local item = player.items[index]
							--TODO how many?
							player.gold += math.ceil(item.cost * sellScale)
							player.items:remove(index)
							clientMessage"Thanks!"
							self:close()	--TODO repopulate
						end)
					end
				end
			end)
		end
	end,
}

WarpObj=GameObj:subclass{
	solid=true,
	init=[:,args]do
		GameObj.super.init(self,args)
		self.destMap = args.destMap
		self.destPos = args.destPos
	end,
	onInteract=[:,player]do
		setMapRequest = {map=self.destMap}
		setMapRequest.pos = self.destPos
	end,
}

TownObj=WarpObj:subclass{
	spriteIndex=0,--'objs/town.png'
}

UpStairsObj=WarpObj:subclass{
	spriteIndex=260,--'objs/upstairs.png'
}

DownStairsObj=WarpObj:subclass{
	spriteIndex=66,--'objs/downstairs.png'
}

FireWallObj=GameObj:subclass{
	spriteIndex=70,--'objs/firewall.png'
	lightRadius=10,
	init=[:,args]do
		GameObj.super.init(self,args)
		self.life = math.random(10,100)
		self.caster = args.caster
	end,
	getLightRadius=[:] self.lightRadius * (math.random() * .5 + .5),
	update=[:]do
		self.life-=1
		if self.life <= 0 then self.remove = true end
	end,
	onTouch=[:,other]do
		if BattleObj:isa(other) then
			spells.Fire:useOnTarget(self.caster, other)
		end
	end,
}

FriendlyFrogObj=HelperObj:subclass{
	spriteIndex=74,--'objs/frog.png'
}

FriendlySnakeObj=HelperObj:subclass{
	spriteIndex=202,--'objs/snake.png'
	hpMax = 1,
	physEvade = 30,
	inflictAttributes = {'Poison'},
	damageType = 'pierce',
}

PopupObj=GameObj:subclass{
	update=[:]do
		self.remove = true
	end,
}

--[[
args:
	text
	x
	y
	outlineSize
--]]
drawOutlineText=[args]do
	for x=-1,1 do
		for y=-1,1 do
			text(args.text, args.x + x * args.outlineSize, args.y + y * args.outlineSize, 0xf0, -1)
		end
	end
	text(args.text, args.x, args.y, 0xfc, -1)
end

PopupText=PopupObj:subclass{
	color=0x1f,	-- rgb(255,0,0)
	init=[:,args]do
		PopupText.super.init(self,args)
		self.msg = args.msg
		self.color = args.color
	end,
	drawLocal=[:,rx,ry]do
		-- draw a circle at this location ... avg blended ... what color?
		blend(5)	-- avg w/solid color
		pokew(blendColorMem, self.color)
		elli(rx, ry, tileSize.x, tileSize.y)

		local fontSize = math.ceil(tileSize.x/2)
		local msgs = string.split(self.msg,' ')
		local y = ry + fontSize - 3
		for _,msg in ipairs(msgs) do
			local length = text(msg, -100, -100, -1, -1)
			drawOutlineText{
				text=msg,
				outlineSize=math.ceil(fontSize/16),
				x=rx+tileSize.x/2 - length/2,
				y=y,
			}
			y += fontSize
		end
		blend(-1)
	end,
}

--don't convert classes to self too hastily without making sure their image is precached
--I'm using self with Spell.use() and putting all spells.url's in the image precache
PopupSpellIcon=PopupObj:subclass{
	init=[:,args]do
		PopupSpellIcon.super.init(self,args)
		self.spriteIndex=args.spriteIndex
	end,
}

PopupSlashAttack=PopupObj:subclass{
	spriteIndex=10,--'objs/damage-slash.png'
}

PopupPierceAttack=PopupObj:subclass{
	spriteIndex=8,--url='objs/damage-pierce.png'
}

PopupBludgeonAttack=PopupObj:subclass{
	spriteIndex=6,--url='objs/damage-bludgeon.png'
}

DoorObj=GameObj:subclass{
	spriteIndex=64,--url='objs/door.png'
	solid=true,
	blocksLight=true,
	onInteract=[:,player]do
		self.remove = true
	end,
}

TreasureObj=GameObj:subclass{
	spriteIndex=256,--url='objs/treasure.png'
	solid=true,
	onInteract=[:,player]do
		local itemClass = itemClasses:pickRandom()

		--store trick: spawn 100, pick the closest to the player's gp level
		local item = itemClass()
		for i=1,100 do
			local newItem = itemClass()
			if math.abs(newItem.cost - player.gold) <= math.abs(item.cost - player.gold) then
				item = newItem
			end
		end

		clientMessage("you got "..item.name)
		player.items:insert(item)

		self.remove = true
	end,
}

SignObj=GameObj:subclass{
	solid=true,
}

WeaponSign=SignObj:subclass{
	spriteIndex=200,--url='objs/shop-weapon-sign.png'
}

ArmorSign=SignObj:subclass{
	spriteIndex=140,--url='objs/shop-armor-sign.png'
}

FoodSign=SignObj:subclass{
	spriteIndex=142,--url='objs/shop-food-sign.png'
}

ItemSign=SignObj:subclass{
	spriteIndex=194,--url='objs/shop-item-sign.png'
}

RelicSign=SignObj:subclass{
	spriteIndex=196,--url='objs/shop-relic-sign.png'
}

SpellSign=SignObj:subclass{
	spriteIndex=198,--url='objs/shop-spell-sign.png'
}

HealSign=SignObj:subclass{
	spriteIndex=192,--url='objs/shop-heal-sign.png'
}

--a list of all types that need graphics to be cached
objTypes = table{
	--hero
	HeroObj,
	--monsters
	OrcObj, ThiefObj, TroggleObj, FighterObj, SnakeObj, SeaMonsterObj, EnemyBoatObj,
	--DevilObj, WizardObj, BalrogObj,
	--wildlife:
	FishObj, DeerObj,
	--warps:
	TownObj, UpStairsObj, DownStairsObj,
	--town guys:
	MerchantObj, GuardObj,
	--spells:
	FireWallObj, FriendlyFrogObj, FriendlySnakeObj,
	--effects:
	DeadObj,
	--popups:
	PopupSlashAttack, PopupPierceAttack, PopupBludgeonAttack,
	--misc objs
	WeaponSign, ArmorSign, FoodSign, ItemSign, RelicSign, SpellSign, HealSign,
	DoorObj, TreasureObj,
}


-- attributes

Attribute=class{
	init=[:,target]do
		if self.lifeRange then self.life = math.random(table.unpack(self.lifeRange)) end
	end,
	update=[:,target]do
		if self.life then
			self.life-=1
			if self.life <= 0 then self.remove = true end
		end
	end,
}

attributes = {
	Attribute:subclass{
		name = "Don't Move",
		lifeRange = {5,10},
	},
	Attribute:subclass{
		name = "Poison",
		lifeRange = {10,20},
		update=[:,target, ...]do
			target:adjustPoints('hp', -math.ceil(target:stat'hpMax'/50))
			Attribute.update(self, target, ...)
		end,
	},
	Attribute:subclass{
		name = "Regen",
		lifeRange = {10,20},
		update=[:,target,...]do
			target:adjustPoints('hp', math.ceil(target:stat'hpMax'/50))
			Attribute.update(self, target, ...)
		end,
	},
	Attribute:subclass{
		name = "Light",
		lightRadius = 10,
		life = 100,
	},
}
for i,attr in ipairs(attributes) do
	attributes[attr.name] = attr
end


--spells

--[[
castingInfo:
	spell = current spell casting
	target = where it's being targetted
	dontCost = override costing mp (for scrolls)
	onCast = what to do upon casting it (for scrolls)
--]]
spellTargetKeyCallback=[key]do
	local nx = castingInfo.target.x
	local ny = castingInfo.target.y
	if key=='left' then nx-=1
	elseif key=='up' then ny-=1
	elseif key=='right' then nx+=1
	elseif key=='down' then ny+=1
	elseif key=='cancel' then
		castingInfo = nil
		keyCallback = nil
		return false
	elseif key=='ok' then
		castingInfo.spell:use(player, castingInfo.target)
		castingInfo = nil
		keyCallback = nil
		return true
	end
	if distL1(player.pos, vec2(nx,ny)) <= castingInfo.spell.range then
		castingInfo.target.x = nx
		castingInfo.target.y = ny
	end
	clientMessage("choose target for spell "..castingInfo.spell.name)
	return false
end

Spell=class{
	inflictAttributes = {},
	inflictChance = 1/4,
	clientUse=[:,args]do
		--prompt the user for a target location
		castingInfo = {}
		castingInfo.spell = self

		castingInfo.target = vec2(player.pos)
		if not self.targetSelf then
			local bestDist = self.range+1
			for y=player.pos.y-self.range,player.pos.y+self.range do
				for x=player.pos.x-self.range,player.pos.x+self.range do
					local tilePos = vec2(x,y)
					local tileDist = distL1(player.pos, tilePos)
					if tileDist <= self.range then
						local tileObjs=thisMap:getTileObjs(x,y)
						if tileObjs then
							for _,obj in ipairs(tileObjs) do
								if BattleObj:isa(obj) and obj.hostile then
									if tileDist < bestDist then
										bestDist = tileDist
										castingInfo.target = tilePos
									end
								end
							end
						end
					end
				end
			end
		end

		if args then
			for k,v in pairs(args) do
				castingInfo[k] = v
			end
		end
		clientMessage("choose target for spell "..castingInfo.spell.name)
		keyCallback	= spellTargetKeyCallback
	end,
	canPayFor=[:,caster]do
		if caster == player and castingInfo and castingInfo.dontCost then return true end
		return caster.mp >= self.cost
	end,
	payFor=[:,caster]do
		if caster == player and castingInfo and castingInfo.dontCost then return end
		caster.mp -= self.cost
	end,
	use=[:,caster, pos]do
		if not self:canPayFor(caster) then
			PopupText{msg='NO MP!', pos=caster.pos}
			return
		end
		self:payFor(caster)

		for y=pos.y-self.area,pos.y+self.area do
			for x=pos.x-self.area,pos.x+self.area do
				local tilePos=vec2(x,y)
				if distL1(pos, tilePos) <= self.area then
					local tile = thisMap:getTile(tilePos:unpack())
					local tileObjs=thisMap:getTileObjs(tilePos:unpack())
					self:useOnTile(caster, tile, tilePos, tileObjs)
				end
			end
		end
		if caster == player and castingInfo and castingInfo.onCast then
			castingInfo:onCast(caster)
		end
	end,
	useOnTile=[:,caster,tile,tilePos,tileObjs]do
		if self.spriteIndex then
			 PopupSpellIcon{pos=tilePos, spriteIndex=self.spriteIndex}
		end
		if tileObjs then
			for _,obj in ipairs(tileObjs) do
				if BattleObj:isa(obj) then
					self:useOnTarget(caster, obj)
				end
			end
		end
		if self.spawn then
			--don't allow solid spawned objects to spawn over other solid objects
			local blocking = false
			if self.spawn.solid then
				if tileObjs then
					for _,obj in ipairs(tileObjs) do
						if obj.solid then
							blocking = true
							break
						end
					end
				end
			end
			if not blocking then
				--spawn
				local spawnObj = self.spawn{pos=vec2(tilePos), caster=caster}
				--do an initial touch test
				if spawnObj.onTouch then
					for _,obj in ipairs(tileObjs) do
						spawnObj:onTouch(obj)
					end
				end
			end
		end
	end,
	useOnTarget=[:,caster, target]do
		if not self.alwaysHits and not caster:magicHitRoll(target) then
			 PopupText{msg='MISS!',pos=target.pos}
			return
		end
		if self.damage then
			target:adjustPoints('hp', -self.damage * caster:stat'magicAttack', caster)
		end
		if self.inflictAttributes then
			target:setAttributes(self.inflictAttributes)
		end
		if self.removeAttributes then
			target:removeAttributes(self.removeAttributes)
		end
	end,
}

spells=table{
	-- TODO get rid of these, and route the damage call from Fire Wall through spell itself some other way ...
	{name='Fire', damage=5, range=8, area=2, cost=1,
		spriteIndex=70,--url:'objs/firewall.png'},
	},
	{name='Ice', damage=5, range=8, area=2, cost=1,
		spriteIndex=70,--url:'objs/firewall.png'},
	},
	{name='Bolt', damage=5, range=8, area=2, cost=1,
		spriteIndex=70,--url:'objs/firewall.png'},
	},
	{name='Fire Wall', spawn=FireWallObj, range=5, area=2, cost=3},
	{name='Frog Wall', spawn=FriendlyFrogObj, range=10, area=3, cost=1, alwaysHits=true},
	{name='Snake Wall', spawn=FriendlySnakeObj, range=10, area=3, cost=2, alwaysHits=true},
	{name="Don't Move", inflictAttributes={"Don't Move"}, range=10, area=3, cost=3},
	{name="Poison", inflictAttributes={"Poison"}, damage=5, range=10, area=3, cost=3},
	{name="Heal", damage=-10, range=3, area=0, cost=3, targetSelf=true, alwaysHits=true},
	{name="Antidote", removeAttributes={"Poison"}, range=0, area=0, cost=1, targetSelf=true, alwaysHits=true},
	{name="Regen", inflictAttributes={"Regen"}, inflictChance=1, range=0, area=0, cost=1, targetSelf=true, alwaysHits=true},
	{name="Blink", range=20, area=0, cost=10, targetSelf=true, useOnTile=[:,caster,tile,tilePos,tileObjs]player:setPos(tilePos:unpack())},
	{name="Light", range=20, area=0, cost=1, targetSelf=true, inflictAttributes={"Light"}, inflictChance=1, alwaysHits=true},
}
for i,spellProto in ipairs(spells) do
	local spellClass = (spellProto.super or Spell):subclass(spellProto)
	local spell = spellClass()
	spells[i] = spell
	assert(not spells[spellProto.name], "got two spells with matching names: "..tostring(spellProto.name))
	spells[spellProto.name] = spell
end


-- items


weaponBaseTypes = table{
	{name='Derp', damageType='slash', fieldRanges={physAttack=1, physHitChance=5}},
	{name='Staff', damageType='bludgeon', fieldRanges={physAttack=1, physHitChance=10, magicAttack=5, magicHitChance=10}},
	{name='Dagger', damageType='slash', fieldRanges={physAttack=2, physHitChance=10}},
	{name='Sword', damageType='slash', fieldRanges={physAttack=3, physHitChance=15}},
	{name='Flail', damageType='bludgeon', fieldRanges={physAttack=4, physHitChance=20}},
	{name='Axe', damageType='slash', fieldRanges={physAttack=5, physHitChance=25}},
	--TODO range for these (targetting past the four cardinal directions)
	{name='Boomerang', damageType='bludgeon', fieldRanges={physAttack=6, physHitChance=30}},
	{name='Bow', damageType='pierce', fieldRanges={physAttack=7, physHitChance=35}},
	{name='Star', damageType='pierce', fieldRanges={physAttack=8, physHitChance=40, range=10}},
	{name='Crossbow', damageType='pierce', fieldRanges={physAttack=9, physHitChance=45, range=20}},
}

weaponModifiers = table{
	{name="Plain ol'"},
	{name='Short', fieldRanges={physAttack={0,5}, physHitChance={0,10}}},
	{name='Long', fieldRanges={physAttack={3,8}, physHitChance={5,15}}},
	{name='Heavy', fieldRanges={physAttack={3,8}, physHitChance={5,15}}},
	{name='Bastard', fieldRanges={physAttack={0,10}, physHitChance={10,20}}},
	{name='Demon', fieldRanges={physAttack={20,20}, physHitChance={30,35}}},
	{name='Were', fieldRanges={physAttack={20,25}, physHitChance={35,45}}},
	{name='Rune', fieldRanges={physAttack={30,35}, physHitChance={40,50}}},
	{name='Dragon', fieldRanges={physAttack={30,40}, physHitChance={40,50}}},
	{name='Quick', fieldRanges={physAttack={40,45}, physHitChance={90,100}}},
}
weaponModifierFields = table{'physAttack','physHitChance'}

defenseModifiers = table{
	{name="Cloth", fieldRanges={magicEvade=1, hpMax=1, physEvade=1}},
	{name="Leather", fieldRanges={magicEvade=2, hpMax=2, physEvade=2}},
	{name="Wooden", fieldRanges={magicEvade=3, hpMax=3, physEvade=3}},
	{name="Chain", fieldRanges={magicEvade=4, hpMax=4, physEvade=4}},
	{name="Plate", fieldRanges={magicEvade=5, hpMax=5, physEvade=5}},
	{name="Copper", fieldRanges={magicEvade=6, hpMax=6, physEvade=6}},
	{name="Iron", fieldRanges={magicEvade=7, hpMax=7, physEvade=7}},
	{name="Bronze", fieldRanges={magicEvade=8, hpMax=8, physEvade=8}},
	{name="Steel", fieldRanges={magicEvade=9, hpMax=9, physEvade=9}},
	{name="Silver", fieldRanges={magicEvade=10, hpMax=10, physEvade=10}},
	{name="Gold", fieldRanges={magicEvade=11, hpMax=11, physEvade=11}},
	{name="Crystal", fieldRanges={magicEvade=12, hpMax=12, physEvade=12}},
	{name="Opal", fieldRanges={magicEvade=13, hpMax=13, physEvade=13}},
	{name="Platinum", fieldRanges={magicEvade=14, hpMax=14, physEvade=14}},
	{name="Plutonium", fieldRanges={magicEvade=15, hpMax=15, physEvade=15}},
	{name="Adamantium", fieldRanges={magicEvade=16, hpMax=16, physEvade=16}},
	{name="Potassium", fieldRanges={magicEvade=17, hpMax=17, physEvade=17}},
	{name="Osmium", fieldRanges={magicEvade=18, hpMax=18, physEvade=18}},
	{name="Holmium", fieldRanges={magicEvade=19, hpMax=19, physEvade=19}},
	{name="Mithril", fieldRanges={magicEvade=20, hpMax=20, physEvade=20}},
	{name="Aegis", fieldRanges={magicEvade=21, hpMax=21, physEvade=21}},
	{name="Genji", fieldRanges={magicEvade=22, hpMax=22, physEvade=22}},
	{name="Pro", fieldRanges={magicEvade=23, hpMax=23, physEvade=23}},
	{name="Diamond", fieldRanges={magicEvade=24, hpMax=24, physEvade=24}},
}
armorBaseTypes = table{
	{name='Armor'},
}
armorModifiers = defenseModifiers
armorModifierFields = table{'magicEvade','physEvade','hpMax'}

helmBaseTypes = table{
	{name='Helm'},
}
helmModifiers = defenseModifiers
helmModifierFields = table{'magicEvade','physEvade'}

shieldBaseTypes = table{
	{name='Buckler'},
	{name='Shield', evadeRange={5,10}},
}
shieldModifiers = defenseModifiers
shieldModifierFields = table{'magicEvade','physEvade'}

Item=class{
	costPerField = {
		physAttack = 10,
		physHitChance = 5,
		physEvade = 3,
		magicEvade = 7,
		hpMax = 5,	--equipment uses hp/mp Max
		mpMax = 3,
		hp = .8,	--usable items use hp/mp
		mp = 2,
		food = .02,
	},
	init=[:]do
		if self.fieldRanges then self:applyRanges(self.fieldRanges) end
	end,
	applyRanges=[:,fieldRanges]do
		for field,rangeInfo in pairs(fieldRanges)do
			if type(rangeInfo)=='number' then
				rangeInfo={math.ceil(rangeInfo*.75), rangeInfo}
			end
			if self[field]==nil then self[field]=0 end
			local statValue=math.random(table.unpack(rangeInfo))
			self[field]+=statValue
			if self.costPerField[field] then
				if self.cost==nil then self.cost=0 end
				self.cost+=statValue*self.costPerField[field]
			end
		end
		if self.cost ~= nil then self.cost = math.ceil(self.cost) end
	end,
}

UsableItem=Item:subclass{
	use=[:]do
		local result
		if self.hp then player:adjustPoints('hp', self.hp) end
		if self.mp then player:adjustPoints('mp', self.mp) end
		if self.food then player:adjustPoints('food', self.food) end
		if self.attributes then player:setAttributes(self.attributes) end
		if self.removeAttributes then player:removeAttributes(self.removeAttributes) end
		--TODO player.giveSpell ... and have it up the spell level if the player already knows it
		if self.spellTaught then
			if player.spells:find(self.spellTaught) then
				clientMessage("You already know "..self.spellTaught.name)
				return 'keep'
			else
				clientMessage("You learned "..self.spellTaught.name)
				player.spells:insert(self.spellTaught)
				player.spells:sort([a,b] a.cost < b.cost)
			end
		end
		if self.spellUsed then
			-- don't have the item menu remove the scroll ...
			result='keep'
			self.spellUsed:clientUse{dontCost=true, onCast=[]do
				-- instead have the scroll removed if we can pay for it
				player.items:remove((player.items:find(self)))
			end}
		end
		return result
	end,
}

EquipItem=Item:subclass{
	init=[:,...] do
		EquipItem.super.init(self, ...)
		local name = nil
		local area = 0
		if self.baseTypes then
			local baseTypes = self.baseTypes
			local baseType = baseTypes:pickRandom()
			self.damageType = baseType.damageType
			if baseType.area ~= nil then area += baseType.area end
			if baseType.fieldRanges then	-- TODO this condition wasn't in the original ... why is it needed here?
				self:applyRanges(baseType.fieldRanges)
			end
			name = baseType.name
		end
		if self.modifiers then
			local modifiers = self.modifiers
			local modifier = modifiers:pickRandom()
			if modifier.area ~= nil then area += modifier.area end
			if modifier.fieldRanges then
				local modifierRanges={}
				if self.modifierFields then
					for _,field in ipairs(self.modifierFields) do
						modifierRanges[field]=modifier.fieldRanges[field]
					end
				end
				self:applyRanges(modifierRanges)
			end
			name = modifier.name..(name and ' '..name or '')
		end
		self.name = name
		self.attackOffsets = table{vec2(1,0)}
		local used = {}
		used[tostring(vec2(0,0))] = true
		used[tostring(vec2(1,0))] = true
		for i=1,area do
			for tries = 1,100 do
				local src = self.attackOffsets:pickRandom()
				local ofs = dirs:pickRandom().offset
				local dst = src+ofs
				local dstkey = tostring(dst)
				if not used[dstkey] then
					self.attackOffsets:insert(dst)
					used[dstkey] = true
					break
				end
			end
		end
		self.attackOffsets:remove(1)
	end,
}

WeaponItem=EquipItem:subclass{
	name = 'Weapon',
	type = 'weapon',
	baseTypes = weaponBaseTypes,
	modifiers = weaponModifiers,
	modifierFields = weaponModifierFields,
}

ArmorItem=EquipItem:subclass{
	name = 'Armor',
	type = 'armor',
	baseTypes = armorBaseTypes,
	modifiers = armorModifiers,
	modifierFields = armorModifierFields,
}

ShieldItem=EquipItem:subclass{
	name = 'Shield',
	type = 'shield',
	baseTypes = shieldBaseTypes,
	modifiers = shieldModifiers,
	modifierFields = shieldModifierFields,
}

HelmItem=EquipItem:subclass{
	name = 'Helm',
	type = 'helm',
	baseTypes = helmBaseTypes,
	modifiers = helmModifiers,
	modifierFields = helmModifierFields,
}

RelicItem=EquipItem:subclass{
	name = 'Relic',
	type = 'relic',
}

itemClasses = table{
	--potions
	UsableItem:subclass{name='Potion', fieldRanges={hp=25}},
	UsableItem:subclass{name='Big Potion', fieldRanges={hp=150}},
	UsableItem:subclass{name='Mana', fieldRanges={mp=25}},
	UsableItem:subclass{name='Big Mana', fieldRanges={mp=150}},
	UsableItem:subclass{name='Antidote', cost=10, removeAttributes={'Poison'}},
	UsableItem:subclass{name='Torch', cost=10, attributes={'Light'}},
	--food
	UsableItem:subclass{name='Apple', fieldRanges={food=100}},
	UsableItem:subclass{name='Bread', fieldRanges={food=200}},
	UsableItem:subclass{name='Cheese', fieldRanges={food=350}},
	UsableItem:subclass{name='Fish Fillet', fieldRanges={food=500}},
	UsableItem:subclass{name='Venison', fieldRanges={food=1000}},
	UsableItem:subclass{name='Steak', fieldRanges={food=2000}},
	--weapon
	WeaponItem,
	--shields, armor, helms
	ArmorItem,
	ShieldItem,
	HelmItem,
	--relics
	RelicItem:subclass{name='Flashlight', cost=500, lightRadius=20},
	RelicItem:subclass{name='MPify', cost=500, mpMaxModify=[:,value] value * 2, hpMaxModify=[:,value] math.ceil(value/2) },
	RelicItem:subclass{name='HPify', cost=500, hpMaxModify=[:,value] value * 2, mpMaxModify=[:,value] math.ceil(value/2) },
}
for _,spell in ipairs(spells) do
	itemClasses:insert(UsableItem:subclass{name=spell.name..' Book', cost=100, spellTaught=spell})
end
for _,spell in ipairs(spells) do
	itemClasses:insert(UsableItem:subclass{name=spell.name..' Scroll', cost=10, spellUsed=spell})
end
for _,itemClass in ipairs(itemClasses) do
	itemClasses[itemClass.name] = itemClass
end


-- tile types


Tile=class{
	init=[:,pos]do
		self.pos = vec2(pos)
	end,
}

-- indexes in the tilemap
tileTypes = {}
for _,tileType in ipairs{
	Tile:subclass{name='Grass', tileIndexes={0,2,4}},
	Tile:subclass{name='Bricks', tileIndexes={6}},
	Tile:subclass{name='Trees', tileIndexes={192}},
	Tile:subclass{name='Water', tileIndexes={128}, water=true},
	Tile:subclass{name='Stone', tileIndexes={66}, solid=true},
	Tile:subclass{name='Wall', tileIndexes={64}, solid=true},
} do
	-- key by name
	if tileTypes[tileType.name] then trace("tileTypes name "..tileType.name.." used twice!") end
	tileTypes[tileType.name] = tileType
	-- key by tilesheet index
	for _,tileIndex in ipairs(tileType.tileIndexes) do
		if tileTypes[tileIndex] then trace("tileTypes index "..tileIndex.." used twice") end
		tileType[tileIndex] = tileType
	end
end

Map=class{
	--[[
	args:
		name
		size
		onload
		exitMap
		temp
		wrap
		spawn
		resetObjs
		fixedObjs
		playerStart
		tileType
	--]]
	init=[:,args]do
		self.name = args!.name
		self.exitMap = args.exitMap
		self.temp = args.temp
		self.wrap = args.wrap
		self.spawn = args.spawn
		self.resetObjs=args.resetObjs
		self.fixedObjs=table(args.fixedObjs)
		if args.playerStart then self.playerStart=vec2(args.playerStart) end
		self.fogColor = args.fogColor

		self.size = vec2(args!.size)
		self.bbox = box2(vec2(), self.size-1)

		local tileType = args.tileType or tileTypes.Grass
		-- TODO only alloc what tiles have objs on them ... and use the tilemap for tile images ... then use map() for rendering ...
		-- tiles still holds...
		--  - the room (temporary for level generation)
		-- 	- the light level ... hmm ...
		self.tiles = {}
		for y=0,self.size.y-1 do
			local tilerow = {}
			self.tiles[y] = tilerow
			for x=0,self.size.x-1 do
				tilerow[x] = tileType(vec2(x,y))
				-- here or in setMap ?
				mset(x,y,assert(table.pickRandom(tileTypes![tileType.name].tileIndexes)))
			end
		end
		
		self.tileObjs={}

		maps:insert(self)
		maps[self.name] = self
		--local _ = args.onload?(self)	-- FIXME in langfix, make safe-navigation work in statements apart from assignment
		if args.onload then args.onload(self) end
	end,
	--wraps the position if the map is a wrap map
	--if not, returns false
	wrapPos=[:,pos]do
		pos.y = math.floor(pos.y)
		pos.x = math.floor(pos.x)
		if self.wrap then
			pos.y = ((pos.y % self.size.y) + self.size.y) % self.size.y
			pos.x = ((pos.x % self.size.x) + self.size.x) % self.size.x
		else
			if pos.x < 0 or pos.y < 0
			or pos.x >= self.size.x or pos.y >= self.size.y
			then
				return false
			end
		end
		return true
	end,
	getTile=[:,x,y]do
		local pos = vec2(x,y)
		if not self:wrapPos(pos) then return end
		return self.tiles[pos.y][pos.x]
	end,
	getTileType=[:,x,y]do
		error'TODO'	
		--[[
		It seems ideal to mget() this, but don't forget that only the current map is in mget memory
		Reading multiple maps from ROM memory brings up the question of how to store multiple tilemap resources ...
		That brings up the question ... 
			one tilemap chunk-per-bank and multiple banks , like TIC-80?
			or multiple banks that can be assigned to anything, and a tilemap-bank is one option (less wasteful of memory) ?
			or just have the ROM one giant arbitrary blob, put a FAT somewhere, and have it point to locations for arbitray-sized tilemaps? ...  this might mean extra overhead for the FAT.
		--]]
	end,
	setTileType=[:,x,y,tileType]do
		local pos = vec2(x,y)
		if not self:wrapPos(pos) then return end
		local tile = tileType(pos)
		self.tiles[pos.y][pos.x] = tile
		mset(pos.x,pos.y,assert(table.pickRandom(tileTypes![tileType.name].tileIndexes)))
		return tile
	end,
	--[[
	args:
		pos
		range,
		callback
	--]]
	floodFill=[:,args]do
		local allTiles = {}
		local startPos = vec2(args.pos)
		local startTile = self:getTile(startPos:unpack())
		local startInfo = {tile=startTile, pos=startPos, dist=0}
		args.callback(startInfo.tile, startInfo.dist, self:getTileObjs(startPos:unpack()))
		allTiles[tostring(startPos)] = startInfo
		local currentset = table{startInfo}
		while #currentset > 0 do
			local nextset = table()
			for _,currentInfo in ipairs(currentset) do
				local nextDist = currentInfo.dist + 1
				if nextDist <= args.maxDist then
					for j,dir in ipairs(dirs) do
						local nextPos = currentInfo.pos + dir.offset
						if self:wrapPos(nextPos) then
							local nextkey = tostring(nextPos)
							if not allTiles[nextkey] then
								local tile = self:getTile(nextPos:unpack())
								local nextInfo = {tile=tile, pos=nextPos, dist=nextDist}
								allTiles[nextkey] = true
								if args.callback(tile, nextDist, self:getTileObjs(nextPos:unpack())) then
									nextset:insert(nextInfo)
								end
							end
						end
					end
				end
			end
			currentset = nextset
		end
	end,
	
	getTileObjs=[:,x,y]do
		local pos=vec2(x,y)
		if not self:wrapPos(pos) then return end
		local tileObjsRow=self.tileObjs[pos.y]
		if not tileObjsRow then return end
		return tileObjsRow[pos.x]
	end,
	addObjToTile=[:,obj]do
		local pos=vec2(obj.pos)
		if not self:wrapPos(pos) then return end
		local tileObjsRow=self.tileObjs[pos.y]
		if not tileObjsRow then 
			tileObjsRow={}
			self.tileObjs[pos.y]=tileObjsRow
		end
		local tileObjs=tileObjsRow[pos.x]
		if not tileObjs then
			tileObjs=table()
			tileObjsRow[pos.x]=tileObjs
		end
		tileObjs:insertUnique(obj)
	end,
	removeObjFromTile=[:,obj]do
		local pos=vec2(obj.pos)
		if not self:wrapPos(pos) then return end
		local tileObjsRow=self.tileObjs[pos.y]
		if not tileObjsRow then return end
		local tileObjs=tileObjsRow[pos.x]
		if not tileObjs then return end
		tileObjs:removeObject(obj)
		if #tileObjs==0 then
			tileObjsRow[pos.x]=nil
			if not next(tileObjsRow) then
				self.tileObjs[pos.y]=nil
			end
		end
	end,
	
	pathfind=[:,start, finish]do
		if not self:wrapPos(start) then return end
		if not self:wrapPos(finish) then return end
		local srcX = start.x
		local srcY = start.y
		local dstX = finish.x
		local dstY = finish.y

		local srcpos = vec2(srcX, srcY)
		local currentset = table{{pos=srcpos}}
		local alltiles = {}	--keys are serialized vectors
		alltiles[tostring(srcpos)] = true

		while #currentset > 0 do
			--[[
			for all current options
			test neighbors
			if any are not in all tiles then add it to the next set and to the all tiles
			--]]
			local nextset = table()
			for _,currentmove in ipairs(currentset) do
				for dirIndex,dir in ipairs(dirs) do
					local nextpos = currentmove.pos + dir.offset
					if self:wrapPos(nextpos) then
						if nextpos.x == dstX and nextpos.y == dstY then
							--process the list and return it
							local rpath = table{nextpos, currentmove.pos}
							local src = currentmove.src
							while src do
								rpath:insert(src.pos)
								src = src.src
							end
							return rpath:reverse()
						end
						local nextkey = tostring(nextpos)
						if not alltiles[nextkey] then
							local tile = self.tiles[nextpos.y][nextpos.x]
							if not (tile.solid or tile.water) then
								alltiles[nextkey] = true
								nextset:insert{pos=nextpos, src=currentmove}
							end
						end
					end
				end
			end
			currentset = nextset
		end
	end,
}


--[[
args:
	map
	classify
	bbox <- default: range
--]]
pickFreeRandomFixedPos=[args]do
	local targetMap = args.map
	local bbox = box2(args.bbox or targetMap.bbox)
	local classify = args.classify

	for attempt=1,1000 do
		local pos = randomBoxPos(bbox)
		local tile = targetMap:getTile(pos.x, pos.y)

		local good
		if classify then
			good = classify(tile)
		else
			good = not (tile.solid or tile.water)
		end
		if good then
			local found = false
			for _,obj in ipairs(targetMap.fixedObjs) do
				if obj.pos == pos then
					found = true
					break
				end
			end
			if not found then
				return pos
			end
		end
	end
	trace"failed to find free position"
	return vec2()
end

findFixedObj=[targetMap,callback]do
	for _,fixedObj in ipairs(targetMap.fixedObjs) do
		if callback(fixedObj) then return fixedObj end
	end
end

--[[
args:
	name
	size
	temp
	healer
	stores
	world
	worldPos
--]]
genTown=[args]do
	local world = args.world
	world.fixedObjs:insert{
		type=TownObj,
		pos=args.worldPos,
		destMap=args.name,
	}

	local newMap=Map{
		name=args.name,
		size=vec2(args.size),
		temp=args.temp,
		exitMap=world.name,
		resetObjs=true,
	}
	newMap.playerStart=vec2(math.floor(newMap.size.x/2), newMap.size.y-2)
	local border = 3
	local entrance = 6
	for y=0,newMap.size.y-1 do
		for x=0,newMap.size.x-1 do
			if x < border or y < border or y >= newMap.size.y-border then
				if math.abs(x-newMap.size.x/2) >= entrance then
					newMap:setTileType(x,y,tileTypes.Stone)
				end
			elseif x >= newMap.size.x-border then
				newMap:setTileType(x,y,tileTypes.Water)
			end
		end
	end

	newMap.fixedObjs:insert{
		type=GuardObj,
		pos=vec2(math.floor(newMap.size.x/2-entrance)+2, newMap.size.y-2),
	}

	newMap.fixedObjs:insert{
		type=GuardObj,
		pos=vec2(math.floor(newMap.size.x/2+entrance)-2, newMap.size.y-2),
	}

	local brickradius=3
	local buildBricksAround=[pos]do
		local minx = pos.x - brickradius
		local miny = pos.y - brickradius
		local maxx = pos.x + brickradius
		local maxy = pos.y + 1
		if minx < 0 then minx = 0 end
		if miny < 0 then miny = 0 end
		if maxx >= newMap.size.x then maxx = newMap.size.x-1 end
		if maxy >= newMap.size.y then maxy = newMap.size.y-1 end
		for y=miny,maxy do
			for x=minx,maxx do
				if tileTypes.Grass:isa(newMap:getTile(x,y)) then
					if distLInf(pos,{x=x,y=y}) == math.ceil(brickradius/2) and y <= pos.y then
						newMap:setTileType(x,y,tileTypes.Wall)
					else
						newMap:setTileType(x,y,tileTypes.Bricks)
					end
				end
			end
		end
	end

	local dockGuy = {
		type=MerchantObj,
		pos=vec2(newMap.size.x-border-brickradius-1, math.random(border+1, newMap.size.y-border-2)),
		onInteract=[:,player]do
			if not storyInfo.foundPrincess then
				clientMessage("I'm the guy at the docks")
			else
				clientMessage("We're sailing for the capitol! All set?")
				local prompt = clientPrompt({'No','Yes'}, [cmd,index]do
					prompt:close()
					if cmd=='Yes' then
						--TODO make the player a boat ...
						setMapRequest={map='World'}
					end
				end)
			end
		end,
	}
	buildBricksAround(dockGuy.pos)
	newMap.fixedObjs:insert(dockGuy)

	local pathwidth = 1
	local npcBrickRadius = 3
	local findNPCPos = []
		pickFreeRandomFixedPos{
			map=newMap,
			classify=[tile] tileTypes.Grass:isa(tile),
			bbox=box2(
				 vec2(border+npcBrickRadius+1, border+npcBrickRadius+1),
				 vec2(newMap.size.x-border-npcBrickRadius-2,newMap.size.y-border-npcBrickRadius-3)
			),
		}

	local storyGuy = {
		type=MerchantObj,
		pos=findNPCPos(),
		onInteract=[:,player]do
			if not storyInfo.foundPrincess then
				clientMessage("They stole the princess! Follow the brick path and you'll find them!")
			else
				clientMessage("Thank you for saving her! Now you must take her to the capital. Talk to the guy at the dock to take the next boat out of town.")
			end
		end,
	}
	buildBricksAround(storyGuy.pos)
	newMap.fixedObjs:insert(storyGuy)

	local signOffset = vec2(-2,0)

	if args.healer then
		local healerGuy = {
			type=MerchantObj,
			pos=findNPCPos(),
			onInteract=[:,player]do
				local cost = 1
				if player.hp == player:stat'hpMax' and player.mp == player:stat'mpMax' then
					clientMessage("Come back when you need a healin'!")
				elseif player.gold >= cost then
					player.gold -= cost
					player:adjustPoints('mp', math.ceil(player:stat'mpMax'/5))
					player:adjustPoints('hp', math.ceil(player:stat'hpMax'/5))
					clientMessage("Heal yo self!")
				else
					clientMessage("No free lunches!!! One coin please!")
				end
			end,
		}
		buildBricksAround(healerGuy.pos)
		newMap.fixedObjs:insert(healerGuy)
		newMap.fixedObjs:insert{
			type=HealSign,
			pos=healerGuy.pos + signOffset,
		}
	end

	if args.stores then
		for _,storeInfo in ipairs(args.stores) do
			local storeGuy = {
				type=MerchantObj,
				pos=findNPCPos(),
				store=true,
				itemClasses=storeInfo.itemClasses,
				msg=storeInfo.msg,
			}
			buildBricksAround(storeGuy.pos)
			newMap.fixedObjs:insert(storeGuy)
			newMap.fixedObjs:insert{
				type=storeInfo.signType,
				pos=storeGuy.pos + signOffset,
			}
		end
	end

	for y=0,newMap.size.y-1 do
		for x=math.floor(newMap.size.x/2)-pathwidth, math.floor(newMap.size.x/2)+pathwidth do
			if tileTypes.Grass:isa(newMap:getTile(x,y)) then
				newMap:setTileType(x,y,tileTypes.Bricks)
			end
		end
	end

	for _,fixedObj in ipairs(newMap.fixedObjs) do
		if fixedObj.type == MerchantObj then
			for x=math.min(fixedObj.pos.x, math.floor(newMap.size.x/2)),math.max(fixedObj.pos.x, math.floor(newMap.size.x/2)) do
				for y=fixedObj.pos.y-pathwidth,fixedObj.pos.y+pathwidth do
					if x >= 0 and y >= 0 and x < newMap.size.x and y < newMap.size.y then
						if tileTypes.Grass:isa(newMap:getTile(x,y)) then
							newMap:setTileType(x,y,tileTypes.Bricks)
						end
					end
				end
			end
		end
	end

	maps:insert(newMap)

	return newMap
end


genDungeonLevel=[targetMap,prevMapName,nextMapName,avgRoomSize]do
	local rooms = table()

	--trace("begin gen "+targetMap.name)

	local max = math.floor(targetMap.size.x * targetMap.size.y / avgRoomSize)
	for i=1,max do
		local room = {pos=randomBoxPos(targetMap.bbox)}
		room.bbox = box2(room.pos, room.pos)
		rooms:insert(room)
		targetMap.tiles[room.pos.y][room.pos.x].room = room
	end

	local modified
	repeat
		modified=false
		for j,room in ipairs(rooms) do
			local bbox = box2(room.bbox.min-1, room.bbox.max+1):clamp(targetMap.bbox)
			local roomcorners = {room.bbox.min, room.bbox.max}
			local corners = {bbox.min, bbox.max}
			for i,corner in ipairs(corners) do
				local found = false
				for y=room.bbox.min.y,room.bbox.max.y do
					if targetMap.tiles[y][corner.x].room then
						found = true
						break
					end
				end
				if not found then
					for y=room.bbox.min.y,room.bbox.max.y do
						targetMap.tiles[y][corner.x].room = room
					end
					roomcorners[i].x = corner.x
					modified = true
				end

				found = false
				for x=room.bbox.min.x,room.bbox.max.x do
					if targetMap.tiles[corner.y][x].room then
						found = true
						break
					end
				end
				if not found then
					for x=room.bbox.min.x,room.bbox.max.x do
						targetMap.tiles[corner.y][x].room = room
					end
					roomcorners[i].y = corner.y
					modified = true
				end
			end
		end
	until not modified

	--clear tile rooms for reassignment
	for y=0,targetMap.size.y-1 do
		for x=0,targetMap.size.x-1 do
			targetMap.tiles[y][x].room = nil
		end
	end

	--carve out rooms
	--console.log("carving out rooms")
	for i=#rooms,1,-1 do
		local room = rooms[i]
		room.bbox.min.x+=1
		room.bbox.min.y+=1

		--our room goes from min+1 to max-1
		--so if that distance is zero then we have no room
		local dead = (room.bbox.min.x > room.bbox.max.x) or (room.bbox.min.y > room.bbox.max.y)
		if dead then
			rooms:remove(i)
		else
			for y=room.bbox.min.y,room.bbox.max.y do
				for x=room.bbox.min.x,room.bbox.max.x do
					targetMap:setTileType(x,y,tileTypes.Bricks)
				end
			end

			--rooms
			for y=room.bbox.min.y,room.bbox.max.y do
				for x=room.bbox.min.x,room.bbox.max.x do
					targetMap.tiles[y][x].room = room
				end
			end
		end
	end


	local dimfields = {'x','y'}
	local minmaxfields = {'min','max'}
	--see what rooms touch other rooms
	--trace("finding neighbors")
	local pos = vec2()
	for _,room in ipairs(rooms) do
		room.neighbors = table()
		for dim,dimfield in ipairs(dimfields) do
			local dimnextfield = dimfields[dim%2+1]
			for minmax,minmaxfield in ipairs(minmaxfields) do
				local minmaxofs = minmax * 2 - 3
				pos[dimfield] = room.bbox[minmaxfield][dimfield] + minmaxofs
				for tmp=room.bbox.min[dimnextfield]+1,room.bbox.max[dimnextfield]-1 do
					pos[dimnextfield]=tmp
					--step twice to find our neighbor
					local nextpos = vec2(pos)
					nextpos[dimfield] += minmaxofs
					local tile = targetMap:getTile(nextpos.x,nextpos.y)
					if tile
					and tile.room
					then
						local neighborRoom = tile.room
						local neighborRoomIndex = assert(rooms:find(neighborRoom), "found unknown neighbor room")
						local _, neighbor = room.neighbors:find(nil, [neighbor] neighbor.room == neighborRoom)
						if not neighbor then
							neighbor = {room=neighborRoom, positions=table()}
							room.neighbors:insert(neighbor)
						end
						neighbor.positions:insert(vec2(pos))
					end
				end
			end
		end
	end

	--pick a random room as the start
	--TODO start in a big room.
	local startRoom = rooms:pickRandom()
	local lastRoom = startRoom

	local leafRooms = table()
	local usedRooms = table{startRoom}

	--trace("establishing connectivity")
	while true do
		local srcRoomOptions = usedRooms:filter([room]
			--if the room has no rooms that haven't been used,then don't consider it
			--so keep all of the neighbor's neighbors that haven't been used
			--if self has any good neighbors then consider it
			#room.neighbors:filter([neighborInfo]
				not usedRooms:find(neighborInfo.room)
			) > 0
		)
		if #srcRoomOptions == 0 then break end
		local srcRoom = srcRoomOptions:pickRandom()

		local leafRoomIndex = leafRooms:find(srcRoom)
		if leafRoomIndex ~= -1 then leafRooms:remove(leafRoomIndex) end

		--self is the same filter as is within the srcRoomOptions filter -=1 so if you want to cache self info, feel free
		local neighborInfoOptions = srcRoom.neighbors:filter([neighborInfo]
			not usedRooms:find(neighborInfo.room)
		)
		local neighborInfo = neighborInfoOptions:pickRandom()
		local dstRoom = neighborInfo.room
		lastRoom = dstRoom
		--so find dstRoom in srcRoom.neighbors
		local pos = neighborInfo.positions:pickRandom()
		targetMap:setTileType(pos.x, pos.y, tileTypes.Bricks)
		targetMap.fixedObjs:insert{
			pos=pos,
			type=DoorObj,
		}
		usedRooms:insert(dstRoom)
		leafRooms:insert(dstRoom)
	end

	--[[
	for (local y = 0; y < targetMap.size.y; y+=1) {
		for (local x = 0; x < targetMap.size.x; x+=1) {
			delete targetMap.tiles[y][x].room
		}
	}
	--]]

	local upstairs = {
		type=UpStairsObj,
		pos=pickFreeRandomFixedPos{map=targetMap, bbox=startRoom.bbox},
		destMap=prevMapName,
	}
	targetMap.fixedObjs:insert(upstairs)
	targetMap.playerStart=upstairs.pos
	if nextMapName then
		targetMap.fixedObjs:insert{
			type=DownStairsObj,
			pos=pickFreeRandomFixedPos{map=targetMap, bbox=lastRoom.bbox},
			destMap=nextMapName,
		}
	else
		--add a princess or a key or a crown or something stupid
		targetMap.fixedObjs:insert{
			type=MerchantObj,
			pos=pickFreeRandomFixedPos{map=targetMap, bbox=lastRoom.bbox},
			msg='Tee Hee! Take me back to the village',
			onInteract=[:,player]do
				-- so much for ES6 OOP being more useful than hacked-together original JS prototypes...
				-- can't call super here even if self function is added to a class prototype
				MerchantObj.onInteract(self, arguments)
				player:adjustPoints('hp', player:stat'hpMax')
				-- unlock the next story point
				--TODO quests?
				storyInfo.foundPrincess = true
				self.remove = true
			end,
		}
	end

	--add treasure - after stairs so they get precedence
	for _,room in ipairs(usedRooms) do
		if room ~= startRoom
		and room ~= lastRoom
		and math.random() <= .5
		then
			targetMap.fixedObjs:insert{
				type=TreasureObj,
				pos=pickFreeRandomFixedPos{map=targetMap, bbox=room.bbox},
			}
		end
	end

	--trace("end gen "+targetMap.name)
end

--[[
args:
	prefix - name prefix (1..n appended to it for each level)
	depth - how many levels deep
	size
	spawn
	tempRange : {from:#, to:#}
	world
	worldPos
	avgRoomSize
--]]
genDungeon=[args]do
	local world = args.world
	world.fixedObjs:insert{
		type=TownObj,
		pos=args.worldPos,
		destMap=args.prefix..'1',
	}

	local avgRoomSize = args.avgRoomSize or 20

	--trace("generating dungeon stack "+args.prefix)
	local depth = args.depth or 1
	local firstMap
	for i=0,depth-1 do
		local newMap=Map{
			name=args.prefix..(i+1),
			size= vec2(args.size),
			spawn=args.spawn,	--all keeping the same copy for now
			temp=args.temp.to*i/depth + args.temp.from*(depth-1-i)/depth,
			tileType=tileTypes.Wall,
			fogColor=0xf0,	--black
			fogDecay=.01,
		}
		if not firstMap then firstMap=newMap end

		local prevMapName = nil
		local nextMapName = nil
		if i == 0 then
			prevMapName = 'World'
		else
			prevMapName = args.prefix..i
		end
		if i < depth-2 then nextMapName = args.prefix..(i+2) end
		genDungeonLevel(newMap, prevMapName, nextMapName, avgRoomSize)

		--after generating it and before adding it
		--modify all warps to self dungeon -=1 give them the appropriate location
		if i == 0 then
			for j,othermap in ipairs(maps) do
				if othermap.fixedObjs then
					for k,fixedObj in ipairs(othermap.fixedObjs) do
						if fixedObj.destMap == args.prefix..'1' then
							for l=1,#newMap.fixedObjs do
								if newMap.fixedObjs[l].type == UpStairsObj then
									fixedObj.destPos = newMap.fixedObjs[l].pos
									break
								end
							end
						end
					end
				end
			end
		end
		maps:insert(newMap)
	end

	--trace("done with "+args.prefix)
	return firstMap
end

--[[
args:
	name
	size
	temp

start it out
--]]

drawGrassBlob=[targetMap,cx,cy,r]do
	local extra = 3
	local sr = r + extra
	for dy=-sr,sr do
		for dx=-sr,sr do
			local x = dx + cx
			local y = dy + cy
			local rad = math.sqrt(dx*dx + dy*dy)
			rad -= extra*(1+noise(x/10,y/10))
			if rad <= r then
				local mx = (x + targetMap.size.x) % targetMap.size.x
				local my = (y + targetMap.size.y) % targetMap.size.y
				targetMap:setTileType(mx, my, tileTypes.Grass)
			end
		end
	end
end

initMaps=[]do
	-- randgen world
	local worldBaseSpawnRate = .02
	local world = Map{
		name='World',
		size=vec2(256,256),	-- but not all is used ... ... hmm
		temp=70,
		tileType=tileTypes.Water,
		wrap=true,
		spawn={
			{type=OrcObj, rate=worldBaseSpawnRate},
			{type=ThiefObj, rate=worldBaseSpawnRate/10},
			{type=TroggleObj, rate=worldBaseSpawnRate/20},
			{type=FighterObj, rate=worldBaseSpawnRate/30},
			{type=FishObj, rate=worldBaseSpawnRate/20},
			{type=DeerObj, rate=worldBaseSpawnRate/20},
			{type=SeaMonsterObj, rate=worldBaseSpawnRate/40},
			{type=EnemyBoatObj, rate=worldBaseSpawnRate/80}
		},
	}

	local grassRadius = 15
	local townGrassPos = randomBoxPos(world.bbox)
	local dungeonDist = 10
	local dungeonPos = vec2(
		math.random(-2*dungeonDist,-dungeonDist),
		math.random(-dungeonDist,dungeonDist)
	) + townGrassPos
	local delta = dungeonPos - townGrassPos
	local divs = math.ceil(math.max(math.abs(delta.x), math.abs(delta.y)))
	for i=0,divs do
		local frac = i / divs
		local x = math.floor(townGrassPos.x + delta.x * frac + .5)
		local y = math.floor(townGrassPos.y + delta.y * frac + .5)
		--TODO single ellipsoid with control points at townGrassPos and dungeonPos
		drawGrassBlob(world, x, y, grassRadius)
	end
	--TODO then trace from townGrassPos to the sea

	local townPos = vec2(townGrassPos)
	while tileTypes.Grass:isa(world:getTile(townPos.x,townPos.y)) do
		townPos.x+=1
	end
	world.playerStart=townPos-vec2(1,0)

	local isWeapon=[itemClass] WeaponItem:isa(itemClass)
	local isRelic=[itemClass] RelicItem:isa(itemClass)
	local isArmor=[itemClass] not isWeapon(itemClass) and not isRelic(itemClass) and EquipItem:isa(itemClass)	--all else
	local isFood=[itemClass] (UsableItem:isa(itemClass) and itemClass.food) or (itemClass.fieldRanges and itemClass.fieldRanges.food)
	local isSpell=[itemClass] UsableItem:isa(itemClass) and itemClass.spellUsed or itemClass.spellTaught
	local isMisc=[itemClass] UsableItem:isa(itemClass) and not isFood(itemClass) and not isSpell(itemClass)

	local town = genTown{
		world=world,
		worldPos=townPos,
		name='Helpless Village',
		size=vec2(32,32),
		temp=70,
		healer=true,
		--TODO gen a whole bunch of items, then divy them up (rather than searching through their prototypes and trying to predict their behavior)
		stores={
			{signType=WeaponSign, itemClasses=itemClasses:filter(isWeapon), msg='Weapons for sale'},
			{signType=RelicSign, itemClasses=itemClasses:filter(isRelic), msg='Relics for sale'},
			{signType=ArmorSign, itemClasses=itemClasses:filter(isArmor), msg='Armor for sale'},
			{signType=FoodSign, itemClasses=itemClasses:filter(isFood), msg='Welcome to the food library. Foooood liiibraaary.'},
			{signType=SpellSign, itemClasses=itemClasses:filter(isSpell), msg='Double, double, toil and trouble...'},
			{signType=ItemSign, itemClasses=itemClasses:filter(isMisc), msg='Items for sale'}
		},
	}

	local dungeonBaseSpawnRate = .1
	local dungeon = genDungeon{
		world=world,
		worldPos=dungeonPos,
		prefix='DungeonA',
		depth=16,
		size=vec2(64,64),
		avgRoomSize=100,
		spawn={
			{type=OrcObj, rate=dungeonBaseSpawnRate},
			{type=SnakeObj, rate=dungeonBaseSpawnRate/2},
			{type=FighterObj, rate=dungeonBaseSpawnRate/10},
		},
		temp={from=70, to=40},
	}

	local townFixedObj = findFixedObj(world, [fixedObj] fixedObj.destMap == town.name)
	local dungeonFixedObj = findFixedObj(world, [fixedObj] fixedObj.destMap == dungeon.name )
	--now pathfind from townFixedObj.pos to dungeonFixedObj.pos, follow the path, and fill it in as brick
	local path = world:pathfind(townFixedObj.pos, dungeonFixedObj.pos)
	if not path then
		trace("from",townFixedObj.pos,"to",dungeonFixedObj.pos)
	else
		for _,pos in ipairs(path) do
			world:setTileType(pos.x, pos.y, tileTypes.Bricks)
		end
	end

	--put rocks around the town
	local rockRadius = 3
	for y=townFixedObj.pos.y-rockRadius,townFixedObj.pos.y+rockRadius do
		for x=townFixedObj.pos.x-rockRadius,townFixedObj.pos.x+rockRadius do
			local tile = world:getTile(x,y)
			if tileTypes.Grass:isa(tile) then
				if distLInf(townFixedObj.pos,{x=x,y=y}) <= 1 then
					world:setTileType(x,y,tileTypes.Bricks)
				else
					world:setTileType(x,y,tileTypes.Stone)
				end
			end
		end
	end

	--now sprinkle in trees
	for y=0,world.size.y-1 do
		for x=0,world.size.x-1 do
			if tileTypes.Grass:isa(world:getTile(x,y)) then
				if math.random() < (noise(x/20,y/20)+1)*.5 - .1 then
					world:setTileType(x,y,tileTypes.Trees)
				end
			end
		end
	end

	--and add a mountain range or two ...
end

drawTextBlock=[msgs, x, y, floatRight]do
	local maxWidth = 0
	for j,msg in ipairs(msgs) do
		maxWidth = math.max(maxWidth, text(msg, -100, -100))
	end

	local rectx = x
	if floatRight then rectx -= maxWidth end

	blend(3)
	rect(rectx, y, maxWidth, fontSize * #msgs, 0xfe)
	blend(-1)

	for j,msg in ipairs(msgs) do
		local rowx = x
		if floatRight then
			local width = text(msg, -100, -100)
			rowx -= width
		end
		drawOutlineText{
			text=msg,
			outlineSize=math.ceil(fontSize/16),
			x=rowx,
			y=y,
		}
		y += fontSize
	end
end

showMenu=true
draw=[]do
	if not player then return end

	view.center:set(player.pos)
	if castingInfo then view.center:set(castingInfo.target) end

	cls(0xf0)

	local widthInTiles = math.floor(screenSize.x / tileSize.x)
	local heightInTiles = math.floor(screenSize.y / tileSize.y)
	view.bbox.min.x = math.ceil(view.center.x - widthInTiles / 2)
	view.bbox.min.y = math.ceil(view.center.y - heightInTiles / 2)
	if not thisMap.wrap then
		if view.bbox.min.x + widthInTiles >= thisMap.size.x then view.bbox.min.x = thisMap.size.x - widthInTiles end
		if view.bbox.min.y + heightInTiles >= thisMap.size.y then view.bbox.min.y = thisMap.size.y - heightInTiles end
		if view.bbox.min.x < 0 then view.bbox.min.x = 0 end
		if view.bbox.min.y < 0 then view.bbox.min.y = 0 end
	end
	view.bbox.max.x = view.bbox.min.x + widthInTiles
	view.bbox.max.y = view.bbox.min.y + heightInTiles
	if not thisMap.wrap then
		if view.bbox.max.x >= thisMap.size.x then view.bbox.max.x = thisMap.size.x-1 end
		if view.bbox.max.y >= thisMap.size.y then view.bbox.max.y = thisMap.size.y-1 end
	end
	--draw tiles first
	map(view.bbox.min.x,		-- tilemap pos
		view.bbox.min.y,
		view.bbox.max.x - view.bbox.min.x + 1,	-- tilemap size
		view.bbox.max.y - view.bbox.min.y + 1,
		0, 0,					-- screen pos
		0,						-- tilemap index offset
		true					-- 16x16
	)
	for y=view.bbox.min.y,view.bbox.max.y do
		for x=view.bbox.min.x,view.bbox.max.x do
			local tileObjs = thisMap:getTileObjs(x,y)
			if tileObjs then
				for _,obj in ipairs(tileObjs) do
					if obj.draw then obj:draw() end
				end
			end
		end
	end

	local ry=0
	if thisMap.fogColor then
		blend(6)	-- set to subtract
		local ry=0
		for y=view.bbox.min.y,view.bbox.max.y do
			local rx=0
			for x=view.bbox.min.x,view.bbox.max.x do
				local tile = thisMap:getTile(x,y)
				local light = 0
				if tile.light then
					light = tile.light
				end
				local darkness = math.floor((1 - math.clamp(light,0,1)) * 31)
				pokew(blendColorMem, darkness|(darkness<<5)|(darkness<<10))
				rect(rx * tileSize.x, ry * tileSize.y, tileSize.x, tileSize.y, 0xf0)
				rx+=1
			end
			ry+=1
		end
		blend(-1)
	end

	if castingInfo then
		blend(5)
		for y=player.pos.y-castingInfo.spell.range,player.pos.y+castingInfo.spell.range do
			for x=player.pos.x-castingInfo.spell.range,player.pos.x+castingInfo.spell.range do
				if distL1(player.pos, vec2(x,y))<=castingInfo.spell.range then
					local rx = (x - view.bbox.min.x) * tileSize.x
					local ry = (y - view.bbox.min.y) * tileSize.y
					pokew(blendColorMem, (0x1f<<10))	-- blend avg with blue ...
					rect(rx, ry, tileSize.x, tileSize.y)
				end
			end
		end

		for y=castingInfo.target.y-castingInfo.spell.area,castingInfo.target.y+castingInfo.spell.area do
			for x=castingInfo.target.x-castingInfo.spell.area,castingInfo.target.x+castingInfo.spell.area do
				if distL1(castingInfo.target, vec2(x,y)) <= castingInfo.spell.area then
					local rx = (x - view.bbox.min.x) * tileSize.x
					local ry = (y - view.bbox.min.y) * tileSize.y
					pokew(blendColorMem, 0x1f)	-- blend avg with red ...
					rect(rx, ry, tileSize.x, tileSize.y)
				end
			end
		end
		blend(-1)
	end

	if showMenu then
		local statFields = {'hpMax','mpMax','warmth','physAttack','physHitChance','physEvade','magicAttack','magicHitChance','magicEvade','attackOffsets'}
		local stats = {}
		for _,field in ipairs(statFields) do
			stats[field] = player:stat(field)
			if field == 'attackOffsets' then stats[field] = #stats[field] end
		end
		if possibleEquipField then
			local oldEquip = player[possibleEquipField]
			player[possibleEquipField] = possibleEquipItem
			for _,field in ipairs(statFields) do
				local altStat = player:stat(field)
				if field == 'attackOffsets' then altStat = #altStat end
				local diff = altStat - stats[field]
				if diff > 0 then
					stats[field] = '(+' .. diff .. ')'
				elseif diff < 0 then
					stats[field] = '(' .. diff .. ')'
				end
			end
			player[possibleEquipField] = oldEquip
		end

		drawTextBlock({
			'HP:' .. player.hp..'/'..stats.hpMax,
			'MP:' .. player.mp..'/'..stats.mpMax,
			'Cal.:' .. player.food,
			'Temp:' .. round(player.temp, 10),
			'Warmth:' .. stats.warmth,
			'Gold:' .. player.gold,
			'PA:' .. stats.physAttack,
			'P.Hit:' .. stats.physHitChance,
			'P.Evd:' .. stats.physEvade,
			'P.Area:' .. stats.attackOffsets,
			'MA:' .. stats.magicAttack,
			'M.Hit:' .. stats.magicHitChance,
			'M.Evd:' .. stats.magicEvade
		}, screenSize.x, 0, true)
	end

	if #player.attributes > 0 then
		drawTextBlock(player.attributes:mapi([attribute] attribute.name),
			0, screenSize.y - #player.attributes * fontSize - 8
		)
	end

	if #popupMessage > 0 then
		drawTextBlock(popupMessage, 0, 0)
		for k in pairs(popupMessage) do
			popupMessage[k] = nil
		end
	end

	for i,prompt in ipairs(clientPromptStack) do
		drawTextBlock(table.mapi(prompt.options, [option,i]
			((prompt.index == i and '>' or ' ')..option)
		), (i-1)<<2, ((i-1)<<2) + 8)
	end
end

pickFreePos=[classifier]do
	for attempt=1,1000 do
		local pos = randomBoxPos(thisMap.bbox)
		local tile = thisMap:getTile(pos.x, pos.y)
		local tileObjs = thisMap:getTileObjs(pos.x, pos.y)
		if not tileObjs then
			local good
			if classifier then
				good = classifier(tile)
			else
				good = not (tile.solid or tile.water)
			end
			if good then
				return pos
			end
		end
	end
	trace("failed to find free position")
	return vec2()
end

updateGame=[]do
	if thisMap.spawn then
		for _,spawnInfo in ipairs(thisMap.spawn) do
			if math.random() < spawnInfo.rate and #thisMap.objs < 2000 then
				local spawnClass = spawnInfo.type
				local classifier = spawnClass.movesInWater
					and ([tile] tile.water)
					or nil
				spawnClass{pos=pickFreePos(classifier)}
			end
		end
	end

	--decay light
	if thisMap.fogDecay then
		for y=view.bbox.min.y-1,view.bbox.max.y+1 do
			for x=view.bbox.min.x-1,view.bbox.max.x+1 do
				local tile = thisMap:getTile(x,y)
				if tile and tile.light then
					if view.bbox:contains(vec2(x,y)) then
						tile.light = math.max(0, tile.light - thisMap.fogDecay)
					else
						thisMap.tiles[y][x] = nil
					end
				end
			end
		end
	end

	local i=1
	while i<=#thisMap.objs do
		local obj = thisMap.objs[i]
		if obj.remove then
			obj:clearTile()
			thisMap.objs:remove(i)
			if obj == player then
				player = nil
			end
		else
			--obj?:update()
			if obj.update then obj:update() end
			--obj?:postUpdate()
			if obj.postUpdate then obj:postUpdate() end
			i+=1
		end
		if setMapRequest~=nil then break end	--christmas came early
	end

	if setMapRequest~=nil and player then
		setMap(setMapRequest)
		setMapRequest = nil
	else
		draw()
	end
end


setMap=[args]do
	--if we were somewhere already...
	if thisMap then
		--remove player
		if player then
			player:clearTile()
			thisMap.objs:removeObject(player)
			if not args.dontSavePos then
				thisMap.lastPlayerStart=vec2(player.pos)
			end
		end
		if thisMap.resetObjs then
			for _,obj in ipairs(thisMap.objs) do
				obj:clearTile()
			end
			thisMap.objs = nil
		end
	end

	--now load the map
	thisMap = maps![args.map]

	-- copy the map tile types into the tilemap
	for y=0,thisMap.size.y-1 do
		local tilerow=thisMap.tiles[y]
		for x=0,thisMap.size.x-1 do
			local tile=tilerow[x]
			mset(x,y,assert(table.pickRandom(tileTypes![tile.name].tileIndexes)))
		end
	end

	local firstSpawn = false
	if not thisMap.objs then
		firstSpawn = true
		thisMap.objs = table()
	end

	--spawn any fixed objs
	if thisMap.fixedObjs and firstSpawn then
		for _,fixedObj in ipairs(thisMap.fixedObjs) do
			 fixedObj:type()
		end
	end

	if player then
		thisMap.objs:insert(1, player)

		--init hero
		if args.pos then
			player:setPos(args.pos:unpack())
		elseif thisMap.lastPlayerStart then
			player:setPos(thisMap.lastPlayerStart:unpack())
		elseif thisMap.playerStart then
			player:setPos(thisMap.playerStart:unpack())
		else
			trace("we don't have a setMap pos and we don't have a map.playerStart ...")
			player:setPos(0,0)
		end
		player:applyLight()
	end

	--local _ = args.done?()	-- TODO langifx
	if args.done then args.done() end

	clientMessage("Entering "..thisMap.name)

	draw()
end



attackKeyCallback=[key]do
	keyCallback = nil
	if key=='left' then
		player:attack(-1, 0)
	elseif key=='up' then
		player:attack(0, -1)
	elseif key=='right' then
		player:attack(1, 0)
	elseif key=='down' then
		player:attack(0, 1)
	end
	return true
end

interactKeyCallback=[key]do
	keyCallback = nil
	if key=='left' then
		player:interact(-1, 0)
	elseif key=='up' then
		player:interact(0, -1)
	elseif key=='right' then
		player:interact(1, 0)
	elseif key=='down' then
		player:interact(0, 1)
	end
	return true
end

doEquipScreen=[]do
	local equipPrompt
	local refreshEquipPrompt = []do
		for i,field in ipairs(player.equipFields) do
			local s = field
			if player[field] then s ..= ': ' .. player[field].name end
			equipPrompt.options[i] = s
		end
		equipPrompt:refreshContent()
	end
	equipPrompt = ClientPrompt(
		player.equipFields,
		[:,cmd,index]do
			local equipField = player.equipFields[index]
			local equippableItemIndexes = range(#player.items):filter([itemIndex]
				player:canEquip(equipField, player.items[itemIndex])
			)
			equippableItemIndexes:insert(1, 0)
			ClientPrompt(
				equippableItemIndexes:mapi([itemIndex]
					itemIndex==0 and 'Nothing' or player.items[itemIndex].name
				),
				[:,itemName,index]do
					self:close()
					local itemIndex = equippableItemIndexes[index]
					local item = player.items[itemIndex]
					if item then player.items:remove(itemIndex) end
					player:setEquip(equipField,item)
					refreshEquipPrompt()
				end,
				[:,cmd,index]do
					possibleEquipField = equipField
					possibleEquipItem = player.items[equippableItemIndexes[index]]
				end,
				[:]do
					possibleEquipField = nil
				end
			)
		end
	)
	refreshEquipPrompt()
end

doSpellScreen=[]do
	local spells = player.spells:filter([spell]do
		return spell:canPayFor(player)	--TODO grey out uncastable spells
	end)
	if #spells==0 then
		clientMessage("You don't have any spells that you can use right now")
		return
	end
	ClientPrompt(
		spells:mapi([spell] spell.name..' ('..spell.cost..')'),
		[:,cmd,index]do
			closeAllPrompts()
			spells[index]:clientUse()
		end
	)
end

doItemScreen=[]do
	local items=player.items:filter([item] item.use)	--TODO grey out unusable items
	if #items==0 then
		clientMessage("You don't have any items that you can use right now")
		return
	end
	ClientPrompt(
		items:mapi([item,index] item.name),
		[:,cmd,index]do
			self:close()
			local item = items[index]
			local result = item:use(player)
			if result~='keep' then
				player.items:removeObject(item)
			end
		end
	)
end

doMenu=[]do
	ClientPrompt({
		'Pass',
		'Attack',
		'Spell',
		'Item',
		'Talk',
		'Equip',
		'Cheat',
	}, [:,cmd,index]do
		-- TODO Pass doesn't pass ...
		if cmd=='Attack' then
			self:close()
			keyCallback=attackKeyCallback
			clientMessage"Attack Whom?"
		elseif cmd=='Spell' then
			doSpellScreen()
		elseif cmd=='Item' then
			doItemScreen()
		elseif cmd=='Talk' then
			self:close()
			keyCallback = interactKeyCallback
			clientMessage"Talk to Whom?"
		elseif cmd=='Equip' then
			doEquipScreen()
		elseif cmd=='Cheat' then
			cheat()
		end
	end)
end

defaultKeyCallback=[key]do
	if key=='ok' then
		doMenu()
		return false
	elseif key=='left' then
		player:move(-1, 0)
	elseif key=='up' then
		player:move(0, -1)
	elseif key=='right' then
		player:move(1, 0)
	elseif key=='down' then
		player:move(0, 1)
	end
	return true
end

handleCommand=[key]do
	if not keyCallback then keyCallback = defaultKeyCallback end
	if keyCallback == defaultKeyCallback and #clientPromptStack>0 then keyCallback = promptKeyCallback end
	if keyCallback(key) then
		updateGame()
	else
		draw()
	end
end

cheat=[]do
	player.gold = math.huge
	player.hp = math.huge
	player.hpMax = math.huge
	player.mp = math.huge
	player.mpMax = math.huge
	player.spells = table(spells)
	draw()
end

update=[]do
	if btnp('up', 0, 20, 5) then
		handleCommand'up'
	elseif btnp('down', 0, 20, 5) then
		handleCommand'down'
	elseif btnp('left', 0, 20, 5) then
		handleCommand'left'
	elseif btnp('right', 0, 20, 5) then
		handleCommand'right'
	elseif btnp('b', 0, 20, 5) then
		handleCommand'ok'
	elseif btnp'x' then
		showMenu=not showMenu
		draw()
	elseif btnp('y', 0, 20, 5) then
		handleCommand'cancel'
	end
end

initMaps()
player=HeroObj{}
setMap{map='Helpless Village'}
