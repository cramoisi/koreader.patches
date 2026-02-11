-- Title sort for KOReader File Manager (series-aware)
-- Place this file in: .koreader/patches/
--
-- Adds one "Sort by" key:
--   title (series-aware)
--
-- Behavior:
--   - Sort key is normally the title.
--   - If a book has a series, its sort key becomes: series name (A->Z),
--     and within that series, items keep the classic order (series index, then title).
--   - Items without a series are sorted by title.
--
-- Net effect: it behaves like "Sort by title", except series books are grouped and
-- ordered as series + index.

local BookList = require("ui/widget/booklist")
local ffiUtil = require("ffi/util")
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

local function hasSeries(props)
    if not props or not props.series then
        return false
    end

    -- considère comme "pas de série" :
    -- nil, FFFF, vide ou uniquement espaces
    if props.series == FFFF then
        return false
    end

    if tostring(props.series):match("^%s*$") then
        return false
    end

    return true
end


BookList.collates.title_series_aware = {
    text = _("title (series-aware)"),
    menu_order = 8,
    can_collate_mixed = false,

    item_func = function(item, ui)
        prepareItem(item, ui)
    end,

    init_sort_func = function(cache)
        local my_cache = cache or {}
        return function(a, b)
            local a_has = hasSeries(a.doc_props)
            local b_has = hasSeries(b.doc_props)

            -- Primary key: series name if present, else title.
            local ka = a_has and a.doc_props.series or a.doc_props.display_title
            local kb = b_has and b.doc_props.series or b.doc_props.display_title

            if ka ~= kb then
                return ffiUtil.strcoll(ka, kb)
            end

            -- If both are in the same series, keep classic series ordering.
            if a_has and b_has and a.doc_props.series == b.doc_props.series then
                if a.doc_props.series_index and b.doc_props.series_index and
                   a.doc_props.series_index ~= b.doc_props.series_index then
                    return a.doc_props.series_index < b.doc_props.series_index
                end
                return ffiUtil.strcoll(a.doc_props.display_title, b.doc_props.display_title)
            end

            -- Otherwise (same title key), fall back to title then path to stabilize.
            local ta = a.doc_props.display_title or a.text or ""
            local tb = b.doc_props.display_title or b.text or ""
            if ta ~= tb then
                return ffiUtil.strcoll(ta, tb)
            end

            local pa = a.path or a.file or ""
            local pb = b.path or b.file or ""
            return ffiUtil.strcoll(pa, pb)
        end, my_cache
    end,

    mandatory_func = function(item)
        if not item.doc_props then return "" end
        if hasSeries(item.doc_props) then
            if item.doc_props.series_index then
                return item.doc_props.series .. " #" .. item.doc_props.series_index
            end
            return item.doc_props.series
        end
        return ""
    end,
}

return BookList.collates
