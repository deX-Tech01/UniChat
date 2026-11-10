# UniChat owner controls

The owner is the confirmed Supabase Auth account for chimdike247@gmail.com. The frontend contains only the publishable key; never add a service-role key or database password to website/.

## Install

1. Run the latest supabase/UniChat_Combined_Upgrade.sql in Supabase SQL Editor. It includes all earlier upgrades and works whether you installed those updates already or still use the original setup. A completely new project needs UniChat_Setup.sql first. Do not run the original setup again over an existing upgraded project.
2. Copy every file from website/ into website/ in your existing VS Code Git repository. Include owner-controls.js, photo-crop.js and follow-lists.js. Preserve your repository's .git folder.
3. Commit and push. Vercel: Root Directory website, Framework Other, Output Directory ., no build/install command.
4. Sign in and open Owner dashboard. The Owner section selector includes the new controls and all previous content settings.

No live settings, users, roles, authenticator factors or data have been changed for you by creating this package.

## Overview

Registered accounts counts Supabase Auth accounts in this project, including those without completed student profiles. Completed profiles is a separate total. Online now counts distinct signed-in students whose visible tab sent a heartbeat in the last 90 seconds; multiple tabs count once. It is an approximate presence indicator, not proof someone is reading the site. Hidden tabs stop reporting visible presence; closed/disconnected tabs age out. The dashboard refreshes every 30 seconds. Active today starts collecting visits after this upgrade. Today's date boundary uses Africa/Lagos.

The school/department tables and 30-day growth use completed profile records. They are not independently verified enrolment figures. If the Supabase project serves other applications too, the Auth account total can include their accounts.

## Students and moderation

Search students by name, username, school or department, loading pages of 50. The owner can edit profile fields and suspend/restore accounts. Suspension blocks application data and writes; it does not delete an Auth account or erase already downloaded content. Auth account deletion and project-level account recovery remain in Supabase.

The Moderation centre brings together reports about posts, comments/replies, Reels and their comments, Stories, profiles, discussions and listings. Existing post reports are imported once; older deployed clients' post reports are also forwarded to the new queue. Review selected evidence, move reports through open/reviewing/resolved/dismissed, and send a response visible in the reporter's My reports page. Public content can be removed or listings closed. Suspend an account for private-chat abuse rather than editing its private conversation.

Students can report a selected direct message, group message, voice note or attachment. The report form explicitly asks them to share that item with the owner and moderators. The database verifies participation and creates the evidence snapshot itself. There is no owner/moderator private-conversation list or bypass to browse unreported messages, recordings or attachments. The report grants access only to its selected file. Reporting is limited to 20 submissions per student per hour.

The Privacy & blocks screen explains report sharing. Open/reviewing report files are protected from normal application deletion and excluded from owner cleanup. A viewer who already downloaded a file can keep it. Closed reports retain their evidence record; expired/unused public files may later be cleaned. Keep reports only as long as operationally necessary, using your Supabase administration procedures to manage longer-term retention.

## Announcements

Create a title/message, optional exact school and department labels, a start time and optional end time. Blank audience fields mean all students. Times entered are local browser time and stored as timestamps. Published announcements appear on Home for matching signed-in students. Uncheck Published to hide one. Open Home tabs refresh notices within about 30 seconds. This is an in-app announcement, not a bulk email or SMS service.

## Operations and upload limits

Maintenance mode immediately blocks student application data and writes through database rules. The owner can still sign in and manage the site; if owner MFA is required, unlock the dashboard with the authenticator. Already open tabs replace their screen with the configured notice within about 30 seconds. Already downloaded content and existing signed URLs cannot be recalled.

Feature switches in Features pause registration completion, posting, messaging, communities, events, uploads, Reels, Stories, group chats, opportunities, marketplace, comments, reactions, following or announcements. Switches pause new student writes and their corresponding interface; they do not erase old data. The app prevents signup through its interface while registration is paused; to disable new Supabase Auth accounts through all possible clients, also change the Auth signup setting in Supabase. Hosting, Auth delivery/quotas and billing are external project controls.

Upload limits let you lower supported bucket sizes, choose permitted MIME types and set video/voice-note duration from 1 to 60 seconds. Stored file size/type limits are applied to Supabase Storage buckets, and the web app checks uploads too. Duration is constrained as declared metadata in the database and measured in the browser; there is no server transcoder analysing video/audio bytes. Limits cannot exceed the app's supported maxima:

| Category | Maximum | Formats |
| --- | --- | --- |
| Post media | 2.5 MB | JPEG, PNG, WebP, GIF, MP4 |
| Chat files | 10 MB | JPEG, PNG, WebP, GIF, MP4, WebM, PDF |
| Reels / Stories | 20 MB; 60 sec video | JPEG, PNG, WebP, MP4, WebM; Story photos also max 5 MB |
| Voice notes | 1 MB; 60 sec | WebM, Ogg, MP4 audio |
| Profile photos | 512 KB processed | JPEG, PNG, WebP; the editor exports JPEG |
| Cover photos | 1 MB processed | JPEG |

Keep JPEG enabled for the photo editors and appropriate audio formats enabled for your students' browsers. Changes affect future uploads; they do not rewrite existing files. Rerunning the combined migration preserves your chosen limits.

Storage totals use stored-object metadata; they do not claim to show remaining plan quota or billing. Cleanup reviews at most 100 candidates per batch: expired Stories and unused post/profile/cover uploads. Unused uploads must be over a day old. Private chat files and open report evidence are excluded. Review the candidate list before deleting. Files are removed through the Storage API, not by deleting storage.objects rows directly. If cleanup stops, run Review again to get a fresh list. Existing Story-author cleanup also continues.

## Staff and activity log

Only the owner can appoint or remove a moderator, using an existing active username. Moderators can review submitted reports, remove public reported content, close listings and suspend/restore ordinary accounts. They cannot edit student details, suspend the owner/staff, change site settings, appoint staff, see owner totals, export backups or browse unreported private conversations. Role removal takes effect in the database immediately; an open interface may take up to 30 seconds to update.

The Activity log records administrative table changes and moderation decisions from installation onward. It stores actor, operation, target and timestamp, not private message bodies. The dashboard shows the latest 200 entries. Ordinary students cannot read it, and the web app cannot edit/delete log entries. A database/project administrator remains technically able to maintain the database directly; this is an application audit trail, not an external tamper-proof archive.

## Owner account protection

Security supports Supabase TOTP authenticator enrollment and verification. Verify the authenticator first, then select Require authenticator for owner controls. The database enforces AAL2 for the owner role and existing owner-only functions/policies; hiding buttons alone is not the protection. MFA is optional and OFF initially to avoid locking you out during installation. Enrollment must be enabled in your Supabase Auth configuration. No live owner enrollment has been performed for you.

After enabling the requirement, later password sign-ins can use the normal student interface but must verify the authenticator to unlock owner controls. Keep access to the owner email and your authenticator. Email password recovery alone does not bypass MFA. For a lost authenticator, recover the user's factors through Supabase administration. If a database administrator must perform emergency recovery, restore access from Supabase SQL Editor after verifying the owner, rather than putting any bypass key in the website.

Sign out my other sessions revokes the current account's other refresh sessions. Already issued access tokens can remain valid until expiry. Send my recovery email requests the existing Supabase password-reset flow. Configure the project's Auth Site URL/redirect URLs and reliable SMTP delivery before relying on recovery at scale.

Official references:
- https://supabase.com/docs/guides/auth/auth-mfa
- https://supabase.com/docs/reference/javascript/auth-mfa-enroll
- https://supabase.com/docs/reference/javascript/auth-mfa-challengeandverify
- https://supabase.com/docs/reference/javascript/auth-signout

## Backups and recovery

Download settings backup exports the current published appearance/text/feature settings as JSON. To restore, upload that settings file; it is saved as a draft. Inspect Branding, Texts, Features and related sections, then deliberately publish. Restoring this file does not change maintenance, owner MFA, staff roles, students or posts.

Export public site data includes profile records, settings, directory, communities, events, Reels/Stories metadata, listings, announcements and public posts/likes/comments. It excludes authentication credentials, private chats/voice/files and private report evidence, and contains file paths rather than media bytes. Treat exports as private administrative files. Large sites should use database tools rather than the browser JSON export.

For complete disaster recovery, separately back up the Supabase database and Storage files through your own Supabase project administration:
1. Keep this website package and its Git history.
2. Use your project's available database backup/export facilities or a PostgreSQL/Supabase CLI backup from your own computer. Include the schemas and roles required by Supabase; follow the current official backup/restore procedure. Do not paste the database password or service key into ChatGPT or put it in Git.
3. Back up Storage file bytes as well as metadata, recording each bucket and object path. A database dump alone is not a copy of uploaded media.
4. Store backup copies securely outside the live project, and periodically test restoring to a separate project before touching production.
5. Restore only after checking Auth identities, policies, file paths and application configuration against the target project. The dashboard does not offer a destructive one-click database restore.

## Validation and live checklist

Local PostgreSQL-compatible tests cover original migration/rerun and media/chat regressions; unique online counts; owner/moderator boundaries; participant-only private report submission and selected evidence access; targeted notices; maintenance restrictions; upload policies; database MFA gating; audit permissions; safe cleanup/evidence holds; and preserving chosen limits on rerun.

Local browser tests use a mock SDK and disposable data. They covered owner statistics, student search, report review/resolution, announcements, maintenance settings, saving upload limits, authenticator setup/verification UI, moderator appointment, activity log, existing branding access, private-report consent and My reports. Settings backup download passed; the browser file picker was unreliable for restore. The actual import code passed separate tests for valid draft-only restoration and rejection of malformed/oversized backups. These tests do not prove a real TOTP code, SMTP delivery, live Storage integration or physical-phone compatibility.

After installing, test with the owner, a moderator and two ordinary accounts: verify counts; create a targeted notice; submit one selected private message and voice-note report; confirm the owner sees that evidence but no unrelated conversation; suspend/restore a student; enable/disable maintenance; try a file over a reduced limit; export/import a settings draft; and enrol/verify the owner's authenticator before enabling its requirement. Test the earlier Reels, Stories, covers and messaging features too.


## Student experience controls

Verification lists affiliation requests and lets the owner record an approval/rejection reason. Configure only official school-controlled email domains; never add a public email provider. School-email badges depend on current confirmed primary email and the configured domain. Reviewed badges reflect the owner's review and are not identity guarantees.

Academic hubs lets the owner archive/reopen hubs. Archiving stops new contributions; it does not expose member discussions to the owner. Members can report individual hub posts/replies for review.

Account requests lists students who asked for deletion and are deactivated. This release queues deletion for manual handling; it does not offer automatic Auth/Storage/database erasure. Before completing a request, review report-evidence retention and database foreign-key dependencies. Removing an Auth identity alone is not a complete erasure workflow. Use a tested administrative cleanup process in your own Supabase project, including stored file bytes and application records; do not mark a request complete before that work succeeds. Students can cancel the request and reactivate until processing is completed. Never put a service role key in website files.

The public-data export now filters profiles, posts/interactions and media through their visibility rules. Private birthdays, user settings, collaboration preferences, private hub content and private conversations are excluded. Students' personal exports contain their own settings/profile and content, relevant conversation data and media metadata, not passwords or media file bytes. Treat these exports as private files.


## Update 12: direct messages and posting fix

Direct one-to-one messages no longer require approval. Each recipient's messaging preferences, blocks and active account status still apply. Opening a direct chat creates or reuses a participant-only conversation record. Group invitations remain opt-in. Online markers reveal presence only for students who enable sharing; owner usage statistics retain their existing administrative purpose.

The posting fix corrects INSERT RETURNING access checks and does not disable RLS or permit impersonating another post owner. If the old error is still displayed, ensure the latest combined SQL completed and the entire latest website folder reached the deployment. Check owner feature switches, account status and maintenance state rather than disabling RLS.


## Performance update 13

Startup now obtains current account/access information in one authenticated request. The fast bootstrap has no target-user parameter and returns only the caller's own profile, settings/preferences and state. Feed pages execute under the caller's normal RLS permissions, preserve post audiences and blocks, and fetch a maximum of 16 metadata rows (15 displayed plus a next-page check). Three indexes support chronological, author and campus feeds.

Caches are short-lived, account-scoped and in-memory. Sign-out clears them and invalidates pending data responses. Permission decisions still come from Supabase, not from a cached browser role. Administrative draft loading is deferred until the owner opens the dashboard. No student data or existing media is deleted by update 13.

For a real timing check after installation, use the same account, device and connection before/after a hard refresh. Separate password/email-confirmation time from the time after successful authentication. Avoid treating the controlled local benchmark as a live service guarantee.


## Update 14: larger upload limits
Owner dashboard → Upload limits accepts higher KB values without UniChat's old category maximums. Existing limits stay unchanged until you save. Supabase Storage's project/global limit must also permit the chosen size; this does not make storage or bandwidth unlimited. Supported formats and duration limits remain enforced.


## Custom student-entered institution and department
Students can choose “My Institution isn't Listed” or “My Department isn't Listed” at signup or when editing their profile. Their typed names are saved on their own profile. The shared school directory remains owner-managed; review and add recurring names through Directory if appropriate. This does not verify institutional affiliation.
