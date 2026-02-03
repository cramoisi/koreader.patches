-- 2-fm-disable-tap-open-files.lua
-- FileManager: prevent accidental opening of *files* on tap (Palma tiny bezel),
-- while keeping:
--   - tap on folders (navigation)
--   - tap selection toggling when select mode is enabled
--   - long-press menu unchanged

local FileManager = require("apps/filemanager/filemanager")

-- Patch only once
if not FileManager._disable_tap_open_files_patched then
  FileManager._disable_tap_open_files_patched = true

  local orig_setupLayout = FileManager.setupLayout

  FileManager.setupLayout = function(self, ...)
    orig_setupLayout(self, ...)

    local fc = self.file_chooser
    if not fc or fc._disable_tap_open_files_fc_patched then
      return
    end
    fc._disable_tap_open_files_fc_patched = true

    local orig_onFileSelect = fc.onFileSelect

    fc.onFileSelect = function(file_chooser, item, ...)
      -- Keep selection mode behavior intact.
      if self.selected_files then
        return orig_onFileSelect(file_chooser, item, ...)
      end

      -- In normal browsing: ignore taps on *files* (prevents accidental opens).
      -- Keep taps on folders so you can still navigate.
      if item and item.is_file then
        return true
      end

      return orig_onFileSelect(file_chooser, item, ...)
    end
  end
end
