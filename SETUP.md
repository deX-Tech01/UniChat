# Latest release: Update 14

Use `INSTALL_UPDATE.md` at the top of this package for the latest instructions. This complete package includes the original site and all upgrades through Update 14: faster startup, feeds, media, repeat visits and conversations; and higher owner-selected upload sizes. Run the combined SQL on your existing project and replace the entire `website/` folder before committing and pushing to GitHub/Vercel.

Earlier setup reference follows. Earlier numeric upload limits describe defaults or previous versions; the owner can now raise the byte limits, subject to Supabase's own project/service limits. Duration and format restrictions remain.

---

# UniChat setup

This package includes all upgrades through follower/following lists, owner controls, Reels, Stories and cover photos. For an existing UniChat installation, follow INSTALL_UPDATE.md. Run supabase/UniChat_Combined_Upgrade.sql once; do not also run the individual upgrades.

For a fresh Supabase project, run supabase/UniChat_Setup.sql, then supabase/UniChat_Combined_Upgrade.sql in SQL Editor. The app uses only the supplied publishable key. No database password or service-role key belongs in the website.

Authentication → URL Configuration:
- Site URL: https://unichatt.vercel.app
- Redirect URL: https://unichatt.vercel.app/

The confirmed Supabase Auth email chimdike247@gmail.com is the configured site owner. Register and confirm this email to use Owner dashboard. Keep email confirmation enabled. Configure custom SMTP before broad student signup and password recovery: https://supabase.com/docs/guides/auth/auth-smtp

Deploy website/ using your VS Code → GitHub → Vercel workflow. No build step is required. Vercel Root Directory is website, Framework Preset Other, Output Directory ., and Build/Install Commands empty.

App accounts, database, media and realtime updates use Supabase. Site hosting is Vercel. Existing private ChatGPT previews are separate from the live Vercel website.

After installation, see OWNER_GUIDE.md for owner statistics, moderation, maintenance, limits, security and recovery.
