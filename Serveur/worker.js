// Base des ressorties : où chaque film ancien repasse en France.
// Sources : catalogue JustWatch, identifiants Wikidata, pages publiques d’AlloCiné autorisées par son robots.txt (jamais /_/),
// et données ouvertes de programmation des cinémas indépendants (SCARE, data.gouv.fr).
// 1 400 pages AlloCiné par jour au plus (45 000 requêtes par mois avec le reste), une par minute ; pause d’une heure au premier refus. Aucune donnée personnelle.
const UA = { "User-Agent": "mon-cine-perso/1.0" }, AC = "https://www.allocine.fr/seance/film-", JOUR = 86400, MAX = 1400;
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
const MOIS = { janvier: 1, "février": 2, mars: 3, avril: 4, mai: 5, juin: 6, juillet: 7, "août": 8, septembre: 9, octobre: 10, novembre: 11, "décembre": 12 };
const txt2 = s => txt(s).replace(/&eacute;/g, "é").replace(/\s+/g, " ").trim();
function iso(d) {
  const m = d && d.match(/(\d+)(?:er)? (\S+) (\d{4})/);
  return m && MOIS[m[2]] ? `${m[3]}-${String(MOIS[m[2]]).padStart(2, "0")}-${m[1].padStart(2, "0")}` : "";
}
/** Salles d’une page de département, et s’il existe une page suivante */
export function salles(h, n) {
  const out = new Map();
  for (const m of h.matchAll(/csalle=(\w+)\.html">\s*([^<]+)<\/a>/g)) {
    const i = h.indexOf("<address", m.index), a = i > 0 && i < m.index + 1500 ? h.slice(h.indexOf(">", i) + 1, h.indexOf("</address", i)) : "";
    out.set(m[1], { id: m[1], nom: txt2(m[2]), adr: txt2(a) });
  }
  // Certaines salles n’ont qu’une étiquette, sans lien lisible
  for (const m of h.matchAll(/data-theater="([^"]+)"/g)) try { const j = JSON.parse(txt(m[1])); if (j.id && !out.has(j.id)) out.set(j.id, { id: j.id, nom: j.name, adr: "" }); } catch {}
  const t = h.match(/(\d+) cinémas?/);
  return { l: [...out.values()], suite: t ? +t[1] > n * 20 : false };
}
/** Films d’une page de salle, avec les horaires du jour et du lendemain */
export function seances(h) {
  const out = [], c = h.split('class="card entity-card');
  for (let k = 1; k < c.length; k++) {
    const x = c[k], t = x.match(/meta-title-link"[^>]*cfilm=(\d+)\.html">([^<]+)</);
    if (!t) continue;
    const heures = [];
    for (const m of x.matchAll(/data-experiences="([^"]*)"[^>]*?data-showtime-time="([^"]{16})/g)) heures.push(m[2] + (m[1].includes("Version.Original") ? "|VO" : m[1].includes("Version.French") ? "|VF" : "|"));
    const i = x.indexOf("meta-body-info"), d = x.slice(i, i + 1200).match(/class="date[^"]*">\s*([^<]+)/), img = x.slice(0, 1200).match(/(?:data-src|src)="(https:\/\/fr\.web\.img[^"]+\.jpg)"/);
    out.push({ ac: +t[1], titre: txt2(t[2]), sortie: iso(d && d[1]), rep: x.includes("Date de reprise") ? 1 : 0, img: img ? img[1].replace(/\/c_\d+_\d+\//, "/c_310_420/") : null, h: heures });
  }
  return out;
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
const OK = "(jw>?1-172800 or suivi>?1-3456000 or cine>?1-1209600)";
async function departement(e) {
  const t = now();
  let l = JSON.parse(await get(e, "deps") || "null");
  if (!l) {
    const h = await page(e, "https://www.allocine.fr/salle/");
    if (!h) return true;
    l = [...new Set([...h.matchAll(/departement-(\d+)/g)].map(m => m[1] + ":1"))];
    await put(e, "deps", JSON.stringify(l));
    return true;
  }
  if (!l.length) { await e.DB.prepare("delete from etat where k='deps'").run(); await put(e, "recense", t); return true; }
  const [d, n] = l[0].split(":"), h = await page(e, `https://www.allocine.fr/salle/cinema/departement-${d}/${n > 1 ? "?page=" + n : ""}`);
  if (h === null) return true;
  const r = salles(h, +n);
  if (r.l.length) await e.DB.prepare("insert into salles(id,nom,adr,vu) select json_extract(value,'$.id'),json_extract(value,'$.nom'),json_extract(value,'$.adr'),?2 from json_each(?1) where true on conflict(id) do update set nom=excluded.nom,adr=case when excluded.adr='' then salles.adr else excluded.adr end,vu=excluded.vu").bind(JSON.stringify(r.l), t).run();
  l.shift();
  if (r.suite && +n < 12) l.unshift(d + ":" + (+n + 1));
  await put(e, "deps", JSON.stringify(l));
  return true;
}
async function salle(e) {
  const t = now(), s = await e.DB.prepare("select id from salles where vu>?1-5184000 and (lu is null or (n>0 and lu<?1-172800) or (n=0 and lu<?1-345600)) order by (lu is not null), lu limit 1").bind(t).first();
  if (!s) return false;
  const h = await page(e, `https://www.allocine.fr/seance/salle_gen_csalle=${s.id}.html`);
  if (h === null) return true;
  const l = seances(h), j = JSON.stringify(l), max = new Date().getFullYear() - 2 + "-12-31", jour = today();
  await e.DB.batch([
    e.DB.prepare("update salles set lu=?,n=? where id=?").bind(t, dates(h).length, s.id),
    e.DB.prepare("delete from passages where salle=?").bind(s.id),
    e.DB.prepare("insert or replace into passages(salle,ac,jour,h) select ?2,json_extract(value,'$.ac'),?3,json_extract(value,'$.h') from json_each(?1) where json_array_length(value,'$.h')>0").bind(j, s.id, jour),
    e.DB.prepare("insert into trouves(ac,titre,sortie,affiche,vu) select json_extract(value,'$.ac'),json_extract(value,'$.titre'),json_extract(value,'$.sortie'),json_extract(value,'$.img'),?2 from json_each(?1) where json_extract(value,'$.rep')=1 or (json_extract(value,'$.sortie')<>'' and json_extract(value,'$.sortie')<=?3) on conflict(ac) do update set vu=excluded.vu").bind(j, t, max),
    e.DB.prepare("update films set cine=?2 where ac in (select json_extract(value,'$.ac') from json_each(?1) where json_extract(value,'$.rep')=1 or json_extract(value,'$.sortie')<=?3)").bind(j, t, max),
  ]);
  return true;
}
/** Programmation des indépendants : tout le fichier, cinq cents lignes par passage, chaque nuit */
async function independants(e) {
  const t = now(), champs = "showid,cineid,cinenom,cineville,cineadresse,cinecp,_coords.lat,_coords.lon,filmtitle,filmposter,filmversion,showstart,showurl,_donnees_imdb.id";
  let u = await get(e, "ind_url"), debut = +(await get(e, "ind_debut") || 0);
  if (!u) {
    if (t - debut < 22 * 3600) return false;
    u = `https://datacinesindes.fr/data-fair/api/v1/datasets/programmation-cinemas/lines?size=500&select=${champs}`;
    debut = t; await put(e, "ind_debut", t); await put(e, "ind_url", u);
  }
  const r = await fetch(u, { headers: UA, signal: AbortSignal.timeout(25000) });
  if (!r.ok) { await e.DB.prepare("delete from etat where k='ind_url'").run(); await put(e, "ind_debut", t - 18 * 3600); await put(e, "ind_err", r.status); return true; }
  const b = await r.text(), n = b.slice(0, 600).match(/"next":"([^"]+)"/);
  await e.DB.prepare(`insert into ind(id,tmdb,titre,cine,nom,ville,adr,lat,lon,debut,version,url,affiche,vu)
    select json_extract(value,'$.cineid')||'-'||json_extract(value,'$.showid'),json_extract(value,'$."_donnees_imdb.id"'),json_extract(value,'$.filmtitle'),json_extract(value,'$.cineid'),json_extract(value,'$.cinenom'),json_extract(value,'$.cineville'),
    coalesce(json_extract(value,'$.cineadresse'),'')||' '||coalesce(json_extract(value,'$.cinecp'),''),json_extract(value,'$."_coords.lat"'),json_extract(value,'$."_coords.lon"'),substr(json_extract(value,'$.showstart'),1,16),json_extract(value,'$.filmversion'),json_extract(value,'$.showurl'),json_extract(value,'$.filmposter'),?2
    from json_each(?1,'$.results') where json_extract(value,'$.cineid') is not null and json_extract(value,'$.showid') is not null and json_extract(value,'$.showstart')>=?3
    on conflict(id) do update set tmdb=excluded.tmdb,debut=excluded.debut,version=excluded.version,url=excluded.url,vu=excluded.vu`).bind(b, t, today()).run();
  if (n && new URL(n[1]).host === "datacinesindes.fr") await put(e, "ind_url", n[1].replace(/\\u0026/g, "&"));
  else await e.DB.batch([
    e.DB.prepare("delete from etat where k='ind_url'"), e.DB.prepare("delete from ind where vu<?").bind(debut),
    e.DB.prepare("insert or ignore into tmeta(tmdb,titre,affiche) select tmdb,max(titre),max(affiche) from ind where tmdb is not null group by tmdb"),
    e.DB.prepare("update films set cine=?1 where tmdb in (select i.tmdb from ind i join tmeta m on m.tmdb=i.tmdb where m.sortie<>'' and m.sortie<=?2)").bind(t, new Date().getFullYear() - 2 + "-12-31"),
  ]);
  return true;
}
async function sparql(q) {
  const r = await fetch("https://query.wikidata.org/sparql?format=json&query=" + encodeURIComponent(q), { headers: { ...UA, Accept: "application/json" } });
  return r.ok ? (await r.json()).results.bindings : null;
}
/** Films vus dans une salle : numéro TMDB ; films des indépendants : date de sortie */
async function relier(e) {
  const t = now(), old = new Date().getFullYear() - 2 + "-12-31";
  const a = (await e.DB.prepare("select ac,titre,sortie,affiche from trouves where tmdb is null and (wiki is null or wiki<?) limit 50").bind(t - 15 * JOUR).all()).results;
  if (a.length) {
    const b = await sparql(`SELECT ?a ?t WHERE { VALUES ?a { ${a.map(x => `"${x.ac}"`).join(" ")} } ?f wdt:P1265 ?a; wdt:P4947 ?t }`);
    if (!b) return true;
    const st = [e.DB.prepare(`update trouves set wiki=? where ac in (${a.map(x => +x.ac).join(",")})`).bind(t)];
    for (const x of b) {
      const f = a.find(y => y.ac === +x.a.value), id = +x.t.value;
      if (!f || !id) continue;
      st.push(e.DB.prepare("update trouves set tmdb=? where ac=?").bind(id, f.ac));
      st.push(e.DB.prepare("insert into films(tmdb,ac,titre,sortie,affiche,cine,wiki) values(?1,?2,?3,?4,?5,?6,?6) on conflict(tmdb) do update set ac=coalesce(films.ac,excluded.ac),cine=excluded.cine,titre=coalesce(films.titre,excluded.titre),sortie=coalesce(films.sortie,excluded.sortie),affiche=coalesce(films.affiche,excluded.affiche)").bind(id, f.ac, f.titre, f.sortie, f.affiche, t));
    }
    await e.DB.batch(st);
    return true;
  }
  const m = (await e.DB.prepare("select tmdb,titre,affiche from tmeta where sortie is null limit 60").all()).results;
  if (!m.length) return false;
  const b = await sparql(`SELECT ?t (MIN(?d) AS ?s) (SAMPLE(?a) AS ?x) (SAMPLE(?l) AS ?n) WHERE { VALUES ?t { ${m.map(x => `"${x.tmdb}"`).join(" ")} } ?f wdt:P4947 ?t. OPTIONAL { ?f wdt:P577 ?d } OPTIONAL { ?f wdt:P1265 ?a } OPTIONAL { ?f rdfs:label ?l FILTER(LANG(?l)="fr") } } GROUP BY ?t`);
  if (!b) return true;
  const st = [];
  for (const f of m) {
    const x = b.find(y => +y.t.value === f.tmdb), s = x?.s?.value?.slice(0, 10) || "";
    st.push(e.DB.prepare("update tmeta set sortie=? where tmdb=?").bind(s, f.tmdb));
    if (s && s <= old) st.push(e.DB.prepare("insert into films(tmdb,ac,titre,sortie,affiche,cine,wiki) values(?1,?2,?3,?4,?5,?6,?6) on conflict(tmdb) do update set cine=excluded.cine,ac=coalesce(films.ac,excluded.ac),titre=coalesce(films.titre,excluded.titre),sortie=coalesce(films.sortie,excluded.sortie),affiche=coalesce(films.affiche,excluded.affiche)").bind(f.tmdb, +x.x?.value || null, x.n?.value || f.titre, s, f.affiche, t));
  }
  await e.DB.batch(st);
  return true;
}
async function film(e) {
  const t = now(), f = await e.DB.prepare(`select tmdb,ac from films where ac is not null and ${OK} and (lu is null or lu<?1-172800) order by (lu is not null), lu limit 1`).bind(t).first();
  if (!f) return false;
  await lire(e, f);
  return true;
}
async function ville(e) {
  const t = now(), v = await e.DB.prepare("select ac,loc from villes where lu is null or lu<? order by (lu is not null), lu limit 1").bind(t - 4 * JOUR).first();
  if (!v) return false;
  const h = await page(e, `${AC}${v.ac}/pres-de-${v.loc}/`);
  if (h !== null) await e.DB.prepare("update villes set dates=?,lu=? where ac=? and loc=?").bind(JSON.stringify(dates(h)), t, v.ac, v.loc).run();
  return true;
}
async function tour(e) {
  const t = now(), m = Math.floor(t / 60) % 10;
  if (m === 0 && t - +(await get(e, "catalogue") || 0) > 6 * 3600) return catalogue(e);
  if (m % 3 === 1 && await independants(e)) return;
  if (m % 5 === 2 && await relier(e)) return;
  if (m === 5) {
    const w = (await e.DB.prepare(`select tmdb from films where ac is null and ${OK} and (wiki is null or wiki<?1-432000) limit 60`).bind(t).all()).results;
    if (w.length) return wikidata(e, w.map(x => x.tmdb));
  }
  if (m % 2 === 0 && t - +(await get(e, "recense") || 0) > 30 * JOUR) return departement(e);
  // Sur dix minutes : sept salles, une ou deux pages de film, deux dates de ville
  const o = m === 3 ? [film, ville, salle] : m === 6 || m === 8 ? [ville, film, salle] : [salle, film, ville];
  for (const f of o) if (await f(e)) return;
}
/** Réponses composées par la base : le serveur ne décode rien */
async function ressorties(e) {
  return (await e.DB.prepare(`with f as (select * from films where ${OK}),
    v as (select f.tmdb t,json_object('loc',v.loc,'nom',v.nom,'n',v.n,'dates',json((select json_group_array(value) from json_each(coalesce(v.dates,'[]')) where value>=?2))) j from f join villes v on v.ac=f.ac where v.dates is null or exists(select 1 from json_each(v.dates) where value>=?2)),
    i as (select tmdb t,json_object('loc',-min(cine),'nom',ville,'n',count(distinct cine),'dates',json_group_array(distinct substr(debut,1,10))) j from ind where tmdb in (select tmdb from f) and debut>=?2 group by tmdb,ville),
    g as (select t,json_group_array(json(j)) l from (select * from v union all select * from i) group by t)
    select json_object('at',?1,'films',json(coalesce(json_group_array(json_object('tmdb',tmdb,'ac',ac,'titre',titre,'sortie',sortie,'affiche',affiche,'chaines',json(coalesce(chaines,'[]')),'lu',coalesce(lu,case when ac is null then cine end),'villes',json(coalesce(g.l,'[]')))),'[]'))) j from f left join g on g.t=f.tmdb`).bind(now(), today()).first()).j;
}
async function fiche(e, id) {
  return (await e.DB.prepare(`select json_object('tmdb',f.tmdb,'ac',f.ac,'titre',f.titre,'sortie',f.sortie,'affiche',f.affiche,'chaines',json(coalesce(chaines,'[]')),'lu',coalesce(lu,case when f.ac is null then cine end),
    'villes',json((select coalesce(json_group_array(json(j)),'[]') from (
      select json_object('loc',v.loc,'nom',v.nom,'n',v.n,'dates',json((select json_group_array(value) from json_each(coalesce(v.dates,'[]')) where value>=?2))) j from villes v where v.ac=f.ac and (v.dates is null or exists(select 1 from json_each(v.dates) where value>=?2))
      union all select json_object('loc',-min(cine),'nom',ville,'n',count(distinct cine),'dates',json_group_array(distinct substr(debut,1,10))) from ind where tmdb=f.tmdb and debut>=?2 group by ville)))) j from films f where f.tmdb=?1`).bind(id, today()).first())?.j || "{}";
}
/** Horaires connus d’un film : salles AlloCiné lues aujourd’hui et indépendants à venir */
async function horaires(e, id, ac) {
  return (await e.DB.prepare(`select json_object('salles',json((select coalesce(json_group_array(json_object('id',s.id,'nom',s.nom,'adr',s.adr,'h',json(p.h))),'[]') from passages p join salles s on s.id=p.salle where p.ac=coalesce((select ac from films where tmdb=?1),?3) and p.jour>=date(?2,'-1 day'))),
    'ind',json((select coalesce(json_group_array(json_object('id',id,'cine',cine,'nom',nom,'ville',ville,'adr',adr,'lat',lat,'lon',lon,'d',debut,'v',version,'u',url)),'[]') from (select * from ind where tmdb=?1 and debut>=?2 order by debut limit 1500)))) j`).bind(id, today(), ac || -1).first()).j;
}
async function suivre(e, ids) {
  ids = [...new Set((Array.isArray(ids) ? ids : []).filter(i => Number.isInteger(i) && i > 0 && i < 1e8))].slice(0, 60);
  if (!ids.length) return;
  const t = now(), n = (await e.DB.prepare("select count(*) n from films where suivi>?").bind(t - 40 * JOUR).first()).n;
  if (n > 400) return;
  await e.DB.batch(ids.map(i => e.DB.prepare("insert into films(tmdb,suivi) values(?,?) on conflict(tmdb) do update set suivi=excluded.suivi").bind(i, t)));
}
export default {
  async scheduled(_, e, c) { c.waitUntil(tour(e).catch(x => put(e, "err", new Date().toISOString() + " " + String(x).slice(0, 300)))); },
  async fetch(r, e, c) {
    const u = new URL(r.url);
    try {
      if (r.method === "POST" && u.pathname === "/suivre") { const b = await r.text(); if (b.length > 4000) return json({}, 413, 0); await suivre(e, JSON.parse(b).ids); return json({ ok: 1 }, 200, 0); }
      if (r.method !== "GET") return json({}, 405, 0);
      const txtj = (s, age) => new Response(s, { headers: { "content-type": "application/json; charset=utf-8", "cache-control": `public, max-age=${age}` } });
      let m;
      if (u.pathname === "/ressorties") return txtj(await ressorties(e), 600);
      if ((m = u.pathname.match(/^\/film\/(\d{1,8})$/))) return txtj(await fiche(e, +m[1]), 300);
      if ((m = u.pathname.match(/^\/horaires\/(\d{1,8})(?:\/(\d{1,12}))?$/))) return txtj(await horaires(e, +m[1], +m[2]), 300);
      if (u.pathname === "/affiche") return json((await e.DB.prepare("select ac,titre from encours where vu>? limit 500").bind(now() - 4 * JOUR).all()).results, 200, 3600);
      if (u.pathname === "/") return json({
        films: await e.DB.prepare("select count(*) n, count(ac) ac, count(lu) lu from films").first(), villes: await e.DB.prepare("select count(*) n, count(dates) dates from villes").first(),
        salles: await e.DB.prepare("select count(*) n, count(lu) lu from salles").first(), trouves: await e.DB.prepare("select count(*) n, count(tmdb) tmdb from trouves").first(), passages: (await e.DB.prepare("select count(*) n from passages").first()).n,
        ind: await e.DB.prepare("select count(*) n, count(distinct cine) cinemas from ind").first(), deps: JSON.parse(await get(e, "deps") || "[]").length, pages: +(await get(e, "ac-" + today()) || 0), pause: +(await get(e, "pause") || 0) > now(), err: await get(e, "err"), ind_err: await get(e, "ind_err") }, 200, 10);
      return json({}, 404, 60);
    } catch { return json({ erreur: 1 }, 500, 0); }
  }
};
