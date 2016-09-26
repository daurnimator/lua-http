--[[
Example of websocket client usage

  - Connects to the coinbase feed.
	Documentation of feed: https://docs.exchange.coinbase.com/#websocket-feed
  - Sends a subscribe message
  - Prints off 5 messages
  - Close the socket and clean up.
]]

local websocket = require "http.websocket"

local ws = websocket.new_from_uri("wss://ws-feed.exchange.coinbase.com")
assert(ws:connect())
assert(ws:send([[{"type": "subscribe", "product_id": "BTC-USD"}]]))
for _=1, 5 do
	local data = assert(ws:receive())
	print(data)
end
assert(ws:close())
