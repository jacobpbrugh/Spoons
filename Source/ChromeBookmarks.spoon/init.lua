--- === ChromeBookmarks ===
---
--- Search Google Chrome bookmarks via Seal
---
--- Download: [https://github.com/Hammerspoon/Spoons/raw/master/Spoons/ChromeBookmarks.spoon.zip](https://github.com/Hammerspoon/Spoons/raw/master/Spoons/ChromeBookmarks.spoon.zip)
---
--- This Spoon provides a Seal plugin to search and open Google Chrome bookmarks.
--- It automatically indexes bookmarks from all Chrome profiles and provides fast fuzzy searching.
---
--- Example usage:
--- ```
--- hs.loadSpoon("Seal")
--- spoon.Seal:start()
--- hs.loadSpoon("ChromeBookmarks")
--- spoon.ChromeBookmarks.profiles = "auto"           -- or { "Default", "Profile 1" }
--- spoon.ChromeBookmarks.keyword = "cb"              -- type: "cb <query>"
--- spoon.ChromeBookmarks.openBehavior = "chrome"     -- "chrome" or "default"
--- spoon.ChromeBookmarks.maxResults = 200
--- spoon.ChromeBookmarks:bindToSeal(spoon.Seal)
--- ```

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "ChromeBookmarks"
obj.version = "0.1.0"
obj.author = "Jacob Brugh"
obj.homepage = "https://github.com/Hammerspoon/Spoons"
obj.license = "MIT - https://opensource.org/licenses/MIT"

--- ChromeBookmarks.keyword
--- Variable
--- The keyword to trigger Chrome bookmarks search in Seal. Default: "cb"
obj.keyword = "cb"

--- ChromeBookmarks.profiles
--- Variable
--- Which Chrome profiles to index. Can be "auto" to auto-detect all profiles, or a table like { "Default", "Profile 1" }. Default: "auto"
obj.profiles = "auto"

--- ChromeBookmarks.maxResults
--- Variable
--- Maximum number of search results to display. Default: 200
obj.maxResults = 200

--- ChromeBookmarks.openBehavior
--- Variable
--- How to open bookmarks. "chrome" opens in Chrome, "default" uses system default browser. Default: "chrome"
obj.openBehavior = "chrome"

--- ChromeBookmarks.logLevel
--- Variable
--- Logger verbosity level. Can be 'nothing', 'error', 'warning', 'info', 'debug', or 'verbose'. Default: nil (uses plugin default)
obj.logLevel = nil

-- Helper to get the absolute path of this spoon, for loading the plugin file.
local function scriptPath()
  local str = debug.getinfo(1, "S").source:sub(2)
  return str:match("(.*/)") or ""
end
obj.spoonPath = scriptPath()

--- ChromeBookmarks:bindToSeal(seal)
--- Method
--- Binds the Chrome bookmarks plugin to a running Seal instance
---
--- Parameters:
---  * seal - A running Seal spoon instance (e.g., spoon.Seal)
---
--- Returns:
---  * The ChromeBookmarks object for method chaining
---
--- Notes:
---  * This method loads the Chrome bookmarks plugin into Seal and configures it with the current settings
---  * You must call this after configuring the Spoon's variables (keyword, profiles, etc.)
---  * The plugin will automatically start indexing bookmarks when Seal starts
function obj:bindToSeal(seal)
  if not seal then
    hs.alert.show("ChromeBookmarks: Seal instance not provided")
    return self
  end

  local pluginFile = self.spoonPath .. "seal_chrome_bookmarks.lua"
  if hs.fs.attributes(pluginFile) == nil then
    hs.alert.show("ChromeBookmarks: plugin file not found at " .. pluginFile)
    return self
  end

  -- Load plugin from our file path
  local ok = seal:loadPluginFromFile("chrome_bookmarks", pluginFile)
  if not ok then
    hs.alert.show("ChromeBookmarks: failed to load plugin into Seal")
    return self
  end

  -- Pass configuration into the plugin (mirrors Safari plugin pattern of setting vars on module table)
  local p = seal.plugins.chrome_bookmarks
  if p then
    p.keyword = self.keyword or p.keyword
    p.maxResults = self.maxResults or p.maxResults
    p.openBehavior = self.openBehavior or p.openBehavior
    p.profiles = self.profiles or p.profiles

    if p.logger and self.logLevel then
      p.logger:setLogLevel(self.logLevel)
    end
  end

  -- Let Seal re-register commands in case keyword changed
  if seal.refreshCommandsForPlugin then
    seal:refreshCommandsForPlugin("chrome_bookmarks")
  elseif seal.refreshAllCommands then
    seal:refreshAllCommands()
  end

  return self
end

return obj
