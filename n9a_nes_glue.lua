--[[
can I make a NES ROM to NuMo9 converter?  "transpiler"? "emulator"?  "is not emulator"?
using this to learn:
https://www.patater.com/gbaguy/day2n.htm
https://yizhang82.dev/nes-emu-overview
https://www.nesdev.org/wiki/6502_instructions
https://www.nesdev.org/wiki/CPU_unofficial_opcodes
https://www.nesdev.org/obelisk-6502-guide/reference.html
https://github.com/skilldrick/easy6502
https://www.nesdev.org/6502_cpu.txt
https://gist.github.com/1wErt3r/4048722 <- smb dis but without addresses
https://6502disassembly.com/nes-smb/SuperMarioBros.html	<- with addresses

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
	$fffc is the start vector
bank2 sprites start at $0000
--]]

local hex=|i,n| (('%0'..(n or 2)..'X'):format(i))

do
	local nesheader = blobaddr('data', 1)

	-- read the header:
	-- https://www.nesdev.org/wiki/INES
	assert.eq(peekl(nesheader), 0x1A53454E)	-- "NES\n"
	local PRG_ROM_size = peek(nesheader+4) << 14
	local CHR_ROM_size = peek(nesheader+5) << 13
	local header_6 = peek(nesheader+6)
	-- bit 0 = nametable arrangement
	-- bit 1 = PRG RAM present at $6000-7FFF
	if (header_6 >> 2) & 1 == 1 then 
		trace'has trainer'
	end	-- trainer
	-- bit 3 = alt nametable layout
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
end

local nesrom = blobaddr('data', 0)
local nespeek = |i|peek(nesrom+i)
local nespoke = |i,v|poke(nesrom+i, v)
local nespeekw = |i|peekw(nesrom+i)
local nespokew = |i,v|pokew(nesrom+i, v)
local A = 0	-- accumulator
local X = 0	-- x-register
local Y = 0	-- y-register
local P = 0	-- process flags
local S = 0	-- stack
local PC = peekw(nesrom+0xFFFC)	-- process-counter
trace('initPC = $'..hex(PC,4))

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
local setVN=|arg|do
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
	P &= ~flagCarry
	P |= arg & flagCarry	-- carry is bit 0

	return arg	-- continue to use the arg
end

-- arg : uint8_t
local bit7toC=|arg|do
	P &= ~flagCarry
	P |= (arg >> 7) & flagCarry	-- carry is bit 0

	return arg
end

-- accepts uint8, returns int8
-- TODO peek-signed and int8_t ... casting ... etc
local s8=|x| x >= 0x80 and x - 0x100 or x

-- reads offset from PC
local branch=|offset|do PC += s8(readPC()) end

local doCompare=|reg,val|do
	if reg >= val then
		P |= flagC
	else
		P &= ~flagC
	end
	val = (reg - val) & 0xFF
	setVN(val)
end
local CMP=|src| doCompare(A, src)
local CMPMem=|addr| CMP(nespeek(addr))

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
	A = w & 0xFF
	setVN(A)
end
local SBCMem=|addr| SBC(netpeek(addr))

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
	A = tmp & 0xFF
	setVN(A)
end
local ADCMem=|addr|ADC(nespeek(addr))

local BIT=|i|do
	-- transfer bit 6 & 7 of i to bit 6 & 7 of P
	P &= ~flagNN
	P |= i & flagVN

	-- set flagZ based on `A & i`
	if A & i ~= 0 then
		P &= ~flagZ
	else
		P |= flagZ
	end
end


-- needs to & 0xFF because setVN tests for zero value,
-- and I want it to assume input is uint8_t
-- and don't want to have to & 0xFF in setVN
local DEC=|addr| nespoke(addr, setVN((nespeek(addr) - 1) & 0xFF))
local INC=|addr| nespoke(addr, setVN((nespeek(addr) + 1) & 0xFF))

local incS=||do
	S += 1
	if S >= 0x100 then
		S &= 0xFF
		trace'6502 stack underflow!'
	end
end
local decS=||do
	S -= 1
	if S < 0 then
		S &= 0xFF
		trace'6502 stack overflow!'
	end
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
	--[[ safe
	stackPush(w>>8)
	stackPush(w&0xFF)
	--]]
	-- [[ trust overflow won't happen
	decS()
	nespokew(S|0x100, w)
	decS()
	--]]
end
local stackPopw=||do
	--[[ safe
	-- depends on | evaluating left-to-right
	-- and langfix rewrites this as bit.bor(...)
	-- so this depends on lua arg evaluation being left-to-right
	return stackPop() | (stackPop() << 8)
	--]]
	-- [[ trust underflow won't happen
	incS()
	local w = netpeekw(S|0x100)
	incS()
	return w
	--]]
end

-- assigns A to A | src
-- sets VN flags by result
local ORA=|src|do A = setVN(A | src) end

-- assigns A to A | mem[addr]
-- sets VN flags by result
local ORAMem=|addr| ORA(nespeek(addr))

-- assigns A to A & src
-- sets VN flags by result
local ANDA=|src|do A = setVN(A & src) end

-- assigns A to A & mem[addr]
-- sets VN flags by result
local ANDAMem=|addr| ANDA(nespeek(addr))

-- assigns A to A ~ src
-- sets VN flags by result
local EOR=|src|do A = setVN(A ~ src) end
local EORMem=|addr| ANDA(nespeek(addr))

-- stores A at addr
local STA=|addr| nespoke(addr, A)

-- sets A from addr
-- sets VN flags by result
local LDA=|src|do A = setVN(src) end
local LDAMem=|addr| LDA(nespeek(addr))

-- reads C
-- shifts src left by 1, inserting old C
-- sets src's old bit7 to the new C
-- & 0xFF to treat as uint8
-- sets VN flags based on result
-- returns result
-- * I'm hoping all operations are evaluated left-to-right, since I'm reading C then writing C in dif bit op args
-- * NOTICE, no memory evaluation better modify C ...
local ROL=|src| setVN((P & flagC) | (bit7toC(src) << 1) & 0xFF)
local ROLMem=|addr| nespoke(addr, ROL(nespeek(addr)))

local ROR=|src| setVN((P & flagC) | (bit7toC(src) << 1) & 0xFF)
local RORMem=|addr| nespoke(addr, ROR(nespeek(addr)))

-- sets C to src's bit 7
-- shl once as uint8
-- sets VN flags by result
-- returns result
local ASL=|src| setVN((bit7toC(src) << 1) & 0xFF)
local ASLMem=|addr| nespoke(addr, ASL(nespeek(addr)))

local LSR=|src| setVN(bit0toC(src) >> 1)
local LSRMem=|addr| nespoke(addr, LSR(nespeek(addr)))

local ops = {
	-- DONE
	
-- 0xxx:xx01
	-- ORA, ANDA, EOR, ADC, STA, LDA, CMP, SBC
	-- identical arg read
	-- op bits 0xE0: 0 = OR, 1 = ANDA, 2 = EOR, 3 = ADC, 4 = STA, 5 = LDA, 6 = CMP, 7 = SBC

	-- ORA
	[0x01] = || ORAMem(nespeekw((readPC() + X) & 0xFF)),	-- (indirect,X)
	[0x05] = || ORAMem(readPC()),	-- $00
	[0x09] = || ORA(readPC()),	-- #$00
	[0x0D] = || ORAMem(readPCw()),
	[0x11] = || ORAMem(nespeekw(readPC() + Y)),
	[0x15] = || ORAMem((readPC() + X) & 0xFF),
	[0x19] = || ORAMem(readPCw() + Y),
	[0X1D] = || ORAMem(readPCw() + X),

	-- ANDA
	[0x21] = || ANDAMem(nespeekw((readPC() + X) & 0xFF)),
	[0x25] = || ANDAMem(readPC()),
	[0x29] = || ANDA(readPC()),
	[0x2D] = || ANDAMem(readPCw()),
	[0x31] = || ANDAMem(nespeekw(readPC() + Y)),
	[0x35] = || ANDAMem((readPC() + X) & 0xFF),
	[0x39] = || ANDAMem(readPCw() + Y),
	[0X3D] = || ANDAMem(readPCw() + X),

	-- EOR
	[0x41] = || EORMem(nespeekw((readPC() + X) & 0xFF)),
	[0x45] = || EORMem(readPC()),
	[0x49] = || EOR(readPC()),
	[0x4D] = || EORMem(readPCw()),
	[0x51] = || EORMem(nespeekw(readPC() + Y)),
	[0x55] = || EORMem((readPC() + X) & 0xFF),
	[0x59] = || EORMem(readPCw() + Y),
	[0x5D] = || EORMem(readPCw() + X),

	-- ADC
	[0x61] = || ADCMem(nespeekw((readPC() + X) & 0xFF)),
	[0x65] = || ADCMem(readPC()),
	[0x69] = || ADC(readPC()),
	[0x6D] = || ADCMem(readPCw()),
	[0x71] = || ADCMem(nespeekw(readPC()) + Y),
	[0x75] = || ADCMem((readPC() + X) & 0xFF),
	[0x79] = || ADCMem(readPCw() + Y),
	[0x7D] = || ADCMem(readPCw() + X),

	-- STA
	[0x81] = || STA(nespeekw((readPC() + X) & 0xFF)), 
	[0x85] = || STA(readPC()),
	-- 0x89 = NOP, STA is a mem op, can't do STA non-mem ...
	[0x8D] = || STA(readPCw()),	
	[0x91] = || STA(nespeekw(readPC()) + Y),	
	[0x95] = || STA((readPC() + X) & 0xFF),	
	[0x99] = || STA(readPCw() + Y),	
	[0x9D] = || STA(readPCw() + X),	

	-- LDA
	[0xA1] = || LDAMem(nespeekw((readPC() + X) & 0xFF)),	
	[0xA5] = || LDAMem(readPC()),	
	[0xA9] = || LDA(readPC()),			
	[0xAD] = || LDAMem(readPCw()),	
	[0xB1] = || LDAMem(nespeekw(readPC()) + Y),	
	[0xB5] = || LDAMem((readPC() + X) & 0xFF),	
	[0xB9] = || LDAMem(readPCw() + Y),	
	[0xBD] = || LDAMem(readPCw() + X),	

	-- CMP
	[0xC1] = || CMPMem(nespeekw((readPC() + X) & 0xFF)),	-- CMP
	[0xC5] = || CMPMem(readPC()),	-- CMP
	[0xC9] = || CMP(readPC()),	-- CMP
	[0xCD] = || CMPMem(readPCw()),	-- CMP
	[0xD1] = || CMPMem(nespeekw(readPC()) + Y),	-- CMP
	[0xD5] = || CMPMem((readPC() + X) & 0xFF),	-- CMP
	[0xD9] = || CMPMem(readPCw() + Y),	-- CMP
	[0xDD] = || CMPMem(readPCw() + X),	-- CMP

	-- SBC
	[0xE1] = || SBCMem(nespeekw((readPC() + X) & 0xFF)),	
	[0xE5] = || SBCMem(readPC()),	
	[0xE9] = || SBC(readPC()), 
	[0xED] = || SBCMem(readPCw()),				
	[0xF1] = || SBCMem(nespeekw(readPC()) + Y),	
	[0xF5] = || SBCMem((readPC() + X) & 0xFF),	
	[0xF9] = || SBCMem(readPCw() + Y),			
	[0xFD] = || SBCMem(readPCw() + X),			

	
-- 0xx0:0000
	-- break
	[0x00] = ||do
		nespokew(S, PC)
		PC = nespeekw(0xFFFE)
		P |= flagB
	end,	-- BRK
	[0x20] = ||do
		local addr = readPCw()
		stackPushw((PC - 1) & 0xFFFF)
		PC = addr
	end,	-- JSR
	[0x40] = ||do
		P = stackPop() | flagB_
		PC = stackPopw()
	end,	-- RTI
	[0x60] = ||do
		PC = stackPopw() + 1
	end,	-- RTS

-- 0xx1:0000
	-- branch-on-flag
	-- op & 0x10 <=> branch on flag
	-- op & 0x20: 0 means branch on flag clear, 1 means branch on flag set
	-- missed their chance to swap V and N ... then we'd have ((op >> 6) + 6) & 7 == flag bit
	[0x10] = ||do if P & flagN == 0 then branch() else PC += 1 end end,	-- BPL
	[0x30] = ||do if P & flagN ~= 0 then branch() else PC += 1 end end,	-- BMI
	[0x50] = ||do if P & flagV == 0 then branch() else PC += 1 end end,	-- BVC
	[0x70] = ||do if P & flagV ~= 0 then branch() else PC += 1 end end,	-- BVS
	[0x90] = ||do if P & flagC == 0 then branch() else PC += 1 end end,	-- BCC
	[0xB0] = ||do if P & flagC ~= 0 then branch() else PC += 1 end end, -- BCS
	[0xD0] = ||do if P & flagZ == 0 then branch() else PC += 1 end end, -- BNE
	[0xF0] = ||do if P & flagZ ~= 0 then branch() else PC += 1 end end, -- BEQ

-- 0xx1:1000
	-- CL* / SE*
	[0x18] = ||do P &= ~flagC end,	-- CLC
	[0x38] = ||do P |= flagC end,	-- SEC
	[0x58] = ||do P &= ~flagI end,	-- CLI
	[0x78] = ||do P |= flagI end,	-- SEI
	-- there's no SEV ...
	-- and CLV goes where SEV should've gone
	[0xB8] = ||do P &= ~flagV end,	-- CLV
	[0xD8] = ||do P &= ~flagD end,	-- CLD
	[0xF8] = ||do P |= flagD end,	-- SED

	-- PH* / PL*
	[0x08] = || stackPush(P|flagB_), -- PHP
	[0x28] = ||do P = stackPop() | flagB_ end, -- PLP
	[0x48] = || stackPush(A),	-- PHA
	[0x68] = ||do A = setVN(stackPop()) end,	-- PLA

	-- BIT
	[0x24] = || BIT(nespeek(readPC())),
	[0x2C] = || BIT(nespeek(readPCw())),
	
	-- JMP
	[0x4C] = ||do PC = readPCw() end,	
	[0x6C] = ||do PC = nespeekw(readPCw()) end,	

	[0x84] = || nespoke(readPC(), Y),	-- STY
	[0x88] = ||do Y = setVN((Y - 1) & 0xFF) end,	-- DEY
	[0x8C] = || nespoke(readPCw(), Y),	-- STY
	[0x94] = || nespoke((readPC() + X) & 0xFF, Y),	-- STY
	[0xA4] = ||do Y = setVN(nespeek(readPC())) end,	-- LDY
	[0xA8] = ||do Y = setVN(A) end,	-- TAY
	[0xAC] = ||do Y = setVN(nespeek(readPCw())) end,	-- LDY
	[0xB4] = ||do Y = setVN(nespeek((readPC() + X) & 0xFF)) end,	-- LDY
	[0xBC] = ||do Y = setVN(nespeek(readPCw() + X)) end,	-- LDY
	[0xC0] = || doCompare(Y, readPC()),						-- CPY
	[0xC4] = || doCompare(Y, nespeek(readPC())),	-- CPY
	[0xC8] = ||do Y = setVN((Y + 1) & 0xFF) end,	-- INY
	[0xCC] = || doCompare(Y, nespeek(readPCw())),	-- CPY
	[0xE0] = || doCompare(X, readPC()),	-- CPX
	[0xE4] = || doCompare(X, nespeek(readPC())),	-- CPX
	[0xE8] = ||do X = setVN((X + 1) & 0xFF) end,	-- INX
	[0xEC] = || doCompare(X, nespeek(readPCw())),			-- CPX
	
	[0xA2] = ||do X = setVN(readPC()) end,	-- LDX

	
-- 0xxx:0010
	-- STP
	-- 0x02 = STP
	-- 0x12 = STP
	-- 0x22 = STP
	-- 0x32 = STP
	-- 0x42 = STP
	-- 0x52 = STP
	-- 0x62 = STP
	-- 0x72 = STP

-- 0xx1:1010 = NOP
	-- 0x1A = NOP
	-- 0x3A = NOP
	-- 0x5A = NOP
	-- 0x7A = NOP

-- 0xxx:xx10
	-- ASL, ROL, LSR, ROR
	-- match except op bit 5: 0 means ASL, 1 means ROL
	-- ... no SLO, RLA, SRE, RRA ...

	-- ASL
	[0x06] = || ASLMem(readPC()),	-- $00
	[0x0A] = ||do A = ASL(A) end,
	[0x0E] = || ASLMem(readPCw()),
	[0x16] = || ASLMem((readPC() + X) & 0xFF),
	[0X1E] = || ASLMem(readPCw() + X),

	-- ROL
	[0x26] = || ROLMem(readPC()),
	[0x2A] = ||do A = ROL(A) end,
	[0x2E] = || ROLMem(readPCw()),
	[0x36] = || ROLMem((readPC() + X) & 0xFF),
	[0x3E] = || ROLMem(readPCw() + X),

	-- LSR
	[0x46] = || LSRMem(readPC()),
	[0X4A] = ||do A = LSR(A) end,
	[0x4E] = || LSRMem(readPCw()),
	[0x56] = || LSRMem((readPC() + X) & 0xFF),
	[0x5E] = || LSRMem(readPCw() + X),

	-- ROR
	[0x66] = || RORMem(readPC()),
	[0x6A] = || do A = ROR(A) end,
	[0x6E] = || RORMem(readPCw()),
	[0x76] = || RORMem((readPC() + X) & 0xFF),
	[0x7E] = || RORMem(readPCw() + X),


	-- 0x92 = STP
	-- 0xB2 = STP
	-- 0xD2 = STP
	-- 0xF2 = STP


	-- ST*
	-- 0x82 = NOP
	[0x86] = || nespoke(readPC(), X),	-- STX
	[0x8A] = ||do A = setVN(X) end,	-- TXA
	[0x8E] = || nespoke(readPCw(), X),	-- STX
	-- 0x92 = STP
	[0x96] = || nespoke((readPC() + Y) & 0xFF, X),	-- STX
	[0x9A] = ||do S = X end,		-- TXS
	-- 0x9E	-- SHX

	-- LD* / T*
	-- 0xA2 = LDX
	[0xA6] = ||do X = setVN(nespeek(readPC())) end,	-- LDX
	[0xAA] = ||do X = setVN(A) end,	-- TAX
	[0xAE] = ||do X = setVN(nespeek(readPCw())) end,	-- LDX
	-- 0xB2 = STP
	[0xB6] = ||do X = setVN(nespeek((readPC() + Y) & 0xFF)) end,	-- LDY
	[0xBA] = ||do X = setVN(S) end,	-- TSX
	[0xBE] = ||do X = setVN(nespeek(readPCw() + Y)) end,	-- LDX

	-- 0xC2 = NOP
	[0xC6] = || DEC(readPC()),	-- DEC
	[0xCA] = ||do X = setVN((X - 1) & 0xFF) end,	-- DEX
	[0xCE] = || DEC(readPCw()),
	-- 0xD2 = STP
	[0xD6] = || DEC((readPC() + X) & 0xFF),
	-- 0xDA = NOP
	[0xDE] = || DEC(readPCw() + X),

	-- 0xE2 = NOP
	[0xE6] = || INC(readPC()),
	-- 0xEA = NOP
	[0xEE] = || INC(readPCw()),
	-- 0xF2 = STP
	[0xF6] = || INC((readPC() + X) & 0xFF),
	-- 0xFA = NOP
	[0xFE] = || INC(readPCw() + X),

	-- LD* / T*
	-- 0xA3 = LAX
	-- 0xAB = LAX
	-- 0xAF = LAX
	-- 0xB3 = LAX
	-- 0xB7 = LAX
	-- 0xBB = LAS
	-- 0xBF = LAX
}

local argStrRel=||
	' $+'..hex(0xFF & s8(nespeek(PC)))..' = $'..hex(PC+1+s8(nespeek(PC)),4)

local argStrFor234=|b234|do
	if b234 == 0x00 then
		return ' ($'..hex(nespeek(PC))
			..',X) = ($'..hex((nespeek(PC) + X) & 0xFF)
			..') = $'..hex(nespeekw((nespeek(PC) + X) & 0xFF), 4)
			..' = '..hex(nespeek(nespeekw((nespeek(PC) + X) & 0xFF)))
	elseif b234 == 0x02 then
		return ' $'..hex(nespeek(PC))
			..' = '..hex(nespeek(nespeek(PC)))
	elseif b234 == 0x04 then
		return ' $'..hex(readPCw(),4)
			..' = '..hex(nespeek(readPCw()))
	elseif b234 == 0x06 then
			return ' ($'..nespeek(PC)
				..',Y) = ($'..hex(nespeek(PC) + Y,4)
				..') = $'..hex(nespeekw(nespeek(PC) + Y),4)
				..' = '..hex(nespeek(nespeekw(nespeek(PC) + Y)))
	elseif b234 == 0x08 then
		return ' #$'..hex(nespeek(PC))
	elseif b234 == 0x0A then
		return ' = $'..hex(nespeek((nespeek(PC) + X) & 0xFF))
	elseif b234 == 0x0C then
		return ' = $'..hex(nespeek((readPCw() + Y) & 0xFFFF))
	elseif b234 == 0x0E then
		return ' = $'..hex(nespeek((readPCw() + X) & 0xFFFF))
	end
end

local writebuf=''
local write=|...| do writebuf ..= table{...}:mapi(tostring):concat'\t' end

update=||do
	-- TODO count cycles and break accordingly? or nah?
	for i=1,1 do
	--for i=1,100 do
write(
	'A='..hex(A)
	..' X='..hex(X)
	..' Y='..hex(Y)
	..' S='..hex(S)
	..' P='..hex(P)
	..' PC='..hex(PC,4)
	..' op='..hex(nespeek(PC))
	..' '
)		
		local op = readPC()

		-- https://www.nesdev.org/wiki/CPU_unofficial_opcodes
		local b01 = bit.band(op, 0x03)	-- 00 01 02 03
		local b567 = bit.band(op, 0xE0)	-- 00 20 40 60 80 A0 C0 E0
		local b234 = bit.band(op, 0x0E)	-- 00 04 08 0C 10 14 08 1C

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
write(({'BPL', 'BMI'})[test+1]..argStrRel())
				elseif b67 == 0x40 then
					shr = bitV
write(({'BVC', 'BVS'})[test+1]..' $'..hex(0xFF & s8(nespeek(PC)))..' ($'..hex(PC+1+s8(nespeek(PC)),4)..')')
				elseif b67 == 0x80 then
					shr = bitC
write(({'BCC', 'BCS'})[test+1]..argStrRel())
				elseif b67 == 0xC0 then
					shr = bitZ
write(({'BNE', 'BEQ'})[test+1]..argStrRel())
				end

				if (P >> shr) & 1 == test then
					branch()
				else
					PC += 1
				end

			-- xxx1:1000
			elseif op & 0x1F == 0x18 then

			-- 0xx1:1000
				if op == 0x18 then
					P &= ~flagC	-- CLC
write'CLC'
				elseif op == 0x38 then
					P |= flagC	-- SEC
write'SEC'
				elseif op == 0x58 then
					P &= ~flagI	-- CLI
write'CLI'
				elseif op == 0x78 then
					P |= flagI 	-- SEI
write'SEI'
				elseif op == 0x98 then
					-- TYA is here for some reason
					-- there's no SEV ...
					-- and CLV goes where SEV should've gone
					A = setVN(Y)	-- TYA
write'TYA'				
				elseif op == 0xB8 then
					P &= ~flagV 	-- CLV
write'CLV'				
				elseif op == 0xD8 then
					P &= ~flagD 	-- CLD
write'CLD'				
				elseif op == 0xF8 then
					P |= flagD 	-- SED
write'SED'				
				end

			-- xxxy:yy00 for yyy != 100 and yy != 110
			else
				if op & 0x80 == 0 then	-- bit 7 not set
					if op == 0x00 then	-- BRK
						nespokew(S, PC)
						PC = nespeekw(0xFFFE)
						P |= flagB
					elseif op == 0x20 then	-- JSR
						local addr = readPCw()
						stackPushw((PC - 1) & 0xFFFF)
						PC = addr
					elseif op == 0x40 then	-- RTI
						P = stackPop() | flagB_
						PC = stackPopw()
					elseif op == 0x60 then	-- RTS
						PC = stackPopw() + 1
					
					elseif op == 0x08 then
						stackPush(P | flagB_) -- PHP
					elseif op == 0x28 then
						P = stackPop() | flagB_  -- PLP
					elseif op == 0x48 then
						stackPush(A)	-- PHA
					elseif op == 0x68 then
						A = setVN(stackPop()) 	-- PLA
					
					-- BIT
					elseif op == 0x24 then
						BIT(nespeek(readPC()))
					elseif op == 0x2C then
						BIT(nespeek(readPCw()))
	
					-- JMP
					elseif op == 0x4C then
						PC = readPCw() 
					elseif op == 0x6C then
						PC = nespeekw(readPCw()) 
					
					-- else 04 0C 14 1C 34 3C 44 54 5C 64 74 7C is NOP
					end
				
				else	-- bit 7 set
					-- these match up closely with RMW lower half i.e. op & 0x83 == 0x82
					
					-- 0x80 NOP
					if op == 0x84 then
						nespoke(readPC(), Y)	-- STY
					elseif op == 0x88 then
						Y = setVN((Y - 1) & 0xFF) 	-- DEY
					elseif op == 0x8C then
						nespoke(readPCw(), Y)	-- STY
					-- 0x90 handled by the branch set
					elseif op == 0x94 then
						nespoke((readPC() + X) & 0xFF, Y)	-- STY
					-- 0x98 handled by SE*/CL* set
					elseif op == 0x9C then	-- SHY 
						write'TODO'
					elseif op == 0xA0 then	-- LDY
						Y = setVN(readPC())
					elseif op == 0xA4 then
						Y = setVN(nespeek(readPC())) 	-- LDY
					elseif op == 0xA8 then
						Y = setVN(A) 	-- TAY
					elseif op == 0xAC then
						Y = setVN(nespeek(readPCw())) 	-- LDY
					-- 0xB0 = handled by branch set
					elseif op == 0xB4 then
						Y = setVN(nespeek((readPC() + X) & 0xFF)) 	-- LDY
					-- 0xB8 handled by SE*/CL* set
					elseif op == 0xBC then
						Y = setVN(nespeek(readPCw() + X)) 	-- LDY
					elseif op == 0xC0 then
						doCompare(Y, readPC())						-- CPY
					elseif op == 0xC4 then
						doCompare(Y, nespeek(readPC()))	-- CPY
					elseif op == 0xC8 then
						Y = setVN((Y + 1) & 0xFF) 	-- INY
					elseif op == 0xCC then
						doCompare(Y, nespeek(readPCw()))	-- CPY
					-- 0xD0 handled by branch set
					-- 0xD4 = NOP
					-- 0xD8 handled by SE*/CL* set
					-- 0xDC = NOP
					elseif op == 0xE0 then
						doCompare(X, readPC())	-- CPX
					elseif op == 0xE4 then
						doCompare(X, nespeek(readPC()))	-- CPX
					elseif op == 0xE8 then
						X = setVN((X + 1) & 0xFF) 	-- INX
					elseif op == 0xEC then
						doCompare(X, nespeek(readPCw()))			-- CPX
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

				if b567 == 0x00 then		-- 01 05 09 0D 11 15 19 1D = ORA
write('ORA'..argStrFor234(b234))
				elseif b567 == 0x20 then	-- 21 25 29 2D 31 35 39 3D = AND
write('AND'..argStrFor234(b234))				
				elseif b567 == 0x40 then	-- 41 45 49 4D 51 55 59 5D = EOR
write('EOR'..argStrFor234(b234))
				elseif b567 == 0x60 then	-- 61 65 69 6D 71 75 79 7D = ADC
write('ADC'..argStrFor234(b234))
				elseif b567 == 0x80 then	-- 81 85 8D 91 95 99 9D = STA
					if b234 ~= 0x08 then	-- 89 is NOP
write('STA'..argStrFor234(b234))
					else
write'NOP'					-- does this still inc the PC?
					end
				elseif b567 == 0xA0 then	-- A1 A5 A9 AD B1 B5 B9 BD = LDA
write('LDA'..argStrFor234(b234))
				elseif b567 == 0xC0 then	-- C1 C5 C9 CD D1 D5 D9 DD = CMP
write('CMP'..argStrFor234(b234))
				elseif b567 == 0xE0 then	-- E1 E5 E9 ED F1 F5 F9 FD = SBC
write('SBC'..argStrFor234(b234))
				end


				if b234 == 0x08 then		-- immediate
					arg = readPC()	-- #$00
				else						-- non-immediate, i.e. memory
					if b234 == 0x00 then
						arg = nespeekw((readPC() + X) & 0xFF)	-- (indirect,X)			
					elseif b234 == 0x02 then
						arg = readPC()	-- $00
					elseif b234 == 0x04 then
						arg = readPCw()
					elseif b234 == 0x06 then
						arg = nespeekw(readPC() + Y)
					elseif b234 == 0x0A then
						arg = (readPC() + X) & 0xFF
					elseif b234 == 0x0C then
						arg = (readPCw() + Y) & 0xFFFF
					elseif b234 == 0x0E then
						arg = (readPCw() + X) & 0xFFFF
					end
					arg = nespeek(arg)
				end

				if b567 == 0x00 then		-- 01 05 09 0D 11 15 19 1D = ORA
					A = setVN(A | arg)
				elseif b567 == 0x20 then	-- 21 25 29 2D 31 35 39 3D = AND
					A = setVN(A & arg)
				elseif b567 == 0x40 then	-- 41 45 49 4D 51 55 59 5D = EOR
					A = setVN(A ~ arg)
				elseif b567 == 0x60 then	-- 61 65 69 6D 71 75 79 7D = ADC
					ADC(arg)
				elseif b567 == 0x80 then	-- 81 85 8D 91 95 99 9D = STA
					if b234 ~= 0x08 then	-- 89 is NOP
						STA(arg)
					else
						-- NOP ... does it still read the arg and inc the PC?
					end
				elseif b567 == 0xA0 then	-- A1 A5 A9 AD B1 B5 B9 BD = LDA
					LDA(arg)
				elseif b567 == 0xC0 then	-- C1 C5 C9 CD D1 D5 D9 DD = CMP
					CMP(arg)
				elseif b567 == 0xE0 then	-- E1 E5 E9 ED F1 F5 F9 FD = SBC
					SBC(arg)
				end

			-- RMW
			elseif b01 == 0x02 then
				-- xxxx:xx10

				if op & 0x80 == 0 then	-- bit 7 clear

					if b234 == 0x02 
					or b234 == 0x12
					then
						-- 0xxx:0010
						-- 02 12 22 32 42 52 62 72 = STP
					elseif b234 == 0x1A then
						-- 1A 3A 5A 7A = NOP
					else
						local arg, addr
						if b234 == 0x0A then
							-- immediate
							arg = A
						else
							-- not immediate, use address
							-- (should follow same addressing as ALU, maybe merge?)
							if b234 == 0x06 then
								addr = readPC()
							elseif b234 == 0x0E then
								addr = readPCw()
							elseif b234 == 0x16 then
								addr = (readPC() + X) & 0xFF
							elseif b234 == 0x1E then
								addr = (readPCw() + X) & 0xFFFF
							end
							arg = nespeek(addr)
						end

						if b567 == 0x00	then -- ASL
							arg = ASL(arg)
write'ASL'						
						elseif b567 == 0x20	then -- ROL
							arg = ROL(arg)
write'ROL'						
						elseif b567 == 0x40	then -- LSR
							arg = LSR(arg)
write'LSR'						
						elseif b567 == 0x60	then -- ROR
							arg = ROR(arg)
write'ROR'						
						end
						
						if b234 == 0x0A then
							-- immediate
							A = arg
						else
							-- not immediate, write back to address
							nespoke(addr, arg)
						end
					end
				
				else	-- bit 7 set
					-- 1xx0:0010
					if b234 == 0x12 then
						-- 1xx1:0010
						-- 92 B2 D2 F2 = STP
					else

-- TODO TODO maybe things would be better if I separated out bit7==set first ...
						
						if b567 == 0x80 then
							-- ST*
							-- 0x92 is STP handled above
							if op == 0x86 then
								nespoke(readPC(), X)	-- STX
write'STX'							
							elseif op == 0x8A then
								A = setVN(X) 	-- TXA
write'TXA'							
							elseif op == 0x8E then 
								nespoke(readPCw(), X)	-- STX
write'STX'							
							elseif op == 0x96 then
								nespoke((readPC() + Y) & 0xFF, X)	-- STX
write'STX'							
							elseif op == 0x9A then
								S = X 		-- TXS
write'TXS'							
							elseif op == 0x9E then
								write'SHX'	-- SHX
write'SHX'							
							else
								-- 0x82 = NOP
write'NOP'							
							end

						elseif b567 == 0xA0 then
							
							-- LD* / T*
							-- 0xB2 is STP handled above
							if op == 0xA2 then
								X = setVN(readPC()) 	-- LDX
write'LDX'							
							elseif op == 0xA6 then
								X = setVN(nespeek(readPC()))	-- LDX
write'LDX'							
							elseif op == 0xAA then
								X = setVN(A)	-- TAX
write'TAX'							
							elseif op == 0xAE then
								X = setVN(nespeek(readPCw()))	-- LDX
write'LDX'							
							elseif op == 0xB6 then
								X = setVN(nespeek((readPC() + Y) & 0xFF))	-- LDY
write'LDY'							
							elseif op == 0xBA then
								X = setVN(S)	-- TSX
write'TSX'							
							elseif op == 0xBE then
								X = setVN(nespeek(readPCw() + Y))	-- LDX
write'LDX'							
							end

						elseif b567 == 0xC0 then
							
							-- 0xD2 = STP handled above
							if op == 0xC6 then
								DEC(readPC())				-- DEC
write'DEC'							
							elseif op == 0xCA then
								X = setVN((X - 1) & 0xFF)	-- DEX
write'DEX'							
							elseif op == 0xCE then
								DEC(readPCw())
write'DEC'							
							elseif op == 0xD6 then
								DEC((readPC() + X) & 0xFF)
write'DEC'							
							elseif op == 0xDE then
								DEC(readPCw() + X)
write'DEC'							
							else
								-- 0xC2 = NOP
								-- 0xDA = NOP
write'NOP'							
							end

						elseif b567 == 0xE0 then
							if op == 0xE6 then
								INC(readPC())
write'INC'							
							elseif op == 0xEE then
								INC(readPCw())
write'INC'							
							elseif op == 0xF6 then
								INC((readPC() + X) & 0xFF)
write'INC'							
							elseif op == 0xFE then
								INC(readPCw() + X)
write'INC'							
							else
								-- 0xE2 = NOP
								-- 0xEA = NOP (should be INX?)
								-- 0xFA = NOP
write'NOP'							
							end
						end
					end
				end

			-- unofficial
			elseif b01 == 0x03 then
				-- TODO 
			end
		end
trace(writebuf) writebuf=''
	end
end
