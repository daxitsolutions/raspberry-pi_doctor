# raspberry-pi_doctor

Script de diagnostic rapide pour Raspberry Pi, base sur les erreurs systeme recentes.

## Objectif

Donner un etat de sante simple de la machine, avec trois niveaux de lecture:

- `--noob`: resume tres simple et actions conseillees
- `--advanced`: details techniques + top erreurs
- `--deep`: investigation poussee des causes d'indisponibilite

Le script est concu pour etre leger et rapide afin de limiter la chauffe du RPi.

## Fichier

- `doctor.sh`

## Installation

```bash
chmod +x doctor.sh
```

## Utilisation

Mode simple (par defaut):

```bash
./doctor.sh
```

Mode simple explicite:

```bash
./doctor.sh --noob
```

Mode detaille:

```bash
./doctor.sh --advanced
```

Mode investigation indisponibilite:

```bash
./doctor.sh --deep
```

Aide:

```bash
./doctor.sh --help
```

Note: sur certains systemes, lancer avec `sudo` permet d'avoir une vision plus complete des logs.

## Ce que le script analyse

Le script lit les logs systeme (`journalctl` en priorite, sinon `/var/log/syslog`) et cherche des signaux de:

- stockage (carte SD/disque)
- memoire (OOM)
- temperature / alimentation (throttling, under-voltage)
- reseau
- services (failed/timed out/segfault)
- noyau
- synchronisation de l'heure (NTP/clock jump)
- reset USB pouvant impacter un NIC externe

## Optimisations de performance

Pour rester rapide et eviter une charge inutile:

- fenetre d'analyse courte: `2 hours ago`
- limite de lecture: `200` lignes max
- aucune boucle lourde ni scan complet du journal

En `--deep`, la fenetre est etendue (`7 days ago`) avec une limite de lignes pour rester maitrisee (`6000`).

## Pourquoi `--deep` peut trouver des pannes que `--noob` ne voit pas

`--noob` et `--advanced` se basent surtout sur les erreurs critiques recentes.  
`--deep` va plus loin pour les pannes intermittentes:

- cherche aussi des warnings/evenements non critiques mais suspects
- analyse les coupures lien reseau (wifi/ethernet)
- inspecte l'historique de throttling Raspberry Pi via `vcgencmd get_throttled` (si dispo)
- verifie l'etat actuel des services reseau/SSH
- prend un historique plus large (7 jours)
- si un signal est `> 0`, lance automatiquement une investigation poussee

## Investigations poussees automatiques (`--deep`)

Quand un signal est non nul (ex: `reseau=1` ou `services critiques inactifs=2`), le script ajoute:

- les lignes exactes qui ont declenche l'alerte
- une explication lisible de la cause probable pour chaque ligne
- pour les services inactifs: source `systemctl is-active`, sous-etat (`SubState`) et logs recents par service

Objectif: expliquer concretement pourquoi l'alerte est levee, pas seulement donner un compteur.

## Exemple de workflow

1. Lancer `./doctor.sh --noob`
2. Si `ATTENTION` ou `CRITIQUE`, lancer `./doctor.sh --advanced`
3. Si deconnexions intermittentes sans erreur visible, lancer `./doctor.sh --deep`
4. Corriger le point principal (alimentation, SD, reseau, service, etc.) puis relancer
