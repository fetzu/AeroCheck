**Letzte Aktualisierung**
Oktober 2026


Seit Version 6.8.0 zeichnet AéroCheck seine eigene Karte zum Fliegen, die Pilotenkarte. Diese Seite sagt, woher ihre Daten kommen, was wir davon behalten und was wir weglassen, wie sie zugeschnitten und aktualisiert wird und wer genannt wird. Abschnitt 4.6 der Open Database Licence verlangt, dass alle, die eine aus OpenStreetMap erstellte Karte nutzen, erfahren können, wie sie entstanden ist: Das ist diese Seite.


## 1.0 Was die Karte ist

Die Pilotenkarte wird auf Ihrem Gerät von MapLibre Native gezeichnet, aus Vektorkacheln, die wir jeden Monat aus OpenStreetMap erstellen, und aus dem Relief. Sie zeigt, was Sie aus dem Fenster suchen: Städte und Dörfer nach ihrer Grösse, Hauptstrassen, Eisenbahnen, Flüsse und Seen, Wälder, Siedlungsgebiete, Gletscher, Grenzen, Seilbahnen und Gipfel mit ihrer Höhe in Fuss. Die Luftfahrtebenen (Lufträume, Flugplätze, Verfahren, Ihre Route) liegen darüber, wie auf den Schweizer Karten.

Sie besteht aus zwei Teilen:
- **Der Weltumriss**, in der App selbst: Land, Meer, die grösseren Seen und Flüsse, Grenzen, Länder und Hauptstädte. Ihn zeigt die Karte dort, wo keine Region auf dem Gerät ist.
- **Regionen**, aus den vollständigen Daten erstellt: eine pro Land der Seite [Länder](/de/countries), die grossen in ihre Regionen geteilt (die US-Bundesstaaten, die deutschen Länder, die französischen Regionen…), etwa 236 insgesamt. Eine Region wird innerhalb eines monatlichen Kontingents online gelesen oder heruntergeladen und offline genutzt.


## 2.0 Woher die Daten kommen

- **OpenStreetMap**: © OpenStreetMap-Mitwirkende, unter der [Open Database Licence](https://opendatacommons.org/licenses/odbl/1-0/) (ODbL 1.0), gelesen über den täglichen Build der [Protomaps-Basiskarte](https://docs.protomaps.com/basemaps/downloads). Die Daten der Karte sind ein erzeugtes Werk im Sinne der ODbL: Die Daten selbst finden Sie auf [openstreetmap.org](https://www.openstreetmap.org/copyright).
- **Relief**: [Mapterhorn](https://mapterhorn.com), offene Geländedaten aus nationalen und weltweiten Höhenmodellen. Seine Quellen und ihre Lizenzen stehen unter [mapterhorn.com/attribution](https://mapterhorn.com/attribution).
- **Der Umriss jeder Region**: [Overture Maps](https://overturemaps.org), aus den Grenzen von OpenStreetMap, unter derselben ODbL: © OpenStreetMap-Mitwirkende, Overture Maps Foundation.
- **Ländernamen und grosse Flüsse** des Weltumrisses: [Natural Earth](https://www.naturalearthdata.com) (gemeinfrei).
- **Schrift**: [B612](https://github.com/polarsys/b612), für Cockpit-Bildschirme entworfen, unter der SIL Open Font License 1.1.
- **Darstellung**: [MapLibre Native](https://maplibre.org), unter der BSD-2-Clause-Lizenz.


## 3.0 Was wir behalten und was wir weglassen

Der Build liest die Kacheln von Protomaps und behält, Objekt für Objekt, was ein Pilot braucht. Die Geometrie dessen, was er behält, wird unverändert übernommen: Nichts wird ein zweites Mal vereinfacht oder verschoben.

### 3.1 Behalten
- Land und Bodenbedeckung.
- Wälder, Siedlungsgebiete (Wohnen, Gewerbe und Industrie) und Gletscher.
- Wasser: Meere, Seen, Flüsse und Kanäle, mit ihren Namen.
- Landesgrenzen.
- Strassen: Autobahnen, Autostrassen, Haupt- und Nebenstrassen, mit ihren Nummern, und ob sie im Tunnel verlaufen.
- Eisenbahnen: Hauptlinien, Schmalspurbahnen und Standseilbahnen, mit ihren Tunneln (keine Abstell- oder Dienstgleise). Luftseilbahnen und andere Seilbahnen.
- Orte: Städte, Kleinstädte, Dörfer, Weiler und Einzelhöfe, mit ihren Namen und ihrer Einwohnerzahl, die bestimmt, ab welchem Zoom ein Ort erscheint.

### 3.2 Hinzugefügt
- **Gipfel**, eine eigene Ebene aus den Gipfeln von OpenStreetMap: der Name, die Höhe in Fuss und die Entfernung zum nächsten höheren Gipfel, die bestimmt, ab welchem Zoom ein Gipfel erscheint (ein allein stehender Gipfel erscheint vor einer Kuppe auf einem Grat).

### 3.3 Weggelassen
- Gebäude, Geschäfte und andere Points of Interest, öffentlicher Verkehr, kleine Strassen, Feld- und Wanderwege sowie Kantons- und Regionsgrenzen.
- Jedes Feld, das die Karte nicht zeichnet: Ein Objekt behält seine Art, seinen Namen, seine Strassennummer oder seine Einwohnerzahl, sonst nichts.


## 4.0 An der Grenze zugeschnitten

Eine Region enthält die Daten innerhalb ihres eigenen Umrisses und nichts sonst, sodass zwei Regionen nie denselben Ort zweimal zeichnen. Der Umriss ist die Grenze von OpenStreetMap, wie Overture Maps sie veröffentlicht: an Land die Landesgrenze, auf See die Hoheitsgewässer (12 NM, 6 in der Ägäis) oder die Mitte einer Meerenge, jede Insel eingeschlossen. Jede Kachel, die ihn kreuzt, wird entlang des Umrisses zugeschnitten, auf jedem Zoom, und das Relief ausserhalb wird entfernt. Wo zwei Regionen aneinanderstossen, fügt die App ihre beiden Hälften einer Kachel zusammen; jenseits der Regionen auf dem Gerät übernimmt der Weltumriss. Die Grenzen sind die, die OpenStreetMap zeichnet.


## 5.0 Jeden Monat neu erstellt

Die Karte wird jeden Monat aus den neusten Daten von OpenStreetMap neu erstellt, und dieselben Daten ergeben immer dieselbe Datei, Byte für Byte. Jede Datei ist nach ihrem Inhalt benannt. Das hält die Aktualisierungen klein:
- Ein Gerät fragt die Datei einer Region unter diesem Namen an und fragt nur wieder, wenn sich der Name geändert hat: Eine unveränderte Region wird nie zweimal heruntergeladen.
- Beim Prüfen sagt das Gerät, welche Version es hat, und eine Antwort «unverändert» ist nur wenige Bytes gross.
- Eine heruntergeladene Region aktualisiert sich alle drei Monate selbst, im WLAN, nie im Flug. Bietet die App **Aktualisieren** an, lädt sie die neuere Version früher.

OpenStreetMap wird jede Minute bearbeitet, eine monatliche Karte liegt also höchstens einige Wochen zurück. Was auf der Karte fehlt oder falsch ist, korrigiert man am besten [in OpenStreetMap selbst](https://www.openstreetmap.org/fixthemap): Der nächste Build übernimmt es.


## 6.0 Wie die App die Karte erhält

Die Dateien liegen auf tiles.aerocheck.app, dem Speicher von Cloudflare unter unserem Namen. Eine heruntergeladene Region wird auf dem Gerät gelesen und funktioniert offline; die Hälfte der Regionen ist kleiner als 30 MB, die Schweiz mit Liechtenstein etwa 90 MB, die grössten einige hundert MB. Anderswo liest die App die Kacheln auf dem Bildschirm online (herausgezoomt aus einer Übersicht aller Regionen), innerhalb eines monatlichen Kontingents pro Gerät: 1'500 Kacheln, oder 15'000 mit AéroCheck Pro. Eine heruntergeladene Region zählt nie dazu. Was diese Abfragen zeigen und was wir davon behalten, steht in der [Datenschutzerklärung](/de/privacy), Abschnitt 3.10.


## 7.0 Luftbilder

Die Grundkarte **Luftbilder** zeigt offene behördliche Orthofotos, und nur diese. Jedes Gerät lädt sie vom behördlichen Dienst, der sie veröffentlicht, solange sie auf dem Bildschirm sind: AéroCheck hostet keine, liefert keine mit und lädt keine im Voraus herunter. Jede Quelle wird unter ihrer offenen Lizenz genutzt, an der Grenze des Gebiets zugeschnitten, das sie abdeckt, und mit ihrem eigenen Vermerk auf der Karte genannt, solange ihre Bilder zu sehen sind; an einer Grenze jede, die auf dem Bildschirm ist. Wo keine Behörde Bilder veröffentlicht, die wir nutzen dürfen, zeigt die Grundkarte keine Bilder.

| Gebiet | Vermerk des Anbieters | Lizenz |
|---|---|---|
| Schweiz, Liechtenstein | ©swisstopo | [Kostenlose Geodaten von swisstopo](https://www.swisstopo.admin.ch/de/nutzungsbedingungen-kostenlose-geodaten-und-geodienste) |
| Österreich | Datenquelle: basemap.at | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Frankreich | © IGN – BD ORTHO® | [Licence Ouverte 2.0](https://www.etalab.gouv.fr/licence-ouverte-open-licence/) |
| Niederlande | Beeldmateriaal.nl | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Luxemburg | © ACT Luxembourg | [CC0](https://creativecommons.org/publicdomain/zero/1.0/) |
| Belgien, Flandern | Orthofoto © Digitaal Vlaanderen | Modellicentie Gratis Hergebruik |
| Belgien, Brüssel | Ortho © UrbIS – paradigm.brussels | [CC0](https://creativecommons.org/publicdomain/zero/1.0/) |
| Tschechien | Ortofoto: ČÚZK | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Polen | Ortofotomapa © GUGiK (geoportal.gov.pl) | [Bedingungen des GUGiK](https://www.geoportal.gov.pl/pl/o-geoportalu/regulamin/) |
| Italien, Südtirol | © Autonome Provinz Bozen – Südtirol | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Deutschland, 12 Länder | Die Vermessungsverwaltung jedes Landes: Bayern, Baden-Württemberg, Nordrhein-Westfalen, Berlin, Brandenburg, Sachsen, Thüringen, Rheinland-Pfalz, Hessen, Schleswig-Holstein, Mecklenburg-Vorpommern, Bremen | CC BY 4.0, [dl-de/by-2-0](https://www.govdata.de/dl-de/by-2-0) oder [dl-de/zero-2-0](https://www.govdata.de/dl-de/zero-2-0), wie es jedes Land veröffentlicht |
| USA, ohne Alaska | USDA, USGS The National Map: Orthoimagery | Gemeinfrei |

Wo die Lizenz eines Anbieters verlangt, Änderungen zu kennzeichnen: Die Bilder sind an der Grenze des Gebiets zugeschnitten, das sie abdecken (Daten geändert), und sonst ist nichts verändert. Die Liste kann sich ohne App-Update ändern: Eine Quelle kommt hinzu, sobald ihre Lizenz geprüft ist, und wird abgeschaltet, wenn ihr Anbieter es verlangt. Was das Laden der Bilder jedem Anbieter zeigt, steht in der [Datenschutzerklärung](/de/privacy), Abschnitt 3.11.


## 8.0 Kontakt

Eine Frage zur Karte, oder ein Vermerk, den wir falsch übernommen haben: [Support](/de/support).
