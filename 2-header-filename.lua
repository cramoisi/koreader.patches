--[[
    User patch très simplifié :
    - Affiche en haut de l'écran :
        * le nom du fichier (sans extension) centré
        * le numéro de page à droite
    - Ne touche pas au footer : il reste géré par KOReader.
    - Ne fait rien pour les PDF (uniquement pour les epub-like).
--]]

local Blitbuffer       = require("ffi/blitbuffer")
local TextWidget       = require("ui/widget/textwidget")
local CenterContainer  = require("ui/widget/container/centercontainer")
local VerticalGroup    = require("ui/widget/verticalgroup")
local VerticalSpan     = require("ui/widget/verticalspan")
local HorizontalGroup  = require("ui/widget/horizontalgroup")
local HorizontalSpan   = require("ui/widget/horizontalspan")
local Size             = require("ui/size")
local Geom             = require("ui/geometry")
local Device           = require("device")
local Font             = require("ui/font")
local util             = require("util")
local BD               = require("ui/bidi")
local ReaderView       = require("apps/reader/modules/readerview")

local Screen           = Device.screen
local screen_width     = Screen:getWidth()
local header_settings  = G_reader_settings:readSetting("footer") or {}

-- Récupère "Auteur - Titre" depuis le nom du fichier (sans extension)
local function get_filename_basename(self)
    local doc = (self and self.ui   and self.ui.document)
             or (self and self.view and self.view.document)
             or (self and self.document)

    local p = doc and (doc.file or doc.filepath or doc.path)
    if not p then return nil end

    local _, fname = util.splitFilePathName(p)       -- ".../Auteur - Titre.epub" -> "Auteur - Titre.epub"
    local base, _  = util.splitFileNameSuffix(fname) -- "Auteur - Titre"

    base = base:gsub("_+", " "):gsub("%s%s+", " "):match("^%s*(.-)%s*$")
    return base
end

local _ReaderView_paintTo_orig = ReaderView.paintTo

ReaderView.paintTo = function(self, bb, x, y)
    -- Rendu normal d'abord
    _ReaderView_paintTo_orig(self, bb, x, y)

    -- On ne touche pas aux PDF / docs non "epub-like"
    if self.render_mode ~= nil then
        return
    end

    -- Page courante
    local pageno = self.state.page or 1

    -- Style du header : on réutilise les réglages du footer si dispo
    local header_font_face  = "ffont"
    local header_font_size  = header_settings.text_font_size or 14
    local header_font_bold  = header_settings.text_font_bold or false
    local header_font_color = Blitbuffer.COLOR_BLACK
    local header_top_padding = Size.padding.small

    local header_use_book_margins = true
    local header_margin           = Size.padding.large
    local header_max_width_pct    = 84  -- % de la largeur dispo, avant ellipsis

    -- Texte du header
    local filename_label = get_filename_basename(self) or ""
    local right_header   = tostring(pageno)

    -- Marges : on prend celles du livre si possible
    local left_margin  = header_margin
    local right_margin = header_margin
    if header_use_book_margins and self.document and self.document.getPageMargins then
        local margins = self.document:getPageMargins() or {}
        left_margin  = margins.left  or left_margin
        right_margin = margins.right or right_margin
    end

    local avail_width = screen_width - left_margin - right_margin

    -- Ajuste le texte centré pour qu'il tienne dans la largeur
    local function getFittedText(text, max_width_pct)
        if not text or text == "" then
            return ""
        end
        local text_widget = TextWidget:new{
            text      = text:gsub(" ", "\u{00A0}"), -- no-break space
            max_width = avail_width * max_width_pct * 0.01,
            face      = Font:getFace(header_font_face, header_font_size),
            bold      = header_font_bold,
            padding   = 0,
        }
        local fitted, add_ellipsis = text_widget:getFittedText()
        text_widget:free()
        if add_ellipsis then
            fitted = fitted .. "…"
        end
        return BD.auto(fitted)
    end

    local centered_header = getFittedText(filename_label, header_max_width_pct)

    -- Widgets texte
    local header_text = TextWidget:new{
        text    = centered_header,
        face    = Font:getFace(header_font_face, header_font_size),
        bold    = header_font_bold,
        fgcolor = header_font_color,
        padding = 0,
    }

    local right_header_text = TextWidget:new{
        text    = right_header,
        face    = Font:getFace(header_font_face, header_font_size),
        bold    = header_font_bold,
        fgcolor = header_font_color,
        padding = 0,
    }

    local header_height = math.max(
        header_text:getSize().h,
        right_header_text:getSize().h
    ) + header_top_padding

    -- 1) On dessine le nom de fichier, centré
    local header = CenterContainer:new{
        dimen = Geom:new{
            w = screen_width,
            h = header_height,
        },
        VerticalGroup:new{
            VerticalSpan:new{ width = header_top_padding },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = left_margin },
                header_text,
                HorizontalSpan:new{ width = right_margin },
            },
        },
    }
    header:paintTo(bb, x, y)
    header:free()  -- header_text est libéré avec le container

    -- 2) On dessine le numéro de page en haut à droite (dans les marges)
    local right_size = right_header_text:getSize()
    local right_x = x + screen_width - right_margin - right_size.w
    local right_y = y + header_top_padding

    right_header_text:paintTo(bb, right_x, right_y)
    right_header_text:free()
end
