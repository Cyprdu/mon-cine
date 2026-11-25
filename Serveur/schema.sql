create table if not exists films(tmdb integer primary key, ac integer, titre text, sortie text, affiche text, chaines text, jw integer default 0, suivi integer default 0, wiki integer, lu integer);
create table if not exists villes(ac integer, loc integer, nom text, n integer, dates text, lu integer, primary key(ac,loc));
create table if not exists encours(ac integer primary key, titre text, vu integer);
create table if not exists etat(k text primary key, v text);
