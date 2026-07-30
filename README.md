# README — Environnement requis pour `ODM_batch_repair_makernote_batch.ps1`

Ce document explique **comment installer et configurer** chaque composant nécessaire au bon fonctionnement du script de traitement batch OpenDroneMap (ODM) avec réparation automatique des MakerNotes EXIF.

---

## Sommaire

1. [Prérequis système](#1-prérequis-système)
2. [PowerShell](#2-powershell)
3. [Docker Desktop](#3-docker-desktop)
4. [Support GPU NVIDIA (CUDA + Container Toolkit)](#4-support-gpu-nvidia-cuda--container-toolkit)
5. [Image Docker OpenDroneMap](#5-image-docker-opendronemap)
6. [ExifTool (hôte Windows)](#6-exiftool-hôte-windows)
7. [Partage de disques Docker](#7-partage-de-disques-docker)
8. [Arborescence des dossiers](#8-arborescence-des-dossiers)
9. [Droits et politique d'exécution](#9-droits-et-politique-dexécution)
10. [Vérification finale (checklist)](#10-vérification-finale-checklist)
11. [Lancer le script](#11-lancer-le-script)

---

## 1. Prérequis système

| Composant | Recommandation |
|---|---|
| OS | Windows 10/11 (64 bits), édition Pro/Entreprise recommandée pour WSL2 |
| RAM | 32 Go minimum (le script réserve jusqu'à 34 Go de swap Docker) |
| GPU | Carte NVIDIA compatible CUDA (pour `--gpus all`) |
| Disque | SSD recommandé, espace libre large sur le lecteur de sortie (`D:\resultats_odm`) — les nuages de points et orthophotos peuvent peser plusieurs Go par projet |
| Connexion internet | Requise au moins une fois pour télécharger l'image Docker ODM |

---

## 2. PowerShell

Le script est écrit en PowerShell natif Windows.

### Installation / vérification
```powershell
$PSVersionTable.PSVersion
```
- Windows 10/11 embarque déjà PowerShell 5.1.
- Pour PowerShell 7+ (optionnel mais recommandé) :
```powershell
winget install --id Microsoft.PowerShell --source winget
```

### Politique d'exécution
Par défaut, Windows bloque l'exécution de scripts `.ps1`. Autoriser localement :
```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```
Ou pour un lancement ponctuel sans changer la politique globale :
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\ODM_batch_repair_makernote_batch.ps1
```

---

## 3. Docker Desktop

Le script pilote entièrement ODM via des conteneurs Docker (`docker run ...`).

### Installation
1. Télécharger Docker Desktop : https://www.docker.com/products/docker-desktop/
2. Lancer l'installeur, cocher **"Use WSL 2 instead of Hyper-V"** lors de l'installation.
3. Redémarrer la machine si demandé.
4. Lancer Docker Desktop et attendre que l'icône baleine soit stable (pas en cours de démarrage).

### Vérification
```powershell
docker --version
docker run hello-world
```

### Configuration recommandée (Docker Desktop → Settings)
- **General** : activer *"Use the WSL 2 based engine"*
- **Resources → Advanced** (si backend Hyper-V) : allouer au moins 32 Go RAM, 8+ CPU
- Si backend **WSL2** : la limite mémoire se configure via un fichier `%UserProfile%\.wslconfig` :
```ini
[wsl2]
memory=32GB
swap=8GB
processors=8
```
Puis redémarrer WSL :
```powershell
wsl --shutdown
```

---

## 4. Support GPU NVIDIA (CUDA + Container Toolkit)

Le script utilise `--gpus all` : Docker doit pouvoir exposer le GPU NVIDIA aux conteneurs.

### Étapes
1. **Pilotes NVIDIA** à jour installés sur Windows (via GeForce Experience ou site NVIDIA).
2. **WSL2** doit être activé (le support GPU Docker Desktop passe par WSL2, pas par Hyper-V pur) :
```powershell
wsl --install
wsl --set-default-version 2
```
3. Docker Desktop détecte automatiquement le GPU si les pilotes WSL2 NVIDIA sont installés (pas besoin d'installer manuellement le NVIDIA Container Toolkit sous Windows — c'est géré par Docker Desktop + les pilotes NVIDIA CUDA on WSL).

### Vérification
```powershell
docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi
```
Si la commande affiche les infos de la carte GPU, le support est fonctionnel.

---

## 5. Image Docker OpenDroneMap

Le script utilise l'image `opendronemap/odm:latest`.

### Installation (téléchargement manuel, optionnel — sinon automatique au premier run)
```powershell
docker pull opendronemap/odm:latest
```

### Vérification
```powershell
docker images | findstr odm
```

> ℹ️ Cette image embarque déjà Python 3 et la librairie `exifread`, utilisés par le script pour le scan EXIF ciblé (`_scan_exif_manifest.py`). Aucune installation Python locale n'est nécessaire pour cette partie.

---

## 6. ExifTool (hôte Windows)

Contrairement au reste, la réparation des MakerNotes (`exiftool -MakerNotes=`) s'exécute **directement sur l'hôte Windows**, pas dans Docker.

### Installation
1. Télécharger la version Windows sur : https://exiftool.org/
2. Le fichier téléchargé s'appelle `exiftool(-k).exe` — le renommer en `exiftool.exe`.
3. Placer `exiftool.exe` dans un dossier inclus dans le `PATH`, par exemple `C:\Windows\` ou un dossier dédié ajouté au PATH :
```powershell
[Environment]::SetEnvironmentVariable("Path", $env:Path + ";C:\Outils\ExifTool", "User")
```
4. Redémarrer PowerShell.

### Vérification
```powershell
exiftool -ver
```

---

## 7. Partage de disques Docker

Le script monte des volumes (`-v`) depuis `C:\Users\dj_kone\dataset\...` et `D:\resultats_odm`. Docker Desktop doit être autorisé à accéder à ces lecteurs.

### Configuration (si backend Hyper-V classique)
Docker Desktop → **Settings → Resources → File sharing** → ajouter les lecteurs `C:` et `D:`.

### Avec backend WSL2 (par défaut aujourd'hui)
Le partage de fichiers est automatique pour tous les lecteurs Windows via `/mnt/c`, `/mnt/d`, etc. — aucune configuration manuelle nécessaire dans la plupart des cas récents de Docker Desktop.

### Vérification rapide
```powershell
docker run --rm -v "D:\resultats_odm:/test" alpine ls /test
```

---

## 8. Arborescence des dossiers

Le script attend cette structure :

```
C:\Users\dj_kone\dataset\opendrone\images\
 ├── Projet_A\
 │    ├── photo001.jpg
 │    ├── photo002.jpg
 │    └── ...
 ├── Projet_B\
 │    └── ...
 └── ...

D:\resultats_odm\        <- créé automatiquement par le script
 ├── odm_batch_summary.csv
 ├── Projet_A\
 │    ├── odm_log.txt
 │    ├── _SUCCESS.txt (si succès)
 │    └── ... (sorties ODM : DSM, DTM, nuage de points, orthophoto)
 └── ...
```

- Chaque **sous-dossier** de `baseInput` = un projet ODM distinct.
- Seules les extensions `.jpg/.jpeg/.JPG/.JPEG` sont prises en compte.
- Adapter les variables en tête de script si vos chemins diffèrent :
```powershell
$baseInput   = "C:\Users\dj_kone\dataset\opendrone\images"
$baseOutput  = "D:\resultats_odm"
```

---

## 9. Droits et politique d'exécution

- L'utilisateur Windows doit être membre du groupe **`docker-users`** pour utiliser Docker sans élévation systématique :
```powershell
net localgroup docker-users "NOM_UTILISATEUR" /add
```
(redémarrage de session nécessaire après ajout)

- Lancer PowerShell **en tant qu'administrateur** n'est généralement pas nécessaire une fois Docker correctement configuré, sauf si des restrictions de groupe le demandent.

---

## 10. Vérification finale (checklist)

Avant de lancer le script, valider chaque point :

- [ ] `docker --version` fonctionne
- [ ] `docker run hello-world` fonctionne
- [ ] `docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi` affiche le GPU
- [ ] `docker images` liste `opendronemap/odm:latest` (ou sera tiré automatiquement)
- [ ] `exiftool -ver` fonctionne dans PowerShell
- [ ] Le dossier `C:\Users\dj_kone\dataset\opendrone\images\` existe et contient des sous-dossiers projets avec des `.jpg`
- [ ] Le lecteur `D:\` a suffisamment d'espace libre
- [ ] Docker Desktop peut monter les lecteurs `C:` et `D:` (partage de fichiers)
- [ ] La politique d'exécution PowerShell autorise le script (`RemoteSigned` ou `-Bypass`)
- [ ] `.wslconfig` configuré avec assez de RAM/swap si backend WSL2

---

## 11. Lancer le script

```powershell
cd "C:\chemin\vers\le\script"
powershell.exe -ExecutionPolicy Bypass -File .\ODM_batch_repair_makernote_batch.ps1
```

Le script va alors :
1. Parcourir chaque sous-dossier de `$baseInput`
2. Lancer ODM sur chaque projet
3. En cas de crash lié aux MakerNotes/EXIF, scanner et réparer automatiquement les images fautives via `exiftool`
4. Relancer ODM après réparation
5. Consigner tous les résultats dans `D:\resultats_odm\odm_batch_summary.csv`

---

## Dépannage rapide

| Problème | Cause probable | Solution |
|---|---|---|
| `docker: command not found` | Docker Desktop non lancé ou non installé | Lancer Docker Desktop, vérifier l'installation |
| Conteneur qui plante immédiatement (OOM) | RAM insuffisante allouée à Docker/WSL2 | Augmenter `.wslconfig` ou les ressources Docker Desktop |
| `--gpus all` échoue | Pilotes NVIDIA absents/obsolètes ou WSL2 non activé | Mettre à jour les pilotes, activer WSL2 |
| `exiftool` non reconnu | Pas dans le PATH | Vérifier l'ajout au PATH, redémarrer le terminal |
| Volumes vides dans le conteneur | Partage de disque non autorisé | Vérifier Docker Desktop → File sharing |
| Script bloqué à l'exécution | Politique d'exécution PowerShell restrictive | `Set-ExecutionPolicy RemoteSigned` ou `-ExecutionPolicy Bypass` |
