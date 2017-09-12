local Datagram = require("lib.protocol.datagram")
local Ethernet = require("lib.protocol.ethernet")
local IPV4 = require("lib.protocol.ipv4")
local TCP = require("lib.protocol.tcp")
local ffi = require("ffi")

local networking_magic_numbers = require("networking_magic_numbers")

local function make_payload(len)
   local buf = ffi.new('char[?]', len)
   for i=0,len-1 do
      buf[i] = i % 256
   end
   return ffi.string(buf, len)
end

-- Returns an array of payload fragments
local function split_payload(payload, payload_len, fragment_len)
   -- add fragment_payload_len-1 to handle case when payload_len is divisible by fragment_payload_len
   -- want to compute (payload_len + fragment_len - 1) // fragment_payload_len but lua5.1 has no integer division
   local dividend = payload_len + fragment_len - 1
   local num_fragments = (dividend - dividend % fragment_len) / fragment_len
   local fragments = {n = num_fragments}
   for i=1,num_fragments do
      local curr_fragment_len = fragment_len
      if i == num_fragments then
         curr_fragment_len = payload_len - fragment_len * (num_fragments-1)
      end
      local fragment = string.sub(payload, (i-1) * fragment_len + 1, math.min(i * fragment_len, payload_len))
      fragments[i] = fragment
   end
   return fragments
end

function make_ipv4_packet(config)
   local payload_length = config.payload_length or 100
   local payload = config.payload or
      make_payload(payload_length)

   local datagram = Datagram:new(nil, nil, {delayed_commit = true})
   datagram:payload(payload, payload_length)
   
   local tcp_header_size = 0
   if not config.skip_tcp_header then
      local tcp_header = TCP:new({
      })
      tcp_header_size = tcp_header:sizeof()
      -- TCP data offset field is in units of 32-bit words
      tcp_header:offset(tcp_header_size / 4)
      tcp_header:checksum()
      datagram:push(tcp_header)
   end

   local ip_header = IPV4:new({
      src = config.src_addr,
      dst = config.dst_addr,
      protocol = L4_TCP,
      flags = config.ip_flags or 0,
      frag_off = config.frag_off or 0
   })
   ip_header:total_length(ip_header:sizeof() + tcp_header_size + payload_length)
   ip_header:checksum()
   datagram:push(ip_header)

   local eth_header = Ethernet:new({
      src = config.src_mac,
      dst = config.dst_addr,
      type = L3_IPV4
   })
   datagram:push(eth_header)

   datagram:commit()
   return datagram:packet()
end

function make_fragmented_ipv4_packets(config)
   
   local payload_length = config.payload_length or 500
   local payload = config.payload or
      make_payload(payload_length)

   local datagram = Datagram:new(nil, nil, {delayed_commit = true})
   datagram:payload(payload, payload_length)

   local tcp_header = TCP:new({
   })
   local tcp_header_size = tcp_header:sizeof()
   -- TCP data offset field is in units of 32-bit words
   tcp_header:offset(tcp_header_size / 4)
   tcp_header:checksum()
   datagram:push(tcp_header)

   local ip_payload_length = payload_length + tcp_header_size
   datagram:commit()
   local ip_payload = ffi.string(datagram:packet().data, ip_payload_length)

   local fragment_len = (config.mtu or 100) - IP_HEADER_LENGTH
   -- fragment length must be a multiple of 8
   fragment_len = fragment_len - fragment_len % 8
   local fragments = split_payload(ip_payload, ip_payload_length, fragment_len)
   local num_fragments = fragments.n
   local packets = {n = num_fragments}
   for i=1,num_fragments do
      local ip_flags = 0
      if i ~= num_fragments then
         ip_flags = IP_MF_FLAG
      end
      packets[i] = make_ipv4_packet({
         payload = fragments[i],
         payload_length = fragment_len,
         skip_tcp_header = true,
         src_mac = config.src_mac,
         dst_mac = config.dst_mac,
         src_addr = config.src_addr,
         dst_addr = config.dst_addr,
         ip_flags = ip_flags,
         -- fragment offset field is in multiples of 8
         frag_off = (i-1) * fragment_len / 8
      })
   end
   return packets
end
