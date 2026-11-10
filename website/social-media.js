/* Reels, Stories and cover photos. Uses the existing Supabase student session. */
const mBucket = 'unichat-social-media';
const mTypes = {'image/jpeg':'jpg','image/png':'png','image/webp':'webp','video/mp4':'mp4','video/webm':'webm'};
let mRows = new Map(), mStats = new Map(), mReels = [], mStories = [], mOffset = 0, mMore = true;
let mPageToken = 0, mDraft = null, mCover = null, mBusy = false, mObserver = null;
let mStoryItems = [], mStoryIndex = 0, mStoryTimer = null, mExpiryTimer = null, mStoryPaused = false, mStoryToken = 0;
let mStoryRefresh = null, mCoverCache = new Map(), mCleanupRunning = false;

function mError(e) { return xError(e); }
function mAvailable(kind) { return cfg.features?.[kind === 'reel' ? 'reels' : 'stories'] !== false; }
function mPauseVideos() { document.querySelectorAll('.m-reel video,.m-story-stage video').forEach(v=>v.pause()); }
function mStopStory() { clearTimeout(mStoryTimer);clearTimeout(mExpiryTimer);mStoryTimer=null;mExpiryTimer=null;++mStoryToken; }
function mCleanDraft() { if(mDraft?.url)URL.revokeObjectURL(mDraft.url);mDraft=null; }
function mCleanCover() { if(mCover?.url)URL.revokeObjectURL(mCover.url);mCover=null; }
function mStudent(id) { return students.find(u=>u.id===id) || (id===authUser?.id ? {id,data:session.profile,username:session.profile.username} : {id,data:{name:ucPerson(id)}}); }
function mOwn(row) { return row.author===authUser.id || session.admin; }
function mAuthor(row) { const u=mStudent(row.author);return '<button class="row m-author" onclick="xViewProfile(\''+row.author+'\')">'+xAvatarHTML(u)+'<span><b>'+esc(u.data.name||'Student')+'</b><small>'+esc(u.data.school||'')+'</small></span></button>'; }

function mNavLinks() {
 if(!session?.profile)return;
 for(const [name,label,icon] of [['Reels','Reels','▷'],['Stories','Stories','◉']]) {
  if(!mAvailable(name==='Reels'?'reel':'story'))continue;
  if(!document.getElementById('m-nav-'+name))$('#nav').insertAdjacentHTML('beforeend','<button id="m-nav-'+name+'" class="'+(page===name?'active':'')+'" onclick="go(\''+name+'\')"><i>'+icon+'</i>'+label+'</button>');
 }
 if(!$('#m-mobile-reels')&&mAvailable('reel'))$('#mobile').insertAdjacentHTML('beforeend','<button id="m-mobile-reels" onclick="go(\'Reels\')"><i>▷</i>Reels</button>');
}
const mOldNav=nav;nav=function(){mOldNav();mNavLinks()};
const mOldGo=go;go=function(p){mPauseVideos();mStopStory();mObserver?.disconnect();++mPageToken;if(p!=='Reels'&&location.hash.startsWith('#reel='))history.replaceState(null,'',location.pathname+location.search);mOldGo(p)};

function mReelCard(row) {
 const stat=mStats.get(row.id)||{likes:0,comments:0,liked:false};
 return '<article class="card m-reel" id="m-reel-'+row.id+'">'+mAuthor(row)+
 '<div class="m-reel-stage" id="m-player-'+row.id+'"><div class="m-play-cover"><span class="m-play-symbol">▷</span><button class="primary" onclick="mPlayReel(\''+row.id+'\',this)">Play Reel</button><small>'+Math.ceil(row.size_bytes/1048576)+' MB · '+Math.ceil(Number(row.duration_seconds))+' sec</small></div></div>'+
 '<p class="m-caption">'+xRich(row.caption)+'</p><div class="m-actions"><button id="m-like-'+row.id+'" aria-pressed="'+!!stat.liked+'" onclick="mLike(\''+row.id+'\',this)">'+(stat.liked?'♥':'♡')+' '+stat.likes+'</button><button id="m-comment-count-'+row.id+'" onclick="mComments(\''+row.id+'\')">Comments · '+stat.comments+'</button><button onclick="mShareReel(\''+row.id+'\')">Share ↗</button>'+ (mOwn(row)?'<button onclick="mMediaOptions(\''+row.id+'\')">Manage</button>':'')+'</div></article>';
}
async function mReelPage(reset=true) {
 const token=++mPageToken;if(reset){mPauseVideos();mObserver?.disconnect();mOffset=0;mReels=[];mMore=true;$('#main').innerHTML=title('Campus in motion','Student moments, ideas and life across schools.')+'<div class="m-toolbar"><button class="primary" onclick="mComposer(\'reel\')">＋ Create Reel</button><button class="follow" onclick="go(\'Stories\')">Stories ◉</button><button class="follow" onclick="mReelPage()">Refresh</button></div><p class="small muted">Tap to play · Videos do not load until you choose them.</p><div id="m-reels" class="m-reels"></div><p id="m-feed-status" role="status">Loading Reels…</p>'}
 const moreButton=$('#m-more');if(moreButton)moreButton.disabled=true;
 try {
  const data=checked(await client.from('unichat_media').select('*').eq('kind','reel').order('created_at',{ascending:false}).order('id',{ascending:false}).range(mOffset,mOffset+11))||[];
  if(page!=='Reels'||token!==mPageToken)return;
  mMore=data.length===12;mOffset+=data.length;
  const rows=data.filter(r=>!ucBlocked(r.author));for(const r of rows){mRows.set(r.id,r);mReels.push(r)}
  $('#m-reels').insertAdjacentHTML('beforeend',rows.map(mReelCard).join(''));
  rows.forEach(r=>{const button=document.getElementById('m-like-'+r.id);if(button)button.disabled=true});mObserve();xPhotos();
  if(rows.length){const stats=checked(await client.rpc('unichat_reel_stats',{reel_ids:rows.map(r=>r.id)}))||[];if(page!=='Reels'||token!==mPageToken)return;stats.forEach(stat=>{mStats.set(stat.reel_id,stat);const like=document.getElementById('m-like-'+stat.reel_id),comments=document.getElementById('m-comment-count-'+stat.reel_id);if(like){like.textContent=(stat.liked?'♥':'♡')+' '+stat.likes;like.setAttribute('aria-pressed',String(!!stat.liked));like.disabled=false}if(comments)comments.innerHTML=eBubble+' '+stat.comments})}
  $('#m-feed-status').textContent=mReels.length?'':'No Reels yet. Share your first campus moment.';
  document.getElementById('m-more')?.remove();if(mMore)$('#main').insertAdjacentHTML('beforeend','<button class="follow" id="m-more" onclick="mReelPage(false)">Load more Reels</button>');
  mObserve();xPhotos();useConfig(cfg);
  const shared=location.hash.match(/^#reel=([0-9a-f-]{36})$/);if(reset&&shared)await mSharedReel(shared[1]);
 } catch(e){if(page==='Reels'&&token===mPageToken){$('#m-feed-status').textContent=mError(e);if(moreButton)moreButton.disabled=false}}
}
async function mSharedReel(id) {
 if(!document.getElementById('m-reel-'+id)){const row=checked(await client.from('unichat_media').select('*').eq('id',id).eq('kind','reel').maybeSingle());if(page!=='Reels')return;if(!row||ucBlocked(row.author)){toast('This Reel is unavailable.');return}mRows.set(id,row);const stats=checked(await client.rpc('unichat_reel_stats',{reel_ids:[id]}));if(stats?.[0])mStats.set(id,stats[0]);$('#m-reels').insertAdjacentHTML('afterbegin',mReelCard(row));xPhotos();mObserve()}
 document.getElementById('m-reel-'+id)?.scrollIntoView({block:'start',behavior:'smooth'});
}
function mObserve() {
 mObserver?.disconnect();mObserver=new IntersectionObserver(entries=>entries.forEach(e=>{if(!e.isIntersecting)e.target.querySelector('video')?.pause()}),{threshold:.45});document.querySelectorAll('.m-reel').forEach(el=>mObserver.observe(el));
}
async function mPlayReel(id,button) {
 const row=mRows.get(id),stage=document.getElementById('m-player-'+id);if(!row||!stage)return;
 button.disabled=true;button.textContent='Loading…';
 try {
  const data=checked(await client.storage.from(mBucket).createSignedUrl(row.storage_path,900));if(!stage.isConnected)return;
  mPauseVideos();const video=document.createElement('video');video.controls=true;video.playsInline=true;video.preload='none';video.src=data.signedUrl;video.setAttribute('aria-label',row.caption||'Student Reel');
  video.onplay=()=>document.querySelectorAll('.m-reel video').forEach(v=>{if(v!==video)v.pause()});
  video.onerror=()=>{stage.innerHTML='<p class="m-video-error">This video could not play. Try another browser or ask the creator to upload MP4.</p><button class="primary" onclick="mPlayReel(\''+id+'\',this)">Retry</button>'};
  stage.replaceChildren(video);await video.play().catch(()=>{});
 }catch(e){button.disabled=false;button.textContent='Retry playback';toast(mError(e))}
}
async function mLike(id,button) {
 button.disabled=true;try{const s=mStats.get(id)||{};if(s.liked)checked(await client.from('unichat_reel_likes').delete().eq('reel_id',id).eq('user_id',authUser.id));else checked(await client.from('unichat_reel_likes').insert({reel_id:id,user_id:authUser.id}));const stats=checked(await client.rpc('unichat_reel_stats',{reel_ids:[id]}));if(stats?.[0])mStats.set(id,stats[0]);const n=mStats.get(id);button.textContent=(n.liked?'♥':'♡')+' '+n.likes;button.setAttribute('aria-pressed',String(n.liked))}catch(e){toast(mError(e))}finally{button.disabled=false}
}
async function mComments(id) {
 mPauseVideos();modal('<h2>Reel comments</h2><div id="m-comments" class="m-comments" role="status">Loading comments…</div><form onsubmit="event.preventDefault();mSendComment(\''+id+'\',this)"><label>Your comment<textarea class="input" name="comment" maxlength="2000" rows="3" required></textarea></label><p class="small" id="m-comment-error" role="alert"></p><button class="primary">Post comment</button></form>');await mCommentList(id);
}
async function mCommentList(id) {
 const target=$('#m-comments');if(!target)return;
 try{const rows=checked(await client.from('unichat_reel_comments').select('*').eq('reel_id',id).order('created_at',{ascending:false}).limit(100))||[];if(!target.isConnected)return;target.innerHTML=rows.reverse().map(c=>'<div class="divider"><button class="x-profile-link" onclick="$(\'#modal\').close();xViewProfile(\''+c.author+'\')">'+esc(ucPerson(c.author))+'</button><p style="white-space:pre-wrap">'+xRich(c.body)+'</p><span class="small muted">'+esc(ucDate(c.created_at))+'</span>'+((c.author===authUser.id||session.admin)?'<button class="follow" onclick="mDeleteComment(\''+c.id+'\',\''+id+'\',this)">Delete</button>':'')+'</div>').join('')||'<p class="muted">Start the conversation.</p>';if(rows.length===100)target.insertAdjacentHTML('beforeend','<p class="small muted">Showing the latest 100 comments.</p>');const stats=checked(await client.rpc('unichat_reel_stats',{reel_ids:[id]}));if(stats?.[0]){mStats.set(id,stats[0]);const count=document.getElementById('m-comment-count-'+id);if(count)count.textContent='Comments · '+stats[0].comments}}catch(e){if(target.isConnected)target.textContent=mError(e)}
}
async function mSendComment(id,form) {
 const button=form.querySelector('button'),error=$('#m-comment-error');button.disabled=true;try{const body=form.elements.comment.value.trim();if(!body)throw Error('Write a comment first.');checked(await client.from('unichat_reel_comments').insert({reel_id:id,author:authUser.id,body}));form.elements.comment.value='';error.textContent='';await mCommentList(id)}catch(e){error.textContent=mError(e)}finally{button.disabled=false}
}
async function mDeleteComment(id,reel,button) {button.disabled=true;try{checked(await client.from('unichat_reel_comments').delete().eq('id',id));await mCommentList(reel)}catch(e){button.disabled=false;toast(mError(e))}}
async function mShareReel(id) {
 const url=location.origin+location.pathname+'#reel='+id;try{if(navigator.share)await navigator.share({title:'A Reel on '+cfg.name,url});else{await navigator.clipboard.writeText(url);toast('Reel link copied')}}catch(e){if(e.name!=='AbortError')toast('Share this link: '+url)}
}

function mComposer(kind) {
 if(!mAvailable(kind))return toast('This feature is paused.');mPauseVideos();mCleanDraft();
 modal('<h2>'+(kind==='reel'?'Create a Reel':'Add to your Story')+'</h2><p class="muted">'+(kind==='reel'?'Share a video up to 60 seconds and 20 MB.':'Photos up to 5 MB, or videos up to 60 seconds and 20 MB. Visible to signed-in students for 24 hours.')+'</p><form id="m-upload-form" onsubmit="event.preventDefault();mPublish(\''+kind+'\',this)"><label>Choose '+(kind==='reel'?'a video':'a photo or video')+'<input class="input" type="file" name="media" accept="'+(kind==='reel'?'video/mp4,video/webm':'image/jpeg,image/png,image/webp,video/mp4,video/webm')+'" onchange="mSelectMedia(this,\''+kind+'\')" required></label><div id="m-upload-preview" class="m-upload-preview"></div><label>Caption<textarea class="input" name="caption" maxlength="1500" rows="3" placeholder="What’s happening on your campus?"></textarea></label><p id="m-upload-status" class="small" role="status"></p><button class="primary" id="m-publish">'+(kind==='reel'?'Publish Reel':'Share Story')+'</button></form>');
}
async function mVideoDuration(file,url) {
 return await new Promise((resolve,reject)=>{const v=document.createElement('video');v.preload='metadata';const timer=setTimeout(()=>done(Error('Cannot read this video. Try a standard MP4 export.')),15000);function done(error,duration){clearTimeout(timer);v.onloadedmetadata=v.onerror=null;v.removeAttribute('src');v.load();error?reject(error):resolve(duration)}v.onloadedmetadata=()=>{const d=v.duration;if(!Number.isFinite(d)||d<=0||d>oLimit('unichat-social-media').seconds+.1)done(Error('Choose a video no longer than '+oLimit('unichat-social-media').seconds+' seconds.'));else done(null,Math.min(d,oLimit('unichat-social-media').seconds))};v.onerror=()=>done(Error('This browser cannot open the video. Try MP4 (H.264).'));v.src=url});
}
async function mSelectMedia(input,kind) {
 mCleanDraft();const file=input.files?.[0],status=$('#m-upload-status'),preview=$('#m-upload-preview');preview.replaceChildren();if(!file)return;
 const draft={file,url:URL.createObjectURL(file),duration:0,ready:false};mDraft=draft;status.textContent='Checking your file…';
 try {
  if(!mTypes[file.type]||(kind==='reel'&&!file.type.startsWith('video/')))throw Error('Choose a supported photo or MP4/WebM video.');
  if(!file.size||file.size>oLimit('unichat-social-media').bytes)throw Error('This file exceeds the owner upload limit.');
  if(file.type.startsWith('video/'))draft.duration=await mVideoDuration(file,draft.url);
  else await new Promise((resolve,reject)=>{const img=new Image();img.onload=resolve;img.onerror=()=>reject(Error('Cannot open this photo.'));img.src=draft.url});
  if(mDraft!==draft||!preview.isConnected)return;
  const el=document.createElement(file.type.startsWith('video/')?'video':'img');el.src=draft.url;if(el.tagName==='VIDEO'){el.controls=true;el.playsInline=true;el.preload='metadata'}else el.alt='Story preview';preview.replaceChildren(el);draft.ready=true;status.textContent='Ready · '+(file.size/1048576).toFixed(1)+' MB'+(draft.duration?' · '+Math.ceil(draft.duration)+' seconds':'');
 }catch(e){if(mDraft===draft){mCleanDraft();input.value='';status.textContent=e.message}}
}
async function mPublish(kind,form) {
 if(mBusy)return;const status=$('#m-upload-status'),draft=mDraft;if(!draft?.ready){status.textContent='Choose a file and wait for its preview first.';return}
 const id=xUUID(),path=authUser.id+'/'+kind+'/'+id+'.'+mTypes[draft.file.type];let uploaded=false,posted=false;
 mBusy=true;form.querySelectorAll('button,input,textarea').forEach(el=>el.disabled=true);$('#modal .close').disabled=true;$('#modal').oncancel=e=>e.preventDefault();status.textContent='Uploading… Keep this window open.';
 try {
  checked(await client.storage.from(mBucket).upload(path,draft.file,{contentType:draft.file.type,upsert:false}));uploaded=true;
  checked(await client.from('unichat_media').insert({id,author:authUser.id,kind,storage_path:path,mime_type:draft.file.type,size_bytes:draft.file.size,duration_seconds:draft.duration,caption:form.elements.caption.value.trim()}));posted=true;
  mCleanDraft();$('#modal').close();mRows.clear();go(kind==='reel'?'Reels':'Stories');toast(kind==='reel'?'Reel published':'Story shared for 24 hours');
 }catch(e){if(uploaded&&!posted)try{await client.storage.from(mBucket).remove([path])}catch{}status.textContent=mError(e)}
 finally{mBusy=false;form.querySelectorAll('button,input,textarea').forEach(el=>el.disabled=false);const close=$('#modal .close');if(close)close.disabled=false;$('#modal').oncancel=null}
}

async function mLoadStories() {
 const rows=checked(await client.from('unichat_media').select('*').eq('kind','story').gt('expires_at',new Date().toISOString()).order('created_at',{ascending:false}).limit(200))||[];
 mStories=rows.filter(r=>new Date(r.expires_at)>new Date()&&!ucBlocked(r.author));mStories.forEach(r=>mRows.set(r.id,r));return mStories;
}
function mStoryCircles(full=false) {
 const groups=new Map();mStories.forEach(r=>{if(new Date(r.expires_at)>new Date()&&!groups.has(r.author))groups.set(r.author,r)});
 return '<div class="m-story-strip"><button class="m-story-person" onclick="mComposer(\'story\')"><span class="m-story-ring m-story-add">＋</span><span>Your Story</span></button>'+[...groups.values()].map(r=>{const u=mStudent(r.author);return '<button class="m-story-person" onclick="mOpenStories(\''+r.author+'\')"><span class="m-story-ring">'+xAvatarHTML(u)+'</span><span>'+esc(r.author===authUser.id?'You':u.data.name||'Student')+'</span></button>'}).join('')+'</div>'+(!groups.size&&full?'<p class="muted">No Stories yet. Share a glimpse of your day.</p>':'');
}
async function mStoriesPage() {
 const token=++mPageToken;$('#main').innerHTML=title('Campus Stories','Little moments. New connections. Here for 24 hours.')+'<div id="m-stories-loading" class="card">Loading Stories…</div>';
 try{await mLoadStories();if(page!=='Stories'||token!==mPageToken)return;$('#main').innerHTML=title('Campus Stories','Little moments. New connections. Here for 24 hours.')+'<div class="card">'+mStoryCircles(true)+'</div><div class="card"><h3>Share your day</h3><p class="muted">Photos, project updates and short videos from your student life. Stories are visible to signed-in students and disappear from view after 24 hours.</p><button class="primary" onclick="mComposer(\'story\')">＋ Add Story</button><button class="follow" onclick="go(\'Reels\')">Explore Reels</button></div>';xPhotos();useConfig(cfg);mCleanupExpired()}catch(e){if(page==='Stories'&&token===mPageToken)$('#m-stories-loading').textContent=mError(e)}
}
async function mHomeStories() {
 if(page!=='Home'||!session?.profile||!mAvailable('story'))return;
 if(!$('#m-home-stories'))$('#main').insertAdjacentHTML('afterbegin','<section class="card m-home-stories" id="m-home-stories"><div class="row between"><b>Stories</b><button class="follow" onclick="go(\'Stories\')">View all</button></div><div class="m-home-strip" role="status">Loading Stories…</div></section>');
 const target=$('#m-home-stories .m-home-strip');try{await mLoadStories();if(page==='Home'&&target?.isConnected){target.innerHTML=mStoryCircles();xPhotos()}}catch{if(target?.isConnected)target.innerHTML='<button class="follow" onclick="go(\'Stories\')">Open Stories</button>'}
}
function mOpenStories(author) {
 mPauseVideos();mStopStory();mStoryItems=mStories.filter(r=>r.author===author&&new Date(r.expires_at)>new Date()).sort((a,b)=>new Date(a.created_at)-new Date(b.created_at));mStoryIndex=0;mStoryPaused=false;
 if(!mStoryItems.length)return toast('These Stories have expired.');modal('<div id="m-story-view"></div>');mShowStory();
}
async function mShowStory() {
 mStopStory();const token=mStoryToken,row=mStoryItems[mStoryIndex],target=$('#m-story-view');if(!row||!target){$('#modal').close();return}
 const remain=new Date(row.expires_at).getTime()-Date.now();if(remain<=0){mNextStory(1);return}
 target.innerHTML='<div class="m-story-header">'+mAuthor(row)+'<span class="small muted">'+(mStoryIndex+1)+' / '+mStoryItems.length+'</span></div><div class="m-story-stage" role="status">Loading Story…</div><p class="m-caption">'+esc(row.caption)+'</p><div class="m-story-controls"><button class="follow" onclick="mNextStory(-1)" '+(mStoryIndex===0?'disabled':'')+'>← Previous</button><button class="follow" id="m-story-pause" onclick="mToggleStory()">Pause</button><button class="follow" onclick="mNextStory(1)">Next →</button></div>'+(mOwn(row)?'<button class="follow" onclick="mMediaOptions(\''+row.id+'\')">Manage this Story</button>':'')+'<p class="small muted">Expires '+esc(ucDate(row.expires_at))+'</p>';
 mExpiryTimer=setTimeout(()=>{if(token===mStoryToken){toast('This Story has expired.');mNextStory(1)}},remain);
 try{const data=checked(await client.storage.from(mBucket).createSignedUrl(row.storage_path,Math.max(1,Math.min(60,Math.floor(remain/1000)))));if(token!==mStoryToken||!target.isConnected)return;const stage=target.querySelector('.m-story-stage'),el=document.createElement(row.mime_type.startsWith('video/')?'video':'img');el.src=data.signedUrl;
  if(el.tagName==='VIDEO'){el.controls=true;el.playsInline=true;el.preload='none';el.onended=()=>{if(!mStoryPaused)mNextStory(1)};const pause=$('#m-story-pause');pause.textContent='Play';mStoryPaused=true;el.onplay=()=>{mStoryPaused=false;if($('#m-story-pause'))$('#m-story-pause').textContent='Pause'};el.onpause=()=>{mStoryPaused=true;if($('#m-story-pause'))$('#m-story-pause').textContent='Play'};el.onerror=()=>{stage.textContent='Could not play this Story. Try another browser or skip to the next.'}}
  else{el.alt=row.caption||'Student Story';el.onload=()=>{if(token===mStoryToken&&!mStoryPaused)mStoryTimer=setTimeout(()=>mNextStory(1),7000)};el.onerror=()=>{stage.textContent='Could not load this Story. Use Next to continue.'}}
  stage.replaceChildren(el);xPhotos();
 }catch(e){if(token===mStoryToken&&target.isConnected)target.querySelector('.m-story-stage').textContent=mError(e)}
}
function mNextStory(step) {mPauseVideos();mStoryIndex+=step;mStoryPaused=false;if(mStoryIndex>=mStoryItems.length||mStoryIndex<0){mStopStory();$('#modal').close();return}mShowStory()}
function mToggleStory() {const video=$('#m-story-view video');if(video){if(video.paused)video.play().catch(()=>toast('Tap the video play control.'));else video.pause();return}mStoryPaused=!mStoryPaused;clearTimeout(mStoryTimer);$('#m-story-pause').textContent=mStoryPaused?'Resume':'Pause';if(!mStoryPaused)mStoryTimer=setTimeout(()=>mNextStory(1),7000)}
async function mCleanupExpired() {
 if(mCleanupRunning||!authUser)return;mCleanupRunning=true;
 try{const expired=checked(await client.from('unichat_media').select('id,storage_path').eq('author',authUser.id).eq('kind','story').lte('expires_at',new Date().toISOString()).limit(30))||[];for(const row of expired){const removed=await client.storage.from(mBucket).remove([row.storage_path]);if(!removed.error)await client.from('unichat_media').delete().eq('id',row.id)}}catch{}finally{mCleanupRunning=false}
}

function mMediaOptions(id) {
 const row=mRows.get(id);if(!row||!mOwn(row))return;mStopStory();mPauseVideos();modal('<h2>Manage '+(row.kind==='reel'?'Reel':'Story')+'</h2><form onsubmit="event.preventDefault();mSaveCaption(\''+id+'\',this)"><label>Caption<textarea class="input" name="caption" maxlength="1500" rows="4">'+esc(row.caption)+'</textarea></label><p id="m-manage-error" role="alert"></p><button class="primary">Save caption</button></form><div class="divider"><p class="small muted">Deleting removes this '+row.kind+' and its reactions and comments.</p><button class="follow" onclick="mConfirmDelete(\''+id+'\')">Delete '+row.kind+'</button></div>');
}
async function mSaveCaption(id,form) {const button=form.querySelector('button');button.disabled=true;try{checked(await client.from('unichat_media').update({caption:form.elements.caption.value.trim()}).eq('id',id));$('#modal').close();mRows.delete(id);mRefreshMedia();toast('Caption updated')}catch(e){$('#m-manage-error').textContent=mError(e)}finally{button.disabled=false}}
function mConfirmDelete(id) {const row=mRows.get(id);if(!row)return;modal('<h2>Delete this '+row.kind+'?</h2><p>This will also remove its likes and comments.</p><p id="m-delete-error" role="alert"></p><button class="primary" onclick="mDeleteMedia(\''+id+'\',this)">Delete permanently</button><button class="follow" onclick="mMediaOptions(\''+id+'\')">Cancel</button>')}
async function mDeleteMedia(id,button) {const row=mRows.get(id);if(!row)return;button.disabled=true;try{checked(await client.from('unichat_media').delete().eq('id',id));const cleanup=await client.storage.from(mBucket).remove([row.storage_path]);mRows.delete(id);$('#modal').close();mRefreshMedia();toast(cleanup.error?'Deleted. The stored file may need cleanup in Supabase.':'Deleted')}catch(e){$('#m-delete-error').textContent=mError(e);button.disabled=false}}
function mRefreshMedia(){if(page==='Reels')mReelPage();else if(page==='Stories')mStoriesPage();else if(page==='Admin')adminPage();else if(page==='Home')mHomeStories()}

function mCoverMarkup(data) {return '<div class="m-cover" data-cover-path="'+esc(data.cover_path||'')+'"><span class="m-cover-school">'+esc(data.school||'')+'</span></div>'}
async function mPaintCovers() {
 for(const el of document.querySelectorAll('[data-cover-path]')){const path=el.dataset.coverPath;if(!path||el.querySelector('img'))continue;try{let cached=mCoverCache.get(path);if(!cached||cached.expires<Date.now()){const r=checked(await client.storage.from('unichat-covers').createSignedUrl(path,900));cached={url:r.signedUrl,expires:Date.now()+840000};mCoverCache.set(path,cached)}if(!el.isConnected||el.dataset.coverPath!==path)continue;const img=document.createElement('img');img.src=cached.url;img.alt='Profile cover photo';el.prepend(img)}catch{}}
}
function mOwnCover() {
 if(page!=='Profile'||$('#m-own-cover'))return;const card=$('#main .card');if(!card)return;card.querySelector('.poster')?.remove();const holder=document.createElement('div');holder.id='m-own-cover';holder.innerHTML=mCoverMarkup(session.profile);card.prepend(holder);card.insertAdjacentHTML('beforeend','<div class="divider row"><button class="follow" onclick="mCoverEditor()">Add / change cover photo</button></div>');mPaintCovers();
}
function mCoverEditor() {
 mCleanCover();modal('<h2>Your cover photo</h2><p class="muted">Choose a wide photo, then crop and reposition it.</p><label>Choose photo<input class="input" type="file" accept="image/jpeg,image/png,image/webp" onchange="mSelectCover(this)"></label><canvas id="m-cover-canvas" width="900" height="300" class="m-cover-canvas"></canvas><label>Zoom<input class="input" id="m-cover-zoom" type="range" min="1" max="3" value="1" step="0.05" oninput="mCoverPaint()"></label><label>Horizontal position<input class="input" id="m-cover-x" type="range" min="0" max="100" value="50" oninput="mCoverPaint()"></label><label>Vertical position<input class="input" id="m-cover-y" type="range" min="0" max="100" value="50" oninput="mCoverPaint()"></label><p id="m-cover-error" role="alert"></p><button class="primary" onclick="mSaveCover(this)">Save cover photo</button>'+ (session.profile.cover_path?' <button class="follow" onclick="mRemoveCover(this)">Remove cover photo</button>':''));
}
async function mSelectCover(input) {
 mCleanCover();const file=input.files?.[0];if(!file)return;const draft={file,url:URL.createObjectURL(file),image:new Image(),ready:false};mCover=draft;
 try{if(!['image/jpeg','image/png','image/webp'].includes(file.type)||file.size>Math.max(10485760,oLimit('unichat-covers').bytes))throw Error('Choose a supported photo within the owner upload limit.');await new Promise((resolve,reject)=>{draft.image.onload=resolve;draft.image.onerror=()=>reject(Error('Cannot open this photo.'));draft.image.src=draft.url});if(mCover!==draft)return;draft.ready=true;$('#m-cover-error').textContent='';mCoverPaint()}catch(e){if(mCover===draft){mCleanCover();$('#m-cover-error').textContent=e.message;input.value=''}}
}
function mCoverPaint() {
 if(!mCover?.ready||!$('#m-cover-canvas'))return;const image=mCover.image,zoom=Number($('#m-cover-zoom').value),width=Math.min(image.width,image.height*3)/zoom,height=width/3,x=(image.width-width)*Number($('#m-cover-x').value)/100,y=(image.height-height)*Number($('#m-cover-y').value)/100;const canvas=$('#m-cover-canvas');canvas.getContext('2d').drawImage(image,x,y,width,height,0,0,canvas.width,canvas.height);
}
function mCoverLock(locked){const dialog=$('#modal');dialog.querySelectorAll('button,input').forEach(el=>el.disabled=locked);dialog.oncancel=locked?e=>e.preventDefault():null}
async function mSaveCover(button) {
 if(mBusy)return;if(!mCover?.ready){$('#m-cover-error').textContent='Choose a photo first.';return}mBusy=true;mCoverLock(true);const old=session.profile.cover_path,path=authUser.id+'/'+xUUID()+'.jpg';let uploaded=false,saved=false;
 try{const canvas=$('#m-cover-canvas'),blob=await new Promise(resolve=>canvas.toBlob(resolve,'image/jpeg',.85));if(!blob||blob.size>oLimit('unichat-covers').bytes)throw Error('This photo is too large. Choose a simpler photo.');checked(await client.storage.from('unichat-covers').upload(path,blob,{contentType:'image/jpeg'}));uploaded=true;const data={...session.profile,cover_path:path};await api('profile',data);saved=true;session.profile=data;Object.assign(state,data);if(old)await client.storage.from('unichat-covers').remove([old]);mCleanCover();$('#modal').close();render();toast('Cover photo saved')}catch(e){if(uploaded&&!saved)await client.storage.from('unichat-covers').remove([path]);$('#m-cover-error').textContent=mError(e)}finally{mBusy=false;mCoverLock(false)}
}
async function mRemoveCover(button) {
 if(mBusy)return;mBusy=true;mCoverLock(true);try{const old=session.profile.cover_path,data={...session.profile,cover_path:null};await api('profile',data);session.profile=data;Object.assign(state,data);if(old)await client.storage.from('unichat-covers').remove([old]);mCoverCache.clear();mCleanCover();$('#modal').close();render();toast('Cover photo removed')}catch(e){$('#m-cover-error').textContent=mError(e)}finally{mBusy=false;mCoverLock(false)}
}
const mOldRegister=register;register=async function(){const media={avatar_path:session?.profile?.avatar_path,cover_path:session?.profile?.cover_path};await mOldRegister();let restored=false;if(session?.profile){for(const [key,value] of Object.entries(media))if(value&&!Object.hasOwn(session.profile,key)){session.profile[key]=value;state[key]=value;restored=true}}if(restored&&page==='Profile')render()};updateProfile=register;
const mOldProfilePage=xProfilePage;xProfilePage=async function(epoch){await mOldProfilePage(epoch);if(page!=='Student'||epoch!==xEpoch)return;const data=xProfile===authUser.id?session.profile:students.find(u=>u.id===xProfile)?.data;if(!data)return;const poster=$('#main .poster');if(poster){poster.outerHTML=mCoverMarkup(data);mPaintCovers()}};

const mOldRender=render;render=function(){if(!session?.profile)return;mPauseVideos();mObserver?.disconnect();mStopStory();if(['Reels','Stories'].includes(page)){nav();if(!mAvailable(page==='Reels'?'reel':'story')){$('#main').innerHTML='<div class="card">This feature is currently paused.</div>';return}if(page==='Reels')mReelPage();else mStoriesPage();return}++mPageToken;mOldRender();if(page==='Home')mHomeStories();if(page==='Profile')mOwnCover()};
const mOldConfig=useConfig;useConfig=function(c){mOldConfig(c);mPaintCovers()};
const mOldAdmin=adminPage;adminPage=async function(){if(session?.admin){draft=draft||structuredClone(cfg);draft.features={reels:true,stories:true,...draft.features}}await mOldAdmin();if(!session?.admin)return;$('#main .tabs')?.insertAdjacentHTML('beforeend','<button onclick="collectDraft();adminTab=\'Media\';adminPage()">Reels & Stories</button>');if(adminTab==='Media'){const panel=$('#adminpanel');panel.innerHTML='<h3>Reels & Stories</h3><p class="muted">Review student uploads and remove inappropriate media. Expired Stories are excluded.</p><div id="m-moderation">Loading…</div>';try{const rows=checked(await client.from('unichat_media').select('*').order('created_at',{ascending:false}).limit(100))||[];if(page!=='Admin'||adminTab!=='Media')return;$('#m-moderation').innerHTML=rows.filter(r=>r.kind==='reel'||new Date(r.expires_at)>new Date()).map(r=>{mRows.set(r.id,r);return '<div class="divider"><b>'+esc(ucPerson(r.author))+' · '+r.kind+'</b><p>'+esc(r.caption||'No caption')+'</p><button class="follow" onclick="mAdminPreview(\''+r.id+'\')">Preview</button><button class="follow" onclick="mMediaOptions(\''+r.id+'\')">Edit / delete</button></div>'}).join('')||'<p class="muted">No active uploads yet.</p>'}catch(e){if(panel.isConnected)$('#m-moderation').textContent=mError(e)}}};
async function mAdminPreview(id){const row=mRows.get(id);if(!row)return;mPauseVideos();modal('<h2>Media preview</h2><div id="m-admin-preview">Loading…</div>');const target=$('#m-admin-preview');try{const data=checked(await client.storage.from(mBucket).createSignedUrl(row.storage_path,60));if(!target.isConnected)return;const el=document.createElement(row.mime_type.startsWith('video/')?'video':'img');el.src=data.signedUrl;el.style.cssText='width:100%;max-height:65vh;object-fit:contain';if(el.tagName==='VIDEO'){el.controls=true;el.playsInline=true}else el.alt='Student Story';target.replaceChildren(el)}catch(e){if(target.isConnected)target.textContent=mError(e)}}
const mOldStart=startLive;startLive=function(){mOldStart();clearInterval(mStoryRefresh);mStoryRefresh=setInterval(()=>{if(!session?.profile)return;mStories=mStories.filter(r=>new Date(r.expires_at)>new Date());if(page==='Home'){const target=$('#m-home-stories .m-home-strip');if(target){target.innerHTML=mStoryCircles();xPhotos()}}else if(page==='Stories'&&!$('#modal').open)mStoriesPage()},60000);if(session?.profile){mCleanupExpired();const shared=location.hash.match(/^#reel=([0-9a-f-]{36})$/);if(shared){page='Reels';render()}}};
window.addEventListener('hashchange',()=>{if(session?.profile&&/^#reel=[0-9a-f-]{36}$/.test(location.hash)){page='Reels';render()}});
document.addEventListener('visibilitychange',()=>{if(document.hidden){mPauseVideos();clearTimeout(mStoryTimer);mStoryPaused=true;const pause=$('#m-story-pause');if(pause)pause.textContent='Resume'}});
$('#modal').addEventListener('close',()=>{$('#modal').querySelectorAll('video').forEach(v=>v.pause());mStopStory();mPauseVideos();mCleanDraft();mCleanCover()});
const mOldSignOut=signOut;signOut=async function(){mPauseVideos();mStopStory();mObserver?.disconnect();clearInterval(mStoryRefresh);mCleanDraft();mCleanCover();mRows.clear();mStats.clear();mCoverCache.clear();mReels=[];mStories=[];++mPageToken;await mOldSignOut()};
