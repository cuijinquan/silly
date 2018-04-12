local core = require "sys.core"
local ns = require "sys.netstream"

local socket_pool = {}

local socket = {}

local EVENT = {}

local TAG = "socket"

local function new_socket(fd)
	local s = {
		fd = fd,
		delim = false,
		co = false,
		limit = 65535,
	}
	assert(not socket_pool[fd], "new_socket fd already connected")
	socket_pool[fd] = s
end

function EVENT.accept(fd, _, portid, addr)
	local lc = socket_pool[portid];
	new_socket(fd)
	local ok, err = core.pcall(lc.disp, fd, addr)
	if not ok then
		core.log(err)
		socket.close(fd)
	end
end

function EVENT.close(fd, _, errno)
	local s = socket_pool[fd]
	if s == nil then
		return
	end
	assert(s.callback == nil)
	ns.clear(s.sbuffer)
	if s.co then
		local co = s.co
		s.co = false
		core.wakeup(co)
	end
	socket_pool[fd] = nil
end

function EVENT.data(fd, message)
	local s = socket_pool[fd]
	if not s then
		return
	end
	assert(s.callback == nil)
	local sbuffer = s.sbuffer
	sbuffer = ns.push(sbuffer, message)
	s.sbuffer = sbuffer
	if not s.delim then	--non suspend read
		assert(not s.co)
		return
	end
	local delim = s.delim
	if type(delim) == "number" then
		assert(s.co)
		local dat = ns.read(sbuffer, delim)
		if dat then
			local co = s.co
			s.co = false
			s.delim = false
			core.wakeup(co, dat)
		end
	elseif type(delim) == "string" then
		assert(s.co)
		local dat = ns.readline(sbuffer, delim)
		if dat then
			local co = s.co
			s.co = false
			s.delim = false
			core.wakeup(co, dat)
		end
	end
end

local function socket_dispatch(type, fd, message, ...)
	assert(EVENT[type])(fd, message, ...)
end

function socket.listen(port, disp)
	assert(port)
	assert(disp)
	local portid = core.listen(port, socket_dispatch, TAG)
	if portid then
		socket_pool[portid] = {
			fd = portid,
			disp = disp,
			co = false
		}
	end
	return portid
end

function socket.connect(ip, bind)
	local fd = core.connect(ip, socket_dispatch, bind, TAG)
	if fd then
		assert(fd >= 0)
		new_socket(fd)
	end
	return fd
end

function socket.limit(fd, limit)
	local s = socket_pool[fd]
	if s == nil then
		return false
	end
	s.limit = limit
end

function socket.close(fd)
	local s = socket_pool[fd]
	if s == nil then
		return
	end
	if s.so then
		core.wakeup(s.so)
	end
	ns.clear(s.sbuffer)
	socket_pool[fd] = nil
	core.close(fd, TAG)
end

local function suspend(s)
	assert(not s.co)
	s.co = core.running()
	return core.wait()
end


function socket.read(fd, n)
	local s = socket_pool[fd]
	if not s then
		return nil
	end
	local r = ns.read(s.sbuffer, n)
	if r then
		return r
	end
	s.delim = n
	return suspend(s)
end

function socket.readall(fd)
	local s = socket_pool[fd]
	if not s then
		return nil
	end
	return ns.readall(s.sbuffer, n)
end

function socket.readline(fd, delim)
	delim = delim or "\n"
	local s = socket_pool[fd]
	if not s then
		return nil
	end
	local r = ns.readline(s.sbuffer, delim)
	if r then
		return r
	end

	s.delim = delim
	return suspend(s)
end

function socket.write(fd, str)
	local s = socket_pool[fd]
	if not s then
		return false, "already closed"
	end
	return core.write(fd, str)
end

---------udp
local function new_udp(fd, callback)
	local s = {
		fd = fd,
		callback = callback,
	}
	assert(not socket_pool[fd], "new_udp fd already connected")
	socket_pool[fd] = s
end

--udp client can be closed(because it use connect)
local function udp_dispatch(type, fd, message, _, addr)
	local data
	assert(type == "udp" or type == "close")
	local cb = assert(socket_pool[fd]).callback
	if type == "udp" then
		data = ns.todata(message)
	elseif type == "close" then
		socket_pool[fd] = nil
	end
	assert(socket_pool[fd]).callback(data, addr)
end

function socket.bind(addr, callback)
	local fd = core.bind(addr, udp_dispatch, TAG)
	if fd  then
		new_udp(fd, callback)
	end
	return fd
end

function socket.udp(addr, callback, bindip)
	local fd = core.udp(addr, udp_dispatch, bindip, TAG)
	if fd  then
		new_udp(fd, callback)
	end
	return fd
end

function socket.udpwrite(fd, str, addr)
	if not socket_pool[fd] then
		return false
	end
	return core.udpwrite(fd, str, addr)
end

return socket

