--[[
    Center Project:Title page controls in the footer.

    Effet :
      - Après l'init Project:Title, remplace le container des contrôles de page
        (RightContainer/LeftContainer) par un CenterContainer.
      - Résultat : chevrons & numéro de page centrés en bas, loin des coins,
        sans modifier le plugin lui-même.

    À déposer dans : patches/2-pt-center-page-controls.lua
--]]

local userpatch       = require("userpatch")
local CenterContainer = require("ui/widget/container/centercontainer")
local Menu            = require("ui/widget/menu")

local function patchCoverBrowser(_plugin)
    local ok, CoverMenu = pcall(require, "covermenu")
    if not ok or not CoverMenu or not CoverMenu.menuInit then
        return
    end

    local orig_menuInit = CoverMenu.menuInit

    -- On wrappe la version Project:Title
    function CoverMenu:menuInit(...)
        -- Appel normal de PT
        orig_menuInit(self, ...)

        -- À ce stade, le layout est construit :
        -- self[1] = FrameContainer{ footer }
        local root = self[1]
        if type(root) ~= "table" then return end

        local footer = root[1]
        if type(footer) ~= "table" then return end

        -- footer = OverlapGroup{
        --   [1] = self.content_group,
        --   [2] = page_return,
        --   [3] = current_folder,
        --   [4] = page_controls,
        --   [5] = footer_line,
        -- }
        local page_controls = footer[4]
        if type(page_controls) ~= "table" then return end

        -- page_controls = BottomContainer{ page_info_container }
        local old_container = page_controls[1]
        if type(old_container) ~= "table" or not old_container.dimen then
            return
        end

        -- On recrée un container centré avec les mêmes enfants
        local children = {}
        for i, child in ipairs(old_container) do
            children[i] = child
        end

        local new_container = CenterContainer:new {
            dimen = old_container.dimen:copy(),
            table.unpack(children),
        }

        page_controls[1] = new_container
        -- pas besoin de return explicite : Menu.init n'utilise pas de valeur de retour
    end

    -- TRÈS IMPORTANT : recoller Menu.init sur notre version patchée
    Menu.init = function(self, ...)
        -- On appelle la nouvelle CoverMenu:menuInit, qui wrappe celle de PT
        return CoverMenu.menuInit(self, ...)
    end
end

userpatch.registerPatchPluginFunc("coverbrowser", patchCoverBrowser)
