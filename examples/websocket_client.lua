--[[
Example of websocket client usage

  - Connects to the coinbase feed.
  - Sends a subscribe message
  - Prints off 5 messages
  - Close the socket and clean up.
]]

local json = require "cjson"
local websocket = require "http.websocket"

local ws = websocket.new_from_uri("ws://ws-feed.exchange.coinbase.com")
assert(ws:connect())
assert(ws:send(json.encode({type = "subscribe", product_id = "BTC-USD"})))
for _=1, 5 do
	local data = assert(ws:receive())
	print(data)
end
assert(ws:close())
