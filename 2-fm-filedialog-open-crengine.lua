-- 2-fm-filedialog-open-crengine.lua

local _ = require("gettext")
local UIManager = require("ui/uimanager")
local DocumentRegistry = require("document/documentregistry")
local ButtonDialog = require("ui/widget/buttondialog")

local function getCoolReaderProvider(path)
    local providers = DocumentRegistry:getProviders(path)
    if not providers then return nil end
    for _, p in ipairs(providers) do
        local prov = p.provider or p
        local key  = (prov.provider or ""):lower()
        local name = (prov.provider_name or ""):lower()
        if key == "crengine"
            or name:find("cool reader", 1, true)
            or name:find("crengine", 1, true)
        then
            return prov
        end
    end
    return nil
end

local function find_button_by_text(buttons, target_text)
    if type(buttons) ~= "table" then return nil end
    for _, row in ipairs(buttons) do
        if type(row) == "table" then
            for _, btn in ipairs(row) do
                if type(btn) == "table" and btn.text == target_text then
                    return btn
                end
            end
        end
    end
    return nil
end

local function extract_file_and_fm_from_callback(cb)
    if type(cb) ~= "function" then return nil, nil end
    if not debug or not debug.getupvalue then return nil, nil end

    local file, fm = nil, nil

    for i = 1, 200 do
        local name, val = debug.getupvalue(cb, i)
        if not name then break end

        -- file path
        if not file then
            if (name == "file" or name == "path") and type(val) == "string" then
                file = val
            elseif type(val) == "string" and val:find("/", 1, true) and #val > 8 then
                local tail = val:sub(-12)
                if tail:find("%.") then
                    file = val
                end
            end
        end

        -- file_manager instance (local in filemanager.lua, captured by callbacks)
        if not fm then
            if (name == "file_manager" or name == "filemanager" or name == "fm")
                and type(val) == "table"
                and type(val.openFile) == "function"
            then
                fm = val
            end
        end

        if file and fm then
            break
        end
    end

    return file, fm
end

-- Patch once
if ButtonDialog._open_crengine_patched then
    return true
end
ButtonDialog._open_crengine_patched = true

local _orig_new = ButtonDialog.new

ButtonDialog.new = function(cls, opts)
    if type(opts) == "table" and type(opts.buttons) == "table" then
        local ow1 = _("Open with…")
        local ow2 = _("Open with...")

        local open_with_btn = find_button_by_text(opts.buttons, ow1) or find_button_by_text(opts.buttons, ow2)

        if open_with_btn and type(open_with_btn.callback) == "function" then
            local file, fm = extract_file_and_fm_from_callback(open_with_btn.callback)

            if file and fm and not opts._open_crengine_added then
                opts._open_crengine_added = true

                local prov = getCoolReaderProvider(file) or DocumentRegistry:getProvider(file)

                table.insert(opts.buttons, 1, {{
                    text = _("Open"),
                    callback = function()
                        if UIManager.closeTopmost then
                            UIManager:closeTopmost()
                        end
                        fm:openFile(file, prov)
                    end,
                }})
            end
        end
    end

    return _orig_new(cls, opts)
end

return true
