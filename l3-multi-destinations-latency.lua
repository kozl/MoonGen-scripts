--- This script can be used to measure timestamping precision and accuracy.
--  Connect cables of different length between two ports (or a fiber loopback cable on a single port) to use this.
local mg		= require "dpdk"
local ts		= require "timestamping"
local device	= require "device"
local hist		= require "histogram"
local memory	= require "memory"
local stats		= require "stats"

local SRC_IP = parseIPAddress("192.168.1.2")
local DST_IP = {parseIPAddress("10.0.0.1"), parseIPAddress("10.255.255.255")}

local PKT_SIZE = 60

function master(txPort, rxPort)
	if not txPort or not rxPort then
		errorf("usage: txPort[:numcores] rxPort")
	end
	if type(txPort) == "string" then
		txPort, txCores = tonumberall(txPort:match("(%d+):(%d+)"))
	else
		txPort, txCores = txPort, 1
	end
	if not txPort or not txCores then
		print("could not parse " .. tostring(txPort))
		return
	end
	local txDev = device.config({port = txPort, txQueues = txCores + 1})
	local rxDev = device.config({port = rxPort, rxQueues = 1 })
	device.waitForLinks()
	for i = 1, txCores do
		dpdk.launchLua("loadSlave", txDev, txDev:getTxQueue(i - 1, i==1)
	end
	runTest(txDev:getTxQueue(txCores), rxDev:getRxQueue(0))
end

function loadSlave(txDev, txQueue, showStats)
local mem = memory.createMemPool(function(buf)
		buf:getUdpPacket():fill{
			pktLength = PKT_SIZE,
			ethSrc = txQueue,
			ethDst = "10:11:12:13:14:15",
			ip4Src = SRC_IP,
			ip4Dst = DST_IP,
			udpSrc = 1234,
			udpDst = 5678,	
		}
	end)
	bufs = mem:bufArray(128)
	local ctr = stats:newDevTxCounter(txDev, "plain")
	while dpdk.running() do
		bufs:alloc(PKT_SIZE)
		for _, buf in ipairs(bufs) do
			local pkt = buf:getUdpPacket()
			pkt.ip4.dst:set(math.random(DST_IP[1], DST_IP[2]))
		end
		-- UDP checksums are optional, so just IP checksums are sufficient here
		bufs:offloadIPChecksums()
		queue:send(bufs)
		if showStats then ctr:update() end
	end
	if showStats then ctr:finalize() end
end

function runTest(txQueue, rxQueue)
	local timestamper = ts:newTimestamper(txQueue, rxQueue)
	local hist = hist:new()
	while mg.running() do
		hist:update(timestamper:measureLatency())
	end
	hist:save("histogram.csv")
	hist:print()
end