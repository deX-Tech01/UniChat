# Latest release — Update 15

This is the COMPLETE package: the original website and all upgrades through 15. It has not been deployed to your live site.

## Install on your existing site

1. Run `supabase/UniChat_Combined_Upgrade.sql` in the existing Supabase project's SQL Editor. Keep Row Level Security enabled. This preserves accounts and content. Do not rerun `UniChat_Setup.sql` on your existing project. If Updates 02–14 already completed successfully, `UniChat_Update_15.sql` alone is sufficient; run one route, not both.
2. Copy **every file inside `website/`** into `website/` in your existing VS Code Git repository, replacing matching files and including the new `campus-social.js` and `campus-social.css`. Keep `app.js`, all other existing scripts, and your repository's `.git` folder. Avoid a nested `website/website` folder.
3. From your repository root, commit and push:

```bash
git add website supabase SETUP.md INSTALL_UPDATE.md OWNER_GUIDE.md
git commit -m "Add marketplace photos, group pictures, sharing and tag notifications"
git push origin main
```

4. Wait for Vercel to finish deploying, then refresh. Keep Vercel Root Directory as `website`, Framework Other and Output Directory `.`; no build/install command is needed.

## Included in this release

- Marketplace listings can include one product photo. Choose from the gallery, preview, drag with one finger to position and pinch with two fingers to zoom before saving. Desktop users can drag and use the mouse wheel. Edit/replace/remove the photo later. The poster can delete their own listing after confirmation; the owner can also moderate/delete it. Deletion is permanent.
- Communities have a creator-managed identifying picture, set when creating or editing the community. Academic hubs have the same editor during creation and a **Change group picture** action for the creator/owner. Existing groups without pictures continue to work.
- Photos are cropped to a 4:3 marketplace image or a square group image and exported as JPEG. New private storage category **Marketplace / hub / community pictures** defaults to 5 MB per processed photo. The owner can raise it in Upload limits, subject to Supabase's own limits. Existing owner limits are preserved. Gallery options and supported source formats depend on the device/browser.
- Post Share opens a panel with **Send to a student on UniChat**, Facebook, WhatsApp, Telegram, email, copy link and the device's native share menu where supported. Shared chat posts include a View shared post button. Shared links open their exact post, including older posts outside the first feed page. A link requires sign-in and preserves its audience; sending inside UniChat checks that both students can view it and that messaging is allowed. YouTube does not have a general website share endpoint: copy the link into your own YouTube description or post where links are supported.
- Type `@` in a post, comment, reply or their edit fields to find visible students by name/username. Select a suggestion to insert their exact `@username`. New tags notify the selected student after saving; self-tags, blocks, inactive accounts and inaccessible post audiences do not generate tag notices. At most 20 distinct usernames are considered per item. Editing can notify newly tagged students, with at most one tag notice per author/student/item to avoid repeated edit spam. Display names with spaces are not usernames.
- Notifications show who followed you, tagged you, liked a post, commented, replied or messaged. Follow-request actions remain available where enabled. Open a notification to reach its post/profile/conversation. There are All/Unread filters, individual read actions, Mark all as read, older notification pages and a real unread badge. Realtime updates are used when connected, with a periodic refresh while the page is visible. This is an in-app inbox, not browser push or email delivery.
- Signup and Edit profile retain missing-institution/department entry. **Choose Department** is the default for a new blank department, including an institution with no saved departments.

Photo paths and creator permissions are checked in the database, not only by hidden buttons. Images use expiring private signed URLs. Already downloaded pictures cannot be recalled. Replaced/deleted photos are removed when the uploader's orphan-cleanup request succeeds; a network failure or an owner replacing another student's picture can leave an unlinked object for manual Storage cleanup. Do not delete database `storage.objects` rows directly.

Validation covered existing SQL regressions, repeated migration application, creator-only pictures/deletion, owner limits, audience-safe sharing, tags in posts/comments/replies/edits, blocked recipients, private notifications and unread counts. Local browser checks used disposable mock accounts for photo selection/cropping/display, listing deletion, community pictures, hub creation, sharing, mention selection and notification destinations. Test actual two-finger gestures and the native share menu on your own phone after installation; the desktop browser check cannot exercise every mobile gallery/share sheet.

Earlier release notes follow for reference; where they describe older fixed upload sizes, those are defaults, not the latest owner-configurable ceilings.

---

# Custom institution and department entry — Update 14.1

This is a website-only update. If your database already has Update 14, no new SQL is needed.

1. Copy the complete `website` folder into your existing UniChat Git repository and replace matching files. This update changes `app.js` and `priority-upgrades.js`.
2. Commit and push to your usual main branch; wait for Vercel to finish deploying, then refresh the site.
3. Signup and Edit profile now offer **My Institution isn't Listed** and **My Department isn't Listed**. Selecting either reveals a required text field. Students may enter a missing department even at a listed institution.

Typed names are stored as the student's institution/department. They do not grant directory-editing permissions or automatically add entries to everyone's signup dropdown. Owners continue to manage the shared Directory. Existing profile names, including names outside the current directory, are preserved when editing. Selecting a different institution clears the previous department so the student can make a new choice.

All previous features and SQL upgrades remain included below and in the package.

---

# Update 14 — responsive loading and owner upload sizes

1. Run `supabase/UniChat_Combined_Upgrade.sql` in the existing Supabase project's SQL Editor. This preserves accounts and content; it does not disable RLS. For a project already on Update 13, Update 14 alone is sufficient.
2. Copy the **entire website folder** into your existing repository, including performance.js, responsive.js, and the updated index.html. Commit and push to your usual main branch. Keep Vercel Root Directory as website.
3. Refresh the deployed page after Vercel finishes. In Owner dashboard → Upload limits, enter the maximum KB and save (1024 KB = 1 MB). For example 102400 KB = 100 MB. Existing selected sizes are preserved until you change them.

The owner form and database no longer cap sizes at the old 1/5/10/20 MB values. Supabase project/global upload limits, available storage, bandwidth, and device/browser limits still apply; adjust the project's Storage upload limit in Supabase too if necessary. Raising UniChat's limit cannot override the hosting service. Supported file types and the existing 60-second maximum duration remain enforced. New values are checked as accurately representable whole bytes.

Chats paint immediately and fetch the newest 30 mixed messages in one server request. Load earlier messages retrieves older pages. Text, voice recording/playback, image/video previews, PDFs, replies, search, reporting, privacy, blocks and opt-in online/read status remain supported. Drafts and playing media survive background refreshes. Session-only caches avoid repeated work; writes and realtime updates invalidate them. Cached data is cleared at sign-out. Loading data still requires network time; a first visit on a slow connection is not instantaneous.

The package includes all original files and upgrades. Database testing uses local PostgreSQL-compatible fixtures; browser testing uses mock accounts, not your production messages.

---

# Performance update 13 — faster sign-in and first load

This is the COMPLETE UniChat package, containing the original website and every upgrade through 13. It has not been deployed to your live site.

## Apply this update

1. Run **supabase/UniChat_Combined_Upgrade.sql** in Supabase SQL Editor. If upgrades 02–12 already completed successfully, you can instead run **supabase/UniChat_Update_13.sql** only. Do not run both, and do not rerun Setup on an existing project.
2. Copy **every file inside website/** into the website folder in your original VS Code Git repository. Replace existing files and include the new **performance.js** and **performance.css**. Avoid website/website and keep your existing .git folder.
3. Commit and push, wait for Vercel Ready, then hard-refresh the page.

```bash
git add website supabase SETUP.md INSTALL_UPDATE.md OWNER_GUIDE.md
git commit -m "Speed up UniChat startup and feed loading"
git push origin main
```

## What is faster

- The sign-in completion path now makes one authenticated bootstrap request for your own profile, current role/maintenance settings, preferences and personal state. It no longer loads that same account/feed twice before showing the home screen.
- Your account shell and composer appear first. A separate bounded request loads the first **15 posts**, then **Load more posts** adds another page. The query fetches one extra metadata row to determine whether another page exists. Tied timestamps use an ID cursor to prevent duplicates.
- Campus, Following, your own posts, other student posts and bookmarks use server-filtered pages. Own profile post/community totals come from the database rather than the number of currently loaded posts.
- Notifications, Stories, birthday reminders, announcements and student suggestions no longer block first display. Communities, event/member lists and group chats load when their sections are opened.
- Simultaneous requests for the same data or signed media URL share one pending request. Short-lived caches stay in memory and are scoped to the signed-in account. Sign-out clears them; late responses from an older account/session are rejected. No new private-profile or message cache is saved to localStorage.
- One debounced realtime channel refreshes relevant sections instead of several overlapping handlers reloading the entire account. Owner access/maintenance checks and presence heartbeats remain active. Message history and read state remain protected by Supabase rules.
- The feed does not wait for signed image/video URLs. It shows media placeholders and requests those URLs near the viewport. Repeated avatar URL requests are coalesced. Videos retain explicit controls in posts and muted active-video playback in Reels.
- Large post photos are resized to a maximum long edge of 1600 px and compressed when that makes the file smaller. PNG/WebP transparency is retained; animated GIFs are preserved. Video transcoding and server-side video thumbnails are not included.
- Scripts download in parallel using ordered defer attributes. Loading placeholders and retry states replace a blank initial screen. A secondary feature failing does not undo a successful sign-in.

## Measured checks and limitations

A local browser comparison used identical disposable data and a simulated **60 ms delay per SDK request**. The previous version made **26 data calls before the home shell appeared**, taking about **1298 ms** in that run. The revised path made **1 call before the shell**, taking about **134 ms** (a repeat measured about 113 ms). These are controlled local tests of session restoration/sign-in completion, not a measurement or promise of your live Supabase, password-authentication, email confirmation or Nigerian mobile-network latency.

The revised feed initially rendered 15 posts. Loading more produced 30 distinct posts with no duplicates; switching to My Campus showed only the campus result. Browser checks also covered own-profile totals, chat loading on demand, sending a message, and returning to the feed. A 2400×1600 JPEG of 4,197,610 bytes was resized to 1600×1067 and approximately 912 KB, then published and displayed through the lazy media path.

PostgreSQL-compatible tests passed original-data preservation/reruns, earlier owner/media/messaging/privacy regressions, bootstrap user isolation, private preferences, 15+1 feed bounds, stable cursors, profile/audience visibility, maintenance restrictions and anonymous denial. Separate cache tests passed request coalescing, expiry, mutation invalidation, retry after failure and rejecting a late private response after switching accounts.

After installation, test sign-in and signup on your own phone and connection. Supabase response times, project availability, email delivery and media sizes still affect actual loading. This update does not move your database, change plans, add a paid service or alter hosting.

---

# Latest update: chat, posting and media refresh

**This is the COMPLETE package: original website plus all updates through 12.**

1. Run `supabase/UniChat_Combined_Upgrade.sql` in Supabase SQL Editor. Existing projects do not need to run Setup again. Keep Row Level Security enabled. If upgrades 02–11 already completed successfully, running only `UniChat_Update_12.sql` is also supported.
2. Copy **all files inside this ZIP's website folder** into the original repository's website folder. Replace existing files. Include both new social-refresh files; do not create website/website. Keep your existing .git folder.
3. Commit and push the website and SQL changes. Wait for Vercel Ready, then hard-refresh.

```bash
git add website supabase SETUP.md INSTALL_UPDATE.md OWNER_GUIDE.md
git commit -m "Fix posting and refresh UniChat chat and media"
git push origin main
```

### What changed in update 12

- Fixed the reproduced `new row violates row-level security policy for table unichat_content` when a new post is inserted and immediately returned by the SDK. The SELECT policy now checks the new row's author directly. Other viewers still require the post audience check. RLS remains enabled.
- One-to-one chats open directly: no message-request approval step. Blocks, suspension, maintenance, messaging feature switches and recipient privacy preferences remain enforced in Supabase. Existing conversations are preserved. Group chat invitations still require acceptance.
- Messenger-style chat list, selected conversation panel, student search, media bubbles, typing/delivery/read indicators and green Active now markers. Existing students' active-status choices are preserved. Enable **Settings → Show my online status** to share your status; hidden status is not falsely shown as offline. Active status is refreshed about every 15 seconds and uses recent visible-tab heartbeats, not exact continuous presence.
- Photos/videos preview in the post composer and published feed. Chat image/video previews load when near the visible conversation area; PDFs remain document links. Upload limits still apply and can be managed by the owner.
- More is now a full **Menu page**, with feature tiles and five primary mobile tabs. It is not a collapsible dialog.
- Followers and Following open a full searchable Connections page with avatars, profile links, follow buttons and pagination. Own-profile Posts and Communities counts are also clickable.
- Reels and Stories buttons immediately open a photo/video-only native picker, then show a visual preview and caption before sharing. Mobile OS/browser determines whether this appears as Photos, Gallery or a file picker; a website cannot force a particular phone gallery app. Desktop browsers normally use a file dialog. Common browser-decodable nonstandard photos are converted to JPEG; unsupported formats ask for a standard JPEG/PNG or MP4 export.
- Reels use a vertical scroll-snap feed: the visible video plays muted, the previous one pauses, with explicit pause/sound/next controls. Stories have a full-height viewer, progress bars, previous/next tap zones, pause and sound controls; video Stories start muted. Browser autoplay settings may require a tap. Video files are not transcoded on the server.
- Removed the Supabase-powered banner and obsolete preview notices.

### Verification

Local PostgreSQL-compatible tests reproduced the original post INSERT RETURNING failure and passed after the policy fix, including photo posts. Tests also passed direct chat without acceptance, idempotent conversation creation, participant-only private history, blocks/nobody messaging preferences, active-status privacy and the earlier migration/owner/media/comment/birthday/matching regressions. The combined migration was applied twice to test reruns.

Browser QA used a disposable local mock SDK. Checked: direct chat open/send with no request UI; green online marker; image inside a message; full Menu page; clickable Followers page; selecting a photo and showing its composer preview; publishing its photo post; direct Reel picker, video preview and upload; Reel autoplay and next-video scrolling with the previous video paused; Story image viewer and tap controls. Physical Android/iPhone picker behavior and live Supabase Auth/Storage/Realtime remain to be checked after installation. The package does not contain the mock SDK or test media.

---

# UniChat combined upgrade

This package combines upgrades 02–12. It is prepared for the original live version. Existing accounts, posts and branding are preserved. No changes have been applied to your live project by this package.

## Install once when ready

1. In Supabase SQL Editor, run the entire supabase/UniChat_Combined_Upgrade.sql. You do not need to run the individual numbered upgrades as well. Only a fresh project needs UniChat_Setup.sql first.
2. Extract the package and copy all files in website/ into website/ in your existing VS Code repository. Keep your repository's .git folder. Include features.js, voice-discover.js, photo-crop.js, priority-upgrades.js, social-media.js, owner-controls.js follow-lists.js, student-experience.js, inline-comments.js, messaging-experience.js student-experience.css, social-refresh.js and social-refresh.css.
3. From the repository root:

```bash
git add website
git commit -m "Add UniChat student matching, privacy and inline comments"
git push
```

4. Wait for Vercel to report Ready, then hard-refresh https://unichatt.vercel.app/.

Vercel: Root Directory website; Framework Other; Output Directory .; Build and Install Commands empty.

## Owner dashboard additions

Overview shows registered accounts, completed profiles, unique online students, new/active users today and school/department totals. Added searchable student management, a unified report queue, targeted announcements, maintenance mode, adjustable upload policies, moderator roles, an administrative activity log, optional owner authenticator protection, session/recovery actions, storage review/cleanup, settings backup/draft restore and public-data exports. Read OWNER_GUIDE.md for operation and live verification.

Private reports share only the item a participant explicitly selects; the Privacy & blocks screen explains this. There is no general owner private-chat browser. Full Auth administration and complete database/media disaster recovery remain in Supabase, outside the dashboard. MFA is not enabled for you automatically.

## Included upgrades

- Viewable student profiles, shareable profile links, follow counts, shared connections (people both students follow), and optional cropped profile photos at signup or later from Profile.
- Private one-to-one voice notes; image, video and PDF attachments; replies to direct text messages; accepted-invitation group chats with text and files.
- Owner-managed school and department directory; discovery filters for school, department and level. Existing profile wording is preserved. Owner dashboard → Directory can import existing school labels for review.
- Clickable @username mentions, threaded post-comment replies, and an in-app notification inbox for activity and message requests.
- Student opportunities (internships, scholarships, jobs and competitions) and a campus marketplace. Students manage their listings; the owner can moderate them. Marketplace payments and application processing are not included.
- Previous communities, discussions, events, RSVPs, message requests, blocking and owner layout controls remain.

## Reels, Stories and cover photos

- Reels: MP4 or WebM video uploads, up to 60 seconds and 20 MB, caption, vertical feed, likes, comments, sharing a direct Reel link and creator caption editing/deletion. Videos load only when Play Reel is selected; off-screen videos pause. Uploading a pre-recorded video is supported; there is no camera editor, music library, video trimming or recommendation algorithm.
- Stories: JPEG, PNG or WebP photos up to 5 MB, or MP4/WebM videos up to 60 seconds and 20 MB. Open Stories from Home or navigation. View in sequence, pause/resume, or move previous/next. Photo Stories advance after seven seconds; videos use play controls. Expiry is assigned by the database at publication, 24 hours later. Normal student reads and new signed URLs are denied after expiry. A file already downloaded or saved by a viewer cannot be recalled.
- Cover photos: Profile → Add / change cover photo. Choose a JPEG, PNG or WebP under 10 MB, zoom/reposition to a 3:1 banner, then save. The processed JPEG is at most 1 MB. Change or remove it later; it is visible on student profiles.
- Owner dashboard → Reels & Stories lets you preview, edit captions and delete public student media. Owner dashboard → Features includes Reels and Stories switches. This does not change private chat access.

Reels/Stories use the separate private unichat-social-media bucket; profile covers use unichat-covers. Existing post uploads keep their original bucket and limits. Supabase storage/download quotas still apply. There is no server-side video transcoding; standard MP4/H.264 is the most portable choice. Duration is checked by the browser and constrained as declared metadata in the database, not analysed from the video by a media server. Stored upload size/type are cross-checked when Supabase object metadata is available.

Expired Stories disappear from student views automatically. Their files are removed in batches when their author next signs in or opens Stories; this is not a continuously running storage-cleanup service. Inactive authors' expired files can continue using storage. The owner can remove leftover files from Supabase Storage. Failed deletion cleanup can also leave unused files there.

## Followers and Following

Tap Followers or Following on your Profile, or on another available student's profile, to open the full list. Each entry shows a photo/initials, name, username, school and department. Tap the photo/name to open that profile, or use Follow / Follow back / Unfollow. Your own row is marked You and has no follow button. Unfollowing someone in your own Following list removes that entry and updates the counts.

Search connections by name, username, school or department. Load more retrieves 25 students at a time. Counts and lists query the database rather than relying on the limited discovery cache. They require sign-in and omit blocked/suspended accounts from the displayed results; counts reflect the available profiles for the viewer. Maintenance restrictions remain in force.

Download and run the UPDATED combined SQL for this addition, even if you already ran the earlier combined file. It adds read-only list/count helpers and an index while preserving existing follows. The combined file includes all previous upgrades; do not run each numbered update separately. Copy follow-lists.js with the rest of website/.

## Profile photo gestures

Profile pictures now use direct manipulation instead of position/zoom sliders. Drag with one finger to reposition and pinch with two fingers to zoom. On a computer, drag with the mouse and zoom with its wheel. Reset crop recentres the photo. The same editor opens for the optional signup photo; Use this photo stages the selected crop until confirmed sign-in. The saved square crop matches the circular preview. Cover-photo controls are unchanged.

The gesture editor itself needs no SQL changes. The included latest combined migration also installs the follower-list helpers required by this package. Include the new photo-crop.js file when copying website/.

## Profiles and uploads

Profile affiliations are self-reported. The school directory is configured by the owner; it does not certify enrolment. Photos are cropped and resized to JPEG before upload. When signup requires email confirmation, the optional photo is held on that browser for up to 24 hours and uploaded after sign-in and profile completion. If confirmation occurs elsewhere, add the photo later from Profile.

Chat attachments support JPEG, PNG, WebP, GIF, MP4, WebM and PDF, up to 10 MB each. Files use private storage and expiring signed URLs. Voice notes currently belong to one-to-one conversations, not group chats. Group invitations are limited to accepted direct contacts and must be accepted before reading the group.

Private messages, voice notes and chat files remain participant-only; the owner receives no special access to other conversations. In-app notifications do not include push notifications or email delivery. Voice/video calls have not been added.

## Voice notes

Open an accepted conversation → Record voice note. Allow the microphone when your own browser asks. Stop, preview, send or discard. The recording stops automatically after one minute, and stops when the browser page is hidden. Navigating away or signing out discards an unsent recording. Received recordings load on demand to reduce data use. Playback uses native audio controls, including seek/progress and duration where supported.

Recordings use compressed WebM/Opus, Ogg/Opus or MP4/AAC according to browser support, with a 32 kbps target requested from the browser. The browser may choose a different rate. Each upload is capped at 1 MB. The one-minute limit is enforced in the recording UI and declared duration is constrained in the database; there is no server-side audio transcoding or duration analysis.

Files are in the private unichat-voice bucket. Participants can read sent recording metadata or request a signed file URL. When a participant explicitly reports a selected recording, the owner/moderators can review that recording through its report; they cannot browse the rest of the conversation. Signed playback links last 15 minutes. A message request must be accepted before a voice note can be uploaded or sent. Blocks prevent new notes in both directions, while existing stored history remains. Failed sends attempt to remove the unused uploaded file; if network cleanup fails, an unused file may require later storage cleanup.

Voice notes consume your Supabase storage and download allowances. They have no separate call-provider charge, but usage is not unlimited or guaranteed to remain free. Test on your actual Android/iPhone/browser combinations. No voice/video calling was added.

## Validation and deployment checks

Local PostgreSQL-compatible checks passed for upgrading the original database, rerunning the combined migration, preserving accounts/posts/branding, existing private-chat rules, Reels author isolation/likes/comments/counts/moderation, Story expiry and blocked access, cover upload ownership/removal, and anonymous isolation. All website JavaScript syntax checks passed.

Local browser tests used mock Supabase responses and disposable fixtures. They covered Reel file selection/preview/publication/playback, likes/comments, Story photo selection/publication/viewing, cover crop/reposition/save, owner moderation UI and feature switches. These tests are not a live Supabase integration test or a physical-phone compatibility check.

After deployment, sign in with two confirmed student accounts. Upload a short MP4 Reel, like/comment/share its link, publish a photo/video Story and change/remove a cover photo. Check viewing from the second account. Check the owner moderation panel. Also verify the earlier upgrades: profile photo save/remove; image/video/PDF in accepted conversations; voice-note preview/send/playback; group invitation/acceptance/files; mentions/replies; directory settings and listings. Use an unrelated third account to verify private chats remain inaccessible. Test on your actual Android/iPhone browsers before inviting many students.

Owner-control SQL and UI checks, setup limits and the settings-import verification limit are detailed in OWNER_GUIDE.md.

Gesture checks cover pinch anchoring, bounds, cancellation and preview/export alignment. Local browser checks passed for file selection, dragging, keyboard zoom, save and signup crop staging. Physical touch gestures still need checking on your Android/iPhone.

Follower-list validation: local database checks passed for complete pagination/search, current follow states, visibility filters and maintenance/anonymous denial. Local mock-browser checks passed for own/other-profile counts, photos, loading all pages, search, follow-back, unfollow/count updates, profile links and empty states. Verify these on your live Supabase project after installation.


## New student experience upgrade (08–11)

- **People for you** explains suggestions using school, department, courses and interests. Set preferred school/department in Settings; blank means all. Matching uses database rules, with no external AI service.
- **Study partners** lists students who opt in and have compatible online/on-campus preferences. Shared courses and available days/periods improve ranking. Start an approved private conversation to agree on a session; this is not a booking calendar.
- **Course & department hubs** are student-created academic circles. Search, join, ask questions, share resource links, discuss, reply, edit/delete your posts, and leave. Hub content requires membership. Creators and the owner can archive hubs. Latest 300 hubs, 50 posts per hub and 100 replies per post are shown.
- **Settings** contains birthday sharing, profile/post visibility, message eligibility, follower approval, online/read-status choices, school/department preferences and study/collaboration details. Comments made in someone else's discussion follow that discussion's audience. Existing posts keep the Students audience until their author changes it. New posts use the chosen default or composer audience.
- **Birthday** is required in the new signup form. Existing students can add it in Settings. It is stored outside public profile JSON and is private by default. Choose Private, Day/month only, or Full date. Mutual followers with visible shared birthdays appear on Home for the coming week. Today's birthday generates a deduplicated in-app notification; reminders never include a birth year. Turning off birthday reminders hides the banner and prevents new reminders.
- **Inline comments** replace the comment popup for posts and Reels, using an outlined speech-bubble icon. Like/reply to comments, including your own; edit/delete your own comments and replies. Load comments and replies in pages of 20. Post authors can edit text/audience or delete their post and its comments through the post options. Existing post media is preserved when editing text.
- **Better messaging** adds conversation search, unread badges, typing indicators and sent/delivered/read labels. Delivery/read state advances when a recipient opens the conversation. Read status is shown only when both participants opt in; online status is opt-in. Text search retrieves 25 results per page. Voice notes/files/group chats remain included; calling remains postponed.
- **Matched opportunities** uses school, department, level and interests/skills. Listings can specify department, levels and tags. Save opportunities to receive one in-app notice when you visit within three days of the deadline. There are no email or push birthday/deadline reminders in this package.
- **Collaboration profiles** show skills, interests, courses, goals and optional projects with links and teammate needs. Set discovery participation separately from profile visibility.
- **Optional verification** supports confirmed primary email addresses at exact owner-configured institution domains, or owner affiliation review with a note/public link. No ID-document collection is built in. Badges describe what was checked and do not guarantee identity or enrolment. Changing school invalidates the badge; school-email badges also require the current confirmed email/domain to remain valid.
- **Account self-service** includes JSON data export, password recovery, revoking other refresh sessions, deactivation/reactivation and a cancellable deletion request. Deletion requests hide the account immediately but require manual owner processing; they do not erase data automatically. Existing access tokens expire normally after session revocation. Owner accounts cannot deactivate themselves.
- On phones, use **More** in the bottom navigation to reach the new pages.

Owner dashboard adds Verification, Academic hubs and Account requests. Owner Features also includes suggestions, study matching and hubs. Published feature changes use the existing draft/publish workflow.

### Checks completed

PostgreSQL-compatible tests apply the combined migration twice over original accounts/posts/branding and verify existing owner/media/chat/follow regressions. New checks cover private DOB and year hiding, reminder deduplication, post audiences/report privacy, follow approval, comment ownership/replies/reactions, messaging policies/read receipts/search, matching opt-in, hub membership, verification permissions, personal export and account lifecycle permissions.

Browser checks with a local mock SDK covered inline author replies, liking/editing a reply, saving day/month birthday sharing, mobile navigation, explained study suggestions, joining a hub and posting a question. These checks do not substitute for testing real Supabase Auth/Storage/Realtime, email delivery or a physical phone. After installing, use two ordinary test accounts to verify birthday/privacy sharing, following approval, comments, messages and hubs before inviting students.
