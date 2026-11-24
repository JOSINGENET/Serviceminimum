# Service Minimum

Inventaire, classement et réduction des services Windows au strict nécessaire.

## Ce que fait l'application

- Relève tous les services du poste et les classe : essentiel, à garder, optionnel, inutile probable, logiciel tiers.
- Garde un historique daté des relevés, pour voir sur plusieurs jours quels services tournent réellement.
- Tient la liste des services strictement nécessaires et le journal de ses évolutions.
- Affiche l'utilisation des ressources : mémoire vive, processeur, processus, services les plus gourmands.
- Enregistre plusieurs configurations nommées, les classe de la plus économe à la plus gourmande et permet de les ré-appliquer.
- N'applique que ce qui est coché, après sauvegarde de l'état antérieur.

### Fonctions ajoutées (versions 1.1 à 1.9)

- **Lancement au démarrage** : case « Lancer au démarrage de Windows » (tâche planifiée à l'ouverture de session, sans demande de confirmation). L'application tourne alors réduite près de l'horloge (icône en forme de bouclier) ; fermer la fenêtre ne l'arrête pas, clic droit sur l'icône > Quitter.
- **Historique local** : toutes les 5 minutes, relevé des services actifs, des applications ouvertes, des ports en écoute et des connexions établies.
- **Services nécessaires selon l'usage** : colonne « Usage constaté » (système, lié à une application réellement utilisée, régulier, occasionnel, jamais actif) et fichier `services-necessaires-selon-usage.csv`.
- **Anomalies** (onglet) : plantages et échecs relevés par Windows sur 24 h, service automatique arrêté sur erreur, nouveau service, mode de démarrage modifié hors de l'application, service actif alors qu'il ne l'est presque jamais, consommation élevée, envois ou téléchargements importants. Chaque ligne indique la consommation (mémoire, processeur) et l'activité réseau.
- **Ports et connexions** (onglet) : ports en écoute et connexions établies avec adresses IP, programme et service ; avis (nécessaire, normal, non nécessaire, à vérifier) et habitude (nouveau, rare, habituel) ; volumes envoyés et téléchargés par connexion.
- **Habitude** (version 1.2) : chaque service, chaque port et chaque connexion est classé Habituel, Inhabituel ou Suspect (Apprentissage pendant la première heure), avec un filtre dans chaque liste. Suspect = programme non signé ouvert au réseau ou qui communique sur Internet, port à risque, exécutable de service non signé hors des dossiers de programmes, envois importants. Le motif s'affiche au survol de la case ; « Déclarer habituel » lève le classement pour un élément connu (`elements-declares-habituels.csv`).
- **Tableau de bord** (version 1.3) : bouton « Tableau de bord » ; page sombre de style futuriste ouverte dans le navigateur (jauges, anomalies, connexions, globe ou carte du monde). Elle est servie par l'application sur `127.0.0.1` uniquement, en lecture seule, et seulement une fois le tableau de bord ouvert.
- **Origine** (version 1.3) : bouton « Origine (carte) » ou double-clic sur une ligne de l'onglet « Ports et connexions ». Trace le parcours réseau jusqu'à l'adresse distante, nœud par nœud, et l'anime sur le globe. Les adresses IP rencontrées sont géolocalisées par le service en ligne ipwho.is, après accord demandé à la première utilisation ; les réponses sont gardées dans `geolocalisation.csv`.
- **Didacticiel** (version 1.4) : bouton « Didacticiel » ; page animée qui montre comment le processeur, le cache, la mémoire vive, la ROM (UEFI-BIOS), le disque, la carte graphique et la carte réseau se répartissent le travail, reliés par leurs bus. Cinq exemples (au repos, traitement de texte, navigation web, calcul, vidéo) mettent en évidence le chemin suivi par les données et le goulot d'étranglement de chacun.
- **Mode sombre** (version 1.5) : case « Mode sombre » dans la barre du haut ; listes, onglets, boutons et barre de titre passent en sombre. Le choix est gardé dans `preferences.json` ; sans choix enregistré, l'application suit le thème des applications de Windows.
- **Export / import des configurations** (version 1.5) : boutons « Exporter (JSON)... » et « Importer (JSON)... » de l'onglet « Configurations enregistrées ». Un import ajoute la configuration à la liste sans rien appliquer ; on l'applique ensuite avec « Appliquer la configuration sélectionnée » (changements affichés, état sauvegardé avant). Les services absents du poste sont ignorés, les services essentiels de Windows ne sont jamais modifiés.
- **Partage des journaux** (version 1.6) : bouton « Partager... » (barre du haut et onglet « Anomalies »). On coche ce qui part (synthèse lisible, journal des anomalies, services nécessaires, journal des modifications, ports, connexions, applications utilisées, configuration sélectionnée) ; un paquet .zip est préparé dans `donnees\partages`, puis le message s'ouvre : brouillon Outlook avec pièce jointe (ou messagerie par défaut), WhatsApp avec la synthèse préremplie, ou Messenger. Le paquet est mis dans le presse-papiers (Ctrl+V dans la conversation). Rien n'est envoyé automatiquement. Les éléments contenant des adresses IP ou la liste des programmes sont décochés par défaut.
- **Périphériques** (version 1.7) : onglet « Périphériques ».
  - *USB, Bluetooth, claviers et souris* : appareils branchés ou associés, historique (première et dernière fois), journal des branchements et débranchements en temps réel, bulle d'alerte à chaque nouvel appareil. Classement Habituel / Inhabituel / Suspect : un appareil inconnu est « Inhabituel » pendant 7 jours ; un nouveau clavier USB est « Suspect » (certaines clés malveillantes se font passer pour un clavier).
  - *Wi-Fi* : carte Wi-Fi, réseau utilisé (signal, canal, sécurité), réseaux à portée et réseaux enregistrés, avec leur niveau de sécurité (ouvert, WEP, WPA/TKIP, WPA2, WPA3). « Suspect » : réseau ouvert enregistré en connexion automatique, ou réseau à portée portant le nom d'un réseau enregistré avec une sécurité plus faible (possible faux point d'accès). Les mots de passe Wi-Fi ne sont jamais lus.
  - *Actions* (avec confirmation et journal) : désactiver / réactiver un périphérique (sauf claviers et souris), couper / rétablir le Wi-Fi ou le Bluetooth, oublier un réseau Wi-Fi enregistré, bloquer / débloquer les clés et disques USB (pilotes USBSTOR et UASPStor ; les appareils déjà branchés restent utilisables jusqu'à leur débranchement).
  - Les éléments suspects, les périphériques en erreur et les nouveaux appareils remontent aussi dans l'onglet « Anomalies ».
- **Démarrage de Windows** (version 1.8) : onglet « Démarrage de Windows ». Liste tout ce qui se lance au démarrage : clés Run et RunOnce du registre (utilisateur, tous les utilisateurs, 32 bits), dossiers Démarrage, tâches planifiées à l'ouverture de session ou au démarrage de l'ordinateur. Pour chacun : état, éditeur, signature, mémoire utilisée s'il tourne, date d'apparition. Classement Habituel / Inhabituel / Suspect (nouvel élément, commande modifiée, programme introuvable, programme non signé, commande de script qui télécharge ou masque sa fenêtre). Actions : désactiver / activer (même mécanisme que le Gestionnaire des tâches, réversible), ajouter un programme au démarrage, retirer un raccourci du dossier Démarrage (mis de côté, récupérable), ouvrir l'emplacement. Bulle d'alerte à chaque nouveau programme au démarrage. Les composants de sécurité (antivirus) ne sont pas désactivables ici. Les applications du Microsoft Store se règlent dans Paramètres > Applications > Démarrage.
- **Gestes à la webcam** (version 1.8) : bouton « Gestes » du tableau de bord. Pincer (pouce + index) et bouger : tourner le globe ; deux mains pincées : zoom ; index pointé maintenu sur un bouton ou une connexion : le sélectionner ; main ouverte balayée : globe ou carte ; poing fermé 1 s : réinitialiser la vue. Le suivi des mains (MediaPipe) tourne dans le navigateur : l'image de la webcam n'est envoyée nulle part. La bibliothèque et le modèle sont téléchargés une fois (jsDelivr et Google) puis gardés en cache.
- **Réduction progressive** (version 1.9) : bouton « Réduction progressive : palier suivant... » de l'onglet « Diagnostic d'optimisation ». L'application réduit les services par paliers, du moins risqué au plus risqué : 1. inutiles probables à l'arrêt ; 2. automatiques jamais vus actifs ; 3. optionnels ; 4. tiers et non classés peu actifs ; 5. essai de mise en veille, par lots de 5, de ceux qui tournent en permanence sans application rattachée ; 6. gel (désactivation) de ceux qui sont restés en veille sans jamais redémarrer. Un palier ne fait que cocher des lignes : rien n'est modifié avant « APPLIQUER LA SÉLECTION ». Chaque passage d'Automatique à Manuel est suivi : après un redémarrage de Windows et 3 jours d'usage, un service qui a redémarré seul est « réveillé » (utile à la demande, il reste en veille), un service jamais réveillé devient candidat au gel. Les essentiels, les « à garder », les antivirus, les services des applications réellement utilisées et ceux dont Docker, WSL ou Claude ont besoin ne sont jamais proposés. La ligne « Réduction progressive » du diagnostic donne l'avancement ; quand plus aucun palier n'a de candidat, l'optimum est atteint.
- **Arrêts** : arrêt d'un service avec la liste de ceux qui en dépendent, fermeture du programme qui tient un port, blocage d'un port dans le pare-feu Windows (réversible).

Limites : les volumes envoyés et téléchargés sont mesurés sur les connexions TCP IPv4 ouvertes au moment des relevés (une connexion brève entre deux relevés n'est pas comptée) ; les avis « habituel / rare / nouveau » ne sont donnés qu'après une heure de relevés.

## Installation

**Version compilée.** Télécharger `ServiceMinimum.zip` depuis la page *Releases* du dépôt, le décompresser dans un dossier et lancer `ServiceMinimum.exe`. Windows demande les droits administrateur.

**Version script.** Copier `ServiceMinimum.ps1` et `Lancer Service Minimum.cmd` dans un même dossier, puis lancer le `.cmd`. Requiert Windows PowerShell 5.1 (livré avec Windows 10 et 11).

Sans droits administrateur, l'application s'ouvre en lecture seule.

Antivirus (Microsoft Defender, Kaspersky, etc.) : Service Minimum ne les arrête pas. Leur protection est verrouillée par le système (protection contre les falsifications de Defender, autodéfense de Kaspersky) et une fonction qui les désactiverait serait traitée comme un logiciel malveillant. Pour les mettre en pause, passer par leur propre interface.

## Échange de configurations avec une autre application (Fifou)

Une autre application peut transmettre une configuration à Service Minimum de deux façons :

- **Fichier** : produire un fichier JSON au format ci-dessous, que l'utilisateur importe par le bouton « Importer (JSON)... ».
- **Ligne de commande** : lancer `ServiceMinimum.exe -importer "C:\chemin\configuration.json"` (ou `Lancer Service Minimum.cmd`, via `powershell.exe -File ServiceMinimum.ps1 -importer ...`). Windows demande les droits administrateur ; si Service Minimum est déjà ouvert, le fichier lui est transmis et apparaît dans la minute.

Dans les deux cas rien n'est appliqué automatiquement : l'utilisateur garde la main.

Format (`VersionSchema` 1) :

```json
{
  "Schema": "ServiceMinimum.Configuration",
  "VersionSchema": 1,
  "Application": "Service Minimum 1.5.0",
  "Nom": "Configuration idéale",
  "Date": "2026-11-21 12:00:00",
  "MachineSource": "INGENET-127",
  "Exportee": "2026-11-21 13:50:00",
  "Windows": "10.0.19045.0",
  "Services": [
    { "Name": "DiagTrack", "DisplayName": "Expériences des utilisateurs connectés et télémétrie", "Categorie": "4 - Inutile probable", "Cible": "Disabled" },
    { "Name": "Spooler", "DisplayName": "Spouleur d'impression", "Categorie": "2 - A garder", "Cible": "Auto" }
  ]
}
```

`Name` est le nom technique du service, `Cible` son mode de démarrage voulu : `Auto`, `Manual` ou `Disabled`. Seuls `Schema`, `Services[].Name` et `Services[].Cible` sont obligatoires ; les lignes non valides sont ignorées.

## Données

Tout est écrit dans le sous-dossier `donnees`, à côté de l'application. Ce dossier est propre à chaque poste et n'est pas versionné.

| Fichier | Contenu |
|---|---|
| `inventaire-courant.json` | Dernier inventaire des services |
| `releves\` | Un relevé daté par lancement |
| `profils\` | Configurations enregistrées |
| `services-necessaires.csv` | Liste courante des services nécessaires |
| `historique-services-necessaires.csv` | Journal des évolutions de cette liste |
| `journal-modifications.csv` | Modifications appliquées aux services, arrêts, blocages de ports |
| `historique-services.csv` | Pour chaque service : nombre de relevés, nombre de relevés où il était actif |
| `historique-applications.csv` | Applications utilisées (première et dernière fois, nombre de relevés) |
| `services-necessaires-selon-usage.csv` | Services nécessaires au vu des applications utilisées et de l'historique |
| `historique-ports.csv` | Ports en écoute déjà vus (programme, service, fréquence) |
| `historique-connexions.csv` | Adresses IP distantes déjà contactées, par programme |
| `journal-ports.csv` | Ouvertures et fermetures de ports |
| `journal-anomalies.csv` | Anomalies de services détectées |
| `preferences.json` | Préférences d'affichage (mode sombre) |
| `import-en-attente\` | Configurations transmises par `-importer` pendant que l'application était ouverte (vidé automatiquement) |
| `partages\` | Paquets .zip préparés pour le partage |
| `historique-peripheriques.csv` | Périphériques USB et Bluetooth déjà vus |
| `historique-wifi.csv` | Réseaux Wi-Fi utilisés et à portée déjà vus |
| `journal-peripheriques.csv` | Branchements, débranchements, connexions Wi-Fi, désactivations, blocages |
| `historique-demarrage.csv` | Programmes lancés au démarrage de Windows déjà vus |
| `reduction-progressive.json` | Services mis en veille et avancement de la réduction progressive |
| `journal-demarrage.csv` | Programmes ajoutés, retirés, modifiés, activés ou désactivés au démarrage |
| `demarrage-retires\` | Raccourcis retirés du dossier Démarrage (les remettre pour annuler) |
| `suivi.json` | Nombre de relevés de surveillance |
| `demarrage.log` | Journal de démarrage (étapes du lancement, erreurs) |
| `erreurs.log` | Erreurs non bloquantes |

Si l'application ne s'ouvre pas, `demarrage.log` indique à quelle étape le lancement s'est arrêté.

## Publier une version

Chaque envoi sur `main` déclenche GitHub Actions (`.github/workflows/build.yml`) : vérification de la syntaxe avec l'analyseur PowerShell de Windows, compilation de `ServiceMinimum.exe` avec [ps2exe](https://github.com/MScholtes/PS2EXE), puis paquet `ServiceMinimum.zip` (exécutable, pages `tableau-de-bord.html` et `didacticiel.html`, README), téléchargeable dans l'onglet *Actions*.

Pour publier une version dans *Releases* :

1. Mettre à jour `$VersionApp` en tête de `ServiceMinimum.ps1`.
2. Pousser une étiquette : `git tag v1.8.0` puis `git push origin v1.8.0`.

Depuis le poste, `Pousser sur GitHub.cmd` envoie les modifications du dossier (il reprend l'historique déjà publié s'il est lancé pour la première fois).

## Fichiers

- `ServiceMinimum.ps1` : l'application (interface Windows Forms).
- `Lancer Service Minimum.cmd` : lanceur de la version script.
- `tableau-de-bord.html` : page du tableau de bord, de la carte « Origine » et des gestes à la webcam ; à livrer à côté de l'application (à ajouter aussi au `ServiceMinimum.zip` produit par la compilation).
- `didacticiel.html` : page du didacticiel (fonctionnement de l'ordinateur) ; à livrer à côté de l'application, s'ouvre directement sans serveur.
- `Pousser sur GitHub.cmd` : envoie les modifications du dossier sur GitHub.
- `.github/workflows/build.yml` : compilation et publication.
