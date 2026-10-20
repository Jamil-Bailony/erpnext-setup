app_name = "erp_custom"
app_title = "ERP Custom"
app_publisher = "Jamil Bailony"
app_description = "Our ERPNext customisations: UI, fonts, and anything else site-specific"
app_email = "jBailony@outlook.com"
app_license = "Proprietary"
required_apps = ["erpnext"]

# Assets
# Bundles live in erp_custom/public and are built (and content-hashed) by `bench build`.

# Desk (/app)
app_include_css = "erp_custom.bundle.css"

# Website and portal pages, including /login
web_include_css = "erp_custom.bundle.css"
