# Bullion Monkey

Persönlichs Trading-Dashboard und News-Kalender. Lauft als Web-App uf em iPhone-Homescreen.
Trades und Iistellige bliibed lokal uf em Grät (localStorage), kei Login. Backup als JSON-Datei.

- `src/app.html`: de ganz App-Code (HTML, CSS, JS in einere Datei)
- `sh build.sh`: baut `docs/index.html` us `src/app.html`
- `docs/`: d Website, wo GitHub Pages usliferet
- `docs/news.json`: Forex-Factory-Kalender vo dere Wuche, wird vom Workflow `.github/workflows/news.yml` zwöimol am Tag aktualisiert
