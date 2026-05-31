-- Minimal base64 encoder (pure Lua) for binary JPEG data.
local B = {}

local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function B.encode(data)
	local out = {}
	local len = #data
	local i = 1
	while i <= len do
		local b1 = string.byte(data, i)
		local b2 = i + 1 <= len and string.byte(data, i + 1) or nil
		local b3 = i + 2 <= len and string.byte(data, i + 2) or nil

		local n = b1 * 65536 + (b2 or 0) * 256 + (b3 or 0)
		local c1 = math.floor(n / 262144) % 64
		local c2 = math.floor(n / 4096) % 64
		local c3 = math.floor(n / 64) % 64
		local c4 = n % 64

		out[#out + 1] = chars:sub(c1 + 1, c1 + 1)
		out[#out + 1] = chars:sub(c2 + 1, c2 + 1)
		out[#out + 1] = b2 and chars:sub(c3 + 1, c3 + 1) or "="
		out[#out + 1] = b3 and chars:sub(c4 + 1, c4 + 1) or "="

		i = i + 3
	end
	return table.concat(out)
end

return B
