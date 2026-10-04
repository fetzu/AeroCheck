**Dernière mise à jour**
Septembre 2026


AéroCheck est une app open source de listes de vérification et de conscience de la situation pour pilotes, développée et publiée par Julien Bono, en Suisse. Cette page dit ce que l'app garde sur votre appareil, ce qu'elle envoie, à qui et avec quelle précision, et ce que nos propres serveurs conservent.

En bref : pas de compte, pas de publicité, pas de statistiques d'utilisation, aucun pistage. Vos vols sont conservés sur votre appareil et, si vous synchronisez, dans votre propre iCloud. Certaines requêtes portent une position, une route ou quelques points d'une trace, arrondis pour la plupart, pour que l'app puisse afficher la météo, le relief et les espaces aériens (la section 3.0 les énumère toutes). Notre serveur d'API garde la trace d'un achat, jamais une position. Si vous nous envoyez la checklist d'un avion depuis ce site, nous conservons ce que vous envoyez aussi longtemps que la demande en a besoin (section 4.3).


## 1.0 Ce qui reste sur votre appareil

### 1.1 Vols et carnet de vol
La trace GPS, les heures, les atterrissages, les plans de vol, les routes et votre carnet de vol sont enregistrés dans le stockage propre à l'app sur l'appareil, et dans votre iCloud si vous le permettez (section 2.0). En dehors des points arrondis énumérés à la section 3.0, ils ne quittent l'appareil que lorsque vous les exportez ou les partagez (section 5.0).

### 1.2 Position et mouvement
L'app utilise le GPS pour la carte mobile, la trace enregistrée, les instruments et la détection automatique des décollages et des atterrissages, et l'altimètre barométrique (données de mouvement) pour l'altitude. Les mesures du baromètre ne quittent jamais l'appareil. Les requêtes qui portent une position sont toutes énumérées à la section 3.0.

### 1.3 Vos propres appareils
L'app Apple Watch et le mode compagnon (iPad et iPhone ensemble) échangent les données du vol directement entre vos propres appareils, sans passer par un serveur. Le widget de l'écran d'accueil lit la liste de vos avions sur l'appareil.

### 1.4 Ni statistiques ni pistage
AéroCheck ne contient aucun SDK de statistiques ou de publicité, aucun outil de rapport de plantage et aucun pistage d'aucune sorte, et n'utilise pas l'identifiant publicitaire. Si vous l'autorisez dans iOS (Réglages, Confidentialité et sécurité, Analyse et améliorations, partage avec les développeurs d'apps), Apple transmet des rapports de plantage anonymisés au développeur ; c'est un réglage d'Apple, pas de l'app.


## 2.0 iCloud

Avec « Synchroniser avec iCloud » activé (dans les réglages de l'app, activé par défaut), vos vols (avec leurs traces), plans de vol, voyages, pages de vol et réglages (y compris les noms de pilote et d'instructeur que vous saisissez) sont conservés dans le dossier d'AéroCheck de votre iCloud Drive, ce qui explique d'ailleurs que vous les voyiez dans l'app Fichiers, et les réglages et les vols sont synchronisés entre vos appareils par la base de données privée de l'app dans votre compte iCloud. Dans les deux cas, il s'agit de votre propre compte iCloud : Apple conserve les données selon sa [politique de confidentialité](https://www.apple.com/chfr/legal/privacy/), et le développeur n'y a pas accès.

Avec l'option désactivée, tout reste sur l'appareil : l'app ne lit ni n'écrit son dossier iCloud Drive, et ne synchronise rien. La désactiver copie d'abord sur l'appareil ce qui se trouve dans iCloud Drive et laisse les fichiers d'iCloud Drive où ils sont (supprimez-les dans l'app Fichiers si vous voulez qu'ils disparaissent) ; la réactiver recopie dans iCloud Drive ce que vous avez fait entre-temps. L'option vaut pour l'appareil sur lequel elle est réglée.


## 3.0 Ce qui quitte votre appareil, et vers qui

« Arrondie » signifie ci-dessous que la position est ramenée sur une grille avant que la requête ne quitte l'appareil. Pour donner l'échelle, en Suisse, un quart de degré fait environ 28 km sur 19 km, trois décimales environ 100 m et deux décimales environ 1 km.

### 3.1 Relais météo d'AéroCheck (wx.aerocheck.app)
Notre propre petit serveur, qui va chercher la météo aéronautique pour le compte de l'app.
- METAR et SIGMET autour de vous : votre position arrondie au quart de degré, pendant un vol ou lorsque la carte de navigation est ouverte, au plus toutes les cinq minutes.
- TAF : le code OACI d'un aérodrome (votre destination prévue pendant le briefing d'approche, sinon la station la plus proche).
- Vents en altitude : chaque point de la route que vous planifiez, arrondi au quart de degré, et votre position arrondie de la même façon lorsque vous ouvrez Déroutement en vol.

Le relais arrondit une nouvelle fois de son côté, puis demande à [aviationweather.gov](https://aviationweather.gov) (le service météorologique national des États-Unis) les stations METAR d'un carré autour de ce point de grille, un TAF par son code OACI et la liste des SIGMET sans aucune position ; et à [Open-Meteo](https://open-meteo.com) les vents en altitude en ce point de grille. Il ne transmet jamais votre adresse IP. Il garde ses réponses dans le cache de Cloudflare de cinq minutes à une heure, par position arrondie, et n'a pas de base de données.

### 3.2 swisstopo (Office fédéral de topographie, geo.admin.ch)
- Tuiles des cartes suisses (carte OACI, carte de vol à voile, cartes nationales et images aériennes), sur la carte de navigation et sur les cartes de partage avec un fond suisse : les tuiles demandées montrent la zone à l'écran, et la carte de navigation suit l'avion. Sur la carte OACI, une tuile fait environ 7 km de côté ; sur les cartes les plus détaillées, environ 100 m.
- Relief en Suisse : les points d'une route que vous planifiez (profil de la route, « Définir les altitudes », l'altitude d'un point que vous modifiez), arrondis au mètre ; et, lorsque vous ajoutez le relief à la carte de partage d'un vol, jusqu'à 200 points de la trace enregistrée, départ et arrivée compris, arrondis au mètre.
- Vent au sol de MétéoSuisse, pour les briefings de départ et d'approche : pendant un vol, l'app télécharge toutes les dix minutes le jeu complet des mesures de vent actuelles sur data.geo.admin.ch, sans aucune position. Elle ne le fait qu'en Suisse ou à proximité (la requête en dit donc autant).

### 3.3 Open-Meteo (open-meteo.com)
Relief hors de Suisse, envoyé directement par l'app : des points le long d'une route que vous planifiez (« Définir les altitudes »), ou jusqu'à 80 points d'une trace enregistrée lorsque vous ajoutez le relief à sa carte de partage, départ et arrivée compris, arrondis à trois décimales. Les vents en altitude passent par notre relais pour aller chez Open-Meteo (section 3.1).

### 3.4 OpenAIP (openaip.net)
- Les espaces aériens et les autres données aéronautiques se téléchargent par pays : la requête nomme le pays, rien d'autre. Pour une route planifiée, l'app demande à OpenAIP la taille des données des pays traversés que vous n'avez pas encore téléchargés (codes de pays uniquement).
- « Données aéronautiques en ligne » (réglages, désactivé par défaut) : tant que l'option est activée, qu'aucun espace aérien n'est téléchargé et que la carte de navigation est ouverte, votre position arrondie à deux décimales, au plus une fois par minute, et seulement lorsque la dernière réponse a plus de cinq minutes ou que l'avion s'est déplacé de plus de 10 NM.
- Tuiles de la carte OpenAIP (désactivées par défaut) : les tuiles montrent la zone à l'écran.

### 3.5 Apple
- Les fonds de carte Apple, les vignettes des routes et les cartes des cartes de partage (sauf si vous choisissez un fond suisse) viennent d'Apple Plans, qui reçoit la zone affichée.
- Lors de la première configuration, votre position actuelle, une fois, pour trouver votre pays et proposer quoi télécharger.
- Les achats passent par l'App Store ; l'app ne voit jamais vos moyens de paiement ni votre identifiant Apple.

### 3.6 OurAirports
La base des aérodromes est téléchargée en entier, sans aucune position.

### 3.7 Serveur d'API d'AéroCheck (api.aerocheck.app)
Jamais de position. Lorsque vous ouvrez un avion, l'app envoie son identifiant, son immatriculation et la langue que vous utilisez, pour obtenir la bonne liste de vérification. Avec AéroCheck Pro, l'app envoie en outre la preuve d'achat que lui remet Apple (une transaction signée par Apple) et l'identifiant de transaction d'origine de cet achat, puis un jeton de session avec chaque requête. Ce que le serveur conserve figure à la section 4.0.


## 4.0 Ce que nos serveurs conservent

Nos trois serveurs (l'API, le relais météo et celui qui reçoit les demandes d'avions) tournent chez Cloudflare, qui traite l'adresse IP de chaque requête pour l'acheminer, selon la [politique de confidentialité de Cloudflare](https://www.cloudflare.com/fr-fr/privacypolicy/).

### 4.1 Serveur d'API
- Par achat, un enregistrement classé sous l'identifiant de transaction d'origine de l'achat : son statut, sa date d'échéance, le produit, l'environnement (App Store ou test), s'il se renouvelle et quand il a été vérifié pour la dernière fois. Il est conservé jusqu'à 30 jours après l'échéance d'un abonnement, 90 jours après la dernière vérification d'un achat à vie, et 7 jours une fois qu'un achat a expiré ou a été remboursé.
- Le lien entre un achat et son enregistrement, ainsi qu'une marque si Apple signale un remboursement, pendant 400 jours.
- Les jetons de session avec lesquels l'app s'authentifie, sous forme d'empreintes SHA-256 uniquement (jamais les jetons eux-mêmes), pendant 180 jours, avec une liste de ces empreintes par achat pour qu'au plus cinq soient valables en même temps.
- Votre adresse IP, dans un compteur de requêtes qui limite la fréquence des appels d'une même adresse, pendant une minute.

Apple informe le serveur des échéances, des remboursements et des révocations ; ces avis ne font que mettre à jour l'enregistrement de l'achat (et poser la marque de remboursement). Le serveur ne connaît jamais votre nom, votre adresse e-mail ni votre identifiant Apple, et ne reçoit jamais de position. Ses journaux notent le type d'événement et des identifiants réduits à leurs quatre derniers caractères. Comme l'enregistrement de l'achat est classé sous un identifiant, l'étiquette de confidentialité de l'App Store déclare l'historique d'achat et un identifiant d'utilisateur comme liés à vous, utilisés pour le fonctionnement de l'app et jamais pour du pistage.

### 4.2 Relais météo
Ni base de données ni journaux propres : seulement le cache décrit à la section 3.1.

### 4.3 Demandes d'avions (intake.aerocheck.app)
Seulement si vous nous envoyez la checklist d'un avion depuis [aerocheck.app/fr/send](/fr/send) (l'app elle-même n'envoie rien de tel). Le serveur des demandes conserve :
- ce que vous avez saisi : les immatriculations, le type d'avion, le club, si vous l'envoyez pour le club, les langues de la checklist, vos remarques, votre adresse e-mail, votre nom si vous le donnez, et l'adresse e-mail du contact du club si vous la donnez (tout de suite ou plus tard) ;
- les fichiers que vous envoyez (le document du club, en PDF ou en images), dans Cloudflare R2, et la demande dans une base de données Cloudflare D1, avec son historique : chaque statut, la date de son changement et les messages que nous vous écrivons ;
- la réponse du club lorsqu'on la lui demande : le nom et la fonction de la personne qui répond pour lui, sa décision et son message ;
- votre avis et votre message, si vous relisez le brouillon ;
- les liens vers la page de votre demande et vers celle du club, sous forme d'empreintes SHA-256 uniquement (les liens eux-mêmes sont dans les e-mails, jamais chez nous) ;
- votre adresse IP, dans un compteur de requêtes qui limite la fréquence des envois d'une même adresse, pendant une minute au plus.

Le formulaire est protégé par Cloudflare Turnstile, qui examine votre navigateur pour distinguer une personne d'un robot, selon [l'avenant de confidentialité de Turnstile](https://www.cloudflare.com/fr-fr/turnstile-privacy-policy/) ; le serveur ne vérifie que la réponse de Turnstile.

Qui le lit : Julien Bono, qui développe AéroCheck, lit la demande et ses fichiers pour préparer la checklist pour l'app. Chaque demande est aussi suivie dans un ticket d'un dépôt GitHub privé : les immatriculations, le type, le club, vos remarques, le nom et la taille des fichiers, et, en commentaires, la réponse du club et votre message de relecture ; jamais une adresse e-mail. Ce qui arrive dans l'app, c'est la checklist, jamais votre fichier, votre nom ni votre adresse.

Les e-mails au sujet de votre demande (réception, question, mise en ligne) et le lien du club partent par [Resend](https://resend.com/legal/privacy-policy), un service d'e-mail établi aux États-Unis, qui reçoit l'adresse, le message et le lien pour les livrer. Les réponses arrivent à support@aerocheck.app.

Combien de temps : tout est conservé tant que la demande est ouverte. 90 jours après sa clôture (mise en ligne, refusée ou doublon), les fichiers et toutes les adresses e-mail sont supprimés ; reste la fiche de la demande (son numéro, les immatriculations, le type, le club, le nom que vous avez donné le cas échéant, et son historique), pour que nous sachions d'où vient une checklist. Une demande dont les fichiers n'ont jamais fini d'arriver est supprimée après 24 heures. Pour faire supprimer une demande plus tôt, ou savoir ce que nous en conservons, écrivez à support@aerocheck.app ou répondez à l'un de nos e-mails.


## 5.0 Exports et partage

Vous pouvez exporter ou partager des vols (GPX, JSON, ZIP), votre carnet de vol (PDF, CSV), des plans de vol et des logs de nav (GPX, JSON, tableur, PDF) et des cartes de partage (images). Rien n'est exporté sans que vous le demandiez. La copie que l'app prépare pour la feuille de partage ou l'aperçu est supprimée dès que cette feuille se ferme (ou au lancement suivant, si l'app a été arrêtée avant). Une fois partagé, le fichier est entre vos mains : il peut contenir votre nom et un historique détaillé de vos positions.


## 6.0 Autorisations

- La position « Lorsque l'app est active » dessine la carte et enregistre le vol ; « Toujours » continue l'enregistrement quand l'écran se verrouille ou que vous changez d'app en vol.
- Mouvement permet à l'app de lire l'altimètre barométrique ; les mesures restent sur l'appareil.
- Photos (ajout uniquement) vous permet d'enregistrer une carte de partage dans votre photothèque. L'app ne peut pas voir vos photos.

Vous pouvez modifier chacune d'elles à tout moment dans l'app Réglages d'iOS.


## 7.0 Supprimer vos données

Supprimer l'app supprime ses données sur l'appareil. Pour effacer ce qui se trouve dans votre iCloud, supprimez le dossier d'AéroCheck dans iCloud Drive et les données iCloud de l'app (dans l'app Réglages d'iOS, sous votre nom, iCloud, stockage). L'enregistrement de l'achat sur notre serveur expire de lui-même (section 4.1) ; pour le faire supprimer plus tôt, contactez-nous (section 10.0). Une demande d'avion est supprimée comme le dit la section 4.3, ou plus tôt si vous écrivez à support@aerocheck.app.


## 8.0 Ce site

Le site lui-même ne dépose aucun cookie et ne mesure pas son audience. Il est servi par GitHub Pages à travers Cloudflare, et la page des avions demande la liste actuelle à api.aerocheck.app depuis votre navigateur. Les pages des demandes (envoyer une checklist, suivre une demande, la réponse d'un club) parlent à intake.aerocheck.app depuis votre navigateur (section 4.3), et le formulaire charge Cloudflare Turnstile depuis challenges.cloudflare.com. Les liens de nos e-mails portent leur code après un « # », qu'un navigateur n'envoie jamais au site : seul le serveur des demandes le reçoit, pour ouvrir la demande.


## 9.0 Open source et modifications

AéroCheck est open source : le [code source](https://github.com/fetzu/AeroCheck) permet à chacun de vérifier ce que dit cette page. Nous mettons cette politique à jour lorsque l'app ou ce site change ce qu'il envoie ; la date en tête de page indique la dernière fois.


## 10.0 Contact

Pour toute question sur cette politique ou sur vos données, ouvrez un ticket sur le [dépôt GitHub](https://github.com/fetzu/AeroCheck/issues) (sans y mettre de données personnelles : nous prendrons contact pour la suite).

Voir aussi les [conditions d'utilisation](/fr/terms), qui disent ce qu'est AéroCheck, ce qu'il n'est pas, et pourquoi le commandant de bord reste responsable de tout ce qu'il vous affiche.
