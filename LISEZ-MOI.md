# Platine — installer l'app sur ton iPhone depuis un PC

Tu n'as pas besoin de Mac ni de payer. GitHub compile l'app sur un de ses Mac, et Sideloadly l'installe sur ton iPhone.

Compte environ 30 minutes la première fois, puis 2 minutes pour chaque mise à jour.

---

## 1. Préparer l'iPhone (une seule fois)

1. Ouvre **Réglages → Confidentialité et sécurité → Mode développeur** et active-le. L'iPhone redémarre.
   *Si l'option n'apparaît pas, elle apparaîtra après la première installation avec Sideloadly (étape 4).*

## 2. Mettre le code sur GitHub (une seule fois)

1. Crée un compte gratuit sur **github.com**.
2. En haut à droite, clique sur **+ → New repository**.
   - Nom : `platine`
   - Choisis **Public** : la compilation est alors gratuite et illimitée. En **Private**, tu as environ 200 minutes de Mac par mois, soit 30 à 40 compilations, ce qui suffit aussi.
   - Clique sur **Create repository**.
3. Sur la page du dépôt, clique sur **uploading an existing file**.
4. Décompresse le zip sur ton PC, puis **glisse tout le contenu du dossier `Platine`** dans la page : les dossiers `Platine`, `.github`, et les fichiers `project.yml` et `LISEZ-MOI.md`.
   - Le dossier `.github` est indispensable. S'il n'apparaît pas dans l'Explorateur Windows, coche **Affichage → Éléments masqués**.
5. Clique sur **Commit changes**.

## 3. Récupérer l'app compilée

1. Dans ton dépôt, ouvre l'onglet **Actions**. La compilation « Construire Platine » démarre toute seule et dure 5 à 10 minutes.
2. Quand elle est verte ✓, clique dessus. En bas, dans **Artifacts**, télécharge **Platine-ipa**.
3. Décompresse-le : tu obtiens **Platine.ipa**.

*Si elle est rouge ✗ : télécharge l'artifact **journal-compilation** et envoie-moi son contenu, je corrige.*

## 4. Installer sur l'iPhone avec Sideloadly

1. Installe **iTunes** et **iCloud** depuis le site d'Apple (apple.com/fr/itunes), **pas** depuis le Microsoft Store. Sideloadly en a besoin pour parler à l'iPhone.
2. Installe **Sideloadly** depuis sideloadly.io.
3. Branche l'iPhone en USB, déverrouille-le et touche **Se fier à cet ordinateur**.
4. Dans Sideloadly :
   - glisse **Platine.ipa** dans la fenêtre ;
   - entre ton **identifiant Apple** (l'adresse e-mail de ton compte Apple) ;
   - clique sur **Start**, puis entre ton mot de passe Apple et le code de double authentification si demandé.
5. Sur l'iPhone, ouvre **Réglages → Général → VPN et gestion de l'appareil**, touche ton adresse e-mail puis **Faire confiance**.
6. Platine est sur ton écran d'accueil. 🎉

> Conseil : crée un identifiant Apple secondaire gratuit pour Sideloadly si tu préfères ne pas utiliser ton compte principal.

## 5. Le renouvellement tous les 7 jours

Sans compte développeur payant, Apple fait expirer l'app au bout de 7 jours. Ta musique et tes pochettes restent en place.

- **À la main** : rebranche l'iPhone et relance l'installation du même `.ipa` dans Sideloadly.
- **Automatique** : dans Sideloadly, coche **Auto-refresh** avant de cliquer sur Start. Ensuite, laisse Sideloadly ouvert sur ton PC (il tourne en arrière-plan) et l'iPhone sur le même Wi-Fi : il renouvelle l'app tout seul.

## 6. Mettre ta musique dans l'app

Deux façons :

- **Depuis l'iPhone** : bouton **+** en haut à droite, puis choisis tes fichiers dans Fichiers (iCloud Drive, Sur mon iPhone, clé USB…).
- **Depuis le PC** : ouvre l'app **Appareils Apple** (ou iTunes), sélectionne ton iPhone → **Fichiers** → **Platine**, et glisse tes MP3, M4A, FLAC ou WAV dedans. À la prochaine ouverture de Platine, ils sont importés automatiquement.

Formats lus : MP3, AAC/M4A, ALAC, FLAC, WAV, AIFF.

## 7. Changer les pochettes (autant de fois que tu veux)

Touche la pochette dans l'écran « En lecture », ou balaie un morceau vers la gauche → **Pochette**.

- **Photos** : image, GIF ou vidéo. Les GIF et vidéos tournent en boucle, sans le son.
- **Fichiers** : JPG, PNG, HEIC, GIF, MOV, MP4.
- **Appliquer à tout l'album** pour changer tous les morceaux d'un coup.
- **Pochette d'origine** pour revenir à celle du fichier audio.

L'écran verrouillé et le Centre de contrôle affichent l'image fixe (la première image d'un GIF ou d'une vidéo).

## 8. Modifier l'app

Change un fichier `.swift` sur GitHub (crayon ✏️ → **Commit changes**). La compilation repart toute seule, puis tu réinstalles le nouveau `.ipa` avec Sideloadly : tes morceaux sont conservés.

---

### Ce que contient le projet

```
Platine/
├─ .github/workflows/build.yml   compilation automatique sur GitHub
├─ project.yml                   description du projet Xcode (XcodeGen)
└─ Platine/
   ├─ PlatineApp.swift           point d'entrée
   ├─ Models/Track.swift         un morceau
   ├─ Models/Library.swift       bibliothèque, import, pochettes
   ├─ Audio/Player.swift         lecture, fondus, écran verrouillé, AirPods
   ├─ Views/LibraryView.swift    accueil, liste, mini-lecteur
   ├─ Views/NowPlayingView.swift écran « En lecture »
   ├─ Views/ArtworkEditor.swift  changement de pochette
   ├─ Views/Components.swift     verre liquide, pochettes animées, fond, barre de lecture
   ├─ Support/Palette.swift      couleurs extraites des pochettes
   └─ Assets.xcassets            icône de l'app
```

Sur iOS 26, l'app utilise le vrai **Liquid Glass** d'Apple. Sur iOS 17 à 18, elle utilise un verre dépoli équivalent.
