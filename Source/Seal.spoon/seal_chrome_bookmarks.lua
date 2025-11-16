--- === Seal.plugins.chrome_bookmarks ===
--- Search and open Google Chrome bookmarks from Seal
---
--- Automatically indexes bookmarks from all Chrome profiles and provides fast searching.
--- Bookmarks appear in the default Seal results - no keyword required.

local obj = {}
obj.__index = obj
obj.__name = "seal_chrome_bookmarks"

--- Seal.plugins.chrome_bookmarks.profiles
--- Variable
--- Which Chrome profiles to index. Can be "auto" to auto-detect all profiles, or a table like { "Default", "Profile 1" }. Default: "auto"
obj.profiles = "auto"

--- Seal.plugins.chrome_bookmarks.always_open_with_chrome
--- Variable
--- If `true` (default), bookmarks are always opened with Chrome. If `false`, they are opened with the default browser.
obj.always_open_with_chrome = true

-- Internals
obj.logger = hs.logger.new("seal_chrome_bookmarks", "info")
obj.icon = hs.image.imageFromAppBundle("com.google.Chrome") or hs.image.imageFromName(hs.image.systemImageNames.Network)
obj._chromeUserDir = os.getenv("HOME") .. "/Library/Application Support/Google/Chrome"
obj._index = {}       -- flat list of bookmark entries
obj._watchers = {}    -- pathwatchers per profile bookmarks file

-- Entry shape: { title=string, url=string, path=string, host=string, profile=string }

---------------------------------------------------------------------
-- Utilities
---------------------------------------------------------------------

local function file_exists(p)
  return hs.fs.attributes(p) ~= nil
end

local function read_file(p)
  local f = io.open(p, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function normalize(s)
  return (s or ""):lower()
end

local function split_words(s)
  local t = {}
  for w in s:gmatch("%S+") do t[#t+1] = w end
  return t
end

local function domain_from_url(u)
  local host = u:match("^%a+://([^/]+)")
  if not host then
    host = u:match("^([^/]+)/") or ""
  end
  return host or ""
end

---------------------------------------------------------------------
-- Bookmark parsing (Chrome JSON)
---------------------------------------------------------------------

local function add_entry(list, title, url, folderPath, profile)
  if not url or url == "" then return end
  list[#list+1] = {
    title = title or url,
    url = url,
    path = folderPath or "",
    host = domain_from_url(url),
    profile = profile or "Default",
  }
end

local function walk_children(list, node, folderPath, profile)
  if not node then return end
  if node.type == "url" then
    add_entry(list, node.name, node.url, folderPath, profile)
  elseif node.type == "folder" and node.children then
    local newPath = folderPath and (folderPath .. "/" .. (node.name or "")) or (node.name or "")
    for _, child in ipairs(node.children) do
      walk_children(list, child, newPath, profile)
    end
  end
end

local function parse_bookmarks_file(path, profile, acc)
  local content = read_file(path)
  if not content then return end
  local ok, data = pcall(hs.json.decode, content)
  if not ok or not data then return end
  local roots = data.roots or {}
  for _, rootName in ipairs({ "bookmark_bar", "other", "synced" }) do
    local root = roots[rootName]
    if root and root.children then
      for _, child in ipairs(root.children) do
        walk_children(acc, child, rootName, profile)
      end
    end
  end
end

-- Auto-detect profiles present in the Chrome user dir
local function detect_profiles(chromeUserDir)
  local profiles = {}
  -- Check if Chrome directory exists
  if not file_exists(chromeUserDir) then
    return profiles
  end
  -- Default plus numbered profiles whose dirs contain "Bookmarks"
  if file_exists(chromeUserDir .. "/Default/Bookmarks") then
    table.insert(profiles, "Default")
  end
  -- Iterate subdirs
  local ok, iter, dirObj = pcall(hs.fs.dir, chromeUserDir)
  if not ok or not iter then
    return profiles
  end
  for name in iter, dirObj do
    if name and name ~= "." and name ~= ".." and name:match("^Profile %d+$") then
      if file_exists(chromeUserDir .. "/" .. name .. "/Bookmarks") then
        table.insert(profiles, name)
      end
    end
  end
  return profiles
end

function obj:_getProfiles()
  -- Determine which profiles to use based on configuration
  if self.profiles == "auto" or (type(self.profiles) == "string" and self.profiles:lower() == "auto") then
    return detect_profiles(self._chromeUserDir)
  elseif type(self.profiles) == "table" then
    return self.profiles
  else
    return { "Default" }
  end
end

function obj:_reindex()
  local t0 = hs.timer.secondsSinceEpoch()
  local list = {}
  local useProfiles = self:_getProfiles()

  for _, p in ipairs(useProfiles) do
    local f = self._chromeUserDir .. "/" .. p .. "/Bookmarks"
    if file_exists(f) then
      parse_bookmarks_file(f, p, list)
    end
  end

  self._index = list
  self.logger:i(string.format("Indexed %d Chrome bookmarks in %.0f ms", #list, (hs.timer.secondsSinceEpoch()-t0)*1000))
end

function obj:_watch()
  -- Stop existing watchers
  for _, w in ipairs(self._watchers) do pcall(function() w:stop() end) end
  self._watchers = {}

  local useProfiles = self:_getProfiles()

  for _, p in ipairs(useProfiles) do
    local f = self._chromeUserDir .. "/" .. p .. "/Bookmarks"
    if file_exists(f) then
      local watcher = hs.pathwatcher.new(f, function() self:_reindex() end)
      watcher:start()
      table.insert(self._watchers, watcher)
    end
  end
end

---------------------------------------------------------------------
-- Search and scoring
---------------------------------------------------------------------

-- Score a bookmark entry against query tokens
local function score_entry(e, tokens)
  local title = normalize(e.title)
  local url = normalize(e.url)
  local host = normalize(e.host)
  local path = normalize(e.path)

  local score = 0

  -- Strong boosts for matches
  for _, tok in ipairs(tokens) do
    local t = normalize(tok)
    if #t == 0 then goto continue end
    if title:find(t, 1, true) then score = score + 100 end
    if host:find(t, 1, true) then score = score + 80 end
    if url:find(t, 1, true) then score = score + 60 end
    if path:find(t, 1, true) then score = score + 20 end
    ::continue::
  end

  -- Exact domain match bonus
  for _, tok in ipairs(tokens) do
    if normalize(tok) == host then score = score + 50 end
  end

  return score
end

---------------------------------------------------------------------
-- Seal plugin API
---------------------------------------------------------------------

function obj:commands()
  -- No commands - we use bare() for default search
  return {}
end

function obj:bare()
  -- Return the function that handles bare queries (no command prefix)
  return self.choicesBookmarks
end

function obj.choicesBookmarks(query)
  if not query or query == "" then
    return {}
  end

  local tokens = split_words(query)
  if #tokens == 0 then
    return {}
  end

  local choices = {}

  -- Filter and rank bookmarks
  for _, e in ipairs(obj._index) do
    local s = score_entry(e, tokens)
    if s > 0 then
      local subText = e.host
      if e.path and e.path ~= "" then
        subText = subText .. "  —  " .. e.path
      end
      if e.profile and e.profile ~= "Default" then
        subText = subText .. "  (" .. e.profile .. ")"
      end

      local uuid = obj.__name .. "__" .. e.url
      local choice = {
        text = e.title,
        subText = subText,
        url = e.url,
        image = obj.icon,
        uuid = uuid,
        plugin = obj.__name,
        type = "openURL",
        _score = s,
      }
      table.insert(choices, choice)
    end
  end

  -- Apply frecency boost BEFORE sorting and limiting
  -- Access Seal's frecency data if available
  if obj.seal and obj.seal.frecency_enable and obj.seal.frecency_data then
    for _, choice in ipairs(choices) do
      local frecency_data = obj.seal.frecency_data[choice.uuid]
      if frecency_data and frecency_data.last_used then
        -- Huge boost for recently used items (10000 points per recent use)
        -- This ensures recently used bookmarks appear first regardless of match score
        local recency_boost = frecency_data.last_used > 0 and 10000 or 0
        choice._score = choice._score + recency_boost
      end
    end
  end

  -- Sort by score (highest first) - now includes frecency boost
  table.sort(choices, function(a, b) return a._score > b._score end)

  -- Limit results to avoid overwhelming the UI
  local maxResults = 50
  if #choices > maxResults then
    local trimmed = {}
    for i = 1, maxResults do
      trimmed[i] = choices[i]
    end
    choices = trimmed
  end

  return choices
end

function obj.completionCallback(rowInfo)
  if rowInfo["type"] == "openURL" then
    local url = rowInfo["url"]

    if obj.always_open_with_chrome then
      -- Open in Chrome via AppleScript to reuse existing window
      local escapedURL = url:gsub("\\", "\\\\"):gsub('"', '\\"')
      local script = string.format([[
        tell application id "com.google.Chrome"
          if (count of windows) is 0 then make new window
          tell front window to make new tab with properties {URL:"%s"}
          activate
        end tell
      ]], escapedURL)
      local ok, err = hs.osascript.applescript(script)
      if not ok then
        -- Fallback to default handler
        obj.logger:w("AppleScript failed to open URL in Chrome: " .. tostring(err))
        hs.urlevent.openURL(url)
      end
    else
      -- Use default browser
      hs.urlevent.openURL(url)
    end
  end
end

---------------------------------------------------------------------
-- Initialize on load (Seal doesn't call start() on plugins)
---------------------------------------------------------------------

-- Index bookmarks immediately when plugin is loaded
obj:_reindex()
obj:_watch()

return obj
