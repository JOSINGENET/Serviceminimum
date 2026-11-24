#requires -version 5.1
<#
  SERVICE MINIMUM - inventaire, classement et optimisation des services Windows
  - Releve les services, les classe (essentiel / a garder / optionnel / inutile probable / tiers)
  - Garde un historique (releves dates) et plusieurs configurations nommees, re-applicables,
    classees selon les ressources mesurees quand le PC y est conforme
  - Affiche l'utilisation des ressources (memoire vive, processeur, processus, services)
  - Applique uniquement ce qui est coche, apres sauvegarde de l'etat anterieur
  - Surveillance (1.1) : lancement au demarrage, historique des services actifs et des applications
    utilisees, anomalies de services (consommation, envois et telechargements), historique et journal
    des ports et des connexions (adresses IP), arret d'un service avec ses dependances, blocage de ports
  Donnees : sous-dossier "donnees" a cote de ce script.
#>

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- Emplacement de l'application
# Lance comme script : $PSCommandPath. Compile en .exe (ps2exe) : chemin de l'executable.
$VersionApp = '1.9.0'
$CheminApp = $PSCommandPath
$EstExe = $false
if (-not $CheminApp) {
    $CheminApp = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $EstExe = $true
}
$DossierApp = Split-Path -Parent $CheminApp
# Lance par la tache planifiee d'ouverture de session : argument -demarrage (fenetre reduite pres de l'horloge)
# -importer "fichier.json" : ajoute une configuration exportee (par exemple depuis Fifou), sans l'appliquer
$ModeDemarrage = $false
$FichierAImporter = ''
for ($i = 0; $i -lt $args.Count; $i++) {
    $argument = [string]$args[$i]
    if ($argument -eq '-demarrage') { $ModeDemarrage = $true }
    elseif ($argument -eq '-importer' -and ($i + 1) -lt $args.Count) { $FichierAImporter = [string]$args[$i + 1]; $i++ }
}
if ($FichierAImporter) {
    try { $FichierAImporter = [System.IO.Path]::GetFullPath($FichierAImporter) } catch { }
}

# ---------------------------------------------------------------- Journal de demarrage
$JournalDemarrage = Join-Path (Join-Path $DossierApp 'donnees') 'demarrage.log'
function Write-Demarrage([string]$texte) {
    try {
        $dossier = Split-Path -Parent $JournalDemarrage
        if (-not (Test-Path -LiteralPath $dossier)) { New-Item -ItemType Directory -Path $dossier | Out-Null }
        Add-Content -LiteralPath $JournalDemarrage -Value ('{0} | pid {1} | {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $PID, $texte) -Encoding UTF8
    } catch { }
}
trap {
    Write-Demarrage ('ERREUR | ' + $_.Exception.Message + ' | ' + $_.ScriptStackTrace)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message + "`n`n" + $_.ScriptStackTrace, 'Service Minimum - erreur au demarrage', 'OK', 'Error')
    } catch { }
    break
}
Write-Demarrage ('lancement - version ' + $VersionApp + ' - ' + $CheminApp + ' - demarrage automatique = ' + $ModeDemarrage)

# ---------------------------------------------------------------- Elevation
$identite = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identite)
$EstAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $EstAdmin) {
    try {
        Write-Demarrage 'demande des droits administrateur'
        $suite = ''
        if ($ModeDemarrage) { $suite += ' -demarrage' }
        if ($FichierAImporter) { $suite += (' -importer "{0}"' -f $FichierAImporter) }
        if ($EstExe) {
            if ($suite) { Start-Process -FilePath $CheminApp -Verb RunAs -ArgumentList $suite.Trim() }
            else { Start-Process -FilePath $CheminApp -Verb RunAs }
        } else {
            $arguments = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $CheminApp) + $suite
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments
        }
        Write-Demarrage 'relance en administrateur demandee'
        exit
    } catch {
        Write-Demarrage ('elevation refusee ou impossible : ' + $_.Exception.Message)
        # Elevation refusee : on continue en lecture seule
    }
}

Write-Demarrage ('administrateur = ' + $EstAdmin)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------- Instance unique
# L'application peut tourner reduite pres de l'horloge : on evite d'en ouvrir une seconde.
$script:Verrou = $null
$dejaOuvert = $false
try {
    $verrouCree = $false
    $script:Verrou = New-Object System.Threading.Mutex($true, 'Global\ServiceMinimum_InstanceUnique', [ref]$verrouCree)
    if (-not $verrouCree) { $dejaOuvert = $true }
} catch {
    Write-Demarrage ('verrou d''instance indisponible : ' + $_.Exception.Message)
}
if ($dejaOuvert -and $FichierAImporter) {
    try {
        $attente = Join-Path (Join-Path $DossierApp 'donnees') 'import-en-attente'
        if (-not (Test-Path -LiteralPath $attente)) { New-Item -ItemType Directory -Path $attente | Out-Null }
        $nomAttente = ('{0}-{1}' -f (Get-Date -Format 'yyyyMMddHHmmss'), [System.IO.Path]::GetFileName($FichierAImporter))
        Copy-Item -LiteralPath $FichierAImporter -Destination (Join-Path $attente $nomAttente) -Force
        Write-Demarrage 'import transmis a l''application deja ouverte'
    } catch {
        Write-Demarrage ('import impossible : ' + $_.Exception.Message)
    }
    exit
}
if ($dejaOuvert) {
    Write-Demarrage 'deja en cours d''execution - seconde ouverture abandonnee'
    if (-not $ModeDemarrage) {
        [void][System.Windows.Forms.MessageBox]::Show("Service Minimum est déjà ouvert.`r`n`r`nIl tourne réduit près de l'horloge (icône en forme de bouclier, éventuellement derrière la flèche « ^ ») : double-cliquer sur cette icône pour afficher la fenêtre.", 'Service Minimum', 'OK', 'Information')
    }
    exit
}

# ---------------------------------------------------------------- Dossiers
$Racine     = $DossierApp
$Donnees    = Join-Path $Racine 'donnees'
$DirReleves = Join-Path $Donnees 'releves'
$DirProfils = Join-Path $Donnees 'profils'
foreach ($d in @($Donnees, $DirReleves, $DirProfils)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}
$FichierIdeal    = Join-Path $Donnees 'configuration-ideale.json'
$FichierIdealCsv = Join-Path $Donnees 'configuration-ideale.csv'
$FichierJournal  = Join-Path $Donnees 'journal-modifications.csv'
$FichierCourant  = Join-Path $Donnees 'inventaire-courant.json'
$FichierNecessaires = Join-Path $Donnees 'services-necessaires.csv'
$FichierHistoNec    = Join-Path $Donnees 'historique-services-necessaires.csv'
$FichierNecUsage     = Join-Path $Donnees 'services-necessaires-selon-usage.csv'
$FichierSuivi        = Join-Path $Donnees 'suivi.json'
$FichierHistoSvc     = Join-Path $Donnees 'historique-services.csv'
$FichierHistoApps    = Join-Path $Donnees 'historique-applications.csv'
$FichierHistoPorts   = Join-Path $Donnees 'historique-ports.csv'
$FichierHistoCnx     = Join-Path $Donnees 'historique-connexions.csv'
$FichierJournalPorts = Join-Path $Donnees 'journal-ports.csv'
$FichierJournalAno   = Join-Path $Donnees 'journal-anomalies.csv'
$FichierApprouves    = Join-Path $Donnees 'elements-declares-habituels.csv'
$FichierGeo          = Join-Path $Donnees 'geolocalisation.csv'
$FichierAccordGeo    = Join-Path $Donnees 'geolocalisation-acceptee.txt'
$FichierTableau      = Join-Path $Racine 'tableau-de-bord.html'
$FichierDidacticiel  = Join-Path $Racine 'didacticiel.html'
$FichierHistoPer     = Join-Path $Donnees 'historique-peripheriques.csv'
$FichierHistoWifi    = Join-Path $Donnees 'historique-wifi.csv'
$FichierJournalPer   = Join-Path $Donnees 'journal-peripheriques.csv'
$FichierHistoDem     = Join-Path $Donnees 'historique-demarrage.csv'
$FichierJournalDem   = Join-Path $Donnees 'journal-demarrage.csv'
$DirDemarrageRetires = Join-Path $Donnees 'demarrage-retires'
$NomTache            = 'Service Minimum'
$PrefixeRegle        = 'Service Minimum - bloquer '
$IntervalleSuiviMin  = 5

# ---------------------------------------------------------------- Base de connaissances
# Format : Nom|Categorie|Cible|Note
#   Categorie : E = essentiel (verrouille)  G = a garder  O = optionnel selon usage  I = inutile probable
#   Cible     : vide = ne rien changer, Manual, Disabled
$BaseTexte = @'
RpcSs|E||Appels de procedure distante - coeur de Windows
RpcEptMapper|E||Coeur de Windows
DcomLaunch|E||Coeur de Windows
LSM|E||Gestion des sessions
SamSs|E||Comptes et securite
Schedule|E||Planificateur de taches
EventLog|E||Journal d'evenements
EventSystem|E||Evenements COM+
PlugPlay|E||Detection du materiel
Power|E||Gestion de l'alimentation
ProfSvc|E||Profils utilisateur
UserManager|E||Gestionnaire des utilisateurs
CoreMessagingRegistrar|E||Coeur de Windows
BrokerInfrastructure|E||Taches en arriere-plan
SystemEventsBroker|E||Coeur de Windows
gpsvc|E||Strategies de groupe
Dhcp|E||Adresse reseau automatique
Dnscache|E||Resolution des noms (Internet, serveur)
NlaSvc|E||Detection du reseau
nsi|E||Interface reseau
netprofm|E||Profils reseau
Netman|E||Connexions reseau
NcbService|E||Connexions reseau
Wcmsvc|E||Gestionnaire de connexions
WlanSvc|E||Wi-Fi
dot3svc|E||Reseau filaire authentifie
WinHttpAutoProxySvc|E||Proxy automatique
BFE|E||Moteur de filtrage (pare-feu)
mpssvc|E||Pare-feu Windows
WinDefend|E||Antivirus Microsoft Defender
WdNisSvc|E||Defender - inspection reseau
MDCoreSvc|E||Defender
Sense|E||Defender for Endpoint
SecurityHealthService|E||Securite Windows
wscsvc|E||Centre de securite
SgrmBroker|E||Protection du systeme
webthreatdefsvc|E||Protection contre les menaces web
CryptSvc|E||Certificats et signatures
KeyIso|E||Isolation des cles
VaultSvc|E||Gestionnaire d'identifiants
EFS|E||Chiffrement de fichiers
BDESVC|E||BitLocker
LanmanWorkstation|E||Acces aux partages reseau (lecteurs V: W: Z:)
Winmgmt|E||Infrastructure de gestion (WMI)
AudioSrv|E||Son
AudioEndpointBuilder|E||Son
StateRepository|E||Applications modernes
TimeBrokerSvc|E||Taches en arriere-plan
TokenBroker|E||Connexion aux comptes (Microsoft 365)
Appinfo|E||Elevation administrateur (UAC)
AppXSvc|E||Applications du Store
ClipSVC|E||Licences des applications
LicenseManager|E||Licences
sppsvc|E||Activation Windows / Office
DeviceInstall|E||Installation de peripheriques
DeviceAssociationService|E||Association de peripheriques
hidserv|E||Touches et peripheriques d'entree
SENS|E||Notifications systeme
wuauserv|E||Windows Update
UsoSvc|E||Orchestrateur des mises a jour
WaaSMedicSvc|E||Reparation de Windows Update
TrustedInstaller|E||Installation des mises a jour
msiserver|E||Installation de logiciels
InstallService|E||Installation du Store
AppReadiness|E||Preparation des applications
DispBrokerDesktopSvc|E||Affichage
TextInputManagementService|E||Saisie clavier
TabletInputService|E||Saisie clavier / tactile
FontCache|E||Cache des polices
Themes|E||Apparence
ShellHWDetection|E||Detection de supports (cles USB)
StorSvc|E||Stockage
VSS|E||Cliches instantanes (sauvegardes, restauration)
swprv|E||Cliches instantanes
vds|E||Disques virtuels
DPS|E||Diagnostics
WdiServiceHost|E||Diagnostics
WdiSystemHost|E||Diagnostics
camsvc|E||Autorisations des applications
Eaphost|E||Authentification reseau
IKEEXT|E||VPN / IPsec
PolicyAgent|E||IPsec
BITS|G||Transferts en arriere-plan (mises a jour, OneDrive)
DoSvc|G||Optimisation de la distribution des mises a jour
W32Time|G||Heure exacte (horodatage des documents)
Spooler|G||Impression, y compris impression PDF
WSearch|G||Recherche Windows - indispensable a la recherche Outlook
ClickToRunSvc|G||Microsoft Office (Word, Excel, Outlook)
WebClient|G||WebDAV - acces aux bibliotheques SharePoint en lecteur reseau
OneDrive Updater Service|G||Mises a jour OneDrive / synchronisation SharePoint
FileSyncHelper|G||OneDrive
Netlogon|G||Connexion au domaine si le PC y est rattache
lmhosts|G||Noms NetBIOS (serveur local)
FDResPub|G||Decouverte reseau (voir le serveur et les PC)
fdPHost|G||Decouverte reseau
WpnService|G||Notifications
CDPSvc|G||Plateforme des appareils connectes
PcaSvc|G||Compatibilite des programmes
DusmSvc|G||Suivi de consommation de donnees
defragsvc|G||Optimisation des disques (planifiee)
SysMain|O||Prechargement des applications - gain faible sur SSD, a tester
LanmanServer|O||Utile seulement si CE PC partage des dossiers ou une imprimante
bthserv|O|Manual|Bluetooth - a garder si souris, clavier ou casque Bluetooth
BTAGService|O|Manual|Bluetooth audio (casque, kit mains libres)
BthAvctpSvc|O|Manual|Bluetooth audio
WbioSrvc|O|Manual|Windows Hello (empreinte, visage) - a garder si utilise
SCardSvr|O||Carte a puce / cle de signature electronique - a garder si utilisee
ScDeviceEnum|O||Carte a puce / cle de signature
SCPolicySvc|O||Carte a puce
CertPropSvc|O||Certificats de carte a puce
TermService|O|Manual|Bureau a distance vers ce PC
SessionEnv|O|Manual|Bureau a distance
UmRdpService|O|Manual|Bureau a distance
RasMan|O||VPN - a garder si un VPN est utilise
SstpSvc|O||VPN
WerSvc|O|Manual|Rapports d'erreurs Windows
wercplsupport|O|Manual|Rapports de problemes
TrkWks|O|Manual|Suivi des raccourcis deplaces sur le reseau
iphlpsvc|O|Manual|Transition IPv6
SSDPSRV|O|Manual|Decouverte UPnP (appareils multimedia)
upnphost|O|Manual|Hote UPnP
StiSvc|O|Manual|Scanners et appareils photo
lfsvc|O|Manual|Geolocalisation
SharedAccess|O|Manual|Partage de connexion - requis par WSL / Hyper-V
icssvc|O|Manual|Point d'acces mobile
TapiSrv|O|Manual|Telephonie
seclogon|O|Manual|Executer en tant qu'autre utilisateur
CscService|O|Manual|Fichiers hors connexion
lltdsvc|O|Manual|Cartographie du reseau
SensorService|O||Capteurs (rotation, luminosite) - portable
SensrSvc|O||Capteurs
SensorDataService|O||Capteurs
tzautoupdate|O||Fuseau horaire automatique
DiagTrack|I|Disabled|Telemetrie Microsoft
dmwappushservice|I|Disabled|Telemetrie (messages push WAP)
diagnosticshub.standardcollector.service|I|Manual|Collecte de diagnostics (developpement)
MapsBroker|I|Disabled|Cartes telechargees
RetailDemo|I|Disabled|Mode demonstration magasin
XblAuthManager|I|Disabled|Xbox
XblGameSave|I|Disabled|Xbox
XboxNetApiSvc|I|Disabled|Xbox
XboxGipSvc|I|Disabled|Accessoires Xbox
GamingServices|I|Manual|Jeux Microsoft Store
GamingServicesNet|I|Manual|Jeux Microsoft Store
Fax|I|Disabled|Telecopie
WMPNetworkSvc|I|Disabled|Partage reseau du Lecteur Windows Media
RemoteRegistry|I|Disabled|Registre a distance (risque de securite)
RemoteAccess|I|Disabled|Routage
PhoneSvc|I|Manual|Telephonie mobile
wisvc|I|Disabled|Programme Windows Insider
WalletService|I|Disabled|Portefeuille
SEMgrSvc|I|Manual|Paiements NFC
AJRouter|I|Disabled|Objets connectes AllJoyn
NetTcpPortSharing|I|Disabled|Partage de ports .NET
WpcMonSvc|I|Disabled|Controle parental
shpamsvc|I|Disabled|Comptes partages
MixedRealityOpenXRSvc|I|Disabled|Realite mixte
spectrum|I|Disabled|Realite mixte
perceptionsimulation|I|Disabled|Realite mixte
SharedRealitySvc|I|Disabled|Realite mixte
SNMPTRAP|I|Disabled|Interruptions SNMP
'@

$Base = @{}
foreach ($ligne in ($BaseTexte -split "`r?`n")) {
    if ([string]::IsNullOrWhiteSpace($ligne)) { continue }
    $p = $ligne.Split('|')
    $Base[$p[0]] = [pscustomobject]@{ Cat = $p[1]; Cible = $p[2]; Note = $p[3] }
}

$LibelleCat = @{
    'E' = '1 - Essentiel'
    'G' = '2 - A garder'
    'O' = '3 - Optionnel'
    'I' = '4 - Inutile probable'
    'T' = '5 - Logiciel tiers'
    'W' = '6 - Windows (non classe)'
    'U' = '7 - Par utilisateur'
}
$ModeFr = @{ 'Auto' = 'Automatique'; 'Manual' = 'Manuel'; 'Disabled' = 'Désactivé' }
$ModeEn = @{ 'Automatique' = 'Auto'; 'Manuel' = 'Manual'; 'Désactivé' = 'Disabled' }
$Inchange = 'Inchangé'

# ---------------------------------------------------------------- Fonctions
function Get-CheminExe([string]$pathName) {
    if ([string]::IsNullOrWhiteSpace($pathName)) { return '' }
    if ($pathName -match '^\s*"([^"]+)"') { return $matches[1] }
    if ($pathName -match '^\s*(.+?\.exe)') { return $matches[1] }
    return ($pathName.Trim() -split ' ')[0]
}

function Get-Classement($svc) {
    $nom = [string]$svc.Name
    if ($nom -match '^(.+)_[0-9a-f]{4,8}$') {
        $modele = $matches[1]
        if (Test-Path ("HKLM:\SYSTEM\CurrentControlSet\Services\{0}" -f $modele)) {
            return [pscustomobject]@{ Cat = 'U'; Cible = ''; Note = 'Service propre à la session utilisateur - non modifiable ici' }
        }
    }
    if ($Base.ContainsKey($nom)) { return $Base[$nom] }
    if ($nom -match '^(gupdate|gupdatem|GoogleUpdater|edgeupdate|edgeupdatem|MozillaMaintenance|AdobeARMservice|brave|BraveElevation|opera)') {
        return [pscustomobject]@{ Cat = 'O'; Cible = 'Manual'; Note = 'Mise à jour automatique d''un logiciel - en Manuel, la mise à jour se fait à l''ouverture du logiciel' }
    }
    $exe = Get-CheminExe ([string]$svc.PathName)
    $exeDev = [Environment]::ExpandEnvironmentVariables($exe)
    if ($exeDev -like ($env:windir + '\*')) {
        return [pscustomobject]@{ Cat = 'W'; Cible = ''; Note = 'Composant Windows non répertorié - laissé tel quel par prudence' }
    }
    $editeur = ''
    try {
        if ($exeDev -and (Test-Path -LiteralPath $exeDev)) {
            $editeur = (Get-Item -LiteralPath $exeDev).VersionInfo.CompanyName
        }
    } catch { $editeur = '' }
    if ([string]::IsNullOrWhiteSpace($editeur)) { $editeur = 'éditeur inconnu' }
    return [pscustomobject]@{ Cat = 'T'; Cible = ''; Note = ('Logiciel installé ({0}) - à décider selon l''usage du logiciel' -f $editeur) }
}

function Get-Inventaire {
    $procs = @{}
    foreach ($p in (Get-Process)) { $procs[[int]$p.Id] = $p }
    $liste = New-Object System.Collections.ArrayList
    foreach ($s in (Get-CimInstance -ClassName Win32_Service | Sort-Object DisplayName)) {
        $cl = Get-Classement $s
        $mem = 0
        $procId = [int]$s.ProcessId
        if ($procId -gt 0 -and $procs.ContainsKey($procId)) {
            try { $mem = [int][math]::Round($procs[$procId].WorkingSet64 / 1MB) } catch { $mem = 0 }
        }
        [void]$liste.Add([pscustomobject]@{
            Name        = [string]$s.Name
            DisplayName = [string]$s.DisplayName
            State       = [string]$s.State
            StartMode   = [string]$s.StartMode
            Cat         = $cl.Cat
            Cible       = $cl.Cible
            Note        = $cl.Note
            Chemin      = [string]$s.PathName
            MemMo       = $mem
            ProcId      = $procId
        })
    }
    return $liste.ToArray()
}

function Save-Releve([string]$motif, $inventaire) {
    $horodatage = Get-Date -Format 'yyyyMMdd-HHmmss'
    $fichier = Join-Path $DirReleves ("releve-{0}.json" -f $horodatage)
    $contenu = [pscustomobject]@{
        Date     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Machine  = $env:COMPUTERNAME
        Motif    = $motif
        Services = @($inventaire | ForEach-Object { [pscustomobject]@{ Name = $_.Name; State = $_.State; StartMode = $_.StartMode } })
    }
    $contenu | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $fichier -Encoding UTF8
    return $fichier
}

function Get-StatsReleves {
    # Pour chaque service : nombre de releves ou il etait actif
    $stats = @{}
    $fichiers = @(Get-ChildItem -LiteralPath $DirReleves -Filter 'releve-*.json' | Sort-Object Name | Select-Object -Last 100)
    $total = 0
    foreach ($f in $fichiers) {
        try {
            $r = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $total++
            foreach ($s in $r.Services) {
                if ($s.State -eq 'Running') {
                    if ($stats.ContainsKey($s.Name)) { $stats[$s.Name]++ } else { $stats[$s.Name] = 1 }
                }
            }
        } catch { }
    }
    # L'historique continu (surveillance) remplace les releves des qu'il est plus fourni
    if ($script:Suivi -and [int]$script:Suivi.Echantillons -gt $total -and $script:HistoSvc.Count -gt 0) {
        $continu = @{}
        foreach ($h in @($script:HistoSvc.Values)) {
            if ([int]$h.Actif -gt 0) { $continu[[string]$h.Nom] = [int]$h.Actif }
        }
        return [pscustomobject]@{ Total = [int]$script:Suivi.Echantillons; Actifs = $continu }
    }
    return [pscustomobject]@{ Total = $total; Actifs = $stats }
}

function Save-Necessaires($inventaire) {
    # Liste des services strictement necessaires (categories Essentiel et A garder)
    # + historique de ses evolutions : ajout, retrait, changement de mode de demarrage.
    $actuels = @($inventaire | Where-Object { $_.Cat -eq 'E' -or $_.Cat -eq 'G' } | Sort-Object Name | ForEach-Object {
        $mode = [string]$_.StartMode
        if ($ModeFr.ContainsKey($mode)) { $mode = $ModeFr[$mode] }
        [pscustomobject]@{ Nom = [string]$_.Name; Service = [string]$_.DisplayName; Categorie = $LibelleCat[$_.Cat]; Demarrage = $mode; Role = [string]$_.Note }
    })
    if ($actuels.Count -eq 0) { return 0 }
    $premier = -not (Test-Path -LiteralPath $FichierNecessaires)
    $avant = @{}
    if (-not $premier) {
        foreach ($l in @(Import-Csv -LiteralPath $FichierNecessaires -Delimiter ';' -Encoding UTF8)) { $avant[[string]$l.Nom] = $l }
    }
    $date = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $evenements = New-Object System.Collections.ArrayList
    $vus = @{}
    foreach ($s in $actuels) {
        $vus[$s.Nom] = $true
        if ($s.Demarrage -eq 'Unknown' -and $avant.ContainsKey($s.Nom)) { $s.Demarrage = [string]$avant[$s.Nom].Demarrage }
        $evenement = ''
        $detail = $s.Demarrage
        if ($premier) {
            $evenement = 'Liste initiale'
        } elseif (-not $avant.ContainsKey($s.Nom)) {
            $evenement = 'Ajouté'
        } elseif ([string]$avant[$s.Nom].Demarrage -ne $s.Demarrage -and [string]$avant[$s.Nom].Demarrage -ne 'Unknown') {
            $evenement = 'Démarrage modifié'
            $detail = ([string]$avant[$s.Nom].Demarrage) + ' -> ' + $s.Demarrage
        }
        if ($evenement) {
            [void]$evenements.Add([pscustomobject]@{ Date = $date; Evenement = $evenement; Nom = $s.Nom; Service = $s.Service; Categorie = $s.Categorie; Detail = $detail })
        }
    }
    foreach ($nom in @($avant.Keys)) {
        if (-not $vus.ContainsKey($nom)) {
            $a = $avant[$nom]
            [void]$evenements.Add([pscustomobject]@{ Date = $date; Evenement = 'Retiré'; Nom = [string]$a.Nom; Service = [string]$a.Service; Categorie = [string]$a.Categorie; Detail = [string]$a.Demarrage })
        }
    }
    if ($evenements.Count -gt 0) {
        $evenements | Export-Csv -LiteralPath $FichierHistoNec -Append -NoTypeInformation -Delimiter ';' -Encoding UTF8
    }
    $actuels | Export-Csv -LiteralPath $FichierNecessaires -NoTypeInformation -Delimiter ';' -Encoding UTF8
    return $evenements.Count
}

function Write-Erreur([string]$ou, $erreur) {
    try {
        $ligne = '{0} | {1} | {2} | {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $ou, $erreur.Exception.Message, $erreur.ScriptStackTrace
        Add-Content -LiteralPath (Join-Path $Donnees 'erreurs.log') -Value $ligne -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------- Ressources
function Get-Ressources {
    # Photo de l'utilisation des ressources : memoire vive, processeur, processus, services
    $ramTot = 0; $ramUtil = 0; $cpu = 0; $nbProc = 0
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $ramTot = [int][math]::Round($os.TotalVisibleMemorySize / 1KB)
        $ramUtil = $ramTot - [int][math]::Round($os.FreePhysicalMemory / 1KB)
    } catch { }
    try {
        $perf = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
        $cpu = [int]$perf.PercentProcessorTime
    } catch { }
    try { $nbProc = @(Get-Process).Count } catch { }
    $actifs = 0
    $memSvc = 0
    $parProc = @{}
    foreach ($s in $script:Inventaire) {
        if ($s.State -eq 'Running') { $actifs++ }
        $id = [int]$s.ProcId
        if ($id -gt 0 -and -not $parProc.ContainsKey($id)) {
            # Plusieurs services peuvent partager un meme processus : on ne le compte qu'une fois
            $parProc[$id] = [pscustomobject]@{ Nom = [string]$s.DisplayName; Mo = [int]$s.MemMo }
            $memSvc += [int]$s.MemMo
        }
    }
    $top = @($parProc.Values | Sort-Object Mo -Descending | Select-Object -First 3 | ForEach-Object { '{0} ({1} Mo)' -f $_.Nom, $_.Mo })
    $pct = 0
    if ($ramTot -gt 0) { $pct = [int][math]::Round(100 * $ramUtil / $ramTot) }
    $topNom = ''
    $topMo = 0
    foreach ($p in @($parProc.Values | Sort-Object Mo -Descending | Select-Object -First 1)) { $topNom = $p.Nom; $topMo = $p.Mo }
    return [pscustomobject]@{
        TopNom         = $topNom
        TopMo          = $topMo
        RamTotMo       = $ramTot
        RamMo          = $ramUtil
        RamPct         = $pct
        Cpu            = $cpu
        Processus      = $nbProc
        ServicesActifs = $actifs
        MemServicesMo  = $memSvc
        Top            = ($top -join ', ')
    }
}

function Get-Niveau([double]$valeur, [double]$seuilAttention, [double]$seuilCritique) {
    if ($valeur -ge $seuilCritique) { return 'critique' }
    if ($valeur -ge $seuilAttention) { return 'attention' }
    return 'ok'
}

function Set-Tag($tag, [string]$valeur, [string]$detail, [string]$niveau) {
    $c = $CouleursTag[$niveau]
    $tag.Panneau.BackColor = $c[0]
    $tag.Bande.BackColor = $c[1]
    $tag.Valeur.Text = $valeur
    $tag.Detail.Text = $detail
}

function Update-LabelRessources {
    # Met a jour les pastilles de ressources (vert = normal, orange = a surveiller, rouge = critique)
    $r = $script:Ressources
    if (-not $r) { return }
    Set-Tag $tagRam ('{0} %' -f $r.RamPct) ('{0:N1} / {1:N1} Go utilisés' -f ($r.RamMo / 1024), ($r.RamTotMo / 1024)) (Get-Niveau $r.RamPct 70 85)
    Set-Tag $tagCpu ('{0} %' -f $r.Cpu) 'charge instantanée' (Get-Niveau $r.Cpu 50 80)
    Set-Tag $tagProc ([string]$r.Processus) 'processus en cours' (Get-Niveau $r.Processus 200 300)
    Set-Tag $tagSvc ([string]$r.ServicesActifs) ('sur {0} services' -f $script:Inventaire.Count) (Get-Niveau $r.ServicesActifs 100 125)
    $partSvc = 0
    if ($r.RamMo -gt 0) { $partSvc = [int][math]::Round(100 * $r.MemServicesMo / $r.RamMo) }
    Set-Tag $tagMemSvc ('{0:N0} Mo' -f $r.MemServicesMo) ('{0} % de la mémoire utilisée' -f $partSvc) 'neutre'
    Set-Tag $tagTop ('{0:N0} Mo' -f $r.TopMo) $r.TopNom 'neutre'
}

# ---------------------------------------------------------------- Diagnostic d'optimisation
function Add-Diag($liste, [string]$priorite, [string]$domaine, [string]$constat, [string]$conseil) {
    [void]$liste.Add([pscustomobject]@{ Priorite = $priorite; Domaine = $domaine; Constat = $constat; Conseil = $conseil })
}

function Get-Noms($services, [int]$max) {
    $noms = @($services | Select-Object -First $max | ForEach-Object { [string]$_.DisplayName })
    $texte = $noms -join ', '
    if (@($services).Count -gt $max) { $texte += ', ...' }
    return $texte
}

function Get-Diagnostic {
    $d = New-Object System.Collections.ArrayList
    $script:Recommandes = @{}
    $r = $script:Ressources
    $inv = @($script:Inventaire)

    # 1. Memoire vive
    if ($r -and $r.RamTotMo -gt 0) {
        $gros = ''
        try {
            $groupes = @(Get-Process | Group-Object ProcessName | ForEach-Object {
                [pscustomobject]@{ Nom = $_.Name; Nb = $_.Count; Mo = [int][math]::Round((($_.Group | Measure-Object -Property WorkingSet64 -Sum).Sum) / 1MB) }
            } | Sort-Object Mo -Descending | Select-Object -First 5)
            $gros = (@($groupes | ForEach-Object { '{0} {1:N0} Mo ({2} processus)' -f $_.Nom, $_.Mo, $_.Nb }) -join ' ; ')
        } catch { }
        $partSvc = 0
        if ($r.RamMo -gt 0) { $partSvc = [int][math]::Round(100 * $r.MemServicesMo / $r.RamMo) }
        $constat = 'Mémoire vive utilisée à {0} % ({1:N1} Go sur {2:N1} Go). Les services en occupent {3:N0} Mo, soit {4} % de la mémoire utilisée. Plus gros consommateurs : {5}.' -f $r.RamPct, ($r.RamMo / 1024), ($r.RamTotMo / 1024), $r.MemServicesMo, $partSvc, $gros
        if ($r.RamPct -ge 85) {
            $conseil = 'Mémoire saturée : Windows se rabat sur le disque, ce qui ralentit tout le poste. '
            if ($partSvc -lt 25) { $conseil += 'Les services pèsent peu dans le total : le gain principal viendra des applications listées ci-contre (fermer celles qui ne servent pas, réduire les onglets et extensions du navigateur). ' }
            if ($r.RamTotMo -le 8600) { $conseil += 'Avec {0:N0} Go installés, passer à 16 Go serait la mesure la plus efficace.' -f ($r.RamTotMo / 1024) }
            Add-Diag $d 'Élevée' 'Mémoire vive' $constat $conseil
        } elseif ($r.RamPct -ge 70) {
            Add-Diag $d 'Moyenne' 'Mémoire vive' $constat 'Mémoire chargée sans être saturée : fermer les applications inutilisées et surveiller l''évolution.'
        } else {
            Add-Diag $d 'Information' 'Mémoire vive' $constat 'Rien à faire : la mémoire disponible est suffisante.'
        }
    }

    # 2. Processeur
    if ($r -and $r.Cpu -ge 80) {
        Add-Diag $d 'Élevée' 'Processeur' ('Processeur chargé à {0} % au moment de la mesure.' -f $r.Cpu) 'Si la charge persiste au repos, repérer le processus en cause dans le Gestionnaire des tâches (onglet Processus, tri par Processeur).'
    } elseif ($r -and $r.Cpu -ge 50) {
        Add-Diag $d 'Moyenne' 'Processeur' ('Processeur chargé à {0} % au moment de la mesure.' -f $r.Cpu) 'À surveiller : normal pendant un calcul ou une mise à jour, anormal si le poste est au repos.'
    }

    # 3. Services "inutiles probables" pas encore au mode propose
    $inutiles = @($inv | Where-Object { $_.Cat -eq 'I' -and $_.Cible -and $_.Cible -ne $_.StartMode })
    if ($inutiles.Count -gt 0) {
        foreach ($s in $inutiles) { $script:Recommandes[[string]$s.Name] = [string]$s.Cible }
        Add-Diag $d 'Moyenne' 'Services inutiles' ('{0} service(s) « inutiles probables » ne sont pas encore au mode proposé : {1}.' -f $inutiles.Count, (Get-Noms $inutiles 12)) 'Cliquer sur « Cocher les services recommandés », puis sur « APPLIQUER LA SÉLECTION ». Sans risque pour un usage bureautique ; l''état antérieur reste restaurable.'
    }

    # 4. Services optionnels en demarrage automatique
    $optionnels = @($inv | Where-Object { $_.Cat -eq 'O' -and $_.Cible -and $_.Cible -ne $_.StartMode -and $_.StartMode -eq 'Auto' })
    if ($optionnels.Count -gt 0) {
        Add-Diag $d 'Faible' 'Services optionnels' ('{0} service(s) optionnels démarrent automatiquement : {1}.' -f $optionnels.Count, (Get-Noms $optionnels 12)) 'À passer en Manuel si la fonction correspondante ne sert pas (voir la colonne « À quoi ça sert »). Non cochés automatiquement : à décider ligne par ligne.'
    }

    # 5. Services de logiciels tiers actifs
    $tiers = @($inv | Where-Object { $_.Cat -eq 'T' -and $_.State -eq 'Running' } | Sort-Object MemMo -Descending)
    if ($tiers.Count -gt 0) {
        $memTiers = 0
        foreach ($s in $tiers) { $memTiers += [int]$s.MemMo }
        $liste = (@($tiers | Select-Object -First 8 | ForEach-Object { '{0} ({1} Mo)' -f $_.DisplayName, $_.MemMo }) -join ', ')
        $prio = 'Faible'
        if ($memTiers -ge 500) { $prio = 'Moyenne' }
        Add-Diag $d $prio 'Logiciels tiers' ('{0} service(s) de logiciels tiers sont actifs, pour environ {1:N0} Mo : {2}.' -f $tiers.Count, $memTiers, $liste) 'Passer en Manuel ceux des logiciels peu utilisés (mises à jour automatiques, lanceurs) ; conserver l''antivirus, les licences de logiciels métier et les outils de sauvegarde.'
    }

    # 6. Services automatiques jamais vus actifs dans l'historique
    $stats = Get-StatsReleves
    if ($stats.Total -ge 5) {
        $jamais = @($inv | Where-Object { $_.StartMode -eq 'Auto' -and $_.Cat -ne 'E' -and $_.Cat -ne 'U' -and -not $stats.Actifs.ContainsKey($_.Name) })
        if ($jamais.Count -gt 0) {
            Add-Diag $d 'Faible' 'Historique' ('{0} service(s) en démarrage automatique n''ont jamais été vus actifs sur les {1} derniers relevés : {2}.' -f $jamais.Count, $stats.Total, (Get-Noms $jamais 12)) 'Candidats au mode Manuel. Le constat sera plus fiable avec des relevés pris à différents moments de la journée, sur une semaine.'
        }
    } else {
        Add-Diag $d 'Information' 'Historique' ('{0} relevé(s) seulement en historique.' -f $stats.Total) 'Le diagnostic s''affinera après une semaine : ouvrir l''application à différents moments de la journée pour repérer les services jamais utilisés.'
    }

    # 7. Configurations enregistrees
    $cfgs = @(Get-Configs)
    $meilleure = $null
    $meilleureMo = [double]::MaxValue
    foreach ($cfg in $cfgs) {
        $mes = @(Get-MesuresConfig $cfg)
        if ($mes.Count -gt 0) {
            $moy = [double](($mes | Measure-Object -Property MemServicesMo -Average).Average)
            if ($moy -lt $meilleureMo) { $meilleureMo = $moy; $meilleure = $cfg }
        }
    }
    if ($cfgs.Count -lt 2 -or -not $meilleure) {
        Add-Diag $d 'Information' 'Configurations' ('{0} configuration(s) enregistrée(s) : pas encore de quoi comparer.' -f $cfgs.Count) 'Après chaque série de modifications, enregistrer l''état actuel (onglet « Configurations enregistrées ») : le classement montrera le gain réel.'
    } else {
        $nbEcarts = @(Get-EcartsConfig $meilleure).Count
        if ($nbEcarts -gt 0) {
            Add-Diag $d 'Moyenne' 'Configurations' ('La configuration la plus économe mesurée est « {0} » ({1:N0} Mo en moyenne pour les services) ; le PC s''en écarte sur {2} service(s).' -f $meilleure.Nom, $meilleureMo, $nbEcarts) 'L''appliquer depuis l''onglet « Configurations enregistrées ».'
        } else {
            Add-Diag $d 'Information' 'Configurations' ('Le PC est conforme à la configuration la plus économe mesurée, « {0} » ({1:N0} Mo en moyenne pour les services).' -f $meilleure.Nom, $meilleureMo) 'Rien à faire.'
        }
    }
    # 8. Reduction progressive (version 1.9)
    try {
        $bilan = Get-BilanReduction
        Add-Diag $d $bilan.Priorite 'Réduction progressive' $bilan.Constat $bilan.Conseil
    } catch { Write-Erreur 'Diagnostic - reduction progressive' $_ }
    return $d.ToArray()
}

function Update-Diagnostic {
    $ordre = @{ 'Élevée' = 1; 'Moyenne' = 2; 'Faible' = 3; 'Information' = 4 }
    $niveaux = @{ 'Élevée' = 'critique'; 'Moyenne' = 'attention'; 'Faible' = 'ok'; 'Information' = 'neutre' }
    $script:Diagnostic = @(Get-Diagnostic | Sort-Object { $ordre[$_.Priorite] })
    $gridDiag.Rows.Clear()
    foreach ($x in $script:Diagnostic) {
        $i = $gridDiag.Rows.Add($x.Priorite, $x.Domaine, $x.Constat, $x.Conseil)
        $gridDiag.Rows[$i].Cells['Priorite'].Style.BackColor = $CouleursTag[$niveaux[$x.Priorite]][0]
    }
    $gridDiag.ClearSelection()
}

# ---------------------------------------------------------------- Reduction progressive (version 1.9)
# Reduit les services par paliers, du moins risque au plus risque, avec une periode d'observation
# entre deux paliers. Un palier ne fait que cocher des lignes : c'est l'utilisateur qui applique.
# Chaque passage Automatique -> Manuel est note (mise en veille) ; un service en veille qui redemarre
# tout seul est "reveille" (utile a la demande), un service jamais reveille devient candidat au gel.
$FichierReduction = Join-Path $Donnees 'reduction-progressive.json'
$ReductionObservationJours = 3
$ReductionLotEssai = 5
$ReductionNbPaliers = 6
$script:Reduction = $null

function Get-Reduction {
    if ($script:Reduction) { return $script:Reduction }
    $r = [pscustomobject]@{ Veille = @(); DernierPalier = 0; DateDernierPalier = '' }
    if (Test-Path -LiteralPath $FichierReduction) {
        try {
            $x = Get-Content -LiteralPath $FichierReduction -Raw -Encoding UTF8 | ConvertFrom-Json
            $r.Veille = @($x.Veille | Where-Object { $_ -and $_.Name })
            $r.DernierPalier = [int]$x.DernierPalier
            $r.DateDernierPalier = [string]$x.DateDernierPalier
        } catch { Write-Erreur 'Lecture reduction progressive' $_ }
    }
    $script:Reduction = $r
    return $r
}

function Save-Reduction {
    try {
        $r = Get-Reduction
        [pscustomobject]@{
            Veille            = @($r.Veille)
            DernierPalier     = [int]$r.DernierPalier
            DateDernierPalier = [string]$r.DateDernierPalier
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $FichierReduction -Encoding UTF8
    } catch { Write-Erreur 'Enregistrement reduction progressive' $_ }
}

function Register-ChangementReduction([string]$nom, [string]$avant, [string]$apres, [bool]$arrete) {
    # Appele apres chaque changement de mode reussi : tient la liste des services mis en veille
    try {
        $r = Get-Reduction
        $r.Veille = @($r.Veille | Where-Object { [string]$_.Name -ne $nom })
        if ($avant -eq 'Auto' -and $apres -eq 'Manual') {
            $actif = $false
            $s = @($script:Inventaire | Where-Object { [string]$_.Name -eq $nom }) | Select-Object -First 1
            if ($s -and $s.State -eq 'Running' -and -not $arrete) { $actif = $true }
            $r.Veille = @($r.Veille) + @([pscustomobject]@{ Name = $nom; Depuis = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); ActifAuChangement = $actif })
        }
        Save-Reduction
    } catch { Write-Erreur 'Suivi reduction progressive' $_ }
}

function Get-DernierDemarrageWindows {
    try { return (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch { return $null }
}

function ConvertTo-DateReduction([string]$texte) {
    try { return [datetime]::ParseExact($texte, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}

function Get-EtatVeille {
    # Etat de chaque service mis en veille : En attente de redémarrage / En observation / Réveillé / Jamais réveillé
    $r = Get-Reduction
    $boot = Get-DernierDemarrageWindows
    $maintenant = Get-Date
    $liste = New-Object System.Collections.ArrayList
    $garder = New-Object System.Collections.ArrayList
    foreach ($v in @($r.Veille)) {
        $nom = [string]$v.Name
        $s = @($script:Inventaire | Where-Object { [string]$_.Name -eq $nom }) | Select-Object -First 1
        # Desinstalle, remis en automatique ou gele en dehors de l'application : il sort du suivi
        if (-not $s -or [string]$s.StartMode -ne 'Manual') { continue }
        [void]$garder.Add($v)
        $depuis = ConvertTo-DateReduction ([string]$v.Depuis)
        if (-not $depuis) { $depuis = $maintenant }
        $ref = $depuis
        $attente = $false
        if ([bool]$v.ActifAuChangement) {
            # Il tournait encore au moment du changement : on ne peut rien conclure avant un redemarrage de Windows
            if ($boot -and $boot -gt $depuis) { $ref = $boot } else { $attente = $true }
        }
        $etat = 'En observation'
        $jours = [math]::Max(0, ($maintenant - $ref).TotalDays)
        if ($attente) {
            $etat = 'En attente de redémarrage'
        } else {
            $reveille = ($s.State -eq 'Running')
            if (-not $reveille -and $script:HistoSvc) {
                $h = $script:HistoSvc[(Get-NomStable $nom)]
                if ($h) {
                    $dernier = ConvertTo-DateReduction ([string]$h.DernierActif)
                    if ($dernier -and $dernier -gt $ref.AddMinutes(1)) { $reveille = $true }
                }
            }
            if ($reveille) { $etat = 'Réveillé' }
            elseif ($jours -ge $ReductionObservationJours) { $etat = 'Jamais réveillé' }
        }
        [void]$liste.Add([pscustomobject]@{ Name = $nom; DisplayName = [string]$s.DisplayName; Etat = $etat; Jours = $jours; Depuis = [string]$v.Depuis; MemMo = [int]$s.MemMo })
    }
    if ($garder.Count -ne @($r.Veille).Count) {
        $r.Veille = $garder.ToArray()
        Save-Reduction
    }
    return $liste.ToArray()
}

function Test-ServiceSecurite($s) {
    # Antivirus et composants de securite : jamais proposes a la reduction
    $t = ('{0} {1} {2}' -f $s.Name, $s.DisplayName, $s.Chemin).ToLower()
    return ($t -match 'securityhealth|windefend|defender|msmpeng|kaspersky|\\avp(ui)?\.exe|\\ksde\.exe|avast|\bavg\b|bitdefender|\beset\b|norton|sophos|malwarebytes|trend micro|mcafee')
}

function Test-ServiceLieApplication($s) {
    # Vrai si le service appartient a une application reellement utilisee
    # (meme dossier d'installation, ou meme paquet du Microsoft Store)
    $u = ''
    try { $u = [string](Get-UsageService $s) } catch { $u = '' }
    if ($u -like 'Lié à*') { return $true }
    $chemin = [string]$s.Chemin
    if ($chemin -match '\\WindowsApps\\([^\\_]+)_') {
        $paquet = $matches[1].ToLower()
        foreach ($a in @($script:HistoApps.Values)) {
            $cheminApp = [string]$a.Chemin
            if ($cheminApp -match '\\WindowsApps\\([^\\_]+)_') {
                if ($matches[1].ToLower() -eq $paquet) { return $true }
            }
        }
    }
    return $false
}

# Services dont une application a besoin sans que leur dossier d'installation le montre
# (motif cherche dans le nom des applications utilisees | services proteges de la reduction)
$LiensConnusTexte = @'
docker|WSLService,vmms,vmcompute,HvHost,hns,nvagent,iphlpsvc,com.docker.service
claude|vmms,vmcompute,HvHost,hns
wsl|WSLService,vmcompute,HvHost,hns
'@

function Get-ServicesProtegesParUsage {
    # Noms des services a ne pas proposer parce qu'une application utilisee en depend (liens connus)
    $proteges = @{}
    $apps = @($script:HistoApps.Values | ForEach-Object { ('{0} {1}' -f $_.Nom, $_.Produit).ToLower() })
    foreach ($ligne in ($LiensConnusTexte -split "`r?`n")) {
        $parts = $ligne.Split('|')
        if ($parts.Count -lt 2 -or -not $parts[0]) { continue }
        $motif = $parts[0].ToLower()
        if (@($apps | Where-Object { $_.Contains($motif) }).Count -eq 0) { continue }
        foreach ($n in $parts[1].Split(',')) { if ($n.Trim()) { $proteges[$n.Trim().ToLower()] = $motif } }
    }
    return $proteges
}

function Get-TauxActiviteService($s) {
    # Part des releves ou le service etait actif ; -1 si l'historique est trop court
    if (-not $script:HistoSvc) { return -1 }
    $h = $script:HistoSvc[(Get-NomStable ([string]$s.Name))]
    if (-not $h) { return -1 }
    $obs = [int]$h.Observations
    if ($obs -lt 12) { return -1 }
    return [int][math]::Round(100 * [int]$h.Actif / $obs)
}

function New-PalierReduction([int]$num, [string]$titre, [string]$explication, $changements) {
    return [pscustomobject]@{ Num = $num; Titre = $titre; Explication = $explication; Changements = @($changements) }
}

function New-ChangementReduction($s, [string]$cible) {
    return [pscustomobject]@{ Name = [string]$s.Name; DisplayName = [string]$s.DisplayName; Avant = [string]$s.StartMode; Cible = $cible; MemMo = [int]$s.MemMo; State = [string]$s.State }
}

function Get-PaliersReduction {
    # Retourne les paliers qui ont encore des services a proposer, du moins risque au plus risque.
    # Un service n'apparait que dans un seul palier (le premier qui le concerne).
    $paliers = New-Object System.Collections.ArrayList
    $proteges = Get-ServicesProtegesParUsage
    $inv = @($script:Inventaire | Where-Object { $_.Cat -ne 'E' -and $_.Cat -ne 'U' -and $ModeFr.ContainsKey([string]$_.StartMode) -and -not (Test-ServiceSecurite $_) })
    $pris = @{}

    # 1. Inutiles probables pas encore au mode propose par la base de connaissances.
    #    Un service inutile probable qui tourne passe d'abord par la veille (jamais de gel direct).
    $c = New-Object System.Collections.ArrayList
    foreach ($s in @($inv | Where-Object { $_.Cat -eq 'I' -and $_.Cible -and $ModeFr.ContainsKey([string]$_.Cible) -and [string]$_.Cible -ne [string]$_.StartMode })) {
        $cible = [string]$s.Cible
        if ($s.State -eq 'Running') {
            if ($s.StartMode -ne 'Auto') { continue }
            $cible = 'Manual'
        }
        [void]$c.Add((New-ChangementReduction $s $cible))
        $pris[[string]$s.Name] = $true
    }
    if ($c.Count -gt 0) { [void]$paliers.Add((New-PalierReduction 1 'services inutiles probables' 'Services que la base de connaissances classe « inutiles probables » (télémétrie, jeux, fonctions absentes de ce poste) et qui sont à l''arrêt. Risque très faible.' $c.ToArray())) }

    # Candidats a la mise en veille : automatiques, hors « a garder », non proteges par une application utilisee
    $auto = @($inv | Where-Object { $_.StartMode -eq 'Auto' -and $_.Cat -ne 'G' -and -not $pris.ContainsKey([string]$_.Name) -and -not $proteges.ContainsKey(([string]$_.Name).ToLower()) })

    # 2. Automatiques jamais vus actifs
    $c = @($auto | Where-Object { $_.State -ne 'Running' -and (Get-TauxActiviteService $_) -eq 0 } | ForEach-Object { New-ChangementReduction $_ 'Manual' })
    foreach ($x in $c) { $pris[$x.Name] = $true }
    if ($c.Count -gt 0) { [void]$paliers.Add((New-PalierReduction 2 'automatiques jamais actifs' 'Services en démarrage automatique qui n''ont jamais été vus actifs dans l''historique. En veille, ils démarreront seuls si un logiciel en a besoin. Risque très faible.' $c)) }

    # 3. Optionnels pour lesquels la base de connaissances propose un mode
    $c = @($auto | Where-Object { -not $pris.ContainsKey([string]$_.Name) -and $_.Cat -eq 'O' -and $_.Cible -and $ModeFr.ContainsKey([string]$_.Cible) -and [string]$_.Cible -ne 'Auto' } | ForEach-Object { New-ChangementReduction $_ 'Manual' })
    foreach ($x in $c) { $pris[$x.Name] = $true }
    if ($c.Count -gt 0) { [void]$paliers.Add((New-PalierReduction 3 'services optionnels' 'Services optionnels de Windows (scanner, assistance IPv6, mises à jour de navigateurs...). Risque faible : ils redémarrent à la demande.' $c)) }

    # 4. Tiers, non classes et optionnels peu actifs, sans lien avec une application utilisee
    $reste = @($auto | Where-Object { -not $pris.ContainsKey([string]$_.Name) -and @('T', 'W', 'O') -contains [string]$_.Cat -and -not (Test-ServiceLieApplication $_) })
    $c = @($reste | Where-Object { $t = Get-TauxActiviteService $_; $t -ge 0 -and $t -lt 50 } | ForEach-Object { New-ChangementReduction $_ 'Manual' })
    foreach ($x in $c) { $pris[$x.Name] = $true }
    if ($c.Count -gt 0) { [void]$paliers.Add((New-PalierReduction 4 'services peu actifs' 'Services de logiciels tiers ou non classés, actifs dans moins d''un relevé sur deux et sans lien avec une application utilisée. Risque faible.' $c)) }

    # 5. Essai par lots : ceux qui tournent en permanence sans lien avec une application utilisee
    $c = @($reste | Where-Object { -not $pris.ContainsKey([string]$_.Name) } | Sort-Object { [int]$_.MemMo } -Descending | Select-Object -First $ReductionLotEssai | ForEach-Object { New-ChangementReduction $_ 'Manual' })
    if ($c.Count -gt 0) { [void]$paliers.Add((New-PalierReduction 5 ('essai de mise en veille (lot de {0} au plus)' -f $ReductionLotEssai) 'Services qui tournent en permanence sans qu''aucune application utilisée ne leur soit rattachée. C''est un ESSAI : après le redémarrage, ceux qui se réveillent seuls sont utiles et restent en veille ; si une fonction manque, les remettre en Automatique (bouton « Restaurer un relevé »). Décocher ceux que vous savez nécessaires. Risque moyen.' $c)) }

    # 6. Gel : en veille depuis la fin de l'observation et jamais reveilles
    $parNom = @{}
    foreach ($s in $inv) { $parNom[[string]$s.Name] = $s }
    $c = @(Get-EtatVeille | Where-Object { $_.Etat -eq 'Jamais réveillé' -and $parNom.ContainsKey([string]$_.Name) } | ForEach-Object { New-ChangementReduction $parNom[[string]$_.Name] 'Disabled' })
    if ($c.Count -gt 0) { [void]$paliers.Add((New-PalierReduction 6 'gel des services jamais réveillés' ('Services mis en veille depuis au moins {0} jours et jamais redémarrés depuis : on peut les désactiver (gel). Réversible par « Restaurer un relevé ».' -f $ReductionObservationJours) $c)) }

    return $paliers.ToArray()
}

function Get-BilanReduction {
    # Texte de synthese pour le diagnostic et pour le bouton « Réduction progressive »
    $etats = @(Get-EtatVeille)
    $palier = @(Get-PaliersReduction) | Select-Object -First 1
    $nbAuto = @($script:Inventaire | Where-Object { $_.StartMode -eq 'Auto' }).Count
    $constat = '{0} service(s) en démarrage automatique.' -f $nbAuto
    if ($etats.Count -gt 0) {
        $constat += ' {0} service(s) en veille suivis :' -f $etats.Count
        foreach ($e in @('En attente de redémarrage', 'En observation', 'Réveillé', 'Jamais réveillé')) {
            $g = @($etats | Where-Object { $_.Etat -eq $e })
            if ($g.Count -gt 0) { $constat += ' {0} = {1} ({2}) ;' -f $e.ToLower(), $g.Count, (Get-Noms $g 8) }
        }
        $constat = $constat.TrimEnd(' ', ';') + '.'
    } else {
        $constat += ' Aucun service en veille suivi pour l''instant.'
    }
    $attente = @($etats | Where-Object { $_.Etat -eq 'En attente de redémarrage' }).Count
    $obs = @($etats | Where-Object { $_.Etat -eq 'En observation' })
    $conseil = ''
    if ($attente -gt 0) { $conseil += 'Redémarrer Windows (commande « Redémarrer », pas « Arrêter ») pour que la mise en veille prenne effet. ' }
    if ($obs.Count -gt 0) {
        $resteJ = [math]::Ceiling($ReductionObservationJours - [double](($obs | Measure-Object -Property Jours -Minimum).Minimum))
        if ($resteJ -lt 1) { $resteJ = 1 }
        $conseil += 'Observation en cours : encore {0} jour(s) d''usage normal avant de conclure. ' -f $resteJ
    }
    $priorite = 'Information'
    if ($palier) {
        $priorite = 'Faible'
        $conseil += 'Palier suivant : n° {0} sur {1}, {2} ({3} service(s)). Bouton « Réduction progressive : palier suivant... ».' -f $palier.Num, $ReductionNbPaliers, $palier.Titre, $palier.Changements.Count
    } elseif ($attente -eq 0 -and $obs.Count -eq 0) {
        $conseil += 'Optimum atteint : il ne reste que des services essentiels, à garder, liés à vos applications ou utiles à la demande. Enregistrer cet état (onglet « Configurations enregistrées ») pour pouvoir y revenir.'
    }
    return [pscustomobject]@{ Priorite = $priorite; Constat = $constat; Conseil = $conseil.Trim(); Palier = $palier; Etats = $etats }
}

# ---------------------------------------------------------------- Configurations enregistrees
function Get-Configs {
    $liste = New-Object System.Collections.ArrayList
    foreach ($f in @(Get-ChildItem -LiteralPath $DirProfils -Filter 'config-*.json' | Sort-Object Name)) {
        try {
            $c = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $c | Add-Member -NotePropertyName Fichier -NotePropertyValue $f.FullName -Force
            [void]$liste.Add($c)
        } catch { Write-Erreur 'Get-Configs' $_ }
    }
    return $liste.ToArray()
}

function Get-MesuresConfig($cfg) {
    $m = @()
    if ($cfg.Mesures) { $m = @($cfg.Mesures) }
    return $m
}

function Save-Config($cfg, $mesures) {
    [pscustomobject]@{
        Nom      = [string]$cfg.Nom
        Date     = [string]$cfg.Date
        Machine  = [string]$cfg.Machine
        Services = @($cfg.Services)
        Mesures  = @($mesures)
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cfg.Fichier -Encoding UTF8
}

function New-Config([string]$nom, [string]$fichier) {
    # Enregistre l'etat actuel des modes de demarrage sous un nom
    $services = @($script:Inventaire | Where-Object { $_.Cat -ne 'U' } | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; DisplayName = $_.DisplayName; Categorie = $LibelleCat[$_.Cat]; Cible = $_.StartMode }
    })
    $cfg = [pscustomobject]@{
        Nom      = $nom
        Date     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Machine  = $env:COMPUTERNAME
        Services = $services
        Fichier  = $fichier
    }
    Save-Config $cfg @()
}

function Get-EcartsConfig($cfg) {
    # Services dont le mode de demarrage actuel differe de celui de la configuration
    $voulu = @{}
    foreach ($s in $cfg.Services) { $voulu[[string]$s.Name] = [string]$s.Cible }
    return @($script:Inventaire | Where-Object { $_.Cat -ne 'U' -and $_.Cat -ne 'E' -and $voulu.ContainsKey($_.Name) -and $ModeFr.ContainsKey($voulu[$_.Name]) -and $ModeFr.ContainsKey([string]$_.StartMode) -and $voulu[$_.Name] -ne $_.StartMode } | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; DisplayName = $_.DisplayName; Avant = $_.StartMode; Cible = $voulu[$_.Name] }
    })
}

function Add-MesuresConfigs {
    # Ajoute une mesure de ressources a chaque configuration a laquelle le PC est conforme
    # (au plus une mesure par demi-heure et par configuration)
    $r = $script:Ressources
    if (-not $r) { return }
    foreach ($cfg in @(Get-Configs)) {
        if (@(Get-EcartsConfig $cfg).Count -gt 0) { continue }
        $mes = @(Get-MesuresConfig $cfg)
        if ($mes.Count -gt 0) {
            $recent = $false
            try {
                $d = [datetime]::ParseExact([string]$mes[$mes.Count - 1].Date, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
                if (((Get-Date) - $d).TotalMinutes -lt 30) { $recent = $true }
            } catch { }
            if ($recent) { continue }
        }
        $nouvelle = [pscustomobject]@{
            Date           = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            ServicesActifs = $r.ServicesActifs
            MemServicesMo  = $r.MemServicesMo
            RamMo          = $r.RamMo
            RamPct         = $r.RamPct
            Cpu            = $r.Cpu
            Processus      = $r.Processus
        }
        $mes = @($mes + $nouvelle | Select-Object -Last 200)
        Save-Config $cfg $mes
    }
}

function Update-Configs {
    # Classement : memoire moyenne occupee par les services (la plus faible en tete),
    # puis nombre moyen de services actifs. Les configurations jamais mesurees sont en fin de liste.
    $lignes = New-Object System.Collections.ArrayList
    foreach ($cfg in @(Get-Configs)) {
        $mes = @(Get-MesuresConfig $cfg)
        $tri = [double]::MaxValue
        $tri2 = [double]::MaxValue
        $txtAct = ''; $txtMem = ''; $txtRam = ''; $txtCpu = ''
        if ($mes.Count -gt 0) {
            $moyAct = [math]::Round(($mes | Measure-Object -Property ServicesActifs -Average).Average)
            $moyMem = [math]::Round(($mes | Measure-Object -Property MemServicesMo -Average).Average)
            $moyRam = [math]::Round(($mes | Measure-Object -Property RamMo -Average).Average)
            $moyCpu = [math]::Round(($mes | Measure-Object -Property Cpu -Average).Average)
            $tri = [double]$moyMem
            $tri2 = [double]$moyAct
            $txtAct = [string]$moyAct
            $txtMem = '{0:N0}' -f $moyMem
            $txtRam = '{0:N1}' -f ($moyRam / 1024)
            $txtCpu = [string]$moyCpu
        }
        $svc = @($cfg.Services)
        $ecarts = @(Get-EcartsConfig $cfg).Count
        [void]$lignes.Add([pscustomobject]@{
            Cfg    = $cfg
            Nom    = [string]$cfg.Nom
            Tri    = $tri
            Tri2   = $tri2
            NbMes  = $mes.Count
            Ecarts = $ecarts
            Auto   = @($svc | Where-Object { $_.Cible -eq 'Auto' }).Count
            Manuel = @($svc | Where-Object { $_.Cible -eq 'Manual' }).Count
            Desact = @($svc | Where-Object { $_.Cible -eq 'Disabled' }).Count
            TxtAct = $txtAct
            TxtMem = $txtMem
            TxtRam = $txtRam
            TxtCpu = $txtCpu
        })
    }
    $gridCfg.Rows.Clear()
    $rang = 0
    foreach ($l in @($lignes | Sort-Object Tri, Tri2, Nom)) {
        $txtRang = '-'
        if ($l.NbMes -gt 0) { $rang++; $txtRang = [string]$rang }
        $etat = 'Active'
        if ($l.Ecarts -gt 0) { $etat = '{0} écart(s)' -f $l.Ecarts }
        $i = $gridCfg.Rows.Add($txtRang, $l.Nom, [string]$l.Cfg.Date, $etat, $l.Auto, $l.Manuel, $l.Desact, $l.NbMes, $l.TxtAct, $l.TxtMem, $l.TxtRam, $l.TxtCpu)
        $row = $gridCfg.Rows[$i]
        $row.Tag = $l.Cfg
        if ($l.Ecarts -eq 0) { $row.DefaultCellStyle.BackColor = $CouleursTag['ok'][0] }
    }
}

function Update-Suivi {
    $script:Ressources = Get-Ressources
    Update-LabelRessources
    if ($script:PremierPassage) {
        $script:PremierPassage = $false
        # Reprise de l'ancienne "configuration ideale" (version precedente de l'application)
        $fichierRepris = Join-Path $DirProfils 'config-ideale.json'
        if ((Test-Path -LiteralPath $FichierIdeal) -and -not (Test-Path -LiteralPath $fichierRepris)) {
            try {
                $ancienne = Get-Content -LiteralPath $FichierIdeal -Raw -Encoding UTF8 | ConvertFrom-Json
                $reprise = [pscustomobject]@{
                    Nom      = 'Configuration idéale'
                    Date     = [string]$ancienne.Date
                    Machine  = [string]$ancienne.Machine
                    Services = @($ancienne.Services)
                    Fichier  = $fichierRepris
                }
                Save-Config $reprise @()
            } catch { Write-Erreur 'Reprise configuration ideale' $_ }
        }
        if (@(Get-Configs).Count -eq 0 -and $script:Inventaire.Count -gt 0) {
            New-Config 'État de référence' (Join-Path $DirProfils 'config-reference.json')
        }
    }
    Add-MesuresConfigs
    Update-Configs
    try { Update-Diagnostic } catch { Write-Erreur 'Update-Diagnostic' $_ }
}

function Set-Mode([string]$nom, [string]$mode) {
    # $mode : Auto / Manual / Disabled. Retourne $null si OK, sinon le message d'erreur.
    $typePs = @{ 'Auto' = 'Automatic'; 'Manual' = 'Manual'; 'Disabled' = 'Disabled' }[$mode]
    $typeSc = @{ 'Auto' = 'auto'; 'Manual' = 'demand'; 'Disabled' = 'disabled' }[$mode]
    try {
        Set-Service -Name $nom -StartupType $typePs -ErrorAction Stop
        return $null
    } catch {
        $message = $_.Exception.Message
        try {
            $null = & sc.exe config $nom 'start=' $typeSc 2>&1
            if ($LASTEXITCODE -eq 0) { return $null }
        } catch { }
        return $message
    }
}

function Invoke-Changements($changements, [bool]$arreter, [string]$motif) {
    # $changements : objets { Name, Avant, Cible }
    [void](Save-Releve $motif $script:Inventaire)
    $ok = 0
    $echecs = New-Object System.Collections.ArrayList
    foreach ($c in $changements) {
        $script:ModifsInternes[[string]$c.Name] = $true
        $erreur = Set-Mode $c.Name $c.Cible
        if ($erreur) {
            $resultat = 'ECHEC : ' + $erreur
            [void]$echecs.Add($c.Name)
        } else {
            $ok++
            $resultat = 'OK'
            $arreteOk = $false
            if ($arreter -and $c.Cible -ne 'Auto') {
                try { Stop-Service -Name $c.Name -ErrorAction Stop; $arreteOk = $true }
                catch { $resultat = 'OK (arrêt effectif au prochain redémarrage)' }
            }
            Register-ChangementReduction ([string]$c.Name) ([string]$c.Avant) ([string]$c.Cible) $arreteOk
        }
        [pscustomobject]@{
            Date     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            Motif    = $motif
            Service  = $c.Name
            Avant    = $c.Avant
            Apres    = $c.Cible
            Resultat = $resultat
        } | Export-Csv -LiteralPath $FichierJournal -Append -NoTypeInformation -Delimiter ';' -Encoding UTF8
    }
    $texte = "{0} service(s) modifié(s)." -f $ok
    if ($echecs.Count -gt 0) {
        $texte += "`r`n`r`n{0} refus (services protégés par Windows) :`r`n{1}" -f $echecs.Count, ($echecs -join ', ')
    }
    $texte += "`r`n`r`nL'état antérieur est sauvegardé (bouton « Restaurer un relevé »)."
    [void][System.Windows.Forms.MessageBox]::Show($texte, 'Service Minimum', 'OK', 'Information')
}

# ================================================================ SURVEILLANCE (version 1.1)
# Historique local des services actifs, des applications utilisees, des ports ouverts
# et des connexions etablies ; detection des anomalies de services.

$BasePortsTexte = @'
TCP|135|N|RPC de Windows (cœur du système) - ne pas fermer|
TCP|139|I|NetBIOS (ancien partage réseau) - inutile sur un réseau récent ; se ferme par le pare-feu|
UDP|137|I|NetBIOS (noms) - inutile sur un réseau récent ; se ferme par le pare-feu|
UDP|138|I|NetBIOS (datagrammes) - inutile sur un réseau récent ; se ferme par le pare-feu|
TCP|445|I|Partage de fichiers et d'imprimantes - utile seulement si CE poste partage des dossiers ou une imprimante (inutile pour accéder au serveur)|LanmanServer
TCP|3389|I|Bureau à distance - à fermer si la prise de main à distance ne sert pas|TermService
TCP|5985|I|Administration à distance (WinRM)|WinRM
TCP|5986|I|Administration à distance sécurisée (WinRM)|WinRM
TCP|5357|I|Découverte réseau (publication de ce poste auprès des autres)|FDResPub
UDP|3702|I|Découverte réseau (WS-Discovery)|FDResPub
UDP|1900|I|Découverte UPnP / SSDP|SSDPSRV
TCP|2869|I|UPnP|SSDPSRV
TCP|7680|I|Optimisation de la distribution (partage des mises à jour Windows entre postes)|DoSvc
UDP|5355|I|Résolution de noms locale (LLMNR)|
UDP|5353|S|Découverte locale mDNS (imprimantes, diffusion vers un écran)|
TCP|5040|S|Plateforme des appareils connectés (Windows)|
UDP|5050|S|Plateforme des appareils connectés (Windows)|
UDP|500|S|VPN / IPsec (IKE)|
UDP|4500|S|VPN / IPsec (NAT-T)|
UDP|123|S|Heure Windows (NTP)|
UDP|68|N|Client DHCP (obtention de l'adresse IP)|
UDP|546|N|Client DHCPv6 (obtention de l'adresse IP)|
TCP|1947|S|Gestionnaire de licences Sentinel (clé de protection de logiciels métier) - à garder si un logiciel protégé est utilisé|hasplms
UDP|1947|S|Gestionnaire de licences Sentinel (clé de protection de logiciels métier) - à garder si un logiciel protégé est utilisé|hasplms
UDP|2177|I|Qualité audio-vidéo Windows (qWave) - utile seulement pour la diffusion audio-vidéo sur le réseau local|QWAVE
TCP|2177|I|Qualité audio-vidéo Windows (qWave) - utile seulement pour la diffusion audio-vidéo sur le réseau local|QWAVE
UDP|41641|S|VPN Tailscale|
TCP|21|V|Serveur FTP - inhabituel sur un poste de travail|
TCP|22|V|Serveur SSH - inhabituel sur un poste de travail|
TCP|23|V|Telnet - à fermer|
TCP|25|V|Serveur de messagerie (SMTP) - inhabituel sur un poste de travail|
TCP|80|V|Serveur web - inhabituel sur un poste de travail|
TCP|443|V|Serveur web sécurisé - inhabituel sur un poste de travail|
TCP|1433|V|Base de données SQL Server|
TCP|3306|V|Base de données MySQL|
TCP|5432|V|Base de données PostgreSQL|
TCP|5900|V|Prise de main à distance (VNC)|
TCP|8080|V|Serveur web ou proxy|
'@
$BasePorts = @{}
foreach ($ligne in ($BasePortsTexte -split "`r?`n")) {
    if ([string]::IsNullOrWhiteSpace($ligne)) { continue }
    $p = $ligne.Split('|')
    $BasePorts[($p[0] + '|' + $p[1])] = [pscustomobject]@{ Code = $p[2]; Note = $p[3]; Service = $p[4] }
}
$LibelleAvis = @{ 'N' = 'Nécessaire'; 'S' = 'Normal'; 'I' = 'Non nécessaire'; 'V' = 'À vérifier' }
$NotesPortDistant = @{
    443 = 'Web sécurisé (https)'; 80 = 'Web (http)'; 8080 = 'Web (http)'; 8443 = 'Web sécurisé (https)'
    53 = 'Résolution de noms (DNS)'; 445 = 'Partage de fichiers'; 139 = 'Partage de fichiers (NetBIOS)'
    993 = 'Messagerie (réception)'; 995 = 'Messagerie (réception)'; 143 = 'Messagerie (réception)'
    587 = 'Messagerie (envoi)'; 465 = 'Messagerie (envoi)'; 25 = 'Messagerie (envoi)'
    3389 = 'Bureau à distance'; 22 = 'SSH'; 21 = 'FTP'; 123 = 'Heure'; 5228 = 'Notifications Google'
    1883 = 'Messagerie d''objets connectés (MQTT)'; 8883 = 'Messagerie d''objets connectés (MQTT)'
}
$ProcessusProteges = @('System', 'Idle', 'Registry', 'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass', 'svchost', 'dwm', 'fontdrvhost', 'explorer', 'MsMpEng')
$ProcessusHorsApplis = @('explorer', 'ApplicationFrameHost', 'TextInputHost', 'SystemSettings', 'ShellExperienceHost', 'SearchApp', 'SearchHost', 'StartMenuExperienceHost', 'LockApp', 'powershell', 'ServiceMinimum')

$script:Suivi = [pscustomobject]@{ Echantillons = 0; Debut = '' }
$script:HistoSvc = @{}
$script:HistoApps = @{}
$script:HistoPorts = @{}
$script:HistoCnx = @{}
$script:RacinesApps = @{}
$script:CatParNom = @{}
$script:ModifsInternes = @{}
$script:EcoutesPrec = $null
$script:LignesReseau = @()
$script:Anomalies = @()
$script:AnomaliesJournalisees = @{}
$script:AlertesVues = @{}
$script:InfoPid = @{}
$script:CpuPrec = @{}
$script:CpuDate = $null
$script:CnxSuivies = @{}
$script:OctetsPid = @{}
$script:PortsBloques = @{}
$script:StatsTcpDispo = $false
$script:Icone = $null
$script:VersZone = $false
$script:Quitter = $false
$script:InfoZoneDonnee = $false
$script:SuiviEnCours = $false
$script:InfoExe = @{}
$script:Approuves = @{}
$script:HabitudesCnx = @{}
$script:AnoParNom = @{}
$script:SuspectsSvc = @()
$PortsRisques = @(21, 23, 1080, 3128, 4444, 5900, 6667, 9001, 9050, 31337)

# Volumes envoyes / recus par connexion TCP (statistiques etendues de Windows, IPv4)
try {
    Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Runtime.InteropServices;
public static class SmTcpStats {
    [StructLayout(LayoutKind.Sequential)]
    public struct MIB_TCPROW {
        public uint dwState;
        public uint dwLocalAddr;
        public uint dwLocalPort;
        public uint dwRemoteAddr;
        public uint dwRemotePort;
    }
    [DllImport("iphlpapi.dll")]
    static extern uint SetPerTcpConnectionEStats(ref MIB_TCPROW row, int type, byte[] rw, uint rwVersion, uint rwSize, uint offset);
    [DllImport("iphlpapi.dll")]
    static extern uint GetPerTcpConnectionEStats(ref MIB_TCPROW row, int type, IntPtr rw, uint rwVersion, uint rwSize, IntPtr ros, uint rosVersion, uint rosSize, byte[] rod, uint rodVersion, uint rodSize);
    static uint Port(int p) {
        return (uint)(((p & 0xFF) << 8) | ((p >> 8) & 0xFF));
    }
    static MIB_TCPROW Ligne(string adrLocale, int portLocal, string adrDistante, int portDistant) {
        MIB_TCPROW r = new MIB_TCPROW();
        r.dwState = 5;
        r.dwLocalAddr = BitConverter.ToUInt32(IPAddress.Parse(adrLocale).GetAddressBytes(), 0);
        r.dwRemoteAddr = BitConverter.ToUInt32(IPAddress.Parse(adrDistante).GetAddressBytes(), 0);
        r.dwLocalPort = Port(portLocal);
        r.dwRemotePort = Port(portDistant);
        return r;
    }
    public static uint Activer(string adrLocale, int portLocal, string adrDistante, int portDistant) {
        MIB_TCPROW r = Ligne(adrLocale, portLocal, adrDistante, portDistant);
        byte[] rw = new byte[] { 1 };
        return SetPerTcpConnectionEStats(ref r, 1, rw, 0, 1, 0);
    }
    public static long[] Lire(string adrLocale, int portLocal, string adrDistante, int portDistant) {
        MIB_TCPROW r = Ligne(adrLocale, portLocal, adrDistante, portDistant);
        byte[] rod = new byte[96];
        uint e = GetPerTcpConnectionEStats(ref r, 1, IntPtr.Zero, 0, 0, IntPtr.Zero, 0, 0, rod, 0, 96);
        if (e != 0) { return null; }
        return new long[] { BitConverter.ToInt64(rod, 0), BitConverter.ToInt64(rod, 16) };
    }
}
'@
    $script:StatsTcpDispo = $true
} catch {
    Write-Demarrage ('statistiques TCP indisponibles : ' + $_.Exception.Message)
}

function Import-Table([string]$fichier, [string]$champCle) {
    $t = @{}
    if (Test-Path -LiteralPath $fichier) {
        try {
            foreach ($l in @(Import-Csv -LiteralPath $fichier -Delimiter ';' -Encoding UTF8)) {
                $k = [string]$l.$champCle
                if ($k) { $t[$k] = $l }
            }
        } catch { Write-Erreur ('Lecture ' + $fichier) $_ }
    }
    return $t
}

function Export-Table($table, [string]$fichier, [string]$tri) {
    $lignes = @($table.Values | Sort-Object $tri)
    if ($lignes.Count -eq 0) { return }
    $lignes | Export-Csv -LiteralPath $fichier -NoTypeInformation -Delimiter ';' -Encoding UTF8
}

function Initialize-Suivi {
    if (Test-Path -LiteralPath $FichierSuivi) {
        try {
            $x = Get-Content -LiteralPath $FichierSuivi -Raw -Encoding UTF8 | ConvertFrom-Json
            $script:Suivi.Echantillons = [int]$x.Echantillons
            $script:Suivi.Debut = [string]$x.Debut
        } catch { Write-Erreur 'Lecture suivi' $_ }
    }
    $script:HistoSvc = Import-Table $FichierHistoSvc 'Nom'
    $script:HistoApps = Import-Table $FichierHistoApps 'Nom'
    $script:HistoPorts = Import-Table $FichierHistoPorts 'Cle'
    $script:HistoCnx = Import-Table $FichierHistoCnx 'Cle'
    $script:HistoPer = Import-Table $FichierHistoPer 'Id'
    $script:HistoWifi = Import-Table $FichierHistoWifi 'Cle'
    $script:HistoDem = Import-Table $FichierHistoDem 'Cle'
    $script:Approuves = Import-Table $FichierApprouves 'Cle'
    $script:GeoCache = Import-Table $FichierGeo 'Cle'
    $script:HabitudesCnx = @{}
    foreach ($h in @($script:HistoCnx.Values)) { $script:HabitudesCnx[([string]$h.Processus + '|' + [string]$h.PortDistant)] = $true }
    Update-PortsBloques
}

function Save-Suivi {
    try {
        $script:Suivi | ConvertTo-Json | Set-Content -LiteralPath $FichierSuivi -Encoding UTF8
        Export-Table $script:HistoSvc $FichierHistoSvc 'Nom'
        Export-Table $script:HistoApps $FichierHistoApps 'Nom'
        Export-Table $script:HistoPorts $FichierHistoPorts 'Cle'
        if ($script:HistoCnx.Count -gt 3000) {
            # On ne garde que les 2500 destinations vues le plus recemment
            $garder = @($script:HistoCnx.Values | Sort-Object DerniereFois -Descending | Select-Object -First 2500)
            $script:HistoCnx = @{}
            foreach ($g in $garder) { $script:HistoCnx[[string]$g.Cle] = $g }
        }
        Export-Table $script:HistoCnx $FichierHistoCnx 'Cle'
    } catch { Write-Erreur 'Save-Suivi' $_ }
}

function Format-Octets([double]$n) {
    if ($n -lt 0) { return '' }
    if ($n -ge 1073741824) { return ('{0:N1} Go' -f ($n / 1073741824)) }
    if ($n -ge 1048576) { return ('{0:N1} Mo' -f ($n / 1048576)) }
    if ($n -ge 1024) { return ('{0:N0} Ko' -f ($n / 1024)) }
    return ('{0:N0} o' -f $n)
}

function Get-NomStable([string]$nom) {
    # Les services "par utilisateur" changent de suffixe a chaque session : on le neutralise
    if ($nom -match '^(.+)_[0-9a-f]{4,8}$') { return ($matches[1] + '_*') }
    return $nom
}

function Get-PorteeAdresse([string]$ip) {
    if ($ip -eq '::1' -or $ip -like '127.*') { return 'Interne au PC' }
    if ($ip -like '10.*' -or $ip -like '192.168.*' -or $ip -like '169.254.*' -or $ip -match '^172\.(1[6-9]|2[0-9]|3[01])\.' -or $ip -like 'fe80:*' -or $ip -like 'fd*:*' -or $ip -like 'fc*:*') { return 'Réseau local' }
    return 'Internet'
}

$script:BasesInstall = @()
foreach ($b in @(($env:LOCALAPPDATA + '\Programs'), $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:LOCALAPPDATA, $env:APPDATA)) {
    if ($b) { $script:BasesInstall += ([string]$b).ToLower().TrimEnd('\') }
}
function Get-RacineInstall([string]$chemin) {
    # Dossier d'installation d'un logiciel : premier dossier sous Program Files, ProgramData, AppData...
    if ([string]::IsNullOrWhiteSpace($chemin)) { return '' }
    $c = $chemin.ToLower()
    foreach ($base in $script:BasesInstall) {
        if ($c.StartsWith($base + '\')) {
            $reste = $c.Substring($base.Length + 1)
            $i = $reste.IndexOf('\')
            if ($i -le 0) { return '' }
            $premier = $reste.Substring(0, $i)
            if (@('common files', 'windowsapps', 'packages', 'microsoft', 'temp') -contains $premier) { return '' }
            return ($base + '\' + $premier)
        }
    }
    return ''
}

function Get-InfoExe([string]$chemin) {
    # Emplacement, editeur et signature d'un executable (resultat garde en memoire)
    if ([string]::IsNullOrWhiteSpace($chemin)) { return $null }
    $k = $chemin.ToLower()
    if ($script:InfoExe.ContainsKey($k)) { return $script:InfoExe[$k] }
    $info = [pscustomobject]@{ Chemin = $chemin; Existe = $false; Windows = $false; Programmes = $false; Signe = $false; Editeur = '' }
    try {
        if (Test-Path -LiteralPath $chemin) {
            $info.Existe = $true
            if ($k.StartsWith(([string]$env:windir).ToLower() + '\')) { $info.Windows = $true }
            foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
                if ($pf -and $k.StartsWith(([string]$pf).ToLower() + '\')) { $info.Programmes = $true }
            }
            try { $info.Editeur = [string](Get-Item -LiteralPath $chemin).VersionInfo.CompanyName } catch { }
            if ($info.Windows) {
                $info.Signe = $true
            } else {
                try {
                    $signature = Get-AuthenticodeSignature -LiteralPath $chemin -ErrorAction Stop
                    if ([string]$signature.Status -eq 'Valid') { $info.Signe = $true }
                } catch { }
            }
        }
    } catch { }
    $script:InfoExe[$k] = $info
    return $info
}

function New-Etat([string]$etat, [string]$motif) {
    return [pscustomobject]@{ Etat = $etat; Motif = $motif }
}

function Get-EtatService($s) {
    # Classement Habituel / Inhabituel / Suspect d'un service
    $nomReel = [string]$s.Name
    if ($script:Approuves.ContainsKey('svc|' + $nomReel)) { return (New-Etat 'Habituel' 'Déclaré habituel par l''utilisateur') }
    $cat = [string]$s.Cat
    if ($cat -ne 'E' -and $cat -ne 'G' -and $cat -ne 'U') {
        $exe = [Environment]::ExpandEnvironmentVariables((Get-CheminExe ([string]$s.Chemin)))
        $info = Get-InfoExe $exe
        if ($info -and $info.Existe -and -not $info.Windows -and -not $info.Signe) {
            if (-not $info.Programmes) { return (New-Etat 'Suspect' ('Exécutable non signé installé hors des dossiers de programmes : ' + $exe)) }
            $idp = [int]$s.ProcId
            if ($s.State -eq 'Running' -and $idp -gt 0) {
                $nbNet = @($script:LignesReseau | Where-Object { $_.Type -eq 'Connexion' -and [int]$_.IdProc -eq $idp -and $_.Portee -eq 'Internet' }).Count
                if ($nbNet -gt 0) { return (New-Etat 'Suspect' ('Exécutable non signé qui communique sur Internet : ' + $exe)) }
            }
        }
    }
    $ano = $null
    if ($script:AnoParNom.ContainsKey($nomReel)) { $ano = $script:AnoParNom[$nomReel] }
    if ($ano -and ([string]$ano.Cle -like 'envoi|*' -or [string]$ano.Cle -like 'netinutile|*')) { return (New-Etat 'Suspect' ([string]$ano.Anomalie)) }
    if ([int]$script:Suivi.Echantillons -lt 12) { return (New-Etat 'Apprentissage' 'Moins d''une heure de relevés : pas encore d''habitude établie') }
    if ($ano) { return (New-Etat 'Inhabituel' ([string]$ano.Anomalie)) }
    $nom = Get-NomStable $nomReel
    if ($script:HistoSvc.ContainsKey($nom)) {
        $h = $script:HistoSvc[$nom]
        $obs = [int]$h.Observations
        if ($obs -ge 12) {
            $pct = [int][math]::Round(100 * [int]$h.Actif / $obs)
            if ($s.State -eq 'Running' -and $pct -lt 10) { return (New-Etat 'Inhabituel' ('Actif alors qu''il ne l''est presque jamais ({0} % des relevés)' -f $pct)) }
            if ($s.State -ne 'Running' -and $pct -gt 90) { return (New-Etat 'Inhabituel' ('Arrêté alors qu''il est presque toujours actif ({0} % des relevés)' -f $pct)) }
            return (New-Etat 'Habituel' ('Conforme à l''historique (actif dans {0} % des relevés)' -f $pct))
        }
        return (New-Etat 'Inhabituel' 'Service apparu récemment dans l''historique')
    }
    return (New-Etat 'Habituel' '')
}

function Set-EtatLigne($l, [bool]$nouveau, [int]$pct, [int]$total) {
    # Classement Habituel / Inhabituel / Suspect d'un port en ecoute ou d'une connexion
    $cleApprouve = 'port|' + [string]$l.Cle
    if ($l.Type -eq 'Connexion') { $cleApprouve = 'cnx|' + [string]$l.Processus }
    if ($script:Approuves.ContainsKey($cleApprouve)) { $l.Etat = 'Habituel'; $l.Motif = 'Déclaré habituel par l''utilisateur'; return }
    $confiance = $true
    $info = Get-InfoExe ([string]$l.CheminExe)
    if ($info -and $info.Existe -and -not $info.Windows -and -not $info.Signe) { $confiance = $false }
    if ($l.Type -eq 'Écoute') {
        if ($l.Portee -eq 'Ouvert au réseau') {
            if ($l.Processus -eq '(terminé)') { $l.Etat = 'Suspect'; $l.Motif = 'Port ouvert au réseau par un programme introuvable'; return }
            if ($PortsRisques -contains [int]$l.Port) { $l.Etat = 'Suspect'; $l.Motif = 'Port à risque ouvert au réseau'; return }
            if (-not $confiance) { $l.Etat = 'Suspect'; $l.Motif = 'Programme non signé qui ouvre un port au réseau'; return }
        }
        if ($total -lt 12) { $l.Etat = 'Apprentissage'; $l.Motif = 'Moins d''une heure de relevés'; return }
        if ($nouveau) { $l.Etat = 'Inhabituel'; $l.Motif = 'Port jamais vu auparavant'; return }
        if ($pct -lt 10) { $l.Etat = 'Inhabituel'; $l.Motif = ('Port rarement ouvert ({0} % des relevés)' -f $pct); return }
        $l.Etat = 'Habituel'; $l.Motif = ''
        return
    }
    if ($l.Portee -eq 'Interne au PC') { $l.Etat = 'Habituel'; $l.Motif = ''; return }
    if ($PortsRisques -contains [int]$l.PortDistant) { $l.Etat = 'Suspect'; $l.Motif = 'Connexion vers un port distant à risque'; return }
    if (-not $confiance -and $l.Portee -eq 'Internet') { $l.Etat = 'Suspect'; $l.Motif = 'Programme non signé qui communique sur Internet'; return }
    if ($total -lt 12) { $l.Etat = 'Apprentissage'; $l.Motif = 'Moins d''une heure de relevés'; return }
    if ($nouveau) { $l.Etat = 'Inhabituel'; $l.Motif = 'Ce programme n''avait jamais utilisé ce type de connexion'; return }
    $l.Etat = 'Habituel'; $l.Motif = ''
}

function Set-Approuve([string]$cle, [string]$libelle) {
    # Bascule : declare un element habituel, ou annule cette declaration. Retourne $true s'il est desormais approuve.
    $approuve = $true
    if ($script:Approuves.ContainsKey($cle)) {
        $script:Approuves.Remove($cle)
        $approuve = $false
    } else {
        $script:Approuves[$cle] = [pscustomobject]@{ Cle = $cle; Libelle = $libelle; Date = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }
    }
    try {
        if ($script:Approuves.Count -gt 0) { Export-Table $script:Approuves $FichierApprouves 'Cle' }
        elseif (Test-Path -LiteralPath $FichierApprouves) { Remove-Item -LiteralPath $FichierApprouves }
    } catch { Write-Erreur 'Elements approuves' $_ }
    return $approuve
}

function Get-ServicesLegers {
    $proprietes = @('Name', 'DisplayName', 'ProcessId', 'State', 'StartMode', 'ExitCode')
    return @(Get-CimInstance -ClassName Win32_Service -Property $proprietes)
}

function Add-Anomalie($liste, [string]$gravite, [string]$service, [string]$nom, [string]$anomalie, [int]$idp, [string]$conseil, [string]$cle) {
    [void]$liste.Add([pscustomobject]@{ Gravite = $gravite; Service = $service; Nom = $nom; Anomalie = $anomalie; IdProc = $idp; Conso = ''; Reseau = ''; Conseil = $conseil; Cle = $cle })
}

function Update-HistoServices($svcs, [string]$maintenant, $anos) {
    $premier = ($script:HistoSvc.Count -eq 0)
    $total = [int]$script:Suivi.Echantillons
    $vus = @{}
    foreach ($s in $svcs) {
        $nomReel = [string]$s.Name
        $nom = Get-NomStable $nomReel
        if ($vus.ContainsKey($nom)) { continue }
        $vus[$nom] = $true
        $actif = ($s.State -eq 'Running')
        $mode = [string]$s.StartMode
        $idp = [int]$s.ProcessId
        if ($script:HistoSvc.ContainsKey($nom)) {
            $h = $script:HistoSvc[$nom]
            $ancien = [string]$h.Demarrage
            # « Unknown » : Windows n'a pas donne le mode (service protege) ; ce n'est pas un changement
            if ($mode -eq 'Unknown') { $mode = $ancien }
            if ($ancien -and $mode -and $ancien -ne 'Unknown' -and $ancien -ne $mode -and -not $script:ModifsInternes.ContainsKey($nomReel)) {
                Add-Anomalie $anos 'Moyenne' ([string]$s.DisplayName) $nomReel ('Mode de démarrage modifié en dehors de Service Minimum : {0} -> {1}' -f $ancien, $mode) $idp 'Si ce changement n''est pas voulu (mise à jour, installation d''un logiciel), remettre le mode souhaité dans la liste du haut.' ('mode|{0}|{1}' -f $nomReel, $mode)
            }
            $obs = [int]$h.Observations
            $nbActif = [int]$h.Actif
            if ($actif -and $obs -ge 24 -and $nbActif -lt ($obs * 0.1)) {
                Add-Anomalie $anos 'Faible' ([string]$s.DisplayName) $nomReel ('Service actif alors qu''il ne l''est presque jamais ({0} relevé(s) sur {1})' -f $nbActif, $obs) $idp 'Vérifier ce qui l''a démarré (logiciel ouvert, mise à jour). S''il ne sert pas, l''arrêter.' ('rare|{0}|{1}' -f $nomReel, (Get-Date -Format 'yyyyMMdd'))
            }
            $h.Demarrage = $mode
            $h.Service = [string]$s.DisplayName
            $h.Observations = [string]($obs + 1)
            if ($actif) { $h.Actif = [string]($nbActif + 1); $h.DernierActif = $maintenant }
        } else {
            $dernier = ''
            $nb = '0'
            if ($actif) { $dernier = $maintenant; $nb = '1' }
            $script:HistoSvc[$nom] = [pscustomobject]@{ Nom = $nom; Service = [string]$s.DisplayName; Demarrage = $mode; Observations = '1'; Actif = $nb; PremiereFois = $maintenant; DernierActif = $dernier }
            if (-not $premier -and $nom -eq $nomReel) {
                Add-Anomalie $anos 'Moyenne' ([string]$s.DisplayName) $nomReel 'Nouveau service apparu sur le poste' $idp 'Normal après l''installation d''un logiciel ou une mise à jour ; sinon, vérifier son origine avant de le laisser actif.' ('nouveau|' + $nomReel)
            }
        }
        if ($mode -eq 'Auto' -and $s.State -eq 'Stopped') {
            $code = 0
            try { $code = [int]$s.ExitCode } catch { $code = 0 }
            if ($code -ne 0 -and $code -ne 1077) {
                Add-Anomalie $anos 'Moyenne' ([string]$s.DisplayName) $nomReel ('Service à démarrage automatique arrêté sur erreur (code {0})' -f $code) 0 'S''il sert, le redémarrer ; s''il ne sert pas, le passer en Manuel pour supprimer l''erreur à chaque démarrage.' ('erreur|{0}|{1}' -f $nomReel, $code)
            }
        }
    }
    $script:ModifsInternes = @{}
}

function Update-HistoApplications($procs, [string]$maintenant) {
    $vus = @{}
    foreach ($p in $procs) {
        $titre = ''
        try { $titre = [string]$p.MainWindowTitle } catch { $titre = '' }
        if (-not $titre) { continue }
        $nom = [string]$p.ProcessName
        if ($vus.ContainsKey($nom)) { continue }
        if ($ProcessusHorsApplis -contains $nom) { continue }
        if ([int]$p.Id -eq $PID) { continue }
        $vus[$nom] = $true
        if ($script:HistoApps.ContainsKey($nom)) {
            $h = $script:HistoApps[$nom]
            $h.Observations = [string]([int]$h.Observations + 1)
            $h.DerniereFois = $maintenant
        } else {
            $chemin = ''; $produit = ''; $editeur = ''
            try {
                $module = $p.MainModule
                $chemin = [string]$module.FileName
                $produit = [string]$module.FileVersionInfo.FileDescription
                if (-not $produit) { $produit = [string]$module.FileVersionInfo.ProductName }
                $editeur = [string]$module.FileVersionInfo.CompanyName
            } catch { }
            $script:HistoApps[$nom] = [pscustomobject]@{ Nom = $nom; Produit = $produit; Editeur = $editeur; Chemin = $chemin; Racine = (Get-RacineInstall $chemin); Observations = '1'; PremiereFois = $maintenant; DerniereFois = $maintenant }
        }
    }
}

function Update-InfoPid($procs, $svcParPid) {
    # Memoire et charge processeur (moyenne depuis le releve precedent) de chaque processus
    $info = @{}
    $nouveau = @{}
    $date = Get-Date
    $duree = 0
    if ($script:CpuDate) { $duree = ($date - $script:CpuDate).TotalSeconds }
    $coeurs = [Environment]::ProcessorCount
    if ($coeurs -lt 1) { $coeurs = 1 }
    foreach ($p in $procs) {
        $id = [int]$p.Id
        $mem = 0
        try { $mem = [int][math]::Round($p.WorkingSet64 / 1048576) } catch { $mem = 0 }
        $cpu = [double]-1
        try {
            $t = [double]$p.TotalProcessorTime.TotalSeconds
            $nouveau[$id] = $t
            if ($duree -gt 2 -and $script:CpuPrec.ContainsKey($id)) {
                $cpu = [math]::Round(100 * ($t - $script:CpuPrec[$id]) / $duree / $coeurs, 1)
                if ($cpu -lt 0) { $cpu = [double]0 }
            }
        } catch { }
        $nb = 0
        if ($svcParPid.ContainsKey($id)) { $nb = $svcParPid[$id].Count }
        $info[$id] = [pscustomobject]@{ MemMo = $mem; Cpu = $cpu; NbServices = $nb }
    }
    $script:CpuPrec = $nouveau
    $script:CpuDate = $date
    $script:InfoPid = $info
}

function New-LigneReseau([string]$type, [string]$proto, [string]$adresse, [int]$port, [int]$idp, $procParId, $svcParPid) {
    $nomProc = '(terminé)'
    if ($idp -eq 4) { $nomProc = 'System' }
    elseif ($idp -eq 0) { $nomProc = 'Idle' }
    elseif ($procParId.ContainsKey($idp)) { $nomProc = [string]$procParId[$idp].ProcessName }
    $cheminExe = ''
    if ($idp -gt 4 -and $procParId.ContainsKey($idp)) {
        try { $cheminExe = [string]$procParId[$idp].Path } catch { $cheminExe = '' }
    }
    $noms = New-Object System.Collections.ArrayList
    $affiches = New-Object System.Collections.ArrayList
    if ($svcParPid.ContainsKey($idp)) {
        foreach ($s in $svcParPid[$idp]) {
            [void]$noms.Add([string]$s.Name)
            [void]$affiches.Add([string]$s.DisplayName)
        }
    }
    return [pscustomobject]@{
        Type = $type; Proto = $proto; AdresseLocale = $adresse; Port = $port; PortTexte = [string]$port; Nb = 1
        AdresseDistante = ''; PortDistant = 0; IdProc = $idp; Processus = $nomProc
        NomsServices = $noms; Services = ($affiches.ToArray() -join ', ')
        Portee = ''; Avis = ''; Note = ''; Habitude = ''; Etat = ''; Motif = ''; CheminExe = $cheminExe; Envoye = [double]-1; Recu = [double]-1; Cle = ''
    }
}

function Add-Ecoute($ecoutes, [string]$proto, [string]$adresse, [int]$port, [int]$idp, $procParId, $svcParPid) {
    # Les ports UDP temporaires (>= 49152) d'un meme processus sont regroupes sur une seule ligne
    $temporaire = ($proto -eq 'UDP' -and $port -ge 49152)
    if ($temporaire) { $k = 'UDP|tmp|{0}' -f $idp } else { $k = '{0}|{1}|{2}' -f $proto, $port, $idp }
    if ($ecoutes.ContainsKey($k)) {
        $e = $ecoutes[$k]
        if ($temporaire) { $e.Nb = [int]$e.Nb + 1 }
        if (@($e.AdresseLocale -split ';') -notcontains $adresse) { $e.AdresseLocale = $e.AdresseLocale + ';' + $adresse }
    } else {
        $e = New-LigneReseau 'Écoute' $proto $adresse $port $idp $procParId $svcParPid
        if ($temporaire) { $e.Port = 0 }
        $ecoutes[$k] = $e
    }
}

function Get-AvisPort([string]$proto, [int]$port, [bool]$ouvert, [string]$procNom) {
    if ($port -eq 0) {
        return [pscustomobject]@{ Avis = 'Normal'; Note = 'Ports temporaires servant aux échanges sortants du programme (pas de service à l''écoute)' }
    }
    $k = $proto + '|' + $port
    if ($BasePorts.ContainsKey($k)) {
        $b = $BasePorts[$k]
        $avis = $LibelleAvis[$b.Code]
        $note = [string]$b.Note
        if (-not $ouvert -and ($b.Code -eq 'I' -or $b.Code -eq 'V')) { $avis = 'Normal'; $note += ' - accessible seulement depuis ce PC' }
        return [pscustomobject]@{ Avis = $avis; Note = $note }
    }
    if (-not $ouvert) {
        return [pscustomobject]@{ Avis = 'Normal'; Note = ('Service interne de {0} - accessible seulement depuis ce PC' -f $procNom) }
    }
    $systeme = (@('System', 'lsass', 'wininit', 'services', 'svchost', 'spoolsv') -contains $procNom)
    if ($port -ge 49152) {
        if ($systeme) { return [pscustomobject]@{ Avis = 'Normal'; Note = 'Port dynamique de Windows (RPC)' } }
        return [pscustomobject]@{ Avis = 'À vérifier'; Note = ('Port ouvert au réseau par {0} - non répertorié' -f $procNom) }
    }
    if ($systeme) { return [pscustomobject]@{ Avis = 'À vérifier'; Note = 'Port ouvert au réseau par Windows - non répertorié' } }
    return [pscustomobject]@{ Avis = 'À vérifier'; Note = ('Port ouvert au réseau par {0} - non répertorié' -f $procNom) }
}

function Add-StatsCnx($l, $vues) {
    if (-not $script:StatsTcpDispo) { return }
    if ($l.AdresseLocale -notmatch '^\d+\.\d+\.\d+\.\d+$' -or $l.AdresseDistante -notmatch '^\d+\.\d+\.\d+\.\d+$') { return }
    $k = '{0}:{1}>{2}:{3}' -f $l.AdresseLocale, $l.Port, $l.AdresseDistante, $l.PortDistant
    $vues[$k] = $true
    try {
        $maintenant = [DateTime]::UtcNow.Ticks
        $nouvelle = $false
        if (-not $script:CnxSuivies.ContainsKey($k)) {
            [void][SmTcpStats]::Activer($l.AdresseLocale, $l.Port, $l.AdresseDistante, $l.PortDistant)
            $nouvelle = $true
        }
        $v = [SmTcpStats]::Lire($l.AdresseLocale, $l.Port, $l.AdresseDistante, $l.PortDistant)
        # Windows renvoie parfois des compteurs incoherents : on ecarte les valeurs impossibles
        if ($null -ne $v -and [double]$v[0] -ge 0 -and [double]$v[1] -ge 0 -and [double]$v[0] -lt 1e12 -and [double]$v[1] -lt 1e12) {
            if ($nouvelle) {
                # Premiere lecture : sert de point de depart, rien n'est compte
                $script:CnxSuivies[$k] = @([double]$v[0], [double]$v[1], $maintenant)
            } else {
                $prec = $script:CnxSuivies[$k]
                $secondes = [math]::Max(1, ($maintenant - [double]$prec[2]) / 1e7)
                $plafond = 1.25e9 * $secondes + 1e8
                $sortie = [double]$v[0] - [double]$prec[0]
                $entree = [double]$v[1] - [double]$prec[1]
                if ($sortie -lt 0 -or $sortie -gt $plafond) { $sortie = 0 }
                if ($entree -lt 0 -or $entree -gt $plafond) { $entree = 0 }
                $script:CnxSuivies[$k] = @([double]$v[0], [double]$v[1], $maintenant)
                $id = [int]$l.IdProc
                if (-not $script:OctetsPid.ContainsKey($id)) { $script:OctetsPid[$id] = @([double]0, [double]0) }
                $t = $script:OctetsPid[$id]
                $script:OctetsPid[$id] = @(([double]$t[0] + $sortie), ([double]$t[1] + $entree))
            }
            $l.Envoye = [double]$v[0]
            $l.Recu = [double]$v[1]
        } elseif ($nouvelle) {
            $script:CnxSuivies[$k] = @([double]0, [double]0, $maintenant)
        }
    } catch {
        $script:StatsTcpDispo = $false
        Write-Erreur 'Statistiques TCP' $_
    }
}

function Get-Reseau($procParId, $svcParPid) {
    $ecoutes = @{}
    $vues = @{}
    $lignes = New-Object System.Collections.ArrayList
    $tcp = @()
    $udp = @()
    try { $tcp = @(Get-NetTCPConnection -ErrorAction Stop) } catch { Write-Erreur 'Get-NetTCPConnection' $_ }
    try { $udp = @(Get-NetUDPEndpoint -ErrorAction Stop) } catch { Write-Erreur 'Get-NetUDPEndpoint' $_ }
    foreach ($c in $tcp) {
        $etat = [string]$c.State
        $idp = [int]$c.OwningProcess
        if ($etat -eq 'Listen') {
            Add-Ecoute $ecoutes 'TCP' ([string]$c.LocalAddress) ([int]$c.LocalPort) $idp $procParId $svcParPid
        } elseif ($etat -eq 'Established') {
            $l = New-LigneReseau 'Connexion' 'TCP' ([string]$c.LocalAddress) ([int]$c.LocalPort) $idp $procParId $svcParPid
            $l.AdresseDistante = [string]$c.RemoteAddress
            $l.PortDistant = [int]$c.RemotePort
            $l.Portee = Get-PorteeAdresse $l.AdresseDistante
            if ($NotesPortDistant.ContainsKey([int]$l.PortDistant)) { $l.Note = $NotesPortDistant[[int]$l.PortDistant] }
            $l.Cle = '{0}|{1}|{2}' -f $l.Processus, $l.AdresseDistante, $l.PortDistant
            if ($l.Portee -ne 'Interne au PC') { Add-StatsCnx $l $vues }
            [void]$lignes.Add($l)
        }
    }
    foreach ($u in $udp) {
        Add-Ecoute $ecoutes 'UDP' ([string]$u.LocalAddress) ([int]$u.LocalPort) ([int]$u.OwningProcess) $procParId $svcParPid
    }
    foreach ($k in @($script:CnxSuivies.Keys)) {
        if (-not $vues.ContainsKey($k)) { $script:CnxSuivies.Remove($k) }
    }
    foreach ($e in $ecoutes.Values) {
        $ouvert = $false
        foreach ($a in @($e.AdresseLocale -split ';')) {
            if ((Get-PorteeAdresse $a) -ne 'Interne au PC') { $ouvert = $true }
        }
        if ($ouvert) { $e.Portee = 'Ouvert au réseau' } else { $e.Portee = 'Interne au PC' }
        if ([int]$e.Port -eq 0) { $e.PortTexte = 'temporaires ({0})' -f $e.Nb }
        $av = Get-AvisPort $e.Proto ([int]$e.Port) $ouvert $e.Processus
        $e.Avis = $av.Avis
        $e.Note = $av.Note
        if ($script:PortsBloques.ContainsKey(($e.Proto + '|' + $e.Port))) {
            $e.Avis = 'Bloqué (pare-feu)'
            $e.Note = 'Entrées bloquées par une règle Service Minimum - ' + $e.Note
        }
        $nomsSvc = ($e.NomsServices.ToArray() -join ',')
        if ([int]$e.Port -eq 0 -or [int]$e.Port -ge 49152) { $e.Cle = '{0}|dyn|{1}|{2}' -f $e.Proto, $e.Processus, $nomsSvc }
        else { $e.Cle = '{0}|{1}|{2}' -f $e.Proto, $e.Port, $e.Processus }
        $e.AdresseLocale = ($e.AdresseLocale -replace ';', ', ')
        [void]$lignes.Add($e)
    }
    return $lignes.ToArray()
}

function Write-JournalPorts([string]$evenement, $l, [string]$detail) {
    try {
        [pscustomobject]@{
            Date      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            Evenement = $evenement
            Proto     = [string]$l.Proto
            Port      = [string]$l.PortTexte
            Adresse   = [string]$l.AdresseLocale
            Processus = [string]$l.Processus
            IdProc    = [string]$l.IdProc
            Services  = [string]$l.Services
            Detail    = $detail
        } | Export-Csv -LiteralPath $FichierJournalPorts -Append -NoTypeInformation -Delimiter ';' -Encoding UTF8
    } catch { Write-Erreur 'Journal des ports' $_ }
}

function Update-HistoReseau($lignes, [string]$maintenant) {
    $total = [int]$script:Suivi.Echantillons
    $histoVide = ($script:HistoPorts.Count -eq 0)
    $actuelles = @{}
    $vus = @{}
    foreach ($l in $lignes) {
        if ($l.Type -eq 'Écoute') {
            $k = [string]$l.Cle
            $nouveau = $false
            $obs = 1
            if (-not $vus.ContainsKey($k)) {
                $vus[$k] = $true
                if ($script:HistoPorts.ContainsKey($k)) {
                    $h = $script:HistoPorts[$k]
                    $obs = [int]$h.Observations + 1
                    $h.Observations = [string]$obs
                    $h.DerniereFois = $maintenant
                    $h.Adresses = [string]$l.AdresseLocale
                } else {
                    $nouveau = $true
                    $script:HistoPorts[$k] = [pscustomobject]@{ Cle = $k; Proto = [string]$l.Proto; Port = [string]$l.PortTexte; Processus = [string]$l.Processus; Services = [string]$l.Services; Adresses = [string]$l.AdresseLocale; Avis = [string]$l.Avis; Observations = '1'; PremiereFois = $maintenant; DerniereFois = $maintenant }
                }
            } elseif ($script:HistoPorts.ContainsKey($k)) {
                $obs = [int]$script:HistoPorts[$k].Observations
            }
            $pct = 100
            if ($total -gt 0) { $pct = [int][math]::Round(100 * $obs / $total) }
            if ($pct -gt 100) { $pct = 100 }
            if ($total -lt 12) { $l.Habitude = 'Apprentissage' }
            elseif ($nouveau) { $l.Habitude = 'Nouveau' }
            elseif ($pct -lt 10) { $l.Habitude = '{0} % des relevés' -f $pct }
            else { $l.Habitude = '{0} % des relevés' -f $pct }
            Set-EtatLigne $l $nouveau $pct $total
            # Journal : ports TCP et ports UDP fixes uniquement (les ports temporaires changent sans cesse)
            if ([int]$l.Port -gt 0 -and ($l.Proto -eq 'TCP' -or [int]$l.Port -lt 49152)) {
                $cleJournal = '{0}|{1}|{2}' -f $l.Proto, $l.Port, $l.Processus
                if (-not $actuelles.ContainsKey($cleJournal)) {
                    $actuelles[$cleJournal] = $l
                    if ($null -ne $script:EcoutesPrec) {
                        if (-not $script:EcoutesPrec.ContainsKey($cleJournal)) { Write-JournalPorts 'Ouvert' $l ([string]$l.Avis) }
                    } elseif ($nouveau -and -not $histoVide) {
                        Write-JournalPorts 'Nouveau (jamais vu)' $l ([string]$l.Avis)
                    } elseif ($histoVide) {
                        Write-JournalPorts 'État initial' $l ([string]$l.Avis)
                    }
                }
            }
        } elseif ($l.Portee -ne 'Interne au PC') {
            $k = [string]$l.Cle
            $cleHabitude = ([string]$l.Processus + '|' + [string]$l.PortDistant)
            if (-not $vus.ContainsKey('h|' + $cleHabitude)) { $vus['h|' + $cleHabitude] = (-not $script:HabitudesCnx.ContainsKey($cleHabitude)) }
            Set-EtatLigne $l ([bool]$vus['h|' + $cleHabitude]) 100 $total
            if ($vus.ContainsKey('c|' + $k)) { continue }
            $vus['c|' + $k] = $true
            if ($script:HistoCnx.ContainsKey($k)) {
                $h = $script:HistoCnx[$k]
                $h.Observations = [string]([int]$h.Observations + 1)
                $h.DerniereFois = $maintenant
                $l.Habitude = 'Déjà vue ({0} fois)' -f $h.Observations
            } else {
                $script:HistoCnx[$k] = [pscustomobject]@{ Cle = $k; Processus = [string]$l.Processus; Services = [string]$l.Services; AdresseDistante = [string]$l.AdresseDistante; PortDistant = [string]$l.PortDistant; Portee = [string]$l.Portee; Nature = [string]$l.Note; Observations = '1'; PremiereFois = $maintenant; DerniereFois = $maintenant }
                if ($total -lt 12) { $l.Habitude = 'Apprentissage' } else { $l.Habitude = 'Nouvelle destination' }
            }
        }
    }
    foreach ($l in $lignes) {
        if ($l.Type -eq 'Connexion') {
            if ($l.Portee -eq 'Interne au PC') { $l.Etat = 'Habituel' }
            else { $script:HabitudesCnx[([string]$l.Processus + '|' + [string]$l.PortDistant)] = $true }
        }
    }
    if ($null -ne $script:EcoutesPrec) {
        foreach ($k in @($script:EcoutesPrec.Keys)) {
            if (-not $actuelles.ContainsKey($k)) { Write-JournalPorts 'Fermé' $script:EcoutesPrec[$k] '' }
        }
    }
    $script:EcoutesPrec = $actuelles
}

function Get-TexteConso([int]$idp) {
    if ($idp -le 0 -or -not $script:InfoPid.ContainsKey($idp)) { return 'Arrêté - aucune consommation' }
    $i = $script:InfoPid[$idp]
    $t = '{0:N0} Mo de mémoire' -f $i.MemMo
    if ($i.Cpu -ge 0) { $t += ' ; processeur {0:N1} %' -f $i.Cpu }
    if ($i.NbServices -gt 1) { $t += (' (processus partagé par {0} services)' -f $i.NbServices) }
    return $t
}

function Get-TexteReseau([int]$idp) {
    if ($idp -le 0) { return 'Aucun échange réseau' }
    $cnx = @($script:LignesReseau | Where-Object { $_.Type -eq 'Connexion' -and [int]$_.IdProc -eq $idp -and $_.Portee -ne 'Interne au PC' })
    $ecoutes = @($script:LignesReseau | Where-Object { $_.Type -eq 'Écoute' -and [int]$_.IdProc -eq $idp -and $_.Portee -eq 'Ouvert au réseau' -and [int]$_.Port -gt 0 })
    $parties = New-Object System.Collections.ArrayList
    if ($cnx.Count -gt 0) {
        $cibles = @($cnx | Select-Object -First 3 | ForEach-Object { '{0}:{1}' -f $_.AdresseDistante, $_.PortDistant })
        $t = '{0} connexion(s) établie(s) vers {1}' -f $cnx.Count, ($cibles -join ', ')
        if ($cnx.Count -gt 3) { $t += ', ...' }
        if (@($cnx | Where-Object { @(80, 443, 8080, 8443) -contains [int]$_.PortDistant }).Count -gt 0) { $t += ' (échanges web)' }
        [void]$parties.Add($t)
    }
    if ($script:OctetsPid.ContainsKey($idp)) {
        $o = $script:OctetsPid[$idp]
        if (([double]$o[0] + [double]$o[1]) -gt 0) {
            [void]$parties.Add(('envoyé {0}, téléchargé {1} depuis le début de la surveillance' -f (Format-Octets ([double]$o[0])), (Format-Octets ([double]$o[1]))))
        }
    }
    if ($ecoutes.Count -gt 0) {
        [void]$parties.Add(('en écoute sur le(s) port(s) {0}' -f ((@($ecoutes | ForEach-Object { '{0} {1}' -f $_.Proto, $_.Port }) | Select-Object -Unique) -join ', ')))
    }
    if ($parties.Count -eq 0) { return 'Aucun échange réseau au moment du relevé' }
    return ($parties.ToArray() -join ' ; ')
}

function Add-AnomaliesRessources($svcParPid, $anos) {
    foreach ($idp in @($svcParPid.Keys)) {
        $liste = @($svcParPid[$idp])
        $noms = @($liste | Select-Object -First 3 | ForEach-Object { [string]$_.DisplayName })
        $affiche = ($noms -join ', ')
        if ($liste.Count -gt 3) { $affiche += ', ...' }
        $nom = ''
        if ($liste.Count -eq 1) { $nom = [string]$liste[0].Name }
        $cats = @($liste | ForEach-Object { [string]$script:CatParNom[[string]$_.Name] })
        $toutEssentiel = (@($cats | Where-Object { $_ -ne 'E' }).Count -eq 0)
        $toutInutile = (@($cats | Where-Object { $_ -ne 'I' }).Count -eq 0)
        $jour = Get-Date -Format 'yyyyMMdd'
        if ($script:InfoPid.ContainsKey([int]$idp)) {
            $i = $script:InfoPid[[int]$idp]
            if ($i.MemMo -ge 500) {
                Add-Anomalie $anos 'Moyenne' $affiche $nom ('Consommation de mémoire élevée ({0:N0} Mo)' -f $i.MemMo) ([int]$idp) 'Si le service n''est pas indispensable, l''arrêter libère cette mémoire ; sinon surveiller si elle continue de croître (fuite).' ('mem|{0}|{1}' -f $affiche, $jour)
            }
            if ($i.Cpu -ge 25) {
                Add-Anomalie $anos 'Moyenne' $affiche $nom ('Charge processeur élevée ({0:N1} % en moyenne depuis le relevé précédent)' -f $i.Cpu) ([int]$idp) 'Normal pendant une analyse antivirus ou une mise à jour ; anormal si cela dure au repos.' ('cpu|{0}|{1}' -f $affiche, $jour)
            }
        }
        $cnxInternet = @($script:LignesReseau | Where-Object { $_.Type -eq 'Connexion' -and [int]$_.IdProc -eq [int]$idp -and $_.Portee -eq 'Internet' })
        if ($toutInutile -and $cnxInternet.Count -gt 0) {
            Add-Anomalie $anos 'Moyenne' $affiche $nom 'Service classé « inutile probable » qui communique sur Internet' ([int]$idp) 'Candidat à l''arrêt : il consomme du réseau pour une fonction qui ne sert pas.' ('netinutile|{0}|{1}' -f $affiche, $jour)
        }
        if ($script:OctetsPid.ContainsKey([int]$idp) -and -not $toutEssentiel) {
            $o = $script:OctetsPid[[int]$idp]
            if ([double]$o[0] -ge 20971520) {
                Add-Anomalie $anos 'Moyenne' $affiche $nom ('Envois importants vers l''extérieur ({0} envoyés)' -f (Format-Octets ([double]$o[0]))) ([int]$idp) 'Vérifier que cet envoi est attendu (sauvegarde, synchronisation, télémétrie). Les destinations figurent dans l''onglet « Ports et connexions ».' ('envoi|{0}|{1}' -f $affiche, $jour)
            }
            if ([double]$o[1] -ge 209715200) {
                Add-Anomalie $anos 'Faible' $affiche $nom ('Téléchargements importants ({0} reçus)' -f (Format-Octets ([double]$o[1]))) ([int]$idp) 'Le plus souvent une mise à jour ; à surveiller si cela se répète sans raison.' ('recu|{0}|{1}' -f $affiche, $jour)
            }
        }
    }
}

function Add-AnomaliesJournalWindows($svcs, $anos) {
    # Plantages et echecs de services releves par Windows sur les dernieres 24 heures
    $evts = @()
    try {
        $evts = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7000, 7001, 7009, 7011, 7023, 7024, 7031, 7034; StartTime = (Get-Date).AddHours(-24) } -MaxEvents 60 -ErrorAction Stop)
    } catch { $evts = @() }
    $groupes = @{}
    foreach ($e in $evts) {
        $svc = ''
        try { $svc = [string]$e.Properties[0].Value } catch { $svc = '' }
        if (-not $svc) { continue }
        $k = '{0}|{1}' -f $e.Id, $svc
        if ($groupes.ContainsKey($k)) { $groupes[$k].Nb = $groupes[$k].Nb + 1 }
        else { $groupes[$k] = [pscustomobject]@{ Id = [int]$e.Id; Service = $svc; Nb = 1; Dernier = $e.TimeCreated } }
    }
    foreach ($g in $groupes.Values) {
        $gravite = 'Moyenne'
        $libelle = 'Arrêté sur erreur'
        $conseil = 'S''il sert, le redémarrer et surveiller ; s''il ne sert pas, le passer en Manuel.'
        if ($g.Id -eq 7031 -or $g.Id -eq 7034) { $gravite = 'Élevée'; $libelle = 'Arrêt inattendu (plantage)'; $conseil = 'Un service qui plante de façon répétée signale un logiciel défaillant : le mettre à jour, ou arrêter le service s''il ne sert pas.' }
        elseif ($g.Id -eq 7000 -or $g.Id -eq 7001) { $libelle = 'Échec au démarrage' }
        elseif ($g.Id -eq 7009 -or $g.Id -eq 7011) { $libelle = 'Service qui ne répond pas (délai dépassé)' }
        $idp = 0
        $nom = ''
        foreach ($s in $svcs) {
            if ([string]$s.DisplayName -eq $g.Service -or [string]$s.Name -eq $g.Service) { $idp = [int]$s.ProcessId; $nom = [string]$s.Name; break }
        }
        $texte = '{0} - {1} fois en 24 h, dernière fois le {2}' -f $libelle, $g.Nb, $g.Dernier.ToString('dd/MM à HH:mm')
        Add-Anomalie $anos $gravite $g.Service $nom $texte $idp $conseil ('evt|{0}|{1}|{2}' -f $g.Id, $g.Service, $g.Dernier.ToString('yyyyMMddHH'))
    }
}

function Get-UsageService($s) {
    if ($s.Cat -eq 'E') { return 'Système (essentiel)' }
    $exe = [Environment]::ExpandEnvironmentVariables((Get-CheminExe ([string]$s.Chemin)))
    $racine = Get-RacineInstall $exe
    if ($racine -and $script:RacinesApps.ContainsKey($racine)) { return ('Lié à : ' + $script:RacinesApps[$racine]) }
    if ($s.Cat -eq 'G') { return 'Système (à garder)' }
    $nom = Get-NomStable ([string]$s.Name)
    if (-not $script:HistoSvc.ContainsKey($nom)) { return '' }
    $h = $script:HistoSvc[$nom]
    $obs = [int]$h.Observations
    if ($obs -le 0) { return '' }
    $pct = [int][math]::Round(100 * [int]$h.Actif / $obs)
    if ([int]$script:Suivi.Echantillons -lt 12) { return ('Apprentissage ({0} %)' -f $pct) }
    if ($pct -ge 50) { return ('Régulier ({0} %)' -f $pct) }
    if ($pct -gt 0) { return ('Occasionnel ({0} %)' -f $pct) }
    return 'Jamais actif'
}

function Update-ColonneUsage {
    # Rattache les services aux applications reellement utilisees et met a jour la colonne "Usage"
    $script:RacinesApps = @{}
    foreach ($a in @($script:HistoApps.Values)) {
        $racine = [string]$a.Racine
        if (-not $racine) { continue }
        $nomApp = [string]$a.Produit
        if (-not $nomApp) { $nomApp = [string]$a.Nom }
        $script:RacinesApps[$racine] = $nomApp
    }
    $necessaires = New-Object System.Collections.ArrayList
    $suspects = New-Object System.Collections.ArrayList
    foreach ($row in $grid.Rows) {
        $s = $row.Tag
        if (-not $s) { continue }
        $u = Get-UsageService $s
        $row.Cells['Usage'].Value = $u
        $etat = Get-EtatService $s
        $row.Cells['Habitude'].Value = $etat.Etat
        $row.Cells['Habitude'].ToolTipText = $etat.Motif
        if ($etat.Etat -eq 'Suspect') {
            $row.Cells['Habitude'].Style.BackColor = $CouleursTag['critique'][0]
            [void]$suspects.Add([pscustomobject]@{ Service = $s; Motif = $etat.Motif })
        } elseif ($etat.Etat -eq 'Inhabituel') {
            $row.Cells['Habitude'].Style.BackColor = $CouleursTag['attention'][0]
        } elseif ($etat.Etat -eq 'Habituel') {
            $row.Cells['Habitude'].Style.BackColor = $CouleursTag['ok'][0]
        } else {
            $row.Cells['Habitude'].Style.BackColor = $CouleursTag['neutre'][0]
        }
        if ($u -match '^(Système|Lié à|Régulier)') {
            $mode = [string]$s.StartMode
            if ($ModeFr.ContainsKey($mode)) { $mode = $ModeFr[$mode] }
            [void]$necessaires.Add([pscustomobject]@{ Nom = [string]$s.Name; Service = [string]$s.DisplayName; Categorie = $LibelleCat[$s.Cat]; Usage = $u; Demarrage = $mode })
        }
    }
    if ($necessaires.Count -gt 0) {
        $necessaires | Export-Csv -LiteralPath $FichierNecUsage -NoTypeInformation -Delimiter ';' -Encoding UTF8
    }
    $script:SuspectsSvc = $suspects.ToArray()
    # Le filtre par habitude doit suivre les changements de classement
    if ($cmbEtat.SelectedIndex -gt 0) { try { [void](Update-Filtre) } catch { } }
}

function Show-Anomalies {
    $couleur = @{ 'Élevée' = 'critique'; 'Moyenne' = 'attention'; 'Faible' = 'ok'; 'Information' = 'neutre' }
    $gridAno.Rows.Clear()
    if (@($script:Anomalies).Count -eq 0) {
        $i = $gridAno.Rows.Add('Information', '', 'Aucune anomalie de service détectée au dernier relevé', '', '', '')
        $gridAno.Rows[$i].Cells['Gravite'].Style.BackColor = $CouleursTag['neutre'][0]
        $pageAno.Text = 'Anomalies'
    } else {
        foreach ($a in $script:Anomalies) {
            $i = $gridAno.Rows.Add($a.Gravite, $a.Service, $a.Anomalie, $a.Conso, $a.Reseau, $a.Conseil)
            $gridAno.Rows[$i].Tag = $a
            $gridAno.Rows[$i].Cells['Gravite'].Style.BackColor = $CouleursTag[$couleur[$a.Gravite]][0]
        }
        $pageAno.Text = 'Anomalies ({0})' -f @($script:Anomalies).Count
    }
    $gridAno.ClearSelection()
}

function Show-Reseau {
    $filtre = [string]$cmbPorts.SelectedItem
    $ordreAvis = @{ 'À vérifier' = 1; 'Non nécessaire' = 2; 'Bloqué (pare-feu)' = 3; 'Normal' = 4; 'Nécessaire' = 5 }
    $ordrePortee = @{ 'Internet' = 1; 'Réseau local' = 2; 'Interne au PC' = 3 }
    $triEcoutes = @({ $ordreAvis[$_.Avis] }, { [int]$_.Port }, 'Proto')
    $triCnx = @({ $ordrePortee[$_.Portee] }, 'Processus', 'AdresseDistante')
    $ecoutes = @($script:LignesReseau | Where-Object { $_.Type -eq 'Écoute' } | Sort-Object -Property $triEcoutes)
    $cnx = @($script:LignesReseau | Where-Object { $_.Type -eq 'Connexion' } | Sort-Object -Property $triCnx)
    $aVoir = @($ecoutes | Where-Object { $_.Avis -eq 'À vérifier' -or $_.Avis -eq 'Non nécessaire' -or $_.Etat -eq 'Inhabituel' -or $_.Etat -eq 'Suspect' })
    $aVoir += @($cnx | Where-Object { $_.Etat -eq 'Suspect' })
    $lignes = @()
    if ($filtre -eq 'Connexions établies') { $lignes = $cnx }
    elseif ($filtre -eq 'À fermer ou à vérifier') { $lignes = $aVoir }
    elseif ($filtre -eq 'Tout') { $lignes = @($ecoutes) + @($cnx) }
    else { $lignes = $ecoutes }
    $filtreEtat = [string]$cmbEtatPorts.SelectedItem
    if ($cmbEtatPorts.SelectedIndex -gt 0) { $lignes = @($lignes | Where-Object { $_.Etat -eq $filtreEtat }) }
    $gridPorts.Rows.Clear()
    foreach ($l in $lignes) {
        $distant = ''
        if ($l.Type -eq 'Connexion') { $distant = '{0} : {1}' -f $l.AdresseDistante, $l.PortDistant }
        $procTexte = '{0} ({1})' -f $l.Processus, $l.IdProc
        $note = [string]$l.Note
        if ($l.Motif -and $l.Etat -ne 'Apprentissage') {
            if ($note) { $note = ('{0} : {1}. {2}' -f $l.Etat, $l.Motif, $note) } else { $note = ('{0} : {1}' -f $l.Etat, $l.Motif) }
        }
        $i = $gridPorts.Rows.Add($l.Type, $l.Proto, $l.PortTexte, $l.AdresseLocale, $distant, $procTexte, $l.Services, $l.Portee, $l.Avis, $l.Etat, $l.Habitude, (Format-Octets ([double]$l.Envoye)), (Format-Octets ([double]$l.Recu)), $note)
        $row = $gridPorts.Rows[$i]
        $row.Tag = $l
        if ($l.Avis -eq 'À vérifier') { $row.Cells['Avis'].Style.BackColor = $CouleursTag['critique'][0] }
        elseif ($l.Avis -eq 'Non nécessaire') { $row.Cells['Avis'].Style.BackColor = $CouleursTag['attention'][0] }
        elseif ($l.Avis -eq 'Nécessaire' -or $l.Avis -eq 'Normal') { $row.Cells['Avis'].Style.BackColor = $CouleursTag['ok'][0] }
        elseif ($l.Avis) { $row.Cells['Avis'].Style.BackColor = $CouleursTag['neutre'][0] }
        if ($l.Etat -eq 'Suspect') { $row.Cells['Etat'].Style.BackColor = $CouleursTag['critique'][0] }
        elseif ($l.Etat -eq 'Inhabituel') { $row.Cells['Etat'].Style.BackColor = $CouleursTag['attention'][0] }
        elseif ($l.Etat -eq 'Habituel') { $row.Cells['Etat'].Style.BackColor = $CouleursTag['ok'][0] }
        elseif ($l.Etat) { $row.Cells['Etat'].Style.BackColor = $CouleursTag['neutre'][0] }
        $row.Cells['Etat'].ToolTipText = [string]$l.Motif
        if ($l.Type -eq 'Écoute' -or $l.Portee -ne 'Interne au PC') {
            $bulle = 'Double-clic : Origine - carte du parcours réseau'
            if ($l.Motif) { $bulle = ('{0} : {1}' -f $l.Etat, $l.Motif) + "`r`n" + $bulle }
            foreach ($colonne in @('Type', 'Proto', 'Port', 'Local', 'Distant', 'Processus', 'Services')) { $row.Cells[$colonne].ToolTipText = $bulle }
        }
        if ($l.Portee -eq 'Ouvert au réseau' -or $l.Portee -eq 'Internet') { $row.Cells['Portee'].Style.Font = $script:PoliceGras }
    }
    $gridPorts.ClearSelection()
    if ($aVoir.Count -gt 0) { $pagePorts.Text = 'Ports et connexions ({0} à voir)' -f $aVoir.Count } else { $pagePorts.Text = 'Ports et connexions' }
    $lblPorts.Text = '{0} port(s) en écoute dont {1} ouvert(s) au réseau - {2} connexion(s) établie(s) dont {3} vers Internet' -f $ecoutes.Count, @($ecoutes | Where-Object { $_.Portee -eq 'Ouvert au réseau' }).Count, $cnx.Count, @($cnx | Where-Object { $_.Portee -eq 'Internet' }).Count
}

function Send-Alertes {
    # Bulle pres de l'horloge pour les anomalies graves et les ports inhabituels (une seule fois chacun)
    if (-not $script:Icone) { return }
    $nouvelles = New-Object System.Collections.ArrayList
    foreach ($a in @($script:Anomalies)) {
        if ($a.Gravite -ne 'Élevée') { continue }
        if ($script:AlertesVues.ContainsKey($a.Cle)) { continue }
        $script:AlertesVues[$a.Cle] = $true
        [void]$nouvelles.Add(('{0} : {1}' -f $a.Service, $a.Anomalie))
    }
    foreach ($l in @($script:LignesReseau)) {
        $aSignaler = ($l.Etat -eq 'Suspect')
        if ($l.Etat -eq 'Inhabituel' -and $l.Type -eq 'Écoute' -and $l.Portee -eq 'Ouvert au réseau') { $aSignaler = $true }
        if (-not $aSignaler) { continue }
        $k = 'port|' + $l.Type + '|' + $l.Cle
        if ($script:AlertesVues.ContainsKey($k)) { continue }
        $script:AlertesVues[$k] = $true
        if ($l.Type -eq 'Écoute') { [void]$nouvelles.Add(('{0} : port {1} {2} ouvert par {3}' -f $l.Etat, $l.Proto, $l.PortTexte, $l.Processus)) }
        else { [void]$nouvelles.Add(('{0} : {1} connecté à {2}:{3}' -f $l.Etat, $l.Processus, $l.AdresseDistante, $l.PortDistant)) }
    }
    if ($nouvelles.Count -eq 0) { return }
    $texte = (@($nouvelles | Select-Object -First 3) -join "`r`n")
    if ($nouvelles.Count -gt 3) { $texte += "`r`n... et {0} autre(s)" -f ($nouvelles.Count - 3) }
    if ($texte.Length -gt 250) { $texte = $texte.Substring(0, 250) + '...' }
    try { $script:Icone.ShowBalloonTip(10000, 'Service Minimum', $texte, [System.Windows.Forms.ToolTipIcon]::Warning) } catch { }
}

function Update-Surveillance {
    # Releve periodique : services, applications, ports, connexions, anomalies
    if ($script:SuiviEnCours) { return }
    $script:SuiviEnCours = $true
    try {
        $maintenant = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $script:Suivi.Echantillons = [int]$script:Suivi.Echantillons + 1
        if (-not $script:Suivi.Debut) { $script:Suivi.Debut = $maintenant }
        $anos = New-Object System.Collections.ArrayList
        $svcs = @()
        $procs = @()
        try { $svcs = @(Get-ServicesLegers) } catch { Write-Erreur 'Releve des services' $_ }
        try { $procs = @(Get-Process) } catch { Write-Erreur 'Releve des processus' $_ }
        $procParId = @{}
        foreach ($p in $procs) { $procParId[[int]$p.Id] = $p }
        $svcParPid = @{}
        foreach ($s in $svcs) {
            $idp = [int]$s.ProcessId
            if ($idp -gt 0 -and $s.State -eq 'Running') {
                if (-not $svcParPid.ContainsKey($idp)) { $svcParPid[$idp] = New-Object System.Collections.ArrayList }
                [void]$svcParPid[$idp].Add($s)
            }
        }
        try { Update-InfoPid $procs $svcParPid } catch { Write-Erreur 'Update-InfoPid' $_ }
        try { Update-HistoServices $svcs $maintenant $anos } catch { Write-Erreur 'Update-HistoServices' $_ }
        try { Update-HistoApplications $procs $maintenant } catch { Write-Erreur 'Update-HistoApplications' $_ }
        try {
            $script:LignesReseau = @(Get-Reseau $procParId $svcParPid)
            Update-HistoReseau $script:LignesReseau $maintenant
        } catch { Write-Erreur 'Releve reseau' $_ }
        try { Update-Peripheriques } catch { Write-Erreur 'Update-Peripheriques' $_ }
        try { Update-Wifi $false } catch { Write-Erreur 'Update-Wifi' $_ }
        try { Update-LignesPeripheriques } catch { Write-Erreur 'Update-LignesPeripheriques' $_ }
        try { Add-AnomaliesPeripheriques $anos } catch { Write-Erreur 'Add-AnomaliesPeripheriques' $_ }
        try { Update-Demarrage } catch { Write-Erreur 'Update-Demarrage' $_ }
        try { Add-AnomaliesDemarrage $anos } catch { Write-Erreur 'Add-AnomaliesDemarrage' $_ }
        try { Add-AnomaliesRessources $svcParPid $anos } catch { Write-Erreur 'Add-AnomaliesRessources' $_ }
        try { Add-AnomaliesJournalWindows $svcs $anos } catch { Write-Erreur 'Add-AnomaliesJournalWindows' $_ }
        try {
            $script:AnoParNom = @{}
            foreach ($a in $anos) {
                if ($a.Nom -and -not $script:AnoParNom.ContainsKey([string]$a.Nom)) { $script:AnoParNom[[string]$a.Nom] = $a }
            }
            Update-ColonneUsage
            foreach ($x in @($script:SuspectsSvc)) {
                $sv = $x.Service
                Add-Anomalie $anos 'Élevée' ([string]$sv.DisplayName) ([string]$sv.Name) ('Service suspect - ' + [string]$x.Motif) ([int]$sv.ProcId) 'Vérifier l''origine de ce service. S''il est connu, cliquer sur sa ligne dans la liste du haut puis « Déclarer habituel » ; sinon l''arrêter.' ('suspect|' + [string]$sv.Name)
            }
        } catch { Write-Erreur 'Classement des services' $_ }
        $ordre = @{ 'Élevée' = 1; 'Moyenne' = 2; 'Faible' = 3 }
        foreach ($a in $anos) {
            if ([string]$a.Cle -notmatch '^(per|dem)\|') {
                try {
                    $a.Conso = Get-TexteConso ([int]$a.IdProc)
                    $a.Reseau = Get-TexteReseau ([int]$a.IdProc)
                } catch { }
            }
            if (-not $script:AnomaliesJournalisees.ContainsKey($a.Cle)) {
                $script:AnomaliesJournalisees[$a.Cle] = $true
                try {
                    [pscustomobject]@{ Date = $maintenant; Gravite = $a.Gravite; Service = $a.Service; Nom = $a.Nom; Anomalie = $a.Anomalie; Consommation = $a.Conso; Reseau = $a.Reseau } | Export-Csv -LiteralPath $FichierJournalAno -Append -NoTypeInformation -Delimiter ';' -Encoding UTF8
                } catch { Write-Erreur 'Journal des anomalies' $_ }
            }
        }
        $triAnomalies = @({ $ordre[$_.Gravite] }, 'Service')
        $script:Anomalies = @($anos | Sort-Object -Property $triAnomalies)
        Save-Suivi
        try { Show-Anomalies } catch { Write-Erreur 'Show-Anomalies' $_ }
        try { Show-Reseau } catch { Write-Erreur 'Show-Reseau' $_ }
        try { Show-Peripheriques } catch { Write-Erreur 'Show-Peripheriques' $_ }
        try { Send-AlerteNouveauxPeripheriques } catch { }
        try { Show-Demarrage } catch { Write-Erreur 'Show-Demarrage' $_ }
        try { Send-AlerteNouveauxDemarrage } catch { }
        try { Send-Alertes } catch { Write-Erreur 'Send-Alertes' $_ }
    } finally {
        $script:SuiviEnCours = $false
    }
}

# ---------------------------------------------------------------- Arret de services, de programmes, blocage de ports
function Write-JournalAction([string]$motif, [string]$objet, [string]$avant, [string]$apres, [string]$resultat) {
    try {
        [pscustomobject]@{
            Date     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            Motif    = $motif
            Service  = $objet
            Avant    = $avant
            Apres    = $apres
            Resultat = $resultat
        } | Export-Csv -LiteralPath $FichierJournal -Append -NoTypeInformation -Delimiter ';' -Encoding UTF8
    } catch { Write-Erreur 'Journal des modifications' $_ }
}

function Get-Dependants([string]$nom) {
    # Tous les services actifs qui dependent (directement ou non) du service donne
    $resultat = New-Object System.Collections.ArrayList
    $vus = @{}
    $file = New-Object System.Collections.Queue
    $file.Enqueue($nom)
    while ($file.Count -gt 0) {
        $courant = [string]$file.Dequeue()
        $svc = $null
        try { $svc = Get-Service -Name $courant -ErrorAction Stop } catch { $svc = $null }
        if (-not $svc) { continue }
        foreach ($d in @($svc.DependentServices)) {
            if ($d.Status -eq 'Stopped') { continue }
            if ($vus.ContainsKey($d.Name)) { continue }
            $vus[$d.Name] = $true
            [void]$resultat.Add($d)
            $file.Enqueue($d.Name)
        }
    }
    return $resultat.ToArray()
}

function Stop-ServiceComplet([string]$nom) {
    # Arrete un service et ceux qui en dependent, apres confirmation. Retourne $true si l'arret a eu lieu.
    if (-not $EstAdmin) {
        [void][System.Windows.Forms.MessageBox]::Show('Lecture seule : relancer Service Minimum en administrateur pour arrêter un service.', 'Service Minimum', 'OK', 'Information')
        return $false
    }
    $svc = $null
    try { $svc = Get-Service -Name $nom -ErrorAction Stop } catch { $svc = $null }
    if (-not $svc) {
        [void][System.Windows.Forms.MessageBox]::Show(('Service introuvable : {0}' -f $nom), 'Service Minimum', 'OK', 'Warning')
        return $false
    }
    if ([string]$script:CatParNom[$nom] -eq 'E') {
        [void][System.Windows.Forms.MessageBox]::Show(('« {0} » est un service essentiel de Windows : son arrêt est refusé.' -f $svc.DisplayName), 'Service Minimum', 'OK', 'Warning')
        return $false
    }
    if ($svc.Status -ne 'Running') {
        [void][System.Windows.Forms.MessageBox]::Show(('« {0} » est déjà arrêté.' -f $svc.DisplayName), 'Service Minimum', 'OK', 'Information')
        return $false
    }
    $dependants = @(Get-Dependants $nom)
    $bloquants = @($dependants | Where-Object { [string]$script:CatParNom[$_.Name] -eq 'E' })
    if ($bloquants.Count -gt 0) {
        [void][System.Windows.Forms.MessageBox]::Show(("Arrêt refusé : des services essentiels de Windows dépendent de « {0} » :`r`n`r`n  {1}" -f $svc.DisplayName, ((@($bloquants | ForEach-Object { $_.DisplayName })) -join "`r`n  ")), 'Service Minimum', 'OK', 'Warning')
        return $false
    }
    $texte = "Arrêter le service « {0} » ?" -f $svc.DisplayName
    if ($dependants.Count -gt 0) {
        $texte += "`r`n`r`n{0} service(s) en dépendent et seront arrêtés avec lui :`r`n  {1}" -f $dependants.Count, ((@($dependants | ForEach-Object { $_.DisplayName })) -join "`r`n  ")
    } else {
        $texte += "`r`n`r`nAucun autre service actif n'en dépend."
    }
    $texte += "`r`n`r`nOui : arrêter et passer en démarrage Manuel (il ne redémarrera plus tout seul)`r`nNon : arrêter seulement, jusqu'au prochain redémarrage du PC`r`nAnnuler : ne rien faire"
    $rep = [System.Windows.Forms.MessageBox]::Show($texte, 'Arrêter un service', 'YesNoCancel', 'Question')
    if ($rep -ne 'Yes' -and $rep -ne 'No') { return $false }
    $avant = ''
    try { $avant = [string](Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f ($nom -replace "'", "''"))).StartMode } catch { $avant = '' }
    $ok = $true
    $resultat = 'OK'
    try {
        Stop-Service -Name $nom -Force -ErrorAction Stop
    } catch {
        $ok = $false
        $resultat = 'ECHEC : ' + $_.Exception.Message
    }
    $apres = 'Arrêté'
    if ($ok -and $rep -eq 'Yes' -and $avant -ne 'Manual' -and $avant -ne 'Disabled') {
        $erreur = Set-Mode $nom 'Manual'
        if ($erreur) { $resultat = 'Arrêté ; passage en Manuel refusé : ' + $erreur } else { $apres = 'Arrêté + Manual'; $script:ModifsInternes[$nom] = $true }
    }
    Write-JournalAction 'arret-service' $nom $avant $apres $resultat
    foreach ($d in $dependants) { Write-JournalAction 'arret-dependance' ([string]$d.Name) ('dépend de ' + $nom) 'Arrêté' $resultat }
    if (-not $ok) {
        [void][System.Windows.Forms.MessageBox]::Show(("L'arrêt de « {0} » a échoué :`r`n{1}" -f $svc.DisplayName, $resultat), 'Service Minimum', 'OK', 'Error')
        return $false
    }
    return $true
}

function Stop-Programme($l) {
    # Ferme le programme (hors service Windows) qui tient un port ou une connexion
    if (-not $EstAdmin) {
        [void][System.Windows.Forms.MessageBox]::Show('Lecture seule : relancer Service Minimum en administrateur.', 'Service Minimum', 'OK', 'Information')
        return $false
    }
    $idp = [int]$l.IdProc
    if ($idp -le 4 -or $idp -eq $PID -or ($ProcessusProteges -contains [string]$l.Processus)) {
        [void][System.Windows.Forms.MessageBox]::Show(('« {0} » est un composant de Windows : il ne peut pas être fermé ici. Pour fermer ce port, utiliser « Bloquer ce port (pare-feu) ».' -f $l.Processus), 'Service Minimum', 'OK', 'Warning')
        return $false
    }
    $rep = [System.Windows.Forms.MessageBox]::Show(("Fermer le programme « {0} » (n° {1}) ?`r`n`r`nSes ports et ses connexions seront fermés. Tout travail non enregistré dans ce programme sera perdu, et il se rouvrira s'il est lancé de nouveau." -f $l.Processus, $idp), 'Fermer un programme', 'YesNo', 'Warning')
    if ($rep -ne 'Yes') { return $false }
    try {
        Stop-Process -Id $idp -Force -ErrorAction Stop
        Write-JournalAction 'arret-programme' ([string]$l.Processus) ('n° ' + $idp) 'Fermé' 'OK'
        return $true
    } catch {
        Write-JournalAction 'arret-programme' ([string]$l.Processus) ('n° ' + $idp) 'Fermé' ('ECHEC : ' + $_.Exception.Message)
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
        return $false
    }
}

function Update-PortsBloques {
    # Regles de blocage creees par Service Minimum dans le pare-feu Windows
    $script:PortsBloques = @{}
    try {
        foreach ($r in @(Get-NetFirewallRule -DisplayName ($PrefixeRegle + '*') -ErrorAction Stop)) {
            if ([string]$r.DisplayName -match '(TCP|UDP) (\d+)$') { $script:PortsBloques[($matches[1] + '|' + $matches[2])] = [string]$r.DisplayName }
        }
    } catch { }
}

function Set-BlocagePort([string]$proto, [int]$port, [bool]$bloquer) {
    $nomRegle = '{0}{1} {2}' -f $PrefixeRegle, $proto, $port
    if ($bloquer) {
        New-NetFirewallRule -DisplayName $nomRegle -Group 'Service Minimum' -Description 'Port fermé aux entrées par Service Minimum' -Direction Inbound -Action Block -Protocol $proto -LocalPort $port -Profile Any -ErrorAction Stop | Out-Null
        Write-JournalAction 'blocage-port' ('{0} {1}' -f $proto, $port) 'Ouvert' 'Bloqué (pare-feu)' 'OK'
    } else {
        Remove-NetFirewallRule -DisplayName $nomRegle -ErrorAction Stop
        Write-JournalAction 'deblocage-port' ('{0} {1}' -f $proto, $port) 'Bloqué (pare-feu)' 'Ouvert' 'OK'
    }
    Update-PortsBloques
}

# ---------------------------------------------------------------- Lancement au demarrage de Windows
function Test-DemarrageAuto {
    try {
        $null = Get-ScheduledTask -TaskName $NomTache -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Set-DemarrageAuto([bool]$actif) {
    if ($actif) {
        if ($EstExe) {
            $action = New-ScheduledTaskAction -Execute $CheminApp -Argument '-demarrage'
        } else {
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -demarrage' -f $CheminApp)
        }
        $declencheur = New-ScheduledTaskTrigger -AtLogOn -User $identite.Name
        try { $declencheur.Delay = 'PT1M' } catch { }
        $compte = New-ScheduledTaskPrincipal -UserId $identite.Name -LogonType Interactive -RunLevel Highest
        $reglages = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
        Register-ScheduledTask -TaskName $NomTache -Action $action -Trigger $declencheur -Principal $compte -Settings $reglages -Description 'Lance Service Minimum à l''ouverture de session (surveillance des services et des ports)' -Force -ErrorAction Stop | Out-Null
    } else {
        Unregister-ScheduledTask -TaskName $NomTache -Confirm:$false -ErrorAction Stop
    }
}

function Show-Fenetre {
    $form.Show()
    $form.ShowInTaskbar = $true
    if ($form.WindowState -eq 'Minimized') { $form.WindowState = 'Normal' }
    $form.Activate()
}

# ================================================================ TABLEAU DE BORD ET ORIGINE (version 1.3)
# Petit serveur local (127.0.0.1 uniquement, lecture seule, protege par un jeton) qui alimente
# la page "tableau-de-bord.html" : ressources, anomalies, connexions, et parcours reseau (Origine).

$script:Ecouteur = $null
$script:TacheHttp = $null
$script:PortHttp = 0
$script:Jeton = [guid]::NewGuid().ToString('N')
$script:Trace = $null
$script:GeoCache = @{}
$script:TamponPing = [System.Text.Encoding]::ASCII.GetBytes('ServiceMinimum-origine-0123456789')
try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12 } catch { }

function Start-ServeurLocal {
    if ($script:Ecouteur) { return $true }
    foreach ($port in @(47800, 47801, 47802, 47803, 47804, 47805, 47806, 47807, 47808, 47809)) {
        $e = $null
        try {
            $e = New-Object System.Net.HttpListener
            $e.Prefixes.Add(('http://127.0.0.1:{0}/' -f $port))
            $e.Start()
            $script:Ecouteur = $e
            $script:PortHttp = $port
            $script:TacheHttp = $e.GetContextAsync()
            Write-Demarrage ('tableau de bord local sur le port ' + $port)
            return $true
        } catch {
            try { if ($e) { $e.Close() } } catch { }
        }
    }
    Write-Demarrage 'tableau de bord local indisponible (aucun port libre)'
    return $false
}

function Stop-ServeurLocal {
    try { if ($script:Ecouteur) { $script:Ecouteur.Stop(); $script:Ecouteur.Close() } } catch { }
    $script:Ecouteur = $null
    $script:TacheHttp = $null
}

function Send-Reponse($rep, [int]$code, [string]$type, [string]$texte) {
    $octets = [System.Text.Encoding]::UTF8.GetBytes($texte)
    $rep.StatusCode = $code
    $rep.ContentType = $type
    $rep.Headers['Cache-Control'] = 'no-store'
    $rep.Headers['X-Content-Type-Options'] = 'nosniff'
    $rep.ContentLength64 = $octets.Length
    $rep.OutputStream.Write($octets, 0, $octets.Length)
}

function ConvertTo-Nombre([string]$valeur) {
    # Texte invariant ("48.85") vers nombre ; $null si vide
    if ([string]::IsNullOrWhiteSpace($valeur)) { return $null }
    try { return [double]::Parse($valeur, [System.Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}

function Get-EtatTableau {
    # Donnees du tableau de bord (lecture seule)
    $r = $script:Ressources
    $ressources = [pscustomobject]@{ ramPct = 0; ramGo = 0; ramTotGo = 0; cpu = 0; processus = 0; servicesActifs = 0; services = @($script:Inventaire).Count }
    if ($r) {
        $ressources = [pscustomobject]@{
            ramPct = [int]$r.RamPct
            ramGo = [math]::Round($r.RamMo / 1024, 1)
            ramTotGo = [math]::Round($r.RamTotMo / 1024, 1)
            cpu = [int]$r.Cpu
            processus = [int]$r.Processus
            servicesActifs = [int]$r.ServicesActifs
            services = @($script:Inventaire).Count
        }
    }
    $reseau = New-Object System.Collections.ArrayList
    foreach ($l in @($script:LignesReseau | Select-Object -First 400)) {
        [void]$reseau.Add([pscustomobject]@{
            type = [string]$l.Type; proto = [string]$l.Proto; port = [string]$l.PortTexte; local = [string]$l.AdresseLocale
            distant = [string]$l.AdresseDistante; portDistant = [int]$l.PortDistant; programme = [string]$l.Processus
            services = [string]$l.Services; portee = [string]$l.Portee; avis = [string]$l.Avis; etat = [string]$l.Etat
            motif = [string]$l.Motif; note = [string]$l.Note
        })
    }
    $anomalies = New-Object System.Collections.ArrayList
    foreach ($a in @($script:Anomalies | Select-Object -First 40)) {
        [void]$anomalies.Add([pscustomobject]@{ gravite = [string]$a.Gravite; service = [string]$a.Service; anomalie = [string]$a.Anomalie })
    }
    $ecoutes = @($script:LignesReseau | Where-Object { $_.Type -eq 'Écoute' -and $_.Portee -eq 'Ouvert au réseau' })
    $compte = [pscustomobject]@{
        anomalies = @($script:Anomalies).Count
        portsOuverts = $ecoutes.Count
        portsSuspects = @($ecoutes | Where-Object { $_.Etat -eq 'Suspect' }).Count
        connexions = @($script:LignesReseau | Where-Object { $_.Type -eq 'Connexion' }).Count
    }
    return [pscustomobject]@{
        machine = [string]$env:COMPUTERNAME
        version = $VersionApp
        heure = (Get-Date -Format 'HH:mm:ss')
        ressources = $ressources
        compte = $compte
        anomalies = $anomalies.ToArray()
        reseau = $reseau.ToArray()
    }
}

function Get-TraceTableau {
    $t = $script:Trace
    if (-not $t) { return [pscustomobject]@{ cible = ''; termine = $true; message = ''; etapes = @() } }
    $etapes = New-Object System.Collections.ArrayList
    foreach ($e in @($t.Etapes)) {
        [void]$etapes.Add([pscustomobject]@{
            n = [int]$e.N; ip = [string]$e.Ip; ms = [int]$e.Ms; lat = $e.Lat; lon = $e.Lon
            lieu = [string]$e.Lieu; org = [string]$e.Org; prive = [bool]$e.Prive; muet = [bool]$e.Muet; cible = [bool]$e.Cible
        })
    }
    return [pscustomobject]@{ cible = [string]$t.Cible; termine = [bool]$t.Termine; message = [string]$t.Message; etapes = $etapes.ToArray() }
}

function Invoke-RequeteLocale($contexte) {
    $req = $contexte.Request
    $rep = $contexte.Response
    try {
        $chemin = [string]$req.Url.AbsolutePath
        if ($req.HttpMethod -ne 'GET') {
            Send-Reponse $rep 405 'text/plain; charset=utf-8' 'Méthode refusée'
        } elseif ($chemin -eq '/' -or $chemin -eq '/tableau-de-bord.html') {
            if (Test-Path -LiteralPath $FichierTableau) {
                Send-Reponse $rep 200 'text/html; charset=utf-8' ([System.IO.File]::ReadAllText($FichierTableau, [System.Text.Encoding]::UTF8))
            } else {
                Send-Reponse $rep 404 'text/plain; charset=utf-8' 'Fichier tableau-de-bord.html introuvable à côté de l''application.'
            }
        } elseif ($chemin -like '/api/*') {
            if ([string]$req.QueryString['jeton'] -ne $script:Jeton) {
                Send-Reponse $rep 403 'application/json; charset=utf-8' '{"ok":false,"message":"Jeton invalide : rouvrir le tableau de bord depuis Service Minimum."}'
            } elseif ($chemin -eq '/api/etat') {
                Send-Reponse $rep 200 'application/json; charset=utf-8' (Get-EtatTableau | ConvertTo-Json -Depth 5 -Compress)
            } elseif ($chemin -eq '/api/trace') {
                Send-Reponse $rep 200 'application/json; charset=utf-8' (Get-TraceTableau | ConvertTo-Json -Depth 5 -Compress)
            } elseif ($chemin -eq '/api/origine') {
                $ip = [string]$req.QueryString['ip']
                $adresse = $null
                $valide = [System.Net.IPAddress]::TryParse($ip, [ref]$adresse)
                if (-not $valide) {
                    Send-Reponse $rep 200 'application/json; charset=utf-8' '{"ok":false,"message":"Adresse IP invalide."}'
                } elseif (-not (Test-Path -LiteralPath $FichierAccordGeo)) {
                    Send-Reponse $rep 200 'application/json; charset=utf-8' '{"ok":false,"message":"Tracé non autorisé : lancer une première fois « Origine (carte) » depuis la fenêtre Service Minimum pour accepter la géolocalisation en ligne."}'
                } else {
                    Start-Trace $adresse.ToString()
                    Send-Reponse $rep 200 'application/json; charset=utf-8' '{"ok":true}'
                }
            } else {
                Send-Reponse $rep 404 'application/json; charset=utf-8' '{"ok":false}'
            }
        } else {
            Send-Reponse $rep 404 'text/plain; charset=utf-8' 'Introuvable'
        }
    } catch {
        Write-Erreur 'Tableau de bord local' $_
    } finally {
        try { $rep.Close() } catch { }
    }
}

# ---------------------------------------------------------------- Geolocalisation (service en ligne ipwho.is)
function Test-AdressePublique([string]$ip) {
    if ([string]::IsNullOrWhiteSpace($ip)) { return $false }
    if ((Get-PorteeAdresse $ip) -ne 'Internet') { return $false }
    if ($ip -match '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.') { return $false }
    if ($ip -eq '0.0.0.0' -or $ip -eq '::' -or $ip -like '224.*' -or $ip -like '239.*' -or $ip -like 'ff*:*') { return $false }
    return $true
}

function Get-Geoloc([string]$ip) {
    # $ip vide = adresse publique de ce poste. Resultat garde en memoire et dans geolocalisation.csv.
    $cle = $ip
    if (-not $cle) { $cle = 'ce-poste' }
    if ($script:GeoCache.ContainsKey($cle)) { return $script:GeoCache[$cle] }
    $g = $null
    try {
        $r = Invoke-RestMethod -Uri ('https://ipwho.is/' + $ip) -TimeoutSec 6 -ErrorAction Stop
        if ($r -and $r.success) {
            $lieu = (@([string]$r.city, [string]$r.country) | Where-Object { $_ }) -join ', '
            $org = ''
            try { $org = [string]$r.connection.org } catch { $org = '' }
            if (-not $org) { try { $org = [string]$r.connection.isp } catch { $org = '' } }
            $g = [pscustomobject]@{ Cle = $cle; Lat = [string]$r.latitude; Lon = [string]$r.longitude; Lieu = $lieu; Org = $org; Date = (Get-Date -Format 'yyyy-MM-dd') }
        }
    } catch { Write-Erreur 'Geolocalisation' $_ }
    if ($g) {
        $script:GeoCache[$cle] = $g
        if ($cle -ne 'ce-poste') {
            try { $g | Export-Csv -LiteralPath $FichierGeo -Append -NoTypeInformation -Delimiter ';' -Encoding UTF8 } catch { }
        }
    } else {
        # Echec memorise pour la session : on ne redemande pas la meme adresse en boucle
        $script:GeoCache[$cle] = $null
    }
    return $g
}

function Set-GeolocEtape($e) {
    $g = $null
    if ($e.N -eq 0) { $g = Get-Geoloc '' }
    elseif (Test-AdressePublique ([string]$e.Ip)) { $g = Get-Geoloc ([string]$e.Ip) }
    if ($g) {
        $e.Lat = ConvertTo-Nombre ([string]$g.Lat)
        $e.Lon = ConvertTo-Nombre ([string]$g.Lon)
        $e.Lieu = [string]$g.Lieu
        $e.Org = [string]$g.Org
    }
}

# ---------------------------------------------------------------- Parcours reseau (Origine)
function New-EtapeTrace([int]$n, [string]$ip, [int]$ms, [bool]$muet, [bool]$cible) {
    $prive = $false
    if ($ip -and -not (Test-AdressePublique $ip)) { $prive = $true }
    return [pscustomobject]@{ N = $n; Ip = $ip; Ms = $ms; Lat = $null; Lon = $null; Lieu = ''; Org = ''; Prive = $prive; Muet = $muet; Cible = $cible }
}

function Start-Trace([string]$ip) {
    # Demarre le trace vers une adresse ; il avance ensuite pas a pas (Step-Trace), sans bloquer la fenetre
    if ($script:Trace -and $script:Trace.Ping) { try { $script:Trace.Ping.Dispose() } catch { } }
    $t = [pscustomobject]@{
        Cible = $ip; Ttl = 0; Tache = $null; Ping = $null; Chrono = $null
        Etapes = (New-Object System.Collections.ArrayList); AGeoloc = (New-Object System.Collections.Queue)
        Muets = 0; Fini = $false; Termine = $false; Message = ''
    }
    $depart = New-EtapeTrace 0 'Ce PC' 0 $false $false
    [void]$t.Etapes.Add($depart)
    $t.AGeoloc.Enqueue($depart)
    $script:Trace = $t
}

function Complete-Trace($t, [bool]$atteinte) {
    $t.Fini = $true
    $nb = @($t.Etapes | Where-Object { $_.N -gt 0 -and -not $_.Cible }).Count
    if ($atteinte) {
        $t.Message = 'Destination {0} atteinte en {1} étape(s).' -f $t.Cible, $nb
    } else {
        # La destination ne repond pas au ping (frequent) : on la place quand meme sur la carte
        $fin = New-EtapeTrace ($t.Ttl) $t.Cible 0 $false $true
        [void]$t.Etapes.Add($fin)
        $t.AGeoloc.Enqueue($fin)
        $t.Message = 'La destination {0} ne répond pas au ping : derniers nœuds masqués, position finale donnée par sa géolocalisation.' -f $t.Cible
    }
}

function Step-Trace {
    $t = $script:Trace
    if (-not $t -or $t.Termine) { return }
    if ($t.AGeoloc.Count -gt 0) {
        $e = $t.AGeoloc.Dequeue()
        try { Set-GeolocEtape $e } catch { Write-Erreur 'Set-GeolocEtape' $_ }
        return
    }
    if ($t.Fini) { $t.Termine = $true; return }
    if (-not $t.Tache) {
        $t.Ttl = [int]$t.Ttl + 1
        if ($t.Ttl -gt 30) { Complete-Trace $t $false; return }
        try {
            $options = New-Object System.Net.NetworkInformation.PingOptions(([int]$t.Ttl), $true)
            $t.Ping = New-Object System.Net.NetworkInformation.Ping
            $t.Chrono = [System.Diagnostics.Stopwatch]::StartNew()
            $t.Tache = $t.Ping.SendPingAsync([System.Net.IPAddress]::Parse($t.Cible), 900, $script:TamponPing, $options)
        } catch {
            Write-Erreur 'Ping du trace' $_
            Complete-Trace $t $false
        }
        return
    }
    if (-not $t.Tache.IsCompleted) { return }
    $rep = $null
    try { $rep = $t.Tache.Result } catch { $rep = $null }
    $ms = 0
    try { $ms = [int]$t.Chrono.ElapsedMilliseconds } catch { $ms = 0 }
    $t.Tache = $null
    try { $t.Ping.Dispose() } catch { }
    $t.Ping = $null
    $statut = ''
    if ($rep) { $statut = [string]$rep.Status }
    if ($statut -eq 'Success' -or $statut -eq 'TtlExpired') {
        $ip = [string]$rep.Address
        $atteinte = ($statut -eq 'Success')
        $e = New-EtapeTrace ([int]$t.Ttl) $ip $ms $false $atteinte
        [void]$t.Etapes.Add($e)
        $t.AGeoloc.Enqueue($e)
        $t.Muets = 0
        if ($atteinte) { Complete-Trace $t $true }
    } else {
        [void]$t.Etapes.Add((New-EtapeTrace ([int]$t.Ttl) '' 0 $true $false))
        $t.Muets = [int]$t.Muets + 1
        if ($t.Muets -ge 5) { Complete-Trace $t $false }
    }
}

function Open-Tableau {
    # Ouvre le tableau de bord dans le navigateur par defaut (via l'Explorateur, donc sans droits administrateur)
    if (-not (Start-ServeurLocal)) {
        [void][System.Windows.Forms.MessageBox]::Show('Le tableau de bord n''a pas pu démarrer (ports locaux 47800 à 47809 occupés).', 'Service Minimum', 'OK', 'Warning')
        return
    }
    if (-not (Test-Path -LiteralPath $FichierTableau)) {
        [void][System.Windows.Forms.MessageBox]::Show(('Fichier introuvable : {0}' -f $FichierTableau), 'Service Minimum', 'OK', 'Warning')
        return
    }
    $minuteurHttp.Start()
    $url = 'http://127.0.0.1:{0}/?jeton={1}' -f $script:PortHttp, $script:Jeton
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $url)
}

function Get-CibleOrigine($l) {
    # Adresse a tracer pour une ligne de l'onglet Ports : la machine distante d'une connexion,
    # ou une machine actuellement connectee au port en ecoute
    if ($l.Type -eq 'Connexion') {
        if ($l.Portee -eq 'Interne au PC') { return '' }
        return [string]$l.AdresseDistante
    }
    $pairs = @($script:LignesReseau | Where-Object { $_.Type -eq 'Connexion' -and [int]$_.IdProc -eq [int]$l.IdProc -and [int]$_.Port -eq [int]$l.Port -and $_.Portee -ne 'Interne au PC' })
    if ($pairs.Count -gt 0) { return [string]$pairs[0].AdresseDistante }
    return ''
}

function Show-Origine($l) {
    $ip = Get-CibleOrigine $l
    if (-not $ip) {
        if ($l.Type -eq 'Connexion') {
            [void][System.Windows.Forms.MessageBox]::Show('Cette connexion reste à l''intérieur du PC : il n''y a pas de parcours réseau à tracer.', 'Origine', 'OK', 'Information')
        } else {
            [void][System.Windows.Forms.MessageBox]::Show(("Aucune machine distante n'est connectée au port {0} {1} en ce moment : il n'y a pas d'origine à tracer.`r`n`r`nSi une machine s'y connecte, la ligne apparaîtra dans « Connexions établies »." -f $l.Proto, $l.PortTexte), 'Origine', 'OK', 'Information')
        }
        return
    }
    if (-not (Test-Path -LiteralPath $FichierAccordGeo)) {
        $rep = [System.Windows.Forms.MessageBox]::Show("Pour placer le parcours sur la carte, Service Minimum doit géolocaliser les adresses IP rencontrées (nœuds du trajet, destination, et l'adresse publique de ce poste).`r`n`r`nCes adresses sont envoyées au service en ligne ipwho.is (connexion chiffrée). Rien d'autre n'est transmis, et les réponses sont gardées en local pour ne pas redemander deux fois la même adresse.`r`n`r`nAutoriser cette géolocalisation en ligne ?", 'Origine - géolocalisation en ligne', 'YesNo', 'Question')
        if ($rep -ne 'Yes') { return }
        Set-Content -LiteralPath $FichierAccordGeo -Value ('Géolocalisation en ligne (ipwho.is) acceptée le ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding UTF8
    }
    Start-Trace $ip
    Open-Tableau
}

# ---------------------------------------------------------------- Export / import des configurations (version 1.5)
# Format JSON portable (Schema = ServiceMinimum.Configuration, VersionSchema = 1), lisible par d'autres
# applications (Fifou). Un import n'applique jamais rien : la configuration est ajoutee a la liste,
# puis l'utilisateur l'applique lui-meme (confirmation et sauvegarde prealable, comme d'habitude).
$SchemaConfig = 'ServiceMinimum.Configuration'
$DirImportAttente = Join-Path $Donnees 'import-en-attente'

function Export-ConfigJson($cfg, [string]$fichier) {
    $services = @($cfg.Services | Where-Object { $ModeFr.ContainsKey([string]$_.Cible) } | ForEach-Object {
        [pscustomobject]@{ Name = [string]$_.Name; DisplayName = [string]$_.DisplayName; Categorie = [string]$_.Categorie; Cible = [string]$_.Cible }
    })
    [pscustomobject]@{
        Schema        = $SchemaConfig
        VersionSchema = 1
        Application   = ('Service Minimum ' + $VersionApp)
        Nom           = [string]$cfg.Nom
        Date          = [string]$cfg.Date
        MachineSource = [string]$cfg.Machine
        Exportee      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Windows       = [string][Environment]::OSVersion.Version
        Services      = $services
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $fichier -Encoding UTF8
    return $services.Count
}

function Import-ConfigJson([string]$fichier) {
    # Retourne la configuration ajoutee ; leve une exception si le fichier n'est pas valide
    $info = Get-Item -LiteralPath $fichier -ErrorAction Stop
    if ($info.Length -gt 5MB) { throw 'Fichier trop volumineux pour une configuration Service Minimum.' }
    $x = Get-Content -LiteralPath $fichier -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$x.Schema -ne $SchemaConfig) { throw 'Ce fichier n''est pas une configuration Service Minimum (champ « Schema » absent ou différent).' }
    if ([int]$x.VersionSchema -gt 1) { throw ('Configuration créée par une version plus récente de Service Minimum (format {0}) : mettre l''application à jour.' -f $x.VersionSchema) }
    $services = New-Object System.Collections.ArrayList
    $vus = @{}
    foreach ($s in @($x.Services)) {
        $nom = [string]$s.Name
        $mode = [string]$s.Cible
        if ($nom -notmatch '^[^\\/"<>|\r\n]{1,256}$') { continue }
        if (-not $ModeFr.ContainsKey($mode)) { continue }
        if ($vus.ContainsKey($nom)) { continue }
        $vus[$nom] = $true
        [void]$services.Add([pscustomobject]@{ Name = $nom; DisplayName = [string]$s.DisplayName; Categorie = [string]$s.Categorie; Cible = $mode })
    }
    if ($services.Count -eq 0) { throw 'Aucun service valide dans ce fichier.' }
    $nomCfg = [string]$x.Nom
    if ([string]::IsNullOrWhiteSpace($nomCfg)) { $nomCfg = 'Configuration importée' }
    $source = [string]$x.MachineSource
    if ($source -and $source -ne $env:COMPUTERNAME) { $nomCfg = '{0} (de {1})' -f $nomCfg, $source }
    if ($nomCfg.Length -gt 120) { $nomCfg = $nomCfg.Substring(0, 120) }
    $slug = ($nomCfg -replace '[^A-Za-z0-9_-]+', '-').Trim('-')
    if (-not $slug) { $slug = 'importee' }
    $destination = Join-Path $DirProfils ('config-{0}.json' -f $slug)
    $n = 2
    while (Test-Path -LiteralPath $destination) {
        $destination = Join-Path $DirProfils ('config-{0}-{1}.json' -f $slug, $n)
        $n++
    }
    $cfg = [pscustomobject]@{ Nom = $nomCfg; Date = [string]$x.Date; Machine = $source; Services = $services.ToArray(); Fichier = $destination }
    Save-Config $cfg @()
    Write-JournalAction 'import-configuration' $nomCfg ([System.IO.Path]::GetFileName($fichier)) ('{0} service(s)' -f $services.Count) 'OK'
    return $cfg
}

function Select-Config([string]$fichier) {
    $gridCfg.ClearSelection()
    foreach ($row in $gridCfg.Rows) {
        if ($row.Tag -and [string]$row.Tag.Fichier -eq $fichier) {
            $row.Selected = $true
            $gridCfg.CurrentCell = $row.Cells['Nom']
            break
        }
    }
}

function Invoke-ImportConfig([string]$fichier) {
    try {
        $cfg = Import-ConfigJson $fichier
        Update-Configs
        try { Show-Fenetre } catch { }
        $onglets.SelectedTab = $pageCfg
        Select-Config ([string]$cfg.Fichier)
        $nbEcarts = 0
        $nbAbsents = 0
        if (@($script:Inventaire).Count -gt 0) {
            $nbEcarts = @(Get-EcartsConfig $cfg).Count
            $presents = @{}
            foreach ($s in $script:Inventaire) { $presents[[string]$s.Name] = $true }
            $nbAbsents = @($cfg.Services | Where-Object { -not $presents.ContainsKey([string]$_.Name) }).Count
        }
        $texte = "Configuration « {0} » importée : {1} service(s).`r`n`r`nÉcarts avec ce PC : {2}.`r`nServices absents de ce PC (ignorés) : {3}.`r`n`r`nRien n'a été modifié. Pour l'appliquer : elle est sélectionnée dans l'onglet « Configurations enregistrées » ; cliquer sur « Appliquer la configuration sélectionnée » (la liste des changements est affichée et l'état actuel sauvegardé avant). Les services essentiels de Windows ne sont jamais modifiés." -f $cfg.Nom, @($cfg.Services).Count, $nbEcarts, $nbAbsents
        [void][System.Windows.Forms.MessageBox]::Show($texte, 'Service Minimum - import', 'OK', 'Information')
    } catch {
        Write-Erreur 'Import de configuration' $_
        [void][System.Windows.Forms.MessageBox]::Show(("Import impossible :`r`n{0}" -f $_.Exception.Message), 'Service Minimum - import', 'OK', 'Warning')
    }
}

function Receive-ImportsEnAttente {
    # Fichiers deposes par une seconde ouverture (ServiceMinimum -importer ...) pendant que l'application tournait
    # Un message d'import reste ouvert pendant que les minuteurs continuent : on evite de traiter deux fois le meme fichier
    if ($script:ImportEnCours) { return }
    if (-not (Test-Path -LiteralPath $DirImportAttente)) { return }
    $script:ImportEnCours = $true
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $DirImportAttente -Filter '*.json' -File)) {
            $copie = Join-Path ([System.IO.Path]::GetTempPath()) ('ServiceMinimum-import-' + [guid]::NewGuid().ToString('N') + '.json')
            try {
                Move-Item -LiteralPath $f.FullName -Destination $copie -Force
                Invoke-ImportConfig $copie
            } finally {
                try { if (Test-Path -LiteralPath $copie) { Remove-Item -LiteralPath $copie -Force } } catch { }
            }
        }
    } finally {
        $script:ImportEnCours = $false
    }
}
$script:ImportEnCours = $false

# ---------------------------------------------------------------- Partage des journaux (version 1.6)
# Prepare un paquet .zip (journaux choisis + synthese lisible + configuration) et ouvre le message dans
# la messagerie choisie. Rien n'est envoye automatiquement : l'utilisateur choisit le destinataire et envoie.
$DirPartages = Join-Path $Donnees 'partages'

$ElementsPartage = @(
    [pscustomobject]@{ Cle = 'synthese'; Libelle = 'Synthèse lisible (texte)'; Fichier = ''; Defaut = $true }
    [pscustomobject]@{ Cle = 'anomalies'; Libelle = 'Journal des anomalies'; Fichier = $FichierJournalAno; Defaut = $true }
    [pscustomobject]@{ Cle = 'necusage'; Libelle = 'Services nécessaires selon l''usage (service minimum)'; Fichier = $FichierNecUsage; Defaut = $true }
    [pscustomobject]@{ Cle = 'histonec'; Libelle = 'Historique de la liste des services nécessaires'; Fichier = $FichierHistoNec; Defaut = $false }
    [pscustomobject]@{ Cle = 'modifs'; Libelle = 'Journal des modifications (services modifiés, arrêts, blocages de ports)'; Fichier = $FichierJournal; Defaut = $true }
    [pscustomobject]@{ Cle = 'histosvc'; Libelle = 'Historique d''activité des services'; Fichier = $FichierHistoSvc; Defaut = $false }
    [pscustomobject]@{ Cle = 'ports'; Libelle = 'Journal des ports (contient des adresses IP de ce poste)'; Fichier = $FichierJournalPorts; Defaut = $false }
    [pscustomobject]@{ Cle = 'histoports'; Libelle = 'Historique des ports en écoute (contient des adresses IP de ce poste)'; Fichier = $FichierHistoPorts; Defaut = $false }
    [pscustomobject]@{ Cle = 'cnx'; Libelle = 'Historique des connexions (contient les adresses IP contactées)'; Fichier = $FichierHistoCnx; Defaut = $false }
    [pscustomobject]@{ Cle = 'apps'; Libelle = 'Applications utilisées sur ce poste'; Fichier = $FichierHistoApps; Defaut = $false }
    [pscustomobject]@{ Cle = 'journalper'; Libelle = 'Journal des périphériques (branchements USB et Bluetooth, connexions Wi-Fi)'; Fichier = $FichierJournalPer; Defaut = $true }
    [pscustomobject]@{ Cle = 'histoper'; Libelle = 'Historique des périphériques USB et Bluetooth'; Fichier = $FichierHistoPer; Defaut = $false }
    [pscustomobject]@{ Cle = 'journaldem'; Libelle = 'Journal du démarrage de Windows (programmes ajoutés, retirés, modifiés)'; Fichier = $FichierJournalDem; Defaut = $true }
    [pscustomobject]@{ Cle = 'histodem'; Libelle = 'Programmes lancés au démarrage de Windows (historique)'; Fichier = $FichierHistoDem; Defaut = $false }
    [pscustomobject]@{ Cle = 'histowifi'; Libelle = 'Historique des réseaux Wi-Fi (noms des réseaux utilisés et à portée)'; Fichier = $FichierHistoWifi; Defaut = $false }
)

$ScriptCourriel = @'
param([string]$Parametres)
# Prepare le courriel dans Outlook (sans l'envoyer) ; sinon ouvre la messagerie par defaut.
$p = Get-Content -LiteralPath $Parametres -Raw -Encoding UTF8 | ConvertFrom-Json
try {
    $outlook = New-Object -ComObject Outlook.Application
    $message = $outlook.CreateItem(0)
    $message.Subject = [string]$p.Sujet
    $message.Body = [string]$p.Corps
    [void]$message.Attachments.Add([string]$p.Zip)
    $message.Display()
} catch {
    $corps = [string]$p.Corps
    if ($corps.Length -gt 1200) { $corps = $corps.Substring(0, 1200) + "`r`n..." }
    $corps += "`r`n`r`nPièce jointe à ajouter : " + [string]$p.Zip
    Start-Process ('mailto:?subject=' + [Uri]::EscapeDataString([string]$p.Sujet) + '&body=' + [Uri]::EscapeDataString($corps))
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f [string]$p.Zip)
}
Remove-Item -LiteralPath $Parametres -ErrorAction SilentlyContinue
'@

function Get-SyntheseTexte([bool]$courte) {
    $l = New-Object System.Collections.ArrayList
    [void]$l.Add(('SERVICE MINIMUM - synthèse du {0}' -f (Get-Date -Format 'dd/MM/yyyy HH:mm')))
    [void]$l.Add(('Poste : {0} - Windows {1} - Service Minimum {2}' -f $env:COMPUTERNAME, [Environment]::OSVersion.Version, $VersionApp))
    $inv = @($script:Inventaire)
    $actifs = @($inv | Where-Object { $_.State -eq 'Running' }).Count
    $aTraiter = @($inv | Where-Object { $_.Cat -eq 'I' -and $_.Cible -and $_.Cible -ne $_.StartMode }).Count
    [void]$l.Add(('Services : {0} dont {1} actifs - {2} « inutiles probables » encore à traiter' -f $inv.Count, $actifs, $aTraiter))
    $r = $script:Ressources
    if ($r) {
        [void]$l.Add(('Ressources : mémoire vive {0} % ({1:N1} / {2:N1} Go), processeur {3} %, {4} processus' -f $r.RamPct, ($r.RamMo / 1024), ($r.RamTotMo / 1024), $r.Cpu, $r.Processus))
    }
    $anos = @($script:Anomalies)
    [void]$l.Add('')
    [void]$l.Add(('Anomalies au dernier relevé : {0}' -f $anos.Count))
    $max = 20
    if ($courte) { $max = 5 }
    foreach ($a in @($anos | Select-Object -First $max)) { [void]$l.Add(('  - [{0}] {1} : {2}' -f $a.Gravite, $a.Service, $a.Anomalie)) }
    if ($anos.Count -gt $max) { [void]$l.Add(('  ... et {0} autre(s)' -f ($anos.Count - $max))) }
    $suspects = @($script:LignesReseau | Where-Object { $_.Etat -eq 'Suspect' })
    $aVoir = @($script:LignesReseau | Where-Object { $_.Type -eq 'Écoute' -and $_.Portee -eq 'Ouvert au réseau' -and ($_.Avis -eq 'À vérifier' -or $_.Avis -eq 'Non nécessaire') })
    [void]$l.Add(('Ports et connexions suspects : {0} - ports ouverts au réseau à vérifier ou non nécessaires : {1}' -f $suspects.Count, $aVoir.Count))
    if (-not $courte) {
        foreach ($x in @($suspects | Select-Object -First 15)) {
            if ($x.Type -eq 'Connexion') { [void]$l.Add(('  - suspect : {0} connecté à {1}:{2} - {3}' -f $x.Processus, $x.AdresseDistante, $x.PortDistant, $x.Motif)) }
            else { [void]$l.Add(('  - suspect : port {0} {1} ouvert par {2} - {3}' -f $x.Proto, $x.PortTexte, $x.Processus, $x.Motif)) }
        }
        foreach ($x in @($aVoir | Select-Object -First 15)) { [void]$l.Add(('  - port {0} {1} ({2}) : {3} - {4}' -f $x.Proto, $x.PortTexte, $x.Processus, $x.Avis, $x.Note)) }
    }
    $nec = 0
    if (Test-Path -LiteralPath $FichierNecUsage) {
        try { $nec = @(Import-Csv -LiteralPath $FichierNecUsage -Delimiter ';' -Encoding UTF8).Count } catch { }
    }
    [void]$l.Add(('Services nécessaires selon l''usage : {0}' -f $nec))
    if ($script:Suivi -and $script:Suivi.Debut) {
        [void]$l.Add(('Surveillance : {0} relevé(s) depuis le {1}' -f $script:Suivi.Echantillons, $script:Suivi.Debut))
    }
    return ($l.ToArray() -join "`r`n")
}

function New-PaquetPartage($cles, $cfg) {
    if (-not (Test-Path -LiteralPath $DirPartages)) { New-Item -ItemType Directory -Path $DirPartages | Out-Null }
    $nom = 'ServiceMinimum-{0}-{1}' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss')
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) $nom
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    try {
        if ($cles -contains 'synthese') { Get-SyntheseTexte $false | Set-Content -LiteralPath (Join-Path $temp 'synthese.txt') -Encoding UTF8 }
        foreach ($e in $ElementsPartage) {
            if ($e.Fichier -and ($cles -contains $e.Cle) -and (Test-Path -LiteralPath $e.Fichier)) { Copy-Item -LiteralPath $e.Fichier -Destination $temp }
        }
        if ($cfg -and ($cles -contains 'config')) { [void](Export-ConfigJson $cfg (Join-Path $temp 'configuration.json')) }
        $zip = Join-Path $DirPartages ($nom + '.zip')
        Compress-Archive -Path (Join-Path $temp '*') -DestinationPath $zip -Force
        return $zip
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Set-PressePapiersFichier([string]$chemin) {
    try {
        $c = New-Object System.Collections.Specialized.StringCollection
        [void]$c.Add($chemin)
        [System.Windows.Forms.Clipboard]::SetFileDropList($c)
        return $true
    } catch {
        Write-Erreur 'Presse-papiers' $_
        return $false
    }
}

function Open-SansElevation([string]$cible) {
    # Passe par l'Explorateur : la cible s'ouvre dans la session de l'utilisateur, sans droits administrateur
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $cible)
}

function Send-PartageCourriel([string]$zip) {
    $sujet = 'Service Minimum - journaux du poste {0} ({1})' -f $env:COMPUTERNAME, (Get-Date -Format 'dd/MM/yyyy')
    $corps = ("Bonjour,`r`n`r`nVous trouverez ci-joint les journaux Service Minimum du poste {0}.`r`n`r`n" -f $env:COMPUTERNAME) + (Get-SyntheseTexte $true)
    $params = Join-Path $DirPartages 'courriel-parametres.json'
    [pscustomobject]@{ Zip = $zip; Sujet = $sujet; Corps = $corps } | ConvertTo-Json | Set-Content -LiteralPath $params -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $DirPartages 'envoi-courriel.ps1') -Value $ScriptCourriel -Encoding UTF8
    $cmd = Join-Path $DirPartages 'envoi-courriel.cmd'
    Set-Content -LiteralPath $cmd -Value ("@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""%~dp0envoi-courriel.ps1"" -Parametres ""%~dp0courriel-parametres.json""`r`n") -Encoding ASCII
    Open-SansElevation $cmd
    [void][System.Windows.Forms.MessageBox]::Show("Le courriel est préparé dans Outlook avec le paquet en pièce jointe : ajoutez le destinataire, vérifiez, puis envoyez-le.`r`n`r`nSans Outlook, votre messagerie par défaut s'ouvre avec la synthèse et le dossier du paquet s'affiche pour l'ajouter en pièce jointe.", 'Partager - courriel', 'OK', 'Information')
}

function Send-PartageWhatsApp([string]$zip) {
    $copie = Set-PressePapiersFichier $zip
    $texte = Get-SyntheseTexte $true
    if ($texte.Length -gt 600) { $texte = $texte.Substring(0, 600) + ' ...' }
    $texte += "`r`n(Journaux complets dans le fichier joint)"
    $enc = [Uri]::EscapeDataString($texte)
    if (Test-Path -LiteralPath 'Registry::HKEY_CLASSES_ROOT\whatsapp') { $url = 'whatsapp://send?text=' + $enc }
    else { $url = 'https://web.whatsapp.com/send?text=' + $enc }
    Open-SansElevation $url
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $zip)
    $aide = "WhatsApp s'ouvre avec la synthèse prête : choisissez le destinataire.`r`n`r`n"
    if ($copie) { $aide += "Le paquet est dans le presse-papiers : Ctrl+V dans la conversation pour le joindre, ou glissez-le depuis la fenêtre de l'Explorateur ouverte." }
    else { $aide += "Glissez le paquet dans la conversation depuis la fenêtre de l'Explorateur ouverte." }
    [void][System.Windows.Forms.MessageBox]::Show($aide, 'Partager - WhatsApp', 'OK', 'Information')
}

function Send-PartageMessenger([string]$zip) {
    $copie = Set-PressePapiersFichier $zip
    Open-SansElevation 'https://www.messenger.com/'
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $zip)
    $aide = "Messenger s'ouvre : choisissez la conversation.`r`n`r`n"
    if ($copie) { $aide += "Le paquet est dans le presse-papiers : Ctrl+V dans la conversation pour le joindre, ou glissez-le depuis la fenêtre de l'Explorateur ouverte." }
    else { $aide += "Glissez le paquet dans la conversation depuis la fenêtre de l'Explorateur ouverte." }
    $aide += "`r`n`r`nMessenger ne permet pas de préremplir un message : la synthèse est dans le paquet (synthese.txt), ou utilisez « Copier la synthèse » pour la coller en texte."
    [void][System.Windows.Forms.MessageBox]::Show($aide, 'Partager - Messenger', 'OK', 'Information')
}

function Show-Partage {
    $cfg = $null
    if ($gridCfg.SelectedRows.Count -gt 0) { $cfg = $gridCfg.SelectedRows[0].Tag }
    $elements = New-Object System.Collections.ArrayList
    foreach ($e in $ElementsPartage) {
        if (-not $e.Fichier -or (Test-Path -LiteralPath $e.Fichier)) { [void]$elements.Add($e) }
    }
    if ($cfg) {
        [void]$elements.Add([pscustomobject]@{ Cle = 'config'; Libelle = ('Configuration sélectionnée : « {0} » (JSON, importable sur un autre poste)' -f $cfg.Nom); Fichier = ''; Defaut = $true })
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Partager les journaux'
    $dlg.Size = New-Object System.Drawing.Size(660, 540)
    $dlg.StartPosition = 'CenterParent'
    $dlg.Font = $form.Font
    $dlg.MinimizeBox = $false
    $dlg.MaximizeBox = $false
    $dlg.ShowInTaskbar = $false

    $intro = New-Object System.Windows.Forms.Label
    $intro.Dock = 'Top'
    $intro.AutoSize = $false
    $intro.Height = 86
    $intro.Padding = New-Object System.Windows.Forms.Padding(10, 10, 10, 0)
    $intro.Text = "Cocher ce qui doit partir. Un paquet .zip est préparé dans « donnees\partages », puis le message s'ouvre dans l'application choisie : c'est vous qui choisissez le destinataire et qui envoyez.`r`n`r`nLes journaux peuvent contenir le nom du poste, des adresses IP et la liste des programmes utilisés : ne cochez que ce que vous voulez transmettre."
    if (-not $cfg) { $intro.Text += " Pour joindre une configuration, la sélectionner d'abord dans l'onglet « Configurations enregistrées »." }

    $liste = New-Object System.Windows.Forms.CheckedListBox
    $liste.Dock = 'Fill'
    $liste.CheckOnClick = $true
    $liste.IntegralHeight = $false
    foreach ($e in $elements) {
        $i = $liste.Items.Add($e.Libelle)
        $liste.SetItemChecked($i, [bool]$e.Defaut)
    }

    $barre = New-Object System.Windows.Forms.FlowLayoutPanel
    $barre.Dock = 'Bottom'
    $barre.AutoSize = $true
    $barre.WrapContents = $true
    $barre.Padding = New-Object System.Windows.Forms.Padding(8)
    foreach ($b in @(
        @('mail', 'Courriel (Outlook)...'),
        @('whatsapp', 'WhatsApp...'),
        @('messenger', 'Messenger...'),
        @('copier', 'Copier la synthèse'),
        @('fichier', 'Enregistrer le paquet seulement'),
        @('', 'Fermer')
    )) {
        $bouton = New-Object System.Windows.Forms.Button
        $bouton.Text = $b[1]
        $bouton.Tag = $b[0]
        $bouton.AutoSize = $true
        $bouton.Height = 30
        $bouton.Margin = New-Object System.Windows.Forms.Padding(3)
        $bouton.Add_Click({
            $fenetre = $this.FindForm()
            $fenetre.Tag = [string]$this.Tag
            $fenetre.Close()
        })
        [void]$barre.Controls.Add($bouton)
    }

    [void]$dlg.Controls.Add($liste)
    [void]$dlg.Controls.Add($intro)
    [void]$dlg.Controls.Add($barre)
    if ($script:ModeSombre) {
        $dlg.BackColor = $script:Theme.Fond
        $dlg.ForeColor = $script:Theme.Texte
        foreach ($c in @($dlg.Controls)) { Set-ThemeControle $c }
        $liste.BackColor = $script:Theme.Grille
        $liste.ForeColor = $script:Theme.Texte
    }
    $dlg.Tag = ''
    [void]$dlg.ShowDialog($form)
    $choix = [string]$dlg.Tag
    $cles = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $liste.Items.Count; $i++) {
        if ($liste.GetItemChecked($i)) { [void]$cles.Add([string]$elements[$i].Cle) }
    }
    $dlg.Dispose()
    if (-not $choix) { return }

    if ($choix -eq 'copier') {
        [System.Windows.Forms.Clipboard]::SetText((Get-SyntheseTexte $false))
        $statut.Text = 'Synthèse copiée dans le presse-papiers : la coller (Ctrl+V) dans le message voulu.'
        return
    }
    if ($cles.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Rien n''est coché : aucun paquet préparé.', 'Partager', 'OK', 'Information')
        return
    }
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try { $zip = New-PaquetPartage $cles.ToArray() $cfg }
    finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
    Write-JournalAction ('partage-' + $choix) ([System.IO.Path]::GetFileName($zip)) '' ($cles.ToArray() -join ', ') 'Préparé (envoi par l''utilisateur)'
    if ($choix -eq 'mail') { Send-PartageCourriel $zip }
    elseif ($choix -eq 'whatsapp') { Send-PartageWhatsApp $zip }
    elseif ($choix -eq 'messenger') { Send-PartageMessenger $zip }
    else {
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $zip)
        $statut.Text = ('Paquet enregistré : {0}' -f $zip)
    }
}

# ================================================================ PERIPHERIQUES : USB, BLUETOOTH, WI-FI (version 1.7)
# Inventaire et historique des peripheriques USB et Bluetooth, des claviers et souris, de la carte Wi-Fi,
# du reseau Wi-Fi utilise, des reseaux a portee et des reseaux enregistres ; journal des branchements
# en temps reel ; classement Habituel / Inhabituel / Suspect ; desactivation, oubli d'un reseau,
# blocage des cles USB.

$ClassesPeripheriques = @('DiskDrive', 'WPD', 'Image', 'Camera', 'Media', 'Printer', 'Net', 'Ports', 'SmartCardReader', 'Biometric', 'USBDevice', 'Bluetooth', 'Keyboard', 'Mouse', 'USB', 'Modem')
$LibelleClasse = @{
    'DiskDrive' = 'Disque ou clé USB'; 'WPD' = 'Téléphone ou appareil (MTP)'; 'Image' = 'Scanner ou appareil photo'
    'Camera' = 'Caméra'; 'Media' = 'Audio / vidéo'; 'Printer' = 'Imprimante'; 'Net' = 'Carte réseau'
    'Ports' = 'Port série'; 'SmartCardReader' = 'Lecteur de carte à puce'; 'Biometric' = 'Biométrie'
    'USBDevice' = 'Appareil USB'; 'Bluetooth' = 'Bluetooth'; 'Keyboard' = 'Clavier'; 'Mouse' = 'Souris ou pavé tactile'
    'USB' = 'Appareil USB'; 'Modem' = 'Modem'
}
$script:HistoPer = @{}
$script:HistoWifi = @{}
$script:LignesPer = @()
$script:PresentsPrec = $null
$script:NouveauxPer = New-Object System.Collections.ArrayList
$script:WifiProfils = @()
$script:WifiInterfaces = @()
$script:WifiAPortee = @()
$script:WifiMessage = ''
$script:WifiPrec = $null
$script:CartesWifi = @()
$script:Observateur = $null
$script:PerEnCours = $false

# Observateur des branchements (message Windows WM_DEVICECHANGE) : journal en temps reel
$script:ObservateurDispo = $false
try {
    Add-Type -ReferencedAssemblies 'System.Windows.Forms' -TypeDefinition @'
using System;
using System.Windows.Forms;
public class SmObservateurPeripheriques : NativeWindow {
    public event EventHandler Changement;
    public SmObservateurPeripheriques() { CreateHandle(new CreateParams()); }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0219) {
            EventHandler h = Changement;
            if (h != null) { h(this, EventArgs.Empty); }
        }
        base.WndProc(ref m);
    }
}
'@
    $script:ObservateurDispo = $true
} catch {
    Write-Demarrage ('observation des branchements indisponible : ' + $_.Exception.Message)
}

function Write-JournalPeripheriques([string]$evenement, $p, [string]$detail) {
    try {
        [pscustomobject]@{
            Date        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            Evenement   = $evenement
            Type        = [string]$p.Type
            Nom         = [string]$p.Nom
            Classe      = [string]$p.Classe
            Identifiant = [string]$p.Id
            Detail      = $detail
        } | Export-Csv -LiteralPath $FichierJournalPer -Append -NoTypeInformation -Delimiter ';' -Encoding UTF8
    } catch { Write-Erreur 'Journal des peripheriques' $_ }
}

function ConvertTo-Date([string]$texte) {
    try { return [datetime]::ParseExact($texte, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}

# ---------------------------------------------------------------- USB, Bluetooth, claviers et souris
function Get-TypePeripherique($d) {
    $id = [string]$d.PNPDeviceID
    if ([string]$d.PNPClass -eq 'Bluetooth' -or $id -like 'BTH*') { return 'Bluetooth' }
    if ($id -like 'HID\*') {
        if ($id -match '00001124|00001812|BTH') { return 'Bluetooth' }
        return 'Clavier / souris'
    }
    return 'USB'
}

function Test-PeripheriqueUtile($d) {
    # Ecarte les elements techniques (concentrateurs, controleurs, services Bluetooth...) pour ne garder que les appareils
    $id = [string]$d.PNPDeviceID
    $classe = [string]$d.PNPClass
    $nom = [string]$d.Name
    if (-not $classe -or $ClassesPeripheriques -notcontains $classe) { return $false }
    if ($id -like 'BTHLEDEVICE*' -or $id -like 'BTHENUM\{*' -or $id -like 'BTH\MS_*') { return $false }
    if ($nom -match '(?i)enumerator|énumérateur|hub|concentrateur|root|racine|composite|mass storage|stockage de masse|host controller|contr[oô]leur h[oô]te') { return $false }
    if ($classe -eq 'USB' -and $id -notlike 'USB\VID_*') { return $false }
    return $true
}

function Get-PeripheriquesPresents {
    $filtre = "PNPDeviceID LIKE 'USB%' OR PNPDeviceID LIKE 'BTH%' OR (PNPDeviceID LIKE 'HID%' AND (PNPClass = 'Keyboard' OR PNPClass = 'Mouse'))"
    $res = New-Object System.Collections.ArrayList
    foreach ($d in @(Get-CimInstance -ClassName Win32_PnPEntity -Filter $filtre -ErrorAction Stop)) {
        if (-not (Test-PeripheriqueUtile $d)) { continue }
        [void]$res.Add([pscustomobject]@{
            Id = [string]$d.PNPDeviceID; Nom = [string]$d.Name; Classe = [string]$d.PNPClass
            Fabricant = [string]$d.Manufacturer; Type = (Get-TypePeripherique $d); Code = [int]$d.ConfigManagerErrorCode
        })
    }
    return $res.ToArray()
}

function Update-Peripheriques {
    # Releve des peripheriques presents ; journal des branchements, debranchements et nouveaux appareils
    if ($script:PerEnCours) { return }
    $script:PerEnCours = $true
    try {
        $maintenant = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $presents = @()
        try { $presents = @(Get-PeripheriquesPresents) } catch { Write-Erreur 'Releve des peripheriques' $_; return }
        $apprentissage = ([int]$script:Suivi.Echantillons -lt 12)
        $histoVide = ($script:HistoPer.Count -eq 0)
        $actuels = @{}
        foreach ($d in $presents) {
            $actuels[$d.Id] = $d
            if ($script:HistoPer.ContainsKey($d.Id)) {
                $h = $script:HistoPer[$d.Id]
                $h.DerniereFois = $maintenant
                $h.Nom = $d.Nom
                if ($null -ne $script:PresentsPrec -and -not $script:PresentsPrec.ContainsKey($d.Id)) {
                    $h.Branchements = [string]([int]$h.Branchements + 1)
                    Write-JournalPeripheriques 'Branché' $d ''
                }
            } else {
                $appr = '0'
                if ($apprentissage -or $histoVide) { $appr = '1' }
                $script:HistoPer[$d.Id] = [pscustomobject]@{ Id = $d.Id; Nom = $d.Nom; Type = $d.Type; Classe = $d.Classe; Fabricant = $d.Fabricant; PremiereFois = $maintenant; DerniereFois = $maintenant; Branchements = '1'; Apprentissage = $appr }
                if ($histoVide) {
                    Write-JournalPeripheriques 'État initial' $d ''
                } else {
                    Write-JournalPeripheriques 'Nouveau (jamais vu)' $d ''
                    if ($appr -eq '0') { [void]$script:NouveauxPer.Add($d) }
                }
            }
        }
        if ($null -ne $script:PresentsPrec) {
            foreach ($k in @($script:PresentsPrec.Keys)) {
                if (-not $actuels.ContainsKey($k)) { Write-JournalPeripheriques 'Débranché' $script:PresentsPrec[$k] '' }
            }
        }
        $script:PresentsPrec = $actuels
        try { Export-Table $script:HistoPer $FichierHistoPer 'Id' } catch { Write-Erreur 'Historique des peripheriques' $_ }
    } finally {
        $script:PerEnCours = $false
    }
}

function Get-EtatPeripherique($l) {
    if ($script:Approuves.ContainsKey('dev|' + $l.Ident)) { return (New-Etat 'Habituel' 'Déclaré habituel par l''utilisateur') }
    $h = $null
    if ($script:HistoPer.ContainsKey($l.Ident)) { $h = $script:HistoPer[$l.Ident] }
    $nouveau = $false
    $premiere = $null
    if ($h -and [string]$h.Apprentissage -ne '1') {
        $premiere = ConvertTo-Date ([string]$h.PremiereFois)
        if ($premiere -and ((Get-Date) - $premiere).TotalDays -lt 7) { $nouveau = $true }
    }
    if ($nouveau -and $l.Classe -eq 'Keyboard' -and $l.Type -ne 'Bluetooth') {
        return (New-Etat 'Suspect' ('Nouveau clavier branché le {0} : vérifier qu''il s''agit bien d''un clavier (certaines clés USB malveillantes se font passer pour un clavier afin de taper des commandes)' -f $premiere.ToString('dd/MM à HH:mm')))
    }
    if ($l.Present -and $l.Code -ne 0 -and $l.Code -ne 22) { return (New-Etat 'Inhabituel' ('Périphérique en erreur (code {0})' -f $l.Code)) }
    if ($nouveau) { return (New-Etat 'Inhabituel' ('Branché pour la première fois le {0}' -f $premiere.ToString('dd/MM à HH:mm'))) }
    if ([int]$script:Suivi.Echantillons -lt 12 -and $h -and [string]$h.Apprentissage -eq '1') { return (New-Etat 'Apprentissage' 'Première heure de relevés') }
    return (New-Etat 'Habituel' '')
}

function Test-RadioBluetooth($l) {
    return ($l.Genre -eq 'pnp' -and $l.Classe -eq 'Bluetooth' -and $l.Ident -notlike 'BTH*')
}

# ---------------------------------------------------------------- Wi-Fi
function Invoke-Netsh([string[]]$arguments) {
    # Sans fenetre de console : indispensable pour la version compilee (.exe), sinon une fenetre s'ouvre a chaque releve
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'netsh.exe'
        $psi.Arguments = (@($arguments | ForEach-Object { if ([string]$_ -match '\s') { '"' + [string]$_ + '"' } else { [string]$_ } }) -join ' ')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
        $p = [System.Diagnostics.Process]::Start($psi)
        $sortie = $p.StandardOutput.ReadToEnd()
        [void]$p.WaitForExit(15000)
        return @($sortie -split "`r?`n")
    } catch { return @() }
}

function Get-WifiInterfaces {
    $res = New-Object System.Collections.ArrayList
    $cur = $null
    foreach ($ligne in (Invoke-Netsh @('wlan', 'show', 'interfaces'))) {
        if ([string]$ligne -notmatch '^\s{2,}(.+?)\s+:\s(.*)$') { continue }
        $cle = $matches[1].Trim().ToLower()
        $val = $matches[2].Trim()
        if ($cle -match '^(name|nom)$') {
            $cur = [pscustomobject]@{ Nom = $val; Description = ''; Etat = ''; SSID = ''; BSSID = ''; Radio = ''; Auth = ''; Chiffrement = ''; Canal = ''; Signal = ''; Profil = '' }
            [void]$res.Add($cur)
            continue
        }
        if (-not $cur) { continue }
        if ($cle -eq 'description') { $cur.Description = $val }
        elseif ($cle -match '(state|tat)$') { $cur.Etat = $val }
        elseif ($cle -eq 'ssid') { $cur.SSID = $val }
        elseif ($cle -eq 'bssid') { $cur.BSSID = $val }
        elseif ($cle -match 'radio') { $cur.Radio = $val }
        elseif ($cle -match '^authenti') { $cur.Auth = $val }
        elseif ($cle -match '^(cipher|chiffrement)$') { $cur.Chiffrement = $val }
        elseif ($cle -match '^(channel|canal)$') { $cur.Canal = $val }
        elseif ($cle -match '^signal$') { $cur.Signal = $val }
        elseif ($cle -match '^(profile|profil)$') { $cur.Profil = $val }
    }
    return $res.ToArray()
}

function Get-WifiAPortee {
    $res = New-Object System.Collections.ArrayList
    $cur = $null
    $lignes = Invoke-Netsh @('wlan', 'show', 'networks', 'mode=bssid')
    foreach ($ligne in $lignes) {
        $ligne = [string]$ligne
        if ($ligne -match '^SSID\s+\d+\s*:\s?(.*)$') {
            $nom = $matches[1].Trim()
            if (-not $nom) { $nom = '(réseau masqué)' }
            $cur = [pscustomobject]@{ SSID = $nom; Auth = ''; Chiffrement = ''; Signal = 0; NbBssid = 0; Canaux = '' }
            [void]$res.Add($cur)
            continue
        }
        if (-not $cur) { continue }
        if ($ligne -match '^\s+(.+?)\s+:\s(.*)$') {
            $cle = $matches[1].Trim().ToLower()
            $val = $matches[2].Trim()
            if ($cle -match '^authenti') { $cur.Auth = $val }
            elseif ($cle -match '^(cipher|chiffrement|encryption)$') { $cur.Chiffrement = $val }
            elseif ($cle -match '^bssid') { $cur.NbBssid = [int]$cur.NbBssid + 1 }
            elseif ($cle -match '^signal$') {
                $s = 0
                if ($val -match '(\d+)') { $s = [int]$matches[1] }
                if ($s -gt [int]$cur.Signal) { $cur.Signal = $s }
            } elseif ($cle -match '^(channel|canal)$') {
                if (-not $cur.Canaux) { $cur.Canaux = $val }
                elseif (@($cur.Canaux -split ', ') -notcontains $val) { $cur.Canaux = $cur.Canaux + ', ' + $val }
            }
        }
    }
    $script:WifiMessage = ''
    if ($res.Count -eq 0 -and @($script:CartesWifi | Where-Object { [string]$_.Status -ne 'Disabled' }).Count -gt 0) {
        $script:WifiMessage = 'liste des réseaux à portée indisponible (Windows peut exiger l''autorisation de localisation pour cette liste)'
    }
    return $res.ToArray()
}

function Get-WifiProfils {
    # Export des profils sans les mots de passe (key=absent), puis lecture du XML (independant de la langue)
    $dossier = Join-Path ([System.IO.Path]::GetTempPath()) ('sm-wifi-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dossier -Force | Out-Null
    $res = New-Object System.Collections.ArrayList
    $vus = @{}
    try {
        [void](Invoke-Netsh @('wlan', 'export', 'profile', ('folder=' + $dossier), 'key=absent'))
        foreach ($f in @(Get-ChildItem -LiteralPath $dossier -Filter '*.xml' -File)) {
            try {
                [xml]$x = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
                $p = $x.WLANProfile
                $nomProfil = [string]$p.name
                if (-not $nomProfil -or $vus.ContainsKey($nomProfil)) { continue }
                $vus[$nomProfil] = $true
                $ssid = [string]$p.SSIDConfig.SSID.name
                if (-not $ssid) { $ssid = $nomProfil }
                $auth = ''
                $enc = ''
                try {
                    $auth = [string]$p.MSM.security.authEncryption.authentication
                    $enc = [string]$p.MSM.security.authEncryption.encryption
                } catch { }
                [void]$res.Add([pscustomobject]@{ Profil = $nomProfil; SSID = $ssid; Auth = $auth; Chiffrement = $enc; Auto = ([string]$p.connectionMode -eq 'auto') })
            } catch { }
        }
    } finally {
        Remove-Item -LiteralPath $dossier -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $res.ToArray()
}

function Get-NiveauSecuriteWifi([string]$auth, [string]$enc) {
    $a = $auth.ToLower()
    $e = $enc.ToLower()
    if ($a -match 'owe') { return 'Fort (Enhanced Open)' }
    if ($a -match 'open|ouvert' -and ($e -match 'none|aucun' -or -not $e)) { return 'Ouvert (sans mot de passe)' }
    if ($e -match 'wep' -or $a -match 'shared|partag') { return 'Faible (WEP)' }
    if ($e -match 'tkip' -or $a -match '^wpa(psk)?$' -or $a -match '^wpa\s*-\s*pers') { return 'Faible (WPA / TKIP)' }
    if ($a -match 'wpa3|sae') { return 'Fort (WPA3)' }
    if ($a -match 'wpa2') { return 'Correct (WPA2)' }
    if (-not $a) { return '' }
    return $auth
}

function Add-HistoWifi([string]$cle, [string]$ssid, [string]$secu, [string]$maintenant, [bool]$appr) {
    if ($script:HistoWifi.ContainsKey($cle)) {
        $h = $script:HistoWifi[$cle]
        $h.Observations = [string]([int]$h.Observations + 1)
        $h.DerniereFois = $maintenant
        $h.Securite = $secu
        return $false
    }
    $a = '0'
    if ($appr) { $a = '1' }
    $script:HistoWifi[$cle] = [pscustomobject]@{ Cle = $cle; SSID = $ssid; Securite = $secu; Observations = '1'; PremiereFois = $maintenant; DerniereFois = $maintenant; Apprentissage = $a }
    return $true
}

function Update-Wifi([bool]$profils) {
    $maintenant = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    try { $script:CartesWifi = @(Get-NetAdapter -ErrorAction Stop | Where-Object { [string]$_.PhysicalMediaType -match '802\.11' -or [string]$_.NdisPhysicalMedium -eq '9' }) } catch { $script:CartesWifi = @() }
    try { $script:WifiInterfaces = @(Get-WifiInterfaces) } catch { Write-Erreur 'Wi-Fi (interfaces)' $_ }
    try { $script:WifiAPortee = @(Get-WifiAPortee) } catch { Write-Erreur 'Wi-Fi (reseaux a portee)' $_ }
    if ($profils -or @($script:WifiProfils).Count -eq 0) {
        try { $script:WifiProfils = @(Get-WifiProfils) } catch { Write-Erreur 'Wi-Fi (profils)' $_ }
    }
    $appr = ([int]$script:Suivi.Echantillons -lt 12 -or $script:HistoWifi.Count -eq 0)
    $connectes = @{}
    foreach ($i in @($script:WifiInterfaces | Where-Object { $_.SSID })) {
        $connectes[[string]$i.SSID] = $true
        $secu = Get-NiveauSecuriteWifi $i.Auth $i.Chiffrement
        $nouveau = Add-HistoWifi ('connecte|' + $i.SSID) $i.SSID $secu $maintenant $appr
        if ($nouveau -and -not $appr) {
            Write-JournalPeripheriques 'Première connexion Wi-Fi' ([pscustomobject]@{ Type = 'Wi-Fi'; Nom = $i.SSID; Classe = ''; Id = $i.BSSID }) $secu
        }
    }
    if ($null -ne $script:WifiPrec) {
        foreach ($s in @($connectes.Keys)) {
            if (-not $script:WifiPrec.ContainsKey($s)) { Write-JournalPeripheriques 'Connexion Wi-Fi' ([pscustomobject]@{ Type = 'Wi-Fi'; Nom = $s; Classe = ''; Id = '' }) '' }
        }
        foreach ($s in @($script:WifiPrec.Keys)) {
            if (-not $connectes.ContainsKey($s)) { Write-JournalPeripheriques 'Déconnexion Wi-Fi' ([pscustomobject]@{ Type = 'Wi-Fi'; Nom = $s; Classe = ''; Id = '' }) '' }
        }
    }
    $script:WifiPrec = $connectes
    foreach ($n in @($script:WifiAPortee)) {
        [void](Add-HistoWifi ('portee|' + $n.SSID) $n.SSID (Get-NiveauSecuriteWifi $n.Auth $n.Chiffrement) $maintenant $appr)
    }
    try { Export-Table $script:HistoWifi $FichierHistoWifi 'Cle' } catch { Write-Erreur 'Historique Wi-Fi' $_ }
}

function Get-EtatHistoWifi([string]$cle, [string]$texteNouveau) {
    $h = $null
    if ($script:HistoWifi.ContainsKey($cle)) { $h = $script:HistoWifi[$cle] }
    $appr = ([int]$script:Suivi.Echantillons -lt 12)
    if (-not $h) {
        if ($appr) { return (New-Etat 'Apprentissage' 'Première heure de relevés') }
        return (New-Etat 'Inhabituel' $texteNouveau)
    }
    if ([string]$h.Apprentissage -eq '1') {
        if ($appr) { return (New-Etat 'Apprentissage' 'Première heure de relevés') }
        return (New-Etat 'Habituel' '')
    }
    $premiere = ConvertTo-Date ([string]$h.PremiereFois)
    if ($premiere -and ((Get-Date) - $premiere).TotalDays -lt 7) {
        return (New-Etat 'Inhabituel' ('{0} (vu pour la première fois le {1})' -f $texteNouveau, $premiere.ToString('dd/MM à HH:mm')))
    }
    return (New-Etat 'Habituel' '')
}

# ---------------------------------------------------------------- Lignes de l'onglet Peripheriques
function New-LignePer([string]$genre, [string]$type, [string]$nom) {
    return [pscustomobject]@{
        Genre = $genre; Type = $type; Nom = $nom; Etat = ''; Habitude = ''; Motif = ''; Securite = ''; Detail = ''
        Premiere = ''; Derniere = ''; Note = ''; Ident = ''; Classe = ''; Code = 0; Present = $true; Alias = ''; Profil = ''; SSID = ''
    }
}

function Update-LignesPeripheriques {
    $lignes = New-Object System.Collections.ArrayList
    $presents = @{}
    if ($script:PresentsPrec) { $presents = $script:PresentsPrec }

    foreach ($h in @($script:HistoPer.Values)) {
        $p = $null
        if ($presents.ContainsKey([string]$h.Id)) { $p = $presents[[string]$h.Id] }
        $l = New-LignePer 'pnp' ([string]$h.Type) ([string]$h.Nom)
        $l.Ident = [string]$h.Id
        $l.Classe = [string]$h.Classe
        $l.Present = ($null -ne $p)
        $l.Premiere = [string]$h.PremiereFois
        $l.Derniere = [string]$h.DerniereFois
        $libelle = [string]$h.Classe
        if ($LibelleClasse.ContainsKey($libelle)) { $libelle = $LibelleClasse[$libelle] }
        $l.Detail = $libelle
        if ([string]$h.Fabricant -and [string]$h.Fabricant -notmatch '^\(') { $l.Detail = '{0} - {1}' -f $libelle, $h.Fabricant }
        $estAssocie = ($l.Ident -like 'BTHENUM\DEV_*' -or $l.Ident -like 'BTHLE\DEV_*')
        if ($p) {
            $l.Code = [int]$p.Code
            if ($l.Code -eq 22) { $l.Etat = 'Désactivé' }
            elseif ($l.Code -ne 0) { $l.Etat = 'En erreur (code {0})' -f $l.Code }
            elseif ($estAssocie) { $l.Etat = 'Associé' }
            else { $l.Etat = 'Branché' }
        } elseif ($estAssocie) {
            $l.Etat = 'Plus associé'
        } else {
            $l.Etat = 'Débranché'
        }
        if (Test-RadioBluetooth $l) {
            $l.Detail = 'Adaptateur Bluetooth (radio)'
            $l.Note = 'Le désactiver coupe tout le Bluetooth (souris, casque, téléphone...).'
        } elseif ($l.Classe -eq 'DiskDrive') {
            $l.Note = 'Stockage amovible : l''éjecter proprement avant de le débrancher.'
        } elseif ($l.Classe -eq 'Keyboard' -or $l.Classe -eq 'Mouse') {
            $l.Note = 'Clavier ou souris : non désactivable ici, pour ne pas perdre la saisie.'
        }
        $e = Get-EtatPeripherique $l
        $l.Habitude = $e.Etat
        $l.Motif = $e.Motif
        [void]$lignes.Add($l)
    }

    $profilsParSsid = @{}
    foreach ($pr in @($script:WifiProfils)) { $profilsParSsid[[string]$pr.SSID] = $pr }
    $connectes = @{}
    foreach ($i in @($script:WifiInterfaces | Where-Object { $_.SSID })) { $connectes[[string]$i.SSID] = $i }
    $aPortee = @{}
    foreach ($n in @($script:WifiAPortee)) { $aPortee[[string]$n.SSID] = $n }

    foreach ($c in @($script:CartesWifi)) {
        $l = New-LignePer 'carte' 'Wi-Fi' ([string]$c.InterfaceDescription)
        $statutCarte = [string]$c.Status
        if ($statutCarte -eq 'Up') { $l.Etat = 'Connectée' }
        elseif ($statutCarte -eq 'Disabled') { $l.Etat = 'Désactivée (Wi-Fi coupé)' }
        else { $l.Etat = 'Activée, non connectée' }
        $l.Ident = [string]$c.Name
        $l.Alias = [string]$c.Name
        $l.Detail = 'Carte Wi-Fi « {0} »' -f $c.Name
        $l.Habitude = 'Habituel'
        $l.Note = 'La désactiver coupe le Wi-Fi ; la réactiver le rétablit.'
        [void]$lignes.Add($l)
    }

    foreach ($i in @($script:WifiInterfaces | Where-Object { $_.SSID })) {
        $l = New-LignePer 'wifi-connecte' 'Wi-Fi' ([string]$i.SSID)
        $niveau = Get-NiveauSecuriteWifi $i.Auth $i.Chiffrement
        $l.SSID = [string]$i.SSID
        $l.Ident = [string]$i.SSID
        $l.Etat = 'Connecté'
        $l.Securite = '{0} - {1} / {2}' -f $niveau, $i.Auth, $i.Chiffrement
        $l.Detail = 'Signal {0}, canal {1}, {2}, point d''accès {3}' -f $i.Signal, $i.Canal, $i.Radio, $i.BSSID
        $h = $null
        if ($script:HistoWifi.ContainsKey('connecte|' + $i.SSID)) { $h = $script:HistoWifi['connecte|' + $i.SSID] }
        if ($h) { $l.Premiere = [string]$h.PremiereFois; $l.Derniere = [string]$h.DerniereFois }
        if ($script:Approuves.ContainsKey('wifi|' + $i.SSID)) {
            $e = New-Etat 'Habituel' 'Déclaré habituel par l''utilisateur'
        } elseif ($niveau -like 'Ouvert*') {
            $e = New-Etat 'Inhabituel' 'Réseau sans mot de passe : ce qui n''est pas chiffré (sites en http, partages) peut être lu par les autres personnes connectées'
        } elseif ($niveau -like 'Faible*') {
            $e = New-Etat 'Inhabituel' 'Sécurité obsolète : passer la box en WPA2 ou WPA3'
        } else {
            $e = Get-EtatHistoWifi ('connecte|' + $i.SSID) 'Première connexion à ce réseau'
        }
        $l.Habitude = $e.Etat
        $l.Motif = $e.Motif
        [void]$lignes.Add($l)
    }

    foreach ($pr in @($script:WifiProfils)) {
        $l = New-LignePer 'wifi-profil' 'Wi-Fi enregistré' ([string]$pr.SSID)
        $niveau = Get-NiveauSecuriteWifi $pr.Auth $pr.Chiffrement
        $l.SSID = [string]$pr.SSID
        $l.Ident = [string]$pr.SSID
        $l.Profil = [string]$pr.Profil
        $l.Securite = '{0} - {1} / {2}' -f $niveau, $pr.Auth, $pr.Chiffrement
        if ($pr.Auto) { $l.Detail = 'Connexion automatique' } else { $l.Detail = 'Connexion manuelle' }
        if ($connectes.ContainsKey([string]$pr.SSID)) { $l.Etat = 'Enregistré, connecté' }
        elseif ($aPortee.ContainsKey([string]$pr.SSID)) { $l.Etat = 'Enregistré, à portée' }
        else { $l.Etat = 'Enregistré' }
        $h = $null
        if ($script:HistoWifi.ContainsKey('connecte|' + $pr.SSID)) { $h = $script:HistoWifi['connecte|' + $pr.SSID] }
        if ($h) { $l.Premiere = [string]$h.PremiereFois; $l.Derniere = [string]$h.DerniereFois }
        if ($script:Approuves.ContainsKey('wifi|' + $pr.SSID)) {
            $e = New-Etat 'Habituel' 'Déclaré habituel par l''utilisateur'
        } elseif ($niveau -like 'Ouvert*' -and $pr.Auto) {
            $e = New-Etat 'Suspect' 'Réseau ouvert enregistré en connexion automatique : n''importe quel point d''accès portant ce nom peut capter le poste. L''oublier, ou passer en connexion manuelle'
        } elseif ($niveau -like 'Faible*') {
            $e = New-Etat 'Inhabituel' 'Sécurité obsolète : ce réseau peut être déchiffré ; l''oublier s''il ne sert plus'
        } else {
            $e = New-Etat 'Habituel' ''
        }
        $l.Habitude = $e.Etat
        $l.Motif = $e.Motif
        $l.Note = 'Le mot de passe n''est pas lu par Service Minimum.'
        [void]$lignes.Add($l)
    }

    foreach ($n in @($script:WifiAPortee)) {
        if ($connectes.ContainsKey([string]$n.SSID)) { continue }
        $l = New-LignePer 'wifi-portee' 'Wi-Fi à portée' ([string]$n.SSID)
        $niveau = Get-NiveauSecuriteWifi $n.Auth $n.Chiffrement
        $l.SSID = [string]$n.SSID
        $l.Ident = [string]$n.SSID
        $l.Etat = 'À portée'
        $l.Securite = '{0} - {1} / {2}' -f $niveau, $n.Auth, $n.Chiffrement
        $l.Detail = 'Signal {0} %, canal {1}, {2} point(s) d''accès' -f $n.Signal, $n.Canaux, $n.NbBssid
        $h = $null
        if ($script:HistoWifi.ContainsKey('portee|' + $n.SSID)) { $h = $script:HistoWifi['portee|' + $n.SSID] }
        if ($h) { $l.Premiere = [string]$h.PremiereFois; $l.Derniere = [string]$h.DerniereFois }
        $enregistre = $null
        if ($profilsParSsid.ContainsKey([string]$n.SSID)) { $enregistre = $profilsParSsid[[string]$n.SSID] }
        $niveauEnregistre = ''
        if ($enregistre) { $niveauEnregistre = Get-NiveauSecuriteWifi $enregistre.Auth $enregistre.Chiffrement }
        if ($script:Approuves.ContainsKey('wifi|' + $n.SSID)) {
            $e = New-Etat 'Habituel' 'Déclaré habituel par l''utilisateur'
        } elseif ($enregistre -and $niveauEnregistre -and $niveau -and $niveau -ne $niveauEnregistre -and ($niveau -like 'Ouvert*' -or $niveau -like 'Faible*')) {
            $e = New-Etat 'Suspect' ('Ce réseau porte le nom d''un réseau enregistré ({0}) mais avec une sécurité plus faible ({1}) : possible faux point d''accès. Ne pas s''y connecter' -f $niveauEnregistre, $niveau)
        } elseif ($enregistre) {
            $e = New-Etat 'Habituel' ''
        } else {
            $e = Get-EtatHistoWifi ('portee|' + $n.SSID) 'Nouveau réseau à portée'
        }
        $l.Habitude = $e.Etat
        $l.Motif = $e.Motif
        [void]$lignes.Add($l)
    }
    $script:LignesPer = $lignes.ToArray()
}

function Add-AnomaliesPeripheriques($anos) {
    foreach ($l in @($script:LignesPer)) {
        if ($l.Genre -eq 'pnp' -and -not $l.Present) { continue }
        if ($l.Habitude -eq 'Suspect') {
            Add-Anomalie $anos 'Élevée' $l.Nom '' ($l.Type + ' - ' + $l.Motif) 0 'Onglet « Périphériques » : vérifier, puis « Déclarer habituel » si c''est connu ; sinon désactiver le périphérique ou oublier le réseau.' ('per|suspect|' + $l.Ident)
        } elseif ($l.Genre -eq 'pnp' -and $l.Etat -like 'En erreur*') {
            Add-Anomalie $anos 'Moyenne' $l.Nom '' ($l.Type + ' - ' + $l.Motif) 0 'Débrancher et rebrancher, ou mettre à jour son pilote ; s''il ne sert pas, le désactiver.' ('per|erreur|' + $l.Ident)
        } elseif ($l.Genre -eq 'pnp' -and $l.Habitude -eq 'Inhabituel') {
            Add-Anomalie $anos 'Faible' $l.Nom '' ($l.Type + ' - ' + $l.Motif) 0 'Normal si vous venez de le brancher ; sinon vérifier de quoi il s''agit.' ('per|nouveau|' + $l.Ident)
        } elseif ($l.Genre -eq 'wifi-connecte' -and $l.Habitude -eq 'Inhabituel') {
            Add-Anomalie $anos 'Faible' $l.Nom '' ('Wi-Fi - ' + $l.Motif) 0 'Éviter les échanges sensibles sur ce réseau, ou utiliser un VPN.' ('per|wifi|' + $l.Ident)
        }
    }
}

function Send-AlerteNouveauxPeripheriques {
    $nouveaux = @($script:NouveauxPer)
    $script:NouveauxPer = New-Object System.Collections.ArrayList
    if (-not $script:Icone -or $nouveaux.Count -eq 0) { return }
    $texte = (@($nouveaux | Select-Object -First 3 | ForEach-Object { '{0} : {1}' -f $_.Type, $_.Nom }) -join "`r`n")
    if ($nouveaux.Count -gt 3) { $texte += "`r`n... et {0} autre(s)" -f ($nouveaux.Count - 3) }
    $icone = [System.Windows.Forms.ToolTipIcon]::Info
    if (@($nouveaux | Where-Object { $_.Classe -eq 'Keyboard' -and $_.Type -ne 'Bluetooth' }).Count -gt 0) {
        $texte += "`r`nNouveau clavier : vérifiez qu'il s'agit bien d'un clavier."
        $icone = [System.Windows.Forms.ToolTipIcon]::Warning
    }
    if ($texte.Length -gt 250) { $texte = $texte.Substring(0, 250) + '...' }
    try { $script:Icone.ShowBalloonTip(8000, 'Service Minimum - nouveau périphérique', $texte, $icone) } catch { }
}

function Start-ObservateurPeripheriques {
    if ($script:Observateur -or -not $script:ObservateurDispo) { return }
    try {
        $script:Observateur = New-Object SmObservateurPeripheriques
        $script:Observateur.add_Changement({
            # Les messages arrivent en rafale : on attend deux secondes de calme avant de relever
            try { $minuteurPer.Stop(); $minuteurPer.Start() } catch { }
        })
    } catch {
        Write-Erreur 'Observateur des peripheriques' $_
        $script:Observateur = $null
    }
}

# ---------------------------------------------------------------- Affichage et actions
function Show-Peripheriques {
    $vue = [string]$cmbPer.SelectedItem
    $lignes = @($script:LignesPer)
    if (-not $chkDebranches.Checked) { $lignes = @($lignes | Where-Object { $_.Genre -ne 'pnp' -or $_.Present }) }
    if ($vue -like 'USB*') { $lignes = @($lignes | Where-Object { $_.Genre -eq 'pnp' -and $_.Type -ne 'Bluetooth' }) }
    elseif ($vue -eq 'Bluetooth') { $lignes = @($lignes | Where-Object { $_.Type -eq 'Bluetooth' }) }
    elseif ($vue -like 'Wi-Fi (*') { $lignes = @($lignes | Where-Object { $_.Genre -eq 'carte' -or $_.Genre -eq 'wifi-connecte' -or $_.Genre -eq 'wifi-portee' }) }
    elseif ($vue -like 'Wi-Fi enregistr*') { $lignes = @($lignes | Where-Object { $_.Genre -eq 'wifi-profil' }) }
    if ($cmbEtatPer.SelectedIndex -gt 0) {
        $filtre = [string]$cmbEtatPer.SelectedItem
        $lignes = @($lignes | Where-Object { $_.Habitude -eq $filtre })
    }
    $ordre = @{ 'Suspect' = 1; 'Inhabituel' = 2; 'Apprentissage' = 3; 'Habituel' = 4 }
    $ordreGenre = @{ 'carte' = 1; 'wifi-connecte' = 2; 'pnp' = 3; 'wifi-profil' = 4; 'wifi-portee' = 5 }
    $tri = @({ $ordre[$_.Habitude] }, { $ordreGenre[$_.Genre] }, 'Type', 'Nom')
    $lignes = @($lignes | Sort-Object -Property $tri)
    $gridPer.Rows.Clear()
    foreach ($l in $lignes) {
        $note = [string]$l.Note
        if ($l.Motif -and $l.Habitude -ne 'Apprentissage') {
            if ($note) { $note = '{0} : {1}. {2}' -f $l.Habitude, $l.Motif, $note } else { $note = '{0} : {1}' -f $l.Habitude, $l.Motif }
        }
        $i = $gridPer.Rows.Add($l.Type, $l.Nom, $l.Etat, $l.Habitude, $l.Securite, $l.Detail, $l.Premiere, $l.Derniere, $note)
        $row = $gridPer.Rows[$i]
        $row.Tag = $l
        $row.Cells['Nom'].ToolTipText = [string]$l.Ident
        $row.Cells['Habitude'].ToolTipText = [string]$l.Motif
        if ($l.Habitude -eq 'Suspect') { $row.Cells['Habitude'].Style.BackColor = $CouleursTag['critique'][0] }
        elseif ($l.Habitude -eq 'Inhabituel') { $row.Cells['Habitude'].Style.BackColor = $CouleursTag['attention'][0] }
        elseif ($l.Habitude -eq 'Habituel') { $row.Cells['Habitude'].Style.BackColor = $CouleursTag['ok'][0] }
        else { $row.Cells['Habitude'].Style.BackColor = $CouleursTag['neutre'][0] }
        if ($l.Securite -like 'Ouvert*' -or $l.Securite -like 'Faible*') { $row.Cells['Securite'].Style.BackColor = $CouleursTag['attention'][0] }
        if ($l.Etat -like 'Désactiv*' -or $l.Etat -like 'En erreur*') { $row.Cells['Etat'].Style.BackColor = $CouleursTag['attention'][0] }
    }
    $gridPer.ClearSelection()
    $aVoir = @($script:LignesPer | Where-Object { ($_.Habitude -eq 'Suspect') -or ($_.Habitude -eq 'Inhabituel' -and $_.Genre -ne 'wifi-portee' -and ($_.Genre -ne 'pnp' -or $_.Present)) }).Count
    if ($aVoir -gt 0) { $pagePer.Text = 'Périphériques ({0} à voir)' -f $aVoir } else { $pagePer.Text = 'Périphériques' }
    $nbPresents = @($script:LignesPer | Where-Object { $_.Genre -eq 'pnp' -and $_.Present }).Count
    $wifi = 'non connecté'
    $c = @($script:LignesPer | Where-Object { $_.Genre -eq 'wifi-connecte' })
    if ($c.Count -gt 0) { $wifi = 'connecté à ' + $c[0].Nom }
    if (@($script:CartesWifi | Where-Object { [string]$_.Status -eq 'Disabled' }).Count -gt 0) { $wifi = 'coupé' }
    $usbBloque = Test-StockageUsbBloque
    $texteUsb = 'autorisées'
    if ($usbBloque) { $texteUsb = 'bloquées' }
    $lblPer.Text = '{0} périphérique(s) branché(s) ou associé(s) - Wi-Fi : {1} - {2} réseau(x) à portée - {3} réseau(x) enregistré(s) - clés USB : {4}' -f $nbPresents, $wifi, @($script:WifiAPortee).Count, @($script:WifiProfils).Count, $texteUsb
    if ($script:WifiMessage) { $lblPer.Text += ' - ' + $script:WifiMessage }
    if (@($script:CartesWifi | Where-Object { [string]$_.Status -eq 'Disabled' }).Count -gt 0) { $btnPerWifi.Text = 'Rétablir le Wi-Fi' } else { $btnPerWifi.Text = 'Couper le Wi-Fi...' }
    $radio = @($script:LignesPer | Where-Object { (Test-RadioBluetooth $_) -and $_.Present })
    if ($radio.Count -gt 0 -and $radio[0].Code -eq 22) { $btnPerBluetooth.Text = 'Rétablir le Bluetooth' } else { $btnPerBluetooth.Text = 'Couper le Bluetooth...' }
    $btnPerBluetooth.Enabled = ($EstAdmin -and $radio.Count -gt 0)
    $btnPerWifi.Enabled = ($EstAdmin -and @($script:CartesWifi).Count -gt 0)
    if ($usbBloque) { $btnPerUsb.Text = 'Débloquer les clés USB' } else { $btnPerUsb.Text = 'Bloquer les clés USB...' }
}

function Update-OngletPeripheriques([bool]$profils) {
    try { Update-Peripheriques } catch { Write-Erreur 'Update-Peripheriques' $_ }
    try { Update-Wifi $profils } catch { Write-Erreur 'Update-Wifi' $_ }
    try { Update-LignesPeripheriques } catch { Write-Erreur 'Update-LignesPeripheriques' $_ }
    try { Show-Peripheriques } catch { Write-Erreur 'Show-Peripheriques' $_ }
}

function Test-StockageUsbBloque {
    try { return ([int](Get-ItemPropertyValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR' -Name 'Start' -ErrorAction Stop) -eq 4) } catch { return $false }
}

function Set-StockageUsb([bool]$bloquer) {
    # USBSTOR (cles et disques classiques) et UASPStor (disques USB rapides) ; 3 = valeur d'origine de Windows
    $valeur = 3
    if ($bloquer) { $valeur = 4 }
    foreach ($pilote in @('USBSTOR', 'UASPStor')) {
        $cle = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $pilote
        if (-not (Test-Path -LiteralPath $cle)) { continue }
        Set-ItemProperty -LiteralPath $cle -Name 'Start' -Value $valeur -ErrorAction Stop
    }
}

function Get-LignePer {
    if ($gridPer.SelectedRows.Count -eq 0 -or -not $gridPer.SelectedRows[0].Tag) {
        [void][System.Windows.Forms.MessageBox]::Show('Cliquer d''abord sur une ligne de la liste.', 'Service Minimum', 'OK', 'Information')
        return $null
    }
    return $gridPer.SelectedRows[0].Tag
}

function Set-EtatPeripherique($l, [bool]$activer) {
    # Desactive ou reactive un peripherique (USB, Bluetooth) ou une carte Wi-Fi. Retourne $true si fait.
    if (-not $EstAdmin) {
        [void][System.Windows.Forms.MessageBox]::Show('Lecture seule : relancer Service Minimum en administrateur.', 'Service Minimum', 'OK', 'Information')
        return $false
    }
    if ($l.Genre -eq 'carte') {
        $coupee = ($l.Etat -like 'Désactiv*')
        if ($activer -and -not $coupee) { [void][System.Windows.Forms.MessageBox]::Show('Cette carte Wi-Fi est déjà active.', 'Service Minimum', 'OK', 'Information'); return $false }
        if (-not $activer -and $coupee) { [void][System.Windows.Forms.MessageBox]::Show('Cette carte Wi-Fi est déjà désactivée.', 'Service Minimum', 'OK', 'Information'); return $false }
        if (-not $activer) {
            $texte = "Couper le Wi-Fi (désactiver la carte « {0} ») ?" -f $l.Nom
            if ($l.Etat -eq 'Connectée') { $texte += "`r`n`r`nATTENTION : le poste est connecté par ce Wi-Fi. La connexion Internet sera coupée, ainsi que toute prise en main à distance, jusqu'à ce que le Wi-Fi soit rétabli sur ce poste." }
            $texte += "`r`n`r`nRéversible avec « Rétablir le Wi-Fi »."
            if ([System.Windows.Forms.MessageBox]::Show($texte, 'Couper le Wi-Fi', 'YesNo', 'Warning') -ne 'Yes') { return $false }
        }
        try {
            if ($activer) { Enable-NetAdapter -Name $l.Alias -Confirm:$false -ErrorAction Stop } else { Disable-NetAdapter -Name $l.Alias -Confirm:$false -ErrorAction Stop }
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
            return $false
        }
        $evt = 'Wi-Fi coupé'
        if ($activer) { $evt = 'Wi-Fi rétabli' }
        Write-JournalPeripheriques $evt ([pscustomobject]@{ Type = 'Wi-Fi'; Nom = $l.Nom; Classe = 'Net'; Id = $l.Alias }) ''
        Write-JournalAction $evt $l.Nom '' '' 'OK'
        return $true
    }
    if ($l.Genre -ne 'pnp') {
        [void][System.Windows.Forms.MessageBox]::Show('Pour un réseau Wi-Fi enregistré : « Oublier ce réseau Wi-Fi... ». Pour couper le Wi-Fi : « Couper le Wi-Fi... ».', 'Service Minimum', 'OK', 'Information')
        return $false
    }
    if (-not $l.Present) {
        [void][System.Windows.Forms.MessageBox]::Show('Ce périphérique n''est pas branché en ce moment.', 'Service Minimum', 'OK', 'Information')
        return $false
    }
    if (-not $activer -and ($l.Classe -eq 'Keyboard' -or $l.Classe -eq 'Mouse')) {
        [void][System.Windows.Forms.MessageBox]::Show('Un clavier ou une souris n''est pas désactivé ici, pour ne pas risquer de perdre la saisie. Pour un clavier ou une souris suspect, le débrancher.', 'Service Minimum', 'OK', 'Warning')
        return $false
    }
    if ($activer -and $l.Code -ne 22) { [void][System.Windows.Forms.MessageBox]::Show('Ce périphérique n''est pas désactivé.', 'Service Minimum', 'OK', 'Information'); return $false }
    if (-not $activer -and $l.Code -eq 22) { [void][System.Windows.Forms.MessageBox]::Show('Ce périphérique est déjà désactivé.', 'Service Minimum', 'OK', 'Information'); return $false }
    if (-not $activer) {
        $texte = "Désactiver « {0} » ?" -f $l.Nom
        if (Test-RadioBluetooth $l) { $texte += "`r`n`r`nC'est l'adaptateur Bluetooth : tout le Bluetooth sera coupé (souris, clavier, casque, téléphone associés)." }
        elseif ($l.Classe -eq 'DiskDrive') { $texte += "`r`n`r`nFermer d'abord les fichiers ouverts sur ce disque." }
        elseif ($l.Classe -eq 'Net') { $texte += "`r`n`r`nC'est une carte réseau : si le poste l'utilise pour Internet, la connexion sera coupée." }
        $texte += "`r`n`r`nLe périphérique restera désactivé, même après redémarrage, jusqu'à « Réactiver »."
        if ([System.Windows.Forms.MessageBox]::Show($texte, 'Désactiver un périphérique', 'YesNo', 'Question') -ne 'Yes') { return $false }
    }
    try {
        if ($activer) { Enable-PnpDevice -InstanceId $l.Ident -Confirm:$false -ErrorAction Stop } else { Disable-PnpDevice -InstanceId $l.Ident -Confirm:$false -ErrorAction Stop }
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show(("Windows a refusé :`r`n{0}" -f $_.Exception.Message), 'Service Minimum - erreur', 'OK', 'Error')
        return $false
    }
    $evt = 'Désactivé'
    if ($activer) { $evt = 'Réactivé' }
    Write-JournalPeripheriques $evt ([pscustomobject]@{ Type = $l.Type; Nom = $l.Nom; Classe = $l.Classe; Id = $l.Ident }) ''
    Write-JournalAction ('peripherique-' + $evt) $l.Nom '' $l.Ident 'OK'
    return $true
}

function Remove-ReseauWifi($l) {
    if (-not $EstAdmin) {
        [void][System.Windows.Forms.MessageBox]::Show('Lecture seule : relancer Service Minimum en administrateur.', 'Service Minimum', 'OK', 'Information')
        return $false
    }
    if ($l.Genre -ne 'wifi-profil') {
        [void][System.Windows.Forms.MessageBox]::Show('Choisir un réseau dans la vue « Wi-Fi enregistrés ».', 'Service Minimum', 'OK', 'Information')
        return $false
    }
    if ([string]$l.Profil -match '"') {
        [void][System.Windows.Forms.MessageBox]::Show('Ce nom de réseau contient des guillemets : l''oublier depuis les paramètres Wi-Fi de Windows.', 'Service Minimum', 'OK', 'Information')
        return $false
    }
    $texte = "Oublier le réseau Wi-Fi « {0} » ?`r`n`r`nSon mot de passe enregistré sera effacé : il faudra le ressaisir pour s'y reconnecter." -f $l.Nom
    if ($l.Etat -like '*connecté*') { $texte += "`r`n`r`nATTENTION : c'est le réseau utilisé en ce moment ; la connexion sera coupée." }
    if ([System.Windows.Forms.MessageBox]::Show($texte, 'Oublier un réseau Wi-Fi', 'YesNo', 'Warning') -ne 'Yes') { return $false }
    $p = Start-Process -FilePath 'netsh.exe' -ArgumentList ('wlan delete profile name="{0}"' -f $l.Profil) -WindowStyle Hidden -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        [void][System.Windows.Forms.MessageBox]::Show(('Windows n''a pas pu oublier ce réseau (code {0}).' -f $p.ExitCode), 'Service Minimum - erreur', 'OK', 'Error')
        return $false
    }
    Write-JournalPeripheriques 'Réseau Wi-Fi oublié' ([pscustomobject]@{ Type = 'Wi-Fi enregistré'; Nom = $l.Nom; Classe = ''; Id = $l.Profil }) $l.Securite
    Write-JournalAction 'oubli-reseau-wifi' $l.Nom '' '' 'OK'
    return $true
}

# ================================================================ DEMARRAGE DE WINDOWS (version 1.8)
# Programmes lances au demarrage : cles Run du registre, dossiers Demarrage, taches planifiees
# a l'ouverture de session ou au demarrage. Activation / desactivation a la maniere du Gestionnaire
# des taches (cles StartupApproved, reversibles), ajout d'un programme, retrait d'un raccourci,
# historique, journal et classement Habituel / Inhabituel / Suspect.

$SourcesRegistreDem = @(
    [pscustomobject]@{ Source = 'HKCU-Run'; Libelle = 'Registre (utilisateur)'; Chemin = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Ruche = 'HKCU'; Approb = 'Run' }
    [pscustomobject]@{ Source = 'HKLM-Run'; Libelle = 'Registre (tous les utilisateurs)'; Chemin = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; Ruche = 'HKLM'; Approb = 'Run' }
    [pscustomobject]@{ Source = 'HKLM-Run32'; Libelle = 'Registre 32 bits (tous les utilisateurs)'; Chemin = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Ruche = 'HKLM'; Approb = 'Run32' }
    [pscustomobject]@{ Source = 'HKCU-RunOnce'; Libelle = 'Registre, une seule fois (utilisateur)'; Chemin = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; Ruche = 'HKCU'; Approb = '' }
    [pscustomobject]@{ Source = 'HKLM-RunOnce'; Libelle = 'Registre, une seule fois (tous les utilisateurs)'; Chemin = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; Ruche = 'HKLM'; Approb = '' }
)
$script:HistoDem = @{}
$script:LignesDem = @()
$script:NouveauxDem = New-Object System.Collections.ArrayList
$script:ModifsDem = @{}
$script:DemEnCours = $false

function Write-JournalDemarrage([string]$evenement, $e, [string]$detail) {
    try {
        [pscustomobject]@{
            Date        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            Evenement   = $evenement
            Programme   = [string]$e.Nom
            Emplacement = [string]$e.Emplacement
            Commande    = [string]$e.Commande
            Detail      = $detail
        } | Export-Csv -LiteralPath $FichierJournalDem -Append -NoTypeInformation -Delimiter ';' -Encoding UTF8
    } catch { Write-Erreur 'Journal du demarrage' $_ }
}

function Test-ApprobationDemarrage([string]$ruche, [string]$sousCle, [string]$nom) {
    # $true si l'element est active (pas de valeur, ou premier octet pair), $false s'il est desactive
    if (-not $sousCle) { return $true }
    $chemin = '{0}:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\{1}' -f $ruche, $sousCle
    try {
        $v = (Get-ItemProperty -LiteralPath $chemin -Name $nom -ErrorAction Stop).$nom
        if ($v -is [byte[]] -and $v.Length -gt 0) { return (($v[0] -band 1) -eq 0) }
    } catch { }
    return $true
}

function New-ElementDem([string]$source, [string]$libelle, [string]$nom, [string]$commande) {
    return [pscustomobject]@{
        Cle = ($source + '|' + $nom); Source = $source; Emplacement = $libelle; Nom = $nom; NomValeur = $nom; Commande = $commande
        Active = $true; Ruche = ''; Approb = ''; Fichier = ''; TaskPath = ''; Exe = ''
        Etat = ''; Habitude = ''; Motif = ''; Editeur = ''; Signature = ''; EnCours = ''; Premiere = ''; Note = ''
    }
}

function Get-ElementsDemarrage {
    $res = New-Object System.Collections.ArrayList
    foreach ($s in $SourcesRegistreDem) {
        try {
            if (-not (Test-Path -LiteralPath $s.Chemin)) { continue }
            $cle = Get-Item -LiteralPath $s.Chemin -ErrorAction Stop
            foreach ($nom in @($cle.GetValueNames())) {
                if (-not $nom) { continue }
                $e = New-ElementDem $s.Source $s.Libelle $nom ([string]$cle.GetValue($nom))
                $e.Ruche = $s.Ruche
                $e.Approb = $s.Approb
                $e.Active = Test-ApprobationDemarrage $s.Ruche $s.Approb $nom
                [void]$res.Add($e)
            }
        } catch { Write-Erreur ('Demarrage - ' + $s.Chemin) $_ }
    }
    $wsh = $null
    try { $wsh = New-Object -ComObject WScript.Shell } catch { }
    foreach ($d in @(
        [pscustomobject]@{ Source = 'Dossier-Utilisateur'; Libelle = 'Dossier Démarrage (utilisateur)'; Dossier = [Environment]::GetFolderPath('Startup'); Ruche = 'HKCU' },
        [pscustomobject]@{ Source = 'Dossier-Commun'; Libelle = 'Dossier Démarrage (tous les utilisateurs)'; Dossier = [Environment]::GetFolderPath('CommonStartup'); Ruche = 'HKLM' }
    )) {
        try {
            if (-not $d.Dossier -or -not (Test-Path -LiteralPath $d.Dossier)) { continue }
            foreach ($f in @(Get-ChildItem -LiteralPath $d.Dossier -File -ErrorAction Stop | Where-Object { $_.Name -ne 'desktop.ini' })) {
                $commande = $f.FullName
                if ($f.Extension -eq '.lnk' -and $wsh) {
                    try {
                        $raccourci = $wsh.CreateShortcut($f.FullName)
                        $commande = ('"{0}" {1}' -f $raccourci.TargetPath, $raccourci.Arguments).Trim()
                    } catch { }
                }
                $e = New-ElementDem $d.Source $d.Libelle $f.BaseName $commande
                $e.Cle = $d.Source + '|' + $f.Name
                $e.NomValeur = $f.Name
                $e.Ruche = $d.Ruche
                $e.Approb = 'StartupFolder'
                $e.Fichier = $f.FullName
                $e.Active = Test-ApprobationDemarrage $d.Ruche 'StartupFolder' $f.Name
                [void]$res.Add($e)
            }
        } catch { Write-Erreur ('Demarrage - ' + $d.Dossier) $_ }
    }
    try {
        foreach ($t in @(Get-ScheduledTask -ErrorAction Stop)) {
            if ([string]$t.TaskPath -like '\Microsoft\*') { continue }
            $declencheurs = @($t.Triggers | Where-Object { $_ -and @('MSFT_TaskLogonTrigger', 'MSFT_TaskBootTrigger') -contains [string]$_.CimClass.CimClassName })
            if ($declencheurs.Count -eq 0) { continue }
            $quand = 'à l''ouverture de session'
            if (@($declencheurs | Where-Object { [string]$_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' }).Count -gt 0) { $quand = 'au démarrage de l''ordinateur' }
            $action = @($t.Actions)[0]
            $commande = '(action COM)'
            if ($action -and $action.Execute) { $commande = ('"{0}" {1}' -f $action.Execute, $action.Arguments).Trim() }
            $e = New-ElementDem 'Tache' ('Tâche planifiée, ' + $quand) ([string]$t.TaskName) $commande
            $e.Cle = 'Tache|' + [string]$t.TaskPath + [string]$t.TaskName
            $e.TaskPath = [string]$t.TaskPath
            $e.Active = ([string]$t.State -ne 'Disabled')
            [void]$res.Add($e)
        }
    } catch { Write-Erreur 'Demarrage - taches planifiees' $_ }
    return $res.ToArray()
}

function Get-EtatDemarrage($l) {
    if ($script:Approuves.ContainsKey('dem|' + $l.Cle)) { return (New-Etat 'Habituel' 'Déclaré habituel par l''utilisateur') }
    $cmd = ([string]$l.Commande).ToLower()
    if ($cmd -match '(powershell|pwsh|cmd\.exe|wscript|cscript|mshta|rundll32|regsvr32|bitsadmin|certutil)' -and $cmd -match '(-enc|-e\s|encodedcommand|http:|https:|\.vbs|\.js\b|\.jse|\.hta|frombase64|downloadstring|downloadfile|iex|invoke-expression|-w\s+hidden|-windowstyle\s+hidden)') {
        return (New-Etat 'Suspect' 'Commande de script au démarrage (téléchargement, code encodé ou fenêtre masquée) : forme courante des programmes malveillants')
    }
    $info = $null
    if ($l.Exe) { $info = Get-InfoExe $l.Exe }
    if ($l.Exe -and $info -and -not $info.Existe -and $l.Exe -match '[\\/]') {
        return (New-Etat 'Inhabituel' 'Programme introuvable : entrée orpheline (logiciel désinstallé), à désactiver')
    }
    if ($info -and $info.Existe -and -not $info.Windows -and -not $info.Signe) {
        $bas = ([string]$l.Exe).ToLower()
        if ($bas -match '\\temp\\|\\tmp\\|\\downloads\\|\\téléchargements\\|\\users\\public\\|\\appdata\\local\\temp') {
            return (New-Etat 'Suspect' 'Programme non signé lancé depuis un dossier temporaire ou de téléchargement')
        }
        if (-not $info.Programmes) {
            return (New-Etat 'Inhabituel' 'Programme non signé installé hors des dossiers de programmes : vérifier son origine, puis « Déclarer habituel » s''il est connu')
        }
    }
    $h = $null
    if ($script:HistoDem.ContainsKey($l.Cle)) { $h = $script:HistoDem[$l.Cle] }
    $appr = ([int]$script:Suivi.Echantillons -lt 12)
    if (-not $h) {
        if ($appr) { return (New-Etat 'Apprentissage' 'Première heure de relevés') }
        return (New-Etat 'Inhabituel' 'Nouveau au démarrage de Windows')
    }
    $modif = ConvertTo-Date ([string]$h.Modifiee)
    if ($modif -and ((Get-Date) - $modif).TotalDays -lt 7) {
        return (New-Etat 'Inhabituel' ('Commande modifiée le {0} : vérifier que ce changement est voulu' -f $modif.ToString('dd/MM à HH:mm')))
    }
    if ([string]$h.Apprentissage -eq '1') {
        if ($appr) { return (New-Etat 'Apprentissage' 'Première heure de relevés') }
        return (New-Etat 'Habituel' '')
    }
    $premiere = ConvertTo-Date ([string]$h.PremiereFois)
    if ($premiere -and ((Get-Date) - $premiere).TotalDays -lt 7) {
        return (New-Etat 'Inhabituel' ('Ajouté au démarrage le {0}' -f $premiere.ToString('dd/MM à HH:mm')))
    }
    return (New-Etat 'Habituel' '')
}

function Test-ElementSecurite($l) {
    # Composants de securite : Service Minimum ne les desactive pas (voir README, rubrique Antivirus)
    $t = ('{0} {1} {2}' -f $l.Nom, $l.Commande, $l.Editeur).ToLower()
    return ($t -match 'securityhealth|windows defender|msmpeng|kaspersky|\\avp(ui)?\.exe|avast|avg|bitdefender|eset|norton|sophos|malwarebytes|trend micro|mcafee')
}

function Update-Demarrage {
    if ($script:DemEnCours) { return }
    $script:DemEnCours = $true
    try {
        $maintenant = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $elements = @(Get-ElementsDemarrage)
        $appr = ([int]$script:Suivi.Echantillons -lt 12)
        $histoVide = ($script:HistoDem.Count -eq 0)
        $vus = @{}
        foreach ($e in $elements) {
            $vus[$e.Cle] = $true
            $actif = '1'
            if (-not $e.Active) { $actif = '0' }
            if ($script:HistoDem.ContainsKey($e.Cle)) {
                $h = $script:HistoDem[$e.Cle]
                if ([string]$h.Present -eq '0') { Write-JournalDemarrage 'Revenu au démarrage' $e '' }
                if ([string]$h.Commande -ne [string]$e.Commande) {
                    Write-JournalDemarrage 'Commande modifiée' $e ('avant : ' + [string]$h.Commande)
                    $h.Commande = [string]$e.Commande
                    $h.Modifiee = $maintenant
                }
                if ([string]$h.Active -ne $actif -and -not $script:ModifsDem.ContainsKey($e.Cle)) {
                    $evt = 'Activé (hors Service Minimum)'
                    if ($actif -eq '0') { $evt = 'Désactivé (hors Service Minimum)' }
                    Write-JournalDemarrage $evt $e ''
                }
                $h.Active = $actif
                $h.Present = '1'
                $h.DerniereFois = $maintenant
            } else {
                $a = '0'
                if ($appr -or $histoVide) { $a = '1' }
                $script:HistoDem[$e.Cle] = [pscustomobject]@{ Cle = $e.Cle; Nom = $e.Nom; Emplacement = $e.Emplacement; Commande = $e.Commande; Active = $actif; Present = '1'; PremiereFois = $maintenant; DerniereFois = $maintenant; Modifiee = ''; Apprentissage = $a }
                if ($histoVide) { Write-JournalDemarrage 'État initial' $e '' }
                else {
                    Write-JournalDemarrage 'Ajouté au démarrage' $e ''
                    if ($a -eq '0') { [void]$script:NouveauxDem.Add($e) }
                }
            }
        }
        foreach ($k in @($script:HistoDem.Keys)) {
            $h = $script:HistoDem[$k]
            if (-not $vus.ContainsKey($k) -and [string]$h.Present -ne '0') {
                $h.Present = '0'
                Write-JournalDemarrage 'Retiré du démarrage' ([pscustomobject]@{ Nom = $h.Nom; Emplacement = $h.Emplacement; Commande = $h.Commande }) ''
            }
        }
        $script:ModifsDem = @{}
        try { Export-Table $script:HistoDem $FichierHistoDem 'Cle' } catch { Write-Erreur 'Historique du demarrage' $_ }

        # Memoire des programmes de demarrage qui tournent en ce moment
        $parChemin = @{}
        try {
            foreach ($p in @(Get-Process)) {
                $chemin = ''
                try { $chemin = [string]$p.Path } catch { }
                if (-not $chemin) { continue }
                $k = $chemin.ToLower()
                if (-not $parChemin.ContainsKey($k)) { $parChemin[$k] = @(0, 0) }
                $parChemin[$k] = @(($parChemin[$k][0] + 1), ($parChemin[$k][1] + [double]$p.WorkingSet64))
            }
        } catch { }
        foreach ($e in $elements) {
            $e.Exe = [Environment]::ExpandEnvironmentVariables((Get-CheminExe ([string]$e.Commande)))
            if ($e.Exe -and $e.Exe -notmatch '[\\/]') {
                try { $trouve = (Get-Command $e.Exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source; if ($trouve) { $e.Exe = $trouve } } catch { }
            }
            $info = $null
            if ($e.Exe) { $info = Get-InfoExe $e.Exe }
            if ($info) {
                $e.Editeur = [string]$info.Editeur
                if (-not $info.Existe) { $e.Signature = 'Introuvable' }
                elseif ($info.Windows) { $e.Signature = 'Windows' }
                elseif ($info.Signe) { $e.Signature = 'Signé' }
                else { $e.Signature = 'Non signé' }
            }
            if ($e.Exe -and $parChemin.ContainsKey($e.Exe.ToLower())) {
                $x = $parChemin[$e.Exe.ToLower()]
                $e.EnCours = '{0:N0} Mo ({1} processus)' -f ($x[1] / 1048576), $x[0]
            }
            if ($e.Active) { $e.Etat = 'Activé' } else { $e.Etat = 'Désactivé' }
            if ($e.Source -like '*RunOnce') { $e.Note = 'Lancé une seule fois au prochain démarrage, puis effacé par Windows.' }
            elseif ($e.Source -eq 'Tache' -and $e.Nom -eq $NomTache) { $e.Note = 'Lancement de Service Minimum : se règle avec la case « Lancer au démarrage de Windows ».' }
            if (Test-ElementSecurite $e) { $e.Note = 'Composant de sécurité : non désactivable depuis Service Minimum.' }
            $h = $script:HistoDem[$e.Cle]
            if ($h) { $e.Premiere = [string]$h.PremiereFois }
            $etat = Get-EtatDemarrage $e
            $e.Habitude = $etat.Etat
            $e.Motif = $etat.Motif
        }
        $script:LignesDem = $elements
    } finally {
        $script:DemEnCours = $false
    }
}

function Add-AnomaliesDemarrage($anos) {
    foreach ($l in @($script:LignesDem)) {
        if (-not $l.Active) { continue }
        if ($l.Habitude -eq 'Suspect') {
            Add-Anomalie $anos 'Élevée' $l.Nom '' ('Démarrage de Windows - ' + $l.Motif) 0 'Onglet « Démarrage de Windows » : vérifier, puis désactiver s''il n''est pas connu, ou « Déclarer habituel ».' ('dem|suspect|' + $l.Cle)
        } elseif ($l.Habitude -eq 'Inhabituel' -and $l.Motif -match '^(Nouveau|Ajouté|Commande modifiée)') {
            Add-Anomalie $anos 'Moyenne' $l.Nom '' ('Démarrage de Windows - ' + $l.Motif) 0 'Normal après l''installation d''un logiciel ; sinon le désactiver dans l''onglet « Démarrage de Windows ».' ('dem|nouveau|' + $l.Cle)
        } elseif ($l.Habitude -eq 'Inhabituel' -and $l.Motif -like 'Programme introuvable*') {
            Add-Anomalie $anos 'Faible' $l.Nom '' ('Démarrage de Windows - ' + $l.Motif) 0 'Le désactiver dans l''onglet « Démarrage de Windows ».' ('dem|orphelin|' + $l.Cle)
        }
    }
}

function Send-AlerteNouveauxDemarrage {
    $nouveaux = @($script:NouveauxDem)
    $script:NouveauxDem = New-Object System.Collections.ArrayList
    if (-not $script:Icone -or $nouveaux.Count -eq 0) { return }
    $texte = (@($nouveaux | Select-Object -First 3 | ForEach-Object { '{0} ({1})' -f $_.Nom, $_.Emplacement }) -join "`r`n")
    if ($nouveaux.Count -gt 3) { $texte += "`r`n... et {0} autre(s)" -f ($nouveaux.Count - 3) }
    if ($texte.Length -gt 250) { $texte = $texte.Substring(0, 250) + '...' }
    try { $script:Icone.ShowBalloonTip(10000, 'Service Minimum - nouveau programme au démarrage', $texte, [System.Windows.Forms.ToolTipIcon]::Warning) } catch { }
}

function Show-Demarrage {
    $vue = [string]$cmbDem.SelectedItem
    $lignes = @($script:LignesDem)
    if ($vue -eq 'Activés') { $lignes = @($lignes | Where-Object { $_.Active }) }
    elseif ($vue -eq 'Désactivés') { $lignes = @($lignes | Where-Object { -not $_.Active }) }
    elseif ($vue -eq 'Registre') { $lignes = @($lignes | Where-Object { $_.Source -like 'HK*' }) }
    elseif ($vue -like 'Dossiers*') { $lignes = @($lignes | Where-Object { $_.Source -like 'Dossier*' }) }
    elseif ($vue -like 'Tâches*') { $lignes = @($lignes | Where-Object { $_.Source -eq 'Tache' }) }
    if ($cmbEtatDem.SelectedIndex -gt 0) {
        $filtre = [string]$cmbEtatDem.SelectedItem
        $lignes = @($lignes | Where-Object { $_.Habitude -eq $filtre })
    }
    $ordre = @{ 'Suspect' = 1; 'Inhabituel' = 2; 'Apprentissage' = 3; 'Habituel' = 4 }
    $tri = @({ $ordre[$_.Habitude] }, { -not $_.Active }, 'Nom')
    $lignes = @($lignes | Sort-Object -Property $tri)
    $gridDem.Rows.Clear()
    foreach ($l in $lignes) {
        $note = [string]$l.Note
        if ($l.Motif -and $l.Habitude -ne 'Apprentissage') {
            if ($note) { $note = '{0} : {1}. {2}' -f $l.Habitude, $l.Motif, $note } else { $note = '{0} : {1}' -f $l.Habitude, $l.Motif }
        }
        $i = $gridDem.Rows.Add($l.Nom, $l.Etat, $l.Habitude, $l.Emplacement, $l.Commande, $l.Editeur, $l.Signature, $l.EnCours, $l.Premiere, $note)
        $row = $gridDem.Rows[$i]
        $row.Tag = $l
        $row.Cells['Commande'].ToolTipText = [string]$l.Commande
        $row.Cells['Habitude'].ToolTipText = [string]$l.Motif
        if ($l.Habitude -eq 'Suspect') { $row.Cells['Habitude'].Style.BackColor = $CouleursTag['critique'][0] }
        elseif ($l.Habitude -eq 'Inhabituel') { $row.Cells['Habitude'].Style.BackColor = $CouleursTag['attention'][0] }
        elseif ($l.Habitude -eq 'Habituel') { $row.Cells['Habitude'].Style.BackColor = $CouleursTag['ok'][0] }
        else { $row.Cells['Habitude'].Style.BackColor = $CouleursTag['neutre'][0] }
        if (-not $l.Active) { $row.Cells['Etat'].Style.BackColor = $CouleursTag['neutre'][0] }
        if ($l.Signature -eq 'Non signé' -or $l.Signature -eq 'Introuvable') { $row.Cells['Signature'].Style.BackColor = $CouleursTag['attention'][0] }
    }
    $gridDem.ClearSelection()
    $aVoir = @($script:LignesDem | Where-Object { $_.Active -and ($_.Habitude -eq 'Suspect' -or $_.Habitude -eq 'Inhabituel') }).Count
    if ($aVoir -gt 0) { $pageDem.Text = 'Démarrage de Windows ({0} à voir)' -f $aVoir } else { $pageDem.Text = 'Démarrage de Windows' }
    $nbActifs = @($script:LignesDem | Where-Object { $_.Active }).Count
    $nbTaches = @($script:LignesDem | Where-Object { $_.Source -eq 'Tache' }).Count
    $nbAuto = @($script:Inventaire | Where-Object { $_.StartMode -eq 'Auto' }).Count
    $lblDem.Text = '{0} programme(s) au démarrage dont {1} activé(s), {2} tâche(s) planifiée(s) - {3} service(s) en démarrage automatique (liste du haut) - les applications du Microsoft Store se règlent dans Paramètres > Applications > Démarrage' -f @($script:LignesDem).Count, $nbActifs, $nbTaches, $nbAuto
}

function Get-LigneDem {
    if ($gridDem.SelectedRows.Count -eq 0 -or -not $gridDem.SelectedRows[0].Tag) {
        [void][System.Windows.Forms.MessageBox]::Show('Cliquer d''abord sur un programme de la liste.', 'Service Minimum', 'OK', 'Information')
        return $null
    }
    return $gridDem.SelectedRows[0].Tag
}

function Set-ActivationDemarrage($l, [bool]$activer) {
    if (-not $EstAdmin) {
        [void][System.Windows.Forms.MessageBox]::Show('Lecture seule : relancer Service Minimum en administrateur.', 'Service Minimum', 'OK', 'Information')
        return $false
    }
    if ($activer -and $l.Active) { [void][System.Windows.Forms.MessageBox]::Show('Ce programme est déjà activé.', 'Service Minimum', 'OK', 'Information'); return $false }
    if (-not $activer -and -not $l.Active) { [void][System.Windows.Forms.MessageBox]::Show('Ce programme est déjà désactivé.', 'Service Minimum', 'OK', 'Information'); return $false }
    if (-not $activer -and (Test-ElementSecurite $l)) {
        [void][System.Windows.Forms.MessageBox]::Show(('« {0} » est un composant de sécurité (antivirus) : Service Minimum ne le désactive pas. Le régler depuis le logiciel de sécurité lui-même.' -f $l.Nom), 'Service Minimum', 'OK', 'Warning')
        return $false
    }
    if ($l.Source -eq 'Tache' -and $l.Nom -eq $NomTache) {
        [void][System.Windows.Forms.MessageBox]::Show('Pour Service Minimum lui-même, utiliser la case « Lancer au démarrage de Windows » en haut de la fenêtre.', 'Service Minimum', 'OK', 'Information')
        return $false
    }
    if ($l.Source -like '*RunOnce') {
        [void][System.Windows.Forms.MessageBox]::Show('Élément « une seule fois » : Windows l''efface après son lancement ; il n''est pas désactivable ici.', 'Service Minimum', 'OK', 'Information')
        return $false
    }
    if (-not $activer) {
        $texte = "Ne plus lancer « {0} » au démarrage de Windows ?`r`n`r`nLe programme reste installé et utilisable ; il ne se lancera simplement plus tout seul. Réversible avec « Activer »." -f $l.Nom
        if ([System.Windows.Forms.MessageBox]::Show($texte, 'Démarrage de Windows', 'YesNo', 'Question') -ne 'Yes') { return $false }
    }
    try {
        if ($l.Source -eq 'Tache') {
            if ($activer) { Enable-ScheduledTask -TaskPath $l.TaskPath -TaskName $l.Nom -ErrorAction Stop | Out-Null }
            else { Disable-ScheduledTask -TaskPath $l.TaskPath -TaskName $l.Nom -ErrorAction Stop | Out-Null }
        } else {
            # Meme mecanisme que le Gestionnaire des taches : l'entree n'est pas effacee, seulement marquee
            $chemin = '{0}:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\{1}' -f $l.Ruche, $l.Approb
            if (-not (Test-Path -LiteralPath $chemin)) { New-Item -Path $chemin -Force | Out-Null }
            $valeur = [byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            if (-not $activer) { $valeur = [byte[]](@(3, 0, 0, 0) + [BitConverter]::GetBytes((Get-Date).ToFileTime())) }
            New-ItemProperty -LiteralPath $chemin -Name $l.NomValeur -Value $valeur -PropertyType Binary -Force -ErrorAction Stop | Out-Null
        }
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show(("Windows a refusé :`r`n{0}" -f $_.Exception.Message), 'Service Minimum - erreur', 'OK', 'Error')
        return $false
    }
    $script:ModifsDem[$l.Cle] = $true
    $evt = 'Désactivé par Service Minimum'
    if ($activer) { $evt = 'Activé par Service Minimum' }
    Write-JournalDemarrage $evt $l ''
    Write-JournalAction ('demarrage-' + $evt) $l.Nom $l.Emplacement $l.Commande 'OK'
    return $true
}

function Add-ProgrammeDemarrage {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Programme à lancer au démarrage de Windows'
    $dlg.Filter = 'Programmes et raccourcis (*.exe;*.lnk)|*.exe;*.lnk|Tous les fichiers (*.*)|*.*'
    $dlg.InitialDirectory = $env:ProgramFiles
    if ($dlg.ShowDialog($form) -ne 'OK') { return $false }
    $source = $dlg.FileName
    $dossier = [Environment]::GetFolderPath('Startup')
    $nom = [System.IO.Path]::GetFileNameWithoutExtension($source) + '.lnk'
    $destination = Join-Path $dossier $nom
    if (Test-Path -LiteralPath $destination) {
        [void][System.Windows.Forms.MessageBox]::Show(('« {0} » est déjà dans le dossier Démarrage.' -f $nom), 'Service Minimum', 'OK', 'Information')
        return $false
    }
    if ([System.IO.Path]::GetExtension($source) -eq '.lnk') {
        Copy-Item -LiteralPath $source -Destination $destination
    } else {
        $wsh = New-Object -ComObject WScript.Shell
        $r = $wsh.CreateShortcut($destination)
        $r.TargetPath = $source
        $r.WorkingDirectory = [System.IO.Path]::GetDirectoryName($source)
        $r.Save()
    }
    $cle = 'Dossier-Utilisateur|' + $nom
    [void](Set-Approuve ('dem|' + $cle) ([System.IO.Path]::GetFileNameWithoutExtension($source)))
    $script:ModifsDem[$cle] = $true
    Write-JournalDemarrage 'Ajouté par Service Minimum' ([pscustomobject]@{ Nom = [System.IO.Path]::GetFileNameWithoutExtension($source); Emplacement = 'Dossier Démarrage (utilisateur)'; Commande = $source }) ''
    Write-JournalAction 'demarrage-ajout' $nom '' $source 'OK'
    [void][System.Windows.Forms.MessageBox]::Show(("« {0} » se lancera à chaque ouverture de session Windows." -f [System.IO.Path]::GetFileNameWithoutExtension($source)), 'Démarrage de Windows', 'OK', 'Information')
    return $true
}

function Remove-ElementDossierDemarrage($l) {
    if ($l.Source -notlike 'Dossier*' -or -not $l.Fichier) {
        [void][System.Windows.Forms.MessageBox]::Show('Seuls les raccourcis du dossier Démarrage se retirent. Pour les autres programmes, utiliser « Désactiver... ».', 'Service Minimum', 'OK', 'Information')
        return $false
    }
    if (Test-ElementSecurite $l) {
        [void][System.Windows.Forms.MessageBox]::Show('Composant de sécurité : non retiré par Service Minimum.', 'Service Minimum', 'OK', 'Warning')
        return $false
    }
    if ($l.Source -eq 'Dossier-Commun' -and -not $EstAdmin) {
        [void][System.Windows.Forms.MessageBox]::Show('Lecture seule : relancer Service Minimum en administrateur.', 'Service Minimum', 'OK', 'Information')
        return $false
    }
    $texte = "Retirer « {0} » du dossier Démarrage ?`r`n`r`nLe raccourci est mis de côté dans « donnees\demarrage-retires » : le remettre dans le dossier Démarrage annule l'opération. Le programme lui-même n'est pas touché." -f $l.Nom
    if ([System.Windows.Forms.MessageBox]::Show($texte, 'Démarrage de Windows', 'YesNo', 'Question') -ne 'Yes') { return $false }
    if (-not (Test-Path -LiteralPath $DirDemarrageRetires)) { New-Item -ItemType Directory -Path $DirDemarrageRetires | Out-Null }
    $cible = Join-Path $DirDemarrageRetires ('{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [System.IO.Path]::GetFileName($l.Fichier))
    Move-Item -LiteralPath $l.Fichier -Destination $cible -ErrorAction Stop
    $script:ModifsDem[$l.Cle] = $true
    Write-JournalDemarrage 'Retiré par Service Minimum' $l ('raccourci conservé : ' + $cible)
    Write-JournalAction 'demarrage-retrait' $l.Nom $l.Fichier $cible 'OK'
    return $true
}

function Update-OngletDemarrage {
    try { Update-Demarrage } catch { Write-Erreur 'Update-Demarrage' $_ }
    try { Show-Demarrage } catch { Write-Erreur 'Show-Demarrage' $_ }
}

# ---------------------------------------------------------------- Interface
$form = New-Object System.Windows.Forms.Form
$titre = 'Service Minimum ' + $VersionApp + ' - ' + $env:COMPUTERNAME
if (-not $EstAdmin) { $titre += '  [LECTURE SEULE - relancer en administrateur pour appliquer]' }
$form.Text = $titre
$form.Size = New-Object System.Drawing.Size(1380, 920)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$script:PoliceGras = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.RowHeadersVisible = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.AutoSizeRowsMode = 'None'
$grid.BackgroundColor = [System.Drawing.Color]::White
$grid.EditMode = 'EditOnEnter'

$colAppliquer = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colAppliquer.Name = 'Appliquer'; $colAppliquer.HeaderText = 'Appliquer'; $colAppliquer.Width = 62
[void]$grid.Columns.Add($colAppliquer)

function Add-ColTexte([string]$nom, [string]$entete, [int]$largeur) {
    $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $c.Name = $nom; $c.HeaderText = $entete; $c.Width = $largeur; $c.ReadOnly = $true
    [void]$grid.Columns.Add($c)
    return $c
}
[void](Add-ColTexte 'Affiche' 'Service' 270)
[void](Add-ColTexte 'Nom' 'Nom technique' 150)
[void](Add-ColTexte 'Categorie' 'Catégorie' 130)
[void](Add-ColTexte 'Etat' 'État' 55)
[void](Add-ColTexte 'Actuel' 'Démarrage actuel' 100)

$colCible = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
$colCible.Name = 'Cible'; $colCible.HeaderText = 'Démarrage proposé'; $colCible.Width = 115
[void]$colCible.Items.AddRange(@($Inchange, 'Automatique', 'Manuel', 'Désactivé'))
$colCible.FlatStyle = 'Flat'
[void]$grid.Columns.Add($colCible)

[void](Add-ColTexte 'Releves' 'Vu actif' 60)
[void](Add-ColTexte 'Usage' 'Usage constaté' 150)
[void](Add-ColTexte 'Habitude' 'Habitude' 90)
$colMem = Add-ColTexte 'Mem' 'Mém. (Mo)' 70
$colMem.ValueType = [int]
$colNote = Add-ColTexte 'Note' 'À quoi ça sert' 380
$colNote.AutoSizeMode = 'Fill'

$haut = New-Object System.Windows.Forms.FlowLayoutPanel
$haut.Dock = 'Top'
$haut.AutoSize = $true
$haut.WrapContents = $true
$haut.Padding = New-Object System.Windows.Forms.Padding(6)

function Add-Bouton([string]$texte) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $texte
    $b.AutoSize = $true
    $b.Height = 28
    $b.Margin = New-Object System.Windows.Forms.Padding(3)
    [void]$haut.Controls.Add($b)
    return $b
}
function Add-Etiquette([string]$texte) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $texte
    $l.AutoSize = $true
    $l.Margin = New-Object System.Windows.Forms.Padding(8, 9, 0, 0)
    [void]$haut.Controls.Add($l)
}

Add-Etiquette 'Catégorie :'
$cmbCat = New-Object System.Windows.Forms.ComboBox
$cmbCat.DropDownStyle = 'DropDownList'
$cmbCat.Width = 170
$cmbCat.Margin = New-Object System.Windows.Forms.Padding(3, 5, 3, 3)
[void]$cmbCat.Items.Add('Toutes')
foreach ($k in ($LibelleCat.Keys | Sort-Object { $LibelleCat[$_] })) { [void]$cmbCat.Items.Add($LibelleCat[$k]) }
$cmbCat.SelectedIndex = 0
[void]$haut.Controls.Add($cmbCat)

Add-Etiquette 'Recherche :'
$txtCherche = New-Object System.Windows.Forms.TextBox
$txtCherche.Width = 150
$txtCherche.Margin = New-Object System.Windows.Forms.Padding(3, 6, 3, 3)
[void]$haut.Controls.Add($txtCherche)

$chkActifs = New-Object System.Windows.Forms.CheckBox
$chkActifs.Text = 'Actifs seulement'
$chkActifs.AutoSize = $true
$chkActifs.Margin = New-Object System.Windows.Forms.Padding(8, 8, 8, 0)
[void]$haut.Controls.Add($chkActifs)

$btnActualiser = Add-Bouton 'Actualiser'
$btnCocher     = Add-Bouton 'Cocher les inutiles'
$btnDecocher   = Add-Bouton 'Tout décocher'
$chkArreter = New-Object System.Windows.Forms.CheckBox
$chkArreter.Text = 'Arrêter aussi maintenant'
$chkArreter.AutoSize = $true
$chkArreter.Checked = $true
$chkArreter.Margin = New-Object System.Windows.Forms.Padding(10, 8, 3, 0)
[void]$haut.Controls.Add($chkArreter)
$btnAppliquer  = Add-Bouton 'APPLIQUER LA SÉLECTION'
$btnAppliquer.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$btnRestaurer   = Add-Bouton 'Restaurer un relevé'
$btnRapport     = Add-Bouton 'Exporter le rapport'
$btnNecessaires = Add-Bouton 'Services nécessaires (historique)'
$btnArreterSvc  = Add-Bouton 'Arrêter le service sélectionné...'
Add-Etiquette 'Habitude :'
$cmbEtat = New-Object System.Windows.Forms.ComboBox
$cmbEtat.DropDownStyle = 'DropDownList'
$cmbEtat.Width = 115
$cmbEtat.Margin = New-Object System.Windows.Forms.Padding(3, 5, 3, 3)
[void]$cmbEtat.Items.AddRange(@('Toutes', 'Habituel', 'Inhabituel', 'Suspect', 'Apprentissage'))
$cmbEtat.SelectedIndex = 0
[void]$haut.Controls.Add($cmbEtat)
$btnApprouverSvc = Add-Bouton 'Déclarer habituel'
$btnTableau = Add-Bouton 'Tableau de bord'
$btnTableau.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$btnDidacticiel = Add-Bouton 'Didacticiel'
$btnPartager = Add-Bouton 'Partager...'
$chkDemarrage = New-Object System.Windows.Forms.CheckBox
$chkDemarrage.Text = 'Lancer au démarrage de Windows'
$chkDemarrage.AutoSize = $true
$chkDemarrage.Margin = New-Object System.Windows.Forms.Padding(10, 8, 3, 0)
[void]$haut.Controls.Add($chkDemarrage)
$chkSombre = New-Object System.Windows.Forms.CheckBox
$chkSombre.Text = 'Mode sombre'
$chkSombre.AutoSize = $true
$chkSombre.Margin = New-Object System.Windows.Forms.Padding(10, 8, 3, 0)
[void]$haut.Controls.Add($chkSombre)

$statut = New-Object System.Windows.Forms.Label
$statut.Dock = 'Bottom'
$statut.Height = 26
$statut.TextAlign = 'MiddleLeft'
$statut.Padding = New-Object System.Windows.Forms.Padding(6, 0, 0, 0)

# ---- Bandeau bas : ressources + configurations enregistrees
$bas = New-Object System.Windows.Forms.Panel
$bas.Dock = 'Bottom'
$bas.Height = 320

# Pastilles de ressources
$CouleursTag = @{
    'ok'        = @([System.Drawing.Color]::FromArgb(226, 240, 217), [System.Drawing.Color]::FromArgb(84, 150, 60))
    'attention' = @([System.Drawing.Color]::FromArgb(255, 242, 204), [System.Drawing.Color]::FromArgb(230, 160, 0))
    'critique'  = @([System.Drawing.Color]::FromArgb(248, 215, 210), [System.Drawing.Color]::FromArgb(200, 60, 45))
    'neutre'    = @([System.Drawing.Color]::FromArgb(222, 234, 246), [System.Drawing.Color]::FromArgb(46, 116, 181))
}
$zoneTags = New-Object System.Windows.Forms.FlowLayoutPanel
$zoneTags.Dock = 'Top'
$zoneTags.Height = 74
$zoneTags.WrapContents = $false
$zoneTags.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 4)
$zoneTags.BackColor = [System.Drawing.Color]::White
$zoneTags.Tag = 'blanc'

function New-Tag([string]$titre, [int]$largeur) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Width = $largeur
    $p.Height = 62
    $p.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)
    $p.Tag = 'pastille'
    $bande = New-Object System.Windows.Forms.Panel
    $bande.Dock = 'Left'
    $bande.Width = 6
    $lt = New-Object System.Windows.Forms.Label
    $lt.Text = $titre.ToUpper()
    $lt.AutoSize = $false
    $lt.Left = 14; $lt.Top = 4; $lt.Width = ($largeur - 18); $lt.Height = 15
    $lt.Font = New-Object System.Drawing.Font('Segoe UI', 7.5, [System.Drawing.FontStyle]::Bold)
    $lt.ForeColor = [System.Drawing.Color]::FromArgb(64, 64, 64)
    $lv = New-Object System.Windows.Forms.Label
    $lv.Text = '...'
    $lv.AutoSize = $false
    $lv.Left = 12; $lv.Top = 18; $lv.Width = ($largeur - 16); $lv.Height = 26
    $lv.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    $ld = New-Object System.Windows.Forms.Label
    $ld.Text = ''
    $ld.AutoSize = $false
    $ld.AutoEllipsis = $true
    $ld.Left = 14; $ld.Top = 44; $ld.Width = ($largeur - 18); $ld.Height = 16
    $ld.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    $ld.ForeColor = [System.Drawing.Color]::FromArgb(64, 64, 64)
    $p.Controls.Add($bande)
    $p.Controls.Add($lt)
    $p.Controls.Add($lv)
    $p.Controls.Add($ld)
    $zoneTags.Controls.Add($p)
    return [pscustomobject]@{ Panneau = $p; Bande = $bande; Valeur = $lv; Detail = $ld }
}
$tagRam    = New-Tag 'Mémoire vive' 190
$tagCpu    = New-Tag 'Processeur' 150
$tagProc   = New-Tag 'Processus' 150
$tagSvc    = New-Tag 'Services actifs' 160
$tagMemSvc = New-Tag 'Mémoire des services' 200
$tagTop    = New-Tag 'Service le plus gourmand' 320
foreach ($tg in @($tagRam, $tagCpu, $tagProc, $tagSvc, $tagMemSvc, $tagTop)) { Set-Tag $tg '...' 'mesure en cours' 'neutre' }

$barreCfg = New-Object System.Windows.Forms.FlowLayoutPanel
$barreCfg.Dock = 'Top'
$barreCfg.AutoSize = $true
$barreCfg.WrapContents = $true
$barreCfg.Padding = New-Object System.Windows.Forms.Padding(6, 2, 6, 2)

function Add-BoutonCfg([string]$texte) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $texte
    $b.AutoSize = $true
    $b.Height = 28
    $b.Margin = New-Object System.Windows.Forms.Padding(3)
    [void]$barreCfg.Controls.Add($b)
    return $b
}
$lblCfg = New-Object System.Windows.Forms.Label
$lblCfg.Text = 'Classées de la plus économe à la plus gourmande :'
$lblCfg.AutoSize = $true
$lblCfg.Margin = New-Object System.Windows.Forms.Padding(0, 9, 8, 0)
[void]$barreCfg.Controls.Add($lblCfg)
$btnCfgSauver    = Add-BoutonCfg 'Enregistrer l''état actuel...'
$btnCfgAppliquer = Add-BoutonCfg 'Appliquer la configuration sélectionnée'
$btnCfgSupprimer = Add-BoutonCfg 'Supprimer'
$btnCfgExporter  = Add-BoutonCfg 'Exporter (JSON)...'
$btnCfgImporter  = Add-BoutonCfg 'Importer (JSON)...'

$gridCfg = New-Object System.Windows.Forms.DataGridView
$gridCfg.Dock = 'Fill'
$gridCfg.AllowUserToAddRows = $false
$gridCfg.AllowUserToDeleteRows = $false
$gridCfg.ReadOnly = $true
$gridCfg.RowHeadersVisible = $false
$gridCfg.MultiSelect = $false
$gridCfg.SelectionMode = 'FullRowSelect'
$gridCfg.BackgroundColor = [System.Drawing.Color]::White

function Add-ColCfg([string]$nom, [string]$entete, [int]$largeur) {
    $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $c.Name = $nom; $c.HeaderText = $entete; $c.Width = $largeur; $c.ReadOnly = $true
    [void]$gridCfg.Columns.Add($c)
    return $c
}
[void](Add-ColCfg 'Rang' 'Rang' 45)
$colCfgNom = Add-ColCfg 'Nom' 'Configuration' 240
[void](Add-ColCfg 'Date' 'Enregistrée le' 125)
[void](Add-ColCfg 'Etat' 'État du PC' 90)
[void](Add-ColCfg 'Auto' 'Automatiques' 85)
[void](Add-ColCfg 'Manuel' 'Manuels' 65)
[void](Add-ColCfg 'Desact' 'Désactivés' 75)
[void](Add-ColCfg 'NbMes' 'Mesures' 60)
[void](Add-ColCfg 'Actifs' 'Services actifs (moy.)' 130)
[void](Add-ColCfg 'MemSvc' 'Mém. services Mo (moy.)' 145)
[void](Add-ColCfg 'Ram' 'Mém. vive Go (moy.)' 125)
[void](Add-ColCfg 'Cpu' 'Processeur % (moy.)' 125)
$colCfgNom.AutoSizeMode = 'Fill'

# Onglet Diagnostic d'optimisation
$barreDiag = New-Object System.Windows.Forms.FlowLayoutPanel
$barreDiag.Dock = 'Top'
$barreDiag.AutoSize = $true
$barreDiag.WrapContents = $true
$barreDiag.Padding = New-Object System.Windows.Forms.Padding(6, 2, 6, 2)
function Add-BoutonDiag([string]$texte) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $texte
    $b.AutoSize = $true
    $b.Height = 28
    $b.Margin = New-Object System.Windows.Forms.Padding(3)
    [void]$barreDiag.Controls.Add($b)
    return $b
}
$btnDiagRelancer = Add-BoutonDiag 'Relancer le diagnostic'
$btnDiagCocher   = Add-BoutonDiag 'Cocher les services recommandés'
$btnDiagExporter = Add-BoutonDiag 'Exporter le diagnostic'
$btnDiagReduction = Add-BoutonDiag 'Réduction progressive : palier suivant...'

$gridDiag = New-Object System.Windows.Forms.DataGridView
$gridDiag.Dock = 'Fill'
$gridDiag.AllowUserToAddRows = $false
$gridDiag.AllowUserToDeleteRows = $false
$gridDiag.ReadOnly = $true
$gridDiag.RowHeadersVisible = $false
$gridDiag.MultiSelect = $false
$gridDiag.SelectionMode = 'FullRowSelect'
$gridDiag.BackgroundColor = [System.Drawing.Color]::White
$gridDiag.AutoSizeRowsMode = 'AllCells'
$gridDiag.DefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::True
function Add-ColDiag([string]$nom, [string]$entete, [int]$largeur) {
    $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $c.Name = $nom; $c.HeaderText = $entete; $c.Width = $largeur; $c.ReadOnly = $true
    [void]$gridDiag.Columns.Add($c)
    return $c
}
[void](Add-ColDiag 'Priorite' 'Priorité' 90)
[void](Add-ColDiag 'Domaine' 'Domaine' 130)
$colDiagConstat = Add-ColDiag 'Constat' 'Constat' 500
$colDiagConseil = Add-ColDiag 'Conseil' 'Amélioration proposée' 500
$colDiagConstat.AutoSizeMode = 'Fill'
$colDiagConseil.AutoSizeMode = 'Fill'

# Onglet Anomalies
function New-Barre {
    $b = New-Object System.Windows.Forms.FlowLayoutPanel
    $b.Dock = 'Top'
    $b.AutoSize = $true
    $b.WrapContents = $true
    $b.Padding = New-Object System.Windows.Forms.Padding(6, 2, 6, 2)
    return $b
}
function Add-BoutonBarre($barre, [string]$texte) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $texte
    $b.AutoSize = $true
    $b.Height = 28
    $b.Margin = New-Object System.Windows.Forms.Padding(3)
    [void]$barre.Controls.Add($b)
    return $b
}
function New-GrilleLecture {
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Dock = 'Fill'
    $g.AllowUserToAddRows = $false
    $g.AllowUserToDeleteRows = $false
    $g.ReadOnly = $true
    $g.RowHeadersVisible = $false
    $g.MultiSelect = $false
    $g.SelectionMode = 'FullRowSelect'
    $g.BackgroundColor = [System.Drawing.Color]::White
    return $g
}
function Add-ColGrille($grille, [string]$nom, [string]$entete, [int]$largeur) {
    $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $c.Name = $nom; $c.HeaderText = $entete; $c.Width = $largeur; $c.ReadOnly = $true
    [void]$grille.Columns.Add($c)
    return $c
}

$barreAno = New-Barre
$btnAnoActualiser = Add-BoutonBarre $barreAno 'Relever maintenant'
$btnAnoArreter    = Add-BoutonBarre $barreAno 'Arrêter ce service et ses dépendances...'
$btnAnoJournal    = Add-BoutonBarre $barreAno 'Journal des anomalies'
$btnAnoPartager   = Add-BoutonBarre $barreAno 'Partager...'
$gridAno = New-GrilleLecture
$gridAno.AutoSizeRowsMode = 'AllCells'
$gridAno.DefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::True
[void](Add-ColGrille $gridAno 'Gravite' 'Gravité' 80)
[void](Add-ColGrille $gridAno 'Service' 'Service' 200)
$colAnoAnomalie = Add-ColGrille $gridAno 'Anomalie' 'Anomalie détectée' 260
[void](Add-ColGrille $gridAno 'Conso' 'Ce qu''il consomme' 190)
$colAnoReseau = Add-ColGrille $gridAno 'Reseau' 'Envois et téléchargements' 280
$colAnoConseil = Add-ColGrille $gridAno 'Conseil' 'Que faire' 260
$colAnoAnomalie.AutoSizeMode = 'Fill'
$colAnoReseau.AutoSizeMode = 'Fill'
$colAnoConseil.AutoSizeMode = 'Fill'

# Onglet Ports et connexions
$barrePorts = New-Barre
$lblAfficher = New-Object System.Windows.Forms.Label
$lblAfficher.Text = 'Afficher :'
$lblAfficher.AutoSize = $true
$lblAfficher.Margin = New-Object System.Windows.Forms.Padding(0, 9, 4, 0)
[void]$barrePorts.Controls.Add($lblAfficher)
$cmbPorts = New-Object System.Windows.Forms.ComboBox
$cmbPorts.DropDownStyle = 'DropDownList'
$cmbPorts.Width = 190
$cmbPorts.Margin = New-Object System.Windows.Forms.Padding(3, 5, 8, 3)
[void]$cmbPorts.Items.AddRange(@('Ports en écoute', 'À fermer ou à vérifier', 'Connexions établies', 'Tout'))
$cmbPorts.SelectedIndex = 0
[void]$barrePorts.Controls.Add($cmbPorts)
$lblEtatPorts = New-Object System.Windows.Forms.Label
$lblEtatPorts.Text = 'Habitude :'
$lblEtatPorts.AutoSize = $true
$lblEtatPorts.Margin = New-Object System.Windows.Forms.Padding(0, 9, 4, 0)
[void]$barrePorts.Controls.Add($lblEtatPorts)
$cmbEtatPorts = New-Object System.Windows.Forms.ComboBox
$cmbEtatPorts.DropDownStyle = 'DropDownList'
$cmbEtatPorts.Width = 115
$cmbEtatPorts.Margin = New-Object System.Windows.Forms.Padding(3, 5, 8, 3)
[void]$cmbEtatPorts.Items.AddRange(@('Toutes', 'Habituel', 'Inhabituel', 'Suspect', 'Apprentissage'))
$cmbEtatPorts.SelectedIndex = 0
[void]$barrePorts.Controls.Add($cmbEtatPorts)
$btnPortsActualiser = Add-BoutonBarre $barrePorts 'Relever maintenant'
$btnPortsArreter    = Add-BoutonBarre $barrePorts 'Arrêter le service ou le programme...'
$btnPortsBloquer    = Add-BoutonBarre $barrePorts 'Bloquer ce port (pare-feu)'
$btnPortsDebloquer  = Add-BoutonBarre $barrePorts 'Débloquer'
$btnPortsApprouver  = Add-BoutonBarre $barrePorts 'Déclarer habituel'
$btnPortsOrigine    = Add-BoutonBarre $barrePorts 'Origine (carte)'
$btnPortsJournal    = Add-BoutonBarre $barrePorts 'Journal des ports'
$lblPorts = New-Object System.Windows.Forms.Label
$lblPorts.Text = ''
$lblPorts.AutoSize = $true
$lblPorts.Margin = New-Object System.Windows.Forms.Padding(10, 9, 0, 0)
[void]$barrePorts.Controls.Add($lblPorts)
$gridPorts = New-GrilleLecture
[void](Add-ColGrille $gridPorts 'Type' 'Type' 70)
[void](Add-ColGrille $gridPorts 'Proto' 'Protocole' 62)
[void](Add-ColGrille $gridPorts 'Port' 'Port local' 95)
[void](Add-ColGrille $gridPorts 'Local' 'Adresse IP locale' 150)
[void](Add-ColGrille $gridPorts 'Distant' 'Adresse IP distante : port' 190)
[void](Add-ColGrille $gridPorts 'Processus' 'Programme (n°)' 150)
[void](Add-ColGrille $gridPorts 'Services' 'Service(s)' 190)
[void](Add-ColGrille $gridPorts 'Portee' 'Portée' 105)
[void](Add-ColGrille $gridPorts 'Avis' 'Avis' 105)
[void](Add-ColGrille $gridPorts 'Etat' 'Habitude' 90)
[void](Add-ColGrille $gridPorts 'Habitude' 'Fréquence' 110)
[void](Add-ColGrille $gridPorts 'Envoye' 'Envoyé' 70)
[void](Add-ColGrille $gridPorts 'Recu' 'Téléchargé' 75)
$colPortsNote = Add-ColGrille $gridPorts 'Note' 'À quoi ça sert' 300
$colPortsNote.AutoSizeMode = 'Fill'

# Onglet Demarrage de Windows
$barreDem = New-Barre
$lblAfficherDem = New-Object System.Windows.Forms.Label
$lblAfficherDem.Text = 'Afficher :'
$lblAfficherDem.AutoSize = $true
$lblAfficherDem.Margin = New-Object System.Windows.Forms.Padding(0, 9, 4, 0)
[void]$barreDem.Controls.Add($lblAfficherDem)
$cmbDem = New-Object System.Windows.Forms.ComboBox
$cmbDem.DropDownStyle = 'DropDownList'
$cmbDem.Width = 190
$cmbDem.Margin = New-Object System.Windows.Forms.Padding(3, 5, 8, 3)
[void]$cmbDem.Items.AddRange(@('Tout', 'Activés', 'Désactivés', 'Registre', 'Dossiers Démarrage', 'Tâches planifiées'))
$cmbDem.SelectedIndex = 0
[void]$barreDem.Controls.Add($cmbDem)
$lblEtatDem = New-Object System.Windows.Forms.Label
$lblEtatDem.Text = 'Habitude :'
$lblEtatDem.AutoSize = $true
$lblEtatDem.Margin = New-Object System.Windows.Forms.Padding(0, 9, 4, 0)
[void]$barreDem.Controls.Add($lblEtatDem)
$cmbEtatDem = New-Object System.Windows.Forms.ComboBox
$cmbEtatDem.DropDownStyle = 'DropDownList'
$cmbEtatDem.Width = 115
$cmbEtatDem.Margin = New-Object System.Windows.Forms.Padding(3, 5, 8, 3)
[void]$cmbEtatDem.Items.AddRange(@('Toutes', 'Habituel', 'Inhabituel', 'Suspect', 'Apprentissage'))
$cmbEtatDem.SelectedIndex = 0
[void]$barreDem.Controls.Add($cmbEtatDem)
$btnDemActualiser = Add-BoutonBarre $barreDem 'Relever maintenant'
$btnDemDesactiver = Add-BoutonBarre $barreDem 'Désactiver...'
$btnDemActiver    = Add-BoutonBarre $barreDem 'Activer'
$btnDemApprouver  = Add-BoutonBarre $barreDem 'Déclarer habituel'
$btnDemAjouter    = Add-BoutonBarre $barreDem 'Ajouter un programme...'
$btnDemRetirer    = Add-BoutonBarre $barreDem 'Retirer du dossier Démarrage...'
$btnDemOuvrir     = Add-BoutonBarre $barreDem 'Ouvrir l''emplacement'
$btnDemJournal    = Add-BoutonBarre $barreDem 'Journal du démarrage'
$lblDem = New-Object System.Windows.Forms.Label
$lblDem.Text = ''
$lblDem.AutoSize = $true
$lblDem.Margin = New-Object System.Windows.Forms.Padding(10, 9, 0, 0)
[void]$barreDem.Controls.Add($lblDem)
$gridDem = New-GrilleLecture
[void](Add-ColGrille $gridDem 'Nom' 'Programme' 200)
[void](Add-ColGrille $gridDem 'Etat' 'État' 80)
[void](Add-ColGrille $gridDem 'Habitude' 'Habitude' 90)
[void](Add-ColGrille $gridDem 'Emplacement' 'Lancé par' 200)
[void](Add-ColGrille $gridDem 'Commande' 'Commande' 280)
[void](Add-ColGrille $gridDem 'Editeur' 'Éditeur' 150)
[void](Add-ColGrille $gridDem 'Signature' 'Signature' 80)
[void](Add-ColGrille $gridDem 'EnCours' 'En cours' 120)
[void](Add-ColGrille $gridDem 'Premiere' 'Vu depuis' 120)
$colDemNote = Add-ColGrille $gridDem 'Note' 'Remarque' 280
$colDemNote.AutoSizeMode = 'Fill'
$pageDem = New-Object System.Windows.Forms.TabPage
$pageDem.Text = 'Démarrage de Windows'
$pageDem.Controls.Add($gridDem)
$pageDem.Controls.Add($barreDem)

# Onglet Peripheriques (USB, Bluetooth, Wi-Fi)
$barrePer = New-Barre
$lblAfficherPer = New-Object System.Windows.Forms.Label
$lblAfficherPer.Text = 'Afficher :'
$lblAfficherPer.AutoSize = $true
$lblAfficherPer.Margin = New-Object System.Windows.Forms.Padding(0, 9, 4, 0)
[void]$barrePer.Controls.Add($lblAfficherPer)
$cmbPer = New-Object System.Windows.Forms.ComboBox
$cmbPer.DropDownStyle = 'DropDownList'
$cmbPer.Width = 270
$cmbPer.Margin = New-Object System.Windows.Forms.Padding(3, 5, 8, 3)
[void]$cmbPer.Items.AddRange(@('Tout', 'USB, claviers et souris', 'Bluetooth', 'Wi-Fi (carte, connexion, réseaux à portée)', 'Wi-Fi enregistrés'))
$cmbPer.SelectedIndex = 0
[void]$barrePer.Controls.Add($cmbPer)
$lblEtatPer = New-Object System.Windows.Forms.Label
$lblEtatPer.Text = 'Habitude :'
$lblEtatPer.AutoSize = $true
$lblEtatPer.Margin = New-Object System.Windows.Forms.Padding(0, 9, 4, 0)
[void]$barrePer.Controls.Add($lblEtatPer)
$cmbEtatPer = New-Object System.Windows.Forms.ComboBox
$cmbEtatPer.DropDownStyle = 'DropDownList'
$cmbEtatPer.Width = 115
$cmbEtatPer.Margin = New-Object System.Windows.Forms.Padding(3, 5, 8, 3)
[void]$cmbEtatPer.Items.AddRange(@('Toutes', 'Habituel', 'Inhabituel', 'Suspect', 'Apprentissage'))
$cmbEtatPer.SelectedIndex = 0
[void]$barrePer.Controls.Add($cmbEtatPer)
$chkDebranches = New-Object System.Windows.Forms.CheckBox
$chkDebranches.Text = 'Inclure les débranchés'
$chkDebranches.AutoSize = $true
$chkDebranches.Margin = New-Object System.Windows.Forms.Padding(4, 8, 8, 0)
[void]$barrePer.Controls.Add($chkDebranches)
$btnPerActualiser = Add-BoutonBarre $barrePer 'Relever maintenant'
$btnPerDesactiver = Add-BoutonBarre $barrePer 'Désactiver...'
$btnPerReactiver  = Add-BoutonBarre $barrePer 'Réactiver'
$btnPerApprouver  = Add-BoutonBarre $barrePer 'Déclarer habituel'
$btnPerOublier    = Add-BoutonBarre $barrePer 'Oublier ce réseau Wi-Fi...'
$btnPerWifi       = Add-BoutonBarre $barrePer 'Couper le Wi-Fi...'
$btnPerBluetooth  = Add-BoutonBarre $barrePer 'Couper le Bluetooth...'
$btnPerUsb        = Add-BoutonBarre $barrePer 'Bloquer les clés USB...'
$btnPerJournal    = Add-BoutonBarre $barrePer 'Journal des périphériques'
$lblPer = New-Object System.Windows.Forms.Label
$lblPer.Text = ''
$lblPer.AutoSize = $true
$lblPer.Margin = New-Object System.Windows.Forms.Padding(10, 9, 0, 0)
[void]$barrePer.Controls.Add($lblPer)
$gridPer = New-GrilleLecture
[void](Add-ColGrille $gridPer 'Type' 'Type' 110)
[void](Add-ColGrille $gridPer 'Nom' 'Nom' 230)
[void](Add-ColGrille $gridPer 'Etat' 'État' 140)
[void](Add-ColGrille $gridPer 'Habitude' 'Habitude' 90)
[void](Add-ColGrille $gridPer 'Securite' 'Sécurité' 210)
[void](Add-ColGrille $gridPer 'Detail' 'Détail' 260)
[void](Add-ColGrille $gridPer 'Premiere' 'Première fois' 120)
[void](Add-ColGrille $gridPer 'Derniere' 'Dernière fois' 120)
$colPerNote = Add-ColGrille $gridPer 'Note' 'Remarque' 300
$colPerNote.AutoSizeMode = 'Fill'
$pagePer = New-Object System.Windows.Forms.TabPage
$pagePer.Text = 'Périphériques'
$pagePer.Controls.Add($gridPer)
$pagePer.Controls.Add($barrePer)

$onglets = New-Object System.Windows.Forms.TabControl
$onglets.Dock = 'Fill'
$pageAno = New-Object System.Windows.Forms.TabPage
$pageAno.Text = 'Anomalies'
$pagePorts = New-Object System.Windows.Forms.TabPage
$pagePorts.Text = 'Ports et connexions'
$pageAno.Controls.Add($gridAno)
$pageAno.Controls.Add($barreAno)
$pagePorts.Controls.Add($gridPorts)
$pagePorts.Controls.Add($barrePorts)
$pageDiag = New-Object System.Windows.Forms.TabPage
$pageDiag.Text = 'Diagnostic d''optimisation'
$pageCfg = New-Object System.Windows.Forms.TabPage
$pageCfg.Text = 'Configurations enregistrées'
$pageDiag.Controls.Add($gridDiag)
$pageDiag.Controls.Add($barreDiag)
$pageCfg.Controls.Add($gridCfg)
$pageCfg.Controls.Add($barreCfg)
$onglets.TabPages.Add($pageDiag)
$onglets.TabPages.Add($pageAno)
$onglets.TabPages.Add($pagePorts)
$onglets.TabPages.Add($pagePer)
$onglets.TabPages.Add($pageDem)
$onglets.TabPages.Add($pageCfg)
$bas.Controls.Add($onglets)

[void]$form.Controls.Add($grid)
[void]$form.Controls.Add($zoneTags)
[void]$form.Controls.Add($haut)
[void]$form.Controls.Add($bas)
[void]$form.Controls.Add($statut)

$Couleurs = @{
    'E' = [System.Drawing.Color]::FromArgb(222, 234, 246)
    'G' = [System.Drawing.Color]::FromArgb(240, 246, 252)
    'O' = [System.Drawing.Color]::FromArgb(255, 248, 220)
    'I' = [System.Drawing.Color]::FromArgb(252, 224, 214)
    'T' = [System.Drawing.Color]::FromArgb(236, 230, 248)
    'W' = [System.Drawing.Color]::White
    'U' = [System.Drawing.Color]::FromArgb(238, 238, 238)
}

# ---------------------------------------------------------------- Mode sombre (version 1.5)
# Bascule clair / sombre de toute l'interface classique ; le choix est garde dans donnees\preferences.json.
# Sans choix enregistre, l'application suit le theme des applications de Windows.
$FichierPreferences = Join-Path $Donnees 'preferences.json'
$script:DwmDispo = $false
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SmDwm {
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
}
'@
    $script:DwmDispo = $true
} catch {
    Write-Demarrage ('barre de titre sombre indisponible : ' + $_.Exception.Message)
}

function New-Couleur([int]$r, [int]$g, [int]$b) { return [System.Drawing.Color]::FromArgb($r, $g, $b) }

$CouleursClair = @{}
foreach ($k in @($Couleurs.Keys)) { $CouleursClair[$k] = $Couleurs[$k] }
$CouleursSombre = @{
    'E' = (New-Couleur 30 44 62)
    'G' = (New-Couleur 38 44 54)
    'O' = (New-Couleur 66 58 30)
    'I' = (New-Couleur 74 42 36)
    'T' = (New-Couleur 54 44 74)
    'W' = (New-Couleur 40 40 46)
    'U' = (New-Couleur 52 52 56)
}
$CouleursTagClair = @{}
foreach ($k in @($CouleursTag.Keys)) { $CouleursTagClair[$k] = @($CouleursTag[$k][0], $CouleursTag[$k][1]) }
$CouleursTagSombre = @{
    'ok'        = @((New-Couleur 34 64 44), (New-Couleur 84 170 90))
    'attention' = @((New-Couleur 78 64 24), (New-Couleur 230 160 0))
    'critique'  = @((New-Couleur 86 36 34), (New-Couleur 220 70 55))
    'neutre'    = @((New-Couleur 30 50 72), (New-Couleur 70 140 210))
}
$ThemeClair = [pscustomobject]@{
    Sombre = $false
    Fond = [System.Drawing.SystemColors]::Control
    Grille = [System.Drawing.SystemColors]::Window
    Entete = [System.Drawing.SystemColors]::Control
    Texte = [System.Drawing.SystemColors]::ControlText
    Faible = (New-Couleur 64 64 64)
    Valeur = [System.Drawing.SystemColors]::ControlText
    Bouton = [System.Drawing.SystemColors]::Control
    Bordure = [System.Drawing.SystemColors]::ControlDark
    Selection = [System.Drawing.SystemColors]::Highlight
    TexteSelection = [System.Drawing.SystemColors]::HighlightText
}
$ThemeSombre = [pscustomobject]@{
    Sombre = $true
    Fond = (New-Couleur 30 30 34)
    Grille = (New-Couleur 40 40 46)
    Entete = (New-Couleur 52 52 60)
    Texte = (New-Couleur 225 228 232)
    Faible = (New-Couleur 165 172 180)
    Valeur = [System.Drawing.Color]::White
    Bouton = (New-Couleur 55 58 66)
    Bordure = (New-Couleur 85 90 100)
    Selection = (New-Couleur 38 92 150)
    TexteSelection = [System.Drawing.Color]::White
}
$script:Theme = $ThemeClair
$script:ModeSombre = $false

function Set-ThemeControle($c) {
    $t = $script:Theme
    if ([string]$c.Tag -eq 'pastille') {
        # Pastilles de ressources : leur fond est gere par Set-Tag, seuls les textes changent ici
        foreach ($x in @($c.Controls)) {
            if ($x -is [System.Windows.Forms.Label]) {
                if ($x.Font.Size -ge 13) { $x.ForeColor = $t.Valeur } else { $x.ForeColor = $t.Faible }
            }
        }
        return
    }
    if ($c -is [System.Windows.Forms.DataGridView]) {
        $c.EnableHeadersVisualStyles = (-not $t.Sombre)
        $c.BackgroundColor = $t.Grille
        $c.GridColor = $t.Bordure
        $c.DefaultCellStyle.BackColor = $t.Grille
        $c.DefaultCellStyle.ForeColor = $t.Texte
        $c.DefaultCellStyle.SelectionBackColor = $t.Selection
        $c.DefaultCellStyle.SelectionForeColor = $t.TexteSelection
        $c.ColumnHeadersDefaultCellStyle.BackColor = $t.Entete
        $c.ColumnHeadersDefaultCellStyle.ForeColor = $t.Texte
        $c.RowHeadersDefaultCellStyle.BackColor = $t.Entete
        return
    }
    if ($c -is [System.Windows.Forms.Button]) {
        if ($t.Sombre) {
            $c.FlatStyle = 'Flat'
            $c.BackColor = $t.Bouton
            $c.ForeColor = $t.Texte
            $c.FlatAppearance.BorderColor = $t.Bordure
        } else {
            $c.FlatStyle = 'Standard'
            $c.BackColor = [System.Drawing.SystemColors]::Control
            $c.UseVisualStyleBackColor = $true
            $c.ForeColor = [System.Drawing.SystemColors]::ControlText
        }
    } elseif ($c -is [System.Windows.Forms.ComboBox]) {
        if ($t.Sombre) {
            $c.FlatStyle = 'Flat'
            $c.BackColor = $t.Grille
            $c.ForeColor = $t.Texte
        } else {
            $c.FlatStyle = 'Standard'
            $c.BackColor = [System.Drawing.SystemColors]::Window
            $c.ForeColor = [System.Drawing.SystemColors]::WindowText
        }
    } elseif ($c -is [System.Windows.Forms.TextBox]) {
        if ($t.Sombre) {
            $c.BackColor = $t.Grille
            $c.ForeColor = $t.Texte
        } else {
            $c.BackColor = [System.Drawing.SystemColors]::Window
            $c.ForeColor = [System.Drawing.SystemColors]::WindowText
        }
    } elseif ($c -is [System.Windows.Forms.TabControl]) {
        # Les onglets sont dessines par l'application en mode sombre (Windows les dessine toujours en clair)
        if ($t.Sombre) { $c.DrawMode = 'OwnerDrawFixed' } else { $c.DrawMode = 'Normal' }
        $c.Invalidate()
    } elseif ($c -is [System.Windows.Forms.Label] -or $c -is [System.Windows.Forms.CheckBox]) {
        $c.ForeColor = $t.Texte
    } elseif ($c -is [System.Windows.Forms.Panel]) {
        # Panneaux, barres de boutons et pages d'onglets
        if ([string]$c.Tag -eq 'blanc' -and -not $t.Sombre) {
            $c.BackColor = [System.Drawing.Color]::White
        } elseif ($c -is [System.Windows.Forms.TabPage] -and -not $t.Sombre) {
            $c.BackColor = [System.Drawing.SystemColors]::Control
            $c.UseVisualStyleBackColor = $true
        } else {
            $c.BackColor = $t.Fond
        }
        $c.ForeColor = $t.Texte
    }
    foreach ($enfant in @($c.Controls)) { Set-ThemeControle $enfant }
}

function Set-TitreSombre {
    # Barre de titre sombre (Windows 10 version 1809 et suivantes, Windows 11)
    if (-not $script:DwmDispo) { return }
    try {
        if (-not $form.IsHandleCreated) { return }
        $v = 0
        if ($script:ModeSombre) { $v = 1 }
        $r = [SmDwm]::DwmSetWindowAttribute($form.Handle, 20, [ref]$v, 4)
        if ($r -ne 0) { $r = [SmDwm]::DwmSetWindowAttribute($form.Handle, 19, [ref]$v, 4) }
    } catch { }
}

function Update-CouleursLignes {
    # Recolore les listes deja remplies avec la palette du theme courant
    foreach ($row in $grid.Rows) {
        if ($row.Tag) { $row.DefaultCellStyle.BackColor = $Couleurs[[string]$row.Tag.Cat] }
    }
    if (@($script:Inventaire).Count -gt 0) {
        try { Update-ColonneUsage } catch { Write-Erreur 'Theme - colonne usage' $_ }
    }
    try { Show-Anomalies } catch { Write-Erreur 'Theme - anomalies' $_ }
    try { Show-Reseau } catch { Write-Erreur 'Theme - reseau' $_ }
    try { Show-Peripheriques } catch { Write-Erreur 'Theme - peripheriques' $_ }
    try { Show-Demarrage } catch { Write-Erreur 'Theme - demarrage' $_ }
    try { Update-Configs } catch { Write-Erreur 'Theme - configurations' $_ }
    try { Update-Diagnostic } catch { Write-Erreur 'Theme - diagnostic' $_ }
}

function Set-Theme([bool]$sombre, [bool]$rafraichir) {
    $script:ModeSombre = $sombre
    if ($sombre) {
        $script:Theme = $ThemeSombre
        $source = $CouleursSombre
        $sourceTag = $CouleursTagSombre
    } else {
        $script:Theme = $ThemeClair
        $source = $CouleursClair
        $sourceTag = $CouleursTagClair
    }
    foreach ($k in @($source.Keys)) { $Couleurs[$k] = $source[$k] }
    foreach ($k in @($sourceTag.Keys)) { $CouleursTag[$k] = @($sourceTag[$k][0], $sourceTag[$k][1]) }
    $form.SuspendLayout()
    try {
        $form.BackColor = $script:Theme.Fond
        $form.ForeColor = $script:Theme.Texte
        foreach ($c in @($form.Controls)) { Set-ThemeControle $c }
    } finally {
        $form.ResumeLayout()
    }
    if ($script:Ressources) {
        try { Update-LabelRessources } catch { }
    } else {
        foreach ($tg in @($tagRam, $tagCpu, $tagProc, $tagSvc, $tagMemSvc, $tagTop)) { Set-Tag $tg '...' 'mesure en cours' 'neutre' }
    }
    Set-TitreSombre
    if ($rafraichir) { Update-CouleursLignes }
    $form.Refresh()
}

function Get-PrefSombre {
    if (Test-Path -LiteralPath $FichierPreferences) {
        try {
            $p = Get-Content -LiteralPath $FichierPreferences -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $p.ModeSombre) { return [bool]$p.ModeSombre }
        } catch { Write-Erreur 'Lecture des preferences' $_ }
    }
    try {
        $v = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop
        return ([int]$v -eq 0)
    } catch { }
    return $false
}

function Save-PrefSombre([bool]$sombre) {
    try {
        [pscustomobject]@{ ModeSombre = $sombre } | ConvertTo-Json | Set-Content -LiteralPath $FichierPreferences -Encoding UTF8
    } catch { Write-Erreur 'Enregistrement des preferences' $_ }
}

$onglets.Add_DrawItem({
    param($s, $e)
    try {
        $t = $script:Theme
        $page = $onglets.TabPages[$e.Index]
        $fondOnglet = $t.Entete
        if ($e.Index -eq $onglets.SelectedIndex) { $fondOnglet = $t.Fond }
        $pinceau = New-Object System.Drawing.SolidBrush($fondOnglet)
        $e.Graphics.FillRectangle($pinceau, $e.Bounds)
        $pinceau.Dispose()
        $drapeaux = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $page.Text, $onglets.Font, $e.Bounds, $t.Texte, $drapeaux)
    } catch { }
})
$form.Add_HandleCreated({ Set-TitreSombre })
$chkSombre.Add_Click({
    try {
        Set-Theme $chkSombre.Checked $true
        Save-PrefSombre $chkSombre.Checked
    } catch {
        Write-Erreur 'Mode sombre' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})
try {
    $prefSombre = Get-PrefSombre
    $chkSombre.Checked = $prefSombre
    Set-Theme $prefSombre $false
    Write-Demarrage ('mode sombre = ' + $prefSombre)
} catch {
    Write-Erreur 'Mode sombre au demarrage' $_
}

$script:Inventaire = @()
$script:Chargement = $false
$script:Ressources = $null
$script:Recommandes = @{}
$script:Diagnostic = @()
$script:PremierPassage = $true

function Update-Filtre {
    $grid.CurrentCell = $null
    $cat = [string]$cmbCat.SelectedItem
    $mot = $txtCherche.Text.Trim()
    $visibles = 0
    foreach ($row in $grid.Rows) {
        $s = $row.Tag
        $voir = $true
        if ($cat -ne 'Toutes' -and $LibelleCat[$s.Cat] -ne $cat) { $voir = $false }
        if ($voir -and $chkActifs.Checked -and $s.State -ne 'Running') { $voir = $false }
        if ($voir -and $cmbEtat.SelectedIndex -gt 0 -and [string]$row.Cells['Habitude'].Value -ne [string]$cmbEtat.SelectedItem) { $voir = $false }
        if ($voir -and $mot) {
            $cible = ($s.Name + ' ' + $s.DisplayName + ' ' + $s.Note)
            if ($cible.IndexOf($mot, [StringComparison]::OrdinalIgnoreCase) -lt 0) { $voir = $false }
        }
        $row.Visible = $voir
        if ($voir) { $visibles++ }
    }
    return $visibles
}

function Update-Grille {
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $script:Chargement = $true
    try {
        $script:Inventaire = @(Get-Inventaire)
        $stats = Get-StatsReleves
        $script:CatParNom = @{}
        $grid.Rows.Clear()
        foreach ($s in $script:Inventaire) {
            $cibleFr = $Inchange
            if ($s.Cible -and $s.Cible -ne $s.StartMode) { $cibleFr = $ModeFr[$s.Cible] }
            $etat = $s.State
            if ($s.State -eq 'Running') { $etat = 'Actif' } elseif ($s.State -eq 'Stopped') { $etat = 'Arrêté' }
            $actuel = $s.StartMode
            if ($ModeFr.ContainsKey($s.StartMode)) { $actuel = $ModeFr[$s.StartMode] }
            $vu = ''
            if ($stats.Total -gt 0) {
                $n = 0
                $nomStats = Get-NomStable ([string]$s.Name)
                if ($stats.Actifs.ContainsKey($s.Name)) { $n = $stats.Actifs[$s.Name] }
                elseif ($stats.Actifs.ContainsKey($nomStats)) { $n = $stats.Actifs[$nomStats] }
                if ($n -gt $stats.Total) { $n = $stats.Total }
                $vu = '{0}/{1}' -f $n, $stats.Total
            }
            $script:CatParNom[[string]$s.Name] = [string]$s.Cat
            $i = $grid.Rows.Add($false, $s.DisplayName, $s.Name, $LibelleCat[$s.Cat], $etat, $actuel, $cibleFr, $vu, '', '', [int]$s.MemMo, $s.Note)
            $row = $grid.Rows[$i]
            $row.Tag = $s
            $row.DefaultCellStyle.BackColor = $Couleurs[$s.Cat]
            if ($s.Cat -eq 'E' -or $s.Cat -eq 'U') {
                $row.Cells['Appliquer'].ReadOnly = $true
                $row.Cells['Cible'].ReadOnly = $true
            }
        }
        [void](Update-Filtre)
        $actifs = @($script:Inventaire | Where-Object { $_.State -eq 'Running' }).Count
        $aTraiter = @($script:Inventaire | Where-Object { $_.Cat -eq 'I' -and $_.Cible -and $_.Cible -ne $_.StartMode }).Count
        $statut.Text = ('{0} services - {1} actifs - {2} « inutiles probables » encore à traiter - {3} relevé(s) en historique - données : {4}' -f $script:Inventaire.Count, $actifs, $aTraiter, $stats.Total, $Donnees)
        # Inventaire lisible pour analyse
        [pscustomobject]@{
            Date     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            Machine  = $env:COMPUTERNAME
            Services = @($script:Inventaire)
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $FichierCourant -Encoding UTF8
        # Historique des services strictement necessaires (ne doit jamais bloquer l'application)
        try { [void](Save-Necessaires $script:Inventaire) } catch { Write-Erreur 'Save-Necessaires' $_ }
        # Ressources et classement des configurations
        try { Update-Suivi } catch { Write-Erreur 'Update-Suivi' $_ }
        # Colonne "Usage" : lien avec les applications utilisees et regularite du service
        try { Update-ColonneUsage } catch { Write-Erreur 'Update-ColonneUsage' $_ }
    } finally {
        $script:Chargement = $false
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

function Get-Selection {
    # Lignes cochees dont la cible differe de l'etat actuel
    $grid.EndEdit() | Out-Null
    $liste = New-Object System.Collections.ArrayList
    foreach ($row in $grid.Rows) {
        if ($row.Cells['Appliquer'].Value -ne $true) { continue }
        $s = $row.Tag
        $choix = [string]$row.Cells['Cible'].Value
        if (-not $ModeEn.ContainsKey($choix)) { continue }
        $cible = $ModeEn[$choix]
        if ($cible -eq $s.StartMode) { continue }
        [void]$liste.Add([pscustomobject]@{ Name = $s.Name; DisplayName = $s.DisplayName; Avant = $s.StartMode; Cible = $cible })
    }
    return $liste.ToArray()
}

# ---------------------------------------------------------------- Evenements
$grid.Add_CurrentCellDirtyStateChanged({
    if ($grid.IsCurrentCellDirty) { [void]$grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) }
})
$grid.Add_DataError({ param($s, $e) $e.ThrowException = $false })
$grid.Add_CellValueChanged({
    param($s, $e)
    # Choisir une cible coche automatiquement la ligne
    if ((-not $script:Chargement) -and $e.RowIndex -ge 0 -and $grid.Columns[$e.ColumnIndex].Name -eq 'Cible') {
        $row = $grid.Rows[$e.RowIndex]
        if (-not $row.Cells['Appliquer'].ReadOnly) {
            $row.Cells['Appliquer'].Value = ([string]$row.Cells['Cible'].Value -ne $Inchange)
        }
    }
})

$cmbCat.Add_SelectedIndexChanged({ [void](Update-Filtre) })
$txtCherche.Add_TextChanged({ [void](Update-Filtre) })
$chkActifs.Add_CheckedChanged({ [void](Update-Filtre) })
$btnActualiser.Add_Click({ Update-Grille })

$btnCocher.Add_Click({
    $n = 0
    foreach ($row in $grid.Rows) {
        $s = $row.Tag
        if ($s.Cat -eq 'I' -and $s.Cible -and $s.Cible -ne $s.StartMode) {
            $row.Cells['Cible'].Value = $ModeFr[$s.Cible]
            $row.Cells['Appliquer'].Value = $true
            $n++
        }
    }
    $statut.Text = ('{0} service(s) « inutiles probables » cochés. Les optionnels et les logiciels tiers restent à votre choix, ligne par ligne.' -f $n)
})

$btnDecocher.Add_Click({
    foreach ($row in $grid.Rows) { if (-not $row.Cells['Appliquer'].ReadOnly) { $row.Cells['Appliquer'].Value = $false } }
})

$btnAppliquer.Add_Click({
    $sel = @(Get-Selection)
    if ($sel.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Aucune modification cochée.', 'Service Minimum', 'OK', 'Information')
        return
    }
    $lignes = @($sel | Select-Object -First 25 | ForEach-Object { '  {0} : {1} -> {2}' -f $_.DisplayName, $ModeFr[$_.Avant], $ModeFr[$_.Cible] })
    $texte = "{0} modification(s) :`r`n`r`n{1}" -f $sel.Count, ($lignes -join "`r`n")
    if ($sel.Count -gt 25) { $texte += "`r`n  ..." }
    $texte += "`r`n`r`nL'état actuel sera sauvegardé avant. Continuer ?"
    $rep = [System.Windows.Forms.MessageBox]::Show($texte, 'Confirmer', 'YesNo', 'Question')
    if ($rep -ne 'Yes') { return }
    Invoke-Changements $sel $chkArreter.Checked 'avant-application'
    Update-Grille
})

$btnCfgSauver.Add_Click({
    try {
        $nom = [Microsoft.VisualBasic.Interaction]::InputBox('Nom de la configuration (état actuel des modes de démarrage) :', 'Service Minimum', ('Configuration du ' + (Get-Date -Format 'dd-MM-yyyy')))
        if ([string]::IsNullOrWhiteSpace($nom)) { return }
        $nom = $nom.Trim()
        $slug = ($nom -replace '[^A-Za-z0-9_-]+', '-').Trim('-')
        if (-not $slug) { $slug = 'sans-nom' }
        $fichier = Join-Path $DirProfils ('config-{0}.json' -f $slug)
        if (Test-Path -LiteralPath $fichier) {
            $rep = [System.Windows.Forms.MessageBox]::Show('Une configuration porte déjà ce nom. La remplacer (ses mesures seront remises à zéro) ?', 'Confirmer', 'YesNo', 'Question')
            if ($rep -ne 'Yes') { return }
        }
        New-Config $nom $fichier
        $script:Ressources = Get-Ressources
        Update-LabelRessources
        Add-MesuresConfigs
        Update-Configs
    } catch {
        Write-Erreur 'Enregistrer configuration' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})

$btnCfgAppliquer.Add_Click({
    try {
        if ($gridCfg.SelectedRows.Count -eq 0) { return }
        $cfg = $gridCfg.SelectedRows[0].Tag
        $ecarts = @(Get-EcartsConfig $cfg)
        if ($ecarts.Count -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show(('Le PC est déjà conforme à la configuration « {0} ».' -f $cfg.Nom), 'Service Minimum', 'OK', 'Information')
            return
        }
        $lignes = @($ecarts | Select-Object -First 25 | ForEach-Object { '  {0} : {1} -> {2}' -f $_.DisplayName, $ModeFr[$_.Avant], $ModeFr[$_.Cible] })
        $texte = "Configuration « {0} » du {1}`r`n{2} écart(s) à corriger :`r`n`r`n{3}" -f $cfg.Nom, $cfg.Date, $ecarts.Count, ($lignes -join "`r`n")
        if ($ecarts.Count -gt 25) { $texte += "`r`n  ..." }
        $texte += "`r`n`r`nL'état actuel sera sauvegardé avant. Continuer ?"
        $rep = [System.Windows.Forms.MessageBox]::Show($texte, 'Confirmer', 'YesNo', 'Question')
        if ($rep -ne 'Yes') { return }
        Invoke-Changements $ecarts $chkArreter.Checked 'avant-configuration'
        Update-Grille
    } catch {
        Write-Erreur 'Appliquer configuration' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})

$btnCfgExporter.Add_Click({
    try {
        $cfg = $null
        if ($gridCfg.SelectedRows.Count -gt 0) { $cfg = $gridCfg.SelectedRows[0].Tag }
        if (-not $cfg) {
            [void][System.Windows.Forms.MessageBox]::Show('Cliquer d''abord sur la configuration à exporter.', 'Service Minimum', 'OK', 'Information')
            return
        }
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Filter = 'Configuration Service Minimum (*.json)|*.json'
        $nomFichier = (([string]$cfg.Nom) -replace '[^A-Za-z0-9_-]+', '-').Trim('-')
        if (-not $nomFichier) { $nomFichier = 'configuration' }
        $dlg.FileName = ('ServiceMinimum-{0}.json' -f $nomFichier)
        $dlg.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
        if ($dlg.ShowDialog($form) -ne 'OK') { return }
        $n = Export-ConfigJson $cfg $dlg.FileName
        Write-JournalAction 'export-configuration' ([string]$cfg.Nom) '' $dlg.FileName 'OK'
        $texte = "Configuration « {0} » exportée ({1} services) :`r`n{2}`r`n`r`nSur un autre poste : bouton « Importer (JSON)... », ou lancer Service Minimum avec l'option -importer suivie du chemin du fichier (par exemple depuis Fifou)." -f $cfg.Nom, $n, $dlg.FileName
        [void][System.Windows.Forms.MessageBox]::Show($texte, 'Service Minimum - export', 'OK', 'Information')
    } catch {
        Write-Erreur 'Export de configuration' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})

$btnCfgImporter.Add_Click({
    try {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Configuration Service Minimum (*.json)|*.json|Tous les fichiers (*.*)|*.*'
        $dlg.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
        if ($dlg.ShowDialog($form) -ne 'OK') { return }
        Invoke-ImportConfig $dlg.FileName
    } catch {
        Write-Erreur 'Import de configuration' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})

$btnCfgSupprimer.Add_Click({
    try {
        if ($gridCfg.SelectedRows.Count -eq 0) { return }
        $cfg = $gridCfg.SelectedRows[0].Tag
        $rep = [System.Windows.Forms.MessageBox]::Show(('Supprimer définitivement la configuration « {0} » et ses mesures ? Les services du PC ne sont pas modifiés.' -f $cfg.Nom), 'Confirmer', 'YesNo', 'Warning')
        if ($rep -ne 'Yes') { return }
        Remove-Item -LiteralPath $cfg.Fichier
        Update-Configs
    } catch {
        Write-Erreur 'Supprimer configuration' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})

$btnDiagRelancer.Add_Click({
    try {
        $script:Ressources = Get-Ressources
        Update-LabelRessources
        Update-Diagnostic
    } catch {
        Write-Erreur 'Relancer diagnostic' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})

$btnDiagCocher.Add_Click({
    try {
        $n = 0
        foreach ($row in $grid.Rows) {
            $s = $row.Tag
            if ($script:Recommandes.ContainsKey([string]$s.Name) -and -not $row.Cells['Appliquer'].ReadOnly) {
                $row.Cells['Cible'].Value = $ModeFr[$script:Recommandes[[string]$s.Name]]
                $row.Cells['Appliquer'].Value = $true
                $n++
            }
        }
        if ($n -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show('Aucun service à cocher : les modifications sans risque sont déjà appliquées.', 'Service Minimum', 'OK', 'Information')
        } else {
            $statut.Text = ('{0} service(s) recommandés par le diagnostic sont cochés : vérifier la liste, puis « APPLIQUER LA SÉLECTION ».' -f $n)
        }
    } catch {
        Write-Erreur 'Cocher recommandes' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})

$btnDiagReduction.Add_Click({
    try {
        $bilan = Get-BilanReduction
        $palier = $bilan.Palier
        if (-not $palier) {
            [void][System.Windows.Forms.MessageBox]::Show(("RÉDUCTION PROGRESSIVE`r`n`r`n{0}`r`n`r`n{1}" -f $bilan.Constat, $bilan.Conseil), 'Service Minimum - réduction progressive', 'OK', 'Information')
            return
        }
        $lignes = @($palier.Changements | Select-Object -First 20 | ForEach-Object {
            $detail = ''
            if ($_.State -eq 'Running' -and [int]$_.MemMo -gt 0) { $detail = '  ({0} Mo)' -f $_.MemMo }
            '  {0} : {1} -> {2}{3}' -f $_.DisplayName, $ModeFr[$_.Avant], $ModeFr[$_.Cible], $detail
        })
        $texte = "RÉDUCTION PROGRESSIVE - palier {0} sur {1} : {2}`r`n`r`n{3}`r`n`r`n{4}" -f $palier.Num, $ReductionNbPaliers, $palier.Titre, $palier.Explication, ($lignes -join "`r`n")
        if ($palier.Changements.Count -gt 20) { $texte += "`r`n  ..." }
        $enCours = @($bilan.Etats | Where-Object { $_.Etat -eq 'En attente de redémarrage' -or $_.Etat -eq 'En observation' })
        if ($enCours.Count -gt 0) {
            $texte += "`r`n`r`nATTENTION : {0} service(s) du palier précédent sont encore en observation ({1}). Mieux vaut attendre la fin de l'observation avant d'aller plus loin : si une fonction venait à manquer, on saurait quel palier est en cause." -f $enCours.Count, (Get-Noms $enCours 6)
        }
        $texte += "`r`n`r`nCocher ces {0} service(s) dans la liste du haut ?`r`nRien n'est modifié tant que « APPLIQUER LA SÉLECTION » n'est pas cliqué ; chaque ligne peut encore être décochée." -f $palier.Changements.Count
        $rep = [System.Windows.Forms.MessageBox]::Show($texte, 'Service Minimum - réduction progressive', 'YesNo', 'Question')
        if ($rep -ne 'Yes') { return }
        $voulu = @{}
        foreach ($c in $palier.Changements) { $voulu[[string]$c.Name] = [string]$c.Cible }
        $n = 0
        foreach ($row in $grid.Rows) {
            $s = $row.Tag
            if ($s -and $voulu.ContainsKey([string]$s.Name) -and -not $row.Cells['Appliquer'].ReadOnly) {
                $row.Cells['Cible'].Value = $ModeFr[$voulu[[string]$s.Name]]
                $row.Cells['Appliquer'].Value = $true
                $n++
            }
        }
        $r = Get-Reduction
        $r.DernierPalier = [int]$palier.Num
        $r.DateDernierPalier = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Save-Reduction
        if ($n -lt $palier.Changements.Count) {
            [void][System.Windows.Forms.MessageBox]::Show(("{0} service(s) cochés sur {1} : les autres ne sont pas affichés ou ne sont pas modifiables. Remettre les filtres de la liste sur « Tout » puis relancer le palier." -f $n, $palier.Changements.Count), 'Service Minimum - réduction progressive', 'OK', 'Information')
        }
        $statut.Text = ('Palier {0} : {1} service(s) cochés. Vérifier la liste, puis « APPLIQUER LA SÉLECTION ». Ensuite, redémarrer Windows et travailler normalement {2} jours avant le palier suivant.' -f $palier.Num, $n, $ReductionObservationJours)
    } catch {
        Write-Erreur 'Reduction progressive' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})

$btnDiagExporter.Add_Click({
    try {
        $fichier = Join-Path $Donnees ('diagnostic-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $lignes = New-Object System.Collections.ArrayList
        [void]$lignes.Add(('SERVICE MINIMUM - diagnostic du {0} - {1}' -f (Get-Date -Format 'dd/MM/yyyy HH:mm'), $env:COMPUTERNAME))
        [void]$lignes.Add('')
        foreach ($x in $script:Diagnostic) {
            [void]$lignes.Add(('[{0}] {1}' -f $x.Priorite, $x.Domaine))
            [void]$lignes.Add(('  Constat : {0}' -f $x.Constat))
            [void]$lignes.Add(('  Amélioration proposée : {0}' -f $x.Conseil))
            [void]$lignes.Add('')
        }
        $lignes | Set-Content -LiteralPath $fichier -Encoding UTF8
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $fichier)
    } catch {
        Write-Erreur 'Exporter diagnostic' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})

# Rafraichissement periodique de l'utilisation des ressources
$minuteur = New-Object System.Windows.Forms.Timer
$minuteur.Interval = 10000
$minuteur.Add_Tick({
    try { Receive-ImportsEnAttente } catch { Write-Erreur 'Imports en attente' $_ }
    try {
        if (-not $form.Visible) { return }
        $script:Ressources = Get-Ressources
        Update-LabelRessources
    } catch { }
})
$form.Add_FormClosed({
    $minuteur.Stop()
    $minuteurSuivi.Stop()
    $minuteurHttp.Stop()
    Stop-ServeurLocal
    try { if ($script:Icone) { $script:Icone.Visible = $false; $script:Icone.Dispose() } } catch { }
})

# ---------------------------------------------------------------- Surveillance : minuteur, icone, actions
$minuteurSuivi = New-Object System.Windows.Forms.Timer
$minuteurSuivi.Interval = ($IntervalleSuiviMin * 60000)
$minuteurSuivi.Add_Tick({
    try { Update-Surveillance } catch { Write-Erreur 'Surveillance periodique' $_ }
})

# Tableau de bord local et trace reseau : une requete et un pas de trace par passage
$minuteurHttp = New-Object System.Windows.Forms.Timer
$minuteurHttp.Interval = 80
$minuteurHttp.Add_Tick({
    try {
        if ($script:TacheHttp -and $script:TacheHttp.IsCompleted) {
            $contexte = $null
            try { $contexte = $script:TacheHttp.Result } catch { $contexte = $null }
            try { $script:TacheHttp = $script:Ecouteur.GetContextAsync() } catch { $script:TacheHttp = $null }
            if ($contexte) { Invoke-RequeteLocale $contexte }
        }
        Step-Trace
    } catch { Write-Erreur 'Tableau de bord (minuteur)' $_ }
})

$btnTableau.Add_Click({
    try { Open-Tableau } catch {
        Write-Erreur 'Tableau de bord' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})
$btnPartager.Add_Click({
    try { Show-Partage } catch {
        Write-Erreur 'Partager' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})
$btnAnoPartager.Add_Click({
    try { Show-Partage } catch {
        Write-Erreur 'Partager' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})
$btnDidacticiel.Add_Click({
    try {
        if (Test-Path -LiteralPath $FichierDidacticiel) {
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $FichierDidacticiel)
        } else {
            [void][System.Windows.Forms.MessageBox]::Show(('Fichier introuvable : {0}' -f $FichierDidacticiel), 'Service Minimum', 'OK', 'Warning')
        }
    } catch {
        Write-Erreur 'Didacticiel' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})

# Icone pres de l'horloge : l'application y reste quand elle est lancee au demarrage
try {
    $script:Icone = New-Object System.Windows.Forms.NotifyIcon
    $script:Icone.Icon = [System.Drawing.SystemIcons]::Shield
    $script:Icone.Text = 'Service Minimum - surveillance des services et des ports'
    $menuIcone = New-Object System.Windows.Forms.ContextMenuStrip
    $entreeOuvrir = $menuIcone.Items.Add('Ouvrir Service Minimum')
    $entreeRelever = $menuIcone.Items.Add('Relever maintenant')
    $entreeQuitter = $menuIcone.Items.Add('Quitter (arrête la surveillance)')
    $entreeOuvrir.Add_Click({ try { Show-Fenetre } catch { Write-Erreur 'Ouvrir' $_ } })
    $entreeRelever.Add_Click({ try { Update-Surveillance } catch { Write-Erreur 'Relever' $_ } })
    $entreeQuitter.Add_Click({ $script:Quitter = $true; $form.Close() })
    $script:Icone.ContextMenuStrip = $menuIcone
    $script:Icone.Add_DoubleClick({ try { Show-Fenetre } catch { Write-Erreur 'Ouvrir' $_ } })
    $script:Icone.Add_BalloonTipClicked({ try { Show-Fenetre } catch { Write-Erreur 'Ouvrir' $_ } })
    $script:Icone.Visible = $true
} catch {
    Write-Demarrage ('icone de notification indisponible : ' + $_.Exception.Message)
    $script:Icone = $null
}

# Fermer la fenetre : si la surveillance au demarrage est active, l'application reste pres de l'horloge
$form.Add_FormClosing({
    param($s, $e)
    try {
        if ($script:VersZone -and $script:Icone -and -not $script:Quitter -and $e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
            $e.Cancel = $true
            $form.Hide()
            if (-not $script:InfoZoneDonnee) {
                $script:InfoZoneDonnee = $true
                $script:Icone.ShowBalloonTip(8000, 'Service Minimum', 'La surveillance continue. Double-clic sur cette icône pour rouvrir la fenêtre ; clic droit > Quitter pour arrêter.', [System.Windows.Forms.ToolTipIcon]::Info)
            }
        }
    } catch { Write-Erreur 'Fermeture' $_ }
})

$chkDemarrage.Add_Click({
    try {
        if (-not $EstAdmin) {
            [void][System.Windows.Forms.MessageBox]::Show('Lecture seule : relancer Service Minimum en administrateur pour changer ce réglage.', 'Service Minimum', 'OK', 'Information')
            $chkDemarrage.Checked = (Test-DemarrageAuto)
            return
        }
        Set-DemarrageAuto $chkDemarrage.Checked
        $script:VersZone = ($chkDemarrage.Checked -or $ModeDemarrage)
        Write-JournalAction 'demarrage-automatique' 'Service Minimum' '' ([string]$chkDemarrage.Checked) 'OK'
        if ($chkDemarrage.Checked) {
            [void][System.Windows.Forms.MessageBox]::Show("Service Minimum se lancera à chaque ouverture de session Windows, sans demande de confirmation, réduit près de l'horloge (icône en forme de bouclier).`r`n`r`nIl relève les services, les applications, les ports et les connexions toutes les $IntervalleSuiviMin minutes. Fermer la fenêtre ne l'arrête plus : clic droit sur l'icône > Quitter.", 'Service Minimum', 'OK', 'Information')
        }
    } catch {
        Write-Erreur 'Demarrage automatique' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
        $chkDemarrage.Checked = (Test-DemarrageAuto)
    }
})

function Update-ApresAction {
    # Apres un arret ou un blocage : inventaire et releve a jour
    try { Update-Grille } catch { Write-Erreur 'Update-Grille' $_ }
    try { Update-Surveillance } catch { Write-Erreur 'Update-Surveillance' $_ }
}

$btnArreterSvc.Add_Click({
    try {
        $row = $null
        if ($grid.CurrentRow -and $grid.CurrentRow.Visible) { $row = $grid.CurrentRow }
        if (-not $row -or -not $row.Tag) {
            [void][System.Windows.Forms.MessageBox]::Show('Cliquer d''abord sur la ligne du service à arrêter.', 'Service Minimum', 'OK', 'Information')
            return
        }
        if (Stop-ServiceComplet ([string]$row.Tag.Name)) { Update-ApresAction }
    } catch {
        Write-Erreur 'Arreter le service' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})

$btnAnoActualiser.Add_Click({
    try {
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        Update-Surveillance
    } catch { Write-Erreur 'Relever maintenant' $_ }
    finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
})
$btnPortsActualiser.Add_Click({
    try {
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        Update-Surveillance
    } catch { Write-Erreur 'Relever maintenant' $_ }
    finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
})
$cmbPorts.Add_SelectedIndexChanged({ try { Show-Reseau } catch { Write-Erreur 'Show-Reseau' $_ } })
$cmbEtatPorts.Add_SelectedIndexChanged({ try { Show-Reseau } catch { Write-Erreur 'Show-Reseau' $_ } })
$cmbEtat.Add_SelectedIndexChanged({ try { [void](Update-Filtre) } catch { Write-Erreur 'Update-Filtre' $_ } })

$btnApprouverSvc.Add_Click({
    try {
        $row = $null
        if ($grid.CurrentRow -and $grid.CurrentRow.Visible) { $row = $grid.CurrentRow }
        if (-not $row -or -not $row.Tag) {
            [void][System.Windows.Forms.MessageBox]::Show('Cliquer d''abord sur la ligne du service.', 'Service Minimum', 'OK', 'Information')
            return
        }
        $sv = $row.Tag
        $approuve = Set-Approuve ('svc|' + [string]$sv.Name) ([string]$sv.DisplayName)
        Update-ColonneUsage
        if ($approuve) { $statut.Text = ('« {0} » est déclaré habituel : il ne sera plus signalé inhabituel ni suspect.' -f $sv.DisplayName) }
        else { $statut.Text = ('« {0} » n''est plus déclaré habituel : il est de nouveau classé d''après l''historique.' -f $sv.DisplayName) }
    } catch {
        Write-Erreur 'Declarer habituel (service)' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})

$btnAnoArreter.Add_Click({
    try {
        if ($gridAno.SelectedRows.Count -eq 0 -or -not $gridAno.SelectedRows[0].Tag) {
            [void][System.Windows.Forms.MessageBox]::Show('Cliquer d''abord sur la ligne de l''anomalie concernée.', 'Service Minimum', 'OK', 'Information')
            return
        }
        $a = $gridAno.SelectedRows[0].Tag
        if ([string]$a.Cle -like 'per|*') {
            [void][System.Windows.Forms.MessageBox]::Show('Cette anomalie concerne un périphérique ou un réseau Wi-Fi : elle se traite dans l''onglet « Périphériques ».', 'Service Minimum', 'OK', 'Information')
            $onglets.SelectedTab = $pagePer
            return
        }
        if ([string]$a.Cle -like 'dem|*') {
            [void][System.Windows.Forms.MessageBox]::Show('Cette anomalie concerne un programme lancé au démarrage de Windows : elle se traite dans l''onglet « Démarrage de Windows ».', 'Service Minimum', 'OK', 'Information')
            $onglets.SelectedTab = $pageDem
            return
        }
        if (-not $a.Nom) {
            [void][System.Windows.Forms.MessageBox]::Show(("Cette ligne concerne un processus partagé par plusieurs services ({0}).`r`n`r`nChoisir le service à arrêter dans la liste du haut, puis « Arrêter le service sélectionné... »." -f $a.Service), 'Service Minimum', 'OK', 'Information')
            return
        }
        if (Stop-ServiceComplet ([string]$a.Nom)) { Update-ApresAction }
    } catch {
        Write-Erreur 'Arreter (anomalies)' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})

function Get-LignePort {
    if ($gridPorts.SelectedRows.Count -eq 0 -or -not $gridPorts.SelectedRows[0].Tag) {
        [void][System.Windows.Forms.MessageBox]::Show('Cliquer d''abord sur la ligne du port ou de la connexion.', 'Service Minimum', 'OK', 'Information')
        return $null
    }
    return $gridPorts.SelectedRows[0].Tag
}

$btnPortsArreter.Add_Click({
    try {
        $l = Get-LignePort
        if (-not $l) { return }
        $fait = $false
        $noms = @($l.NomsServices.ToArray())
        $svcPort = ''
        $cle = ([string]$l.Proto + '|' + [string]$l.Port)
        if ($l.Type -eq 'Écoute' -and $BasePorts.ContainsKey($cle)) { $svcPort = [string]$BasePorts[$cle].Service }
        if ($noms.Count -eq 1) {
            $fait = Stop-ServiceComplet ([string]$noms[0])
        } elseif ($noms.Count -gt 1 -and $svcPort -and ($noms -contains $svcPort)) {
            $fait = Stop-ServiceComplet $svcPort
        } elseif ($noms.Count -gt 1) {
            [void][System.Windows.Forms.MessageBox]::Show(("Ce port est tenu par un processus partagé par plusieurs services :`r`n`r`n  {0}`r`n`r`nArrêter le service voulu depuis la liste du haut (« Arrêter le service sélectionné... »), ou fermer le port avec « Bloquer ce port (pare-feu) »." -f ($l.Services -replace ', ', "`r`n  ")), 'Service Minimum', 'OK', 'Information')
        } elseif ($svcPort) {
            # Port tenu par Windows lui-meme pour le compte d'un service connu (ex. 445 = service Serveur)
            $fait = Stop-ServiceComplet $svcPort
        } else {
            $fait = Stop-Programme $l
        }
        if ($fait) { Update-ApresAction }
    } catch {
        Write-Erreur 'Arreter (ports)' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})

$btnPortsBloquer.Add_Click({
    try {
        $l = Get-LignePort
        if (-not $l) { return }
        if (-not $EstAdmin) {
            [void][System.Windows.Forms.MessageBox]::Show('Lecture seule : relancer Service Minimum en administrateur.', 'Service Minimum', 'OK', 'Information')
            return
        }
        if ($l.Type -ne 'Écoute' -or [int]$l.Port -le 0) {
            [void][System.Windows.Forms.MessageBox]::Show('Le blocage s''applique à un port en écoute précis. Pour couper une connexion établie, arrêter le service ou le programme qui la tient.', 'Service Minimum', 'OK', 'Information')
            return
        }
        if ($script:PortsBloques.ContainsKey(([string]$l.Proto + '|' + [string]$l.Port))) {
            [void][System.Windows.Forms.MessageBox]::Show('Ce port est déjà bloqué.', 'Service Minimum', 'OK', 'Information')
            return
        }
        $texte = "Bloquer les entrées sur le port {0} {1} dans le pare-feu Windows ?`r`n`r`n{2}`r`n`r`nLes autres appareils du réseau ne pourront plus joindre ce port. Le programme continue de tourner et les échanges sortants ne sont pas touchés. Réversible avec « Débloquer »." -f $l.Proto, $l.Port, $l.Note
        if ($l.Avis -eq 'Nécessaire') { $texte += "`r`n`r`nATTENTION : ce port est classé nécessaire au fonctionnement de Windows." }
        $rep = [System.Windows.Forms.MessageBox]::Show($texte, 'Bloquer un port', 'YesNo', 'Question')
        if ($rep -ne 'Yes') { return }
        Set-BlocagePort ([string]$l.Proto) ([int]$l.Port) $true
        Update-Surveillance
    } catch {
        Write-Erreur 'Bloquer un port' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})

$btnPortsDebloquer.Add_Click({
    try {
        $l = Get-LignePort
        if (-not $l) { return }
        if (-not $EstAdmin) {
            [void][System.Windows.Forms.MessageBox]::Show('Lecture seule : relancer Service Minimum en administrateur.', 'Service Minimum', 'OK', 'Information')
            return
        }
        if (-not $script:PortsBloques.ContainsKey(([string]$l.Proto + '|' + [string]$l.Port))) {
            [void][System.Windows.Forms.MessageBox]::Show('Ce port n''est pas bloqué par Service Minimum.', 'Service Minimum', 'OK', 'Information')
            return
        }
        Set-BlocagePort ([string]$l.Proto) ([int]$l.Port) $false
        Update-Surveillance
    } catch {
        Write-Erreur 'Debloquer un port' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})

function Open-Journal([string]$fichier) {
    if (Test-Path -LiteralPath $fichier) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $fichier)
    } else {
        [void][System.Windows.Forms.MessageBox]::Show('Ce journal est encore vide.', 'Service Minimum', 'OK', 'Information')
    }
}
$btnPortsOrigine.Add_Click({
    try {
        $l = Get-LignePort
        if (-not $l) { return }
        Show-Origine $l
    } catch {
        Write-Erreur 'Origine' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})
$gridPorts.Add_CellDoubleClick({
    param($s, $e)
    try {
        if ($e.RowIndex -lt 0) { return }
        $l = $gridPorts.Rows[$e.RowIndex].Tag
        if ($l) { Show-Origine $l }
    } catch {
        Write-Erreur 'Origine (double-clic)' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})

$btnPortsApprouver.Add_Click({
    try {
        $l = Get-LignePort
        if (-not $l) { return }
        if ($l.Type -eq 'Connexion') {
            $cle = 'cnx|' + [string]$l.Processus
            $libelle = 'Connexions du programme ' + [string]$l.Processus
        } else {
            $cle = 'port|' + [string]$l.Cle
            $libelle = ('Port {0} {1} ouvert par {2}' -f $l.Proto, $l.PortTexte, $l.Processus)
        }
        $approuve = Set-Approuve $cle $libelle
        Update-Surveillance
        if ($approuve) { $statut.Text = ($libelle + ' : déclaré habituel.') } else { $statut.Text = ($libelle + ' : n''est plus déclaré habituel.') }
    } catch {
        Write-Erreur 'Declarer habituel (port)' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})
# Demarrage de Windows : actions
$cmbDem.Add_SelectedIndexChanged({ try { Show-Demarrage } catch { Write-Erreur 'Show-Demarrage' $_ } })
$cmbEtatDem.Add_SelectedIndexChanged({ try { Show-Demarrage } catch { Write-Erreur 'Show-Demarrage' $_ } })
$btnDemActualiser.Add_Click({
    try {
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        Update-OngletDemarrage
    } catch { Write-Erreur 'Relever le demarrage' $_ }
    finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
})
$btnDemDesactiver.Add_Click({
    try {
        $l = Get-LigneDem
        if (-not $l) { return }
        if (Set-ActivationDemarrage $l $false) { Update-OngletDemarrage }
    } catch {
        Write-Erreur 'Desactiver au demarrage' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})
$btnDemActiver.Add_Click({
    try {
        $l = Get-LigneDem
        if (-not $l) { return }
        if (Set-ActivationDemarrage $l $true) { Update-OngletDemarrage }
    } catch {
        Write-Erreur 'Activer au demarrage' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})
$btnDemApprouver.Add_Click({
    try {
        $l = Get-LigneDem
        if (-not $l) { return }
        $approuve = Set-Approuve ('dem|' + $l.Cle) ([string]$l.Nom)
        Update-OngletDemarrage
        if ($approuve) { $statut.Text = ('« {0} » est déclaré habituel au démarrage.' -f $l.Nom) } else { $statut.Text = ('« {0} » n''est plus déclaré habituel.' -f $l.Nom) }
    } catch {
        Write-Erreur 'Declarer habituel (demarrage)' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})
$btnDemAjouter.Add_Click({
    try { if (Add-ProgrammeDemarrage) { Update-OngletDemarrage } } catch {
        Write-Erreur 'Ajouter au demarrage' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})
$btnDemRetirer.Add_Click({
    try {
        $l = Get-LigneDem
        if (-not $l) { return }
        if (Remove-ElementDossierDemarrage $l) { Update-OngletDemarrage }
    } catch {
        Write-Erreur 'Retirer du demarrage' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})
$btnDemOuvrir.Add_Click({
    try {
        $l = Get-LigneDem
        if (-not $l) { return }
        $cible = [string]$l.Fichier
        if (-not $cible) { $cible = [string]$l.Exe }
        if ($cible -and (Test-Path -LiteralPath $cible)) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $cible) }
        else { [void][System.Windows.Forms.MessageBox]::Show('Le programme est introuvable sur le disque.', 'Service Minimum', 'OK', 'Information') }
    } catch { Write-Erreur 'Ouvrir l''emplacement' $_ }
})
$btnDemJournal.Add_Click({ try { Open-Journal $FichierJournalDem } catch { Write-Erreur 'Journal' $_ } })

# Peripheriques : releve apres un branchement (deux secondes apres le dernier message de Windows) et actions
$minuteurPer = New-Object System.Windows.Forms.Timer
$minuteurPer.Interval = 2000
$minuteurPer.Add_Tick({
    $minuteurPer.Stop()
    try {
        Update-Peripheriques
        Update-LignesPeripheriques
        Show-Peripheriques
        Send-AlerteNouveauxPeripheriques
    } catch { Write-Erreur 'Branchement de peripherique' $_ }
})
$cmbPer.Add_SelectedIndexChanged({ try { Show-Peripheriques } catch { Write-Erreur 'Show-Peripheriques' $_ } })
$cmbEtatPer.Add_SelectedIndexChanged({ try { Show-Peripheriques } catch { Write-Erreur 'Show-Peripheriques' $_ } })
$chkDebranches.Add_CheckedChanged({ try { Show-Peripheriques } catch { Write-Erreur 'Show-Peripheriques' $_ } })

$btnPerActualiser.Add_Click({
    try {
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        Update-OngletPeripheriques $true
    } catch { Write-Erreur 'Relever les peripheriques' $_ }
    finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
})

$btnPerDesactiver.Add_Click({
    try {
        $l = Get-LignePer
        if (-not $l) { return }
        if (Set-EtatPeripherique $l $false) { Update-OngletPeripheriques $false }
    } catch {
        Write-Erreur 'Desactiver un peripherique' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})

$btnPerReactiver.Add_Click({
    try {
        $l = Get-LignePer
        if (-not $l) { return }
        if (Set-EtatPeripherique $l $true) { Update-OngletPeripheriques $false }
    } catch {
        Write-Erreur 'Reactiver un peripherique' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})

$btnPerApprouver.Add_Click({
    try {
        $l = Get-LignePer
        if (-not $l) { return }
        if ($l.Genre -eq 'carte') {
            [void][System.Windows.Forms.MessageBox]::Show('La carte Wi-Fi est toujours considérée comme habituelle.', 'Service Minimum', 'OK', 'Information')
            return
        }
        if ($l.Genre -eq 'pnp') { $cle = 'dev|' + $l.Ident } else { $cle = 'wifi|' + $l.SSID }
        $approuve = Set-Approuve $cle ([string]$l.Nom)
        Update-LignesPeripheriques
        Show-Peripheriques
        if ($approuve) { $statut.Text = ('« {0} » est déclaré habituel.' -f $l.Nom) } else { $statut.Text = ('« {0} » n''est plus déclaré habituel.' -f $l.Nom) }
    } catch {
        Write-Erreur 'Declarer habituel (peripherique)' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})

$btnPerOublier.Add_Click({
    try {
        $l = Get-LignePer
        if (-not $l) { return }
        if (Remove-ReseauWifi $l) { Update-OngletPeripheriques $true }
    } catch {
        Write-Erreur 'Oublier un reseau Wi-Fi' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})

$btnPerWifi.Add_Click({
    try {
        $carte = @($script:LignesPer | Where-Object { $_.Genre -eq 'carte' }) | Select-Object -First 1
        if (-not $carte) {
            [void][System.Windows.Forms.MessageBox]::Show('Aucune carte Wi-Fi trouvée sur ce poste.', 'Service Minimum', 'OK', 'Information')
            return
        }
        $activer = ($carte.Etat -like 'Désactiv*')
        if (Set-EtatPeripherique $carte $activer) { Update-OngletPeripheriques $false }
    } catch {
        Write-Erreur 'Couper le Wi-Fi' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})

$btnPerBluetooth.Add_Click({
    try {
        $radio = @($script:LignesPer | Where-Object { (Test-RadioBluetooth $_) -and $_.Present }) | Select-Object -First 1
        if (-not $radio) {
            [void][System.Windows.Forms.MessageBox]::Show('Aucun adaptateur Bluetooth trouvé sur ce poste.', 'Service Minimum', 'OK', 'Information')
            return
        }
        $activer = ($radio.Code -eq 22)
        if (Set-EtatPeripherique $radio $activer) { Update-OngletPeripheriques $false }
    } catch {
        Write-Erreur 'Couper le Bluetooth' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})

$btnPerUsb.Add_Click({
    try {
        if (-not $EstAdmin) {
            [void][System.Windows.Forms.MessageBox]::Show('Lecture seule : relancer Service Minimum en administrateur.', 'Service Minimum', 'OK', 'Information')
            return
        }
        $bloque = Test-StockageUsbBloque
        if ($bloque) {
            $texte = "Débloquer les clés et disques USB ?`r`n`r`nIls seront de nouveau reconnus dès leur prochain branchement."
        } else {
            $texte = "Bloquer les clés et disques USB ?`r`n`r`nLes clés et disques USB branchés à partir de maintenant ne seront plus reconnus. Ceux déjà branchés restent utilisables jusqu'à leur débranchement. Les téléphones, claviers, souris, imprimantes et casques ne sont pas concernés.`r`n`r`nRéversible avec « Débloquer les clés USB »."
        }
        if ([System.Windows.Forms.MessageBox]::Show($texte, 'Clés USB', 'YesNo', 'Question') -ne 'Yes') { return }
        Set-StockageUsb (-not $bloque)
        $evt = 'Clés USB bloquées'
        if ($bloque) { $evt = 'Clés USB débloquées' }
        Write-JournalPeripheriques $evt ([pscustomobject]@{ Type = 'USB'; Nom = 'Stockage USB'; Classe = 'DiskDrive'; Id = 'USBSTOR, UASPStor' }) ''
        Write-JournalAction 'stockage-usb' 'USBSTOR, UASPStor' ([string]$bloque) ([string](-not $bloque)) 'OK'
        Show-Peripheriques
    } catch {
        Write-Erreur 'Blocage des cles USB' $_
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
    }
})

$btnPerJournal.Add_Click({ try { Open-Journal $FichierJournalPer } catch { Write-Erreur 'Journal' $_ } })

$btnAnoJournal.Add_Click({ try { Open-Journal $FichierJournalAno } catch { Write-Erreur 'Journal' $_ } })
$btnPortsJournal.Add_Click({ try { Open-Journal $FichierJournalPorts } catch { Write-Erreur 'Journal' $_ } })

$btnRestaurer.Add_Click({
    $fichiers = @(Get-ChildItem -LiteralPath $DirReleves -Filter 'releve-*.json' | Sort-Object Name -Descending)
    if ($fichiers.Count -eq 0) { return }
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Restaurer les modes de démarrage d''un relevé'
    $dlg.Size = New-Object System.Drawing.Size(520, 420)
    $dlg.StartPosition = 'CenterParent'
    $dlg.Font = $form.Font
    $lst = New-Object System.Windows.Forms.ListBox
    $lst.Dock = 'Fill'
    foreach ($f in $fichiers) {
        $motif = ''
        try { $motif = (Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).Motif } catch { }
        [void]$lst.Items.Add(('{0}   [{1}]' -f $f.BaseName, $motif))
    }
    $lst.SelectedIndex = 0
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Restaurer ce relevé'
    $ok.Dock = 'Bottom'
    $ok.Height = 34
    $ok.DialogResult = 'OK'
    [void]$dlg.Controls.Add($lst)
    [void]$dlg.Controls.Add($ok)
    if ($dlg.ShowDialog($form) -ne 'OK' -or $lst.SelectedIndex -lt 0) { return }
    $releve = Get-Content -LiteralPath $fichiers[$lst.SelectedIndex].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $ancien = @{}
    foreach ($s in $releve.Services) { $ancien[$s.Name] = $s.StartMode }
    $ecarts = @($script:Inventaire | Where-Object { $_.Cat -ne 'U' -and $ancien.ContainsKey($_.Name) -and $ModeFr.ContainsKey([string]$ancien[$_.Name]) -and $ancien[$_.Name] -ne $_.StartMode } | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; DisplayName = $_.DisplayName; Avant = $_.StartMode; Cible = [string]$ancien[$_.Name] }
    })
    if ($ecarts.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Aucun écart avec ce relevé.', 'Service Minimum', 'OK', 'Information')
        return
    }
    $rep = [System.Windows.Forms.MessageBox]::Show(("{0} service(s) reviendront à leur mode de démarrage du {1}. Continuer ?" -f $ecarts.Count, $releve.Date), 'Confirmer', 'YesNo', 'Question')
    if ($rep -ne 'Yes') { return }
    Invoke-Changements $ecarts $false 'avant-restauration'
    Update-Grille
})

$btnRapport.Add_Click({
    $fichier = Join-Path $Donnees ('rapport-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $script:Inventaire | ForEach-Object {
        [pscustomobject]@{
            Service   = $_.DisplayName
            Nom       = $_.Name
            Categorie = $LibelleCat[$_.Cat]
            Etat      = $_.State
            Demarrage = $_.StartMode
            Propose   = $_.Cible
            MemoireMo = $_.MemMo
            Note      = $_.Note
            Chemin    = $_.Chemin
        }
    } | Export-Csv -LiteralPath $fichier -NoTypeInformation -Delimiter ';' -Encoding UTF8
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $fichier)
})

$btnNecessaires.Add_Click({
    if (Test-Path -LiteralPath $FichierHistoNec) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $FichierHistoNec)
    } else {
        [void][System.Windows.Forms.MessageBox]::Show('Aucun historique pour l''instant.', 'Service Minimum', 'OK', 'Information')
    }
})

if (-not $EstAdmin) {
    $btnAppliquer.Enabled = $false
    $btnCfgAppliquer.Enabled = $false
    $btnRestaurer.Enabled = $false
    $btnArreterSvc.Enabled = $false
    $btnAnoArreter.Enabled = $false
    $btnPortsArreter.Enabled = $false
    $btnPortsBloquer.Enabled = $false
    $btnPortsDebloquer.Enabled = $false
    $chkDemarrage.Enabled = $false
    $btnPerDesactiver.Enabled = $false
    $btnPerReactiver.Enabled = $false
    $btnPerOublier.Enabled = $false
    $btnPerWifi.Enabled = $false
    $btnPerBluetooth.Enabled = $false
    $btnPerUsb.Enabled = $false
    $btnDemDesactiver.Enabled = $false
    $btnDemActiver.Enabled = $false
    $btnDemAjouter.Enabled = $false
}

# ---------------------------------------------------------------- Lancement
try {
    $form.Add_Shown({
        try {
            Write-Demarrage 'fenetre affichee, inventaire en cours'
            if ($ModeDemarrage -and $script:Icone) { $form.Hide() }
            $statut.Text = 'Inventaire des services en cours, quelques secondes...'
            $form.Refresh()
            try { Initialize-Suivi } catch { Write-Erreur 'Initialize-Suivi' $_ }
            try { $chkDemarrage.Checked = (Test-DemarrageAuto) } catch { }
            $script:VersZone = ($ModeDemarrage -or $chkDemarrage.Checked)
            Update-Grille
            [void](Save-Releve 'lancement' $script:Inventaire)
            $minuteur.Start()
            Write-Demarrage 'inventaire termine'
            try { Update-Surveillance } catch { Write-Erreur 'Update-Surveillance' $_ }
            $minuteurSuivi.Start()
            try { Start-ObservateurPeripheriques } catch { Write-Erreur 'Observateur des peripheriques' $_ }
            if ($FichierAImporter) { Invoke-ImportConfig $FichierAImporter }
            try { Receive-ImportsEnAttente } catch { Write-Erreur 'Imports en attente' $_ }
            $nbMesurees = @($script:LignesReseau | Where-Object { $_.Type -eq 'Connexion' -and [double]$_.Envoye -ge 0 }).Count
            $nbCnx = @($script:LignesReseau | Where-Object { $_.Type -eq 'Connexion' -and $_.Portee -ne 'Interne au PC' }).Count
            Write-Demarrage ('surveillance demarree - volumes mesures sur {0} connexion(s) sur {1} - statistiques TCP disponibles = {2}' -f $nbMesurees, $nbCnx, $script:StatsTcpDispo)
        } catch {
            Write-Demarrage ('ERREUR au chargement | ' + $_.Exception.Message + ' | ' + $_.ScriptStackTrace)
            [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
        }
    })
    if ($ModeDemarrage -and $script:Icone) {
        $form.WindowState = 'Minimized'
        $form.ShowInTaskbar = $false
    }
    Write-Demarrage 'ouverture de la fenetre'
    [System.Windows.Forms.Application]::Run($form)
    Write-Demarrage 'fenetre fermee'
} catch {
    Write-Demarrage ('ERREUR fenetre | ' + $_.Exception.Message + ' | ' + $_.ScriptStackTrace)
    [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Service Minimum - erreur', 'OK', 'Error')
}
