create table if not exists films(tmdb integer primary key, ac integer, titre text, sortie text, affiche text, chaines text, jw integer default 0, suivi integer default 0, wiki integer, lu integer, cine integer default 0);
create table if not exists villes(ac integer, loc integer, nom text, n integer, dates text, lu integer, primary key(ac,loc));
create table if not exists encours(ac integer primary key, titre text, vu integer);
create table if not exists etat(k text primary key, v text);
create table if not exists salles(id text primary key, nom text, adr text, vu integer, lu integer, n integer);
create table if not exists passages(salle text, ac integer, jour text, h text, primary key(salle,ac)) without rowid;
create index if not exists passages_ac on passages(ac);
create table if not exists trouves(ac integer primary key, titre text, sortie text, affiche text, vu integer, wiki integer, tmdb integer, lu integer);
create table if not exists ind(id text primary key, tmdb integer, titre text, cine integer, nom text, ville text, adr text, lat real, lon real, debut text, version text, url text, affiche text, vu integer) without rowid;
create index if not exists ind_tmdb on ind(tmdb);
create table if not exists tmeta(tmdb integer primary key, titre text, affiche text, sortie text);
-- Index : chaque minute, le serveur va droit à la prochaine salle ou ville au lieu de relire la table
create index if not exists salles_lu on salles(lu, vu);
create index if not exists villes_lu on villes(lu);
create index if not exists films_ac on films(ac);
create index if not exists tmeta_sortie on tmeta(sortie);
