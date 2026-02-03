---
layout: page
title: Manuel d'utilisation
lang: fr
permalink: /fr/manual/
english_only: true
---

# Manuel d'utilisation

Bienvenue dans le manuel d'utilisation d'AeroCheck. Ce guide couvre toutes les fonctions de l'application pour vous aider a tirer le meilleur parti de vos vols.

**Table des matieres**
- [Premiers pas](#premiers-pas)
- [Checklists](#checklists)
- [Navigation en vol](#navigation-en-vol)
- [Briefings](#briefings)
- [Journal de vol](#journal-de-vol)
- [Planification de vol (Beta)](#planification-de-vol-beta)
- [Mode circuits](#mode-circuits)
- [Parametres et abonnement](#parametres-et-abonnement)

---

## Premiers pas

### Premier lancement

Au premier lancement, AeroCheck demande l'**autorisation de localisation**. Celle-ci est necessaire pour le suivi GPS, l'affichage de la vitesse sol et la carte de navigation. Accordez l'autorisation "Lorsque l'app est active" ou "Toujours" pour un fonctionnement complet, y compris le suivi en arriere-plan pendant les vols.

### Selection d'un aeronef

L'ecran d'accueil affiche un **carrousel d'aeronefs**. Balayez vers la gauche ou la droite pour parcourir les aeronefs disponibles. L'aeronef inclus (WT9 Dynamic / F-HVXA) est gratuit. Les aeronefs premium necessitent un abonnement AeroCheck Pro.

Chaque fiche aeronef affiche l'immatriculation, le type et le nombre d'items de checklist. Appuyez sur l'icone **Parametres** pour gerer les aeronefs, telecharger des checklists supplementaires ou souscrire un abonnement.

### Demarrer un vol

Appuyez sur **DEMARRER LE VOL** pour commencer un vol standard. L'application vous guidera a travers les 16 phases de vol, de la visite pre-vol jusqu'au hangar. Pour l'entrainement en tour de piste, appuyez sur **TOURS DE PISTE** -- cela active le mode circuits, qui simplifie la checklist pour les atterrissages repetes.

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
- **Vitesse estimee** (Beta) -- Vitesse sol GPS corrigee avec les donnees de vent MeteoSuisse (Suisse uniquement)
- **Donnees aerodromes** -- Telecharger la base de donnees OurAirports pour les frequences mondiales
- **Cartes hors ligne** -- Mettre en cache la carte OACI suisse et la Segelflugkarte pour une utilisation hors ligne
- **Synchronisation iCloud** -- Synchroniser les journaux de vol entre appareils

### A propos et avance

- **A propos** -- Version de l'app, site web, auteur et informations open source
- **Checklists disponibles** -- Voir toutes les checklists en cache et leurs versions
- **Donnees** -- Statistiques de vol et GPS
- **Options developpeur** -- Outils de debogage caches (appuyez 5 fois sur le numero de version pour les activer)
