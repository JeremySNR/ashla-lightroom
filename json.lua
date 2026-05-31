-- Minimal pure-Lua JSON encode/decode. Sufficient for OpenAI request/response payloads.
local json = {}

----------------------------------------------------------------------
-- Encode
----------------------------------------------------------------------
local escape_map = {
	["\\"] = "\\\\", ["\""] = "\\\"", ["\b"] = "\\b",
	["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function escape_str(s)
	return (s:gsub('[%c\\"]', function(c)
		return escape_map[c] or string.format("\\u%04x", string.byte(c))
	end))
end

local function is_array(t)
	local n = 0
	for k in pairs(t) do
		if type(k) ~= "number" then return false end
		n = n + 1
	end
	return n == #t
end

local encode_value

local function encode_table(t)
	if next(t) == nil then return "{}" end
	local parts = {}
	if is_array(t) then
		for _, v in ipairs(t) do
			parts[#parts + 1] = encode_value(v)
		end
		return "[" .. table.concat(parts, ",") .. "]"
	else
		for k, v in pairs(t) do
			parts[#parts + 1] = '"' .. escape_str(tostring(k)) .. '":' .. encode_value(v)
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
end

encode_value = function(v)
	local tv = type(v)
	if tv == "string" then
		return '"' .. escape_str(v) .. '"'
	elseif tv == "number" then
		if v ~= v or v == math.huge or v == -math.huge then return "null" end
		return string.format("%.10g", v)
	elseif tv == "boolean" then
		return tostring(v)
	elseif tv == "table" then
		return encode_table(v)
	else
		return "null"
	end
end

function json.encode(v)
	return encode_value(v)
end

----------------------------------------------------------------------
-- Decode
----------------------------------------------------------------------
local function decode_error(str, pos, msg)
	error(("JSON decode error at %d: %s"):format(pos, msg), 0)
end

local decode_value

local function skip_ws(str, pos)
	local _, e = str:find("^[ \t\r\n]*", pos)
	return e + 1
end

local unescape_map = {
	['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b",
	f = "\f", n = "\n", r = "\r", t = "\t",
}

local function decode_string(str, pos)
	local out = {}
	local i = pos + 1
	while i <= #str do
		local c = str:sub(i, i)
		if c == '"' then
			return table.concat(out), i + 1
		elseif c == "\\" then
			local nc = str:sub(i + 1, i + 1)
			if nc == "u" then
				local hex = str:sub(i + 2, i + 5)
				local code = tonumber(hex, 16)
				if code and code < 128 then
					out[#out + 1] = string.char(code)
				else
					out[#out + 1] = "?" -- non-ASCII unicode left as placeholder
				end
				i = i + 6
			else
				out[#out + 1] = unescape_map[nc] or nc
				i = i + 2
			end
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	decode_error(str, pos, "unterminated string")
end

local function decode_number(str, pos)
	local s, e = str:find("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
	local num = tonumber(str:sub(s, e))
	if not num then decode_error(str, pos, "invalid number") end
	return num, e + 1
end

local function decode_array(str, pos)
	local arr = {}
	pos = skip_ws(str, pos + 1)
	if str:sub(pos, pos) == "]" then return arr, pos + 1 end
	while true do
		local val
		val, pos = decode_value(str, pos)
		arr[#arr + 1] = val
		pos = skip_ws(str, pos)
		local c = str:sub(pos, pos)
		if c == "]" then return arr, pos + 1 end
		if c ~= "," then decode_error(str, pos, "expected ',' or ']'") end
		pos = skip_ws(str, pos + 1)
	end
end

local function decode_object(str, pos)
	local obj = {}
	pos = skip_ws(str, pos + 1)
	if str:sub(pos, pos) == "}" then return obj, pos + 1 end
	while true do
		if str:sub(pos, pos) ~= '"' then decode_error(str, pos, "expected key string") end
		local key
		key, pos = decode_string(str, pos)
		pos = skip_ws(str, pos)
		if str:sub(pos, pos) ~= ":" then decode_error(str, pos, "expected ':'") end
		pos = skip_ws(str, pos + 1)
		local val
		val, pos = decode_value(str, pos)
		obj[key] = val
		pos = skip_ws(str, pos)
		local c = str:sub(pos, pos)
		if c == "}" then return obj, pos + 1 end
		if c ~= "," then decode_error(str, pos, "expected ',' or '}'") end
		pos = skip_ws(str, pos + 1)
	end
end

decode_value = function(str, pos)
	pos = skip_ws(str, pos)
	local c = str:sub(pos, pos)
	if c == "{" then return decode_object(str, pos)
	elseif c == "[" then return decode_array(str, pos)
	elseif c == '"' then return decode_string(str, pos)
	elseif c == "t" and str:sub(pos, pos + 3) == "true" then return true, pos + 4
	elseif c == "f" and str:sub(pos, pos + 4) == "false" then return false, pos + 5
	elseif c == "n" and str:sub(pos, pos + 3) == "null" then return nil, pos + 4
	else return decode_number(str, pos) end
end

function json.decode(str)
	local ok, result = pcall(function()
		local v, pos = decode_value(str, 1)
		return v
	end)
	if ok then return result end
	return nil, result
end

return json
