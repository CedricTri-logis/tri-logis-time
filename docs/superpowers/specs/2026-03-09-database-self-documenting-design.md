# Design: Base de donnees auto-documentee

**Date:** 2026-03-09
**Statut:** Approuve

## Objectif

Transformer la base de donnees Supabase en documentation vivante en ajoutant des `COMMENT ON` structures sur toutes les tables et colonnes non-evidentes. Creer un skill et une regle CLAUDE.md pour que Claude consulte et maintienne ces commentaires systematiquement.

## Contexte

- 36+ tables, 100+ migrations, 19 specs, 50+ plans
- La logique metier est dispersee dans des fichiers markdown
- L'IA doit chercher dans plusieurs fichiers pour comprendre une table
- Les `COMMENT ON` PostgreSQL permettent d'embarquer la logique directement dans le schema

## Livrables

### 1. Skill `supabase-schema-context`

**Emplacement:** `/Users/cedric/.claude/skills/supabase-schema-context/SKILL.md`

**Declencheur:** Semi-automatique — Claude le consulte au debut d'une tache qui touche la DB ou quand il ecrit une migration.

**Contenu:**
- Format standard des COMMENT ON (semi-structure)
- Commande SQL pour lire les commentaires
- Checklist: toute migration qui cree/modifie une table DOIT inclure les COMMENT ON
- Guide de niveaux (C/B/A)
- Exemples concrets

### 2. Rule 8 dans CLAUDE.md

Nouvelle regle obligatoire:
- AVANT de commencer une tache DB: lire les COMMENT ON des tables impliquees
- AVANT toute migration: verifier les commentaires existants
- DANS toute migration: inclure les COMMENT ON mis a jour
- Ne jamais modifier une table sans avoir lu ses commentaires

### 3. Migration big bang

Une seule migration SQL non-destructive ajoutant tous les COMMENT ON.

## Format des commentaires

### Format semi-structure standard

```sql
COMMENT ON TABLE shifts IS '
ROLE: Quarts de travail des employes, du clock-in au clock-out.
STATUTS: active = en cours | completed = termine
REGLES: 1 seul shift actif par employe. Clock-out auto apres 16h sans activite.
RELATIONS: -> employee_profiles (N:1) | <- gps_points (1:N) | <- trips (1:N) | <- cleaning_sessions (1:N)
TRIGGERS: Sur completion -> calcule la duree totale.
';
```

### Sections disponibles

| Section | Usage | Obligatoire |
|---------|-------|-------------|
| `ROLE:` | Raison d'etre de la table | Oui |
| `STATUTS:` | Valeurs possibles et signification | Si applicable |
| `REGLES:` | Contraintes metier, limites, validations | Si applicable |
| `RELATIONS:` | FK critiques avec cardinalite (`->` parent, `<-` enfant) | Oui |
| `TRIGGERS:` | Effets de bord, webhooks, notifications | Si applicable |
| `ALGORITHME:` | Logique de calcul complexe | Si applicable |
| `RLS:` | Resume des politiques d'acces | Si applicable |

### Separateurs

- `|` entre les valeurs/items sur une meme ligne
- `->` pour les relations vers un parent
- `<-` pour les relations depuis un enfant
- `=` pour les definitions de valeurs

### Niveaux de detail

| Niveau | Tables | Detail |
|--------|--------|--------|
| **C (maximal)** | `employee_profiles`, `shifts`, `gps_points`, `trips`, `stationary_clusters`, `cleaning_sessions`, `day_approvals`, `locations` | Toutes les sections, regles completes, algorithmes |
| **B (moyen)** | Majorite des tables | ROLE + RELATIONS + sections pertinentes |
| **A (minimal)** | `app_config`, `app_settings`, `report_audit_logs` | ROLE seulement, 1 ligne |

### Colonnes a commenter

- Commenter: colonnes avec logique metier, valeurs enumerees, calculs, signification non-evidente
- Ne PAS commenter: `id`, `created_at`, `updated_at` (evidentes)

## Commandes SQL de consultation

```sql
-- Lire le commentaire d'une table
SELECT obj_description(c.oid)
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relname = 'TABLE_NAME' AND n.nspname = 'public';

-- Lire les commentaires de toutes les colonnes d'une table
SELECT a.attname AS column_name, col_description(a.attrelid, a.attnum) AS comment
FROM pg_attribute a
JOIN pg_class c ON a.attrelid = c.oid
JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE c.relname = 'TABLE_NAME' AND n.nspname = 'public' AND a.attnum > 0 AND NOT a.attisdropped
ORDER BY a.attnum;
```

## Ordre d'execution

1. Creer le skill `supabase-schema-context`
2. Mettre a jour CLAUDE.md global avec Rule 8
3. Lire toutes les specs et plans pour extraire la logique metier
4. Generer la migration big bang avec tous les COMMENT ON
5. Review
6. Appliquer la migration

## Risques

- **Aucun risque de donnees** — `COMMENT ON` est purement metadata
- **Risque de commentaires obsoletes** — mitige par le skill qui oblige la mise a jour lors de chaque migration
- **Volume de travail** — 36+ tables a documenter, extraction de 19 specs + 50 plans
