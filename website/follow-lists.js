/* Followers and Following: read complete lists in pages, not the discovery cache. */
let fList=null,fRequest=0,fSearchTimer=null,fCountCache=new Map();
function fCountButtons(id,counts){const format=n=>Number.isFinite(Number(n))?Number(n).toLocaleString():'…';return '<button class="f-count" onclick="fOpenList(\''+id+'\',\'followers\')"><strong>'+format(counts.followers)+'</strong><span>Followers</span></button><button class="f-count" onclick="fOpenList(\''+id+'\',\'following\')"><strong>'+format(counts.following)+'</strong><span>Following</span></button>'}
async function fCounts(id){const viewer=authUser?.id;const value=checked(await client.rpc('unichat_follow_counts',{student_id:id}));if(session?.profile&&authUser?.id===viewer)fCountCache.set(id,value);return value}
async function fUpdateCounts(id){try{const counts=await fCounts(id);if(!session?.profile)return;document.querySelectorAll('[data-follow-stats="'+id+'"]').forEach(host=>{host.innerHTML=fCountButtons(id,counts)});if(fList?.owner===id)fTabs();}catch(e){document.querySelectorAll('[data-follow-stats="'+id+'"]').forEach(host=>{host.innerHTML='<span class="small muted">'+esc(xError(e))+'</span><button class="follow" onclick="fUpdateCounts(\''+id+'\')">Retry</button>'});}}
function fTabs(){if(!fList||!$('#f-tabs'))return;const counts=fCountCache.get(fList.owner);$('#f-tabs').innerHTML=['followers','following'].map(kind=>'<button class="'+(fList.kind===kind?'active':'')+'" aria-pressed="'+(fList.kind===kind)+'" onclick="fSwitchList(\''+kind+'\')">'+(kind==='followers'?'Followers':'Following')+(counts?' · '+Number(counts[kind]).toLocaleString():'')+'</button>').join('')}
async function fOpenList(id,kind='followers'){
 if(!session?.profile)return;if(!['followers','following'].includes(kind))return;
 clearTimeout(fSearchTimer);++fRequest;fList={owner:id,kind,search:'',offset:0,rows:[],more:false,loading:false};
 const person=id===authUser.id?'Your connections':(students.find(p=>p.id===id)?.data?.name||'Student connections');
 modal('<h2>'+esc(person)+'</h2><div class="tabs f-tabs" id="f-tabs"></div><label class="small">Search these connections<input class="input" id="f-search" type="search" maxlength="100" placeholder="Name, username, school or department" oninput="fSearch(this.value)"></label><p class="small muted">Available student profiles. Blocked and suspended accounts are excluded.</p><div id="f-results"></div><p id="f-status" role="status" class="small muted"></p><button class="follow" id="f-more" hidden onclick="fLoadList(false)">Load more</button>');
 fTabs();fUpdateCounts(id);await fLoadList(true);
}
function fSwitchList(kind){if(!fList||!['followers','following'].includes(kind))return;clearTimeout(fSearchTimer);fList.kind=kind;fTabs();fLoadList(true)}
function fSearch(value){if(!fList)return;fList.search=value;clearTimeout(fSearchTimer);++fRequest;fList.loading=true;$('#f-more').hidden=true;$('#f-status').textContent='Searching…';fSearchTimer=setTimeout(()=>fLoadList(true),250)}
function fListCard(row){const self=row.id===authUser.id;return '<article class="f-person" data-follow-person="'+row.id+'"><button class="f-avatar-link" onclick="fOpenProfile(\''+row.id+'\')" aria-label="Open '+esc(row.data.name)+' profile">'+xAvatarHTML(row)+'</button><div class="f-person-info"><button class="x-profile-link" onclick="fOpenProfile(\''+row.id+'\')">'+esc(row.data.name)+'</button><p class="small muted">@'+esc(row.username)+(self?' · You':'')+'</p><p class="small muted">'+esc(row.data.school||'')+(row.data.department?' · '+esc(row.data.department):'')+'</p>'+(row.follows_you&&!self?'<span class="pill">Follows you</span>':'')+'</div>'+(!self?'<button class="follow f-follow-button" aria-pressed="'+!!row.is_following+'" onclick="fToggleFollow(\''+row.id+'\',this)">'+(row.is_following?'Unfollow':row.follows_you?'Follow back':'Follow')+'</button>':'')+'</article>'}
async function fLoadList(reset=true){
 const current=fList;if(!current)return;const token=++fRequest,kind=current.kind,search=current.search;
 current.loading=true;if(reset){current.rows=[];current.offset=0;$('#f-results').innerHTML=''}
 $('#f-more').disabled=true;$('#f-status').textContent=search?'Searching…':'Loading…';
 try{
  const rows=checked(await client.rpc('unichat_follow_list',{student_id:current.owner,list_kind:kind,page_offset:current.offset,search_text:search}))||[];
  if(fList!==current||token!==fRequest||!$('#f-results'))return;
  const batch=rows.slice(0,25);current.more=rows.length>25;current.offset+=batch.length;current.rows.push(...batch);
  for(const row of batch){const found=students.findIndex(p=>p.id===row.id);if(found<0)students.push({...row,status:'active'});else students[found]={...students[found],...row};}
  $('#f-results').insertAdjacentHTML('beforeend',batch.map(fListCard).join(''));$('#f-more').hidden=!current.more;$('#f-more').disabled=false;$('#f-more').textContent='Load more';
  $('#f-status').textContent=current.rows.length?(current.more?'More connections are available.':'Showing all '+current.rows.length+' '+(search?'matching connection'+(current.rows.length===1?'':'s'):kind==='followers'?'follower'+(current.rows.length===1?'':'s'):'followed student'+(current.rows.length===1?'':'s'))+'.'):(search?'No matching connections.':kind==='followers'?'No followers yet.':'No students followed yet.');
  xPhotos();
 }catch(e){if(fList===current&&token===fRequest&&$('#f-status')){$('#f-status').textContent=xError(e);$('#f-more').hidden=false;$('#f-more').disabled=false;$('#f-more').textContent='Try again'}}
 finally{if(fList===current&&token===fRequest)current.loading=false}
}
function fOpenProfile(id){$('#modal').close();if(id===authUser.id)go('Profile');else xViewProfile(id)}
async function fToggleFollow(id,button){
 const current=fList,row=current?.rows.find(p=>p.id===id);if(!row||id===authUser.id)return;const following=!row.is_following;button.disabled=true;
 try{
  if(following){const result=await client.from('unichat_follows').insert({follower:authUser.id,following:id});if(result.error&&result.error.code!=='23505')checked(result)}
  else checked(await client.from('unichat_follows').delete().eq('follower',authUser.id).eq('following',id));
  state.following=following?[...new Set([...state.following,id])]:state.following.filter(p=>p!==id);
  xFollows=xFollows.filter(f=>!(f.follower===authUser.id&&f.following===id));if(following)xFollows.push({follower:authUser.id,following:id});
  row.is_following=following;
  if(button.isConnected){button.textContent=following?'Unfollow':row.follows_you?'Follow back':'Follow';button.setAttribute('aria-pressed',String(following))}
  await Promise.all([...new Set([authUser.id,current.owner,id])].map(fUpdateCounts));
  if(fList===current&&current.owner===authUser.id&&current.kind==='following'&&!following)await fLoadList(true);
  toast(following?'Following '+row.data.name:'Unfollowed '+row.data.name);
 }catch(e){toast(xError(e))}finally{if(button.isConnected)button.disabled=false}
}
function fOwnCounts(){if(page!=='Profile'||!session?.profile)return;const card=$('#main .card');if(!card||card.querySelector('[data-follow-stats]'))return;const old=[...card.querySelectorAll('b')].find(el=>el.querySelector('span')?.textContent.trim()==='Following');const host=document.createElement('span');host.className='f-profile-counts';host.dataset.followStats=authUser.id;host.innerHTML=fCountButtons(authUser.id,fCountCache.get(authUser.id)||{followers:'…',following:'…'});if(old)old.replaceWith(host);else card.insertAdjacentElement('beforeend',host);fUpdateCounts(authUser.id)}
const fOldRender=render;render=function(){fOldRender();fOwnCounts()};
const fOldProfile=xProfilePage;xProfilePage=async function(epoch){await fOldProfile(epoch);if(page!=='Student'||epoch!==xEpoch)return;fUpdateCounts(xProfile)};
$('#modal').addEventListener('close',()=>{clearTimeout(fSearchTimer);++fRequest;fList=null});
const fOldSignOut=signOut;signOut=async function(){clearTimeout(fSearchTimer);++fRequest;fList=null;fCountCache.clear();await fOldSignOut()};
