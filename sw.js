/* Club Magnolias: guarda la página para abrirla sin señal. Siempre intenta la red primero. */
const CACHE='magnolias-v2';
const SHELL=['./','./index.html','./manifest.webmanifest','./icons/icon-192.png','./media/flor.png','./media/wordmark.png','./media/logo.png'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(CACHE).then(c=>c.addAll(SHELL)).then(()=>self.skipWaiting()));});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim()));});
self.addEventListener('fetch',e=>{
  const r=e.request;const u=new URL(r.url);
  if(r.method!=='GET'||u.origin!==location.origin)return;
  if(r.mode==='navigate'){e.respondWith(fetch(r).then(res=>{const c=res.clone();caches.open(CACHE).then(k=>k.put('./index.html',c));return res;}).catch(()=>caches.match('./index.html')));return;}
  if(/\.(png|jpg|webp|svg|js)$/.test(u.pathname)&&!u.pathname.endsWith('sw.js')){
    e.respondWith(caches.match(r).then(hit=>hit||fetch(r).then(res=>{if(res.ok&&!/\.mp4$/.test(u.pathname)){const c=res.clone();caches.open(CACHE).then(k=>k.put(r,c));}return res;})));
  }
});
