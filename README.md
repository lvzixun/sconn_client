# sconn_client
用lua版本[socket](https://github.com/lvzixun/sconn_client/blob/master/lib/lsocket.c)实现的客户端非阻塞模式收发协议模块。

### 正常连接
[`conn.lua`](https://github.com/lvzixun/sconn_client/blob/master/conn.lua)以非阻塞模式正常连接服务器进行收发协议。
API如下：
~~~.lua
local conn = require "conn"

local sock = conn.connect_host(host, port) -- 网络连接

local success, err = sock:update() -- 更新状态
sock:close() -- 关闭连接

sock:send(data) -- 发送数据

local out = {}
local count = sock:recv(out) -- 接受数据

sock:send_msg(data [, header_len[, endian]]) -- 添加包头发送数据

local out_msg = {}
local count = sock:recv_msg(out_msg [, header_len[, endian]]) -- 根据包头读取数据
~~~

### 断线重连
[`sconn.lua`](https://github.com/lvzixun/sconn_client/blob/master/sconn.lua)
根据[gosconn](https://github.com/ejoy/goscon)协议实现的断线重连模块。
api与`conn.lua`一致，只是多了`sock:reconnect()`接口。


### network
[`network.lua`](https://github.com/lvzixun/sconn_client/blob/master/network.lua)为sproto协议实现的一个客户端网络模块。