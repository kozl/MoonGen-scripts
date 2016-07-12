--- This script can be used to measure timestamping precision and accuracy.
--  Connect cables of different length between two ports (or a fiber loopback cable on a single port) to use this.
local dpdk		= require "dpdk"
local ts		= require "timestamping"
local device	= require "device"
local hist		= require "histogram"
local memory	= require "memory"
local stats		= require "stats"

local SRC_IP = parseIPAddress("192.168.1.2")
local DST_IP = {parseIPAddress("10.0.0.2"), parseIPAddress("10.0.0.254")}
local DST_ETH = "90:e2:ba:3f:c7:00"

local PKT_SIZE = 60

function master(txPort, rxPort, rate)
	if not txPort or not rxPort then
		errorf("usage: txPort[:numcores] rxPort rate")
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
	for i = 1, txCores do
		dpdk.launchLua("loadSlave", txDev, txDev:getTxQueue(i - 1), i==1)
	end
  dpdk.launchLua("rxCounter", rxDev)
	runTest(txDev:getTxQueue(txCores), rxDev:getRxQueue(0), PKT_SIZE)
end

function loadSlave(txDev, txQueue, showStats)
local mem = memory.createMemPool(function(buf)
		buf:getUdpPacket():fill{
			pktLength = PKT_SIZE,
			ethSrc = txQueue,
			ethDst = DST_ETH,
			ip4Src = SRC_IP,
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
		txQueue:send(bufs)
		if showStats then ctr:update() end
	end
	if showStats then ctr:finalize() end
end

function rxCounter(rxDev)
  local ctr = stats:newDevRxCounter(rxDev, "plain")
  while dpdk.running() do
    ctr:update()
  end
  ctr:finalize()
end

function runTest(txQueue, rxQueue, size)
	local timestamper = ts:newTimestamper(txQueue, rxQueue)
	local hist = hist:new()
	if size < 84 then
		log:warn("Packet size %d is smaller than minimum timestamp size 84. Timestamped packets will be larger than load packets.", size)
		size = 84
	end
	dpdk.sleepMillis(1000)
	while dpdk.running() do
		hist:update(timestamper:measureLatency(size, function(buf)
			fillUdpPacket(buf, size)
			local pkt = buf:getUdpPacket()
			pkt.ip4.src:set(SRC_IP)
			pkt.ip4.dst:set(math.random(DST_IP[1], DST_IP[2]))
			pkt.eth.dst:set(DST_ETH)
		end))
	end
	hist:save("histogram.csv")
	hist:print()
end
