#!/usr/bin/env python3
"""
Script to add missing French translations to Localizable.xcstrings
"""

import json
import sys

# All the missing translations organized by category
TRANSLATIONS = {
    # Settings View - General
    "settings.title": {"en": "Settings", "fr": "Réglages"},
    "settings.done": {"en": "Done", "fr": "Terminé"},

    # Settings - Alert
    "settings.deleteCache.title": {"en": "Delete Cache?", "fr": "Supprimer le cache ?"},
    "settings.deleteCache.message": {"en": "This will delete the cached ICAO chart. You will need to download it again for offline use.", "fr": "Cela supprimera la carte OACI mise en cache. Vous devrez la télécharger à nouveau pour une utilisation hors ligne."},

    # Settings - Subscription
    "settings.subscription.aeroCheckPro": {"en": "AeroCheck Pro", "fr": "AeroCheck Pro"},
    "settings.subscription.accessAll": {"en": "You have access to all premium aircraft checklists.", "fr": "Vous avez accès à toutes les checklists d'avions premium."},
    "settings.subscription.lapsed": {"en": "Your subscription has lapsed. Premium checklists will remain available during the grace period.", "fr": "Votre abonnement a expiré. Les checklists premium resteront disponibles pendant la période de grâce."},
    "settings.subscription.unlockText": {"en": "Subscribe to unlock additional aircraft checklists.", "fr": "Abonnez-vous pour débloquer des checklists d'avions supplémentaires."},

    # Settings - Aircraft
    "settings.aircraft.premiumAircrafts": {"en": "Premium Aircrafts", "fr": "Avions Premium"},
    "settings.aircraft.noPremiumAircraft": {"en": "No premium aircraft", "fr": "Aucun avion premium"},
    "settings.aircraft.getLatestData": {"en": "Get latest aircraft data", "fr": "Obtenir les dernières données"},
    "settings.aircraft.selectAircraft": {"en": "Select the aircraft you will be flying. Premium aircraft require an AeroCheck Pro subscription. Tap 'Get latest aircraft data' to refresh the list and check for checklist updates.", "fr": "Sélectionnez l'avion que vous allez piloter. Les avions premium nécessitent un abonnement AeroCheck Pro. Appuyez sur 'Obtenir les dernières données' pour actualiser la liste et vérifier les mises à jour des checklists."},

    # Settings - GPS
    "settings.gps.recordingInterval": {"en": "Recording Interval", "fr": "Intervalle d'enregistrement"},
    "settings.gps.gpsStatus": {"en": "GPS Status", "fr": "Statut GPS"},
    "settings.gps.lowerIntervals": {"en": "Lower intervals provide more detailed tracks but use more storage", "fr": "Des intervalles plus courts fournissent des traces plus détaillées mais utilisent plus de stockage"},

    # Settings - Experimental
    "settings.experimental.showEstimatedAirspeed": {"en": "Show Estimated Airspeed", "fr": "Afficher la vitesse air estimée"},
    "settings.experimental.whenEnabled": {"en": "When enabled, displays an estimated indicated airspeed (IAS) calculated from GPS ground speed and wind data from MeteoSwiss.", "fr": "Lorsqu'activé, affiche une vitesse air indiquée (IAS) estimée calculée à partir de la vitesse sol GPS et des données de vent de MétéoSuisse."},
    "settings.experimental.onlyInSwitzerland": {"en": "This feature only works in Switzerland and requires a constant cellular connection.", "fr": "Cette fonctionnalité fonctionne uniquement en Suisse et nécessite une connexion cellulaire constante."},

    # Settings - Flight Planning
    "settings.flightPlanning.waypointProximity": {"en": "Waypoint Proximity", "fr": "Proximité des waypoints"},
    "settings.flightPlanning.terrainAltitudeUnit": {"en": "Terrain Altitude Unit", "fr": "Unité d'altitude du terrain"},
    "settings.flightPlanning.planFlightRoutes": {"en": "Plan flight routes with waypoints, time/distance calculations, and terrain visualization.", "fr": "Planifiez des routes de vol avec waypoints, calculs de temps/distance et visualisation du terrain."},
    "settings.flightPlanning.waypointProximityDesc": {"en": "Waypoint Proximity: Distance at which waypoints auto-advance during flight.", "fr": "Proximité des waypoints : Distance à laquelle les waypoints avancent automatiquement pendant le vol."},
    "settings.flightPlanning.terrainUnitDesc": {"en": "Terrain Altitude Unit: Unit for displaying terrain profile elevation.", "fr": "Unité d'altitude du terrain : Unité pour afficher l'élévation du profil du terrain."},

    # Settings - Display
    "settings.display.keepScreenOnDesc": {"en": "Keep Screen On: Prevents the screen from dimming during flight.", "fr": "Garder l'écran allumé : Empêche l'écran de s'assombrir pendant le vol."},
    "settings.display.alwaysUseUTCDesc": {"en": "Always Use UTC Times: When enabled, all times in the app are displayed in UTC with a (UTC) suffix.", "fr": "Toujours utiliser l'heure UTC : Lorsqu'activé, toutes les heures dans l'application sont affichées en UTC avec un suffixe (UTC)."},

    # Settings - Navigation
    "settings.navigation.forceICAODesc": {"en": "When ON, the ICAO Chart (1:500,000) remains at all zoom levels. When OFF, seamlessly switches to Segelflugkarte (1:300,000) when zooming in.", "fr": "Lorsque activé, la carte OACI (1:500 000) reste à tous les niveaux de zoom. Lorsque désactivé, bascule automatiquement vers la Segelflugkarte (1:300 000) lors du zoom."},

    # Settings - iCloud
    "settings.icloud.lastSync": {"en": "Last Sync", "fr": "Dernière synchro"},
    "settings.icloud.syncNow": {"en": "Sync Now", "fr": "Synchroniser"},
    "settings.icloud.syncing": {"en": "Syncing...", "fr": "Synchronisation..."},
    "settings.icloud.whenEnabledDesc": {"en": "When enabled, your settings and flight logs are synced across all your devices signed into the same iCloud account.", "fr": "Lorsqu'activé, vos réglages et journaux de vol sont synchronisés sur tous vos appareils connectés au même compte iCloud."},
    "settings.icloud.flightLogsStored": {"en": "Your flight logs are stored in the AéroCheck folder in Files and can be accessed from any device.", "fr": "Vos journaux de vol sont stockés dans le dossier AéroCheck dans Fichiers et peuvent être consultés depuis n'importe quel appareil."},

    # Settings - Offline Maps
    "settings.offlineMaps.icaoChart": {"en": "ICAO Chart", "fr": "Carte OACI"},
    "settings.offlineMaps.segelflugkarte": {"en": "Segelflugkarte", "fr": "Segelflugkarte"},
    "settings.offlineMaps.totalCacheSize": {"en": "Total Cache Size", "fr": "Taille totale du cache"},
    "settings.offlineMaps.updateAddCharts": {"en": "Update/Add Charts", "fr": "Mettre à jour/Ajouter"},
    "settings.offlineMaps.deleteAllCached": {"en": "Delete All Cached Charts", "fr": "Supprimer toutes les cartes"},
    "settings.offlineMaps.downloadCharts": {"en": "Download Charts", "fr": "Télécharger les cartes"},
    "settings.offlineMaps.offlineActive": {"en": "Offline mode active. Both ICAO Chart and Segelflugkarte are available from cache.", "fr": "Mode hors ligne actif. La carte OACI et la Segelflugkarte sont disponibles en cache."},
    "settings.offlineMaps.onlyICAO": {"en": "Offline mode active. Only ICAO Chart is cached. Download Segelflugkarte for seamless zooming in offline mode.", "fr": "Mode hors ligne actif. Seule la carte OACI est en cache. Téléchargez la Segelflugkarte pour un zoom fluide en mode hors ligne."},
    "settings.offlineMaps.chartsCached": {"en": "Charts cached for faster loading. Updated yearly by swisstopo in April.", "fr": "Cartes en cache pour un chargement plus rapide. Mises à jour annuellement par swisstopo en avril."},
    "settings.offlineMaps.downloadDesc": {"en": "Download charts for offline navigation. ICAO Chart is required; Segelflugkarte is optional for detailed zooming.", "fr": "Téléchargez les cartes pour la navigation hors ligne. La carte OACI est requise ; la Segelflugkarte est optionnelle pour un zoom détaillé."},

    # Settings - About
    "settings.about.appVersion": {"en": "App Version", "fr": "Version de l'app"},
    "settings.about.website": {"en": "Website", "fr": "Site web"},
    "settings.about.author": {"en": "Author", "fr": "Auteur"},
    "settings.about.openSource": {"en": "Open Source", "fr": "Open Source"},
    "settings.about.openSourceDesc": {"en": "This app is open source and available on GitHub.", "fr": "Cette application est open source et disponible sur GitHub."},
    "settings.about.mitLicense": {"en": "Released under the MIT License.", "fr": "Publié sous licence MIT."},

    # Settings - Available Checklists
    "settings.availableChecklists.noCached": {"en": "No checklists cached", "fr": "Aucune checklist en cache"},
    "settings.availableChecklists.version": {"en": "Version %@", "fr": "Version %@"},
    "settings.availableChecklists.cachedDesc": {"en": "Checklists cached on this device for offline use. Checklists are downloaded when you select an aircraft and refreshed automatically every 24 hours when online.", "fr": "Checklists en cache sur cet appareil pour une utilisation hors ligne. Les checklists sont téléchargées lorsque vous sélectionnez un avion et actualisées automatiquement toutes les 24 heures en ligne."},

    # Settings - Data
    "settings.data.recordedFlights": {"en": "Recorded Flights", "fr": "Vols enregistrés"},
    "settings.data.totalGPSPoints": {"en": "Total GPS Points", "fr": "Points GPS totaux"},

    # Settings - Developer
    "settings.developer.marketingMode": {"en": "Marketing Mode", "fr": "Mode marketing"},
    "settings.developer.forceNotSubscribed": {"en": "Force 'Not Subscribed' State", "fr": "Forcer l'état 'Non abonné'"},
    "settings.developer.showAllTransactions": {"en": "Show All Transactions", "fr": "Afficher toutes les transactions"},
    "settings.developer.showSubscriptionLogs": {"en": "Show Subscription Logs", "fr": "Afficher les logs d'abonnement"},
    "settings.developer.resetSubscription": {"en": "Reset Subscription State", "fr": "Réinitialiser l'abonnement"},
    "settings.developer.marketingModeDesc": {"en": "Marketing Mode: When enabled, shake your device to show the marketing location controls overlay. This allows you to simulate GPS positions for taking screenshots.", "fr": "Mode marketing : Lorsqu'activé, secouez votre appareil pour afficher les contrôles de localisation marketing. Cela vous permet de simuler des positions GPS pour prendre des captures d'écran."},
    "settings.developer.forceNotSubscribedDesc": {"en": "Force 'Not Subscribed': Ignores actual subscription status and pretends you're not subscribed. Useful for testing the free experience even with an active subscription.", "fr": "Forcer 'Non abonné' : Ignore le statut réel de l'abonnement et prétend que vous n'êtes pas abonné. Utile pour tester l'expérience gratuite même avec un abonnement actif."},
    "settings.developer.showAllTransactionsDesc": {"en": "Show All Transactions: Displays all StoreKit transactions for debugging subscription issues.", "fr": "Afficher toutes les transactions : Affiche toutes les transactions StoreKit pour déboguer les problèmes d'abonnement."},
    "settings.developer.showSubscriptionLogsDesc": {"en": "Show Subscription Logs: Real-time logs of subscription sync operations and server communication.", "fr": "Afficher les logs d'abonnement : Logs en temps réel des opérations de synchronisation d'abonnement et de communication serveur."},
    "settings.developer.resetSubscriptionDesc": {"en": "Reset Subscription: Clears cached subscription state and re-checks with StoreKit.", "fr": "Réinitialiser l'abonnement : Efface l'état d'abonnement en cache et revérifie avec StoreKit."},

    # Beta Warning Sheets
    "warning.betaFeature": {"en": "Beta Feature", "fr": "Fonctionnalité Bêta"},
    "warning.experimentalFeature": {"en": "Experimental Feature", "fr": "Fonctionnalité Expérimentale"},
    "warning.iUnderstandEnable": {"en": "I Understand - Enable Feature", "fr": "J'ai compris - Activer"},
    "warning.cancel": {"en": "Cancel", "fr": "Annuler"},

    # Flight Planning Warning
    "warning.flightPlanning.betaDesc": {"en": "Flight Planning is a beta feature. It is provided for planning purposes only and should not replace proper flight preparation.", "fr": "La planification de vol est une fonctionnalité bêta. Elle est fournie à des fins de planification uniquement et ne doit pas remplacer une préparation de vol appropriée."},
    "warning.flightPlanning.planRoutes": {"en": "Plan routes with waypoints, calculate times and distances, and visualize terrain along your route.", "fr": "Planifiez des routes avec waypoints, calculez les temps et distances, et visualisez le terrain le long de votre route."},
    "warning.flightPlanning.autoAdvance": {"en": "During flight, the app can automatically advance waypoints based on your GPS position.", "fr": "Pendant le vol, l'application peut faire avancer automatiquement les waypoints en fonction de votre position GPS."},
    "warning.flightPlanning.terrainViz": {"en": "Terrain visualization is only available within Switzerland using swisstopo data.", "fr": "La visualisation du terrain n'est disponible qu'en Suisse en utilisant les données swisstopo."},

    # Estimated Airspeed Warning
    "warning.estimatedAirspeed.calculated": {"en": "The estimated indicated airspeed (IAS) shown is calculated from GPS ground speed and wind data from MeteoSwiss weather stations.", "fr": "La vitesse air indiquée (IAS) estimée affichée est calculée à partir de la vitesse sol GPS et des données de vent des stations météo de MétéoSuisse."},
    "warning.estimatedAirspeed.inaccurate": {"en": "This estimation can be highly inaccurate due to local wind variations, altitude differences, and station distance.", "fr": "Cette estimation peut être très imprécise en raison des variations de vent locales, des différences d'altitude et de la distance de la station."},
    "warning.estimatedAirspeed.alwaysRelyOnboard": {"en": "Always rely on your aircraft's onboard airspeed indicator for actual IAS readings.", "fr": "Fiez-vous toujours à l'indicateur de vitesse air de bord de votre avion pour les lectures IAS réelles."},
    "warning.estimatedAirspeed.requiresCellular": {"en": "This feature requires a constant cellular connection and only works within Switzerland.", "fr": "Cette fonctionnalité nécessite une connexion cellulaire constante et ne fonctionne qu'en Suisse."},

    # Download Sheet
    "download.title": {"en": "Download Charts", "fr": "Télécharger les cartes"},
    "download.description": {"en": "Download Swiss aeronautical charts for offline navigation and faster loading.", "fr": "Téléchargez les cartes aéronautiques suisses pour une navigation hors ligne et un chargement plus rapide."},
    "download.selectCharts": {"en": "Select Charts to Download", "fr": "Sélectionner les cartes à télécharger"},
    "download.downloadingTiles": {"en": "Downloading tiles...", "fr": "Téléchargement des tuiles..."},
    "download.estimatedTimeRemaining": {"en": "Estimated time remaining: %@", "fr": "Temps restant estimé : %@"},
    "download.total": {"en": "Total: %@", "fr": "Total : %@"},
    "download.done": {"en": "Done", "fr": "Terminé"},
    "download.cancel": {"en": "Cancel", "fr": "Annuler"},
    "download.redownload": {"en": "Re-download Charts", "fr": "Retélécharger les cartes"},
    "download.downloadSegelflug": {"en": "Download Segelflugkarte", "fr": "Télécharger la Segelflugkarte"},
    "download.cached": {"en": "CACHED", "fr": "EN CACHE"},

    # Transaction Debug
    "debug.transaction.loading": {"en": "Loading transactions...", "fr": "Chargement des transactions..."},
    "debug.transaction.noFound": {"en": "No Transactions Found", "fr": "Aucune transaction trouvée"},
    "debug.transaction.couldMean": {"en": "This could mean:\\n• You're not signed into an Apple ID\\n• No subscriptions have been purchased\\n• Testing with StoreKit Configuration file", "fr": "Cela pourrait signifier :\\n• Vous n'êtes pas connecté à un identifiant Apple\\n• Aucun abonnement n'a été acheté\\n• Test avec un fichier de configuration StoreKit"},
    "debug.transaction.totalTransactions": {"en": "Total Transactions", "fr": "Transactions totales"},
    "debug.transaction.activeSubscriptions": {"en": "Active Subscriptions", "fr": "Abonnements actifs"},
    "debug.transaction.accountType": {"en": "Account Type", "fr": "Type de compte"},
    "debug.transaction.summary": {"en": "Summary", "fr": "Résumé"},
    "debug.transaction.allTransactions": {"en": "All Transactions", "fr": "Toutes les transactions"},
    "debug.transaction.title": {"en": "Transaction Debug", "fr": "Débogage des transactions"},
    "debug.transaction.close": {"en": "Close", "fr": "Fermer"},
    "debug.transaction.environment": {"en": "Environment", "fr": "Environnement"},
    "debug.transaction.purchased": {"en": "Purchased", "fr": "Acheté"},
    "debug.transaction.expires": {"en": "Expires", "fr": "Expire"},
    "debug.transaction.transactionID": {"en": "Transaction ID", "fr": "ID de transaction"},
    "debug.transaction.originalID": {"en": "Original ID", "fr": "ID original"},
    "debug.transaction.verificationError": {"en": "Verification Error: %@", "fr": "Erreur de vérification : %@"},
    "debug.transaction.revokedOn": {"en": "Revoked on %@", "fr": "Révoqué le %@"},

    # Subscription Debug Log
    "debug.subscriptionLog.noLogs": {"en": "No Logs Yet", "fr": "Pas encore de logs"},
    "debug.subscriptionLog.logsAppear": {"en": "Logs will appear here when you sync with the server or perform subscription operations.", "fr": "Les logs apparaîtront ici lorsque vous synchroniserez avec le serveur ou effectuerez des opérations d'abonnement."},
    "debug.subscriptionLog.title": {"en": "Subscription Logs", "fr": "Logs d'abonnement"},
    "debug.subscriptionLog.close": {"en": "Close", "fr": "Fermer"},

    # Premium Aircraft List
    "premium.loadingAircraft": {"en": "Loading premium aircraft...", "fr": "Chargement des avions premium..."},
    "premium.noAircraftAvailable": {"en": "No Premium Aircraft Available", "fr": "Aucun avion premium disponible"},
    "premium.checkBackLater": {"en": "Check back later for new aircraft.", "fr": "Revenez plus tard pour de nouveaux avions."},
    "premium.title": {"en": "Premium Aircraft", "fr": "Avions Premium"},
    "premium.requiresAeroCheckPro": {"en": "Requires AeroCheck Pro", "fr": "Nécessite AeroCheck Pro"},

    # Checklist - Action Buttons (should respect checklist language)
    "checklist.engineStart": {"en": "ENGINE START", "fr": "DÉMARRAGE MOTEUR"},
    "checklist.started": {"en": "Started", "fr": "Démarré"},
    "checklist.readyForLineUp": {"en": "READY FOR LINE UP", "fr": "PRÊT POUR L'ALIGNEMENT"},
    "checklist.lineUp": {"en": "Line Up", "fr": "Alignement"},
    "checklist.engineShutdown": {"en": "ENGINE SHUTDOWN", "fr": "ARRÊT MOTEUR"},
    "checklist.shutdown": {"en": "Shutdown", "fr": "Arrêt"},
    "checklist.goAround": {"en": "GO AROUND", "fr": "REMISE DE GAZ"},
    "checklist.goArounds": {"en": "Go Arounds", "fr": "Remises de gaz"},
    "checklist.touchAndGo": {"en": "TOUCH-AND-GO", "fr": "POSÉ-DÉCOLLÉ"},
    "checklist.touchAndGoes": {"en": "Touch-and-goes", "fr": "Posés-décollés"},
    "checklist.fullStop": {"en": "FULL STOP", "fr": "ARRÊT COMPLET"},
    "checklist.fullStops": {"en": "Full Stops", "fr": "Arrêts complets"},
    "checklist.landed": {"en": "LANDED", "fr": "ATTERRI"},
    "checklist.landing": {"en": "Landing", "fr": "Atterrissage"},

    # Checklist - Hidden Items
    "checklist.hiddenItems.title": {"en": "HIDDEN CHECKLIST ITEMS", "fr": "ÉLÉMENTS DE CHECKLIST MASQUÉS"},
    "checklist.hiddenItems.count": {"en": "%d item%@ hidden — hold to reveal", "fr": "%d élément%@ masqué%@ — maintenir pour révéler"},
    "checklist.hiddenItems.holdToUpdate": {"en": "Hold 1.5s to update", "fr": "Maintenir 1,5 s pour mettre à jour"},
    "checklist.hiddenItems.updateConfirm": {"en": "Do you want to update the %@ time to now?", "fr": "Voulez-vous mettre à jour l'heure de %@ à maintenant ?"},

    # Checklist - Other
    "checklist.page": {"en": "PAGE %d", "fr": "PAGE %d"},
    "checklist.tapToAdvance": {"en": "Tap to advance", "fr": "Appuyer pour avancer"},

    # Checklist - Speed Reference
    "checklist.airspeeds.afm": {"en": "AIRSPEEDS (AFM)", "fr": "VITESSES AIR (AFM)"},
    "checklist.maxCrosswind": {"en": "Max crosswind", "fr": "Vent de travers max"},

    # Briefing
    "briefing.departure.title": {"en": "Departure Briefing", "fr": "Briefing de départ"},
    "briefing.approach.title": {"en": "Approach Briefing", "fr": "Briefing d'approche"},
    "briefing.departure": {"en": "DEPARTURE", "fr": "DÉPART"},
    "briefing.approach": {"en": "APPROACH", "fr": "APPROCHE"},
    "briefing.airspeeds": {"en": "AIRSPEEDS (IAS)", "fr": "VITESSES AIR (IAS)"},
    "briefing.emergencyBriefing": {"en": "EMERGENCY BRIEFING", "fr": "BRIEFING D'URGENCE"},
    "briefing.missedApproach": {"en": "MISSED APPROACH", "fr": "APPROCHE MANQUÉE"},
    "briefing.alternate": {"en": "ALTERNATE", "fr": "DÉGAGEMENT"},
    "briefing.close": {"en": "Close", "fr": "Fermer"},

    # Flight Log
    "flightLog.title": {"en": "Flight Log", "fr": "Journal de vol"},
    "flightLog.close": {"en": "Close", "fr": "Fermer"},
    "flightLog.exportAll.title": {"en": "Export All Flights", "fr": "Exporter tous les vols"},
    "flightLog.exportAll.gpx": {"en": "GPX Files (.zip)", "fr": "Fichiers GPX (.zip)"},
    "flightLog.exportAll.json": {"en": "JSON Files (.zip)", "fr": "Fichiers JSON (.zip)"},
    "flightLog.exportAll.message": {"en": "Export all %d flights as a ZIP archive", "fr": "Exporter les %d vols dans une archive ZIP"},
    "flightLog.importError.title": {"en": "Import Error", "fr": "Erreur d'importation"},
    "flightLog.importError.ok": {"en": "OK", "fr": "OK"},
    "flightLog.noFlights.title": {"en": "No Flights Recorded", "fr": "Aucun vol enregistré"},
    "flightLog.noFlights.message": {"en": "Start a flight to begin recording.\\nYour flights will appear here.", "fr": "Démarrez un vol pour commencer l'enregistrement.\\nVos vols apparaîtront ici."},
    "flightLog.importFlight": {"en": "Import Flight", "fr": "Importer un vol"},

    # Flight Detail
    "flightDetail.exportFormat.title": {"en": "Export Format", "fr": "Format d'export"},
    "flightDetail.exportFormat.gpx": {"en": "GPX (GPS Track)", "fr": "GPX (Trace GPS)"},
    "flightDetail.exportFormat.json": {"en": "JSON (Full Data)", "fr": "JSON (Données complètes)"},
    "flightDetail.exportFormat.message": {"en": "Choose export format. JSON includes all flight times and data.", "fr": "Choisissez le format d'export. JSON inclut tous les temps et données de vol."},
    "flightDetail.delete.title": {"en": "Delete Flight?", "fr": "Supprimer le vol ?"},
    "flightDetail.delete.message": {"en": "This action cannot be undone.", "fr": "Cette action ne peut pas être annulée."},
    "flightDetail.flightTrack": {"en": "FLIGHT TRACK", "fr": "TRACE DE VOL"},
    "flightDetail.noGPSData": {"en": "No GPS data recorded", "fr": "Aucune donnée GPS enregistrée"},
    "flightDetail.altitudeProfile": {"en": "ALTITUDE PROFILE", "fr": "PROFIL D'ALTITUDE"},
    "flightDetail.noAltitudeData": {"en": "No altitude data recorded", "fr": "Aucune donnée d'altitude enregistrée"},
    "flightDetail.flightDetails": {"en": "FLIGHT DETAILS", "fr": "DÉTAILS DU VOL"},
    "flightDetail.aircraft": {"en": "Aircraft", "fr": "Avion"},
    "flightDetail.date": {"en": "Date", "fr": "Date"},
    "flightDetail.flightTime": {"en": "Flight Time", "fr": "Temps de vol"},
    "flightDetail.distance": {"en": "Distance", "fr": "Distance"},
    "flightDetail.gpsPoints": {"en": "GPS Points", "fr": "Points GPS"},
    "flightDetail.goArounds": {"en": "Go Arounds", "fr": "Remises de gaz"},
    "flightDetail.touchAndGoes": {"en": "Touch-and-goes", "fr": "Posés-décollés"},
    "flightDetail.fullStops": {"en": "Full Stops", "fr": "Arrêts complets"},
    "flightDetail.flightTimes": {"en": "FLIGHT TIMES", "fr": "TEMPS DE VOL"},
    "flightDetail.sessionStart": {"en": "Session Start", "fr": "Début de session"},
    "flightDetail.engineStart": {"en": "Engine Start", "fr": "Démarrage moteur"},
    "flightDetail.takeoff": {"en": "Take-off", "fr": "Décollage"},
    "flightDetail.landing": {"en": "Landing", "fr": "Atterrissage"},
    "flightDetail.engineShutdown": {"en": "Engine Shutdown", "fr": "Arrêt moteur"},
    "flightDetail.sessionEnd": {"en": "Session End", "fr": "Fin de session"},
    "flightDetail.flightName": {"en": "FLIGHT NAME", "fr": "NOM DU VOL"},
    "flightDetail.namePlaceholder": {"en": "Enter flight name (e.g., Circuits 2)", "fr": "Entrez le nom du vol (ex: Circuits 2)"},
    "flightDetail.notes": {"en": "NOTES", "fr": "NOTES"},
    "flightDetail.navPlan": {"en": "Nav Plan", "fr": "Plan de nav"},
    "flightDetail.export": {"en": "Export", "fr": "Exporter"},
    "flightDetail.delete": {"en": "Delete", "fr": "Supprimer"},

    # Altitude Chart
    "altitudeChart.noData": {"en": "No altitude data", "fr": "Pas de données d'altitude"},
    "altitudeChart.altitude": {"en": "Altitude (ft MSL)", "fr": "Altitude (ft MSL)"},

    # Flight Share Card
    "flightShare.flightTime": {"en": "FLIGHT TIME", "fr": "TEMPS DE VOL"},
    "flightShare.altitudeProfile": {"en": "ALTITUDE PROFILE", "fr": "PROFIL D'ALTITUDE"},
    "flightShare.distance": {"en": "DISTANCE", "fr": "DISTANCE"},
    "flightShare.maxAlt": {"en": "MAX ALT", "fr": "ALT MAX"},
    "flightShare.goArounds": {"en": "GO-AROUNDS", "fr": "REMISES GAZ"},
    "flightShare.touchAndGo": {"en": "TOUCH & GO", "fr": "POSÉ-DÉCOLLÉ"},
    "flightShare.gpsPoints": {"en": "GPS POINTS", "fr": "PTS GPS"},
    "flightShare.start": {"en": "Start", "fr": "Début"},
    "flightShare.takeoff": {"en": "Takeoff", "fr": "Décollage"},
    "flightShare.landing": {"en": "Landing", "fr": "Atterrissage"},
    "flightShare.shutdown": {"en": "Shutdown", "fr": "Arrêt"},
}

def add_translation_entry(strings_dict, key, en_value, fr_value):
    """Add a translation entry to the strings dictionary"""
    strings_dict[key] = {
        "extractionState": "manual",
        "localizations": {
            "en": {
                "stringUnit": {
                    "state": "translated",
                    "value": en_value
                }
            },
            "fr": {
                "stringUnit": {
                    "state": "translated",
                    "value": fr_value
                }
            }
        }
    }

def main():
    # Read the existing file
    try:
        with open('AeroCheck/Localizable.xcstrings', 'r') as f:
            data = json.load(f)
    except Exception as e:
        print(f"Error reading file: {e}")
        return 1

    # Add all missing translations
    added_count = 0
    updated_count = 0

    for key, translations in TRANSLATIONS.items():
        if key in data['strings']:
            # Check if French is missing
            if 'fr' not in data['strings'][key].get('localizations', {}):
                data['strings'][key].setdefault('localizations', {})
                data['strings'][key]['localizations']['fr'] = {
                    "stringUnit": {
                        "state": "translated",
                        "value": translations['fr']
                    }
                }
                updated_count += 1
        else:
            add_translation_entry(data['strings'], key, translations['en'], translations['fr'])
            added_count += 1

    # Write back to file
    try:
        with open('AeroCheck/Localizable.xcstrings', 'w') as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        print(f"✓ Successfully added {added_count} new translations and updated {updated_count} existing ones")
        print(f"  Total keys in file: {len(data['strings'])}")
        return 0
    except Exception as e:
        print(f"Error writing file: {e}")
        return 1

if __name__ == '__main__':
    sys.exit(main())
