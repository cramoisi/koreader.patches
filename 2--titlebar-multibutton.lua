-- userpatches/xx-titlebar-multibutton.lua
-- Adds left_buttons/right_buttons support to TitleBar while keeping full backward compatibility.

local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconButton = require("ui/widget/iconbutton")
local LineWidget = require("ui/widget/linewidget")
local Math = require("optmath")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local TitleBar = require("ui/widget/titlebar")
local Screen = Device.screen

local DGENERIC_ICON_SIZE = G_defaults:readSetting("DGENERIC_ICON_SIZE")

-- ---- helpers ---------------------------------------------------------------

local function normalize_button_def(def, fallback)
    -- `def` is a table with fields:
    -- icon, size_ratio, rotation_angle, tap, hold, allow_flash, show_parent
    -- fallback is used when building from legacy single-icon fields.
    local d = def or {}
    if fallback then
        for k, v in pairs(fallback) do
            if d[k] == nil then d[k] = v end
        end
    end
    if not d.icon then return nil end
    if d.size_ratio == nil then d.size_ratio = 0.6 end
    if d.rotation_angle == nil then d.rotation_angle = 0 end
    if d.allow_flash == nil then d.allow_flash = true end
    -- Convention: set tap/hold to false to not handle and let propagate
    if d.tap == nil then d.tap = function() end end
    if d.hold == nil then d.hold = function() end end
    return d
end

local function build_defs_from_legacy(self, side)
    -- side = "left" or "right"
    local icon = self[side .. "_icon"]
    if not icon then return nil end
    local def = normalize_button_def({
        icon = icon,
        size_ratio = self[side .. "_icon_size_ratio"],
        rotation_angle = self[side .. "_icon_rotation_angle"],
        tap = self[side .. "_icon_tap_callback"],
        hold = self[side .. "_icon_hold_callback"],
        allow_flash = self[side .. "_icon_allow_flash"],
        show_parent = self.show_parent,
    })
    return def and { def } or nil
end

local function get_button_defs(self, side)
    -- Prefer new API if provided, otherwise fallback to legacy single icon.
    local key = side .. "_buttons"
    local defs = self[key]
    if type(defs) == "table" and #defs > 0 then
        local out = {}
        for _, d in ipairs(defs) do
            local nd = normalize_button_def(d, { show_parent = self.show_parent })
            if nd then table.insert(out, nd) end
        end
        if #out > 0 then return out end
    end
    return build_defs_from_legacy(self, side)
end

local function sum_reserved_width(defs)
    -- Mirror original heuristic: reserved ≈ icon_size + button_padding
    -- (not 2*padding). Keeps layouts close to stock TitleBar.
    if not defs then return 0 end
    local total = 0
    for _, d in ipairs(defs) do
        local icon_size = Screen:scaleBySize(DGENERIC_ICON_SIZE * (d.size_ratio or 0.6))
        total = total + icon_size
    end
    return total
end

local function make_icon_button(self, def, icon_size, side, is_near_title)
    -- Match stock TitleBar's IconButton settings, but allow multiple.
    local btn = IconButton:new{
        icon = def.icon,
        icon_rotation_angle = def.rotation_angle or 0,
        width = icon_size,
        height = icon_size,
        padding = self.button_padding,
        padding_bottom = icon_size,
        overlap_align = side, -- "left" or "right"
        callback = def.tap,
        hold_callback = def.hold,
        allow_flash = def.allow_flash,
        show_parent = def.show_parent or self.show_parent,
    }

    -- Extend tap zone toward the title only for the button closest to the title
    -- (to avoid huge tap zones stacking when multiple buttons).
    if side == "left" then
        if is_near_title then btn.padding_right = 2 * icon_size end
    else
        if is_near_title then btn.padding_left = 2 * icon_size end
    end

    return btn
end

-- ---- monkeypatch init ------------------------------------------------------

local old_init = TitleBar.init

function TitleBar:init()
    -- Keep legacy close_callback behavior intact
    if self.close_callback then
        self.right_icon = "close"
        self.right_icon_tap_callback = self.close_callback
        self.right_icon_allow_flash = false
        if self.close_hold_callback then
            self.right_icon_hold_callback = function() self.close_hold_callback() end
        end
    end

    if not self.width then
        self.width = Screen:getWidth()
    end

    -- Resolve button definitions (new API or legacy single icon)
    local left_defs = get_button_defs(self, "left")
    local right_defs = get_button_defs(self, "right")

    -- No button on non-touch device (match original intent)
    self.has_left_icon = false
    self.has_right_icon = false

    local left_icon_reserved_width = 0
    local right_icon_reserved_width = 0

    if left_defs then
        self.has_left_icon = true
        left_icon_reserved_width = sum_reserved_width(left_defs) + self.button_padding
    end
    if right_defs then
        self.has_right_icon = true
        right_icon_reserved_width = sum_reserved_width(right_defs) + self.button_padding
    end

    if self.align == "center" then
        left_icon_reserved_width = math.max(left_icon_reserved_width, right_icon_reserved_width)
        right_icon_reserved_width = left_icon_reserved_width
    end

    local title_max_width = self.width - 2*self.title_h_padding - left_icon_reserved_width - right_icon_reserved_width

    local subtitle_max_width = self.width - 2*self.title_h_padding
    if not self.subtitle_fullwidth then
        subtitle_max_width = subtitle_max_width - left_icon_reserved_width - right_icon_reserved_width
    end

    -- ----- title / subtitle (copied from stock, unchanged except widths) -----
    local title_face = self.title_face
    if not title_face then
        title_face = self.fullscreen and self.title_face_fullscreen or self.title_face_not_fullscreen
    end

    if self.title_multilines then
        self.title_widget = TextBoxWidget:new{
            text = self.title,
            alignment = self.align,
            width = title_max_width,
            face = title_face,
            lang = self.lang,
        }
    else
        while true do
            self.title_widget = TextWidget:new{
                text = self.title,
                face = title_face,
                padding = 0,
                lang = self.lang,
                max_width = not self.title_shrink_font_to_fit and title_max_width,
            }
            if not self.title_shrink_font_to_fit then
                break
            end
            if self.title_widget:getWidth() <= title_max_width then
                break
            end
            if not self._initial_titlebar_height then
                self._initial_re_init_needed = true
                self.title_widget:free(true)
                self.title_widget = TextWidget:new{ text = "", face = title_face, padding = 0 }
                break
            end
            self.title_widget:free(true)
            title_face = Font:getFace(title_face.orig_font, title_face.orig_size - 1)
        end
    end

    local title_top_padding = self.title_top_padding
    if not title_top_padding then
        local text_baseline = self.title_widget:getBaseline()

        -- For baseline alignment we need a max icon height among all buttons
        local max_icon_h = 0
        if left_defs then
            for _, d in ipairs(left_defs) do
                max_icon_h = math.max(max_icon_h, Screen:scaleBySize(DGENERIC_ICON_SIZE * (d.size_ratio or 0.6)))
            end
        end
        if right_defs then
            for _, d in ipairs(right_defs) do
                max_icon_h = math.max(max_icon_h, Screen:scaleBySize(DGENERIC_ICON_SIZE * (d.size_ratio or 0.6)))
            end
        end

        local icon_height = max_icon_h
        local icon_baseline = icon_height * 0.85 + self.button_padding
        title_top_padding = Math.round(math.max(0, icon_baseline - text_baseline))

        if self.title_shrink_font_to_fit then
            if self._initial_title_top_padding then
                title_top_padding = Math.round(self._initial_title_top_padding + (self._initial_title_text_baseline - text_baseline)/2)
            else
                self._initial_title_top_padding = title_top_padding
                self._initial_title_text_baseline = text_baseline
            end
        end
    end

    self.subtitle_widget = nil
    if self.subtitle then
        if self.subtitle_multilines then
            self.subtitle_widget = TextBoxWidget:new{
                text = self.subtitle,
                alignment = self.align,
                width = subtitle_max_width,
                face = self.subtitle_face,
                lang = self.lang,
            }
        else
            self.subtitle_widget = TextWidget:new{
                text = self.subtitle,
                face = self.subtitle_face,
                max_width = subtitle_max_width,
                truncate_left = self.subtitle_truncate_left,
                padding = 0,
                lang = self.lang,
            }
        end
    end

    self.title_group = VerticalGroup:new{
        align = self.align,
        overlap_align = self.align,
        VerticalSpan:new{ width = title_top_padding },
    }

    if self.align == "left" then
        self.inner_title_group = HorizontalGroup:new{
            HorizontalSpan:new{ width = left_icon_reserved_width + self.title_h_padding },
            self.title_widget,
        }
        table.insert(self.title_group, self.inner_title_group)
    else
        table.insert(self.title_group, self.title_widget)
    end

    if self.subtitle_widget then
        table.insert(self.title_group, VerticalSpan:new{ width = self.title_subtitle_v_padding })
        if self.align == "left" then
            local span_width = self.title_h_padding
            if not self.subtitle_fullwidth then
                span_width = span_width + left_icon_reserved_width
            end
            self.inner_subtitle_group = HorizontalGroup:new{
                HorizontalSpan:new{ width = span_width },
                self.subtitle_widget,
            }
            table.insert(self.title_group, self.inner_subtitle_group)
        else
            table.insert(self.title_group, self.subtitle_widget)
        end
    end

    table.insert(self, self.title_group)

    self.titlebar_height = self.title_group:getSize().h
    if self.title_shrink_font_to_fit then
        if self._initial_titlebar_height then
            self.titlebar_height = self._initial_titlebar_height
        else
            self._initial_titlebar_height = self.titlebar_height
        end
    end

    if self.with_bottom_line then
        local title_bottom_padding = math.max(title_top_padding, Size.padding.default)
        local filler_height = self.titlebar_height + title_bottom_padding
        if self.title_shrink_font_to_fit then
            if self._initial_filler_height then
                filler_height = self._initial_filler_height
            else
                self._initial_filler_height = filler_height
            end
        end

        local line_widget = LineWidget:new{
            dimen = Geom:new{ w = self.width, h = Size.line.thick },
            background = self.bottom_line_color
        }
        if self.bottom_line_h_padding then
            line_widget.dimen.w = line_widget.dimen.w - 2 * self.bottom_line_h_padding
            line_widget = HorizontalGroup:new{
                HorizontalSpan:new{ width = self.bottom_line_h_padding },
                line_widget,
            }
        end

        local filler_and_bottom_line = VerticalGroup:new{
            VerticalSpan:new{ width = filler_height },
            line_widget,
        }
        table.insert(self, filler_and_bottom_line)
        self.titlebar_height = filler_and_bottom_line:getSize().h
    end

    if not self.bottom_v_padding then
        self.bottom_v_padding = self.with_bottom_line and Size.padding.default or Size.padding.large
    end
    self.titlebar_height = self.titlebar_height + self.bottom_v_padding

    if self._initial_re_init_needed then
        self._initial_re_init_needed = nil
        self:clear()
        self:init()
        return
    end

    if self.info_text then
        local h_padding = self.info_text_h_padding or self.title_h_padding
        local v_padding = self.with_bottom_line and Size.padding.default or 0
        local filler_and_info_text = VerticalGroup:new{
            VerticalSpan:new{ width = self.titlebar_height + v_padding },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = h_padding },
                TextBoxWidget:new{
                    text = self.info_text,
                    face = self.info_text_face,
                    width = self.width - 2 * h_padding,
                    lang = self.lang,
                }
            }
        }
        table.insert(self, filler_and_info_text)
        self.titlebar_height = filler_and_info_text:getSize().h + self.bottom_v_padding
    end

    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.titlebar_height }

    -- ----- multi buttons rendering ------------------------------------------

    self.left_buttons_widgets = nil
    self.right_buttons_widgets = nil
    self.left_button = nil
    self.right_button = nil

    if self.has_left_icon and left_defs then
        local group = HorizontalGroup:new{ overlap_align = "left" }
        local widgets = {}

        for i, d in ipairs(left_defs) do
            local icon_size = Screen:scaleBySize(DGENERIC_ICON_SIZE * (d.size_ratio or 0.6))
            local is_near_title = (i == #left_defs) -- closest to title
            local btn = make_icon_button(self, d, icon_size, "left", is_near_title)
            table.insert(group, btn)
            table.insert(widgets, btn)
        end

        self.left_buttons_widgets = widgets
        -- keep legacy reference for FocusManager compatibility
        self.left_button = widgets[1]
        table.insert(self, group)
    end

    if self.has_right_icon and right_defs then
        local group = HorizontalGroup:new{ overlap_align = "right" }
        local widgets = {}

        -- Order: left-to-right inside the right-anchored group,
        -- so the last one is the outermost on the far right.
        for i, d in ipairs(right_defs) do
            local icon_size = Screen:scaleBySize(DGENERIC_ICON_SIZE * (d.size_ratio or 0.6))
            local is_near_title = (i == 1) -- closest to title
            local btn = make_icon_button(self, d, icon_size, "right", is_near_title)
            table.insert(group, btn)
            table.insert(widgets, btn)
        end

        self.right_buttons_widgets = widgets
        self.right_button = widgets[#widgets]
        table.insert(self, group)
    end

    OverlapGroup.init(self)
end

-- ---- keep legacy setters working -------------------------------------------

local old_setLeftIcon = TitleBar.setLeftIcon
function TitleBar:setLeftIcon(icon)
    if self.left_buttons_widgets and self.left_buttons_widgets[1] then
        self.left_buttons_widgets[1]:setIcon(icon)
        UIManager:setDirty(self.show_parent, "ui", self.dimen)
        return
    end
    return old_setLeftIcon(self, icon)
end

local old_setRightIcon = TitleBar.setRightIcon
function TitleBar:setRightIcon(icon)
    if self.right_buttons_widgets and self.right_buttons_widgets[#self.right_buttons_widgets] then
        self.right_buttons_widgets[#self.right_buttons_widgets]:setIcon(icon)
        UIManager:setDirty(self.show_parent, "ui", self.dimen)
        return
    end
    return old_setRightIcon(self, icon)
end

-- ---- FocusManager layout: include all buttons ------------------------------

function TitleBar:generateHorizontalLayout()
    local row = {}
    if self.left_buttons_widgets then
        for _, b in ipairs(self.left_buttons_widgets) do table.insert(row, b) end
    elseif self.left_button then
        table.insert(row, self.left_button)
    end
    if self.right_buttons_widgets then
        for _, b in ipairs(self.right_buttons_widgets) do table.insert(row, b) end
    elseif self.right_button then
        table.insert(row, self.right_button)
    end
    local layout = {}
    if #row > 0 then table.insert(layout, row) end
    return layout
end

function TitleBar:generateVerticalLayout()
    local layout = {}
    if self.left_buttons_widgets then
        for _, b in ipairs(self.left_buttons_widgets) do table.insert(layout, { b }) end
    elseif self.left_button then
        table.insert(layout, { self.left_button })
    end
    if self.right_buttons_widgets then
        for _, b in ipairs(self.right_buttons_widgets) do table.insert(layout, { b }) end
    elseif self.right_button then
        table.insert(layout, { self.right_button })
    end
    return layout
end
