-- Render the README's benchmark chart from benchstat output.
--
--   lua bench/plot/plot.lua [BENCHSTAT [ARM...]]
--
-- BENCHSTAT is `just bench-compare`'s benchstat.txt, or any text that holds
-- its tables, such as a results write-up; it defaults to
-- zig-out/bench-compare/benchstat.txt. Each ARM names a column to chart
-- against `ref`, one bar per row each, in the key's order; with none, the
-- first column after `ref`. Writes docs/static/benchmark.svg and
-- benchmark-dark.svg: one row per program, our wall time and peak RSS as a
-- share of the reference's, sorted by the first arm's time. Only the brand
-- palette is used.

local input = arg[1] or "zig-out/bench-compare/benchstat.txt"
local wanted = { table.unpack(arg, 2) }

local INK, PAPER, HEAT, SLATE = "#16191d", "#f4f1ec", "#d4412b", "#58616c"
local FONT = "ui-sans-serif, system-ui, -apple-system, 'Segoe UI', sans-serif"

local WIDTH, LEFT, RIGHT, GAP = 760, 100, 24, 32
local TOP, BOTTOM = 92, 48
local PANEL = (WIDTH - LEFT - RIGHT - GAP) / 2
local LABEL = 40 -- the value column at the right of each panel

local scale = { n = 1e-9, ["µ"] = 1e-6, m = 1e-3, k = 1e3, M = 1e6, G = 1e9 }

local function number(token)
	local digits, suffix = token:match("^([%d.]+)(%D*)$")
	assert(digits, "not a benchstat value: " .. token)
	return tonumber(digits) * (scale[suffix] or 1)
end

local function split(line)
	local cells = {}
	for cell in line:gmatch("[^│]+") do
		cells[#cells + 1] = cell:match("^%s*(.-)%s*$")
	end
	return cells
end

-- Each benchstat table is an arm line (`│ ref │ ours │`), a unit line
-- (`│ sec/op │ sec/op vs base │`), then rows. Keep the first sec/op and
-- peak-RSS-KiB tables that have Lua/ rows; bench-capi's tables have none.
local tables, arms, unit = {}, nil, nil
local cpu
local handle = assert(io.open(input))
for line in handle:lines() do
	cpu = cpu or line:match("^cpu: (.+)$")
	if line:find("│", 1, true) then
		local cells = split(line)
		if line:find("vs base", 1, true) then
			unit = (cells[2] == "sec/op" and "time") or (cells[2] == "peak-RSS-KiB" and "rss") or nil
		else
			arms, unit = { table.unpack(cells, 2) }, nil
		end
	elseif unit then
		local name, rest = line:match("^Lua/(%S+)%s+(.*)$")
		if name then
			tables[unit] = tables[unit] or { arms = arms, rows = {}, from = arms }
			local t = tables[unit]
			if t.from == arms then
				local values = {}
				for v in rest:gmatch("(%S+) ±%s+%S+") do
					values[#values + 1] = number(v)
				end
				t.rows[name] = { values = values }
			end
		end
	end
end
handle:close()

assert(tables.time and tables.rss, input .. " has no sec/op and peak-RSS-KiB tables")
assert(tables.time.arms[1] == "ref", "the first arm is " .. tostring(tables.time.arms[1]) .. ", not ref")
if #wanted == 0 then
	wanted = { tables.time.arms[2] }
end

local function column(t, arm)
	for i, name in ipairs(t.arms) do
		if name == arm then
			return i
		end
	end
	error("no arm " .. arm .. " in " .. input)
end

-- One series per arm. A lone arm, `ours`, is `just bench-compare`'s default
-- build, ReleaseFast.
local series, bases = {}, {}
for _, arm in ipairs(wanted) do
	local mode = arm:match("^ours%-(.+)$") or "ReleaseFast"
	local base = mode:gsub("%-capi$", "")
	series[#series + 1] = {
		tcol = column(tables.time, arm),
		rcol = column(tables.rss, arm),
		base = base,
		label = mode:match("%-capi$") and "With the C API" or "Pure Zig",
	}
	bases[base] = true
end
local base = next(bases)
if next(bases, base) then
	base = nil
	for _, s in ipairs(series) do
		s.label = s.label .. " (" .. s.base .. ")"
	end
end

local rows = {}
for name, t in pairs(tables.time.rows) do
	local r = assert(tables.rss.rows[name], name .. " has no peak-RSS-KiB row")
	local function share(row, col)
		local ratio = row.values[col] / row.values[1]
		return { ratio = ratio, ref = row.values[1], ours = row.values[col] }
	end
	local row = { name = name, time = {}, rss = {} }
	for k, s in ipairs(series) do
		row.time[k], row.rss[k] = share(t, s.tcol), share(r, s.rcol)
	end
	rows[#rows + 1] = row
end
table.sort(rows, function(a, b)
	return a.time[1].ratio < b.time[1].ratio
end)

local geo = { name = "geomean", time = {}, rss = {} }
for _, key in ipairs({ "time", "rss" }) do
	for k in ipairs(series) do
		local ref, ours = 0, 0
		for _, row in ipairs(rows) do
			ref, ours = ref + math.log(row[key][k].ref), ours + math.log(row[key][k].ours)
		end
		geo[key][k] = { ratio = math.exp((ours - ref) / #rows) }
	end
end

local function percent(ratio)
	local d = math.floor((ratio - 1) * 100 + 0.5)
	if d == 0 then
		return "0%"
	end
	return (d > 0 and "+" or "−") .. math.abs(d) .. "%"
end

local function escape(s)
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function text(x, y, s, size, fill, anchor, weight)
	return string.format(
		'<text x="%.1f" y="%.1f" font-size="%s" fill="%s" font-family="%s" font-weight="%s" text-anchor="%s">%s</text>',
		x,
		y,
		size,
		fill,
		FONT,
		weight or "normal",
		anchor or "start",
		escape(s)
	)
end

-- One bar is 10 high; two or more share a row at 7 each, 2 apart.
local BAR = #series == 1 and 10 or 7
local PITCH = BAR + 2
local ROW = #series * PITCH + 6
local height = TOP + ROW * (#rows + 1) + 12 + BOTTOM

local function render(theme, path)
	local out = {
		string.format(
			'<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" role="img">',
			WIDTH,
			height,
			WIDTH,
			height
		),
		string.format('<rect width="%d" height="%d" fill="%s"/>', WIDTH, height, theme.bg),
		text(LEFT, 30, "lua against reference Lua 5.5.1", 15, theme.fg, "start", "700"),
		text(
			LEFT,
			48,
			"Each bar is our median as a share of the reference's, which is the dashed line. Shorter is better.",
			8.5,
			theme.muted
		),
	}
	-- The key, right-aligned on the title's line.
	if #series > 1 then
		local x = WIDTH - RIGHT
		for k = #series, 1, -1 do
			local label = series[k].label
			x = x - (#label * 4.4 + 19)
			out[#out + 1] = string.format('<rect x="%.1f" y="23" width="14" height="7" rx="1.5" fill="%s"/>', x, theme.series[k])
			out[#out + 1] = text(x + 19, 30, label, 8, theme.fg)
			x = x - 16
		end
	end
	local bottom = TOP + ROW * (#rows + 1) + 12
	for p, panel in ipairs({ { "time", "Wall time" }, { "rss", "Peak memory" } }) do
		local key, title = panel[1], panel[2]
		local x0 = LEFT + (p - 1) * (PANEL + GAP)
		local most = 1
		for _, row in ipairs({ geo, table.unpack(rows) }) do
			for _, v in ipairs(row[key]) do
				most = math.max(most, v.ratio)
			end
		end
		local span = (PANEL - LABEL) / most
		local refx = x0 + span
		out[#out + 1] = text(x0, TOP - 18, title, 10, theme.fg, "start", "600")
		out[#out + 1] = text(refx - 4, TOP - 18, "reference", 7.5, theme.muted, "end")
		out[#out + 1] = string.format(
			'<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="1" stroke-dasharray="3,3" opacity="0.7"/>',
			refx,
			TOP - 10,
			refx,
			bottom,
			theme.muted
		)
		local function bars(row, top)
			for k, v in ipairs(row[key]) do
				local y = top + (k - 1) * PITCH
				out[#out + 1] = string.format(
					'<rect x="%.1f" y="%.1f" width="%.1f" height="%d" rx="1.5" fill="%s"/>',
					x0,
					y,
					span * v.ratio,
					BAR,
					theme.series[k]
				)
				out[#out + 1] = text(x0 + PANEL, y + BAR - 1, percent(v.ratio), #series == 1 and 8 or 7, theme.muted, "end")
			end
		end
		for i, row in ipairs(rows) do
			bars(row, TOP + ROW * (i - 1) + 3)
		end
		bars(geo, TOP + ROW * #rows + 15)
	end
	for i, row in ipairs(rows) do
		out[#out + 1] = text(LEFT - 12, TOP + ROW * (i - 0.5) + 3.5, row.name, 9, theme.fg, "end")
	end
	out[#out + 1] = string.format(
		'<line x1="0" y1="%.1f" x2="%d" y2="%.1f" stroke="%s" stroke-width="0.7" opacity="0.4"/>',
		TOP + ROW * #rows + 6,
		WIDTH - RIGHT,
		TOP + ROW * #rows + 6,
		theme.muted
	)
	out[#out + 1] = text(LEFT - 12, TOP + ROW * (#rows + 0.5) + 15.5, "geomean", 9, theme.fg, "end", "600")
	out[#out + 1] = text(
		LEFT,
		height - 22,
		"The bench/ programs"
			.. (base and " on " .. base .. " builds" or "")
			.. ": medians of interleaved runs pinned to one core.",
		6.5,
		theme.muted
	)
	out[#out + 1] = text(LEFT, height - 12, (cpu or "") .. ", a shared VM. Local numbers, not a benchmark claim.", 6.5, theme.muted)
	out[#out + 1] = "</svg>\n"
	local file = assert(io.open(path, "w"))
	file:write(table.concat(out, "\n"))
	file:close()
	print("wrote " .. path)
end

render({ bg = PAPER, fg = INK, muted = SLATE, series = { HEAT, SLATE, "#a3abb5" } }, "docs/static/benchmark.svg")
render({ bg = INK, fg = PAPER, muted = "#a3abb5", series = { HEAT, "#a3abb5", SLATE } }, "docs/static/benchmark-dark.svg")
for k, s in ipairs(series) do
	print(string.format("geomean, %s: time %s, peak RSS %s", s.label, percent(geo.time[k].ratio), percent(geo.rss[k].ratio)))
end
