-- Tri "En cours en premier" pour KOReader File Manager
-- À placer dans : .koreader/patches/
--
-- Ajoute un mode de tri :
--   "En cours en premier (auteur, titre)"
--
-- Comportement :
--   1. Livres EN COURS (status "reading" ou % entre 0 et 100%) — triés par auteur puis titre
--   2. Tous les autres livres (non ouverts, terminés, abandonnés) — triés par auteur puis titre
--
-- La colonne de droite affiche le pourcentage de progression pour les livres en cours.

local BookList = require("ui/widget/booklist")
local DocSettings = require("docsettings")
local ffiUtil = require("ffi/util")
local _ = require("gettext")

local FFFF = "\u{FFFF}"

BookList.collates.reading_first = {
    text = _("En cours en premier (auteur, titre)"),
    menu_order = 9,
    can_collate_mixed = false,

    item_func = function(item, ui)
        local path = item.path or item.file

        -- Métadonnées (auteur, titre)
        local doc_props = {}
        if ui and ui.bookinfo then
            doc_props = ui.bookinfo:getDocProps(path) or {}
        end
        item.doc_props = doc_props
        item.doc_props.authors = item.doc_props.authors or FFFF
        item.doc_props.display_title = item.doc_props.display_title or item.text or ""

        -- Statut de lecture lu directement dans le sidecar
        item.is_reading = false
        item.percent_finished = 0

        if DocSettings:hasSidecarFile(path) then
            local ds = DocSettings:open(path)
            local summary = ds:readSetting("summary")
            local status = summary and summary.status
            local pct = ds:readSetting("percent_finished") or 0

            if status == "complete" or status == "abandoned" then
                item.is_reading = false
            elseif status == "reading" then
                item.is_reading = true
            else
                item.is_reading = pct > 0 and pct < 1.0
            end
            item.percent_finished = pct
        end
    end,

    init_sort_func = function(cache)
        local my_cache = cache or {}
        return function(a, b)
            -- Groupe 1 : en cours ; Groupe 2 : tout le reste
            if a.is_reading ~= b.is_reading then
                return a.is_reading
            end

            -- Dans chaque groupe : auteur puis titre
            local aa = a.doc_props and a.doc_props.authors or FFFF
            local ba = b.doc_props and b.doc_props.authors or FFFF
            if aa ~= ba then
                return ffiUtil.strcoll(aa, ba)
            end

            local at = a.doc_props and a.doc_props.display_title or a.text or ""
            local bt = b.doc_props and b.doc_props.display_title or b.text or ""
            return ffiUtil.strcoll(at, bt)
        end, my_cache
    end,

    mandatory_func = function(item)
        if item.is_reading then
            return string.format("%d\u{202F}%%", 100 * (item.percent_finished or 0))
        end
        return ""
    end,
}

return BookList.collates
