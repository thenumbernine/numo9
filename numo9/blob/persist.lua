local BlobDataAbs = require 'numo9.blob.dataabs'

-- 256 bytes for pico8, 1024 bytes for tic80 ... snes is arbitrary, 2k for SMW, 8k for Metroid / Final Fantasy, 32k for Yoshi's Island
-- how to identify unique cartridges?  pico8 uses 'cartdata' function with a 64-byte identifier, tic80 uses either `saveid:` in header or md5
-- tic80 metadata includes title, author, some dates..., description, some urls ...
local BlobPersist = BlobDataAbs:subclass()

BlobPersist.filenamePrefix = 'persist'
BlobPersist.filenameSuffix = '.bin'

return BlobPersist
