# MT5 mit Bullion Monkey verbinde

De Expert Advisor `BullionMonkeySync` schickt jede gschlossene Trade und de Kontostand i en gheime GitHub-Gist. D'App liest de Gist alli 90 Sekunde.
MT5 muess dezue uf em Mac oder PC laufe (s'iPhone-MT5 cha keni Expert Advisors).

## 1. GitHub-Token mache
1. github.com → Profilbild → **Settings → Developer settings → Personal access tokens → Tokens (classic)**
2. **Generate new token (classic)**, Name "Bullion Monkey MT5", Ablauf "No expiration"
3. Nur s'Häkli bi **gist** setze → **Generate token** → Token kopiere

## 2. Expert Advisor in MT5 tue
1. MT5 → **Datei → Datenordner öffnen** → `MQL5/Experts` → `BullionMonkeySync.mq5` dri kopiere
2. Im Navigator rechtsklick uf "Expert Advisors" → **Aktualisieren**
3. **Extras → Optionen → Expert Advisors**: "Algorithmischen Handel erlauben" und "WebRequest für folgende URLs" mit `https://api.github.com`

## 3. Starte
1. `BullionMonkeySync` uf irgend es Chart zieh (z. B. XAUUSD)
2. Bi "Eingaben" s'Token bi **GitHubToken** iisetze, GistId leer lah → OK
3. Es Fenster zeigt d'**Gist-ID** aa (stoht au im Tab "Experten")

## 4. I de App verbinde
Bullion Monkey → Dashboard → **MT5-Verbindung** → Gist-ID iifüege → **Verbinden**

De Kontostand chunnt denn direkt vo MT5. D'Oktober-Tagessumme vom Screenshot wärded usblendet, will die Trades jetzt us MT5 chömed.
De EA handlet nüt, er liest nur d'Historie.
