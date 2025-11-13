
--[[
  Project: Title — Localize progress labels to French via TextWidget hook (v2)
  Goal: Show French labels (without switching KOReader global locale) for:
        "New" -> "Nouveau"
        "Reading" -> "Lecture en cours"
        "Finished" -> "Terminé"
        "On hold" -> "En pause"

  Approach:
    - Hook ListMenuItem.update (per Project: Title userpatch template).
    - Temporarily wrap ui/widget/textwidget.new to rewrite *rendered* strings.
      This happens *after* gettext/formatting, so it catches whatever the UI was going to display.
    - Restore TextWidget.new immediately after updating the row.
]]

local userpatch = require("userpatch")

-- Map *displayed* strings to French. Add variants if your theme/localization emits others.
local MAP = {
  -- English
  ["New"] = "Nouveau",
  ["Reading"] = "Lecture en cours",
  ["Finished"] = "Terminé",
  ["On hold"] = "En pause",
}

local function patchCoverBrowser(_plugin)
  local listmenu = require("listmenu")
  local ListMenuItem = userpatch.getUpValue(listmenu._updateItemsBuildUI, "ListMenuItem")
  if not ListMenuItem then return end

  local orig_update = ListMenuItem.update

  ListMenuItem.update = function(self)
    local TextWidget = require("ui/widget/textwidget")
    local orig_new = TextWidget.new

    -- Rewriter for the single-line status labels
    TextWidget.new = function(class, o)
      if o and type(o.text) == "string" then
        local fr = MAP[o.text]
        if fr then
          o.text = fr
        end
      end
      return orig_new(class, o)
    end

    local ok, err = xpcall(function() orig_update(self) end, debug.traceback)

    -- Always restore
    TextWidget.new = orig_new

    if not ok then error(err, 0) end
  end
end

userpatch.registerPatchPluginFunc("coverbrowser", patchCoverBrowser)
