-- Ignore les chapitres Rakuyomi dans l'historique KOReader

local ReadHistory = require("readhistory")

local orig_addItem = ReadHistory.addItem

function ReadHistory:addItem(file, ts, no_flush)
    -- Sécurité : si pas de nom de fichier, on laisse faire le code normal
    if not file then
        return orig_addItem(self, file, ts, no_flush)
    end

    -- Si le fichier vient des téléchargements Rakuyomi, on le zappe
    -- (fonctionne que ce soit /mnt/onboard/ ou /mnt/us/, etc.)
    if file:match("koreader/rakuyomi/downloads") then
        -- Pas d'entrée ajoutée dans history.lua
        return
    end

    -- Pour tout le reste, comportement normal
    return orig_addItem(self, file, ts, no_flush)
end