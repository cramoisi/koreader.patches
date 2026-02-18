-- 2-fmcollection-persistent-coll-filters.lua
-- KOReader v2025.10 (full logic, minimal logs)

local logger = require("logger")
local util = require("util")

local function _req(path)
    local ok, m = pcall(require, path)
    if ok and m then return m end
    return nil
end

local ReadCollection = _req("readcollection") or _req("frontend/readcollection")
local FMC1 = _req("apps/filemanager/filemanagercollection")
local FMC2 = _req("frontend/apps/filemanager/filemanagercollection")

local function _deepcopy(t) return t and util.tableDeepCopy(t) or nil end
local function _get_coll(self, fallback)
    return (self and self.booklist_menu and self.booklist_menu.path) or fallback
end
local function _is_cleared(mt)
    return mt == nil or (type(mt) == "table" and next(mt) == nil)
end

-- Session: nil unknown / false cleared / table filter
local _session_filters = {}

local function _persist_disk(coll, match_table)
    if not ReadCollection then return end
    if not coll or coll == "" then return end
    if type(ReadCollection.coll_settings) ~= "table" then return end
    ReadCollection.coll_settings[coll] = ReadCollection.coll_settings[coll] or {}
    ReadCollection.coll_settings[coll].view_filter = match_table and _deepcopy(match_table) or nil
    ReadCollection:write({ [coll] = true })
end

local function _restore_from_any(self, coll)
    if not coll or coll == "" then return end

    local sess = _session_filters[coll]
    if sess == false then
        self.match_table = nil
        return
    elseif type(sess) == "table" then
        self.match_table = _deepcopy(sess)
        return
    end

    if ReadCollection and ReadCollection.coll_settings then
        local cs = ReadCollection.coll_settings[coll]
        if cs and cs.view_filter then
            self.match_table = _deepcopy(cs.view_filter)
            return
        end
    end

    self.match_table = nil
end

local function _sync_session_from_current(self, coll)
    if not coll or coll == "" then return end
    if _is_cleared(self.match_table) then
        _session_filters[coll] = false
    else
        _session_filters[coll] = _deepcopy(self.match_table)
    end
end

-- Hook util.tableSetValue: persist match_table changes (when they go through it)
do
    local _orig = util.tableSetValue
    util.tableSetValue = function(tbl, value, ...)
        local args = { ... }
        local is_match = false
        for i = 1, #args do
            if args[i] == "match_table" then is_match = true break end
        end

        local ret = _orig(tbl, value, ...)

        if is_match and type(tbl) == "table" then
            local coll = _get_coll(tbl)
            if coll then
                if _is_cleared(tbl.match_table) then
                    _session_filters[coll] = false
                    _persist_disk(coll, nil)
                else
                    _session_filters[coll] = _deepcopy(tbl.match_table)
                    _persist_disk(coll, tbl.match_table)
                end
            end
        end

        return ret
    end
end

local function _patch_onShowColl(mod)
    if type(mod) ~= "table" or type(mod.onShowColl) ~= "function" then return false end
    if mod._pv_patched then return true end
    mod._pv_patched = true

    local _orig_onShow = mod.onShowColl
    mod.onShowColl = function(self, collection_name, ...)
        local ret = _orig_onShow(self, collection_name, ...)

        local coll = _get_coll(self, collection_name) or collection_name
        if coll and coll ~= "" then
            _restore_from_any(self, coll)

            if type(self.updateItemTable) == "function" then
                pcall(function() self:updateItemTable() end)
            end

            _sync_session_from_current(self, coll)

            if _session_filters[coll] == false then
                _persist_disk(coll, nil)
            end

            if self.booklist_menu
                and type(self.booklist_menu.close_callback) == "function"
                and not self._pv_close_hooked then

                self._pv_close_hooked = true
                local orig_close = self.booklist_menu.close_callback

                self.booklist_menu.close_callback = function(...)
                    local c = _get_coll(self, coll) or coll

                    -- pre-close capture
                    if c and c ~= "" then
                        if _is_cleared(self.match_table) then
                            _session_filters[c] = false
                        else
                            _session_filters[c] = _deepcopy(self.match_table)
                        end
                    end

                    local ok, res = pcall(orig_close, ...)

                    -- post-close persist
                    if c and c ~= "" then
                        local sess = _session_filters[c]
                        if sess == false then
                            _persist_disk(c, nil)
                        elseif type(sess) == "table" then
                            _persist_disk(c, sess)
                        end
                    end

                    if ok then return res end
                    error(res)
                end
            end
        end

        return ret
    end

    return true
end

local ok1 = FMC1 and _patch_onShowColl(FMC1) or false
local ok2 = FMC2 and _patch_onShowColl(FMC2) or false

if ok1 or ok2 then
    logger.warn("PVCOLL: loaded")
else
    logger.warn("PVCOLL: failed to patch (module not found?)")
end
