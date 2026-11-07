**Letzte Aktualisierung**
November 2026


Seit Version 6.8.0 bietet AéroCheck seine eigene Karte zum Fliegen: den Atlas. Diese Seite erklärt, woher ihre Daten kommen, was wir davon behalten (und was wir weglassen), wie sie zugeschnitten und aktualisiert wird und wer genannt wird (gemäss Abschnitt 4.6 der Open Database Licence).


## 1.0 Was die Karte ist

Der Atlas wird auf Ihrem Gerät von MapLibre Native gezeichnet, aus Vektorkacheln, die wir jeden Monat aus OpenStreetMap erstellen, und aus dem Relief von Mapterhorn. Er zeigt, was Sie aus dem Cockpit suchen würden: Städte und Dörfer (nach ihrer Grösse), Hauptstrassen, Eisenbahnen, Flüsse und Seen, Wälder, Siedlungsgebiete, Gletscher, Grenzen, Seilbahnen und Gipfel mit ihrer Höhe in Fuss. Die Luftfahrtebenen (Lufträume, Flugplätze, Verfahren und Ihre Route) liegen darüber, ähnlich wie auf den Schweizer Karten.

Er besteht aus zwei Teilen:
- Der Weltumriss, der mit der App geliefert wird: Land, Meer, die grösseren Seen und Flüsse, Grenzen, Länder und Hauptstädte. Auf ihn greift die Karte zurück, wenn sie keine Region zeigen kann, d. h. offline ausserhalb der heruntergeladenen Regionen, oder wenn das Online-Kontingent des Monats aufgebraucht ist.
- Die Regionen, aus den vollständigen Daten erstellt: eine pro Land auf der Seite [Länder](/de/countries), die grösseren weiter unterteilt (die US-Bundesstaaten, die deutschen Länder, die französischen Regionen…), etwa 236 insgesamt. Eine Region wird entweder online geladen (innerhalb eines monatlichen Kontingents) oder heruntergeladen und offline genutzt.


## 2.0 Woher die Daten kommen

- OpenStreetMap: © OpenStreetMap-Mitwirkende, unter der [Open Database Licence](https://opendatacommons.org/licenses/odbl/1-0/) (ODbL 1.0), gelesen über den täglichen Build der [Protomaps-Basiskarte](https://docs.protomaps.com/basemaps/downloads). Die Daten der Karte sind ein erzeugtes Werk im Sinne der ODbL; die Daten selbst finden Sie auf [openstreetmap.org](https://www.openstreetmap.org/copyright).
- Relief: [Mapterhorn](https://mapterhorn.com), offene Geländedaten aus nationalen und globalen Höhenmodellen. Seine Quellen und deren Lizenzen sind auf [mapterhorn.com/attribution](https://mapterhorn.com/attribution) aufgeführt.
- Umrisse der Regionen: [Overture Maps](https://overturemaps.org), aus den Grenzen von OpenStreetMap und unter derselben ODbL (© OpenStreetMap-Mitwirkende, Overture Maps Foundation).
- Ländernamen und grosse Flüsse des Weltumrisses: [Natural Earth](https://www.naturalearthdata.com) (gemeinfrei).
- Schrift: [B612](https://github.com/polarsys/b612), für Cockpit-Bildschirme entworfen, unter der SIL Open Font License 1.1.
- Darstellung: [MapLibre Native](https://maplibre.org), unter der BSD-2-Clause-Lizenz.


## 3.0 Was wir behalten und was wir weglassen

Unser Build liest die Protomaps-Kacheln und behält, Element für Element, was ein Pilot tatsächlich braucht (oder genauer: was ein Pilot aus dem Cockpit sucht). Was er behält, wird unverändert übernommen: Wir vereinfachen und verschieben es nicht.

### 3.1 Behalten
- Land und Bodenbedeckung.
- Wälder/Gehölze, Siedlungsgebiete (Wohn-, Gewerbe- und Industriegebiete) und Gletscher.
- Gewässer: Meere, Seen, Flüsse und Kanäle, mit ihren Namen.
- Landesgrenzen.
- Strassen: Autobahnen, Autostrassen, Haupt- und Nebenstrassen, mit ihren Nummern (und ob sie durch einen Tunnel führen).
- Eisenbahnen: Hauptstrecken, Schmalspurbahnen und Standseilbahnen, mit ihren Tunneln (aber ohne Abstell- und Betriebsgleise), sowie Seilbahnen und andere Luftseilbahnen.
- Orte: Städte, Kleinstädte, Dörfer, Weiler und Einzelhöfe, mit ihren Namen und ihrer Einwohnerzahl (die bestimmt, ab welcher Zoomstufe ein Ort erscheint).

### 3.2 Hinzugefügt
- Gipfel, eine Ebene, die wir selbst aus den Gipfeln von OpenStreetMap erstellen: der Name, die Höhe in Fuss und die Entfernung zum nächsthöheren Gipfel, die bestimmt, ab welcher Zoomstufe ein Gipfel erscheint (ein allein stehender Gipfel erscheint vor einem Buckel auf einem Grat).

### 3.3 Weggelassen
- Gebäude, Geschäfte und andere Points of Interest, öffentlicher Verkehr, Nebenwege, Feld- und Fusswege sowie Kantons- oder Regionalgrenzen.
- Jedes Attribut, das die Karte nicht zeichnet: Ein Element behält seine Art, seinen Namen, seine Strassennummer oder seine Einwohnerzahl, und sonst nichts.


## 4.0 An der Grenze zugeschnitten

Eine Region enthält nur die Daten innerhalb ihres eigenen Umrisses. Dieser Umriss ist die Grenze von OpenStreetMap, wie Overture Maps sie veröffentlicht: an Land die Grenze selbst; auf See die Hoheitsgewässer (12 NM, bzw. 6 in der Ägäis) oder die Mitte einer Meerenge, jede Insel eingeschlossen. Jede Kachel, die diese Linie kreuzt, wird entlang davon zugeschnitten (auf jeder Zoomstufe), und das Relief ausserhalb wird entfernt. Wo zwei Regionen aneinanderstossen, fügt die App ihre zwei Hälften einer Kachel wieder zusammen; jenseits der Regionen auf Ihrem Gerät übernimmt der Weltumriss. Grenzen werden genau so gezeichnet, wie OpenStreetMap sie zeichnet.


## 5.0 Jeden Monat neu erstellt

Die Karte wird jeden Monat aus den neusten Daten von OpenStreetMap neu erstellt, und jede Datei ist nach ihrem Inhalt benannt. Dadurch bleiben die Updates klein:
- Ein Gerät fragt die Datei einer Region unter diesem Namen an und fragt erst wieder, wenn sich der Name geändert hat: Eine unveränderte Region wird nicht zweimal heruntergeladen.
- Bei der Suche nach Updates nennt das Gerät seine Version, und die Antwort «unverändert» ist nur wenige Bytes gross.
- Eine heruntergeladene Region wird alle drei Monate automatisch aktualisiert, im WLAN und nicht im Flug (die Taste «Aktualisieren», wenn die App sie anbietet, holt den neueren Build früher).

OpenStreetMap wird jede Minute bearbeitet, eine monatliche Karte liegt also höchstens ein paar Wochen zurück. Fehlt etwas auf der Karte oder ist etwas falsch, korrigiert man es am besten [direkt in OpenStreetMap](https://www.openstreetmap.org/fixthemap): Der nächste Build übernimmt es.


## 6.0 Wie die App die Karte erhält

Die Dateien liegen auf tiles.aerocheck.app. Eine heruntergeladene Region wird vom Gerät gelesen und funktioniert offline; die Hälfte der Regionen ist kleiner als 30 MB (die Schweiz mit Liechtenstein etwa 90 MB, die grössten einige hundert MB). Anderswo lädt die App die Kacheln auf dem Bildschirm online (herausgezoomt, aus einer einzigen Übersicht aller Regionen), innerhalb eines monatlichen Kontingents pro Gerät: 1'500 Kacheln, oder 15'000 mit AéroCheck Pro. Eine heruntergeladene Region zählt nicht zu diesem Kontingent. Was diese Abfragen preisgeben und was wir davon behalten, steht in der [Datenschutzerklärung](/de/privacy), Abschnitt 3.10.


## 7.0 Luftbilder

Die Ebene «Luftbilder» zeigt offene Orthofotos öffentlicher Stellen (und sonst nichts). Jedes Gerät lädt sie direkt vom Dienst der jeweiligen Behörde, solange sie auf dem Bildschirm sind: AéroCheck hostet und speichert keine davon. Jede Quelle wird unter ihrer offenen Lizenz genutzt, an der Grenze des Gebiets zugeschnitten, das sie abdeckt, und auf der Karte mit ihrem eigenen Vermerk genannt, sobald ihre Bilder zu sehen sind (an einer Grenze, wo mehrere gleichzeitig erscheinen, jede von ihnen). Wo keine Behörde Bilder veröffentlicht, die wir nutzen dürfen, bleibt die Ebene leer.

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
| Slowenien | Geodetska uprava Republike Slovenije, Ortofoto DOF025 | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Italien, Südtirol | © Autonome Provinz Bozen – Südtirol | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Deutschland, 12 Länder | Die Vermessungsverwaltung jedes Landes: Bayern, Baden-Württemberg, Nordrhein-Westfalen, Berlin, Brandenburg, Sachsen, Thüringen, Rheinland-Pfalz, Hessen, Schleswig-Holstein, Mecklenburg-Vorpommern, Bremen | CC BY 4.0, [dl-de/by-2-0](https://www.govdata.de/dl-de/by-2-0) oder [dl-de/zero-2-0](https://www.govdata.de/dl-de/zero-2-0), wie es jedes Land veröffentlicht |
| USA, ohne Alaska | USDA, USGS The National Map: Orthoimagery | Gemeinfrei |

Wo die Lizenz eines Anbieters verlangt, Änderungen zu kennzeichnen: Die Bilder sind an der Grenze des Gebiets zugeschnitten, das sie abdecken (Daten geändert), und sonst ist nichts verändert. Die Liste kann sich ohne App-Update ändern: Eine Quelle kommt hinzu, sobald ihre Lizenz geprüft ist, und wird abgeschaltet, wenn ihr Anbieter uns darum bittet. Was das Laden der Bilder jedem Anbieter preisgibt, steht in der [Datenschutzerklärung](/de/privacy), Abschnitt 3.11.


## 8.0 Kontakt

Eine Frage zur Karte, oder ein Vermerk, den wir falsch übernommen haben? Schreiben Sie uns über den [Support](/de/support).
