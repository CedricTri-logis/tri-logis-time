# Guide Speckit - Instructions pour Créer un ROADMAP

Ce document est un guide d'instructions pour Claude Code. Donne ce fichier à une nouvelle instance de Claude Code avec la description de ton produit, et il créera un fichier `IMPLEMENTATION_ROADMAP.md` structuré selon les bonnes pratiques Speckit.

---

## Comment utiliser ce guide

### Étape 1: Copie ce prompt à Claude Code

```
Lis le fichier SPECKIT_GUIDE.md dans ce projet. Ensuite, crée un fichier
IMPLEMENTATION_ROADMAP.md basé sur le produit que je vais te décrire.

Voici ce que je veux construire:
[DÉCRIS TON PRODUIT ICI]
```

### Étape 2: Décris ton produit

Inclus ces informations:
- **Quoi**: Qu'est-ce que l'app fait?
- **Pour qui**: Qui sont les utilisateurs?
- **Plateforme**: iOS, Android, Web, Desktop?
- **Backend**: Supabase, Firebase, custom API?
- **Fonctionnalités clés**: Liste les features principales
- **Contraintes**: Budget, timeline, team size, etc.

---

## Instructions pour Claude Code

> **CLAUDE CODE**: Quand un utilisateur te donne ce guide avec une description de produit, suis ces instructions pour créer le IMPLEMENTATION_ROADMAP.md.

### Processus à suivre

```
ÉTAPE 1: Analyser les requirements
         └─► Identifier toutes les fonctionnalités demandées

ÉTAPE 2: Identifier les domaines fonctionnels
         └─► Grouper les features par domaine logique

ÉTAPE 3: Appliquer le test de valeur indépendante
         └─► Pour chaque groupe: "Si on s'arrête ici, l'app est-elle utile?"

ÉTAPE 4: Définir le MVP
         └─► Quelles specs sont le minimum pour une app fonctionnelle?

ÉTAPE 5: Structurer chaque spec
         └─► Suivre le template ci-dessous

ÉTAPE 6: Mapper les dépendances
         └─► Créer le graphe de dépendances

ÉTAPE 7: Valider la cohérence
         └─► Vérifier que chaque spec livre de la valeur testable
```

---

## Règles Speckit à respecter

### Règle 1: Principe d'indépendance

Chaque spec DOIT être:

| Critère | Question à se poser |
|---------|---------------------|
| Indépendamment implémentable | Peut-on la développer sans attendre d'autres specs? |
| Indépendamment testable | Peut-on la tester seule et voir de la valeur? |
| Indépendamment déployable | Peut-on la livrer aux utilisateurs seule? |
| Indépendamment démontrable | Peut-on montrer quelque chose de fonctionnel? |

### Règle 2: Quand DIVISER en specs séparées

- User stories ne peuvent pas être testées indépendamment
- Features ont des domaines complètement différents
- Une story requiert qu'une autre soit complète avant
- Équipe différente travaillera dessus

### Règle 3: Quand COMBINER dans une seule spec

- User stories font partie du même parcours utilisateur
- Features partagent la même infrastructure de base
- Toutes les stories doivent être présentes pour avoir de la valeur
- Livrées comme une seule release

### Règle 4: Structure des phases

Chaque spec suit cette structure de phases:

```
Phase 1: Setup
├── Structure du projet
├── Dépendances
└── Configuration

Phase 2: Foundational (BLOQUANT)
├── Base de données / Schema
├── Auth framework (si applicable)
├── Modèles de base
└── Gestion d'erreurs

Phase 3+: User Stories (par priorité)
├── US1 (P1) - MVP
├── US2 (P2)
└── US3 (P3)

Phase N: Polish
├── Documentation
├── Tests additionnels
└── Optimisation
```

### Règle 5: Format des tâches

```
[ID] [P?] [Story] Description

- [ID]: T001, T002, T003...
- [P]: Peut être parallélisé (fichiers différents)
- [Story]: US1, US2, US3...
```

---

## Template du IMPLEMENTATION_ROADMAP.md

Claude Code DOIT générer un fichier avec cette structure:

```markdown
# [NOM DU PROJET] - Implementation Roadmap

**Projet**: [Description courte]
**Framework**: [Technologies]
**Backend**: [Backend choice]
**Utilisateurs cibles**: [Qui]
**Distribution**: [Comment]

---

## Executive Summary

[Résumé en 2-3 paragraphes]

### Aperçu des Specs

| Spec # | Nom | Priorité | Dépendances | MVP? |
|--------|-----|----------|-------------|------|
| 001 | ... | P0 | None | Yes |
| 002 | ... | P1 | 001 | Yes |
| ... | ... | ... | ... | ... |

### Flow de développement

[Diagramme ASCII montrant le flux]

---

## Décomposition des Specs

### Rationale

[Expliquer pourquoi ce découpage]

---

## Spec 001: [Nom]

**Branch**: `001-nom`
**Complexité**: [Low/Medium/High]

### Purpose

[Pourquoi cette spec existe - 1-2 phrases]

### Scope

#### In Scope
- [Ce qui est inclus]

#### Out of Scope
- [Ce qui N'EST PAS inclus - important!]

### User Stories

#### US1: [Titre] (P1)

**As a** [utilisateur]
**I want to** [action]
**So that** [bénéfice]

**Acceptance Criteria**:
- Given [contexte], when [action], then [résultat]

**Independent Test**: [Comment tester isolément]

### Technical Notes

[Notes d'implémentation importantes]

### Success Criteria

- [ ] [Critère mesurable 1]
- [ ] [Critère mesurable 2]

### Checkpoint

**Après cette spec**: [Ce qu'on peut faire/démontrer]

---

[RÉPÉTER POUR CHAQUE SPEC]

---

## Timeline Recommandée

[Ordre recommandé, sans estimations de temps]

### MVP Milestone

[Quelles specs = MVP]

---

## Graphe de Dépendances

[Diagramme ASCII des dépendances]

---

## Risques

| Risque | Impact | Mitigation |
|--------|--------|------------|
| ... | ... | ... |

---

## Prochaines Étapes

1. [Action 1]
2. [Action 2]
3. [Action 3]
```

---

## Test de Valeur - Questions à poser

Pour chaque spec, Claude Code DOIT répondre à ces questions:

```
□ Si on s'arrête après cette spec, l'app est-elle utile?
  └─► Si NON: Cette spec doit être combinée avec la suivante
  └─► Si OUI: C'est une bonne limite de spec

□ Peut-on tester cette spec sans les autres?
  └─► Si NON: Les dépendances sont-elles correctement définies?
  └─► Si OUI: Bon découpage

□ Peut-on déployer cette spec seule?
  └─► Si NON: Est-ce vraiment une spec séparée?
  └─► Si OUI: Checkpoint valide
```

---

## Exemples de découpage

### Exemple 1: App E-commerce

```
001-foundation       → Setup projet, DB schema
002-auth            → Login, register, profile
003-product-catalog → Liste produits, détails, recherche
004-shopping-cart   → Ajouter/retirer, voir panier
005-checkout        → Paiement, confirmation
006-order-history   → Voir commandes passées

MVP = 001-005 (peut acheter)
```

### Exemple 2: App de Notes

```
001-foundation     → Setup projet
002-note-crud      → Créer, lire, modifier, supprimer notes
003-organization   → Dossiers, tags, recherche
004-sync           → Sync cloud
005-sharing        → Partager notes

MVP = 001-002 (peut prendre des notes)
```

### Exemple 3: App GPS Tracker (ce projet)

```
001-foundation     → Setup Flutter, Supabase, DB
002-auth           → Login, consent privacy
003-shift          → Clock in/out avec GPS ponctuel
004-gps-tracking   → GPS toutes les 5 minutes (background)
005-offline        → Mode hors-ligne, sync
006-history        → Voir historique shifts

MVP = 001-004 (tracking GPS fonctionne)
```

---

## Commandes Speckit disponibles

Après avoir créé le ROADMAP, l'utilisateur peut utiliser:

| Commande | Quand l'utiliser |
|----------|------------------|
| `/speckit.specify` | Créer spec.md pour une spec |
| `/speckit.plan` | Créer plan.md avec design technique |
| `/speckit.tasks` | Générer tasks.md avec tâches |
| `/speckit.implement` | Exécuter les tâches |
| `/speckit.clarify` | Poser des questions de clarification |
| `/speckit.analyze` | Vérifier cohérence entre documents |

---

## Checklist finale pour Claude Code

Avant de livrer le IMPLEMENTATION_ROADMAP.md, vérifie:

- [ ] Chaque spec a un Purpose clair
- [ ] Chaque spec a Scope (In/Out) défini
- [ ] Chaque spec a des User Stories avec critères d'acceptation
- [ ] Chaque spec a des Success Criteria mesurables
- [ ] Chaque spec a un Checkpoint
- [ ] Le MVP est clairement identifié
- [ ] Les dépendances sont explicites
- [ ] Le graphe de dépendances n'a pas de cycles
- [ ] Le test de valeur passe pour chaque spec

---

## Notes pour l'utilisateur

- Ce guide est conçu pour être réutilisable sur n'importe quel projet
- Adapte la description de ton produit avec le plus de détails possible
- Plus tu donnes de contexte, meilleur sera le roadmap
- Tu peux demander à Claude Code d'ajuster le roadmap après génération
