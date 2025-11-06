--[[
    Hide progress bar for "New" and "Finished" items in Project:Title list view,
    but KEEP the trophy icon for finished books.

    How it works:
      - Wrap ptutil.showProgressBar() to honor a one-shot flag.
      - Before listmenu builds the row, we peek at status/percent and set that flag.
      - When the flag is set, draw_progressbar is forced to false for that item only.

    Tested with current Project:Title after KOReader update.
    Author: ChatGPT (for Sébastien)
    License: GNU AGPL v3
--]]

local userpatch = require("userpatch")

local function patchCoverBrowser(_plugin)
    local ptutil = require("ptutil")
    local listmenu = require("listmenu")
    local BookInfoManager = require("bookinfomanager")

    -- Wrap ptutil.showProgressBar once
    if not ptutil._orig_showProgressBar then
        ptutil._orig_showProgressBar = ptutil.showProgressBar
        ptutil.showProgressBar = function(pages)
            local est_pages, show_bar = ptutil._orig_showProgressBar(pages)
            if ptutil._hide_progressbar_once then
                -- consume the one-shot flag
                ptutil._hide_progressbar_once = nil
                show_bar = false
            end
            return est_pages, show_bar
        end
    end

    -- Get ListMenuItem class from listmenu upvalues
    local ListMenuItem = userpatch.getUpValue(listmenu._updateItemsBuildUI, "ListMenuItem")
    if not ListMenuItem then return end

    local orig_update = ListMenuItem.update
    ListMenuItem.update = function(self)
        -- We need to decide BEFORE ptutil.showProgressBar(...) is called.
        -- Recompute the minimal info we need (no cover extraction).
        local filepath = self.entry.file or self.entry.path
        local bookinfo = BookInfoManager:getBookInfo(filepath, false) or {}
        local book_info = self.menu.getBookInfo(filepath) or {}

        local status = book_info.status
        local percent_finished = book_info.percent_finished
        local is_supported = not bookinfo._no_provider

        -- "New" in UI = no percent yet AND supported
        local is_new = (percent_finished == nil) and is_supported
        local is_finished = (status == "complete")

        if is_new or is_finished then
            -- arm one-shot flag consumed by our wrapped ptutil.showProgressBar(...)
            ptutil._hide_progressbar_once = true
        end

        return orig_update(self)
    end
end

userpatch.registerPatchPluginFunc("coverbrowser", patchCoverBrowser)
