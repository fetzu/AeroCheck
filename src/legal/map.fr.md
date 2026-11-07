**Dernière mise à jour**
Novembre 2026


Depuis la version 6.8.0, AéroCheck propose sa propre carte pour le vol : l'Atlas. Cette page explique d'où viennent ses données, ce que nous en gardons (et ce que nous laissons de côté), comment elle est découpée et mise à jour, et qui est crédité (conformément à la section 4.6 de l'Open Database Licence).


## 1.0 Ce qu'est la carte

L'Atlas est dessiné sur votre appareil par MapLibre Native, à partir de tuiles vectorielles que nous construisons chaque mois depuis OpenStreetMap, et du relief de Mapterhorn. Il montre ce que vous chercheriez par la fenêtre : villes et villages (selon leur taille), routes principales, voies ferrées, rivières et lacs, forêts, zones bâties, glaciers, frontières, téléphériques, et sommets avec leur altitude en pieds. Les couches aéronautiques (espaces aériens, aérodromes, procédures et votre route) sont dessinées par-dessus, un peu comme sur les cartes suisses.

Elle se compose de deux parties :
- Le contour du monde, livré avec l'app : terres, mer, grands lacs et grandes rivières, frontières, pays et capitales. C'est ce que la carte affiche quand elle n'a aucune région à afficher, c.-à-d. hors ligne en dehors des régions téléchargées, ou une fois le quota en ligne du mois épuisé.
- Les régions, construites à partir des données complètes : une par pays de la page [Pays](/fr/countries), les plus grands étant découpés plus finement (les États américains, les Länder allemands, les régions françaises…), environ 236 en tout. Une région se charge en ligne (dans un quota mensuel) ou se télécharge pour un usage hors ligne.


## 2.0 D'où viennent les données

- OpenStreetMap : © les contributeurs d'OpenStreetMap, sous l'[Open Database Licence](https://opendatacommons.org/licenses/odbl/1-0/) (ODbL 1.0), obtenu via la compilation quotidienne du [fond de carte Protomaps](https://docs.protomaps.com/basemaps/downloads). Les données de la carte sont une œuvre produite au sens de l'ODbL ; les données elles-mêmes se trouvent sur [openstreetmap.org](https://www.openstreetmap.org/copyright).
- Relief : [Mapterhorn](https://mapterhorn.com), des données de terrain ouvertes issues de modèles d'altitude nationaux et mondiaux. Ses sources et leurs licences sont listées sur [mapterhorn.com/attribution](https://mapterhorn.com/attribution).
- Contours des régions : [Overture Maps](https://overturemaps.org), tirés des limites d'OpenStreetMap et sous la même ODbL (© les contributeurs d'OpenStreetMap, Overture Maps Foundation).
- Noms des pays et grandes rivières du contour du monde : [Natural Earth](https://www.naturalearthdata.com) (domaine public).
- Police : [B612](https://github.com/polarsys/b612), dessinée pour les écrans de cockpit, sous la SIL Open Font License 1.1.
- Rendu : [MapLibre Native](https://maplibre.org), sous licence BSD à 2 clauses.


## 3.0 Ce que nous gardons, et ce que nous laissons de côté

Notre traitement part des tuiles de Protomaps et garde, élément par élément, ce dont un pilote se sert vraiment (ou, plus exactement, ce qu'un pilote cherche depuis le cockpit). Ce qu'il garde est copié tel quel : nous ne le simplifions pas une seconde fois et nous ne le déplaçons pas.

### 3.1 Gardé
- Les terres et la couverture du sol.
- Forêts/bois, zones bâties (habitat, commerce et industrie) et glaciers.
- L'eau : mers, lacs, rivières et canaux, avec leurs noms.
- Les frontières des pays.
- Les routes : autoroutes, voies rapides, routes principales et secondaires, avec leurs numéros (et si elles passent en tunnel).
- Le chemin de fer : grandes lignes, voies étroites et funiculaires, avec leurs tunnels (mais pas les voies de service), ainsi que les téléphériques et autres remontées par câble.
- Les lieux : villes, bourgs, villages, hameaux et habitations isolées, avec leurs noms et leur population (qui détermine à partir de quel niveau de zoom un lieu s'affiche).

### 3.2 Ajouté
- Les sommets, une couche que nous construisons nous-mêmes à partir des sommets d'OpenStreetMap : le nom, l'altitude en pieds et la distance jusqu'au sommet plus haut le plus proche, qui détermine à partir de quel niveau de zoom un sommet s'affiche (un sommet isolé apparaît avant une bosse sur une arête).

### 3.3 Laissé de côté
- Bâtiments, commerces et autres points d'intérêt, transports publics, petites routes, chemins/sentiers, et frontières cantonales ou régionales.
- Tout attribut que la carte ne dessine pas : un élément garde son type, son nom, son numéro de route ou sa population, et rien d'autre.


## 4.0 Découpée à la frontière

Une région ne contient que les données comprises dans son propre contour. Ce contour est la limite d'OpenStreetMap telle que la publie Overture Maps : sur terre, la frontière elle-même ; en mer, les eaux territoriales (12 NM, ou 6 en mer Égée) ou le milieu d'un détroit, chaque île comprise. Chaque tuile qui traverse cette ligne est découpée le long de celle-ci (à chaque niveau de zoom), et le relief au-delà est effacé. Là où deux régions se rencontrent, l'app recolle leurs deux moitiés d'une tuile ; au-delà des régions présentes sur votre appareil, le contour du monde prend le relais. Les frontières sont dessinées exactement comme OpenStreetMap les dessine.


## 5.0 Construite chaque mois

La carte est reconstruite chaque mois à partir des dernières données d'OpenStreetMap, et chaque fichier porte le nom de son contenu. Les mises à jour restent ainsi légères :
- un appareil demande le fichier d'une région sous ce nom, et ne le redemande qu'une fois le nom changé : une région qui n'a pas changé n'est jamais téléchargée deux fois ;
- en vérifiant les mises à jour, l'appareil indique quelle version il a, et une réponse « inchangé » ne pèse que quelques octets ;
- une région téléchargée se met à jour automatiquement tous les trois mois, en Wi-Fi et pas en vol (le bouton « Mettre à jour », quand l'app le propose, charge la nouvelle version plus tôt).

OpenStreetMap est modifié chaque minute : une carte mensuelle a donc au plus quelques semaines de retard sur lui. Si quelque chose manque ou est faux sur la carte, le mieux est de le corriger [dans OpenStreetMap même](https://www.openstreetmap.org/fixthemap) : la prochaine mise à jour de la carte le reprendra.


## 6.0 Comment l'app obtient la carte

Les fichiers sont stockés sur tiles.aerocheck.app. Une région téléchargée se lit depuis l'appareil et fonctionne hors ligne ; la moitié des régions font moins de 30 Mo (la Suisse avec le Liechtenstein environ 90 Mo, les plus grandes quelques centaines de Mo). Ailleurs, l'app charge en ligne les tuiles à l'écran (en vue éloignée, depuis un aperçu unique de toutes les régions), dans un quota mensuel par appareil : 1 500 tuiles, ou 15 000 avec AéroCheck Pro. Une région téléchargée ne compte pas dans ce quota. Ce que ces requêtes révèlent, et ce que nous en gardons, est détaillé dans [la politique de confidentialité](/fr/privacy), section 3.10.


## 7.0 Images aériennes

Le fond « Images aériennes » montre des orthophotos publiques ouvertes (et rien d'autre). Chaque appareil les charge directement depuis le service public qui les publie, pendant qu'elles sont à l'écran : AéroCheck ne les héberge pas et ne les stocke pas. Chaque source est utilisée sous sa licence ouverte, découpée à la limite de la zone qu'elle couvre, et créditée avec sa propre mention sur la carte dès que ses images sont visibles (à une frontière, où plusieurs s'affichent à la fois, chacune l'est). Là où aucun État ne publie d'images que nous avons le droit d'utiliser, le fond reste simplement vide.

| Zone | Mention du fournisseur | Licence |
|---|---|---|
| Suisse, Liechtenstein | ©swisstopo | [Géodonnées gratuites de swisstopo](https://www.swisstopo.admin.ch/en/terms-of-use-free-geodata-and-geoservices) |
| Autriche | Datenquelle: basemap.at | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| France | © IGN – BD ORTHO® | [Licence Ouverte 2.0](https://www.etalab.gouv.fr/licence-ouverte-open-licence/) |
| Pays-Bas | Beeldmateriaal.nl | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Luxembourg | © ACT Luxembourg | [CC0](https://creativecommons.org/publicdomain/zero/1.0/) |
| Belgique, Flandre | Orthofoto © Digitaal Vlaanderen | Modellicentie Gratis Hergebruik |
| Belgique, Bruxelles | Ortho © UrbIS – paradigm.brussels | [CC0](https://creativecommons.org/publicdomain/zero/1.0/) |
| Tchéquie | Ortofoto: ČÚZK | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Pologne | Ortofotomapa © GUGiK (geoportal.gov.pl) | [Conditions du GUGiK](https://www.geoportal.gov.pl/pl/o-geoportalu/regulamin/) |
| Slovénie | Geodetska uprava Republike Slovenije, Ortofoto DOF025 | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Italie, Tyrol du Sud | © Autonome Provinz Bozen – Südtirol | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Allemagne, 12 Länder | L'office du cadastre de chaque Land : Bavière, Bade-Wurtemberg, Rhénanie-du-Nord-Westphalie, Berlin, Brandebourg, Saxe, Thuringe, Rhénanie-Palatinat, Hesse, Schleswig-Holstein, Mecklembourg-Poméranie-Occidentale, Brême | CC BY 4.0, [dl-de/by-2-0](https://www.govdata.de/dl-de/by-2-0) ou [dl-de/zero-2-0](https://www.govdata.de/dl-de/zero-2-0), selon ce que publie chaque Land |
| États-Unis, sauf l'Alaska | USDA, USGS The National Map: Orthoimagery | Domaine public |

Là où la licence d'un fournisseur demande de signaler les modifications : les images sont découpées à la limite de la zone qu'elles couvrent, et rien d'autre n'est changé. La liste peut changer sans mise à jour de l'app : une source s'ajoute une fois sa licence vérifiée, et se désactive si son fournisseur nous le demande. Ce que le chargement des images révèle à chaque fournisseur est décrit dans [la politique de confidentialité](/fr/privacy), section 3.11.


## 8.0 Contact

Une question sur la carte, ou une mention que nous aurions mal reprise ? Écrivez-nous via l'[assistance](/fr/support).
