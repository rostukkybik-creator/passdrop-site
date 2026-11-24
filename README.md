# Public site (GitHub Pages)

Static files only: legal pages, support, the app icon and `catalog.json`, which the app refreshes from. Publish as the `passdrop-site` repository with Pages enabled, then `AppConfig.catalogURL` and the legal URLs resolve.

Contacts match the Circarest pages: 5Hz development agency, hello@5hz.io, no postal address and no governing-law clause. `Tools/release-check.sh` fails if a `{{PLACEHOLDER}}` creeps back in. After editing `SummitPass/Resources/catalog.json`, copy it here (`cp SummitPass/Resources/catalog.json site/catalog.json`) and push.
