--[[
  2-epub-typo-fix-v1-0.lua
  v0.2 : entités décodées (&#8217; &#233; &nbsp; &amp;…) et espaces normalisés
         (retours à la ligne / espaces multiples du XHTML = une espace).
  v0.3 : fausses coupures (OCR) : une sélection à cheval sur une coupure
         fusionne les paragraphes, si la coupure est sûre à supprimer :
         </p> + <p …>, </div> + <div …>, ou un simple <br/>.
  v0.4 : coupures "en série" : paragraphes vides intercalés (<p></p>, <p/>,
         <p>&nbsp;</p>), plusieurs <br/>, indentation en espaces insécables.
  v1.0 : sauvegarde renommée .epub.orig (un .epub.bak des versions de test
         est repris automatiquement comme original).
  Corrige une typo directement dans l'EPUB, depuis la liseuse.

  Utilisation :
    Sélectionner le mot fautif → bouton "Corriger la typo" dans le menu
    de surlignage → saisir la correction → l'EPUB est réécrit puis rechargé.

  Principe :
    1. L'xpointer de la sélection donne le DocFragment N (= Nième élément du spine).
    2. On compte combien de fois le texte apparaît AVANT la sélection dans ce
       fragment (texte rendu) → on sait quelle occurrence corriger.
    3. On lit container.xml → OPF → spine → fichier XHTML correspondant.
    4. On cherche le texte dans le XHTML brut, hors balises, après <body>.
       Contrôle de cohérence : même nombre d'occurrences que dans le texte rendu.
    5. On recopie l'EPUB (ffi/archiver = libarchive) dans un .tmp :
       mimetype en premier et non compressé, le reste en deflate.
    6. On vérifie le .tmp, on garde l'original en .orig (une seule fois :
       le .orig reste la version d'origine), on remplace, on recharge.

  Limites connues (v0.3) :
    - Texte coupé par une balise (<i>, <span>…) au milieu de la sélection : refusé.
    - Coupure qui traverse plus qu'un paragraphe (</p></div><div><p>…) : refusée.
    - Entités HTML nommées exotiques (hors table ci-dessous) : refusées.
    - Dernier chapitre du livre : pas de contrôle "nombre total d'occurrences".
]]

local ReaderHighlight = require("apps/reader/modules/readerhighlight")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

if ReaderHighlight._epub_typo_fix_patched then return end
ReaderHighlight._epub_typo_fix_patched = true

-- ============================================================
-- Petits utilitaires
-- ============================================================

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function isEpub(path)
    return type(path) == "string" and path:lower():match("%.epub$") ~= nil
end

-- Échappement pour écrire la correction dans le XHTML
local function escapeForWrite(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function urlDecode(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function normalizePath(p)
    local out = {}
    for part in p:gmatch("[^/]+") do
        if part == ".." then
            table.remove(out)
        elseif part ~= "." then
            table.insert(out, part)
        end
    end
    return table.concat(out, "/")
end

-- Échappe les caractères magiques des motifs Lua
local function escapePattern(s)
    return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

-- Uniformise les sauts de paragraphe du texte rendu : un seul \n, sans espaces
-- ni insécables autour (indentation OCR en &nbsp;, lignes vides en série…)
local function normalizeBreaks(s)
    local n
    repeat
        local a, b, c
        s, a = s:gsub("%s*\n%s*", "\n")
        s = s:gsub("\n\n+", "\n")
        s, b = s:gsub("\n\194\160", "\n")
        s, c = s:gsub("\194\160\n", "\n")
        n = b + c
    until n == 0
    return s
end

-- Une coupure brute peut-elle être supprimée sans casser le XHTML ?
-- Acceptées (espaces et insécables ignorés) :
--   - une série de <br/>
--   - </X> [paragraphes vides <X></X> ou <X/> ou <br/>]* <X …>   avec X = p ou div
--   - éventuellement précédé/suivi de <br/>
local function tagKind(t)
    if t:match("^<[bB][rR]%s*/?>$") then return "br" end
    local n = t:match("^</(%w+)%s*>$")
    if n then return "close", n:lower() end
    n = t:match("^<(%w+)[^>]*/>$")
    if n then return "empty", n:lower() end
    n = t:match("^<(%w+)>$") or t:match("^<(%w+)%s[^>]*>$")
    if n then return "open", n:lower() end
    return "other"
end

local function isSafeJoin(gap_raw)
    local g = gap_raw:gsub("&nbsp;", ""):gsub("&#160;", ""):gsub("&#[xX][aA]0;", ""):gsub("\194\160", "")
    local kinds = {}
    local rest = g:gsub("<[^>]*>", function(t)
        local k, name = tagKind(t)
        table.insert(kinds, { k, name })
        return ""
    end)
    if rest:match("%S") or #kinds == 0 then return false end

    -- On ignore les <br/> au début et à la fin
    local i, j = 1, #kinds
    while i <= j and kinds[i][1] == "br" do i = i + 1 end
    while j >= i and kinds[j][1] == "br" do j = j - 1 end
    if i > j then return true end -- uniquement des <br/>

    local first, last = kinds[i], kinds[j]
    if j - i < 1 or first[1] ~= "close" or last[1] ~= "open" or first[2] ~= last[2] then
        return false
    end
    local X = first[2]
    if X ~= "p" and X ~= "div" then return false end

    local k = i + 1
    while k < j do
        local cur, nxt = kinds[k], kinds[k + 1]
        if cur[1] == "br" or (cur[1] == "empty" and cur[2] == X) then
            k = k + 1
        elseif cur[1] == "open" and cur[2] == X and k + 1 < j
               and nxt[1] == "close" and nxt[2] == X then
            k = k + 2 -- paragraphe vide <X></X>
        else
            return false
        end
    end
    return true
end

local function countPlain(hay, needle)
    local c, pos = 0, 1
    while true do
        local s, e = hay:find(needle, pos, true)
        if not s then return c end
        c = c + 1
        pos = e + 1
    end
end

local function getAttr(attrs, name)
    return attrs:match("%s" .. name .. "%s*=%s*\"([^\"]*)\"")
        or attrs:match("%s" .. name .. "%s*=%s*'([^']*)'")
end

-- ============================================================
-- Lecture de la structure EPUB
-- ============================================================

-- Renvoie le chemin (dans l'archive) du Nième fichier du spine
local function findSpineFile(reader, n)
    local container = reader:extractToMemory("META-INF/container.xml")
    if not container then return nil, "container.xml introuvable" end

    local opf_path = container:match("full%-path%s*=%s*\"([^\"]+)\"")
                  or container:match("full%-path%s*=%s*'([^']+)'")
    if not opf_path then return nil, "chemin de l'OPF introuvable" end

    local opf = reader:extractToMemory(opf_path)
    if not opf then return nil, "OPF illisible : " .. opf_path end
    local opf_dir = opf_path:match("^(.*/)") or ""

    local manifest, spine = {}, {}
    for name, attrs in opf:gmatch("<([%w:]+)(%s[^>]*)>") do
        local local_name = name:match("([^:]+)$")
        if local_name == "item" then
            local id, href = getAttr(attrs, "id"), getAttr(attrs, "href")
            if id and href then manifest[id] = href end
        elseif local_name == "itemref" then
            local idref = getAttr(attrs, "idref")
            if idref then table.insert(spine, idref) end
        end
    end

    local idref = spine[n]
    if not idref then
        return nil, string.format("fragment %d hors du spine (%d éléments)", n, #spine)
    end
    local href = manifest[idref]
    if not href then return nil, "élément de spine sans manifest : " .. idref end
    href = href:gsub("#.*$", "")
    return normalizePath(opf_dir .. urlDecode(href))
end

-- ============================================================
-- Décodage du XHTML avec table de correspondance
-- ============================================================

local function utf8char(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
                           0x80 + math.floor(cp / 0x40) % 0x40,
                           0x80 + cp % 0x40)
    else
        return string.char(0xF0 + math.floor(cp / 0x40000),
                           0x80 + math.floor(cp / 0x1000) % 0x40,
                           0x80 + math.floor(cp / 0x40) % 0x40,
                           0x80 + cp % 0x40)
    end
end

-- Entités nommées : les 5 XML + les HTML les plus courantes en français
local NAMED_ENTITIES = {
    amp = "&", lt = "<", gt = ">", quot = "\"", apos = "'",
    nbsp = 0xA0, shy = 0xAD, hellip = 0x2026, mdash = 0x2014, ndash = 0x2013,
    laquo = 0xAB, raquo = 0xBB, lsquo = 0x2018, rsquo = 0x2019,
    ldquo = 0x201C, rdquo = 0x201D, oelig = 0x153, OElig = 0x152,
    aelig = 0xE6, AElig = 0xC6, ccedil = 0xE7, Ccedil = 0xC7,
    agrave = 0xE0, acirc = 0xE2, eacute = 0xE9, egrave = 0xE8, ecirc = 0xEA,
    euml = 0xEB, icirc = 0xEE, iuml = 0xEF, ocirc = 0xF4, ugrave = 0xF9,
    ucirc = 0xFB, uuml = 0xFC, Agrave = 0xC0, Eacute = 0xC9, Egrave = 0xC8,
    Ecirc = 0xCA, thinsp = 0x2009,
}

local function decodeEntity(name)
    local hex = name:match("^#[xX](%x+)$")
    if hex then return utf8char(tonumber(hex, 16)) end
    local dec = name:match("^#(%d+)$")
    if dec then return utf8char(tonumber(dec)) end
    local v = NAMED_ENTITIES[name]
    if type(v) == "number" then return utf8char(v) end
    return v -- string ou nil
end

-- Décode le texte du XHTML à partir de <body>, comme crengine le "voit" :
--   - balises et commentaires → un \0 (une recherche ne peut pas les traverser)
--   - entités → caractère UTF-8
--   - suite d'espaces/retours à la ligne → une seule espace
-- Pour chaque octet décodé, on garde la plage [starts, ends] du texte brut
-- qui l'a produit : on peut ainsi remplacer exactement la bonne zone.
local function decodeWithMap(raw)
    local out, starts, ends = {}, {}, {}
    local n = #raw
    local i = raw:find("<body[%s>]")
    if not i then return "", starts, ends end

    local function push(str, s, e)
        for k = 1, #str do
            local idx = #out + 1
            out[idx] = str:sub(k, k)
            starts[idx] = s
            ends[idx] = e
        end
    end

    while i <= n do
        local c = raw:sub(i, i)
        if c == "<" then
            local e
            if raw:sub(i, i + 3) == "<!--" then
                local _, ce = raw:find("-->", i + 4, true)
                e = ce or n
            else
                e = raw:find(">", i + 1, true) or n
            end
            push("\0", i, e)
            i = e + 1
        elseif c == "&" then
            local e = raw:find(";", i + 1, true)
            local decoded = e and (e - i) <= 12 and decodeEntity(raw:sub(i + 1, e - 1))
            if decoded then
                push(decoded, i, e)
                i = e + 1
            else
                push("&", i, i)
                i = i + 1
            end
        elseif c:match("%s") then
            local _, e = raw:find("^%s+", i)
            push(" ", i, e)
            i = e + 1
        else
            -- Bloc de texte littéral jusqu'au prochain < & ou espace
            local e = (raw:find("[<&%s]", i) or n + 1) - 1
            for k = i, e do
                local idx = #out + 1
                out[idx] = raw:sub(k, k)
                starts[idx] = k
                ends[idx] = k
            end
            i = e + 1
        end
    end
    return table.concat(out), starts, ends
end

-- Occurrences de needle dans le texte décodé → liste de plages brutes
--   { [1] = début brut, [2] = fin brute, gaps = { {début, fin}, … } }
-- Chaque \n de needle (saut de paragraphe dans le texte rendu) correspond,
-- côté décodé, à au moins une balise (\0) entourée d'éventuelles espaces.
local function findTextOccurrences(raw, needle)
    local text, starts, ends = decodeWithMap(raw)
    local segs = {}
    for seg in (needle .. "\n"):gmatch("(.-)\n") do
        table.insert(segs, seg)
    end

    local res, pos = {}, 1
    if #segs == 1 then
        while true do
            local s, e = text:find(needle, pos, true)
            if not s then break end
            table.insert(res, { starts[s], ends[e], gaps = {} })
            pos = e + 1
        end
        return res
    end

    local parts = {}
    for i, seg in ipairs(segs) do
        parts[#parts + 1] = escapePattern(seg)
        if i < #segs then
            parts[#parts + 1] = "()[%z \194\160]*%z[%z \194\160]*()"
        end
    end
    local pattern = table.concat(parts)

    while true do
        local r = { text:find(pattern, pos) }
        local s, e = r[1], r[2]
        if not s then break end
        local gaps = {}
        for k = 3, #r, 2 do
            table.insert(gaps, { starts[r[k]], ends[r[k + 1] - 1] })
        end
        table.insert(res, { starts[s], ends[e], gaps = gaps })
        pos = e + 1
    end
    return res
end

-- ============================================================
-- Réécriture de l'EPUB
-- ============================================================

local function applyFix(filepath, frag_index, occ_index, total_rendered, old_text, new_text)
    local Archiver = require("ffi/archiver")

    local reader = Archiver.Reader:new()
    if not reader:open(filepath) then
        return nil, "ouverture impossible : " .. tostring(reader.err)
    end

    -- Indispensable : remplit reader.entries (sinon seek/extract échouent)
    local entries = {}
    for entry in reader:iterate() do
        table.insert(entries, entry)
    end

    local target, err = findSpineFile(reader, frag_index)
    if not target then reader:close(); return nil, err end
    if not reader.entries[target] then
        reader:close()
        return nil, "fichier absent de l'archive : " .. target
    end

    local raw = reader:extractToMemory(target)
    if not raw then reader:close(); return nil, "lecture impossible : " .. target end

    local occ = findTextOccurrences(raw, old_text)

    if total_rendered and #occ ~= total_rendered then
        reader:close()
        return nil, string.format(
            "Texte brut et texte affiché ne concordent pas (%d contre %d occurrences).\n" ..
            "Probablement une balise ou une entité au milieu du mot.",
            #occ, total_rendered)
    end
    local range = occ[occ_index]
    if not range then
        reader:close()
        return nil, string.format("Occurrence n°%d introuvable dans %s (%d trouvées).",
            occ_index, target, #occ)
    end

    for _, g in ipairs(range.gaps) do
        local gap_raw = raw:sub(g[1], g[2])
        if not isSafeJoin(gap_raw) then
            reader:close()
            local shown = trim(gap_raw):gsub("%s+", " ")
            if #shown > 80 then shown = shown:sub(1, 80) .. "…" end
            return nil, "Coupure non fusionnable (structure trop complexe) :\n" .. shown
        end
    end
    if #range.gaps > 0 then
        logger.info("epub-typo-fix: fusion de", #range.gaps, "coupure(s)")
    end

    local new_raw = raw:sub(1, range[1] - 1) .. escapeForWrite(new_text) .. raw:sub(range[2] + 1)
    logger.info("epub-typo-fix:", target, "occurrence", occ_index, old_text, "->", new_text)

    -- Écriture dans un fichier temporaire
    local tmp = filepath .. ".typofix.tmp"
    os.remove(tmp)
    local writer = Archiver.Writer:new()
    if not writer:open(tmp, "epub") then
        reader:close()
        return nil, "écriture impossible : " .. tostring(writer.err)
    end

    local function fail(msg)
        writer:close()
        reader:close()
        os.remove(tmp)
        return nil, msg
    end

    -- mimetype : premier, non compressé
    writer:setZipCompression("store")
    if not writer:addFileFromMemory("mimetype", "application/epub+zip") then
        return fail("échec mimetype : " .. tostring(writer.err))
    end
    writer:setZipCompression("deflate")

    local written = 1
    for _, entry in ipairs(entries) do
        if entry.mode == "file" and entry.path ~= "mimetype" then
            local content
            if entry.path == target then
                content = new_raw
            else
                content = reader:extractToMemory(entry.path)
            end
            if not content then
                return fail("lecture impossible : " .. entry.path)
            end
            if not writer:addFileFromMemory(entry.path, content) then
                return fail("écriture impossible : " .. entry.path .. " (" .. tostring(writer.err) .. ")")
            end
            written = written + 1
        end
    end
    writer:close()
    reader:close()

    -- Vérification du .tmp avant de toucher à l'original
    local check = Archiver.Reader:new()
    if not check:open(tmp) then
        os.remove(tmp)
        return nil, "le fichier réécrit est illisible"
    end
    local n = 0
    for entry in check:iterate() do
        if entry.mode == "file" then n = n + 1 end
    end
    check:close()
    if n ~= written then
        os.remove(tmp)
        return nil, string.format("vérification échouée (%d fichiers au lieu de %d)", n, written)
    end

    -- Remplacement : l'original devient .orig la première fois seulement
    local orig = filepath .. ".orig"
    local old_bak = filepath .. ".bak" -- versions de test (v0.x)
    if lfs.attributes(orig, "mode") ~= "file" then
        local ok, e
        if lfs.attributes(old_bak, "mode") == "file" then
            -- Le .bak des versions de test EST l'original : on le renomme
            -- (le livre actuel sera écrasé par le .tmp juste après)
            ok, e = os.rename(old_bak, orig)
        else
            ok, e = os.rename(filepath, orig)
        end
        if not ok then os.remove(tmp); return nil, "sauvegarde .orig impossible : " .. tostring(e) end
    end
    local ok, e = os.rename(tmp, filepath)
    if not ok then return nil, "remplacement impossible : " .. tostring(e) end

    return true
end

-- ============================================================
-- Interface
-- ============================================================

local function runFix(ui, old_text, new_text, frag_index, occ_index, total_rendered)
    local msg = InfoMessage:new{ text = "Réécriture de l'EPUB…" }
    UIManager:show(msg)
    UIManager:forceRePaint()

    local ok, res, err = pcall(applyFix, ui.document.file, frag_index, occ_index,
        total_rendered, old_text, new_text)
    UIManager:close(msg)

    if not ok or not res then
        local e = not ok and res or err
        logger.warn("epub-typo-fix: échec:", e)
        UIManager:show(InfoMessage:new{ text = "Correction impossible :\n" .. tostring(e) })
        return
    end

    UIManager:show(InfoMessage:new{ text = "Corrigé ✓", timeout = 1 })
    UIManager:nextTick(function() ui:reloadDocument() end)
end

local function showFixDialog(ui, old_text, pos0)
    old_text = trim(normalizeBreaks(old_text or ""))
    if old_text == "" then return end
    local breaks = countPlain(old_text, "\n")

    local frag_index = tonumber(pos0:match("DocFragment%[(%d+)%]"))
    if not frag_index then
        UIManager:show(InfoMessage:new{ text = "Position introuvable (xpointer inattendu)." })
        return
    end

    local doc = ui.document
    local frag_start = "/body/DocFragment[" .. frag_index .. "]"
    local next_start = "/body/DocFragment[" .. (frag_index + 1) .. "]"

    -- Occurrence à corriger = nombre d'occurrences avant la sélection + 1
    local ok, before = pcall(doc.getTextFromXPointers, doc, frag_start, pos0)
    if not ok or type(before) ~= "string" then
        UIManager:show(InfoMessage:new{ text = "Impossible de lire le texte du chapitre." })
        return
    end
    local occ_index = countPlain(normalizeBreaks(before), old_text) + 1

    -- Nombre total dans le fragment (contrôle de cohérence ; absent pour le dernier)
    local total_rendered
    local ok2, full = pcall(doc.getTextFromXPointers, doc, frag_start, next_start)
    if ok2 and type(full) == "string" and full ~= "" then
        total_rendered = countPlain(normalizeBreaks(full), old_text)
    end

    local dialog
    dialog = InputDialog:new{
        title = "Corriger la typo",
        description = string.format("Chapitre %d — occurrence n°%d%s%s", frag_index, occ_index,
            total_rendered and (" sur " .. total_rendered) or "",
            breaks == 1 and "\nFusion d'une coupure"
                or breaks > 1 and ("\nFusion de " .. breaks .. " coupures") or ""),
        -- Les coupures apparaissent comme des espaces dans le champ de saisie
        input = (old_text:gsub("\n", " ")),
        buttons = {{
            {
                text = "Annuler",
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = "Corriger",
                is_enter_default = true,
                callback = function()
                    local new_text = dialog:getInputText()
                    UIManager:close(dialog)
                    if new_text == old_text then return end
                    runFix(ui, old_text, new_text, frag_index, occ_index, total_rendered)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ============================================================
-- Bouton dans le menu de surlignage
-- ============================================================

local orig_init = ReaderHighlight.init

function ReaderHighlight:init(...)
    orig_init(self, ...)
    self:addToHighlightDialog("13_epub_typo_fix", function(this)
        return {
            text = "Corriger la typo",
            enabled = this.ui.rolling ~= nil and isEpub(this.ui.document and this.ui.document.file),
            callback = function()
                -- On capture AVANT onClose(), qui vide la sélection
                local sel = this.selected_text
                local text = sel and sel.text
                local pos0 = sel and sel.pos0
                this:onClose()
                if type(text) == "string" and type(pos0) == "string" then
                    showFixDialog(this.ui, text, pos0)
                end
            end,
        }
    end)
end

logger.info("epub-typo-fix: patch appliqué")
