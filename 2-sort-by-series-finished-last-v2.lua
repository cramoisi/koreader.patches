-- Series sort for KOReader File Manager (Kobo)
-- Place this file in: .koreader/patches/
--
-- Adds one "Sort by" key:
--   series - finished last
--
-- Behavior:
--   - Items with a series are sorted by series name (A->Z)
--   - Items without a series are pushed to the end
--   - Within each series: finished books (100%) are pushed to the end
--   - Other items keep natural order: series index, then title

local BookList = require("ui/widget/booklist")
local ffiUtil = require("ffi/util")
local DocSettings = require("docsettings")
local _ = require("gettext")

local FFFF = "\u{FFFF}"

local function prepareItem(item, ui)
    if not ui or not ui.bookinfo then
        item.doc_props = {
            series = FFFF,
            series_index = nil,
            display_title = item.text,
        }
        return
    end

    local doc_props = ui.bookinfo:getDocProps(item.path or item.file)
    doc_props.series = doc_props.series or FFFF
    doc_props.display_title = doc_props.display_title or item.text
    item.doc_props = doc_props
end

-- Kobo: reading progress from docsettings.
-- Returns 0..1, or nil if never opened / unknown.
local function getPercentFinished(item)
    local path = item.path or item.file
    if not path then return nil end

    local ok, ds = pcall(function()
        return DocSettings:open(path)
    end)
    if not ok or not ds then return nil end

    local pf = ds:readSetting("percent_finished")
    if type(pf) ~= "number" then
        return nil
    end

    -- normalize if stored as 0..100
    if pf > 1 then pf = pf / 100 end
    if pf < 0 then pf = 0 end
    if pf > 1 then pf = 1 end
    return pf
end

-- Returns true if KOReader considers the book finished.
-- We check both percent_finished and the summary.status field, because depending on
-- document type and closing workflow, percent_finished may not be exactly 1.0.
local function isFinished(ds, pf)
    if type(pf) == "number" and pf >= 0.999 then
        return true
    end
    if ds and ds.readSetting then
        local summary = ds:readSetting("summary")
        if type(summary) == "table" then
            local st = summary.status
            if st == "complete" or st == "finished" then
                return true
            end
        end
        -- Some setups store a plain status key.
        local st2 = ds:readSetting("status")
        if st2 == "complete" or st2 == "finished" then
            return true
        end
    end
    return false
end

local function seriesKey(series)
    -- Put "no series" items at the end
    if not series or series == FFFF then
        return FFFF
    end
    return series
end

local function finishedRank(finished)
    -- finished last
    return finished and 1 or 0
end

BookList.collates.series_finished_last = {
    text = _("series - finished last"),
    menu_order = 7,
    can_collate_mixed = false,

    item_func = function(item, ui)
        prepareItem(item, ui)
        -- Open docsettings once so we can check both percent and status.
        local path = item.path or item.file
        local ds
        if path then
            local ok, opened = pcall(function() return DocSettings:open(path) end)
            if ok then ds = opened end
        end

        local pf
        if ds and ds.readSetting then
            pf = ds:readSetting("percent_finished")
            if type(pf) == "number" then
                if pf > 1 then pf = pf / 100 end
                if pf < 0 then pf = 0 end
                if pf > 1 then pf = 1 end
            else
                pf = nil
            end
        else
            pf = nil
        end

        item._pf = pf
        item._finished = isFinished(ds, pf)
        item._finished_rank = finishedRank(item._finished)
    end,

    init_sort_func = function(cache)
        local my_cache = cache or {}
        return function(a, b)
            local sa = seriesKey(a.doc_props.series)
            local sb = seriesKey(b.doc_props.series)
            if sa ~= sb then
                return ffiUtil.strcoll(sa, sb)
            end

            if a._finished_rank ~= b._finished_rank then
                return a._finished_rank < b._finished_rank
            end

            if a.doc_props.series_index and b.doc_props.series_index and sa ~= FFFF then
                if a.doc_props.series_index ~= b.doc_props.series_index then
                    return a.doc_props.series_index < b.doc_props.series_index
                end
            end

            return ffiUtil.strcoll(a.doc_props.display_title, b.doc_props.display_title)
        end, my_cache
    end,

    mandatory_func = function(item)
        if not item.doc_props then return "" end
        if item.doc_props.series and item.doc_props.series ~= FFFF then
            if item.doc_props.series_index then
                return item.doc_props.series .. " #" .. item.doc_props.series_index
            end
            return item.doc_props.series
        end
        return ""
    end,
}

return BookList.collates
