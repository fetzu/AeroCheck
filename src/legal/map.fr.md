**Dernière mise à jour**
Octobre 2026


Depuis la version 6.8.0, AéroCheck dessine sa propre carte pour le vol, la carte du pilote. Cette page dit d'où viennent ses données, ce que nous en gardons et ce que nous laissons de côté, comment elle est découpée et mise à jour, et qui est crédité. La section 4.6 de l'Open Database Licence demande que toute personne utilisant une carte faite à partir d'OpenStreetMap puisse savoir comment elle a été faite : c'est cette page.


## 1.0 Ce qu'est la carte

La carte du pilote est dessinée sur votre appareil par MapLibre Native, à partir de tuiles vectorielles que nous construisons chaque mois depuis OpenStreetMap, et du relief. Elle montre ce que vous cherchez par la fenêtre : villes et villages selon leur taille, routes principales, voies ferrées, rivières et lacs, forêts, zones bâties, glaciers, frontières, téléphériques, et sommets avec leur altitude en pieds. Les couches aéronautiques (espaces aériens, aérodromes, procédures, votre route) sont dessinées par-dessus, comme sur les cartes suisses.

Elle a deux parties :
- **Le contour du monde**, dans l'app elle-même : terres, mer, grands lacs et grandes rivières, frontières, pays et capitales. C'est ce que la carte montre là où aucune région n'est sur l'appareil.
- **Les régions**, une par pays, construites à partir des données complètes : la Suisse avec le Liechtenstein d'abord, d'autres suivront. Une région se lit en ligne dans un quota mensuel, ou se télécharge et s'utilise hors ligne.


## 2.0 D'où viennent les données

- **OpenStreetMap** : © les contributeurs d'OpenStreetMap, sous l'[Open Database Licence](https://opendatacommons.org/licenses/odbl/1-0/) (ODbL 1.0), lu via la compilation quotidienne du [fond de carte Protomaps](https://docs.protomaps.com/basemaps/downloads). Les données de la carte sont une œuvre produite au sens de l'ODbL : les données elles-mêmes se trouvent sur [openstreetmap.org](https://www.openstreetmap.org/copyright).
- **Relief** : [Mapterhorn](https://mapterhorn.com), des données de terrain ouvertes issues de modèles d'altitude nationaux et mondiaux. Ses sources et leurs licences sont listées sur [mapterhorn.com/attribution](https://mapterhorn.com/attribution).
- **Noms des pays et grandes rivières** du contour du monde : [Natural Earth](https://www.naturalearthdata.com) (domaine public).
- **Police** : [B612](https://github.com/polarsys/b612), dessinée pour les écrans de cockpit, sous la SIL Open Font License 1.1.
- **Dessin** : [MapLibre Native](https://maplibre.org), sous licence BSD à 2 clauses.


## 3.0 Ce que nous gardons, et ce que nous laissons de côté

La construction lit les tuiles de Protomaps et garde, élément par élément, ce dont un pilote se sert. La géométrie de ce qu'elle garde est copiée telle quelle : rien n'est simplifié une seconde fois ni déplacé.

### 3.1 Gardé
- Les terres et la couverture du sol.
- Forêts et bois, zones bâties (habitat, commerce et industrie) et glaciers.
- L'eau : mers, lacs, rivières et canaux, avec leurs noms.
- Les frontières des pays.
- Les routes : autoroutes, voies rapides, routes principales et secondaires, avec leurs numéros, et si elles passent en tunnel.
- Le chemin de fer : grandes lignes, voies étroites et funiculaires, avec leurs tunnels (pas les voies de service). Téléphériques et autres remontées par câble.
- Les lieux : villes, bourgs, villages, hameaux et habitations isolées, avec leurs noms et leur population, qui décide à partir de quel zoom un lieu s'affiche.

### 3.2 Ajouté
- **Les sommets**, une couche à nous tirée des sommets d'OpenStreetMap : le nom, l'altitude en pieds et la distance jusqu'au sommet plus haut le plus proche, qui décide à partir de quel zoom un sommet s'affiche (un sommet isolé apparaît avant une bosse sur une arête).

### 3.3 Laissé de côté
- Bâtiments, commerces et autres points d'intérêt, transports publics, petites routes, chemins et sentiers, et frontières cantonales ou régionales.
- Tout champ que la carte ne dessine pas : un élément garde son type, son nom, son numéro de route ou sa population, rien d'autre.


## 4.0 Découpée à la frontière

Une région contient les données de son propre pays et rien d'autre, si bien que deux régions ne dessinent jamais deux fois le même endroit. La frontière est celle d'OpenStreetMap, prise dans les tuiles les plus détaillées de la région et refermée en une ligne autour du pays, enclaves exclues. Chaque tuile qui la traverse est découpée le long d'elle, à chaque zoom, et le relief au-delà est effacé. Passé la frontière, la région voisine prend le relais si elle est sur l'appareil, et le contour du monde partout ailleurs.


## 5.0 Construite chaque mois

La carte est reconstruite chaque mois à partir des dernières données d'OpenStreetMap, et les mêmes données donnent toujours le même fichier, octet pour octet. Chaque fichier porte le nom de son contenu. C'est ce qui garde les mises à jour légères :
- Un appareil demande le fichier d'une région sous ce nom, et ne le redemande que si le nom a changé : une région qui n'a pas changé n'est jamais téléchargée deux fois.
- Quand il vérifie, l'appareil dit quelle version il a, et une réponse « inchangé » ne pèse que quelques octets.
- Une région téléchargée se met à jour d'elle-même tous les trois mois, en Wi-Fi, jamais en vol. Quand l'app propose **Mettre à jour**, elle charge plus tôt la nouvelle version.

OpenStreetMap est modifié chaque minute : une carte mensuelle a donc au plus quelques semaines de retard. Ce qui manque ou est faux sur la carte se corrige au mieux [dans OpenStreetMap même](https://www.openstreetmap.org/fixthemap) : la construction suivante le reprend.


## 6.0 Comment l'app obtient la carte

Les fichiers sont conservés sur tiles.aerocheck.app, le stockage de Cloudflare à notre nom. Une région téléchargée se lit sur l'appareil et fonctionne hors ligne. Ailleurs, l'app lit en ligne les tuiles à l'écran, dans un quota mensuel par appareil : 1 500 tuiles, ou 15 000 avec AéroCheck Pro. Une région téléchargée n'y compte jamais. Ce que ces requêtes montrent, et ce que nous en gardons, figure dans [la politique de confidentialité](/fr/privacy), section 3.10.


## 7.0 Images aériennes

Le fond **Images aériennes** montre des orthophotos publiques ouvertes, et seulement elles. Chaque appareil les charge depuis le service public qui les publie, pendant qu'elles sont à l'écran : AéroCheck n'en héberge aucune, n'en intègre aucune et n'en télécharge aucune à l'avance. Chaque source est utilisée sous sa licence ouverte, découpée à la limite de la zone qu'elle couvre, et créditée dans ses propres mots sur la carte tant que ses images s'affichent ; à une frontière, chacune de celles à l'écran l'est. Là où aucun État ne publie d'images que nous pouvons utiliser, le fond n'en montre pas.

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
| Italie, Tyrol du Sud | © Autonome Provinz Bozen – Südtirol | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Allemagne, 12 Länder | L'office du cadastre de chaque Land : Bavière, Bade-Wurtemberg, Rhénanie-du-Nord-Westphalie, Berlin, Brandebourg, Saxe, Thuringe, Rhénanie-Palatinat, Hesse, Schleswig-Holstein, Mecklembourg-Poméranie-Occidentale, Brême | CC BY 4.0, [dl-de/by-2-0](https://www.govdata.de/dl-de/by-2-0) ou [dl-de/zero-2-0](https://www.govdata.de/dl-de/zero-2-0), selon ce que publie chaque Land |
| États-Unis, sauf l'Alaska | USDA, USGS The National Map: Orthoimagery | Domaine public |

Là où la licence d'un fournisseur demande de signaler les modifications : les images sont découpées à la limite de la zone qu'elles couvrent, et rien d'autre n'est changé. La liste peut changer sans mise à jour de l'app : une source s'ajoute une fois sa licence vérifiée, et se coupe si son fournisseur le demande. Ce que le chargement des images montre à chaque fournisseur figure dans [la politique de confidentialité](/fr/privacy), section 3.11.


## 8.0 Contact

Une question sur la carte, ou une mention que nous aurions mal reprise : [assistance](/fr/support).
