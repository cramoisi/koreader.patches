
--[[
  Project: Title — Unified Filename Parser (v5.1)
  Handles Author, Title, Series, Index from filename using user's schema.

  Changes in 5.1:
    - Fix macOS/iOS decomposed accents (À -> À, É -> É, etc.)
    - Fix triple apostrophes (curly quotes -> single ')
    - Remove "T" or "t" prefix from numeric volume markers (T1, T2 -> index only)
--]]

local userpatch = require("userpatch")

local function trim(s) return (s and s:gsub("^%s+",""):gsub("%s+$","")) end

-- recomposition for decomposed accents (very basic map for macOS NFD)
local accent_map = {
  ["À"] = "À", ["Â"] = "Â", ["Ä"] = "Ä",
  ["É"] = "É", ["È"] = "È", ["Ê"] = "Ê", ["Ë"] = "Ë",
  ["Î"] = "Î", ["Ï"] = "Ï",
  ["Ô"] = "Ô", ["Ö"] = "Ö",
  ["Û"] = "Û", ["Ü"] = "Ü",
  ["Ç"] = "Ç",
  ["à"] = "à", ["â"] = "â", ["ä"] = "ä",
  ["é"] = "é", ["è"] = "è", ["ê"] = "ê", ["ë"] = "ë",
  ["î"] = "î", ["ï"] = "ï",
  ["ô"] = "ô", ["ö"] = "ö",
  ["û"] = "û", ["ü"] = "ü",
  ["ç"] = "ç",
}

local function recombine_accents(s)
  if not s then return s end
  for k,v in pairs(accent_map) do s = s:gsub(k,v) end
  return s
end

local function normalize(s)
  if not s or s == "" then return s end
  s = recombine_accents(s)

  -- remove zero-width, soft hyphen, BOM
  s = s
    :gsub("\226\128[\139-\141]", "") -- ZWSP/ZWNJ/ZWJ
    :gsub("\239\187\191", "") -- BOM
    :gsub("\194\173", "") -- soft hyphen

  -- normalize spaces
  s = s
    :gsub("\194\160", " ")
    :gsub("\226\128[\136-\143]", " ") -- thin, narrow, en/em space

  -- normalize dashes
  s = s
    :gsub("\226\128[\144-\148]", "-")
    :gsub("\226\136\146", "-")

  -- normalize apostrophes (curly quotes -> single ')
  s = s:gsub("[\226\128\152\226\128\153\226\128\154\226\128\155]", "'")

  -- collapse multiple spaces
  s = s:gsub(" +", " ")
  -- keep only " - " for separators (do not touch internal hyphens)
  s = s:gsub(" +%- +", " - ")

  return trim(s)
end

local function split_on_sds(name)
  local parts, rest = {}, name
  while true do
    local i, j = rest:find(" %-% ")
    if not i then break end
    table.insert(parts, trim(rest:sub(1, i-1)))
    rest = rest:sub(j+1)
  end
  table.insert(parts, trim(rest))
  return parts
end

local function strip_trailing_markers_token(s)
  -- enlève UNIQUEMENT les marqueurs complets en fin de segment
  -- tokens reconnus (insensible à la casse) : tome, vol, vol., livre, n, n°, no, nº
  if not s or s == "" then return s end
  -- normaliser les points pour la comparaison (mais on garde l’original ensuite)
  local tokens = {}
  for tok in s:gmatch("%S+") do table.insert(tokens, tok) end
  while #tokens > 0 do
    local last = tokens[#tokens]
    local norm = last:lower():gsub("%.+$", "") -- supprime les '.' finaux pour comparer (vol. => vol)
    if norm == "tome" or norm == "vol" or norm == "livre"
       or norm == "n" or norm == "n°" or norm == "no" or norm == "nº" then
      table.remove(tokens) -- on retire UNIQUEMENT le token complet
    else
      break
    end
  end
  return table.concat(tokens, " ")
end

local function parse_filename(basename)
  local name = normalize(basename or ""):gsub("%.%w+$","")
  local parts = split_on_sds(name)

  -- fallback: comma form if no " - " found
  if #parts == 1 and name:find(",") then
    local a, t = name:match("^(.-),%s*(.-)$")
    if a and t then
      return trim(a), nil, trim(t)
    end
  end

  if #parts < 2 then return nil, nil, nil, nil end

  local author = parts[1]
  local title = parts[#parts]
  local middle = (#parts >= 3) and table.concat(parts, " - ", 2, #parts-1) or nil

  local series, idx = nil, nil
  if middle and middle ~= "" then
    local raw = middle
    -- allow T1/T2 as numeric markers as well
    raw = raw:gsub("([Tt])(%d+)%s*$", "%2")
    local n = tonumber(raw:match("(%d+)%s*$"))
--    if n then
--      local sname = ci_cleanup_markers(raw)
--      sname = trim(sname or "")
--      if sname ~= "" and not sname:lower():match("^[%s%p]*(tome|vol%.?|livre|n[%.°oº]?)%s*$") then
--        series, idx = sname, n
--      end
	if n then
	  -- new: extract prefix before the numeric index to avoid truncating final words
	  local prefix = raw:match("^(.-)[%s#]*%d+%s*$") or raw
	  local sname = strip_trailing_markers_token(prefix)
	  sname = trim(sname or "")
	  if sname ~= "" and not sname:lower():match("^[%s%p]*(tome|vol%.?|livre|n[%.°oº]?)%s*$") then
		series, idx = sname, n
	  end
    else
      if not raw:lower():match("^[%s%p]*(tome|vol%.?|livre|n[%.°oº]?)%s*$") then
		series = strip_trailing_markers_token(trim(raw))
      end
    end
  end

  return trim(author), series, trim(title), idx
end

local function leaf(path)
  return tostring(path or ""):gsub("[/\\]+$",""):match("([^/\\]+)$") or tostring(path or "")
end

local function base_noext(filename)
  return tostring(filename or ""):gsub("%.%w+$","")
end

local function patchCoverBrowser(_plugin)
  local listmenu = require("listmenu")
  local ListMenuItem = userpatch.getUpValue(listmenu._updateItemsBuildUI, "ListMenuItem")
  if not ListMenuItem then return end

  local BookInfoManager = require("bookinfomanager")
  local util = require("util")
  local filemanagerutil = require("apps/filemanager/filemanagerutil")
  local orig_ListMenuItem_update = ListMenuItem.update

  ListMenuItem.update = function(self)
    if self.do_filename_only or not self or type(self.filepath) ~= "string" or self.filepath == "" or self.is_directory then
      return orig_ListMenuItem_update(self)
    end

    local wanted_leaf = leaf(self.filepath)
    local wanted_base = base_noext(wanted_leaf)

    local orig_get = BookInfoManager.getBookInfo
    local restored = false
    local function restore() if not restored then BookInfoManager.getBookInfo = orig_get; restored = true end end

    BookInfoManager.getBookInfo = function(bim, path, want_cover)
      local req_path = path
      if type(req_path) == "table" and req_path.path then req_path = req_path.path end
      local bi = orig_get(bim, path, want_cover)
      if type(bi) ~= "table" then return bi end

      local req_leaf = leaf(req_path)
      if base_noext(req_leaf) == wanted_base then
        local _, filename = util.splitFilePathName(req_path or "")
        local basename = filemanagerutil.splitFileNameType(filename)
        if type(basename) == "table" then basename = basename[1] end
        local author, series, title, sidx = parse_filename(basename or "")
        if author and author ~= "" and title and title ~= "" then
          bi.title   = title
          bi.authors = author
          bi.ignore_meta = false
        end
        if series and series ~= "" then
          bi.series = series
          bi.series_index = sidx or 0
          bi.ignore_meta = false
        end
      end
      return bi
    end

    local ok, err = xpcall(function() orig_ListMenuItem_update(self) end, debug.traceback)
    restore()
    if not ok then error(err, 0) end
  end
end

userpatch.registerPatchPluginFunc("coverbrowser", patchCoverBrowser)
