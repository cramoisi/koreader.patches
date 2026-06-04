-- Tri 
-- À placer dans : .koreader/patches/
--

local BookList = require("ui/widget/booklist")
local DocSettings = require("docsettings")
local ffiUtil = require("ffi/util")
local sort = require("sort")
local util = require("util")
local _ = require("gettext")

local function readStatus(path)
    local percent_finished = 0
    local status = nil
    local been_opened = false

    if DocSettings:hasSidecarFile(path) then
        local ds = DocSettings:open(path)
        local summary = ds:readSetting("summary")
        status = summary and summary.status
        percent_finished = ds:readSetting("percent_finished") or 0
        been_opened = percent_finished > 0 or status ~= nil
    end

    return percent_finished, status, been_opened
end

BookList.collates.percent_natural = {
    text = _("My Sorting mode"),
    menu_order = 10,
    can_collate_mixed = false,

    item_func = function(item, ui)
        local path = item.path or item.file
        local pct, status, opened = readStatus(path)

        local sort_percent
        if opened then
            if status == "complete" then -- finished
                sort_percent = 2.0
            elseif status == "abandoned" then -- onhold / dnf
				sort_percent = 1.9
            end
        else
            sort_percent = 1.0 -- not opened yet
        end

        item.been_opened = opened
        item.percent_finished = pct
        item.sort_percent = sort_percent or util.round_decimal(pct or -1, 2)
    end,

	init_sort_func = function(cache)
		local natsort
		natsort, cache = sort.natsort_cmp(cache)
		return function(a, b)
			if a.sort_percent ~= b.sort_percent then
				return a.sort_percent < b.sort_percent
			end
			return natsort(a.text, b.text)
		end, cache
	end,


    mandatory_func = function(item)
        if item.been_opened then
            return string.format("%d\u{202F}%%", 100 * item.percent_finished)
        end
        return "–"
    end,
}

return BookList.collates
