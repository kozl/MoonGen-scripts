--- This script can be used to measure timestamping precision and accuracy.
--  Connect cables of different length between two ports (or a fiber loopback cable on a single port) to use this.
local moongen		= require "moongen"
local ts		= require "timestamping"
local device		= require "device"
local hist		= require "histogram"
local memory		= require "memory"
local stats		= require "stats"
local log		= require "log"
local timer 		= require "timer"

local SRC_IP = parseIPAddress("192.168.1.2")
local GW_IP = parseIPAddress("192.168.1.1")
local DST_IP = {parseIPAddress("240.0.0.2"), parseIPAddress("240.0.0.254")}
local SRC_MAC = "90:e2:ba:37:dc:44"
local DST_MAC = "90:e2:ba:3f:c7:00"
local SRC_PORT = 1234
local DST_PORT = 5678
local PKT_SIZE = 60

local function fillUdpPacket(buf, len)
	buf:getUdpPacket():fill{
		ethSrc = SRC_MAC,
		ethDst = DST_MAC,
		ip4Src = SRC_IP,
		ip4Dst = DST_IP[1],
		udpSrc = SRC_PORT,
		udpDst = DST_PORT,
		pktLength = len
	}
end

local function doArp()
	if not DST_MAC then
		log:info("Performing ARP lookup on %s", GW_IP)
		DST_MAC = arp.blockingLookup(GW_IP, 5)
		if not DST_MAC then
			log:info("ARP lookup failed, using default destination mac address")
			return
		end
	end
	log:info("Destination mac: %s", DST_MAC)
end

function master(txPort, rxPort, rate, size, duration)
	if not txPort or not rxPort then
		errorf("usage: txPort[:numcores] rxPort [rate] [size] [duration]")
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
	if rate then
		rate = rate/txCores
		for i = 1, txCores do
			txDev:getTxQueue(i - 1):setRate(rate)
		end
	end
	if not duration then duration = 3600 end
	if size then PKT_SIZE = size end
	for i = 1, txCores do
		moongen.startTask("loadSlave", txDev, txDev:getTxQueue(i - 1), rxDev, i==1, PKT_SIZE, duration)
	end
	runTest(txDev:getTxQueue(txCores), rxDev:getRxQueue(0), PKT_SIZE, duration)
end

function loadSlave(txDev, txQueue, rxDev, showStats, size, duration)
	doArp()
	SRC_MAC = txQueue
	PKT_SIZE = size
	local mem = memory.createMemPool(function(buf)
		fillUdpPacket(buf, PKT_SIZE)
	end)
	bufs = mem:bufArray(128)
	local ctrTx = stats:newDevTxCounter(txDev, "plain")
	local ctrRx = stats:newDevRxCounter(rxDev, "plain")
	local timer = timer:new(duration)
	while moongen.running() and timer:running() do
		bufs:alloc(PKT_SIZE)
		for _, buf in ipairs(bufs) do
			local pkt = buf:getUdpPacket()
			pkt.ip4.dst:set(math.random(DST_IP[1], DST_IP[2]))
		end
		-- UDP checksums are optional, so just IP checksums are sufficient here
		bufs:offloadUdpChecksums()
		txQueue:send(bufs)
		if showStats then 
			ctrTx:update()
			ctrRx:update()
		end
	end
	if showStats then 
		ctrTx:finalize()
		ctrRx:finalize()
	end
end

function runTest(txQueue, rxQueue, size, duration)
	local timestamper = ts:newUdpTimestamper(txQueue, rxQueue)
	local hist = hist:new()
	if size < 84 then
		log:warn("Packet size %d is smaller than minimum timestamp size 84. Timestamped packets will be larger than load packets.", size)
		size = 84
	end
	dpdk.sleepMillis(500)
	local timer = timer:new(duration)
	while dpdk.running() and timer:running() do
		hist:update(timestamper:measureLatency(size, function(buf)
			fillUdpPacket(buf, size)
		end))
	end
	dpdk.sleepMillis(1000)
	hist:print()
	hist:save("histogram.csv")
end
