# raspberry-pi_doctor

Script de diagnostic rapide pour Raspberry Pi, base sur les erreurs systeme recentes.

## Objectif

Donner un etat de sante simple de la machine, avec deux niveaux de lecture:

- `--noob`: resume tres simple et actions conseillees
- `--advanced`: details techniques + top erreurs

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

Aide:

```bash
./doctor.sh --help
```

Note: sur certains systemes, lancer avec `sudo` permet d'avoir une vision plus complete des logs.

## Ce que le script analyse

Le script lit les erreurs recentes (`journalctl` en priorite, sinon `/var/log/syslog`) et cherche des signaux de:

- stockage (carte SD/disque)
- memoire (OOM)
- temperature / alimentation (throttling, under-voltage)
- reseau
- services (failed/timed out/segfault)
- noyau

## Optimisations de performance

Pour rester rapide et eviter une charge inutile:

- fenetre d'analyse courte: `2 hours ago`
- limite de lecture: `200` lignes max
- aucune boucle lourde ni scan complet du journal

## Exemple de workflow

1. Lancer `./doctor.sh --noob`
2. Si `ATTENTION` ou `CRITIQUE`, lancer `./doctor.sh --advanced`
3. Corriger le point principal (alimentation, SD, service, etc.) puis relancer
