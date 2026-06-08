---
layout: page
title: Manuel d'utilisation
lang: fr
permalink: /fr/manual/
---

# Manuel d'utilisation

Bienvenue dans le manuel d'utilisation d'AeroCheck. Ce guide couvre toutes les fonctions de l'application pour vous aider a tirer le meilleur parti de vos vols.

**Table des matieres**
- [Premiers pas](#premiers-pas)
- [Checklists](#checklists)
- [Navigation en vol](#navigation-en-vol)
- [Briefings](#briefings)
- [Journal de vol](#journal-de-vol)
- [Apple Watch et mode Compagnon](#apple-watch-et-mode-compagnon)
- [Planification de vol (Beta)](#planification-de-vol-beta)
- [Mode circuits](#mode-circuits)
- [Parametres et abonnement](#parametres-et-abonnement)

---

## Premiers pas

### Premier lancement

Au premier lancement, AeroCheck demande l'**autorisation de localisation**. Celle-ci est necessaire pour le suivi GPS, l'affichage de la vitesse sol et la carte de navigation. Accordez l'autorisation "Lorsque l'app est active" ou "Toujours" pour un fonctionnement complet, y compris le suivi en arriere-plan pendant les vols.

Si vous n'accordez que l'autorisation "Lorsque l'app est active", AeroCheck vous proposera de **passer a "Toujours"** au demarrage d'un vol. C'est l'acces "Toujours" qui permet a la trace de continuer a s'enregistrer lorsque l'ecran se verrouille ou que vous passez a une autre app en vol -- sans cela, une banniere en vol vous avertira que l'enregistrement en arriere-plan est limite (voir [Indicateurs GPS](#indicateurs-gps)).

### Selection d'un aeronef

L'ecran d'accueil affiche un **carrousel d'aeronefs**. Balayez vers la gauche ou la droite pour parcourir les aeronefs disponibles. L'aeronef inclus (WT9 Dynamic / F-HVXA) est gratuit. Les aeronefs premium necessitent un abonnement AeroCheck Pro.

Chaque fiche aeronef affiche l'immatriculation, le type et le nombre d'items de checklist. Appuyez sur l'icone **Parametres** pour gerer les aeronefs, telecharger des checklists supplementaires ou souscrire un abonnement.

### Demarrer un vol

Appuyez sur **DEMARRER LE VOL** pour commencer un vol standard. L'application vous guidera a travers les 16 phases de vol, de la visite pre-vol jusqu'au hangar. Pour l'entrainement en tour de piste, appuyez sur **TOURS DE PISTE** -- cela active le mode circuits, qui simplifie la checklist pour les atterrissages repetes.

Pour les aeronefs premium, la checklist est telechargee depuis l'API AeroCheck. Si elle n'a pas fini de se charger -- par exemple a cause d'une connexion manquante ou d'un abonnement inactif -- AeroCheck ne demarre **pas** le vol avec une checklist incomplete. Il affiche a la place une alerte **"Checklist non disponible"** vous demandant de verifier votre connexion et votre abonnement puis de reessayer, afin qu'une checklist erronee (ou vide) ne puisse jamais apparaitre en vol.

### Demarrer depuis le widget de l'ecran d'accueil

Ajoutez le **widget AeroCheck** a l'ecran d'accueil de votre iPhone ou iPad pour demarrer un vol en un seul appui. Le widget affiche un bouton de demarrage pour chaque aeronef que vous possedez -- le WT9 Dynamic gratuit ainsi que tout aeronef premium debloque (les aeronefs que vous ne possedez pas ne sont jamais affiches). Appuyer sur un bouton demarre directement le vol de cet aeronef, en chargeant sa checklist et en lancant le suivi GPS, exactement comme le bouton DEMARRER dans l'application. Le widget moyen inclut egalement un raccourci vers votre journal de vol.

---

## Checklists

### Les 16 phases de vol

AeroCheck couvre chaque phase de vol :

1. Visite pre-vol
2. Avant demarrage moteur
3. Demarrage moteur
4. Apres demarrage moteur
5. Roulage
6. Point fixe
7. Avant depart
8. Alignement
9. Montee
10. Croisiere
11. Descente
12. Approche
13. Atterrissage
14. Apres atterrissage
15. Arret moteur
16. Au hangar

Naviguez entre les phases avec le **selecteur de phase** en haut de l'ecran. Les phases completees sont marquees d'une coche.

### Mode pas-a-pas

Lorsqu'il est active (par defaut), l'item actuel de la checklist est mis en surbrillance. Appuyez dessus pour le marquer comme complete et passer au suivant. Cela permet de s'assurer qu'aucun item n'est oublie.

### Mode apprentissage

Le mode apprentissage masque les items a memoriser, vous permettant de tester vos connaissances. Les items configures comme "memorisables" n'apparaissent que lorsque le mode apprentissage est desactive. Activez-le dans **Parametres > Checklist > Mode apprentissage**.

### Phases multi-pages

Certaines phases s'etendent sur plusieurs pages. Un indicateur de page en bas de l'ecran montre votre position. Balayez ou appuyez pour naviguer entre les pages d'une phase.

### Langue de la checklist

Si une checklist est disponible en plusieurs langues, vous pouvez choisir votre langue preferee dans **Parametres > Checklist > Langue de la checklist**. Les options incluent Auto (suit la langue de l'appareil), anglais et francais.

---

## Navigation en vol

### Ouvrir la carte

Appuyez sur le bouton **NAV** pendant un vol pour ouvrir la carte de navigation en plein ecran. La carte affiche votre position actuelle avec un indicateur de cap.

### Couches cartographiques

AeroCheck propose plusieurs couches cartographiques :

- **Standard** -- Vue Apple Maps par defaut
- **Satellite** -- Imagerie satellite
- **Carte OACI 1:500 000** -- Carte aeronautique suisse de swisstopo
- **Landeskarten 1:100 000 / 1:50 000** -- Cartes nationales suisses
- **Segelflugkarte 1:300 000** -- Carte de vol a voile suisse

La carte OACI et la Segelflugkarte alternent automatiquement selon le niveau de zoom. Les couches cartographiques suisses sont disponibles en Suisse et a proximite.

### Panneau FREQ

Appuyez sur le bouton **FREQ** pour ouvrir le panneau de frequences radio. Celui-ci affiche :

- **Frequences du plan de vol** (si un plan de vol est actif)
- **Frequences des aerodromes proches** -- Aerodromes detectes automatiquement dans un rayon de 15 NM, affichant ATIS, TWR, GND, APP et autres frequences publiees depuis la base de donnees OurAirports
- **Frequences suisses courantes** -- Frequences d'urgence, d'information et FIS
- **Frequences CTR proches** -- Frequences des zones de controle selon votre position

### Indicateurs GPS

La vue navigation affiche en temps reel :
- **Vitesse sol** en noeuds
- **Altitude** en pieds MSL
- **Qualite du signal GPS**

Si la position GPS cesse de se mettre a jour en vol (aucun point pendant plus de 90 secondes), les indicateurs de vitesse et d'altitude affichent un **drapeau d'erreur** au lieu de valeurs perimees, et l'etat GPS indique **Perdu** -- ainsi une perte de signal silencieuse n'est jamais prise pour une lecture valide. Si l'acces a la localisation est limite a "Lorsque l'app est active", une banniere ambre **"GPS limite"** vous rappelle d'autoriser "Toujours" pour que la trace continue de s'enregistrer en arriere-plan.

### Vitesse, decrochage et vitesse estimee

Pendant les phases de vol, AeroCheck affiche un grand indicateur de vitesse avec un guidage colore vers la vitesse cible de la phase en cours, et une alerte de decrochage (clignotement rouge/blanc) lorsque vous passez sous la vitesse de decrochage de l'aeronef.

Par defaut, cet indicateur affiche la **vitesse sol GPS** (`GND SPD`, en noeuds). La vitesse sol n'est pas la vitesse air affichee par votre instrument de bord -- un vent de face ou arriere la decale -- traitez donc l'alerte de decrochage a l'ecran comme une aide a la vigilance, jamais comme un remplacement de l'anemometre de votre aeronef.

**Vitesse estimee (experimental, Suisse uniquement).** Lorsque vous activez *Afficher la vitesse estimee* dans les Parametres, l'indicateur estime la vitesse air indiquee en corrigeant la vitesse sol GPS avec le vent moyen de la station MeteoSuisse la plus proche. Pour rester honnete, une valeur estimee est clairement signalee : le libelle indique **`EST. IAS`** et le nombre est prefixe d'un tilde (par exemple `~62`), afin qu'une valeur derivee ne soit jamais confondue avec une valeur mesuree. La correction utilise le vent moyen (et non les rafales), et les releves de vent trop anciens sont ecartes plutot qu'utilises, afin qu'une observation perimee ne pilote pas discretement l'estimation.

**Alerte de decrochage sonore (optionnelle).** Avec la vitesse estimee activee, vous pouvez aussi activer une **Alerte de decrochage sonore** dans les Parametres. Une fois armee, elle emet un avertissement audible si votre vitesse passe sous la vitesse de decrochage -- utile lorsque votre regard est a l'exterieur du cockpit. Elle est **desactivee par defaut** et, comme l'indicateur visuel, reste une aide uniquement : fiez-vous toujours a l'anemometre certifie de l'aeronef.

### Cartes hors ligne

Les cartes OACI suisses et la Segelflugkarte peuvent etre mises en cache pour une utilisation hors ligne. Allez dans **Parametres > Cartes hors ligne** pour telecharger les cartes (~100-250 Mo). Lorsque le mode hors ligne est active, les cartes sont servies depuis votre cache local.

---

## Briefings

### Briefing de depart

Avant le depart, un briefing dynamique est affiche comprenant :
- **Aerodrome** et **altitude** (detectes automatiquement par GPS)
- **Piste** (detectee ou selectionnee manuellement)
- **Procedure de depart** -- Direction du premier virage et altitude de mise en palier (a briefer verbalement par le pilote)
- **Vent** (lorsque disponible via MeteoSuisse)
- **Vitesses** -- Rotation (Vr), meilleur angle (Vx), meilleur taux (Vy), meilleure finesse (Vbg) et autres vitesses du manuel de vol
- **Procedures d'urgence** -- Panne avant rotation, panne moteur apres decollage, altitudes minimales de securite

### Briefing d'approche

Avant l'approche, un briefing similaire couvre :
- **Aerodrome** et **altitude**
- **Piste**
- **Vent**
- **Vitesses d'approche** -- Approche initiale, approche finale et vitesses de decrochage
- **Procedure de remise de gaz**

Lorsque les donnees de vent ne sont pas disponibles, le briefing affiche un rappel de verifier la manche a air pour les conditions de calme, vent de travers, vent de face ou vent arriere.

---

## Journal de vol

### Chronometrage automatique

AeroCheck enregistre automatiquement les moments cles de votre vol :
- Heures de **block off / block on**
- Heures de **demarrage / arret moteur**
- Heures de **decollage / atterrissage** (appuyez sur les boutons d'action pour enregistrer)

### Evenements de vol

L'application detecte et enregistre automatiquement :
- **Remises de gaz** -- Detectees lors d'une montee au-dessus d'un seuil apres une approche
- **Touch-and-go** -- Contact bref avec le sol suivi d'un decollage
- **Atterrissages complets** -- Atterrissage final en fin de vol

### Heures moteur

Si active dans **Parametres > Journal de vol**, l'application demande les releves du tachymetre ou de l'horametre au demarrage et a l'arret du moteur. Les heures effectuees sont calculees automatiquement.

### Consulter l'historique des vols

Appuyez sur l'icone du **journal de vol** sur l'ecran d'accueil pour voir les vols passes. Chaque entree affiche la date, la duree, l'aeronef et la distance.

Appuyez sur un vol pour voir sa **vue detaillee**, qui comprend :
- Une carte interactive avec votre trace de vol
- Un profil d'altitude
- Les informations de route (aerodromes de depart et d'arrivee)
- La chronologie de tous les evenements
- Les heures moteur (si enregistrees)
- Les notes de vol

### Exporter les vols

Depuis la vue detaillee, appuyez sur **Exporter** pour sauvegarder votre vol en :
- **GPX** -- Format standard d'echange GPS, compatible avec la plupart des outils cartographiques
- **JSON** -- Donnees de vol detaillees incluant tous les evenements et metadonnees

Vous pouvez aussi generer une **carte de partage** -- un resume visuel de votre vol a partager sur les reseaux sociaux ou par messagerie.

---

## Apple Watch et mode Compagnon

AeroCheck peut afficher votre vol en direct sur un second ecran.

### Apple Watch

L'**application Apple Watch** affiche la phase de vol en cours, la vitesse sol et l'altitude a votre poignet, mises a jour en temps reel depuis votre iPhone. Si la montre cesse de recevoir des donnees fraiches -- par exemple lorsqu'elle s'eloigne du telephone -- une banniere **"NO DATA"** apparait pour vous signaler que les valeurs affichees peuvent etre figees plutot qu'actuelles.

### Mode Compagnon

Sur les appareils compatibles, le **mode Compagnon** transforme un second iPhone ou iPad en second ecran synchronise via une liaison Wi-Fi directe : un appareil sert de maitre et l'autre reproduit son affichage de vol. Si la connexion tombe ou que les donnees deviennent perimees, l'ecran compagnon affiche une banniere **"Donnees obsoletes -- valeurs possiblement figees"** ou **"Connexion perdue"**, afin qu'un ecran reproduit ne soit jamais pris pour un ecran en direct.

Dans les deux cas, la regle est la meme : une banniere d'obsolescence ou de deconnexion signifie *cessez de vous fier aux valeurs de cet ecran* jusqu'a sa reconnexion.

---

## Planification de vol (Beta)

> La planification de vol est une fonctionnalite beta. Activez-la dans **Parametres > Planification de vol**.

### Creer un plan de vol

Ouvrez la vue de planification de vol pour creer une route. Ajoutez des waypoints en :
- Recherchant des aerodromes ou waypoints par nom ou code OACI
- Appuyant sur la carte pour placer un waypoint
- Saisissant les coordonnees manuellement

### Table de route

La table de route affiche pour chaque waypoint :
- Nom du waypoint et frequence
- Altitude prevue
- Vitesse sol
- Temps de vol estime (EET)
- Heure estimee d'arrivee (ETO)
- Route magnetique (MC)

### Profils de terrain

Pour les routes en Suisse, AeroCheck affiche un profil de terrain utilisant les donnees d'elevation swisstopo. Cette visualisation montre l'elevation du sol le long de votre route par rapport a votre altitude prevue.

### Verification des espaces aeriens

AeroCheck confronte votre route prevue aux donnees d'espaces aeriens OpenAIP et signale les espaces controles ou reglementes qu'elle pourrait penetrer. Les conflits apparaissent sous forme de banniere au-dessus de la table de route ; appuyez dessus pour voir chaque espace, ses limites verticales et sa frequence.

La verification suit la geometrie exacte de la route entre les waypoints (et pas seulement les extremites), de sorte qu'un segment qui effleure le coin d'une zone est tout de meme detecte. Lorsque le resultat depend de l'altitude, AeroCheck est volontairement prudent : il signale la severite la plus defavorable, et lorsque le plafond ou le plancher d'une zone est publie par rapport au sol ou en niveau de vol (AGL/FL), ou lorsqu'un segment n'a pas d'altitude prevue saisie, le conflit est marque **"Altitude incertaine -- verifiez la separation verticale."** Ce qualificatif signifie que le conflit horizontal est reel mais que l'app ne peut pas confirmer si votre altitude vous en degage -- vous devez verifier vous-meme la separation verticale par rapport aux cartes en vigueur et au QNH.

Comme toujours, les donnees d'espace aerien sont indicatives et peuvent etre incompletes ou perimees ; elles ne remplacent jamais les cartes aeronautiques officielles ni les NOTAM.

### HUD en vol

Pendant un vol avec un plan actif, un affichage tete haute montre :
- Nom du prochain waypoint, cap et distance
- Altitude prevue
- Temps de vol et ETO
- Indicateur de progression
- Un chronometre pour le chronometrage des segments

### Exportation

Les plans de vol peuvent etre exportes en fichiers GPX compatibles avec les systemes avioniques Dynon, Garmin et autres.

---

## Mode circuits

Le mode circuits est concu pour l'**entrainement en tour de piste** (touch-and-go). Lorsqu'il est active :

- La checklist saute les phases **Croisiere** et **Descente**
- Apres l'atterrissage, la checklist revient directement a la phase **Avant depart**
- Les **atterrissages complets** sont suivis automatiquement

Activez le mode circuits au demarrage d'un vol en appuyant sur **TOURS DE PISTE** sur l'ecran d'accueil, ou basculez-le dans **Parametres > Checklist > Mode circuits**.

---

## Parametres et abonnement

### Aeronef et abonnement

- **AeroCheck Pro** -- Abonnez-vous pour debloquer les checklists d'aeronefs premium
- **Aeronef** -- Selectionnez votre aeronef actif parmi les options incluses et premium
- **Visibilite des aeronefs** -- Afficher ou masquer les aeronefs par aeroclub

### Vol

- **Checklist** -- Surlignage pas-a-pas, mode apprentissage, mode circuits et langue
- **Journal de vol** -- Activer l'enregistrement des heures moteur (horametre)
- **GPS** -- Intervalle d'enregistrement (1-30 secondes) et etat de l'autorisation
- **Affichage** -- Garder l'ecran allume pendant le vol, utiliser l'heure UTC

### Navigation et donnees

- **Navigation** -- Forcer la couche carte OACI
- **Planification de vol** (Beta) -- Activer la planification de route et les profils de terrain
- **Vitesse estimee** (Experimental) -- Vitesse sol GPS corrigee avec le vent moyen MeteoSuisse (Suisse uniquement). Les valeurs estimees sont affichees en `EST. IAS` avec un prefixe `~` pour ne jamais etre confondues avec une vitesse air mesuree. Son activation revele aussi une bascule **Alerte de decrochage sonore** (desactivee par defaut) qui emet un avertissement audible sous la vitesse de decrochage
- **Donnees aerodromes** -- Telecharger la base de donnees OurAirports pour les frequences mondiales
- **Cartes hors ligne** -- Mettre en cache la carte OACI suisse et la Segelflugkarte pour une utilisation hors ligne
- **Synchronisation iCloud** -- Synchroniser les journaux de vol entre appareils

### A propos et avance

- **A propos** -- Version de l'app, site web, auteur et informations open source
- **Checklists disponibles** -- Voir toutes les checklists en cache et leurs versions
- **Donnees** -- Statistiques de vol et GPS
- **Options developpeur** -- Outils de debogage caches (appuyez 5 fois sur le numero de version pour les activer)
