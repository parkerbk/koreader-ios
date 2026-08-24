local StorefrontSettingsCard = require("storefront_settings_card")

local StorefrontSettingsDialog = {}

function StorefrontSettingsDialog:show(Storefront)
    StorefrontSettingsCard.show(Storefront)
end

return StorefrontSettingsDialog
