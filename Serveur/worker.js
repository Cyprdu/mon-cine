// Base des ressorties : où chaque film ancien repasse en France.
// Sources : catalogue JustWatch, identifiants Wikidata, pages publiques d’AlloCiné autorisées par son robots.txt.
// 400 pages AlloCiné par jour au plus, une à la fois ; pause d’une heure au premier refus. Aucune donnée personnelle.
const UA = { "User-Agent": "mon-cine-perso/1.0" }, AC = "https://www.allocine.fr/seance/film-", JOUR = 86400, MAX = 400;
const now = () => Math.floor(Date.now() / 1000), today = () => new Date().toISOString().slice(0, 10);
const json = (o, s = 200, age = 300) => new Response(JSON.stringify(o), { status: s, headers: { "content-type": "application/json; charset=utf-8", "cache-control": `public, max-age=${age}` } });
const txt = s => s.replace(/&quot;/g, '"').replace(/&#0?39;/g, "'").replace(/&amp;/g, "&");
const get = async (e, k) => (await e.DB.prepare("select v from etat where k=?").bind(k).first())?.v;
const put = (e, k, v) => e.DB.prepare("insert into etat values(?,?) on conflict(k) do update set v=excluded.v").bind(k, String(v)).run();

export function villes(h) {
  const out = new Map();
  for (const m of h.matchAll(/data-localization="([^"]+)"[^>]*>\s*[^<]*<span class="light">\((\d+)\)/g)) {
    try { const j = JSON.parse(txt(m[1])); out.set(j.id, { id: j.id, nom: j.value, n: +m[2] }); } catch {}
  }
  return [...out.values()];
}
export function dates(h) {
  const m = h.match(/data-showtimes-dates="([^"]*)"/);
  try { return m ? JSON.parse(txt(m[1])).filter(d => /^\d{4}-\d\d-\d\d$/.test(d)) : []; } catch { return []; }
}
export function affiche(h) {
  const out = new Map();
  for (const m of h.matchAll(/fichefilm_gen_cfilm=(\d+)\.html"[^>]*>([^<]{1,120})<\/a>/g)) if (!out.has(+m[1]) && m[2].trim()) out.set(+m[1], txt(m[2]).trim());
  return [...out];
}
async function page(e, url) {
  const t = now(), day = "ac-" + today();
  if (+(await get(e, "pause") || 0) > t) return null;
  const n = +(await get(e, day) || 0);
  if (n >= MAX) return null;
  await put(e, day, n + 1);
  const r = await fetch(url, { headers: UA, signal: AbortSignal.timeout(20000) });
  if ([403, 429, 503].includes(r.status)) { await put(e, "pause", t + 3600); return null; }
  return r.ok ? await r.text() : r.status === 404 ? "" : null;
}
async function wikidata(e, ids) {
  const q = `SELECT ?t ?a WHERE { VALUES ?t { ${ids.map(i => `"${i}"`).join(" ")} } ?f wdt:P4947 ?t; wdt:P1265 ?a }`;
  const r = await fetch("https://query.wikidata.org/sparql?format=json&query=" + encodeURIComponent(q), { headers: { ...UA, Accept: "application/json" } });
  if (!r.ok) return;
  const j = await r.json(), st = [];
  for (const b of j.results.bindings) if (/^\d+$/.test(b.a.value)) st.push(e.DB.prepare("update films set ac=? where tmdb=?").bind(+b.a.value, +b.t.value));
  st.push(...ids.map(i => e.DB.prepare("update films set wiki=? where tmdb=?").bind(now(), i)));
  await e.DB.batch(st);
}
async function catalogue(e) {
  const t = now(), st = [], y = new Date().getFullYear();
  for (let p = 0; p < 3; p++) {
    const r = await fetch("https://apis.justwatch.com/graphql", { method: "POST", headers: { ...UA, "content-type": "application/json" }, body: JSON.stringify({
      query: 'query($f:TitleFilter!,$a:String){popularTitles(country:FR,filter:$f,first:90,after:$a,sortBy:POPULAR){edges{node{content(country:FR,language:"fr"){title originalReleaseYear originalReleaseDate posterUrl externalIds{tmdbId}} offers(country:FR,platform:WEB){monetizationType package{clearName}}}}}}',
      variables: { f: { objectTypes: ["MOVIE"], monetizationTypes: ["CINEMA"], releaseYear: { max: y - 2 } }, a: p ? btoa(String(p * 90)) : null } }) });
    if (!r.ok) break;
    const ed = (await r.json()).data?.popularTitles?.edges || [];
    for (const { node: n } of ed) {
      const c = n.content, id = +c.externalIds?.tmdbId;
      if (!id) continue;
      const ch = [...new Set(n.offers.filter(o => o.monetizationType === "CINEMA").map(o => o.package.clearName.trim().replace("Cinemas Pathe", "Pathé").replace("CGR Cinémas", "CGR")))].filter(x => !/allocin/i.test(x));
      st.push(e.DB.prepare("insert into films(tmdb,titre,sortie,affiche,chaines,jw) values(?,?,?,?,?,?) on conflict(tmdb) do update set titre=excluded.titre,sortie=excluded.sortie,affiche=excluded.affiche,chaines=excluded.chaines,jw=excluded.jw")
        .bind(id, c.title, c.originalReleaseDate || `${c.originalReleaseYear}-01-01`, c.posterUrl ? "https://images.justwatch.com" + c.posterUrl.replace("{profile}", "s332").replace("{format}", "webp") : null, JSON.stringify(ch), t));
    }
    if (ed.length < 90) break;
  }
  for (let i = 0; i < st.length; i += 50) await e.DB.batch(st.slice(i, i + 50));
  if (st.length) await put(e, "catalogue", t);
}
async function lire(e, f) {
  const h = await page(e, `${AC}${f.ac}/`);
  if (h === null) return;
  const l = villes(h), st = [e.DB.prepare("update films set lu=? where tmdb=?").bind(now(), f.tmdb)];
  st.push(e.DB.prepare(l.length ? `delete from villes where ac=? and loc not in (${l.map(x => +x.id).join(",")})` : "delete from villes where ac=?").bind(f.ac));
  for (const x of l) st.push(e.DB.prepare("insert into villes(ac,loc,nom,n) values(?,?,?,?) on conflict(ac,loc) do update set nom=excluded.nom,n=excluded.n").bind(f.ac, x.id, x.nom, x.n));
  await e.DB.batch(st);
}
async function tour(e) {
  const t = now();
  if (t - +(await get(e, "catalogue") || 0) > 6 * 3600) return catalogue(e);
  const w = (await e.DB.prepare("select tmdb from films where ac is null and (jw>? or suivi>?) and (wiki is null or wiki<?) limit 60").bind(t - 2 * JOUR, t - 40 * JOUR, t - 5 * JOUR).all()).results;
  if (w.length) return wikidata(e, w.map(x => x.tmdb));
  const a = +(await get(e, "affiche_page") || 0);
  if (a > 0 || t - +(await get(e, "affiche") || 0) > JOUR) {
    const h = await page(e, "https://www.allocine.fr/film/aucinema/?page=" + (a + 1));
    if (h !== null) {
      const st = affiche(h).map(([i, n]) => e.DB.prepare("insert into encours values(?,?,?) on conflict(ac) do update set titre=excluded.titre,vu=excluded.vu").bind(i, n, t));
      if (st.length) await e.DB.batch(st);
      await put(e, "affiche_page", a >= 5 ? 0 : a + 1);
      if (a >= 5) await put(e, "affiche", t);
    }
    return;
  }
  // Un film jamais lu ou lu depuis plus de 12 h, puis les dates d’une de ses villes
  const fs = (await e.DB.prepare("select tmdb,ac,lu from films where ac is not null and (jw>? or suivi>?) and (lu is null or lu<?) order by (lu is not null), lu limit 2").bind(t - 2 * JOUR, t - 40 * JOUR, t - JOUR / 2).all()).results;
  if (fs[0]) await lire(e, fs[0]);
  if (fs[1] && !fs[1].lu) return lire(e, fs[1]);   // premier remplissage : d’abord tous les films
  const v = await e.DB.prepare("select ac,loc from villes where lu is null or lu<? order by (lu is not null), lu limit 1").bind(t - 3 * JOUR).first();
  if (v) {
    const h = await page(e, `${AC}${v.ac}/pres-de-${v.loc}/`);
    if (h !== null) await e.DB.prepare("update villes set dates=?,lu=? where ac=? and loc=?").bind(JSON.stringify(dates(h)), t, v.ac, v.loc).run();
  }
}
async function liste(e, where, ...b) {
  const t = today(), fs = (await e.DB.prepare("select * from films where " + where + " limit 400").bind(...b).all()).results, m = new Map();
  const vs = (await (fs.length === 1 ? e.DB.prepare("select * from villes where ac=?").bind(fs[0].ac ?? -1) : e.DB.prepare("select * from villes")).all()).results;
  for (const v of vs) {
    const d = v.dates ? JSON.parse(v.dates).filter(x => x >= t) : null;
    if (d && !d.length) continue;
    if (!m.has(v.ac)) m.set(v.ac, []);
    m.get(v.ac).push({ loc: v.loc, nom: v.nom, n: v.n, dates: d || [] });
  }
  return fs.map(f => ({ tmdb: f.tmdb, ac: f.ac, titre: f.titre || "", sortie: f.sortie || "", affiche: f.affiche, chaines: JSON.parse(f.chaines || "[]"), catalogue: (f.jw || 0) > now() - 2 * JOUR, lu: f.lu, villes: m.get(f.ac) || [] }));
}
async function suivre(e, ids) {
  ids = [...new Set((Array.isArray(ids) ? ids : []).filter(i => Number.isInteger(i) && i > 0 && i < 1e8))].slice(0, 60);
  if (!ids.length) return;
  const t = now(), n = (await e.DB.prepare("select count(*) n from films where suivi>?").bind(t - 40 * JOUR).first()).n;
  if (n > 400) return;
  await e.DB.batch(ids.map(i => e.DB.prepare("insert into films(tmdb,suivi) values(?,?) on conflict(tmdb) do update set suivi=excluded.suivi").bind(i, t)));
}
export default {
  async scheduled(_, e, c) { c.waitUntil(tour(e)); },
  async fetch(r, e, c) {
    const u = new URL(r.url);
    try {
      if (r.method === "POST" && u.pathname === "/suivre") { const b = await r.text(); if (b.length > 4000) return json({}, 413, 0); await suivre(e, JSON.parse(b).ids); return json({ ok: 1 }, 200, 0); }
      if (r.method !== "GET") return json({}, 405, 0);
      const cache = caches.default, key = new Request(u.origin + u.pathname), hit = await cache.match(key);
      if (hit) return hit;
      let o, age = 600, m;
      if (u.pathname === "/ressorties") o = { at: now(), films: await liste(e, "jw>? or suivi>?", now() - 2 * JOUR, now() - 40 * JOUR) };
      else if (u.pathname === "/affiche") { o = (await e.DB.prepare("select ac,titre from encours where vu>? limit 500").bind(now() - 4 * JOUR).all()).results; age = 3600; }
      else if ((m = u.pathname.match(/^\/film\/(\d{1,8})$/))) { o = (await liste(e, "tmdb=?", +m[1]))[0] || {}; age = 300; }
      else if (u.pathname === "/") { age = 10; o = { films: await e.DB.prepare("select count(*) n, count(ac) ac, count(lu) lu from films").first(), villes: await e.DB.prepare("select count(*) n, count(dates) dates from villes").first(), encours: (await e.DB.prepare("select count(*) n from encours").first()).n, pages: +(await get(e, "ac-" + today()) || 0), pause: +(await get(e, "pause") || 0) > now() }; }
      else return json({}, 404, 60);
      const x = json(o, 200, age);
      if (age > 10) c.waitUntil(cache.put(key, x.clone()));
      return x;
    } catch { return json({ erreur: 1 }, 500, 0); }
  }
};
