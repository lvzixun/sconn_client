local buffer_queue = require "buffer_queue"

local q1 = buffer_queue.create()

q1:dump()
print("<<<<<<<<<<<<<<<<<<<<<<<<")
q1:push("12")
q1:push("34")
q1:push("56789")
q1:push("567890")

local s = "abcdefg"
local data = string.pack("<s2", s)

print("### pop:", q1:pop(15))
-- q1:push("aaaa")
q1:push(data)
local ss = q1:pop_block()
print("$$$$ ss:", ss, #ss)

q1:dump()