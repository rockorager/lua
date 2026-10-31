-- A JSON encoder and decoder written the way the common pure-Lua libraries
-- are: the decoder scans with string.byte and string.find and cuts with
-- string.sub, the encoder escapes strings through gsub, sorts object keys,
-- and joins its pieces with table.concat. Each pass encodes a generated
-- document of nested records, decodes it, and encodes the result again.
-- Usage: lua json.lua [N], default 800 records. Prints a checksum.

local n = tonumber(arg and arg[1]) or 800
local passes = 10

local byte, sub, find, format, gsub = string.byte, string.sub, string.find, string.format, string.gsub
local concat, sort = table.concat, table.sort
local mtype, uchar = math.type, utf8.char

-- JSON's null, distinct from a missing key.
local null = setmetatable({}, {
  __tostring = function()
    return "null"
  end,
})

-- Encoder.

local escapes = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function escapeChar(c)
  return escapes[c] or format("\\u%04x", byte(c))
end

local encodeValue

local function encodeString(s, out)
  out[#out + 1] = '"' .. gsub(s, '[%c"\\]', escapeChar) .. '"'
end

encodeValue = function(v, out)
  local t = type(v)
  if t == "string" then
    encodeString(v, out)
  elseif t == "number" then
    if mtype(v) == "integer" then
      out[#out + 1] = format("%d", v)
    else
      out[#out + 1] = format("%.14g", v)
    end
  elseif t == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif v == null then
    out[#out + 1] = "null"
  elseif t == "table" then
    if v[1] ~= nil or next(v) == nil then
      out[#out + 1] = "["
      for i = 1, #v do
        if i > 1 then
          out[#out + 1] = ","
        end
        encodeValue(v[i], out)
      end
      out[#out + 1] = "]"
    else
      local keys = {}
      for k in pairs(v) do
        keys[#keys + 1] = k
      end
      sort(keys)
      out[#out + 1] = "{"
      for i, k in ipairs(keys) do
        if i > 1 then
          out[#out + 1] = ","
        end
        encodeString(k, out)
        out[#out + 1] = ":"
        encodeValue(v[k], out)
      end
      out[#out + 1] = "}"
    end
  else
    error("cannot encode a " .. t)
  end
end

local function encode(v)
  local out = {}
  encodeValue(v, out)
  return concat(out)
end

-- Decoder.

local function decodeError(i, msg)
  error(format("%s at character %d", msg, i))
end

local function skipSpace(s, i)
  return find(s, "[^ \t\r\n]", i) or #s + 1
end

local unescape = {
  [34] = '"',
  [92] = "\\",
  [47] = "/",
  [98] = "\b",
  [102] = "\f",
  [110] = "\n",
  [114] = "\r",
  [116] = "\t",
}

-- The string starting at the quote at i, and the index after its closing
-- quote.
local function decodeString(s, i)
  local parts, np = nil, 0
  local j = i + 1
  while true do
    local k = find(s, '["\\]', j)
    if not k then
      decodeError(i, "unterminated string")
    end
    if byte(s, k) == 34 then
      if not parts then
        return sub(s, j, k - 1), k + 1
      end
      parts[np + 1] = sub(s, j, k - 1)
      return concat(parts), k + 1
    end
    parts = parts or {}
    np = np + 1
    parts[np] = sub(s, j, k - 1)
    local e = byte(s, k + 1)
    np = np + 1
    if e == 117 then
      local cp = tonumber(sub(s, k + 2, k + 5), 16) or decodeError(k, "bad unicode escape")
      parts[np] = uchar(cp)
      j = k + 6
    else
      parts[np] = unescape[e] or decodeError(k, "bad escape")
      j = k + 2
    end
  end
end

local function decodeNumber(s, i)
  local _, e = find(s, "^-?%d+%.?%d*[eE]?[-+]?%d*", i)
  local v = tonumber(sub(s, i, e)) or decodeError(i, "bad number")
  return v, e + 1
end

local literals = {
  [116] = { "true", true },
  [102] = { "false", false },
  [110] = { "null", null },
}

local function decodeValue(s, i)
  i = skipSpace(s, i)
  local c = byte(s, i)
  if c == 123 then
    local obj = {}
    i = skipSpace(s, i + 1)
    if byte(s, i) == 125 then
      return obj, i + 1
    end
    while true do
      if byte(s, i) ~= 34 then
        decodeError(i, "expected a key")
      end
      local key, val
      key, i = decodeString(s, i)
      i = skipSpace(s, i)
      if byte(s, i) ~= 58 then
        decodeError(i, "expected ':'")
      end
      val, i = decodeValue(s, i + 1)
      obj[key] = val
      i = skipSpace(s, i)
      c = byte(s, i)
      if c == 125 then
        return obj, i + 1
      elseif c ~= 44 then
        decodeError(i, "expected ',' or '}'")
      end
      i = skipSpace(s, i + 1)
    end
  elseif c == 91 then
    local arr, len = {}, 0
    i = skipSpace(s, i + 1)
    if byte(s, i) == 93 then
      return arr, i + 1
    end
    while true do
      local val
      val, i = decodeValue(s, i)
      len = len + 1
      arr[len] = val
      i = skipSpace(s, i)
      c = byte(s, i)
      if c == 93 then
        return arr, i + 1
      elseif c ~= 44 then
        decodeError(i, "expected ',' or ']'")
      end
      i = i + 1
    end
  elseif c == 34 then
    return decodeString(s, i)
  elseif c == 45 or (c and c >= 48 and c <= 57) then
    return decodeNumber(s, i)
  end
  local lit = literals[c]
  if lit and sub(s, i, i + #lit[1] - 1) == lit[1] then
    return lit[2], i + #lit[1]
  end
  decodeError(i, "unexpected character")
end

local function decode(s)
  local v, i = decodeValue(s, 1)
  if skipSpace(s, i) <= #s then
    decodeError(i, "trailing characters")
  end
  return v
end

-- The document: records with strings that need escaping, integers and
-- floats, booleans, nulls, and nested objects and arrays.

local cities = { "Zürich", "São Paulo", "Kraków", "Austin", "Ōsaka", "Lagos", "Montréal" }
local words = { "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta" }

local function makeRecord(i)
  local history = {}
  for h = 1, i % 4 + 1 do
    history[h] = {
      date = format("2026-%02d-%02d", h % 12 + 1, i % 28 + 1),
      amount = (i * h * 7919 % 100003) / 100,
      kind = words[(i + h) % #words + 1],
    }
  end
  return {
    id = i,
    name = "user " .. words[i % #words + 1] .. " " .. i,
    email = format("user%d@example.com", i),
    active = i % 3 ~= 0,
    score = (i * 7919 % 10007) / 64,
    balance = i * 37 % 100000 - 50000,
    tags = { words[i % 8 + 1], words[i % 5 + 1], "t" .. i % 13 },
    address = {
      street = format("%d Main St, Apt %d", i % 1000, i % 50),
      city = cities[i % #cities + 1],
      zip = format("%05d", i * 13 % 100000),
    },
    bio = 'Says "hi"\tand\\or\n' .. words[i % 7 + 1] .. "\1" .. i,
    manager = i % 5 == 0 and null or i - 1,
    history = history,
    ratio = i % 9 == 0 and 0.5 or i / 7,
  }
end

local doc = { version = 3, generated = "2026-10-31T00:00:00Z", records = {} }
for i = 1, n do
  doc.records[i] = makeRecord(i)
end

local sum = 0
for _ = 1, passes do
  local s1 = encode(doc)
  local back = decode(s1)
  local s2 = encode(back)
  assert(s1 == s2, "round trip changed the document")
  sum = sum + #s1
  for _, r in ipairs(back.records) do
    sum = sum + r.id + r.balance + #r.history + #r.address.city
    if r.manager == null then
      sum = sum + 1
    end
  end
end

print(sum, #encode(doc.records[n]))
