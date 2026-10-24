**Letzte Aktualisierung**
Oktober 2026


AéroCheck ist eine Open-Source-App für Piloten, für Flugchecklisten und das Situationsbewusstsein, entwickelt und herausgegeben von Julien Bono in der Schweiz. Diese Seite sagt, was die App auf Ihrem Gerät speichert, was sie sendet, an wen und wie genau, und was unsere eigenen Server aufbewahren.

Kurz gesagt: Es gibt kein Konto, keine Werbung, keine Nutzungsanalyse und kein Tracking. Ihre Flüge werden auf Ihrem Gerät gespeichert und, wenn Sie synchronisieren, in Ihrer eigenen iCloud. Einige Abfragen enthalten eine Position, eine Route oder einige Punkte eines Flugwegs, die meisten davon gerundet, damit die App Wetter, Gelände und Lufträume anzeigen kann (Abschnitt 3.0 führt sie alle auf). Unser API-Server bewahrt einen Datensatz zu einem Kauf auf, nie einen Standort. Wenn Sie uns die Checkliste eines Flugzeugs senden, über diese Website oder aus der App, bewahren wir auf, was Sie senden, so lange die Anfrage es erfordert (Abschnitt 4.3).


## 1.0 Was auf Ihrem Gerät bleibt

### 1.1 Flüge und Flugbuch
Der GPS-Flugweg, die Zeiten, die Landungen, die Flugplanungen, die Routen und Ihr Flugbuch werden im eigenen Speicher der App auf dem Gerät abgelegt und, wenn Sie es zulassen, in Ihrer iCloud (Abschnitt 2.0). Abgesehen von den gerundeten Punkten, die Abschnitt 3.0 aufführt, verlassen sie das Gerät nur, wenn Sie sie exportieren oder teilen (Abschnitt 5.0).

### 1.2 Standort und Bewegung
Die App verwendet das GPS für die mitlaufende Karte, den aufgezeichneten Flugweg, die Instrumente und die automatische Erkennung von Starts und Landungen, und den barometrischen Höhenmesser (Bewegungsdaten) für die Höhe. Die Messwerte des Barometers verlassen das Gerät nie. Die Abfragen, die eine Position enthalten, sind alle in Abschnitt 3.0 aufgeführt.

### 1.3 Ihre eigenen Geräte
Die Apple Watch-App und der Begleitmodus (iPad und iPhone zusammen) tauschen Flugdaten direkt zwischen Ihren eigenen Geräten aus, ohne über einen Server zu gehen. Das Widget auf dem Home-Bildschirm liest die Liste Ihrer Flugzeuge vom Gerät.

### 1.4 Keine Nutzungsanalyse, kein Tracking
AéroCheck enthält kein SDK für Nutzungsanalyse oder Werbung, kein Werkzeug für Absturzberichte und keinerlei Tracking, und es verwendet die Werbe-ID nicht. Wenn Sie es in iOS erlauben (Einstellungen, Datenschutz & Sicherheit, Analyse & Verbesserungen, «Mit App-Entwicklern teilen»), gibt Apple anonymisierte Absturzberichte an den Entwickler weiter; das ist eine Einstellung von Apple, nicht der App.


## 2.0 iCloud

Ist «Mit iCloud synchronisieren» eingeschaltet (in den Einstellungen der App, standardmässig eingeschaltet), werden Ihre Flüge (mit ihren Flugwegen), Flugplanungen, Reisen, Flugseiten und Einstellungen (einschliesslich der Namen von Pilot und Fluglehrer, die Sie eingeben) im Ordner von AéroCheck in Ihrem iCloud Drive gespeichert, weshalb Sie sie auch in der Dateien-App sehen, und Einstellungen und Flüge werden über die private Datenbank der App in Ihrem iCloud-Account zwischen Ihren Geräten synchronisiert. Beides ist Ihr eigener iCloud-Account: Apple speichert die Daten gemäss der [Datenschutzrichtlinie von Apple](https://www.apple.com/legal/privacy/), und der Entwickler hat keinen Zugriff darauf.

Ist der Schalter ausgeschaltet, bleibt alles auf dem Gerät: Die App liest weder in ihrem Ordner in iCloud Drive noch schreibt sie dorthin, und sie synchronisiert nichts. Beim Ausschalten kopiert sie zuerst auf das Gerät, was in iCloud Drive liegt, und lässt die Dateien in iCloud Drive, wo sie sind (löschen Sie sie in der Dateien-App, wenn sie verschwinden sollen); beim Wiedereinschalten kopiert sie zurück nach iCloud Drive, was Sie in der Zwischenzeit getan haben. Der Schalter gilt für das Gerät, auf dem er eingestellt ist.


## 3.0 Was Ihr Gerät verlässt, und an wen

«Gerundet» bedeutet im Folgenden, dass die Position auf ein Raster eingerastet wird, bevor die Abfrage das Gerät verlässt. Zur Grössenordnung: In der Schweiz misst ein Viertelgrad etwa 28 mal 19 km, drei Dezimalstellen entsprechen etwa 100 m und zwei Dezimalstellen etwa 1 km.

### 3.1 Wetter-Proxy von AéroCheck (wx.aerocheck.app)
Unser eigener kleiner Server, der das Flugwetter für die App abruft.
- METAR und SIGMET in Ihrer Nähe: Ihre Position, auf einen Viertelgrad gerundet, während ein Flug läuft oder die Navigationskarte offen ist, höchstens alle fünf Minuten.
- TAF: der ICAO-Code eines Flugplatzes (Ihr geplantes Ziel während des Anflugbriefings, sonst die nächstgelegene Station).
- Höhenwinde: jeder Wegpunkt der Route, die Sie planen, auf einen Viertelgrad gerundet, und Ihre Position, ebenso gerundet, wenn Sie im Flug Ausweichen öffnen.
- Wetterkachel von Vorbereiten, solange die Seite eines Flugs vor dem Flug offen ist, höchstens alle zehn Minuten (ausser Sie aktualisieren sie): die Positionen des Abflugflugplatzes, des Zielflugplatzes und der Ausweichflugplätze, jede auf einen Viertelgrad gerundet (für ihre METAR und, wenn ein Flugplatz keinen TAF hat, für die nächstgelegenen TAF), ihre ICAO-Codes (für einen TAF über seinen Code) und die Punkte der Route, auf zwei Dezimalstellen gerundet, höchstens 30, für die SIGMET entlang der Route.

Der Proxy rundet auf seiner Seite noch einmal und fragt dann [aviationweather.gov](https://aviationweather.gov) (den National Weather Service der USA) nach den METAR-Stationen oder den TAF in einem Rechteck um diesen Rasterpunkt, nach einem TAF über seinen ICAO-Code und nach der SIGMET-Liste ohne jede Position, die er selbst filtert, um Ihre Position oder entlang Ihrer Route, und [Open-Meteo](https://open-meteo.com) nach den Höhenwinden an diesem Rasterpunkt. Ihre IP-Adresse gibt er nie weiter. Seine Antworten bewahrt er fünf Minuten bis eine Stunde im Cache von Cloudflare auf, nach gerundeter Position (die SIGMET entlang einer Route bewahrt er nicht auf), und er hat keine Datenbank.

### 3.2 swisstopo (Bundesamt für Landestopografie, geo.admin.ch)
- Kacheln der Schweizer Karten (die ICAO-Karte, die Segelflugkarte, die Landeskarten und Luftbilder), auf der Navigationskarte und auf Bildern zum Teilen mit einer Schweizer Ebene: Die angeforderten Kacheln zeigen den Bereich auf dem Bildschirm, und die Navigationskarte folgt dem Flugzeug. Auf der ICAO-Karte ist eine Kachel etwa 7 km breit, auf den detailliertesten Karten etwa 100 m.
- Gelände in der Schweiz: die Wegpunkte einer Route, die Sie planen (Routenprofil, «Höhen festlegen», die Geländehöhe eines Wegpunkts, den Sie bearbeiten), auf den Meter gerundet; und wenn Sie dem Bild zum Teilen eines Flugs das Gelände hinzufügen, bis zu 200 Punkte des aufgezeichneten Flugwegs, Anfangs- und Endpunkt eingeschlossen, auf den Meter gerundet.
- Bodenwind von MeteoSchweiz, für das Abflug- und das Anflugbriefing: Während eines Flugs lädt die App alle zehn Minuten den ganzen aktuellen Winddatensatz von data.geo.admin.ch herunter, ohne jede Position. Sie tut das nur in der Schweiz oder in ihrer Nähe (so viel verrät also die Abfrage selbst).

### 3.3 Open-Meteo (open-meteo.com)
Gelände ausserhalb der Schweiz, direkt von der App gesendet: Punkte entlang einer Route, die Sie planen («Höhen festlegen»), oder bis zu 80 Punkte eines aufgezeichneten Flugwegs, wenn Sie seinem Bild zum Teilen das Gelände hinzufügen, Anfangs- und Endpunkt eingeschlossen, auf drei Dezimalstellen gerundet. Die Höhenwinde gehen über unseren Proxy an Open-Meteo (Abschnitt 3.1).

### 3.4 OpenAIP (openaip.net)
- Lufträume und andere Luftfahrtdaten werden pro Land heruntergeladen: Die Abfrage nennt das Land, sonst nichts. Für eine geplante Route fragt die App OpenAIP, wie gross die Daten der Länder sind, die die Route überquert und die Sie noch nicht heruntergeladen haben (nur Ländercodes).
- «Online-Luftraumdaten» (Einstellungen, standardmässig aus): Solange die Einstellung eingeschaltet ist, keine Luftraumdaten heruntergeladen sind und die Navigationskarte offen ist, Ihre Position auf zwei Dezimalstellen gerundet, höchstens einmal pro Minute und nur, sobald die letzte Antwort mehr als fünf Minuten alt ist oder sich das Flugzeug um mehr als 10 NM bewegt hat.
- Kartenkacheln von OpenAIP (standardmässig aus): Die Kacheln zeigen den Bereich auf dem Bildschirm.

### 3.5 Apple
- Die Kartenebenen von Apple, die Vorschaubilder der Routen und die Karten auf Bildern zum Teilen (ausser Sie wählen eine Schweizer Ebene) stammen von Apple Karten, das den angezeigten Bereich erhält.
- Bei der ersten Einrichtung einmal Ihre aktuelle Position, um Ihr Land zu bestimmen und vorzuschlagen, was heruntergeladen werden soll.
- Käufe laufen über den App Store; die App sieht weder Ihre Zahlungsdaten noch Ihre Apple-ID.

### 3.6 OurAirports
Die Flugplatzdatenbank wird vollständig heruntergeladen, ohne jede Position.

### 3.7 API-Server von AéroCheck (api.aerocheck.app)
Nie eine Position. Wenn Sie ein Flugzeug öffnen, sendet die App seine Kennung, sein Kennzeichen und die Sprache, die Sie verwenden, um die richtige Checkliste zu erhalten. Mit AéroCheck Pro sendet die App zudem den Kaufnachweis, den Apple ihr gibt (eine von Apple signierte Transaktion), und die ursprüngliche Transaktions-ID dieses Kaufs, und von da an bei jeder Abfrage ein Sitzungstoken. Was der Server aufbewahrt, steht in Abschnitt 4.0.

Derselbe Server stellt als kleine Dateien die VFR-Verfahren von open flightmaps (Platzrunden, VFR-An- und -Abflugrouten und die Meldepunkte, die OpenAIP fehlen), die Liste der Links zu den offiziellen Karten, das Briefing-Verzeichnis (die offiziellen Seiten jedes Landes und seine Regel zum Schliessen eines ATC-Flugplans) und die Platzrunden der US-Flugplätze bereit. Die App lädt die Verfahren pro Land herunter, mit den übrigen Luftfahrtdaten (die Abfrage nennt das Land, sonst nichts), die Kartenliste und das Briefing-Verzeichnis etwa einmal pro Woche, und die Platzrunden, wenn sie zum ersten Mal einen US-Flugplatz zeigt, danach höchstens einmal pro Woche. Auch hier keine Position und kein Sitzungstoken.

### 3.8 Seiten, die Sie in Ihrem Browser öffnen
Einige Tasten öffnen eine Seite in Ihrem Browser, statt selbst etwas abzurufen: Die Briefing-Links auf der Seite eines Flugs öffnen die Seite ihres Herausgebers, und die Nummern des Abschlusses starten einen Anruf. Die App sendet dem Herausgeber von sich aus nichts: Die Website, auf die Sie gelangen, erhält, was ihr jeder Besuch sendet. Zwei dieser Links sagen, was Sie gerade angesehen haben:
- «Offizielle Karte» öffnet die Karte des Flugplatzes auf der Website ihres Herausgebers, des nationalen Flugsicherungs- oder Luftfahrtinformationsdienstes seines Landes. Führt der Link zur eigenen Karte des Flugplatzes (Deutschland, Frankreich, die USA und 11 weitere Länder), erfährt der Herausgeber daraus den Flugplatz; führt er zu einer einzigen Seite für das ganze Land (SkyBriefing in der Schweiz, Österreich, Griechenland, Australien, Neuseeland und die Anmeldeportale Kroatiens und Bulgariens), bekommt der Herausgeber unabhängig vom Flugplatz denselben Seitenaufruf.
- «Fehler melden», bei einer Platzrunde oder einer VFR-Route, öffnet das Fehlermeldeformular von open flightmaps (ein Google-Formular, für das die [Datenschutzerklärung von Google](https://policies.google.com/privacy) gilt) mit bereits ausgefüllter Beschreibung: die Region, der AIRAC-Zyklus, der Flugplatz, das Verfahren und seine Kennung bei open flightmaps sowie die Position der Beschriftung, auf die Sie getippt haben (ein Punkt des Verfahrens, nicht Ihrer). Nichts über Sie: Das Formular hat ein eigenes E-Mail-Feld, das Sie leer lassen können. Ohne das Formular bereitet die App denselben Text als E-Mail an open flightmaps vor, die Sie senden oder nicht.


### 3.9 Anfrageserver von AéroCheck (intake.aerocheck.app)
Nur wenn Sie uns aus der App die Checkliste eines Flugzeugs senden (Flugzeuge › «Senden Sie uns die Checkliste eines Flugzeugs»). Keine Position. Die App sendet:
- das Kennzeichen, das Sie nachschlagen, um zu wissen, ob AéroCheck es schon hat;
- was Sie ausfüllen, und die Dateien, die Sie hinzufügen, so wie das Formular der Website sie sendet (Abschnitt 4.3). Ein Foto geht ohne die Position, die es enthalten kann: Die App entfernt sie vorher. Ein Scan wird auf dem Gerät zu einem PDF;
- für die Prüfung gegen Roboter öffnet die App eine Seite dieser Website, aerocheck.app/send/app/, in einer kleinen Webansicht, die Cloudflare Turnstile lädt, wie es das Formular tut.

Ist eine Anfrage gesendet, behält die App ihre Nummer und ihren Link auf dem Gerät (den Link im Schlüsselbund des Geräts) und führt sie unter «Ihre Anfragen» auf. Wenn die App in den Vordergrund kommt, höchstens alle drei Stunden, fragt sie den Anfrageserver, wo jede offene Anfrage steht, und sendet dabei den Code dieses Links und sonst nichts. Eine Anfrage, die seit 30 Tagen abgeschlossen ist, verschwindet aus der Liste.


## 4.0 Was unsere Server aufbewahren

Unsere drei Server (die API, der Wetter-Proxy und der, der die Flugzeuganfragen empfängt) laufen bei Cloudflare, das die IP-Adresse jeder Abfrage bearbeitet, um sie zuzustellen, gemäss der [Datenschutzrichtlinie von Cloudflare](https://www.cloudflare.com/privacypolicy/).

### 4.1 API-Server
- Pro Kauf ein Datensatz, abgelegt unter der ursprünglichen Transaktions-ID des Kaufs: sein Status, sein Ablaufdatum, das Produkt, die Umgebung (App Store oder Test), ob er sich verlängert und wann er zuletzt geprüft wurde. Er wird bis 30 Tage nach dem Ablaufdatum eines Abonnements aufbewahrt, während 90 Tagen nach der letzten Prüfung eines Kaufs von Lebenslang und während 7 Tagen, sobald ein Kauf verfallen ist oder zurückerstattet wurde.
- Zu welchem Datensatz ein Kauf gehört, und eine Markierung, falls Apple eine Rückerstattung meldet, während 400 Tagen.
- Die Sitzungstoken, mit denen sich die App authentifiziert, nur als SHA-256-Hashes (nie die Token selbst), während 180 Tagen, mit einer Liste dieser Hashes pro Kauf, damit höchstens fünf gleichzeitig gültig sind.
- Ihre IP-Adresse, als Teil eines Zugriffszählers, der begrenzt, wie oft eine Adresse den Server aufrufen darf, während einer Minute.

Apple benachrichtigt den Server über Abläufe, Rückerstattungen und Widerrufe; diese Mitteilungen aktualisieren nur den Datensatz des Kaufs (und setzen die Markierung der Rückerstattung). Der Server erfährt nie Ihren Namen, Ihre E-Mail-Adresse oder Ihre Apple-ID und erhält nie eine Position. Seine Protokolle halten die Art des Ereignisses fest und Kennungen, die auf ihre letzten vier Zeichen gekürzt sind. Weil der Datensatz des Kaufs unter einer Kennung abgelegt ist, deklarieren die Datenschutzangaben im App Store den Kaufverlauf und eine Benutzer-ID als mit Ihnen verknüpft, verwendet für die Funktionalität der App und nie für Tracking.

### 4.2 Wetter-Proxy
Keine Datenbank und keine eigenen Protokolle: nur der in Abschnitt 3.1 beschriebene Cache.

### 4.3 Flugzeuganfragen (intake.aerocheck.app)
Nur wenn Sie uns die Checkliste eines Flugzeugs senden, über [aerocheck.app/de/send](/de/send) oder aus der App (Abschnitt 3.9). Der Anfrageserver bewahrt auf:
- was Sie eingegeben haben: die Kennzeichen, den Flugzeugtyp, den Club, ob Sie sie für den Club senden, die Sprachen der Checkliste, Ihre Notizen, Ihre E-Mail-Adresse, Ihren Namen, falls Sie einen angeben, und die E-Mail-Adresse der Kontaktperson des Clubs, falls Sie sie angeben (gleich oder später);
- die Dateien, die Sie senden (das Dokument des Clubs, als PDF oder Bilder), in Cloudflare R2, und die Anfrage in einer Cloudflare-D1-Datenbank, mit ihrem Verlauf: jeden Status, wann er sich geändert hat, und die Nachrichten, die wir Ihnen schreiben;
- die Antwort des Clubs, wenn er angefragt wird: Name und Funktion der Person, die für ihn antwortet, den Entscheid und ihre Nachricht;
- Ihre Rückmeldung und Ihre Nachricht, wenn Sie den Entwurf gegenlesen;
- die Links zur Seite Ihrer Anfrage und zur Seite des Clubs, nur als SHA-256-Hashes (die Links selbst stehen in den E-Mails, nie bei uns);
- Ihre IP-Adresse, in einem Zugriffszähler, der begrenzt, wie oft eine Adresse senden darf, höchstens während einer Minute.

Das Formular ist durch Cloudflare Turnstile geschützt, das sich Ihren Browser (in der App deren Webansicht) ansieht, um einen Menschen von einem Roboter zu unterscheiden, gemäss dem [Datenschutzzusatz von Cloudflare für Turnstile](https://www.cloudflare.com/turnstile-privacy-policy/); der Server prüft nur die Antwort von Turnstile.

Wer das liest: Julien Bono, der AéroCheck entwickelt, liest die Anfrage und ihre Dateien, um die Checkliste für die App vorzubereiten. Jede Anfrage wird zudem als Issue in einem privaten GitHub-Repository verfolgt: die Kennzeichen, der Typ, der Club, Ihre Notizen, Namen und Grössen der Dateien und, als Kommentare, die Antwort des Clubs und Ihre Nachricht zum Gegenlesen; nie eine E-Mail-Adresse. In die App gelangt die Checkliste, nie Ihre Datei, Ihr Name oder Ihre Adresse.

Die E-Mails zu Ihrer Anfrage (Eingang, eine Rückfrage, in der App) und der Link des Clubs werden über [Resend](https://resend.com/legal/privacy-policy) versandt, einen E-Mail-Dienst mit Sitz in den Vereinigten Staaten, der die Adresse, die Nachricht und den Link erhält, um sie zuzustellen. Antworten erreichen support@aerocheck.app.

Wie lange: Alles wird aufbewahrt, solange die Anfrage offen ist. 90 Tage, nachdem sie abgeschlossen wurde (in der App, abgelehnt oder ein Duplikat), werden die Dateien gelöscht, ebenso jede E-Mail-Adresse, Ihr Name, Ihre Notizen, Name und Funktion der Person, die für den Club geantwortet hat, und die Nachrichten; auf dem Anfrageserver bleibt der Datensatz der Anfrage (ihre Nummer, die Kennzeichen, der Typ, der Club, ihre Status mit Datum). Das GitHub-Issue bleibt, wie es ist (es enthielt nie eine E-Mail-Adresse oder Ihren Namen), damit wir wissen, woher eine Checkliste stammt. Eine Anfrage, deren Dateien nie fertig hochgeladen wurden, wird nach 24 Stunden gelöscht. Um eine Anfrage früher löschen zu lassen oder um zu erfahren, was wir darüber aufbewahren, schreiben Sie an support@aerocheck.app oder antworten Sie auf eine unserer E-Mails.


## 5.0 Export und Teilen

Sie können Flüge (GPX, JSON, ZIP), Ihr Flugbuch (PDF, CSV), Flugplanungen und Nav-Logs (GPX, JSON, Tabelle, PDF) sowie Bilder zum Teilen exportieren oder teilen. Nichts wird exportiert, ohne dass Sie es verlangen. Die Kopie, die die App für das Fenster zum Teilen oder die Vorschau vorbereitet, wird gelöscht, sobald sich dieses Fenster schliesst (oder beim nächsten Öffnen der App, falls die App vorher beendet wurde). Einmal geteilt, liegt die Datei in Ihrer Hand: Sie kann Ihren Namen und einen detaillierten Standortverlauf enthalten.


## 6.0 Berechtigungen

- Standort «Beim Verwenden der App» stellt die Karte dar und zeichnet den Flug auf; «Immer» zeichnet weiter auf, wenn sich der Bildschirm sperrt oder Sie im Flug die App wechseln.
- Bewegung lässt die App den barometrischen Höhenmesser lesen; die Messwerte bleiben auf dem Gerät.
- Fotos (nur hinzufügen) lässt Sie ein Bild zum Teilen in Ihrer Fotomediathek speichern. Die App kann Ihre Fotos nicht sehen: Für eine Flugzeuganfrage erhält sie nur die, die Sie auswählen.
- Kamera, nur um eine Checkliste für eine Flugzeuganfrage zu scannen; die Seiten bleiben auf dem Gerät, bis Sie die Anfrage senden.

Sie können jede davon jederzeit in der Einstellungen-App von iOS ändern.


## 7.0 Ihre Daten löschen

Wenn Sie die App löschen, werden ihre Daten auf dem Gerät gelöscht. Um zu entfernen, was in Ihrer iCloud liegt, löschen Sie den Ordner von AéroCheck in iCloud Drive und die iCloud-Daten der App (in der Einstellungen-App von iOS, unter Ihrem Namen, iCloud, Speicher). Der Datensatz des Kaufs auf unserem Server läuft von selbst ab (Abschnitt 4.1); um ihn früher löschen zu lassen, kontaktieren Sie uns (Abschnitt 10.0). Eine Flugzeuganfrage wird gelöscht, wie es Abschnitt 4.3 sagt, oder früher, wenn Sie an support@aerocheck.app schreiben. Wenn Sie sie aus der Liste der App entfernen (langes Drücken), vergisst die App sie nur auf dem Gerät.


## 8.0 Diese Website

Die Website selbst setzt keine Cookies und führt keine Nutzungsanalyse durch. Sie wird von GitHub Pages über Cloudflare ausgeliefert, und die Flugzeugseite fragt von Ihrem Browser aus api.aerocheck.app nach der aktuellen Liste. Die Anfrageseiten (eine Checkliste senden, eine Anfrage verfolgen, die Antwort eines Clubs) sprechen von Ihrem Browser aus mit intake.aerocheck.app (Abschnitt 4.3), und das Formular lädt Cloudflare Turnstile von challenges.cloudflare.com. Die Links in unseren E-Mails tragen ihren Code nach einem «#», den ein Browser nie an die Website sendet: Nur der Anfrageserver erhält ihn, um die Anfrage zu öffnen.

Die Länderseite öffnet sich mit dem Land, in dem Sie am wahrscheinlichsten fliegen, geschätzt anhand der Zeitzone Ihres Geräts oder sonst der Sprache Ihres Browsers, wie Ihr Browser sie ohnehin jeder Seite mitteilt. Die Schätzung geschieht in Ihrem Browser: Nichts wird gesendet, gespeichert oder nachgeschlagen, und die Seite sagt, woraus sie geschätzt hat.


## 9.0 Open Source und Änderungen

AéroCheck ist Open Source: Der [Quellcode](https://github.com/fetzu/AeroCheck) erlaubt allen, nachzuprüfen, was diese Seite sagt. Wir aktualisieren diese Datenschutzerklärung, wenn die App oder diese Website ändert, was sie sendet; das Datum oben sagt, wann das zuletzt geschah.


## 10.0 Kontakt

Für Fragen zu dieser Datenschutzerklärung oder zu Ihren Daten eröffnen Sie ein Issue im [GitHub-Repository](https://github.com/fetzu/AeroCheck/issues) (ohne Personendaten darin: Wir nehmen mit Ihnen Kontakt auf, um die Sache weiterzuverfolgen).

Siehe auch die [Nutzungsbedingungen](/de/terms), die darlegen, was AéroCheck ist, was es nicht ist und warum der PIC für alles verantwortlich bleibt, was es Ihnen anzeigt.
