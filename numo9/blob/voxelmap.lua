require 'ext.gc'	-- make sure luajit can __gc lua-tables
local ffi = require 'ffi'
local assert = require 'ext.assert'
local class = require 'ext.class'
local table = require 'ext.table'
local vector = require 'ffi.cpp.vector-lua'
local vec3i = require 'vec-ffi.vec3i'
local vec4us = require 'vec-ffi.vec4us'
local matrix_ffi = require 'matrix.ffi'
local gl = require 'gl'
local glreport = require 'gl.report'
local glglobal = require 'gl.global'
local GLArrayBuffer = require 'gl.arraybuffer'
local GLVertexArray = require 'gl.vertexarray'
local GLAttribute = require 'gl.attribute'

local Blob = require 'numo9.blob.blob'

local numo9_rom = require 'numo9.rom'
local spriteSheetSize = numo9_rom.spriteSheetSize
local voxelmapSizeType = numo9_rom.voxelmapSizeType
local voxelMapEmptyValue = numo9_rom.voxelMapEmptyValue
local Voxel = numo9_rom.Voxel

local numo9_video = require 'numo9.video'
local Numo9Vertex = numo9_video.Numo9Vertex


local uint8_t_p = ffi.typeof'uint8_t*'
local int32_t = ffi.typeof'int32_t'
local Voxel_p = ffi.typeof('$*', Voxel)


-- also in numo9/video.lua
-- but it doesn't calc / return w, only x y z
local function vec3to3(m, x, y, z)
	x = tonumber(x)
	y = tonumber(y)
	z = tonumber(z)
	return
		m[0] * x + m[4] * y + m[ 8] * z + m[12],
		m[1] * x + m[5] * y + m[ 9] * z + m[13],
		m[2] * x + m[6] * y + m[10] * z + m[14]
end

-- orientation rotations for the upper 6 rotation bits of the voxel
-- the first 3 axis are for rotations, and have 3 entries for each 90 degree rotation
-- the second 3 are for scales, and have 1 entry for the scale in the x, y, and z direction.
-- This represents a left-multiply of the rotation to the orientation.
-- orientationRotations[orientation+1][axis+1][angle in 90 degree increments +1] = 0-based orientation
local orientationRotations = {
	{{16, 10, 26},{4, 8, 12},{1, 2, 3},{32},{34},{40}},
	{{13, 9, 5},{17, 11, 27},{2, 3, 0},{35},{33},{41}},
	{{24, 8, 18},{14, 10, 6},{3, 0, 1},{34},{32},{42}},
	{{7, 11, 15},{25, 9, 19},{0, 1, 2},{33},{35},{43}},
	{{17, 14, 25},{8, 12, 0},{5, 6, 7},{44},{46},{36}},
	{{1, 13, 9},{18, 15, 26},{6, 7, 4},{47},{45},{37}},
	{{27, 12, 19},{2, 14, 10},{7, 4, 5},{46},{44},{38}},
	{{11, 15, 3},{24, 13, 16},{4, 5, 6},{45},{47},{39}},
	{{18, 2, 24},{12, 0, 4},{9, 10, 11},{40},{42},{32}},
	{{5, 1, 13},{19, 3, 25},{10, 11, 8},{43},{41},{33}},
	{{26, 0, 16},{6, 2, 14},{11, 8, 9},{42},{40},{34}},
	{{15, 3, 7},{27, 1, 17},{8, 9, 10},{41},{43},{35}},
	{{19, 6, 27},{0, 4, 8},{13, 14, 15},{36},{38},{44}},
	{{9, 5, 1},{16, 7, 24},{14, 15, 12},{39},{37},{45}},
	{{25, 4, 17},{10, 6, 2},{15, 12, 13},{38},{36},{46}},
	{{3, 7, 11},{26, 5, 18},{12, 13, 14},{37},{39},{47}},
	{{10, 26, 0},{7, 24, 13},{17, 18, 19},{48},{50},{56}},
	{{14, 25, 4},{11, 27, 1},{18, 19, 16},{51},{49},{57}},
	{{2, 24, 8},{15, 26, 5},{19, 16, 17},{50},{48},{58}},
	{{6, 27, 12},{3, 25, 9},{16, 17, 18},{49},{51},{59}},
	{{11, 15, 3},{24, 13, 16},{4, 5, 6},{45},{47},{39}},
	{{17, 14, 25},{8, 12, 0},{5, 6, 7},{44},{46},{36}},
	{{1, 13, 9},{18, 15, 26},{6, 7, 4},{47},{45},{37}},
	{{27, 12, 19},{2, 14, 10},{7, 4, 5},{46},{44},{38}},
	{{8, 18, 2},{13, 16, 7},{25, 26, 27},{56},{58},{48}},
	{{4, 17, 14},{9, 19, 3},{26, 27, 24},{59},{57},{49}},
	{{0, 16, 10},{5, 18, 15},{27, 24, 25},{58},{56},{50}},
	{{12, 19, 6},{1, 17, 11},{24, 25, 26},{57},{59},{51}},
	{{9, 5, 1},{16, 7, 24},{14, 15, 12},{39},{37},{45}},
	{{25, 4, 17},{10, 6, 2},{15, 12, 13},{38},{36},{46}},
	{{3, 7, 11},{26, 5, 18},{12, 13, 14},{37},{39},{47}},
	{{19, 6, 27},{0, 4, 8},{13, 14, 15},{36},{38},{44}},
	{{48, 42, 58},{36, 40, 44},{33, 34, 35},{0},{2},{8}},
	{{45, 41, 37},{49, 43, 59},{34, 35, 32},{3},{1},{9}},
	{{56, 40, 50},{46, 42, 38},{35, 32, 33},{2},{0},{10}},
	{{39, 43, 47},{57, 41, 51},{32, 33, 34},{1},{3},{11}},
	{{49, 46, 57},{40, 44, 32},{37, 38, 39},{12},{14},{4}},
	{{33, 45, 41},{50, 47, 58},{38, 39, 36},{15},{13},{5}},
	{{59, 44, 51},{34, 46, 42},{39, 36, 37},{14},{12},{6}},
	{{43, 47, 35},{56, 45, 48},{36, 37, 38},{13},{15},{7}},
	{{50, 34, 56},{44, 32, 36},{41, 42, 43},{8},{10},{0}},
	{{37, 33, 45},{51, 35, 57},{42, 43, 40},{11},{9},{1}},
	{{58, 32, 48},{38, 34, 46},{43, 40, 41},{10},{8},{2}},
	{{47, 35, 39},{59, 33, 49},{40, 41, 42},{9},{11},{3}},
	{{51, 38, 59},{32, 36, 40},{45, 46, 47},{4},{6},{12}},
	{{41, 37, 33},{48, 39, 56},{46, 47, 44},{7},{5},{13}},
	{{57, 36, 49},{42, 38, 34},{47, 44, 45},{6},{4},{14}},
	{{35, 39, 43},{58, 37, 50},{44, 45, 46},{5},{7},{15}},
	{{42, 58, 32},{39, 56, 45},{49, 50, 51},{16},{18},{24}},
	{{46, 57, 36},{43, 59, 33},{50, 51, 48},{19},{17},{25}},
	{{34, 56, 40},{47, 58, 37},{51, 48, 49},{18},{16},{26}},
	{{38, 59, 44},{35, 57, 41},{48, 49, 50},{17},{19},{27}},
	{{43, 47, 35},{56, 45, 48},{36, 37, 38},{13},{15},{7}},
	{{49, 46, 57},{40, 44, 32},{37, 38, 39},{12},{14},{4}},
	{{33, 45, 41},{50, 47, 58},{38, 39, 36},{15},{13},{5}},
	{{59, 44, 51},{34, 46, 42},{39, 36, 37},{14},{12},{6}},
	{{40, 50, 34},{45, 48, 39},{57, 58, 59},{24},{26},{16}},
	{{36, 49, 46},{41, 51, 35},{58, 59, 56},{27},{25},{17}},
	{{32, 48, 42},{37, 50, 47},{59, 56, 57},{26},{24},{18}},
	{{44, 51, 38},{33, 49, 43},{56, 57, 58},{25},{27},{19}},
	{{41, 37, 33},{48, 39, 56},{46, 47, 44},{7},{5},{13}},
	{{57, 36, 49},{42, 38, 34},{47, 44, 45},{6},{4},{14}},
	{{35, 39, 43},{58, 37, 50},{44, 45, 46},{5},{7},{15}},
	{{51, 38, 59},{32, 36, 40},{45, 46, 47},{4},{6},{12}},
}

local specialOrientation = table{20, 21, 22, 23, 28, 29, 30, 31, 52, 53, 54, 55, 60, 61, 62, 63}
	:mapi(function(i) return true, i end)
	:setmetatable(nil)

-- inverse orientation for orientation
-- [orientation+1] = rotated orientation
local orientationInv = {0, 3, 2, 1, 12, 19, 6, 27, 8, 9, 10, 11, 4, 25, 14, 17, 26, 15, 18, 5, 27, 12, 19, 6, 24, 13, 16, 7, 25, 14, 17, 4, 32, 33, 34, 35, 36, 49, 46, 57, 40, 43, 42, 41, 44, 59, 38, 51, 58, 37, 50, 47, 57, 36, 49, 46, 56, 39, 48, 45, 59, 38, 51, 44}

-- [sideIndex+1][orientation+1] = rotated sideIndex
local rotateSideByOrientation = {
	{0, 2, 1, 3, 5, 5, 5, 5, 1, 3, 0, 2, 4, 4, 4, 4, 0, 2, 1, 3, nil, nil, nil, nil, 1, 3, 0, 2, nil, nil, nil, nil, 1, 3, 0, 2, 4, 4, 4, 4, 0, 2, 1, 3, 5, 5, 5, 5, 1, 3, 0, 2, nil, nil, nil, nil, 0, 2, 1, 3},
	{1, 3, 0, 2, 4, 4, 4, 4, 0, 2, 1, 3, 5, 5, 5, 5, 1, 3, 0, 2, nil, nil, nil, nil, 0, 2, 1, 3, nil, nil, nil, nil, 0, 2, 1, 3, 5, 5, 5, 5, 1, 3, 0, 2, 4, 4, 4, 4, 0, 2, 1, 3, nil, nil, nil, nil, 1, 3, 0, 2},
	{2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 4, 4, 4, 4, nil, nil, nil, nil, 5, 5, 5, 5, nil, nil, nil, nil, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 4, 4, 4, 4, nil, nil, nil, nil, 5, 5, 5, 5},
	{3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 5, 5, 5, 5, nil, nil, nil, nil, 4, 4, 4, 4, nil, nil, nil, nil, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 5, 5, 5, 5, nil, nil, nil, nil, 4, 4, 4, 4},
	{4, 4, 4, 4, 0, 2, 1, 3, 5, 5, 5, 5, 1, 3, 0, 2, 3, 0, 2, 1, nil, nil, nil, nil, 3, 0, 2, 1, nil, nil, nil, nil, 4, 4, 4, 4, 0, 2, 1, 3, 5, 5, 5, 5, 1, 3, 0, 2, 3, 0, 2, 1, nil, nil, nil, nil, 3, 0, 2, 1},
	{5, 5, 5, 5, 1, 3, 0, 2, 4, 4, 4, 4, 0, 2, 1, 3, 2, 1, 3, 0, nil, nil, nil, nil, 2, 1, 3, 0, nil, nil, nil, nil, 5, 5, 5, 5, 1, 3, 0, 2, 4, 4, 4, 4, 0, 2, 1, 3, 2, 1, 3, 0, nil, nil, nil, nil, 2, 1, 3, 0}
}

--[orientation+1][orientation+1] = orientation
local orientationMul = {
	{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, nil, nil, nil, nil, 24, 25, 26, 27, nil, nil, nil, nil, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, nil, nil, nil, nil, 56, 57, 58, 59},
	{1, 2, 3, 0, 5, 6, 7, 4, 9, 10, 11, 8, 13, 14, 15, 12, 17, 18, 19, 16, nil, nil, nil, nil, 25, 26, 27, 24, nil, nil, nil, nil, 33, 34, 35, 32, 37, 38, 39, 36, 41, 42, 43, 40, 45, 46, 47, 44, 49, 50, 51, 48, nil, nil, nil, nil, 57, 58, 59, 56},
	{2, 3, 0, 1, 6, 7, 4, 5, 10, 11, 8, 9, 14, 15, 12, 13, 18, 19, 16, 17, nil, nil, nil, nil, 26, 27, 24, 25, nil, nil, nil, nil, 34, 35, 32, 33, 38, 39, 36, 37, 42, 43, 40, 41, 46, 47, 44, 45, 50, 51, 48, 49, nil, nil, nil, nil, 58, 59, 56, 57},
	{3, 0, 1, 2, 7, 4, 5, 6, 11, 8, 9, 10, 15, 12, 13, 14, 19, 16, 17, 18, nil, nil, nil, nil, 27, 24, 25, 26, nil, nil, nil, nil, 35, 32, 33, 34, 39, 36, 37, 38, 43, 40, 41, 42, 47, 44, 45, 46, 51, 48, 49, 50, nil, nil, nil, nil, 59, 56, 57, 58},
	{4, 17, 14, 25, 8, 18, 2, 24, 12, 19, 6, 27, 0, 16, 10, 26, 7, 11, 15, 3, nil, nil, nil, nil, 13, 9, 5, 1, nil, nil, nil, nil, 36, 49, 46, 57, 40, 50, 34, 56, 44, 51, 38, 59, 32, 48, 42, 58, 39, 43, 47, 35, nil, nil, nil, nil, 45, 41, 37, 33},
	{5, 18, 15, 26, 9, 19, 3, 25, 13, 16, 7, 24, 1, 17, 11, 27, 4, 8, 12, 0, nil, nil, nil, nil, 14, 10, 6, 2, nil, nil, nil, nil, 37, 50, 47, 58, 41, 51, 35, 57, 45, 48, 39, 56, 33, 49, 43, 59, 36, 40, 44, 32, nil, nil, nil, nil, 46, 42, 38, 34},
	{6, 19, 12, 27, 10, 16, 0, 26, 14, 17, 4, 25, 2, 18, 8, 24, 5, 9, 13, 1, nil, nil, nil, nil, 15, 11, 7, 3, nil, nil, nil, nil, 38, 51, 44, 59, 42, 48, 32, 58, 46, 49, 36, 57, 34, 50, 40, 56, 37, 41, 45, 33, nil, nil, nil, nil, 47, 43, 39, 35},
	{7, 16, 13, 24, 11, 17, 1, 27, 15, 18, 5, 26, 3, 19, 9, 25, 6, 10, 14, 2, nil, nil, nil, nil, 12, 8, 4, 0, nil, nil, nil, nil, 39, 48, 45, 56, 43, 49, 33, 59, 47, 50, 37, 58, 35, 51, 41, 57, 38, 42, 46, 34, nil, nil, nil, nil, 44, 40, 36, 32},
	{8, 11, 10, 9, 12, 15, 14, 13, 0, 3, 2, 1, 4, 7, 6, 5, 24, 27, 26, 25, nil, nil, nil, nil, 16, 19, 18, 17, nil, nil, nil, nil, 40, 43, 42, 41, 44, 47, 46, 45, 32, 35, 34, 33, 36, 39, 38, 37, 56, 59, 58, 57, nil, nil, nil, nil, 48, 51, 50, 49},
	{9, 8, 11, 10, 13, 12, 15, 14, 1, 0, 3, 2, 5, 4, 7, 6, 25, 24, 27, 26, nil, nil, nil, nil, 17, 16, 19, 18, nil, nil, nil, nil, 41, 40, 43, 42, 45, 44, 47, 46, 33, 32, 35, 34, 37, 36, 39, 38, 57, 56, 59, 58, nil, nil, nil, nil, 49, 48, 51, 50},
	{10, 9, 8, 11, 14, 13, 12, 15, 2, 1, 0, 3, 6, 5, 4, 7, 26, 25, 24, 27, nil, nil, nil, nil, 18, 17, 16, 19, nil, nil, nil, nil, 42, 41, 40, 43, 46, 45, 44, 47, 34, 33, 32, 35, 38, 37, 36, 39, 58, 57, 56, 59, nil, nil, nil, nil, 50, 49, 48, 51},
	{11, 10, 9, 8, 15, 14, 13, 12, 3, 2, 1, 0, 7, 6, 5, 4, 27, 26, 25, 24, nil, nil, nil, nil, 19, 18, 17, 16, nil, nil, nil, nil, 43, 42, 41, 40, 47, 46, 45, 44, 35, 34, 33, 32, 39, 38, 37, 36, 59, 58, 57, 56, nil, nil, nil, nil, 51, 50, 49, 48},
	{12, 27, 6, 19, 0, 26, 10, 16, 4, 25, 14, 17, 8, 24, 2, 18, 13, 1, 5, 9, nil, nil, nil, nil, 7, 3, 15, 11, nil, nil, nil, nil, 44, 59, 38, 51, 32, 58, 42, 48, 36, 57, 46, 49, 40, 56, 34, 50, 45, 33, 37, 41, nil, nil, nil, nil, 39, 35, 47, 43},
	{13, 24, 7, 16, 1, 27, 11, 17, 5, 26, 15, 18, 9, 25, 3, 19, 14, 2, 6, 10, nil, nil, nil, nil, 4, 0, 12, 8, nil, nil, nil, nil, 45, 56, 39, 48, 33, 59, 43, 49, 37, 58, 47, 50, 41, 57, 35, 51, 46, 34, 38, 42, nil, nil, nil, nil, 36, 32, 44, 40},
	{14, 25, 4, 17, 2, 24, 8, 18, 6, 27, 12, 19, 10, 26, 0, 16, 15, 3, 7, 11, nil, nil, nil, nil, 5, 1, 13, 9, nil, nil, nil, nil, 46, 57, 36, 49, 34, 56, 40, 50, 38, 59, 44, 51, 42, 58, 32, 48, 47, 35, 39, 43, nil, nil, nil, nil, 37, 33, 45, 41},
	{15, 26, 5, 18, 3, 25, 9, 19, 7, 24, 13, 16, 11, 27, 1, 17, 12, 0, 4, 8, nil, nil, nil, nil, 6, 2, 14, 10, nil, nil, nil, nil, 47, 58, 37, 50, 35, 57, 41, 51, 39, 56, 45, 48, 43, 59, 33, 49, 44, 32, 36, 40, nil, nil, nil, nil, 38, 34, 46, 42},
	{16, 13, 24, 7, 17, 1, 27, 11, 18, 5, 26, 15, 19, 9, 25, 3, 10, 14, 2, 6, nil, nil, nil, nil, 8, 4, 0, 12, nil, nil, nil, nil, 48, 45, 56, 39, 49, 33, 59, 43, 50, 37, 58, 47, 51, 41, 57, 35, 42, 46, 34, 38, nil, nil, nil, nil, 40, 36, 32, 44},
	{17, 14, 25, 4, 18, 2, 24, 8, 19, 6, 27, 12, 16, 10, 26, 0, 11, 15, 3, 7, nil, nil, nil, nil, 9, 5, 1, 13, nil, nil, nil, nil, 49, 46, 57, 36, 50, 34, 56, 40, 51, 38, 59, 44, 48, 42, 58, 32, 43, 47, 35, 39, nil, nil, nil, nil, 41, 37, 33, 45},
	{18, 15, 26, 5, 19, 3, 25, 9, 16, 7, 24, 13, 17, 11, 27, 1, 8, 12, 0, 4, nil, nil, nil, nil, 10, 6, 2, 14, nil, nil, nil, nil, 50, 47, 58, 37, 51, 35, 57, 41, 48, 39, 56, 45, 49, 43, 59, 33, 40, 44, 32, 36, nil, nil, nil, nil, 42, 38, 34, 46},
	{19, 12, 27, 6, 16, 0, 26, 10, 17, 4, 25, 14, 18, 8, 24, 2, 9, 13, 1, 5, nil, nil, nil, nil, 11, 7, 3, 15, nil, nil, nil, nil, 51, 44, 59, 38, 48, 32, 58, 42, 49, 36, 57, 46, 50, 40, 56, 34, 41, 45, 33, 37, nil, nil, nil, nil, 43, 39, 35, 47},
	nil,
	nil,
	nil,
	nil,
	{24, 7, 16, 13, 27, 11, 17, 1, 26, 15, 18, 5, 25, 3, 19, 9, 2, 6, 10, 14, nil, nil, nil, nil, 0, 12, 8, 4, nil, nil, nil, nil, 56, 39, 48, 45, 59, 43, 49, 33, 58, 47, 50, 37, 57, 35, 51, 41, 34, 38, 42, 46, nil, nil, nil, nil, 32, 44, 40, 36},
	{25, 4, 17, 14, 24, 8, 18, 2, 27, 12, 19, 6, 26, 0, 16, 10, 3, 7, 11, 15, nil, nil, nil, nil, 1, 13, 9, 5, nil, nil, nil, nil, 57, 36, 49, 46, 56, 40, 50, 34, 59, 44, 51, 38, 58, 32, 48, 42, 35, 39, 43, 47, nil, nil, nil, nil, 33, 45, 41, 37},
	{26, 5, 18, 15, 25, 9, 19, 3, 24, 13, 16, 7, 27, 1, 17, 11, 0, 4, 8, 12, nil, nil, nil, nil, 2, 14, 10, 6, nil, nil, nil, nil, 58, 37, 50, 47, 57, 41, 51, 35, 56, 45, 48, 39, 59, 33, 49, 43, 32, 36, 40, 44, nil, nil, nil, nil, 34, 46, 42, 38},
	{27, 6, 19, 12, 26, 10, 16, 0, 25, 14, 17, 4, 24, 2, 18, 8, 1, 5, 9, 13, nil, nil, nil, nil, 3, 15, 11, 7, nil, nil, nil, nil, 59, 38, 51, 44, 58, 42, 48, 32, 57, 46, 49, 36, 56, 34, 50, 40, 33, 37, 41, 45, nil, nil, nil, nil, 35, 47, 43, 39},
	nil,
	nil,
	nil,
	nil,
	{32, 35, 34, 33, 44, 47, 46, 45, 40, 43, 42, 41, 36, 39, 38, 37, 48, 51, 50, 49, nil, nil, nil, nil, 56, 59, 58, 57, nil, nil, nil, nil, 0, 3, 2, 1, 12, 15, 14, 13, 8, 11, 10, 9, 4, 7, 6, 5, 16, 19, 18, 17, nil, nil, nil, nil, 24, 27, 26, 25},
	{33, 32, 35, 34, 45, 44, 47, 46, 41, 40, 43, 42, 37, 36, 39, 38, 49, 48, 51, 50, nil, nil, nil, nil, 57, 56, 59, 58, nil, nil, nil, nil, 1, 0, 3, 2, 13, 12, 15, 14, 9, 8, 11, 10, 5, 4, 7, 6, 17, 16, 19, 18, nil, nil, nil, nil, 25, 24, 27, 26},
	{34, 33, 32, 35, 46, 45, 44, 47, 42, 41, 40, 43, 38, 37, 36, 39, 50, 49, 48, 51, nil, nil, nil, nil, 58, 57, 56, 59, nil, nil, nil, nil, 2, 1, 0, 3, 14, 13, 12, 15, 10, 9, 8, 11, 6, 5, 4, 7, 18, 17, 16, 19, nil, nil, nil, nil, 26, 25, 24, 27},
	{35, 34, 33, 32, 47, 46, 45, 44, 43, 42, 41, 40, 39, 38, 37, 36, 51, 50, 49, 48, nil, nil, nil, nil, 59, 58, 57, 56, nil, nil, nil, nil, 3, 2, 1, 0, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 19, 18, 17, 16, nil, nil, nil, nil, 27, 26, 25, 24},
	{36, 57, 46, 49, 32, 58, 42, 48, 44, 59, 38, 51, 40, 56, 34, 50, 39, 35, 47, 43, nil, nil, nil, nil, 45, 33, 37, 41, nil, nil, nil, nil, 4, 25, 14, 17, 0, 26, 10, 16, 12, 27, 6, 19, 8, 24, 2, 18, 7, 3, 15, 11, nil, nil, nil, nil, 13, 1, 5, 9},
	{37, 58, 47, 50, 33, 59, 43, 49, 45, 56, 39, 48, 41, 57, 35, 51, 36, 32, 44, 40, nil, nil, nil, nil, 46, 34, 38, 42, nil, nil, nil, nil, 5, 26, 15, 18, 1, 27, 11, 17, 13, 24, 7, 16, 9, 25, 3, 19, 4, 0, 12, 8, nil, nil, nil, nil, 14, 2, 6, 10},
	{38, 59, 44, 51, 34, 56, 40, 50, 46, 57, 36, 49, 42, 58, 32, 48, 37, 33, 45, 41, nil, nil, nil, nil, 47, 35, 39, 43, nil, nil, nil, nil, 6, 27, 12, 19, 2, 24, 8, 18, 14, 25, 4, 17, 10, 26, 0, 16, 5, 1, 13, 9, nil, nil, nil, nil, 15, 3, 7, 11},
	{39, 56, 45, 48, 35, 57, 41, 51, 47, 58, 37, 50, 43, 59, 33, 49, 38, 34, 46, 42, nil, nil, nil, nil, 44, 32, 36, 40, nil, nil, nil, nil, 7, 24, 13, 16, 3, 25, 9, 19, 15, 26, 5, 18, 11, 27, 1, 17, 6, 2, 14, 10, nil, nil, nil, nil, 12, 0, 4, 8},
	{40, 41, 42, 43, 36, 37, 38, 39, 32, 33, 34, 35, 44, 45, 46, 47, 56, 57, 58, 59, nil, nil, nil, nil, 48, 49, 50, 51, nil, nil, nil, nil, 8, 9, 10, 11, 4, 5, 6, 7, 0, 1, 2, 3, 12, 13, 14, 15, 24, 25, 26, 27, nil, nil, nil, nil, 16, 17, 18, 19},
	{41, 42, 43, 40, 37, 38, 39, 36, 33, 34, 35, 32, 45, 46, 47, 44, 57, 58, 59, 56, nil, nil, nil, nil, 49, 50, 51, 48, nil, nil, nil, nil, 9, 10, 11, 8, 5, 6, 7, 4, 1, 2, 3, 0, 13, 14, 15, 12, 25, 26, 27, 24, nil, nil, nil, nil, 17, 18, 19, 16},
	{42, 43, 40, 41, 38, 39, 36, 37, 34, 35, 32, 33, 46, 47, 44, 45, 58, 59, 56, 57, nil, nil, nil, nil, 50, 51, 48, 49, nil, nil, nil, nil, 10, 11, 8, 9, 6, 7, 4, 5, 2, 3, 0, 1, 14, 15, 12, 13, 26, 27, 24, 25, nil, nil, nil, nil, 18, 19, 16, 17},
	{43, 40, 41, 42, 39, 36, 37, 38, 35, 32, 33, 34, 47, 44, 45, 46, 59, 56, 57, 58, nil, nil, nil, nil, 51, 48, 49, 50, nil, nil, nil, nil, 11, 8, 9, 10, 7, 4, 5, 6, 3, 0, 1, 2, 15, 12, 13, 14, 27, 24, 25, 26, nil, nil, nil, nil, 19, 16, 17, 18},
	{44, 51, 38, 59, 40, 50, 34, 56, 36, 49, 46, 57, 32, 48, 42, 58, 45, 41, 37, 33, nil, nil, nil, nil, 39, 43, 47, 35, nil, nil, nil, nil, 12, 19, 6, 27, 8, 18, 2, 24, 4, 17, 14, 25, 0, 16, 10, 26, 13, 9, 5, 1, nil, nil, nil, nil, 7, 11, 15, 3},
	{45, 48, 39, 56, 41, 51, 35, 57, 37, 50, 47, 58, 33, 49, 43, 59, 46, 42, 38, 34, nil, nil, nil, nil, 36, 40, 44, 32, nil, nil, nil, nil, 13, 16, 7, 24, 9, 19, 3, 25, 5, 18, 15, 26, 1, 17, 11, 27, 14, 10, 6, 2, nil, nil, nil, nil, 4, 8, 12, 0},
	{46, 49, 36, 57, 42, 48, 32, 58, 38, 51, 44, 59, 34, 50, 40, 56, 47, 43, 39, 35, nil, nil, nil, nil, 37, 41, 45, 33, nil, nil, nil, nil, 14, 17, 4, 25, 10, 16, 0, 26, 6, 19, 12, 27, 2, 18, 8, 24, 15, 11, 7, 3, nil, nil, nil, nil, 5, 9, 13, 1},
	{47, 50, 37, 58, 43, 49, 33, 59, 39, 48, 45, 56, 35, 51, 41, 57, 44, 40, 36, 32, nil, nil, nil, nil, 38, 42, 46, 34, nil, nil, nil, nil, 15, 18, 5, 26, 11, 17, 1, 27, 7, 16, 13, 24, 3, 19, 9, 25, 12, 8, 4, 0, nil, nil, nil, nil, 6, 10, 14, 2},
	{48, 39, 56, 45, 51, 35, 57, 41, 50, 47, 58, 37, 49, 43, 59, 33, 42, 38, 34, 46, nil, nil, nil, nil, 40, 44, 32, 36, nil, nil, nil, nil, 16, 7, 24, 13, 19, 3, 25, 9, 18, 15, 26, 5, 17, 11, 27, 1, 10, 6, 2, 14, nil, nil, nil, nil, 8, 12, 0, 4},
	{49, 36, 57, 46, 48, 32, 58, 42, 51, 44, 59, 38, 50, 40, 56, 34, 43, 39, 35, 47, nil, nil, nil, nil, 41, 45, 33, 37, nil, nil, nil, nil, 17, 4, 25, 14, 16, 0, 26, 10, 19, 12, 27, 6, 18, 8, 24, 2, 11, 7, 3, 15, nil, nil, nil, nil, 9, 13, 1, 5},
	{50, 37, 58, 47, 49, 33, 59, 43, 48, 45, 56, 39, 51, 41, 57, 35, 40, 36, 32, 44, nil, nil, nil, nil, 42, 46, 34, 38, nil, nil, nil, nil, 18, 5, 26, 15, 17, 1, 27, 11, 16, 13, 24, 7, 19, 9, 25, 3, 8, 4, 0, 12, nil, nil, nil, nil, 10, 14, 2, 6},
	{51, 38, 59, 44, 50, 34, 56, 40, 49, 46, 57, 36, 48, 42, 58, 32, 41, 37, 33, 45, nil, nil, nil, nil, 43, 47, 35, 39, nil, nil, nil, nil, 19, 6, 27, 12, 18, 2, 24, 8, 17, 14, 25, 4, 16, 10, 26, 0, 9, 5, 1, 13, nil, nil, nil, nil, 11, 15, 3, 7},
	nil,
	nil,
	nil,
	nil,
	{56, 45, 48, 39, 57, 41, 51, 35, 58, 37, 50, 47, 59, 33, 49, 43, 34, 46, 42, 38, nil, nil, nil, nil, 32, 36, 40, 44, nil, nil, nil, nil, 24, 13, 16, 7, 25, 9, 19, 3, 26, 5, 18, 15, 27, 1, 17, 11, 2, 14, 10, 6, nil, nil, nil, nil, 0, 4, 8, 12},
	{57, 46, 49, 36, 58, 42, 48, 32, 59, 38, 51, 44, 56, 34, 50, 40, 35, 47, 43, 39, nil, nil, nil, nil, 33, 37, 41, 45, nil, nil, nil, nil, 25, 14, 17, 4, 26, 10, 16, 0, 27, 6, 19, 12, 24, 2, 18, 8, 3, 15, 11, 7, nil, nil, nil, nil, 1, 5, 9, 13},
	{58, 47, 50, 37, 59, 43, 49, 33, 56, 39, 48, 45, 57, 35, 51, 41, 32, 44, 40, 36, nil, nil, nil, nil, 34, 38, 42, 46, nil, nil, nil, nil, 26, 15, 18, 5, 27, 11, 17, 1, 24, 7, 16, 13, 25, 3, 19, 9, 0, 12, 8, 4, nil, nil, nil, nil, 2, 6, 10, 14},
	{59, 44, 51, 38, 56, 40, 50, 34, 57, 36, 49, 46, 58, 32, 48, 42, 33, 45, 41, 37, nil, nil, nil, nil, 35, 39, 43, 47, nil, nil, nil, nil, 27, 12, 19, 6, 24, 8, 18, 2, 25, 4, 17, 14, 26, 0, 16, 10, 1, 13, 9, 5, nil, nil, nil, nil, 3, 7, 11, 15}
}


local function shiftDownAndRoundUp(x, bits)
	local y = bit.rshift(x, bits)
	local mask = bit.lshift(1, bits) - 1
	if bit.band(x, mask) ~= 0 then y = y + 1 end
	return y
end



local Chunk = class()

-- static member
Chunk.bitsize = vec3i(5, 5, 5)
Chunk.size = Chunk.bitsize:map(function(x) return bit.lshift(1, x) end)
Chunk.bitmask = Chunk.size - 1
Chunk.volume = Chunk.size:volume()	-- same as 1 << bitsize:sum() (if i had a :sum() function...)

local VoxelChunkVolumeArr = ffi.typeof('$['..Chunk.volume..']', Voxel)

function Chunk:init(args)
	local voxelmap = assert(args.voxelmap)
	self.voxelmap = voxelmap

	-- chunk position, in Chunk.size units
	self.chunkPos = vec3i((assert.index(args, 'chunkPos')))

	-- for now don't store data in chunks, just meshes.
	--[[
	self.v = ffi.new(VoxelChunkVolumeArr, self.volume)
	ffi.fill(self.v, ffi.sizeof(VoxelChunkVolumeArr), -1)	-- fills with 0xff, right?
	--]]

	local volume = self.volume
	self.vertexBufCPU = vector(Numo9Vertex)
	self.billboardXYZVoxels = vector(vec3i)	-- type 20
	self.billboardXYVoxels = vector(vec3i)	-- type 21

	-- oh yeah, archive uses this class, maybe I don't want to build the GLArrayBuffer in the ctor after all?
	-- but I think same argument for the blob/image classes, so meh leave it here.
	self.vertexBufGPU = GLArrayBuffer{
		size = ffi.sizeof(Numo9Vertex) * self.vertexBufCPU.capacity,
		count = self.vertexBufCPU.capacity,
		data = self.vertexBufCPU.v,
		usage = gl.GL_DYNAMIC_DRAW,
	}
	:bind()
--DEBUG:print('GL_ARRAY_BUFFER_BINDING', glglobal:get'GL_ARRAY_BUFFER_BINDING')
--DEBUG:print('chunk', self.chunkPos, 'vertexBufGPU init GL_BUFFER_SIZE', self.vertexBufGPU:get'GL_BUFFER_SIZE')
	self.vertexBufGPU:unbind()

	-- says the mesh needs to be rebuilt
	self.dirtyCPU = true
end

local tmpMat = matrix_ffi({4,4}, 'float'):zeros()
function Chunk:rebuildMesh(app)
	if not self.dirtyCPU then return end
	self.dirtyCPU = false

	self.vertexBufCPU:resize(0)
	self.billboardXYZVoxels:resize(0)
	self.billboardXYVoxels:resize(0)

	-- ok here I shoot myself in the foot just a bit
	-- cuz now that I'm baking extra flags,
	-- that means I can no longer update the voxelmap spriteBit, spriteMask, transparentIndex, paletteIndex,
	-- not without rebuilding the whole mesh
	-- but even before it meant recalculating extra every time we draw so *shrug* I don't miss it
	-- maybe those should all be uniforms anyways?
	local spriteBit = 0
	local spriteMask = 0xFF
	local transparentIndex = -1
	local paletteIndex = 0

	-- also in drawTexTri3D:
	local drawFlags = bit.bor(
		-- bits 0/1 == 01b <=> use sprite pathway:
		1,
		-- if transparency is oob then flag the "don't use transparentIndex" bit:
		(transparentIndex < 0 or transparentIndex >= 256) and 4 or 0,
		-- store sprite bit shift in the next 3 bits:
		bit.lshift(spriteBit, 3),

		bit.lshift(spriteMask, 8)
	)

	local extra = vec4us(
		drawFlags,
		0,
		transparentIndex,
		paletteIndex)

	local voxelmapSize = self.voxelmap:getVoxelSize()

	-- which to build this off of?
	-- RAMPtr since thats what AppVideo:drawVoxelMap() uses
	-- but that means it wont be present upon init() ...
	local mp = tmpMat.ptr
	local voxels = assert(self.voxelmap:getVoxelDataRAMPtr(), 'BlobVoxelMap rebuildMesh .ramptr missing')
	local occludedCount = 0

	local ci, cj, ck = self.chunkPos:unpack()
--DEBUG:print('chunk', ci, cj, ck)

	local nbhd = vec3i()
	for k=0,Chunk.size.z-1 do
		local vk = bit.bor(k, bit.lshift(ck, Chunk.bitsize.z))
		if vk < voxelmapSize.z then
			for j=0,Chunk.size.y-1 do
				local vj = bit.bor(j, bit.lshift(cj, Chunk.bitsize.y))
				if vj < voxelmapSize.y then

					-- traverse cols
					local vptr = voxels + (bit.lshift(ci, Chunk.bitsize.x) + voxelmapSize.x * (vj + voxelmapSize.y * vk))
					for i=0,Chunk.size.x-1 do
						local vi = bit.bor(i, bit.lshift(ci, Chunk.bitsize.x))
--DEBUG:print('cpos', ci, cj, ck, 'pos', i, j, k, 'vpos', vi, vj, vk)

						-- chunks can extend beyond the voxelmap when it isnt chunk-aligned in size
						if vi >= voxelmapSize.x then break end

						if vptr.intval ~= voxelMapEmptyValue then
							tmpMat:setTranslate(vi+.5, vj+.5, vk+.5)
							tmpMat:applyScale(1/32768, 1/32768, 1/32768)

							if specialOrientation[vptr.orientation] then
								if vptr.orientation == 20 then
									self.billboardXYZVoxels:emplace_back()[0]:set(vi,vj,vk)
								elseif vptr.orientation == 21 then
									self.billboardXYVoxels:emplace_back()[0]:set(vi,vj,vk)
								end
							else
								--[[
								0 c= 1 s= 0
								1 c= 0 s= 1
								2 c=-1 s= 0
								3 c= 0 s=-1
								--]]

								if vptr.rotZ == 1 then
									--[[
									[ m0 m4 m8  m12] [ 0 -1 0 0 ]
									[ m1 m5 m9  m13] [ 1  0 0 0 ]
									[ m2 m6 m10 m14] [ 0  0 1 0 ]
									[ m3 m7 m11 m15] [ 0  0 0 1 ]
									--]]
									mp[0], mp[1], mp[2], mp[4], mp[5], mp[6]
									= mp[4], mp[5], mp[6], -mp[0], -mp[1], -mp[2]
								elseif vptr.rotZ == 2 then
									--[[
									[ m0 m4 m8  m12] [ -1  0 0 0 ]
									[ m1 m5 m9  m13] [  0 -1 0 0 ]
									[ m2 m6 m10 m14] [  0  0 1 0 ]
									[ m3 m7 m11 m15] [  0  0 0 1 ]
									--]]
									mp[0], mp[1], mp[2], mp[4], mp[5], mp[6]
									= -mp[0], -mp[1], -mp[2], -mp[4], -mp[5], -mp[6]
								elseif vptr.rotZ == 3 then
									--[[
									[ m0 m4 m8  m12] [  0 1 0 0 ]
									[ m1 m5 m9  m13] [ -1 0 0 0 ]
									[ m2 m6 m10 m14] [  0 0 1 0 ]
									[ m3 m7 m11 m15] [  0 0 0 1 ]
									--]]
									mp[0], mp[1], mp[2], mp[4], mp[5], mp[6]
									= -mp[4], -mp[5], -mp[6], mp[0], mp[1], mp[2]
								end

								if vptr.rotY == 1 then
									--[[
									[ m0 m4 m8  m12] [  0 0 1 0 ]
									[ m1 m5 m9  m13] [  0 1 0 0 ]
									[ m2 m6 m10 m14] [ -1 0 0 0 ]
									[ m3 m7 m11 m15] [  0 0 0 1 ]
									--]]
									mp[0], mp[1], mp[2], mp[8], mp[9], mp[10]
									= -mp[8], -mp[9], -mp[10], mp[0], mp[1], mp[2]
								elseif vptr.rotY == 2 then
									mp[0], mp[1], mp[2], mp[8], mp[9], mp[10]
									= -mp[0], -mp[1], -mp[2], -mp[8], -mp[9], -mp[10]
								elseif vptr.rotY == 3 then
									mp[0], mp[1], mp[2], mp[8], mp[9], mp[10]
									= mp[8], mp[9], mp[10], -mp[0], -mp[1], -mp[2]
								end

								if vptr.rotX == 1 then
									--[[
									[ m0 m4 m8  m12] [ 1 0  0 0 ]
									[ m1 m5 m9  m13] [ 0 0 -1 0 ]
									[ m2 m6 m10 m14] [ 0 1  0 0 ]
									[ m3 m7 m11 m15] [ 0 0  0 1 ]
									--]]
									mp[4], mp[5], mp[6], mp[8], mp[9], mp[10]
									= mp[8], mp[9], mp[10], -mp[4], -mp[5], -mp[6]
								elseif vptr.rotX == 6 then
									mp[4], mp[5], mp[6], mp[8], mp[9], mp[10]
									= -mp[4], -mp[5], -mp[6], -mp[8], -mp[9], -mp[10]
								elseif vptr.rotX == 3 then
									mp[4], mp[5], mp[6], mp[8], mp[9], mp[10]
									= -mp[8], -mp[9], -mp[10], mp[4], mp[5], mp[6]
								end

								if vptr.scaleX == 1 then
									--[[
									[ m0 m4 m8  m12] [ -1 0 0 0 ]
									[ m1 m5 m9  m13] [  0 1 0 0 ]
									[ m2 m6 m10 m14] [  0 0 1 0 ]
									[ m3 m7 m11 m15] [  0 0 0 1 ]
									--]]
									mp[0], mp[1], mp[2] = -mp[0], -mp[1], -mp[2]
								end

								local uofs = bit.lshift(vptr.tileXOffset, 3)
								local vofs = bit.lshift(vptr.tileYOffset, 3)

								local mesh = app.blobs.mesh3d[vptr.mesh3DIndex+1]
								if mesh then
									local srcVtxs = mesh:getVertexPtr()	-- TODO blob vs ram location ...

									-- resize first then offest back in case we get a resize ...
									self.vertexBufCPU:reserve(#self.vertexBufCPU + #mesh.triList)

									for ti=0,#mesh.triList-1 do
										local tri = mesh.triList.v[ti]
										local ai, bi, ci = tri.x, tri.y, tri.z

										-- see if this face is aligned to an AABB
										-- see if its neighbors face is occluding on that AABB
										-- if both are true then skip
										local occluded

										-- TODO
										-- transparency
										-- hmm
										-- I'd say "check every used texel for trnsparency and don't occulde if any are transparent"
										-- but nothing's to stop from shifting palettes later
										-- hmmmmmmm


										local sideIndex = mesh.sideForTriIndex[ti]
										if sideIndex then
											-- TODO TODO sides need to be influenced by orientation too ...
											sideIndex = rotateSideByOrientation[sideIndex+1][vptr.orientation+1]

											-- offet into 'sideIndex'
											local sign = 1 - 2 * bit.band(1, sideIndex)
											local axis = bit.rshift(sideIndex, 1)

											nbhd.x, nbhd.y, nbhd.z = vi,vj,vk
											nbhd.s[axis] = nbhd.s[axis] + sign
											if nbhd.x >= 0 and nbhd.x < voxelmapSize.x
											and nbhd.y >= 0 and nbhd.y < voxelmapSize.y
											and nbhd.z >= 0 and nbhd.z < voxelmapSize.z
											then
												-- if it occludes the opposite side then skip this tri
												local nbhdVox = voxels[nbhd.x + voxelmapSize.x * (nbhd.y + voxelmapSize.y * nbhd.z)]
												local nbhdmesh = app.blobs.mesh3d[nbhdVox.mesh3DIndex+1]
												if nbhdmesh
												and not specialOrientation[nbhdVox.orientation]
												then
													local oppositeSideIndex = bit.bxor(1, sideIndex)
													oppositeSideIndex = rotateSideByOrientation[oppositeSideIndex+1][orientationInv[nbhdVox.orientation+1]+1]
													occluded = nbhdmesh.sidesOccluded[oppositeSideIndex]
												end
											end
										end

										if occluded then
											occludedCount = occludedCount + 1
										else
											local va = srcVtxs + ai
											local vb = srcVtxs + bi
											local vc = srcVtxs + ci

											-- preserve orientation even if we are scaling
											if vptr.scaleX == 1 then
												va, vc = vc, va
											end

											local normal = mesh.normalList.v[ti]

											local srcv = va
											local dstVtx = self.vertexBufCPU:emplace_back()
											dstVtx.vertex.x, dstVtx.vertex.y, dstVtx.vertex.z = vec3to3(mp, srcv.x, srcv.y, srcv.z)
											dstVtx.texcoord.x = (tonumber(srcv.u + uofs) + .5) / tonumber(spriteSheetSize.x)
											dstVtx.texcoord.y = (tonumber(srcv.v + vofs) + .5) / tonumber(spriteSheetSize.y)
											dstVtx.normal = normal
											dstVtx.extra = extra
											dstVtx.box.x, dstVtx.box.y, dstVtx.box.z, dstVtx.box.w = 0, 0, 1, 1

											local srcv = vb
											local dstVtx = self.vertexBufCPU:emplace_back()
											dstVtx.vertex.x, dstVtx.vertex.y, dstVtx.vertex.z = vec3to3(mp, srcv.x, srcv.y, srcv.z)
											dstVtx.texcoord.x = (tonumber(srcv.u + uofs) + .5) / tonumber(spriteSheetSize.x)
											dstVtx.texcoord.y = (tonumber(srcv.v + vofs) + .5) / tonumber(spriteSheetSize.y)
											dstVtx.normal = normal
											dstVtx.extra = extra
											dstVtx.box.x, dstVtx.box.y, dstVtx.box.z, dstVtx.box.w = 0, 0, 1, 1

											local srcv = vc
											local dstVtx = self.vertexBufCPU:emplace_back()
											dstVtx.vertex.x, dstVtx.vertex.y, dstVtx.vertex.z = vec3to3(mp, srcv.x, srcv.y, srcv.z)
											dstVtx.texcoord.x = (tonumber(srcv.u + uofs) + .5) / tonumber(spriteSheetSize.x)
											dstVtx.texcoord.y = (tonumber(srcv.v + vofs) + .5) / tonumber(spriteSheetSize.y)
											dstVtx.normal = normal
											dstVtx.extra = extra
											dstVtx.box.x, dstVtx.box.y, dstVtx.box.z, dstVtx.box.w = 0, 0, 1, 1
										end
									end
								end
							end
						end
						vptr = vptr + 1
					end
				end
			end
		end
	end
--DEBUG:print('created', #self.vertexBufCPU/3, 'tris')
--DEBUG:print('occluded', occludedCount, 'tris')
end

-- needs triBuf_prepAddTri to be called beforehand
function Chunk:drawMesh(app)
	if #self.vertexBufCPU == 0 then return end

	local oldVAOID = glglobal:get'GL_VERTEX_ARRAY_BINDING'
	local oldBufferID = glglobal:get'GL_ARRAY_BUFFER_BINDING'
	local oldProgramID = glglobal:get'GL_CURRENT_PROGRAM'
print('GL_VERTEX_ARRAY_BINDING', oldVAOID)
print('GL_ARRAY_BUFFER_BINDING', oldBufferID)
print('GL_CURRENT_PROGRAM', oldProgramID)

--[[ hmm why aren't things working ....
	app.lastAnimSheetTex:bind(3)
	app.lastTilemapTex:bind(2)
	app.lastSheetTex:bind(1)
	app.lastPaletteTex:bind(0)

	app:triBuf_prepAddTri(
		app.lastPaletteTex,
		app.lastSheetTex,
		app.lastTilemapTex,
		app.lastAnimSheetTex)
--]]
	local sceneObj = app.triBuf_sceneObj
	local program = sceneObj.program

print('Chunk:drawMesh self.chunkPos', self.chunkPos)

	if not self.vao
	or program ~= self.vaoProgram
	then
		if self.vao then
			self.vao:delete()
			self.vao = nil
		end
		-- cache vao per-program, which is per-video-mode
		-- because its attrs vary per program , per-video-mode
		self.vaoProgram = program
		self.vao = GLVertexArray{
			program = program,
			attrs = table.map(sceneObj.attrs, function(attr)
				--[[
				local newattr = GLAttribute(attr)
				newattr.buffer = self.vertexBufGPU
				return newattr
				--]]
				-- [[
				local newattr = setmetatable({}, GLAttribute)
				for k,v in pairs(attr) do newattr[k] = v end
				newattr.buffer = self.vertexBufGPU
				return newattr
				--]]
			end),
		} -- init doesnt bind vao...
		self.vao:bind()
assert(glreport'here')
		self.vertexBufGPU:bind()
assert(glreport'here')
	end
assert(glreport'here')
	self.vao:bind()
assert(glreport'here')

print('self.vertexBufCPU.capacity', self.vertexBufCPU.capacity)
print('self.vertexBufCPULastCapacity', self.vertexBufCPULastCapacity)
	if self.vertexBufCPU.capacity ~= self.vertexBufCPULastCapacity then
		self.vertexBufGPU:bind()
assert(glreport'here')
print('GL_ARRAY_BUFFER_BINDING', glglobal:get'GL_ARRAY_BUFFER_BINDING')
print('vertexBufGPU before setData GL_BUFFER_SIZE', self.vertexBufGPU:get'GL_BUFFER_SIZE')
assert(glreport'here')
		self.vertexBufGPU:setData{
			data = self.vertexBufCPU.v,
			count = self.vertexBufCPU.capacity,
			size = ffi.sizeof(Numo9Vertex) * self.vertexBufCPU.capacity,
		}
print('GL_ARRAY_BUFFER_BINDING', glglobal:get'GL_ARRAY_BUFFER_BINDING')
print('vertexBufGPU after setData GL_BUFFER_SIZE', self.vertexBufGPU:get'GL_BUFFER_SIZE')
print('ffi.sizeof(Numo9Vertex)', ffi.sizeof(Numo9Vertex))
print('vertexBufGPU:setData count', self.vertexBufCPU.capacity)
print('vertexBufGPU:setData size', ffi.sizeof(Numo9Vertex) * self.vertexBufCPU.capacity)
print('vertexBufGPU:setData data', self.vertexBufCPU.v)
assert(glreport'here')
	-- [[ TODO only do this when we init or poke RAM
	-- TODO TODO this is causing GL errors
	else
--DEBUG:assert.eq(self.vertexBufGPU.data, self.vertexBufCPU.v)
print('vertexBufGPU:updateData old size', self.vertexBufGPU.size)
print('vertexBufGPU:updateData old data', self.vertexBufGPU.data)
print('vertexBufGPU:updateData data should be', self.vertexBufCPU.v)
print('vertexBufGPU:updateData vertexBufCPU:getNumBytes()', self.vertexBufCPU:getNumBytes())
		self.vertexBufGPU:bind()
print('GL_ARRAY_BUFFER_BINDING', glglobal:get'GL_ARRAY_BUFFER_BINDING')
print('vertexBufGPU before updateData GL_BUFFER_SIZE', self.vertexBufGPU:get'GL_BUFFER_SIZE')
assert(glreport'here')
		self.vertexBufGPU
			:updateData(0,
				--self.vertexBufCPU:getNumBytes())
				ffi.sizeof(Numo9Vertex) * self.vertexBufCPU.capacity)
assert(glreport'here')
	--]]
print('GL_ARRAY_BUFFER_BINDING', glglobal:get'GL_ARRAY_BUFFER_BINDING')
print('vertexBufGPU after updateData GL_BUFFER_SIZE', self.vertexBufGPU:get'GL_BUFFER_SIZE')
	end

	gl.glDrawArrays(gl.GL_TRIANGLES, 0, #self.vertexBufCPU)
assert(glreport'here')

	-- TODO also draw lightmap stuff here

	self.vao:unbind()
	self.vertexBufGPU:unbind()

	gl.glBindBuffer(gl.GL_ARRAY_BUFFER, oldBufferID)
	gl.glUseProgram(oldProgramID)
	gl.glBindVertexArray(oldVAOID)

	-- reset the vectors and store the last capacity
	self.vertexBufCPULastCapacity = self.vertexBufCPU.capacity
end

function Chunk:delete()
	if self.vertexBufGPU then
		self.vertexBufGPU:delete()
		self.vertexBufGPU = nil
	end
	if self.vao then
		self.vao:delete()
		self.vao = nil
	end
end

Chunk.__gc = Chunk.delete




--[[
format:
uint32_t width, height, depth;
typedef struct {
	uint32_t modelIndex : 17;
	uint32_t tileXOffset: 5;
	uint32_t tileYOffset: 5;
	uint32_t orientation : 5;	// 2: z-axis yaw, 2: x-axis roll, 1:y-axis pitch
} VoxelBlock;
VoxelBlock data[width*height*depth];
--]]
local BlobVoxelMap = Blob:subclass()

BlobVoxelMap.filenamePrefix = 'voxelmap'
BlobVoxelMap.filenameSuffix = '.vox'

-- save these for outside
BlobVoxelMap.orientationRotations = orientationRotations
BlobVoxelMap.specialOrientation = specialOrientation
BlobVoxelMap.orientationInv = orientationInv
BlobVoxelMap.rotateSideByOrientation = rotateSideByOrientation
BlobVoxelMap.orientationMul = orientationMul

assert.eq(ffi.sizeof(voxelmapSizeType), ffi.sizeof(Voxel))
function BlobVoxelMap:init(data)
	self.vec = vector(Voxel)	-- use .intptr for the first x y z entries
	local minsize = ffi.sizeof(Voxel) * 3
	if not data or #data < minsize then
		self.vec:emplace_back()[0].intval = 1
		self.vec:emplace_back()[0].intval = 1
		self.vec:emplace_back()[0].intval = 1
		self.vec:emplace_back()[0].intval = voxelMapEmptyValue
	else
		self.vec:resize(math.ceil(#data / ffi.sizeof(Voxel)))
		ffi.copy(self.vec.v, data, #data)
	end

	-- validate that the header at least works
	assert.gt(self:getWidth(), 0)
	assert.gt(self:getHeight(), 0)
	assert.gt(self:getDepth(), 0)

	-- after any chunk goes dirty rebuild it, then rebuild the master list so I just have to do one copy into the draw buffer
	-- or TODO if I do use GPU resources then meh dont bother use a master list, right? cuz gpu multiple draws should be fast enough and an extra CPU copy would be slower right?
	self.vertexBufCPU = vector(Numo9Vertex)
	self.billboardXYZVoxels = vector(vec3i)	-- type 20
	self.billboardXYVoxels = vector(vec3i)	-- type 21


	-- can't build the mesh yet, not until .ramptr is defined
	--self:rebuildMesh()

	-- TODO instead of storing ... three times in memory:
	-- 	- once as the blob from the cart file
	--	- once in RAM
	--	- once in the chunks
	-- how about just storing it in RAM and chunks only?
	-- For one, because the archiver wants the data continuous in :getPtr() ...
	-- how to work around this ...
	local voxptr = self:getVoxelDataBlobPtr()

	-- says that some chunk's mesh needs to be rebuilt
	self.dirtyCPU = true

	-- 0-based, index from interleaving chunkPos with self:voxelSizeInChunks()
	self.chunks = {}
	local voxelmapSize = self:getVoxelSize()

	-- need to update this if the size ever changes...
	self.sizeInChunks = self:getVoxelSizeInChunks()
	self.chunkVolume = self.sizeInChunks:volume()

	-- create the chunks
	do
		local chunkIndex = 0
		for ck=0,self.sizeInChunks.z-1 do
			for cj=0,self.sizeInChunks.y-1 do
				for ci=0,self.sizeInChunks.x-1 do
					local chunk = Chunk{
						voxelmap = self,
						chunkPos = vec3i(ci,cj,ck),
					}
					self.chunks[chunkIndex] = chunk

					-- for now don't store data in chunks, just meshes.
					--[[ can't always do this ...
					ffi.copy(chunk.v, voxptr + chunkIndex * Chunk.volume, ffi.sizeof(VoxelChunkVolumeArr))
					--]]
					--[[
					for k=0,Chunk.size.z-1 do
						for j=0,Chunk.size.y-1 do
							for i=0,Chunk.size.x-1 do
								-- voxelmap index:
								local vi = bit.bor(i, bit.lshift(ci, Chunk.bitsize.x))
								local vj = bit.bor(j, bit.lshift(cj, Chunk.bitsize.y))
								local vk = bit.bor(k, bit.lshift(ck, Chunk.bitsize.z))
								-- copy block by block
								-- TODO maybe ffi.copy by row eventually
								chunk.v[i + Chunk.size.x * (j + Chunk.size.y * k)]
									= voxptr[vi + voxelmapSize.x * (vj + voxelmapSize.y * vk)]
							end
						end
					end
					--]]

					chunkIndex = chunkIndex + 1
				end
			end
		end
	end
end

function BlobVoxelMap:getPtr()
	return ffi.cast(uint8_t_p, self.vec.v)
end

function BlobVoxelMap:getSize()
	return self.vec:getNumBytes()
end

-- get size by the blob, not the RAM...
function BlobVoxelMap:getWidth()
	return self.vec.v[0].intval
end

function BlobVoxelMap:getHeight()
	return self.vec.v[1].intval
end

function BlobVoxelMap:getDepth()
	return self.vec.v[2].intval
end

function BlobVoxelMap:getVoxelSize()
	return vec3i(self:getWidth(), self:getHeight(), self:getDepth())
end

function BlobVoxelMap:getVoxelSizeInChunks()
	local size = self:getVoxelSize()
	return vec3i(
		shiftDownAndRoundUp(size.x, Chunk.bitsize.x),
		shiftDownAndRoundUp(size.y, Chunk.bitsize.y),
		shiftDownAndRoundUp(size.z, Chunk.bitsize.z))
end

function BlobVoxelMap:getVoxelDataBlobPtr()
	return self.vec.v + 3
end

function BlobVoxelMap:getVoxelDataRAMPtr()
	return ffi.cast(Voxel_p, self.ramptr + ffi.sizeof(voxelmapSizeType) * 3)
end

function BlobVoxelMap:getVoxelDataAddr()
	return self.addr + ffi.sizeof(voxelmapSizeType) * 3
end

function BlobVoxelMap:getVoxelBlobPtr(x,y,z)
	x = math.floor(x)
	y = math.floor(y)
	z = math.floor(z)
	if x < 0 or x >= self:getWidth()
	or y < 0 or y >= self:getHeight()
	or z < 0 or z >= self:getDepth()
	then return end
	return self:getVoxelDataBlobPtr() + x + self:getWidth() * (y + self:getHeight() * z)
end

function BlobVoxelMap:getVoxelAddr(x,y,z)
	x = math.floor(x)
	y = math.floor(y)
	z = math.floor(z)
	if x < 0 or x >= self:getWidth()
	or y < 0 or y >= self:getHeight()
	or z < 0 or z >= self:getDepth()
	then return end
	return self:getVoxelDataAddr() + ffi.sizeof(Voxel) * (x + self:getWidth() * (y + self:getHeight() * z))
end

--[[
app = used to search list of mesh3d blobs
--]]
function BlobVoxelMap:rebuildMesh(app)
	if not self.dirtyCPU then return end
	self.dirtyCPU = false

	self.vertexBufCPU:resize(0)
	self.billboardXYZVoxels:resize(0)
	self.billboardXYVoxels:resize(0)

	for chunkIndex=0,self.chunkVolume-1 do
		self.chunks[chunkIndex]:rebuildMesh(app)
	end

	-- [[ now that all chunks have been rebuilt, rebuild our master list
	-- optional TODO if I switch to GPU then dont do this master list, just use individual GPU buffers
	for i=0,self.chunkVolume-1 do
		do
			local chunk = self.chunks[i]
			local srcVtxs = chunk.vertexBufCPU
			local srcLen = #srcVtxs

			local dstVtxs = self.vertexBufCPU
			local dstLen = #dstVtxs
			local writeOfs = dstLen

--DEBUG:assert.eq(srcVtxs.type, dstVtxs.type)
			dstVtxs:resize(dstLen + srcLen)
			local dstVtxPtr = dstVtxs.v + writeOfs
			ffi.copy(dstVtxPtr, srcVtxs.v, ffi.sizeof(srcVtxs.type) * srcLen)
		end

		do
			local chunk = self.chunks[i]
			local srcVtxs = chunk.billboardXYZVoxels
			local srcLen = #srcVtxs

			local dstVtxs = self.billboardXYZVoxels
			local dstLen = #dstVtxs
			local writeOfs = dstLen

--DEBUG:assert.eq(srcVtxs.type, dstVtxs.type)
			dstVtxs:resize(dstLen + srcLen)
			local dstVtxPtr = dstVtxs.v + writeOfs
			ffi.copy(dstVtxPtr, srcVtxs.v, ffi.sizeof(srcVtxs.type) * srcLen)
		end

		do
			local chunk = self.chunks[i]
			local srcVtxs = chunk.billboardXYVoxels
			local srcLen = #srcVtxs

			local dstVtxs = self.billboardXYVoxels
			local dstLen = #dstVtxs
			local writeOfs = dstLen

--DEBUG:assert.eq(srcVtxs.type, dstVtxs.type)
			dstVtxs:resize(dstLen + srcLen)
			local dstVtxPtr = dstVtxs.v + writeOfs
			ffi.copy(dstVtxPtr, srcVtxs.v, ffi.sizeof(srcVtxs.type) * srcLen)
		end
	end
	--]]
end

local warnedAboutTouchingSize

-- touchAddrStart, touchAddrEnd are inclusive
function BlobVoxelMap:onTouchRAM(touchAddrStart, touchAddrEnd, app)
	--if (0, 2) touches-inclusive (addr, addrend) then
	local voxelStartAddr = self.addr + ffi.sizeof(voxelmapSizeType) * 3
	local sizeAddrEnd = voxelStartAddr - 1	-- -1 for inclusive range
	if touchAddrEnd >= self.addr and touchAddrStart <= sizeAddrEnd then
		-- size was touched ... rebuild everything
if not warnedAboutTouchingSize then
	warnedAboutTouchingSize = true
	print("I don't support live changing voxelmap chunk sizes.  Changing this to a value exceeding the limit of RAM could have devastating consequences.")
	print(debug.traceback())
	print()
end
		return
	end

	local width, height, depth = self:getWidth(), self:getHeight(), self:getDepth()

	-- TODO since data is stored [z][y][x] across the whole voxelmap, i could look for rows that touch
	-- this is me being lazy though
	for touchAddr=tonumber(touchAddrStart),tonumber(touchAddrEnd) do
		-- get the chunk index
		-- flag it as dirty
		-- TODO floor vs cast as int? which is faster?
		local voxelIndex = ffi.cast(int32_t, (touchAddr - voxelStartAddr) / ffi.sizeof(Voxel))
		local tmp = voxelIndex
		local vi = tmp % width
		tmp = ffi.cast(int32_t, tmp / width)
		local vj = tmp % height
		tmp = ffi.cast(int32_t, tmp / height)
		local vk = tmp

		local ci = bit.rshift(vi, Chunk.bitsize.x)
		local cj = bit.rshift(vj, Chunk.bitsize.y)
		local ck = bit.rshift(vk, Chunk.bitsize.z)

		local chunkIndex = tonumber(ci + self.sizeInChunks.x * (cj + self.sizeInChunks.y * ck))
		local chunk = self.chunks[chunkIndex]

		chunk.dirtyCPU = true
		self.dirtyCPU = true
	end
end

function BlobVoxelMap:drawMesh(app)
	local sceneObj = app.triBuf_sceneObj
	sceneObj.program:use()	-- wait, is it already bound?

	for i=0,self.chunkVolume-1 do
		self.chunks[i]:drawMesh(app)
	end

	-- rebind the old VAO
	sceneObj.vao:bind()
assert(glreport'here')
end

-- TODO TODO TODO how come this is only working when I pass in an intval, but not a Voxel ?
-- static function
-- vox = Voxel, axis = 012 xyz
-- This is a left-apply.
function BlobVoxelMap:voxelRotateAngleAxis(vox, axis, amount)
	-- can I do this to cast numbers to Voxel's? no.
	-- vox = ffi.cast(Voxel, vox)
	local v2 = ffi.new'Voxel'
	v2.intval = vox
	vox = v2

	if vox.intval == voxelMapEmptyValue then return vox end
	if specialOrientation[vox.orientation] then return vox end
	amount = bit.band(amount or 1, 3)	-- 0,1,2,3
	if amount == 0 then return vox end
	vox.orientation = orientationRotations[vox.orientation+1][axis+1][amount]
	return vox
end

-- This is a left-apply.
function BlobVoxelMap:voxelRotateOrientationL(vox, orientation)
	if specialOrientation[orientation] then
		-- error or just return ident?
		error(tostring(orientation)..' is a specialOrientation')
	end
	local v2 = ffi.new'Voxel'
	v2.intval = vox
	vox = v2

	if vox.intval == voxelMapEmptyValue then return vox end
	if specialOrientation[vox.orientation] then return vox end
	vox.orientation = orientationMul[orientation+1][vox.orientation+1]
	return vox
end

-- This is a right-apply.
function BlobVoxelMap:voxelRotateOrientationR(vox, orientation)
	local v2 = ffi.new'Voxel'
	v2.intval = vox
	vox = v2

	if vox.intval == voxelMapEmptyValue then return vox end
	if specialOrientation[vox.orientation] then return vox end
	vox.orientation = orientationMul[vox.orientation+1][orientation+1]
	return vox
end

function BlobVoxelMap:rotateVoxelsX()
	local size = self:getVoxelSize()
	-- TODO instead of error upon size difference, just resize the whole thing.
	assert.eq(size.y, size.z, "you can't rotate on x axis unless size y and z match")
	for i=0,size.x-1 do
		for j1=0,math.ceil(size.y/2)-1 do
			for k1=0,math.ceil(size.z/2)-1 do
				local j2, k2 = size.y-1-k1, j1
				local j3, k3 = size.y-1-k2, j2
				local j4, k4 = size.y-1-k3, j3
				local v1 = self:getVoxelBlobPtr(i, j1, k1).intval
				local v2 = self:getVoxelBlobPtr(i, j2, k2).intval
				local v3 = self:getVoxelBlobPtr(i, j3, k3).intval
				local v4 = self:getVoxelBlobPtr(i, j4, k4).intval
				self:getVoxelBlobPtr(i, j1, k1)[0] = self:voxelRotateAngleAxis(v4, 0)
				self:getVoxelBlobPtr(i, j2, k2)[0] = self:voxelRotateAngleAxis(v1, 0)
				self:getVoxelBlobPtr(i, j3, k3)[0] = self:voxelRotateAngleAxis(v2, 0)
				self:getVoxelBlobPtr(i, j4, k4)[0] = self:voxelRotateAngleAxis(v3, 0)
			end
		end
	end
end

function BlobVoxelMap:rotateVoxelsY()
	-- TODO instead of error upon size difference, just resize the whole thing.
	local size = self:getVoxelSize()
	assert.eq(size.x, size.z, "you can't rotate on y axis unless size x and z match")
	for j=0,size.y-1 do
		for k1=0,math.ceil(size.z/2)-1 do
			for i1=0,math.ceil(size.x/2)-1 do
				-- TODO repeat the index permutation by `amount`
				local k2, i2 = size.z-1-i1, k1
				local k3, i3 = size.z-1-i2, k2
				local k4, i4 = size.z-1-i3, k3
				local v1 = self:getVoxelBlobPtr(i1, j, k1).intval
				local v2 = self:getVoxelBlobPtr(i2, j, k2).intval
				local v3 = self:getVoxelBlobPtr(i3, j, k3).intval
				local v4 = self:getVoxelBlobPtr(i4, j, k4).intval
				self:getVoxelBlobPtr(i1, j, k1)[0] = self:voxelRotateAngleAxis(v4, 1)
				self:getVoxelBlobPtr(i2, j, k2)[0] = self:voxelRotateAngleAxis(v1, 1)
				self:getVoxelBlobPtr(i3, j, k3)[0] = self:voxelRotateAngleAxis(v2, 1)
				self:getVoxelBlobPtr(i4, j, k4)[0] = self:voxelRotateAngleAxis(v3, 1)
			end
		end
	end
end

function BlobVoxelMap:rotateVoxelsZ()
	local size = self:getVoxelSize()
	-- TODO instead of error upon size difference, just resize the whole thing.
	assert.eq(size.x, size.y, "you can't rotate on z axis unless size x and y match")
	for k=0,size.x-1 do
		for i1=0,math.ceil(size.x/2)-1 do
			for j1=0,math.ceil(size.y/2)-1 do
				-- TODO x,y = -y,x and then modulo to size .. or more appropritaely would be to do the same to size, then to modulo to size.
				local i2, j2 = size.x-1-j1, i1
				local i3, j3 = size.x-1-j2, i2
				local i4, j4 = size.x-1-j3, i3
				local v1 = self:getVoxelBlobPtr(i1, j1, k).intval
				local v2 = self:getVoxelBlobPtr(i2, j2, k).intval
				local v3 = self:getVoxelBlobPtr(i3, j3, k).intval
				local v4 = self:getVoxelBlobPtr(i4, j4, k).intval
				self:getVoxelBlobPtr(i1, j1, k)[0] = self:voxelRotateAngleAxis(v4, 2)
				self:getVoxelBlobPtr(i2, j2, k)[0] = self:voxelRotateAngleAxis(v1, 2)
				self:getVoxelBlobPtr(i3, j3, k)[0] = self:voxelRotateAngleAxis(v2, 2)
				self:getVoxelBlobPtr(i4, j4, k)[0] = self:voxelRotateAngleAxis(v3, 2)
			end
		end
	end
end

return BlobVoxelMap
