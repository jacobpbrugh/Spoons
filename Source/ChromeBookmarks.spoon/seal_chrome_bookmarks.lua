-- seal_chrome_bookmarks.lua
-- A Seal plugin that indexes and searches Google Chrome bookmarks.
-- Saved as "seal_chrome_bookmarks.lua". Loaded via Seal:loadPluginFromFile("chrome_bookmarks", <path>).
-- Invoked with the keyword set in `keyword` (default "cb").

local obj = {}
obj.__index = obj

-- Metadata mostly for logging
obj.__name = "chrome_bookmarks"

-- Configurable fields (can be overridden after loading via spoon.Seal.plugins.chrome_bookmarks.*)
obj.keyword = "cb"              -- command prefix inside Seal
obj.maxResults = 200
obj.openBehavior = "chrome"     -- "chrome" or "default"
obj.profiles = "auto"           -- "auto" or table like { "Default", "Profile 1" }

-- Internals
obj.logger = hs.logger.new("SealChromeBM", "info")
obj._icon = hs.image.imageFromAppBundle("com.google.Chrome") or hs.image.imageFromName(hs.image.systemImageNames.Network)

obj._chromeUserDir = os.getenv("HOME") .. "/Library/Application Support/Google/Chrome"
obj._index = {}       -- flat list of entries
obj._watchers = {}    -- pathwatchers per profile bookmarks file

-- Entry shape:
-- { title=string, url=string, path=string, host=string, profile=string }

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

local function starts_with(s, prefix)
  return s:sub(1, #prefix) == prefix
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

local function clamp(n, lo, hi)
  if n < lo then return lo end
  if n > hi then return hi end
  return n
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

-- auto-detect profiles present in the Chrome user dir
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
-- Search
---------------------------------------------------------------------

-- Score a bookmark entry against query tokens
local function score_entry(e, tokens)
  local title = normalize(e.title)
  local url = normalize(e.url)
  local host = normalize(e.host)
  local path = normalize(e.path)

  local score = 0

  -- strong boosts
  for _, tok in ipairs(tokens) do
    local t = normalize(tok)
    if #t == 0 then goto continue end
    if title:find(t, 1, true) then score = score + 100 end
    if host:find(t, 1, true) then score = score + 80 end
    if url:find(t, 1, true) then score = score + 60 end
    if path:find(t, 1, true) then score = score + 20 end
    ::continue::
  end

  -- exact domain equals token bonus
  for _, tok in ipairs(tokens) do
    if host == tok then score = score + 50 end
  end

  return score
end

local function build_choice(e, score, icon)
  local sub = e.host
  if e.path and e.path ~= "" then
    sub = sub .. "  —  " .. e.path
  end
  sub = sub .. "  (" .. e.profile .. ")"
  return {
    text = e.title,
    subText = sub,
    image = icon,
    url = e.url,
    _score = score,
  }
end

-- Main entrypoint used by Seal when query changes.
-- Seal calls all loaded plugins, but in practice we only react to our keyword prefix to avoid noise.
function obj:choicesForQuery(query)
  query = query or ""
  local q = normalize(query)

  -- Respect keyword
  local kw = normalize(self.keyword or "cb") .. " "
  local usingKeyword = false
  if starts_with(q, kw) then
    q = q:sub(#kw + 1)
    usingKeyword = true
  elseif q == normalize(self.keyword or "cb") then
    -- Just "cb" with no trailing space => show hint
    usingKeyword = true
    q = ""
  end

  if not usingKeyword then
    return {}
  end

  -- No query => show a few recent/frequent picks (we don't track MRU here, so show top alphabetically by title)
  local tokens = split_words(q)
  local choices = {}

  if #tokens == 0 then
    -- Show first N alphabetically
    local tmp = {}
    for _, e in ipairs(self._index) do
      table.insert(tmp, e)
    end
    table.sort(tmp, function(a,b) return a.title:lower() < b.title:lower() end)
    local n = 0
    for _, e in ipairs(tmp) do
      choices[#choices+1] = build_choice(e, 0, self._icon)
      n = n + 1
      if n >= clamp(self.maxResults or 200, 1, 5000) then break end
    end
    return choices
  end

  -- Filter and rank
  local MAX = clamp(self.maxResults or 200, 1, 5000)
  for _, e in ipairs(self._index) do
    local s = score_entry(e, tokens)
    if s > 0 then
      choices[#choices+1] = build_choice(e, s, self._icon)
    end
  end
  table.sort(choices, function(a,b) return a._score > b._score end)

  -- Trim
  if #choices > MAX then
    local trimmed = {}
    for i=1,MAX do trimmed[i] = choices[i] end
    choices = trimmed
  end

  return choices
end

-- Called by Seal when the user selects an entry.
function obj:completionCallback(choice)
  if not choice or not choice.url then return end
  local url = choice.url

  if (self.openBehavior or "chrome") == "chrome" then
    -- open in Google Chrome via AppleScript so it reuses existing window
    -- Properly escape URL for AppleScript string (backslashes and quotes)
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
      self.logger:w("AppleScript failed to open URL in Chrome: " .. tostring(err))
      hs.urlevent.openURL(url)
    end
  else
    -- default handler
    hs.urlevent.openURL(url)
  end
end

---------------------------------------------------------------------
-- Plugin lifecycle hooks expected by Seal
---------------------------------------------------------------------

function obj:start()
  self:_reindex()
  self:_watch()
end

function obj:stop()
  for _, w in ipairs(self._watchers) do pcall(function() w:stop() end) end
  self._watchers = {}
end

-- Some versions of Seal allow dynamic command lists via :commands()
-- We expose one command (self.keyword) to scope our search.
function obj:commands()
  return {
    [self.keyword or "cb"] = {
      cmd = self.keyword or "cb",
      name = "Chrome Bookmarks",
      description = "Search Google Chrome bookmarks",
    }
  }
end

return obj
