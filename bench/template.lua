-- Building text the way web frameworks and report generators do: HTML
-- pages from templates whose {{placeholders}} gsub fills through a function
-- that walks dotted paths, HTML escaping through gsub with a table, money
-- and dates through string.format with thousands separators added by a
-- gsub loop, and a plain-text report with word wrapping and padded
-- columns. Pages are assembled with table.concat.
-- Usage: lua template.lua [N], default 2400 invoices. Prints a checksum.

local n = tonumber(arg and arg[1]) or 2400

local format, gsub, gmatch, rep, upper = string.format, string.gsub, string.gmatch, string.rep, string.upper
local byte, concat = string.byte, table.concat

local page_template = [[
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>{{title}}</title></head>
<body>
<header><h1>{{title}}</h1><p class="to">{{customer.name}} &lt;{{customer.email}}&gt;</p>
<p class="addr">{{customer.address.street}}, {{customer.address.city}} {{customer.address.zip}}</p></header>
<p class="meta">Invoice {{number}} issued {{date}}, due {{due}}. Terms: {{terms}}</p>
<table class="items">
<thead><tr><th>#</th><th>Item</th><th>Qty</th><th>Price</th><th>Amount</th></tr></thead>
<tbody>
{{rows}}
</tbody>
</table>
<p class="subtotal">Subtotal: {{subtotal}}</p>
<p class="tax">Tax ({{tax_rate}}): {{tax}}</p>
<p class="total">Total due: {{total}}</p>
<footer>{{note}}</footer>
</body>
</html>
]]

local row_template =
  [[<tr class="{{class}}"><td>{{index}}</td><td>{{item.name}} <small>{{item.sku}}</small></td><td>{{qty}}</td><td>{{price}}</td><td>{{amount}}</td></tr>]]

local html_escapes = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }

local function escape(s)
  return (gsub(s, "[&<>\"']", html_escapes))
end

local function lookup(ctx, path)
  local v = ctx
  for part in gmatch(path, "[^.]+") do
    v = v[part]
    if v == nil then
      return ""
    end
  end
  return v
end

-- Fills every {{path}} in tpl from ctx, escaped unless raw[path].
local function render(tpl, ctx, raw)
  return (gsub(tpl, "{{([%w_.]+)}}", function(path)
    local v = lookup(ctx, path)
    if raw and raw[path] then
      return v
    end
    return escape(tostring(v))
  end))
end

local function money(cents)
  local s = format("%.2f", cents / 100)
  local k
  repeat
    s, k = gsub(s, "^(-?%d+)(%d%d%d)", "%1,%2")
  until k == 0
  return "$" .. s
end

local products = {}
local adjectives = { "Deluxe", "Compact", "Rugged", "Smart", "Classic", "Eco", "Pro", "Mini" }
local nouns = { "Widget", "Gadget", "Sprocket", "Bracket", "Cable", "Lamp", "Kettle", "Drill" }
for i = 1, 64 do
  products[i] = {
    name = format("%s %s <%s & Co.>", adjectives[i % 8 + 1], nouns[(i * 3) % 8 + 1], i % 2 == 0 and "Acme" or "O'Neil"),
    sku = format("SKU-%04d-%s", i * 37 % 10000, upper(nouns[i % 8 + 1]:sub(1, 3))),
    cents = (i * 7919) % 250000 + 99,
  }
end

local streets = { "Elm St", "Oak Ave", "Maple Rd", "Pine Ln", "Cedar Blvd" }
local cities = { "Springfield", "Riverside", "Fairview", "Madison", "Georgetown", "Clinton" }

local raw = { rows = true }
local note = "Thank you for your business. Payment is due within thirty days of the invoice date; "
  .. "late payments accrue interest at one and a half percent per month. Questions about this "
  .. "invoice can be sent to billing@example.com or answered by phone during business hours."

-- Word-wraps text at width, each line indented.
local function wrap(text, width, indent)
  local lines, line = {}, indent
  for word in gmatch(text, "%S+") do
    if #line + #word + 1 > width and #line > #indent then
      lines[#lines + 1] = line
      line = indent .. word
    elseif #line == #indent then
      line = line .. word
    else
      line = line .. " " .. word
    end
  end
  lines[#lines + 1] = line
  return concat(lines, "\n")
end

local sum = 0
local last
for inv = 1, n do
  local customer = {
    name = format("Customer #%d \"%s\"", inv, adjectives[inv % 8 + 1]),
    email = format("billing+%d@client%d.example.com", inv, inv % 17),
    address = {
      street = format("%d %s", inv * 7 % 9000 + 100, streets[inv % #streets + 1]),
      city = cities[inv % #cities + 1],
      zip = format("%05d", inv * 389 % 100000),
    },
  }
  local rows, report = {}, {}
  local subtotal = 0
  local count = inv % 20 + 10
  for r = 1, count do
    local p = products[(inv * 31 + r * 7) % #products + 1]
    local qty = (inv + r) % 9 + 1
    local amount = p.cents * qty
    subtotal = subtotal + amount
    rows[r] = render(row_template, {
      class = r % 2 == 0 and "even" or "odd",
      index = r,
      item = p,
      qty = qty,
      price = money(p.cents),
      amount = money(amount),
    })
    report[r] = format("%3d  %-36s %4d x %12s = %14s", r, p.name, qty, money(p.cents), money(amount))
  end
  local tax = subtotal * 825 // 10000
  local ctx = {
    title = format("Invoice %06d", inv),
    customer = customer,
    number = format("INV-%04d-%06d", 2026, inv),
    date = format("2026-%02d-%02d", inv % 12 + 1, inv % 28 + 1),
    due = format("2026-%02d-%02d", (inv + 1) % 12 + 1, inv % 28 + 1),
    terms = "Net 30 & no returns after 14 days",
    rows = concat(rows, "\n"),
    subtotal = money(subtotal),
    tax_rate = "8.25%",
    tax = money(tax),
    total = money(subtotal + tax),
    note = note,
  }
  local page = render(page_template, ctx, raw)
  local text = concat({
    rep("=", 78),
    format("%-40s%38s", ctx.title, ctx.date),
    format("%-40s%38s", customer.name, customer.address.city),
    rep("-", 78),
    concat(report, "\n"),
    rep("-", 78),
    format("%62s %15s", "Subtotal", ctx.subtotal),
    format("%62s %15s", "Tax", ctx.tax),
    format("%62s %15s", "Total", ctx.total),
    "",
    wrap(note, 72, "    "),
  }, "\n")
  sum = sum + #page + #text
  last = page
end

-- A position-weighted sum of the last page's bytes.
local h = 0
for i = 1, #last, 7 do
  h = (h * 31 + byte(last, i)) % 1000000007
end

print(sum, h)
