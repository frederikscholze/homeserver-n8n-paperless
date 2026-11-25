# Fehlersuche

Hier stehen die Probleme, die beim Aufbau aufgetreten sind. Jeder Eintrag folgt demselben Schema: Symptom, Diagnose, Ursache, Lösung. Domainnamen sind durch `example.com` ersetzt.

Allgemeine Vorgehensweise bei Fehlern in diesem Aufbau: von außen nach innen prüfen. Zuerst den Zustand der Container, dann deren Logs, dann die Weiterleitung im Nginx Proxy Manager.

```bash
docker compose ps
docker compose logs DIENSTNAME --tail 50
```

---

## 1. Fehler 502 Bad Gateway bei n8n

**Symptom:** Beim Aufruf von `https://n8n.example.com` erscheint "502 Bad Gateway", am PC und am Handy. Die Verschlüsselung funktioniert, das Zertifikat ist gültig.

**Diagnose:**

```bash
docker ps -a
```

Der n8n-Container steht auf `Restarting (1)`, startet also ständig neu. Das Log zeigt den Grund:

```bash
docker logs n8n-stack-n8n-1 --tail 50
```

```
Error: EACCES: permission denied, open '/home/node/.n8n/config'
```

Ein Test direkt auf dem Server bestätigt, dass nichts auf Port 5678 antwortet:

```bash
curl -I http://127.0.0.1:5678
```

**Ursache:** Der Datenordner `n8n_data` gehörte `root`. n8n läuft im Container aber als Benutzer `node` (Nummer 1000) und darf dort nicht schreiben. Dadurch stürzt der Container beim Start ab. Der Proxy findet keine Anwendung hinter sich und meldet 502.

**Lösung:**

```bash
docker compose down
chown -R 1000:1000 n8n_data
docker compose up -d
```

**Merke:** Ein 502 bedeutet, dass der Proxy läuft, aber die Anwendung dahinter nicht antwortet. Die Ursache liegt fast immer im Container, nicht im Proxy.

---

## 2. Falsche Annahme zur Umgebung

**Symptom:** Die Befehle `tail /var/log/nginx/error.log` und `cat /etc/nginx/sites-enabled/*` melden "No such file or directory".

**Ursache:** Es gibt keinen systemweit installierten Nginx. Der Proxy läuft als Container (Nginx Proxy Manager), seine Konfiguration liegt in der Weboberfläche und im Ordner `proxy_data`, nicht in `/etc/nginx`.

**Lösung:** Mit `docker ps -a` zuerst klären, was tatsächlich läuft, bevor man Konfigurationsdateien sucht.

**Merke:** Erst die Umgebung prüfen, dann die Fehlersuche beginnen.

---

## 3. Einstellungen von n8n wirken nicht

**Symptom:** n8n läuft, meldet beim Start aber eine falsche Adresse: `Editor is now accessible via` zeigt die Hauptdomain statt der Unterseite.

**Diagnose:** Beim Prüfen der `docker-compose.yml` fielen drei Fehler auf:

| In der Datei | Richtig |
|---|---|
| `N8N_LISTEN_ADRESS` | `N8N_LISTEN_ADDRESS` |
| `N8N_SCURE_COOCKIE` | `N8N_SECURE_COOKIE` |
| `WEBHOOK_URL=https://example.com` | Adresse der Unterseite, `N8N_WEBHOOK_URL` |

**Ursache:** Umgebungsvariablen mit falschem Namen werden von n8n ohne Fehlermeldung ignoriert. Zusätzlich zeigte die Webhook-Adresse auf die falsche Domain. Das Log wies außerdem darauf hin, dass `WEBHOOK_URL` veraltet ist und durch `N8N_WEBHOOK_URL` ersetzt wird.

**Lösung:** Namen korrigieren, Adresse auf die Unterseite setzen, Container neu erstellen (`docker compose down`, `docker compose up -d`). Die Meldung im Log prüfen:

```bash
docker logs n8n-stack-n8n-1 2>&1 | grep -i "accessible"
```

**Merke:** Eine Einstellung, die nicht wirkt, ist oft nur falsch geschrieben. Namen gegen die Dokumentation abgleichen.

---

## 4. YAML-Fehler: "mapping values are not allowed in this context"

**Symptom:** `docker compose up -d` bricht mit dieser Meldung ab, Zeile 3 wird genannt.

**Diagnose:** Mit sichtbaren Sonderzeichen lässt sich die Datei prüfen:

```bash
cat -A docker-compose.yml | head -n 15
```

Vor `services:` standen zwei zusätzliche Zeilen (`N8N` und eine Leerzeile). Außerdem war in einer Variable ein Unterstrich durch ein Leerzeichen ersetzt.

**Ursache:** Beim Einfügen in den Editor wurde ein Wort mitkopiert. YAML las es als eigenen Eintrag, wodurch `services:` danach ungültig wurde.

**Lösung:** Die Datei komplett neu schreiben statt im Editor zu flicken:

```bash
cat > docker-compose.yml << 'EOF'
...
EOF
```

Danach prüfen, dass die erste Zeile `services:` ist, und die Datei validieren:

```bash
head -n 3 docker-compose.yml
docker compose config > /dev/null && echo "OK"
```

**Merke:** `docker compose config` prüft eine Datei, bevor etwas gestartet wird. Beim Einfügen darauf achten, dass nichts vor oder nach dem Block mitkopiert wird.

---

## 5. Weiterleitung im Proxy

**Symptom (vorbeugend geprüft):** Im Nginx Proxy Manager ist als Ziel `127.0.0.1` naheliegend, führt aber ebenfalls zu 502.

**Ursache:** Der Proxy läuft selbst in einem Container. `127.0.0.1` bedeutet dort "dieser Container", nicht der Server.

**Lösung:** Als Ziel den Dienstnamen aus der compose-Datei eintragen (`n8n`, Port 5678 bzw. `paperless`, Port 8000). Docker löst diese Namen im internen Netzwerk auf. Ob das Netzwerk stimmt, zeigt:

```bash
docker compose exec proxy curl -I http://n8n:5678
```

---

## 6. Zugang zur Verwaltung des Proxys verloren

**Symptom:** Anmeldung am Nginx Proxy Manager nicht mehr möglich.

**Ursache:** Passwort vergessen. Der Nginx Proxy Manager bietet keinen Zurücksetzen-Knopf.

**Lösung:** Der Proxy speichert Zugangsdaten in einer SQLite-Datenbank. Nach einer Sicherungskopie wurde der Passwort-Hash des Benutzers direkt ersetzt:

```bash
docker compose stop proxy
cp proxy_data/database.sqlite proxy_data/database.sqlite.bak
HASH=$(htpasswd -bnBC 10 "" 'NEUES_PASSWORT' | tr -d ':\n' | sed 's/^\$2y/$2b/')
sqlite3 proxy_data/database.sqlite "UPDATE auth SET secret='$HASH' WHERE user_id=1;"
docker compose start proxy
```

Danach wurde die Sicherungskopie gelöscht, weil sie das alte Passwort enthielt.

**Merke:** Vor Eingriffen in eine Datenbank immer eine Kopie anlegen. Kopien mit Zugangsdaten danach entfernen.

---

## 7. Zugriff auf die Verwaltung per Tunnel scheitert

**Hintergrund:** Port 81 (Verwaltung des Proxys) war aus dem Internet erreichbar. In der compose-Datei wurde `'81:81'` zu `'127.0.0.1:81:81'` geändert. Seitdem ist er nur noch vom Server selbst erreichbar.

**Symptom:** Der Browser meldet "Verbindung fehlgeschlagen", wenn die Verwaltung über den Tunnel geöffnet werden soll.

**Diagnose:** Auf dem Server antwortet der Proxy (`curl -I http://127.0.0.1:81` liefert `200 OK`), und `docker compose ps proxy` zeigt `127.0.0.1:81->81/tcp`. Das Problem lag also nur bei der Tunnelverbindung auf dem Windows-Rechner.

**Ursache:** Der Tunnel steht nur, solange das Fenster mit dem laufenden `ssh -L`-Befehl offen bleibt. Er war nicht (mehr) aufgebaut.

**Lösung:** Tunnel in einem neuen Fenster auf dem Windows-Rechner aufbauen, offen lassen, im Browser `http://127.0.0.1:8181` öffnen.

```
ssh -L 8181:127.0.0.1:81 benutzer@server
```

**Merke:** Wenn der Dienst auf dem Server antwortet, liegt der Fehler bei der Verbindung davor.

---

## 8. Probleme beim Veröffentlichen auf GitHub

### 8.1 Leere Dateien

**Symptom:** `.gitignore` hatte 0 Bytes, `.env.example` war leer.

**Ursache:** Der Inhalt wurde beim Speichern im Editor nicht übernommen. Eine leere `.gitignore` schützt nicht vor dem versehentlichen Hochladen von Geheimnissen.

**Lösung:** Dateien per Befehl neu schreiben und anschließend prüfen:

```
echo .env> .gitignore
type .gitignore
dir /a .gitignore
```

Zusätzlich zeigte ein Test mit einer Datei `test.bak`, dass die Regeln wirken.

**Merke:** Dateien nach dem Anlegen mit `type` und `dir` prüfen. Besonders `.gitignore` vor dem ersten Commit testen.

### 8.2 Push abgelehnt: private E-Mail-Adresse

**Symptom:**

```
remote: error: GH007: Your push would publish a private email address.
 ! [remote rejected] main -> main (push declined due to email privacy restrictions)
```

**Ursache:** Der Commit enthielt die echte E-Mail-Adresse als Absender. GitHub lehnt das Hochladen ab, wenn der Schutz der privaten Adresse eingeschaltet ist.

**Lösung:** Den Schutz eingeschaltet lassen und die anonyme Adresse von GitHub (`...@users.noreply.github.com`) verwenden. Danach den Absender des vorhandenen Commits ersetzen:

```
git config --global user.email "ANONYME-ADRESSE"
git commit --amend --reset-author --no-edit
git push -u origin main
```

### 8.3 Fehlersuche bei der Prüfung vor dem Hochladen

Vor dem ersten Commit wurden alle Dateien auf Geheimnisse und Serveradressen durchsucht (`findstr`). In der `docker-compose.yml` stehen nur Platzhalter wie `${PAPERLESS_DB_PASSWORD}`. Die echten Werte liegen in der `.env`, die nicht im Repository ist.

---

## Allgemeine Erkenntnisse

- Befehle einzeln ausführen. Werden mehrere Zeilen auf einmal eingefügt, wird die Ausgabe unübersichtlich, und Fehler lassen sich nicht zuordnen.
- Vor jeder Änderung eine Kopie anlegen, nach der Änderung prüfen, ob alles noch erreichbar ist.
- Bei einer Fehlermeldung zuerst die genaue Meldung lesen. In den Beispielen oben stand die Ursache jeweils im Log oder in der ersten Zeile der Ausgabe.
