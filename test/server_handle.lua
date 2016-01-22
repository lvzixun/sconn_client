local server_new = require "server"
local socket = require "socket.c"
local sleep = socket.sleep

local server, err = server_new(7510)
assert(server, tostring(err))
print("listen...")

local function accept(self)
    local csock = self.v_csock
    print("accept from:", csock:getsockname())
    self:send_msg("welcome to matrix")
end


local function eval(s)
    local cls, err = load(s, nil, "t", _ENV)
    if err then
        return err
    else
        local ret = {pcall(cls)}
        local ok = ret[1]
        if ok then
            return table.concat(ret, "  ", 2)
        else
            return ret[2]
        end
    end
end


local function recv(self, s)
    local recv_buf = self.v_recv_buf
    print("recv:", s, #s)
    self:send_msg(eval(s))
    return true
end

local function _error(self, err)
    print("error:", err)
end

server:register_handle("accept", accept)
server:register_handle("recv", recv)
server:register_handle("error", _error)

while true do
    server:update()
    -- sleep(1)
end

