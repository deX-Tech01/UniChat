# UniChat — Supabase setup

The supplied publishable key is intentionally public. It cannot apply database schema changes. No secret or service-role key is required in the website.

## 1. Apply the database setup

Open your UniChat project at https://supabase.com/dashboard/project/irkizbzqkcsjoosrragh/sql/new.
Create a new SQL query, paste the entire contents of UniChat_Setup.sql, then click Run. Keep the default postgres execution role in SQL Editor. The script creates only UniChat-prefixed application objects and two UniChat storage buckets. It can be run again for this initial setup.

The script was checked with a PostgreSQL-compatible local test engine, including owner-only settings, profile permissions, message isolation and suspended-account restrictions. It has not yet been executed against your hosted project.

## 2. Set authentication URLs

Under Authentication → URL Configuration, set Site URL to your final website origin, and add that origin followed by / to Redirect URLs. For the current private preview, use:
https://unichat-campus-connect.dex0001.chatgpt.site/

When you deploy outside the preview host, update Site URL and add the new production origin. Keep email confirmation enabled. Confirmation and password reset links return to the root page.

## 3. Configure email before inviting students

Supabase's default mail service is for testing and restricts recipients to your project's organization team. Configure custom SMTP for general student signup and password recovery before launch. Enter SMTP credentials only in Supabase's dashboard, never in this app's browser code.
Official guide: https://supabase.com/docs/guides/auth/auth-smtp

## 4. Create the owner account

Register with chimdike247@gmail.com and confirm the email. Choose a password in the app; do not share it. This verified email is the configured owner. Database permissions check the confirmed Supabase Auth email, not a user-editable profile field. Students cannot promote themselves.

Signup asks for full name, username, email, password, school, department and level. A student completes their profile after email confirmation. If a username was taken while confirmation was pending, choose a new one at that step.

## 5. Test

Sign in, create a post, like and reply, edit the profile, then sign out and back in. In Owner dashboard, save a draft, preview, publish, and restore a version. Register a second test student with a verified email after SMTP is configured; check that they cannot open owner controls and that a private message is visible only to its sender and recipient.

## Website hosting

The backend is Supabase. The current preview address retains its existing owner-only ChatGPT hosting gate; Supabase cannot remove that outer gate. For independent access, deploy the website/ folder in UniChat_Supabase_Package.zip on your own static host, then update the authentication URLs above. The folder contains built files and needs no build command or secrets.

## Current scope

Accounts, profiles, owner settings, posts, reactions, comments, reports, private text messages, logo uploads and post uploads use Supabase. Student discovery and messaging currently show the first 100 active profiles; the feed loads the latest 100 posts. Community selection and event interest still use the initial catalogue and account preferences. Community discussions, student-created events, blocking/message requests, notifications, comprehensive page layout editing and launch-scale pagination still require development. Private post media uses one-hour signed URLs; reload to refresh an expired URL.

Existing D1 preview accounts and posts have not been imported: Supabase accounts use new identities. No previous hosted database was deleted.
