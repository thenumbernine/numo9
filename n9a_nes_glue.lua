--[[
can I make a NES ROM to NuMo9 converter?  "transpiler"? "emulator"?  "is not emulator"?
using this to learn:
https://www.patater.com/gbaguy/day2n.htm
https://yizhang82.dev/nes-emu-overview
https://www.nesdev.org/wiki/6502_instructions
https://www.nesdev.org/wiki/CPU_unofficial_opcodes
https://www.nesdev.org/wiki/PPU_memory_map
https://www.nesdev.org/wiki/PPU_programmer_reference
https://www.nesdev.org/obelisk-6502-guide/reference.html
https://www.nesdev.org/6502_cpu.txt
https://github.com/skilldrick/easy6502
https://gist.github.com/1wErt3r/4048722 <- smb dis but without addresses
https://6502disassembly.com/nes-smb/SuperMarioBros.html	<- with addresses
https://web.archive.org/web/20200129081101/http://users.telenet.be:80/kim1-6502/6502/proman.html#910
https://www.pagetable.com/?p=410
https://fms.komkon.org/EMUL8/NES.html
https://zserge.com/posts/6502/

registers:
A = 8bit
X = 8bit
Y = 8bit
P = 16bit
S = 8bit
PC = 8bit
... 2kb onboard RAM
PPU: 256x240 8x8 tiles, up to 64 8x8 or 8x16 sprites
APU: 2 pulse channels, 1 triangle, 1 noise, 1 delta-modulation
$0000-$07ff = RAM
$2000-$2007 = PPU regs
$4000-$401f = APU
$6000-$ffff = cart space
$8000 = bank0 code starts at address
bank1 interrupts start at $fffa
bank2 sprites start at $0000
--]]
mode(1)	-- 256x256 8bpp indexed

local hex=|i,n| (('%0'..(n or 2)..'X'):format(tonumber(i)))

PPUNameTableMirrors = 0	-- 1: CIRAM A10 = PPU A11, 2: CIRAM A10 = PPU A10
PPUNameTableAltLayout = false

local nesheader = blobaddr('data', 2)
assert.ge(blobsize('data', 2), 0x10)	-- 0x10 or 0x210 if trainer present

-- read the header:
-- https://www.nesdev.org/wiki/INES
assert.eq(peekl(nesheader), 0x1A53454E)	-- "NES\n"
local PRG_ROM_size = peek(nesheader+4) << 14
local CHR_ROM_size = peek(nesheader+5) << 13
local header_6 = peek(nesheader+6)
-- bit 01 = nametable arrangement
PPUNameTableMirrors = header_6 & 3
-- bit 2 = PRG RAM present at $6000-7FFF
if (header_6 >> 3) & 1 == 1 then
	trace'has trainer'
end	-- trainer
PPUNameTableAltLayout = (header_6 >> 4) & 1 == 1	-- bit 4 = alt nametable layout
local mapper = header_6 >> 4
local header_7 = peek(nesheader+7)
-- bit 0 = VS unisystem
-- bit 1 = playchoice-10 (8 KB f hint screen afer CHR data)
-- bit 2:3 = if equal 10b then we use NES 2.0 format
mapper |= header_7 & 0xF0
trace('mapper', mapper)
local PRG_RAM_size = peek(nesheader+8)
local NTSC_vs_PAL = peek(nesheader+9) & 1	-- and assert the rest of the bits are zero ...
local header_10 = peek(nesheader+10)
local TV = header_10 & 3	-- 0 = NTSC, 2 = PAL, 1/3 = dual compatible
local PRG_RAM_avail = (header_10 >> 4) & 1 == 1
local bus_conflicts = (header_10 >> 5) & 1 == 1

local PPUControl = 0
local PPUControlAddr = 0x2000

local PPUMask = 0
local PPUMaskAddr = 0x2001

local PPUStatus = 0 -- 0xA0	-- initial state?
local PPUStatusAddr = 0x2002

local OAMPtr = 0
local OAMPtrAddr = 0x2003
local OAMRWAddr = 0x2004

local OAMSize = 0x100
local n9OAMAddr = blobaddr('data', 3)
assert.eq(blobsize('data', 3), OAMSize)
local OAMDMAaddr = 0x4014

local PPUScrollX = 0
local PPUScrollY = 0
local PPUScrollAddr = 0x2005
local PPUScrollReadX = true	-- x first, y second

local PPUMemPtr = 0	-- uint16 reg accessed via $2006/2007
local PPUMemPtrWriteHi = true	-- "high byte first"
local PPUMemAddrAddr = 0x2006
local PPUMemDataAddr = 0x2007

-- 0x4000+ is sound registers
local cartRAMAddr = 0x6000 -- 0x6000-0x8000 is cart ram / persistent
local cartRAMSize = 0x2000
local cartRAMEndAddr = cartRAMAddr + cartRAMSize

-- https://www.emulationonline.com/systems/nes/sprite-rendering/
-- this gives an example rom , but that rom isn't even 32kb, so there is no 0xFFF*
-- so I'll just meh it and always use the min(ROM size, 64k) minus 2 4 6 bytes
-- https://forums.nesdev.org/viewtopic.php?t=17413
-- a guy asks directly this question, nobody seems to answer it.
local idk = math.min(0x8000 + PRG_ROM_size, 0x10000)
local NMIAddr = idk - 6
local RESETAddr = idk - 4
local IRQAddr = idk - 2


local nesrom = blobaddr('data', 0)

-- init persistent RAM
local n9PersistAddr = blobaddr'persist'
assert.ge(blobsize'persist', cartRAMSize, "NES needs more save RAM!")
memcpy(nesrom + cartRAMAddr, n9PersistAddr, cartRAMSize)

local n9PPURAMAddr = blobaddr('data', 1)
local PPURAMSize = 0x4000
local PPURAMMask = 0x3FFF
assert.eq(blobsize('data', 1), PPURAMSize)

local n9SheetAddr = blobaddr'sheet'
local n9TilemapAddr = blobaddr'tilemap'
local n9PalAddr = blobaddr'palette'

local nespeek = |i,dontwrite|do
	if i == PPUControlAddr then
trace('PPUControl read', hex(PPUControl))
		return PPUControl
	elseif i == PPUMaskAddr then
trace('PPUMask read', hex(peek(nesrom+i)))
		return PPUMask
	elseif i == PPUStatusAddr then
		local val = PPUStatus
trace('PPUStatus read', hex(val))
		if not dontwrite then
			PPUStatus &= ~0x80	-- clear vblank on read
		end
		return val
	elseif i == OAMPtrAddr then
trace('OAMPtr read', hex(peek(nesrom+i)))
		return OAMPtr
	elseif i == OAMRWAddr then
		local v = peek(n9OAMAddr + OAMPtr)
trace('OAMRW read from OAM addr '..hex(OAMPtr)..' = '..v)
		return v
	elseif i == PPUScrollAddr then
trace('PPUScroll read', hex(peek(nesrom+i)))
	elseif i == PPUMemAddrAddr then
trace('PPUMemPtr read', hex(peek(nesrom+i)))
	elseif i == PPUMemDataAddr then
		local val = peek(n9PPURAMAddr+PPUMemPtr)
trace('PPUMemData read '..hex(peek(nesrom+i))..' ... as PPU RAM addr '..hex(PPUMemPtr,4)..' val '..hex(val))
		if not dontwrite then
			-- inc upon read/write
			PPUMemPtr += PPUControl & 2 == 0 and 1 or 32
			PPUMemPtr &= PPURAMMask
		end
		return val
	end
	-- handle special read sections
	return peek(nesrom+i)
end
local nespeekw = |i,dontwrite| nespeek(i,dontwrite) | (nespeek(i+1,dontwrite)<<8)

-- assumes i is uint16 and v is uint8
local nespoke = |i,v|do
	if i == PPUControlAddr then
trace('PPUControl write', hex(v))
		PPUControl = v
		return
	elseif i == PPUMaskAddr then
trace('PPUMask write', hex(v))
		PPUMask = v
		return
	elseif i == PPUStatusAddr then
		-- it's a read-only address
trace("PPUStatus write but it's read-only...")
	elseif i == OAMPtrAddr then
trace('OAMPtr write', hex(v))
		OAMPtr = v
		return
	elseif i == OAMRWAddr then
trace('OAMRW write '..hex(v)..' to OAM addr '..hex(OAMPtr))
		poke(n9OAMAddr + OAMPtr, v)
		OAMPtr = uint8_t(OAMPtr + 1)
		return
	elseif i == PPUScrollAddr then
trace('PPUScroll write', hex(v))
		if PPUScrollReadX then
			PPUScrollX = v | ((PPUControl & 1) << 8)
			PPUScrollReadX = false
		else
			PPUScrollY = v | ((PPUControl & 2) << 7)
			PPUScrollReadX = true
		end
	elseif i == PPUMemAddrAddr then
trace('PPUMemPtr write', hex(v))
		if PPUMemPtrWriteHi then
			PPUMemPtr &= 0xFF
			PPUMemPtr |= v << 8
			PPUMemPtrWriteHi = false
		else
			PPUMemPtr &= 0xFF00
			PPUMemPtr |= v
			PPUMemPtrWriteHi = true
		end
	elseif i == PPUMemDataAddr then
trace('PPUMemData write '..hex(v)..' ... to PPU RAM $'..hex(PPUMemPtr,4))
		poke(n9PPURAMAddr+PPUMemPtr, v)
		-- depending on where, update N9 VRAM
		if PPUMemPtr < 0x2000 then
			-- 0000-1000 = pattern table 0
			-- 1000-2000 = pattern table 1
			--[[
			pattern table
			each sprite is 8x8 pixels, 2bpp
			so a sprite is 16 bytes
			so 256 sprites fit in 1 table

			each byte is a row
			first 8 bytes are 1bpp lo-bit
			second 8 bytes are 1bpp hi-bit
			--]]
			--local tableIndex = PPUMemPtr >> 12	-- 0 or 1
			local hi = (PPUMemPtr >> 3) & 1	-- hi bit: 0 or 1
			local y = PPUMemPtr & 0x7
			local sprIndex = PPUMemPtr >> 4
			local sprX = sprIndex & 0x1F
			local sprY = sprIndex >> 5
--trace('...to sprIndex='..sprIndex..' sprX='..sprX..' sprY='..sprY..' hi='..hi)
			for x=0,7 do
				local addr = n9SheetAddr + (x | (sprX << 3) | ((y | (sprY << 3)) << 8))
				local pix = peek(addr)
				pix &= ~(1 << hi)
				pix |= ((v >> (7 - x)) & 1) << hi
				poke(addr, pix)
			end
			-- then the attribute-table is used as bit23 to offset these
		elseif PPUMemPtr < 0x3000 then
			-- 2000-23C0 name table 0
			-- 23C0-2400 attr table 0
			-- 2400-27C0 name table 1
			-- 27C0-2800 attr table 1
			-- 2800-2BC0 name table 2
			-- 2BC0-2C00 attr table 2
			-- 2C00-2FC0 name table 3
			-- 2FC0-3000 attr table 3
			local tileIndex = (PPUMemPtr >> 10) & 3
			local pageaddr = PPUMemPtr & 0x3FF
			--if pageaddr < 960 then
				local x = pageaddr & 0x1f
				local y = pageaddr >> 5
trace('...to nametable='..tileIndex..' x='..x..' y='..y)
				-- 32x30 tilemap
				pokew(n9TilemapAddr + (
					(x | ((tileIndex&1)<<5))
					| ((y | ((tileIndex&2)<<4))<<8)
				) << 1, v)
			--else
				-- attribute-flags
			--end
		elseif PPUMemPtr < 0x3F00 then
		elseif PPUMemPtr < 0x3F20 then
			-- 3F00-3F10 image palette
			-- 3F10-3F20 sprite palette

			-- so the index in the sprite tile + attr + extra is a lookup into this table
			-- and this table is then a lookup into the palette
			-- hmmmmmm

			-- how bout I keep the last or so 64 colors (since I have 4 copies in the 256-color palette)
			-- as the defacto NES palette
			-- and then upon these writes, copy the orig palette 192-256 into the used-palette 0-64 or idk sprite vs image or w/e palette 0-128

			-- what should I initialize this to?
			local palindex = (PPUMemPtr - 0x3F00)
			--palindex &= 0xf	-- mirror? or nah?
			pokew(
				n9PalAddr + palindex << 1,
				peekw(n9PalAddr + ((0xC0 | v & 0x3F) << 1))
			)
		end
		-- inc upon read/write
		PPUMemPtr += PPUControl & 2 == 0 and 1 or 32
		PPUMemPtr &= PPURAMMask
	elseif i == OAMDMAaddr then
		-- increment?
		memcpy(n9OAMAddr, nesrom + (v << 8), OAMSize)
	elseif i >= cartRAMAddr and i < cartRAMEndAddr then
		-- write it to our persistent memory
		poke(n9PersistAddr + i - 0x6000, v)
	end

	-- handle special write sections
	poke(nesrom+i, v)

-- TODO remap addrs 0x200-0x600 to VRAM
end

-- assumes v is uint16
local nespokew = |i,v|do
	nespoke(i, uint8_t(v))
	nespoke(i+1, uint8_t(v>>8))
end

-- used to read state without modifying (i.e. special hardware registers)
local dbg_nespeek=|i| nespeek(i,true)
local dbg_nespeekw=|i| nespeekw(i,true)


local A = 0		-- accumulator
local X = 0		-- x-register
local Y = 0		-- y-register
local P = 0		-- process flags
local S = 0		-- stack
local PC = 0	-- process-counter

local flagC = 0x01	-- carry
local flagZ = 0x02	-- zero
local flagI = 0x04	-- interrupt disable
local flagD = 0x08	-- decimal mode
local flagB = 0x10	-- break
local flag_ = 0x20	-- unused
local flagV = 0x40	-- overflow
local flagN = 0x80	-- negative
local bitC = 0
local bitZ = 1
local bitI = 2
local bitD = 3
local bitB = 4
local bit_ = 5
local bitV = 6
local bitN = 7
local flagB_ = flagB | flag_
local flagVN = flagV | flagN

local readPC=||do
	local i = nespeek(PC)
	PC += 1
	return i
end
local readPCw=||do
	local i = nespeekw(PC)
	PC += 2
	return i
end

-- arg : uint8_t
local setZN=|arg|do
	if arg == 0 then
		P |= flagZ
	else
		P &= ~flagZ
	end
	-- transfer bit 7 from arg to P (this flagN)
	P &= ~flagN
	P |= arg & flagN
	return arg	-- continue to use the arg
end

-- arg : uint8_t
local bit0toC=|arg|do
	-- transfer bit 0 from arg to P (this is flagC)
	P &= ~flagC
	P |= arg & flagC	-- carry is bit 0
	return arg	-- continue to use the arg
end

-- arg : uint8_t
local bit7toC=|arg|do
	P &= ~flagC
	P |= (arg >> 7) & flagC	-- carry is bit 0
	return arg
end

-- reads offset from PC
local branch=|offset|do PC += int8_t(readPC()) end

local doCompare=|reg,val|do
	if reg >= val then
		P |= flagC
	else
		P &= ~flagC
	end
	val = uint8_t(reg - val)
	setZN(val)
end

local SBC=|value|do
	-- transfer NOT `A ~ value`'s bit 7 to P's bit 6 aka flagV
	P &= ~flagV
	P |= (~(A ~ value) & 0x80) >> 1

	local w
	if P & flagD ~= 0 then
		local tmp = 0xF
			+ (A & 0xF)
			- (value & 0xF)
			+ (P & flagC)
		if tmp < 0x10 then
			w = 0
			tmp -= 6
		else
			w = 0x10
			tmp -= 0x10
		end
		w += 0xF0 + (A & 0xF0) - (value & 0xF0)
		if w < 0x100 then
			P &= ~flagC
			if w < 0x80 then
				P &= ~flagV
			end
			w -= 0x60
		else
			P |= flagC
			if w >= 0x180 then
				P &= ~flagV
			end
		end
		w += tmp
	else
		w = 0xFF + A - value + (P & flagC)
		if w < 0x100 then
			P &= ~flagC
			if w < 0x80 then
				P &= ~flagV
			end
		else
			P |= flagC
			if w >= 0x180 then
				P &= ~flagV
			end
		end
	end
	A = uint8_t(w)
	setZN(A)
end

local ADC=|value|do
	-- transfer NOT `A ~ value`'s bit 7 to P's bit 6 aka flagV
	P &= ~flagV
	P |= (~(A ~ value) & 0x80) >> 1

	if P & flagD ~= 0 then
		local tmp = (A & 0xF)
			+ (value & 0xF)
			+ (P & flagC)
		if tmp >= 10 then
			tmp = 0x10 | ((tmp + 6) & 0xF)
		end
		tmp += (A & 0xF0) + (value & 0xF0)
		if tmp >= 160 then
			P |= flagC
			if tmp >= 0x180 then
				P &= ~flagV
			end
			tmp += 0x60
		else
			P &= ~flagC
			if tmp < 0x80 then
				P &= ~flagV
			end
		end
	else
		tmp = A + value + (P & flagC)
		if tmp >= 0x100 then
			P |= flagC
			if tmp >= 0x180 then
				P &= ~flagV
			end
		else
			P &= ~flagC
			if tmp < 0x80 then
				P &= ~flagV
			end
		end
	end
	A = uint8_t(tmp)
	setZN(A)
end

local BIT=|i|do
	-- transfer bit 6 & 7 of i to bit 6 & 7 of P
	P &= ~flagVN
	P |= i & flagVN

	-- set flagZ based on `A & i`
	if A & i ~= 0 then
		P &= ~flagZ
	else
		P |= flagZ
	end
end

local DEC=|addr| nespoke(addr, setZN(uint8_t(nespeek(addr) - 1)))
local INC=|addr| nespoke(addr, setZN(uint8_t(nespeek(addr) + 1)))

local incS=||do
	S = uint8_t(S + 1)
end
local decS=||do
	S = uint8_t(S - 1)
end

local stackPush=|b|do
	nespoke(S|0x100, b)
	decS()
end
local stackPop=||do
	incS()
	return nespeek(S|0x100)
end

local stackPushw=|w|do
	-- [[ safe
	stackPush(uint8_t(w >> 8))
	stackPush(uint8_t(w))
	--]]
	--[[ trust overflow won't happen
	decS()
	nespokew(S|0x100, w)
	decS()
	--]]
end
local stackPopw=||do
	-- [[ safe
	-- depends on | evaluating left-to-right
	-- and langfix rewrites this as bit.bor(...)
	-- so this depends on lua arg evaluation being left-to-right
	return stackPop() | (stackPop() << 8)
	--]]
	--[[ trust underflow won't happen
	incS()
	local w = nespeekw(S|0x100)
	incS()
	return w
	--]]
end

RESET=||do
	PC = nespeekw(RESETAddr)
end
IRQ=||do
	stackPushw(PC)
	stackPush(P)
	P |= flagI
	PC = nespeekw(IRQAddr)
end
NMI=||do
	stackPushw(PC)
	stackPush(P)
	P |= flagI
	PC = nespeekw(NMIAddr)
end
BRK=||do
	stackPushw(PC)
	stackPush(P | flagB)
	P |= flagI
	PC = nespeekw(IRQAddr)
end



local argStrRel=|skipvalue|
	' $+'..hex(dbg_nespeek(PC))
	..(skipvalue and '' or ' = $'..hex(PC+1+int8_t(dbg_nespeek(PC)),4))

local argStrImm=||
	' #$'..hex(dbg_nespeek(PC))

local argStrZP=|skipvalue|
	' $'..hex(dbg_nespeek(PC))
	..(skipvalue and '' or ' = '..hex(dbg_nespeek(dbg_nespeek(PC))))

local argStrZPX=|skipvalue|
	' $'..hex(dbg_nespeek(PC))
	..',X = $'..hex(uint8_t(dbg_nespeek(PC) + X))
	..(skipvalue and '' or ' = '..hex(dbg_nespeek(uint8_t(dbg_nespeek(PC) + X))))

local argStrZPY=|skipvalue|
	' $'..hex(dbg_nespeek(PC))
	..',X = $'..hex(uint8_t(dbg_nespeek(PC) + X))
	..(skipvalue and '' or ' = '..hex(dbg_nespeek(uint8_t(dbg_nespeek(PC) + X))))

local argStrAbs=|skipvalue|
	' $'..hex(dbg_nespeekw(PC),4)
	..(skipvalue and '' or ' = '..hex(dbg_nespeek(dbg_nespeekw(PC))))

local argStrAbsX=|skipvalue|
	' $'..hex(dbg_nespeekw(PC),4)
	..',X = $'..hex(uint16_t(dbg_nespeekw(PC) + X),4)
	..(skipvalue and '' or ' = '..hex(dbg_nespeek(uint16_t(dbg_nespeekw(PC) + X))))

local argStrAbsY=|skipvalue|
	' $'..hex(dbg_nespeekw(PC),4)
	..',Y = $'..hex(uint16_t(dbg_nespeekw(PC) + Y),4)
	..(skipvalue and '' or ' = '..hex(dbg_nespeek(uint16_t(dbg_nespeekw(PC) + Y))))

local argStrIZX=|skipvalue|
	' ($'..dbg_nespeek(PC)
	..',X) = ($'..hex(dbg_nespeek(PC) + X,4)
	..') = $'..hex(dbg_nespeekw(dbg_nespeek(PC) + X),4)
	..(skipvalue and '' or ' = '..hex(dbg_nespeek(dbg_nespeekw(dbg_nespeek(PC) + X))))

-- should this be ($arg,Y) or ($arg),Y ? latter in https://www.nesdev.org/obelisk-6502-guide/reference.html
local argStrIZY=|skipvalue|
	' ($'..dbg_nespeek(PC)
	..'),Y = ($'..hex(dbg_nespeek(PC))
	..'+Y) = $'..hex(dbg_nespeekw(dbg_nespeek(PC)),4)..'+'..hex(Y)
	..(skipvalue and '' or ' = '..hex(uint16_t(dbg_nespeekw(dbg_nespeek(PC)) + Y),4))

local argStrFor234=|b234, ...|do
	if b234 == 0x00 then
		return argStrIZX(...)		-- (Indirect,X)
	elseif b234 == 0x04 then
		return argStrZP(...)		-- Zero Page
	elseif b234 == 0x08 then
		return argStrImm(...)		-- Immediate
	elseif b234 == 0x0C then
		return argStrAbs(...)		-- Absolute
	elseif b234 == 0x10 then
		return argStrIZY(...)		-- (Indirect),Y
	elseif b234 == 0x14 then
		return argStrZPX(...)		-- Zero Page,X
	elseif b234 == 0x18 then
		return argStrAbsY(...)		-- Absolute,Y
	elseif b234 == 0x1C then
		return argStrAbsX(...)		-- Absolute,X
	end
end

local writebuf=''
local write=|...| do writebuf ..= table{...}:mapi(tostring):concat'\t' end

RESET()
trace('initPC = $'..hex(PC,4))

local fbAddr = ramaddr'framebuffer'

cpuRun=||do
--DEBUG(asm):write('A='..hex(A)..' X='..hex(X)..' Y='..hex(Y)..' S='..hex(S)..' P='..hex(P)..' PC='..hex(PC,4)..' op='..hex(nespeek(PC))..' ')
	local op = readPC()

	-- https://www.nesdev.org/wiki/CPU_unofficial_opcodes
	local b01 = bit.band(op, 0x03)	-- 00 01 02 03
	local b567 = bit.band(op, 0xE0)	-- 00 20 40 60 80 A0 C0 E0
	local b234 = bit.band(op, 0x1C)	-- 00 04 08 0C 10 14 08 1C

	-- xxxx:xx00
	-- control
	if b01 == 0x00 then

		-- xxx1:0000
		-- BPL, BMI, BVC, BVS, BCC, BCS, BNE, BEQ
		if op & 0x1F == 0x10 then
			-- branch-on-flag
			-- op & 0x10 <=> branch on flag
			-- op & 0x20: 0 means branch on flag clear, 1 means branch on flag set
			-- missed their chance to swap V and N ... then we'd have ((op >> 6) + 6) & 7 == flag bit

			-- bit 5 specifies whether to test for set vs unset
			local test = (op >> 5) & 1

			local shr
			local b67 = op & 0xC0
			if b67 == 0x00 then
				shr = bitN
--DEBUG(asm):write(({'BPL', 'BMI'})[test+1]..argStrRel())
			elseif b67 == 0x40 then
				shr = bitV
--DEBUG(asm):write(({'BVC', 'BVS'})[test+1]..argStrRel())
			elseif b67 == 0x80 then
				shr = bitC
--DEBUG(asm):write(({'BCC', 'BCS'})[test+1]..argStrRel())
			elseif b67 == 0xC0 then
				shr = bitZ
--DEBUG(asm):write(({'BNE', 'BEQ'})[test+1]..argStrRel())
			end

			if (P >> shr) & 1 == test then
				PC += int8_t(readPC())
			end
			PC += 1

		-- xxx1:1000
		elseif op & 0x1F == 0x18 then

		-- 0xx1:1000
			if op == 0x18 then
				P &= ~flagC	-- CLC
--DEBUG(asm):write'CLC'
			elseif op == 0x38 then
				P |= flagC	-- SEC
--DEBUG(asm):write'SEC'
			elseif op == 0x58 then
				P &= ~flagI	-- CLI
--DEBUG(asm):write'CLI'
			elseif op == 0x78 then
				P |= flagI 	-- SEI
--DEBUG(asm):write'SEI'
			elseif op == 0x98 then
				-- TYA is here for some reason
				-- there's no SEV ...
				-- and CLV goes where SEV should've gone
				A = setZN(Y)	-- TYA
--DEBUG(asm):write'TYA'
			elseif op == 0xB8 then
				P &= ~flagV 	-- CLV
--DEBUG(asm):write'CLV'
			elseif op == 0xD8 then
				P &= ~flagD 	-- CLD
--DEBUG(asm):write'CLD'
			elseif op == 0xF8 then
				P |= flagD 	-- SED
--DEBUG(asm):write'SED'
			end

		-- xxxy:yy00 for yyy != 100 and yy != 110
		else
			if op & 0x80 == 0 then	-- bit 7 not set
				if op == 0x00 then	-- BRK
--DEBUG(asm):write'BRK'
					BRK()
				elseif op == 0x20 then	-- JSR
--DEBUG(asm):write('JSR'..argStrAbs())
					local addr = readPCw()
					stackPushw(uint16_t(PC - 1))
					PC = addr
				elseif op == 0x40 then	-- RTI
--DEBUG(asm):write'RTI'
					P = stackPop() | flagB_
					PC = stackPopw()
				elseif op == 0x60 then	-- RTS
--DEBUG(asm):write'RTS'
					PC = stackPopw() + 1
				elseif op == 0x08 then
--DEBUG(asm):write'PHP'
					stackPush(P | flagB_) -- PHP
				elseif op == 0x28 then
--DEBUG(asm):write'PLP'
					P = stackPop() | flagB_  -- PLP
				elseif op == 0x48 then
--DEBUG(asm):write'PHA'
					stackPush(A)	-- PHA
				elseif op == 0x68 then
--DEBUG(asm):write'PLA'
					A = setZN(stackPop()) 	-- PLA
				elseif op == 0x24 then	-- BIT
--DEBUG(asm):write('BIT'..argStrZP())
					BIT(nespeek(readPC()))
				elseif op == 0x2C then	-- BIT
--DEBUG(asm):write('BIT'..argStrAbs())
					BIT(nespeek(readPCw()))

				-- JMP
				elseif op == 0x4C then
--DEBUG(asm):write('JMP'..argStrAbs(true))		-- Absolute ... but its jump
					PC = readPCw()
				elseif op == 0x6C then
--DEBUG(asm):--write('JMP'..argStrAbs()		-- Indirect ... but its jump
--DEBUG(asm):write('JMP'..' $'..hex(dbg_nespeekw(PC),4)..(skipvalue and '' or ' = '..hex(dbg_nespeekw(dbg_nespeekw(PC)),4)))
					PC = nespeekw(readPCw())
				else
--DEBUG(asm):write'NOP'
				-- else 04 0C 14 1C 34 3C 44 54 5C 64 74 7C is NOP
				end

			else	-- bit 7 set
				-- these match up closely with RMW lower half i.e. op & 0x83 == 0x82

				-- 0x80 NOP
				if op == 0x84 then
--DEBUG(asm):write('STY'..argStrZP())
					nespoke(readPC(), Y)	-- STY
				elseif op == 0x88 then
--DEBUG(asm):write'DEY'
					Y = setZN(uint8_t(Y - 1)) 	-- DEY
				elseif op == 0x8C then
--DEBUG(asm):write('STY'..argStrAbs())
					nespoke(readPCw(), Y)	-- STY
				-- 0x90 handled by the branch set
				elseif op == 0x94 then
--DEBUG(asm):write('STY'..argStrZPX())
					nespoke(uint8_t(readPC() + X), Y)	-- STY
				-- 0x98 handled by SE*/CL* set
				elseif op == 0x9C then	-- SHY
--DEBUG(asm):write'SHY -- TODO'
				elseif op == 0xA0 then	-- LDY
--DEBUG(asm):write('LDY'..argStrImm())
					Y = setZN(readPC())
				elseif op == 0xA4 then
--DEBUG(asm):write('LDY'..argStrZP())
					Y = setZN(nespeek(readPC())) 	-- LDY
				elseif op == 0xA8 then
--DEBUG(asm):write'TAY'
					Y = setZN(A) 	-- TAY
				elseif op == 0xAC then
--DEBUG(asm):write('LDY'..argStrAbs())
					Y = setZN(nespeek(readPCw())) 	-- LDY
				-- 0xB0 = handled by branch set
				elseif op == 0xB4 then
--DEBUG(asm):write('LDY'..argStrZPX())
					Y = setZN(nespeek(uint8_t(readPC() + X))) 	-- LDY
				-- 0xB8 handled by SE*/CL* set
				elseif op == 0xBC then
--DEBUG(asm):write('LDY'..argStrAbsX())
					Y = setZN(nespeek(readPCw() + X)) 	-- LDY
				elseif op == 0xC0 then
--DEBUG(asm):write('CPY'..argStrImm())
					doCompare(Y, readPC())						-- CPY
				elseif op == 0xC4 then
--DEBUG(asm):write('CPY'..argStrZP())
					doCompare(Y, nespeek(readPC()))	-- CPY
				elseif op == 0xC8 then
--DEBUG(asm):write'INY'
					Y = setZN(uint8_t(Y + 1)) 	-- INY
				elseif op == 0xCC then
--DEBUG(asm):write('CPY'..argStrAbs())
					doCompare(Y, nespeek(readPCw()))	-- CPY
				-- 0xD0 handled by branch set
				-- 0xD4 = NOP
				-- 0xD8 handled by SE*/CL* set
				-- 0xDC = NOP
				elseif op == 0xE0 then
--DEBUG(asm):write('CPX'..argStrImm())
					doCompare(X, readPC())	-- CPX
				elseif op == 0xE4 then
--DEBUG(asm):write('CPX'..argStrZP())
					doCompare(X, nespeek(readPC()))	-- CPX
				elseif op == 0xE8 then
--DEBUG(asm):write'INX'
					X = setZN(uint8_t(X + 1)) 	-- INX
				elseif op == 0xEC then
--DEBUG(asm):write('CPX'..argStrAbs())
					doCompare(X, nespeek(readPCw()))			-- CPX
				else
--DEBUG(asm):write'NOP'
				-- 0xF0 handled by branch set
				-- 0xF4 NOP
				-- 0xF8 handled by SE*/CL*
				-- 0xFC NOP
				end
			end
		end

	else
		-- ALU
		if b01 == 0x01 then
			local arg

			if b567 == 0x00 then
--DEBUG(asm):write('ORA'..argStrFor234(b234))
			elseif b567 == 0x20 then
--DEBUG(asm):write('AND'..argStrFor234(b234))
			elseif b567 == 0x40 then
--DEBUG(asm):write('EOR'..argStrFor234(b234))
			elseif b567 == 0x60 then
--DEBUG(asm):write('ADC'..argStrFor234(b234))
			elseif b567 == 0x80 then
				if b234 ~= 0x08 then
--DEBUG(asm):write('STA'..argStrFor234(b234, true))
				else
--DEBUG(asm):write('NOP'..argStrFor234(b234))
				end
			elseif b567 == 0xA0 then
--DEBUG(asm):write('LDA'..argStrFor234(b234))
			elseif b567 == 0xC0 then
--DEBUG(asm):write('CMP'..argStrFor234(b234))
			elseif b567 == 0xE0 then
--DEBUG(asm):write('SBC'..argStrFor234(b234))
			end


			if b234 == 0x08 then		-- immediate
				arg = readPC()	-- #$00
			else						-- non-immediate, i.e. memory
				if b234 == 0x00 then
					arg = nespeekw(uint8_t(readPC() + X))	-- IZX: (indirect,X)
				elseif b234 == 0x04 then
					arg = readPC()	-- $00
				elseif b234 == 0x0C then
					arg = readPCw()
				elseif b234 == 0x10 then
					arg = uint16_t(nespeekw(readPC()) + Y)	-- IZY: (indirect),Y
				elseif b234 == 0x14 then
					arg = uint8_t(readPC() + X)
				elseif b234 == 0x18 then
					arg = uint16_t(readPCw() + Y)
				elseif b234 == 0x1C then
					arg = uint16_t(readPCw() + X)
				end

				-- wait for STA do we not do the final peek above?
				if b567 ~= 0x80 then
					arg = nespeek(arg)
				end
			end

			if b567 == 0x00 then		-- 01 05 09 0D 11 15 19 1D = ORA
				A = setZN(A | arg)
			elseif b567 == 0x20 then	-- 21 25 29 2D 31 35 39 3D = AND
				A = setZN(A & arg)
			elseif b567 == 0x40 then	-- 41 45 49 4D 51 55 59 5D = EOR
				A = setZN(A ~ arg)
			elseif b567 == 0x60 then	-- 61 65 69 6D 71 75 79 7D = ADC
				ADC(arg)
			elseif b567 == 0x80 then	-- 81 85 8D 91 95 99 9D = STA
				if b234 ~= 0x08 then	-- 89 is NOP
					nespoke(arg, A)
				else
					-- NOP ... does it still read the arg and inc the PC?
				end
			elseif b567 == 0xA0 then	-- A1 A5 A9 AD B1 B5 B9 BD = LDA
				A = setZN(arg)
			elseif b567 == 0xC0 then	-- C1 C5 C9 CD D1 D5 D9 DD = CMP
				doCompare(A, arg)
			elseif b567 == 0xE0 then	-- E1 E5 E9 ED F1 F5 F9 FD = SBC
				SBC(arg)
			end

		-- RMW
		elseif b01 == 0x02 then
			-- xxxx:xx10

			if op & 0x80 == 0 then	-- bit 7 clear

				if b234 == 0x00
				or b234 == 0x10
				then
--DEBUG(asm):write'STP'
					-- 0xxx:0010
					-- 02 12 22 32 42 52 62 72 = STP
				elseif b234 == 0x18 then
--DEBUG(asm):write'NOP'
					-- 1A 3A 5A 7A = NOP
				else
					local arg, addr
					if b234 == 0x08 then
						-- immediate
						arg = A
					else
						-- not immediate, use address
						-- (should follow same addressing as ALU, maybe merge?)
						if b234 == 0x04 then
							addr = readPC()
						elseif b234 == 0x0C then
							addr = readPCw()
						elseif b234 == 0x14 then
							addr = uint8_t(readPC() + X)
						elseif b234 == 0x1C then
							addr = uint16_t(readPCw() + X)
						end
						arg = nespeek(addr)
					end

					if b567 == 0x00	then -- ASL
						arg = setZN(uint8_t(bit7toC(arg) << 1))
--DEBUG(asm):write'ASL'
					elseif b567 == 0x20	then -- ROL
						-- reads C
						-- shifts src left by 1, inserting old C
						-- sets src's old bit7 to the new C as uint8
						-- sets VN flags based on result
						-- returns result
						-- * I'm hoping all operations are evaluated left-to-right, since I'm reading C then writing C in dif bit op args
						-- * NOTICE, no memory evaluation better modify C ...
						arg = setZN((P & flagC) | uint8_t(bit7toC(arg) << 1))
--DEBUG(asm):write'ROL'
					elseif b567 == 0x40	then -- LSR
						arg = setZN(bit0toC(arg) >> 1)
--DEBUG(asm):write'LSR'
					elseif b567 == 0x60	then -- ROR
						arg = setZN((P & flagC) | uint8_t(bit7toC(arg) << 1))
--DEBUG(asm):write'ROR'
					end

					if b234 == 0x08 then
						-- immediate
						A = arg
					else
						-- not immediate, write back to address
						nespoke(addr, arg)
					end
				end

			else	-- bit 7 set
				-- 1xx0:0010
				if b234 == 0x10 then
--DEBUG(asm):write'STP'
					-- 1xx1:0010
					-- 92 B2 D2 F2 = STP
				else

-- TODO TODO maybe things would be better if I separated out bit7==set first ...

					if b567 == 0x80 then
						-- ST*
						-- 0x92 is STP handled above
						if op == 0x86 then
--DEBUG(asm):write('STX'..argStrZP())
							nespoke(readPC(), X)	-- STX
						elseif op == 0x8A then
--DEBUG(asm):write'TXA'
							A = setZN(X) 	-- TXA
						elseif op == 0x8E then
--DEBUG(asm):write('STX'..argStrAbs())
							nespoke(readPCw(), X)	-- STX
						elseif op == 0x96 then
							nespoke(uint8_t(readPC() + Y), X)	-- STX
--DEBUG(asm):write('STX'..argStrZPY())
						elseif op == 0x9A then
							S = X 		-- TXS
--DEBUG(asm):write'TXS'
						elseif op == 0x9E then
							error'TODO'
							--TODO ?	-- SHX
--DEBUG(asm):write'SHX'
						else
--DEBUG(asm):write'NOP'
							-- 0x82 = NOP
						end

					elseif b567 == 0xA0 then

						-- LD* / T*
						-- 0xB2 is STP handled above
						if op == 0xA2 then
--DEBUG(asm):write('LDX'..argStrImm())
							X = setZN(readPC()) 	-- LDX
						elseif op == 0xA6 then
--DEBUG(asm):write('LDX'..argStrZP())
							X = setZN(nespeek(readPC()))	-- LDX
						elseif op == 0xAA then
--DEBUG(asm):write'TAX'
							X = setZN(A)	-- TAX
						elseif op == 0xAE then
--DEBUG(asm):write('LDX'..argStrAbs())
							X = setZN(nespeek(readPCw()))	-- LDX
						elseif op == 0xB6 then
--DEBUG(asm):write('LDY'..argStrZPY())
							X = setZN(nespeek(uint8_t(readPC() + Y)))	-- LDY
						elseif op == 0xBA then
--DEBUG(asm):write'TSX'
							X = setZN(S)	-- TSX
						elseif op == 0xBE then
--DEBUG(asm):write('LDX'..argStrAbsY())
							X = setZN(nespeek(readPCw() + Y))	-- LDX
						end

					elseif b567 == 0xC0 then

						-- 0xD2 = STP handled above
						if op == 0xC6 then
							DEC(readPC())				-- DEC
--DEBUG(asm):write'DEC'
						elseif op == 0xCA then
							X = setZN(uint8_t(X - 1))	-- DEX
--DEBUG(asm):write'DEX'
						elseif op == 0xCE then
							DEC(readPCw())
--DEBUG(asm):write'DEC'
						elseif op == 0xD6 then
							DEC(uint8_t(readPC() + X))
--DEBUG(asm):write'DEC'
						elseif op == 0xDE then
							DEC(readPCw() + X)
--DEBUG(asm):write'DEC'
						else
--DEBUG(asm):write'NOP'
							-- 0xC2 = NOP
							-- 0xDA = NOP
						end

					elseif b567 == 0xE0 then
						if op == 0xE6 then
							INC(readPC())
--DEBUG(asm):write'INC'
						elseif op == 0xEE then
							INC(readPCw())
--DEBUG(asm):write'INC'
						elseif op == 0xF6 then
							INC(uint8_t(readPC() + X))
--DEBUG(asm):write'INC'
						elseif op == 0xFE then
							INC(readPCw() + X)
--DEBUG(asm):write'INC'
						else
--DEBUG(asm):write'NOP'
							-- 0xE2 = NOP
							-- 0xEA = NOP (should be INX?)
							-- 0xFA = NOP
						end
					end
				end
			end

		-- unofficial
		elseif b01 == 0x03 then
--DEBUG(asm):write'TODO op'
		end
	end
--DEBUG(asm):-- [[
--DEBUG(asm):trace(writebuf)
--DEBUG(asm):--]]
--DEBUG(asm):--[[
--DEBUG(asm):writebufy ??= 0
--DEBUG(asm):text(writebuf, 0, writebufy, 0x30, 0)
--DEBUG(asm):writebufy = uint8_t(writebufy + 8)
--DEBUG(asm):--]]
--DEBUG(asm):writebuf=''

end

update=||do

--DEBUG(asm):trace'vblank'

	-- set at the start of vblank
	PPUStatus |= 0x80

	-- set before or after?
	if PPUControl & 0x80 == 0x80 then
--DEBUG(asm):trace'NMI'
		NMI()
	end

	-- TODO count cycles and break accordingly? or nah?
	-- 1mil / 60 = 16k or so .. / avg cycles/instr = ?
	--for i=1,1 do
	--for i=1,60 do
	--for i=1,100 do
	for i=1,600 do
		cpuRun()
	end

	-- ... clear at prerender scanline 
	PPUStatus &= 0x1F
	
	-- rendering OAM ...
	cls()

	-- is background rendering enabled?
	-- (is the "nametable" the same as the "background"? or is it sprites with background bit set?)
	if PPUMask & 0x08 ~= 0 then
		map(0, 0, 32, 30, -PPUScrollX, -PPUScrollY)
	end

	-- is sprite rendering enabled?
	if PPUMask & 0x10 ~= 0 then
		for i=0,255,4 do
			local addr = n9OAMAddr + i
			local y = peek(addr)
			local sprIndex = peek(addr + 1)
			local attrs = peek(addr + 2)
			local bg = attrs & 0x20 ~= 0
			local pal = attrs & 3
			local x = peek(addr + 3)

			if i == 0 then
--print('drawing sprite #0 sprIndex '..hex(sprIndex)..' at x='..hex(x)..' y='..hex(y))
				-- TODO test write opacity and set the PPUStatus |= 0x40
				local sprX = sprIndex & 0x1F
				local sprY = (sprIndex >> 5) & 0x1F
				for dy=0,7 do
					for dx=0,7 do
						local sx = x + dx
						local sy = y + dy
						if sx >= 0 and sx < 255	-- pixel 255 is omitted
						and sy >= 0 and sy < 240
						then
							if sx >= 8
							-- I think this is wrong ...
							or (bg and PPUMask & 2 ~= 0)
							or (not bg and PPUMask & 4 ~= 0)
							then
								local sprPix = peek(n9SheetAddr + (
									dx | (sprX << 3)
									| ((dy | (sprY << 3)) << 8)
								))
								if sprPix ~= 0 then
									-- does the framebuffer matter?
									--if fbAddr(sx | (sy << 8)) ~= 0 then 
									PPUStatus |= 0x40
									--end
								end
							end
						end
					end
				end
			end

			local sx, sy = 1, 1
			if attrs & 0x80 ~= 0 then
				sy = -1
				y += 8
			end
			if attrs & 0x40 ~= 0 then
				sx = -1
				x += 8
			end
			spr(sprIndex, x, y, 1, 1,
				pal<<2, -- palette offset
				0, 		-- transparent index
				nil, 	-- sprite bit
				nil, 	-- sprite mask
				sx, sy)
		end
	end

	-- do some instuctions "outside" hislopor idk?
	for i=1,600 do
		cpuRun()
	end

	text('A='..hex(A)..' X='..hex(X)..' Y='..hex(Y)..' S='..hex(S)..' P='..hex(P)..' PC='..hex(PC,4)..' op='..hex(nespeek(PC))..' ', 0, 0, 0x30, 0x0F)
end
