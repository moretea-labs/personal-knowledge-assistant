---
name: Library/greyson/PKS Search
tags: meta/library
description: Search PKS sources from SilverBullet and open exact in-space notes.
---
# PKS Search

Adds **PKS: Search** to the SilverBullet command palette.

Search results come from the existing PKS service. Results inside this Space open at their exact relative path. Results outside this Space are shown as a read-only preview through PKS bounded-read; no content is copied into the Space.

```space-lua
-- priority: 20
pks = pks or {}

local PKS_BASE = "http://127.0.0.1:3217"
local PREVIEW_LIMIT = 8000

local function encode(value)
  return (tostring(value):gsub("([^%w%-_%.~])", function(char)
    local codepoint = string.byte(char)
    if codepoint <= 0x7F then
      return string.format("%%%02X", codepoint)
    elseif codepoint <= 0x7FF then
      return string.format("%%%02X%%%02X", 0xC0 + math.floor(codepoint / 64), 0x80 + codepoint % 64)
    elseif codepoint <= 0xFFFF then
      return string.format("%%%02X%%%02X%%%02X", 0xE0 + math.floor(codepoint / 4096), 0x80 + math.floor(codepoint / 64) % 64, 0x80 + codepoint % 64)
    end
    return string.format("%%%02X%%%02X%%%02X%%%02X", 0xF0 + math.floor(codepoint / 262144), 0x80 + math.floor(codepoint / 4096) % 64, 0x80 + math.floor(codepoint / 64) % 64, 0x80 + codepoint % 64)
  end))
end

local function request(path)
  local response = net.proxyFetch(PKS_BASE .. path)
  if not response.ok then
    error("PKS HTTP " .. tostring(response.status))
  end
  return response.body
end

local function currentSpaceRoot()
  local base = spacelua.baseUrl()
  if type(base) ~= "string" or base == "" then return nil end
  local response = net.proxyFetch(base .. "/.ping")
  if not response.ok then return nil end
  local root = (response.headers or {})["x-space-path"]
  if type(root) ~= "string" or root == "" then return nil end
  return root:gsub("/+$", "")
end

local function inSpacePath(uri, root)
  if type(uri) ~= "string" or type(root) ~= "string" or root == "" then
    return nil
  end
  root = root:gsub("/+$", "")
  if root == "" then return nil end
  local prefix = root .. "/"
  if uri:sub(1, #prefix) ~= prefix then return nil end
  local relative = uri:sub(#prefix + 1)
  if relative == "" then return nil end
  for segment in relative:gmatch("[^/]+") do
    if segment == "." or segment == ".." then return nil end
  end
  if relative:sub(-3):lower() == ".md" then
    relative = relative:sub(1, -4)
  end
  return relative
end

local function clip(value, maxChars)
  local text = tostring(value or ""):gsub("%s+", " ")
  if #text > maxChars then
    return text:sub(1, maxChars) .. "…"
  end
  return text
end

local function previewExternal(result)
  if type(result.documentId) ~= "string" or result.documentId == "" then
    editor.flashNotification("PKS result has no document ID.", "warning")
    return
  end
  local data = request("/api/read/" .. encode(result.documentId) .. "?maxChars=" .. PREVIEW_LIMIT)
  if type(data) ~= "table" or type(data.content) ~= "string" then
    editor.flashNotification("PKS has no readable preview for this result.", "warning")
    return
  end
  local document = data.document or {}
  local title = tostring(document.title or result.title or "PKS result")
  local source = tostring(result.sourceType or "source")
  local uri = tostring(document.uri or result.uri or "")
  local truncated = data.truncated and "\n\n[Preview truncated at 8,000 characters]" or ""
  editor.alert(title .. "\n" .. source .. "\n" .. uri .. "\n\n" .. data.content .. truncated)
end

function pks.search()
  local searchText = editor.prompt("Search all PKS sources")
  if not searchText or searchText:gsub("%s+", "") == "" then return end

  local ok, err = pcall(function()
    local results = request("/api/search?q=" .. encode(searchText) .. "&limit=20")
    if type(results) ~= "table" then error("Invalid PKS search response") end
    if #results == 0 then
      editor.flashNotification("No PKS results found.", "info")
      return
    end

    local root = currentSpaceRoot()
    if not root then
      editor.flashNotification("Space path unavailable; results will open as previews.", "warning")
    end

    local options = {}
    for _, result in ipairs(results) do
      local title = tostring(result.title or "Untitled")
      local heading = tostring(result.headingPath or "")
      local label = title
      if heading ~= "" and heading ~= title then label = label .. " — " .. heading end
      local score = tonumber(result.score) or 0
      local description = tostring(result.sourceType or "source") .. " · " .. string.format("%.2f", score)
      if result.indexStatus then description = description .. " · " .. tostring(result.indexStatus) end
      if result.snippet then description = description .. " · " .. clip(result.snippet, 180) end
      table.insert(options, { name = clip(label, 120), description = description, value = result })
    end

    local selected = editor.filterBox("PKS results", options, tostring(#results) .. " results · select to open", searchText)
    if not selected or type(selected.value) ~= "table" then return end
    local result = selected.value
    local page = inSpacePath(result.uri, root)
    if page then
      editor.navigate(page)
    else
      previewExternal(result)
    end
  end)

  if not ok then
    editor.flashNotification("PKS Search failed: " .. clip(err, 180), "error")
  end
end

command.define {
  name = "PKS: Search",
  run = pks.search,
}
```

## Scope

- Search and retrieval stay in PKS.
- Only paths proven to be under the current Space root are opened in SilverBullet.
- External results use PKS read-only preview; this library never writes note content.
- PKS must be reachable from the SilverBullet server at `127.0.0.1:3217`.