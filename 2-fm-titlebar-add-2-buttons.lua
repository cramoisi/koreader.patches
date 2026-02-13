-- FileManager TitleBar: add Favorites (left) + History (right)

local FileManager = require("apps/filemanager/filemanager")
local ok_disp, Dispatcher = pcall(require, "dispatcher")

local orig_setupLayout = FileManager.setupLayout

local function legacy_button_from_titlebar(tb, side, ratio_fallback)
    return {
        icon = tb[side .. "_icon"],
        size_ratio = tb[side .. "_icon_size_ratio"] or ratio_fallback or 0.6,
        rotation_angle = tb[side .. "_icon_rotation_angle"] or 0,
        allow_flash = tb[side .. "_icon_allow_flash"],
        tap = tb[side .. "_icon_tap_callback"],
        hold = tb[side .. "_icon_hold_callback"],
    }
end

local function dispatch(action)
    if ok_disp and Dispatcher and Dispatcher.execute then
        pcall(function()
            Dispatcher:execute({ action })
        end)
    end
end

function FileManager:setupLayout(...)
    orig_setupLayout(self, ...)

    local tb = self.title_bar
    if not tb then return end

    local left_ratio  = tb.left_icon_size_ratio or 0.6
    local right_ratio = tb.right_icon_size_ratio or 0.6

    local legacy_left  = legacy_button_from_titlebar(tb, "left", left_ratio)
    local legacy_right = legacy_button_from_titlebar(tb, "right", right_ratio)

    -- ---- Actions ----

    local function show_favorites()
        dispatch("favorites")
    end

    local function show_shortcuts()
        if FileManager.instance
           and FileManager.instance.folder_shortcuts then
            FileManager.instance.folder_shortcuts:onShowFolderShortcutsDialog()
        end
    end

    local function open_last_document()
        if FileManager.instance
           and FileManager.instance.menu then
            FileManager.instance.menu:onOpenLastDoc()
        end
    end

    local function show_history()
        if FileManager.instance
           and FileManager.instance.history then
            FileManager.instance.history:onShowHist()
        end
    end

    -- ---- Buttons ----

    tb.left_buttons = {
        legacy_left,
        {
            icon = "favorites",
            size_ratio = left_ratio,
            tap  = show_favorites,
            hold = show_shortcuts,
        },
    }

    tb.right_buttons = {
        {
            icon = "history",
            size_ratio = right_ratio,
            tap  = open_last_document,
            hold = show_history,
        },
        legacy_right,
    }

    -- Disable legacy single-icon mode
    tb.left_icon = nil
    tb.right_icon = nil
    tb.left_icon_tap_callback = nil
    tb.right_icon_tap_callback = nil
    tb.left_icon_hold_callback = nil
    tb.right_icon_hold_callback = nil

    tb:clear()
    tb:init()
end
