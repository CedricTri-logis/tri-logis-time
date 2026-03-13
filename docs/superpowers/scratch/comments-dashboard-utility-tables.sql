-- =============================================================================
-- COMMENT ON statements for dashboard, report, and utility tables
-- Generated: 2026-03-09
-- =============================================================================

-- =============================================================================
-- SECTION 1: DIAGNOSTIC & DEVICE TABLES (Level B)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1.1 diagnostic_logs
-- ---------------------------------------------------------------------------
COMMENT ON TABLE diagnostic_logs IS '
ROLE: Journal des événements de diagnostic envoyés par les appareils mobiles pour visibilité à distance sur les problèmes GPS, shifts et synchronisation.
REGLES: Rétention de 90 jours (cron quotidien à 3h UTC). Sync par batch via RPC sync_diagnostic_logs. UUID client comme PK pour déduplication (ON CONFLICT = duplicate ignoré). L''employé ne peut soumettre que ses propres logs (vérification caller = employee_id).
RELATIONS: -> auth.users (N:1 via employee_id) | -> shifts (N:1 via shift_id, optionnel)
RLS: INSERT = employé authentifié (ses propres logs) | SELECT = admin et manager uniquement.
';

COMMENT ON COLUMN diagnostic_logs.event_category IS 'Catégorie technique de l''événement. Values: gps = suivi de position | shift = cycle clock-in/out | sync = synchronisation données | auth = authentification | permission = permissions OS | lifecycle = cycle de vie app | thermal = surchauffe appareil | error = erreur générique | network = connectivité réseau | battery = niveau batterie | memory = mémoire | crash = crash app | service = service background | satellite = réception satellite | doze = mode économie Android | motion = détection mouvement | metrickit = métriques iOS';

COMMENT ON COLUMN diagnostic_logs.severity IS 'Niveau de gravité. Values: info = information normale | warn = avertissement non-bloquant | error = erreur récupérable | critical = erreur bloquante nécessitant attention';

COMMENT ON COLUMN diagnostic_logs.metadata IS 'Données contextuelles libres en JSONB (stack trace, valeurs capteur, etc.)';

COMMENT ON COLUMN diagnostic_logs.received_at IS 'Horodatage de réception serveur (DEFAULT NOW()). Distinct de created_at qui est l''heure de capture sur l''appareil.';

COMMENT ON COLUMN diagnostic_logs.platform IS 'Plateforme mobile. Values: ios | android';

-- ---------------------------------------------------------------------------
-- 1.2 device_status
-- ---------------------------------------------------------------------------
COMMENT ON TABLE device_status IS '
ROLE: Instantané de l''état du device de chaque employé (permissions, version app, modèle), mis à jour à chaque clock-in via upsert.
REGLES: Une seule ligne par employé (UNIQUE sur employee_id). Upsert via ON CONFLICT — la ligne est créée au premier clock-in et mise à jour ensuite. Aucun historique conservé, seul le dernier état est stocké.
RELATIONS: -> employee_profiles (1:1 via employee_id ON DELETE CASCADE)
RLS: ALL = employé (sa propre ligne) | SELECT = admin/super_admin (toutes les lignes).
';

COMMENT ON COLUMN device_status.gps_permission IS 'Permission GPS accordée par l''OS. Values typiques: denied | whenInUse | always';

COMMENT ON COLUMN device_status.precise_location_enabled IS 'True si la localisation précise est activée (vs approximative sur iOS 14+)';

COMMENT ON COLUMN device_status.battery_optimization_disabled IS 'True si l''optimisation de batterie est désactivée pour l''app (important pour le tracking GPS en arrière-plan)';

COMMENT ON COLUMN device_status.app_standby_bucket IS 'Android App Standby Bucket. Values typiques: ACTIVE | WORKING_SET | FREQUENT | RARE | RESTRICTED. Affecte la fréquence des tâches background autorisées par Android.';

-- =============================================================================
-- SECTION 2: LUNCH BREAKS (Level B)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 2.1 lunch_breaks
-- ---------------------------------------------------------------------------
COMMENT ON TABLE lunch_breaks IS '
ROLE: Pauses dîner déclarées manuellement par les employés pendant un shift actif, déduites du temps de travail total dans les approbations.
REGLES: Une pause = started_at renseigné, ended_at NULL tant que la pause est en cours. La durée est soustraite de total_shift_minutes dans les approbations. Les pauses apparaissent comme activité de type ''lunch'' (auto_status = approved) dans la timeline d''approbation. Les pauses sont considérées comme temps couvert pour la détection de gaps (pas de faux "temps non suivi"). Publication Realtime activée pour les mises à jour live du dashboard.
RELATIONS: -> shifts (N:1 via shift_id ON DELETE CASCADE) | -> employee_profiles (N:1 via employee_id)
RLS: SELECT/INSERT/UPDATE = employé (ses propres pauses) | SELECT = superviseur (via employee_supervisors) | ALL = admin.
';

COMMENT ON COLUMN lunch_breaks.started_at IS 'Début de la pause dîner. Toujours renseigné dès la création.';

COMMENT ON COLUMN lunch_breaks.ended_at IS 'Fin de la pause dîner. NULL = pause en cours (is_on_lunch = true dans le monitoring).';

-- =============================================================================
-- SECTION 3: REPORT TABLES
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 3.1 report_schedules (Level B)
-- ---------------------------------------------------------------------------
COMMENT ON TABLE report_schedules IS '
ROLE: Planifications récurrentes de génération de rapports, configurées par les admins pour une exécution automatique périodique.
STATUTS: active = planification active, prochaine exécution prévue | paused = temporairement suspendue | deleted = supprimée logiquement (soft delete, jamais affichée)
REGLES: Seuls les admin/super_admin peuvent créer des planifications. La suppression est logique (status = deleted). next_run_at recalculé après chaque exécution. run_count et failure_count trackent l''historique d''exécution.
RELATIONS: -> auth.users (N:1 via user_id ON DELETE CASCADE) | <- report_jobs (1:N via schedule_id)
RLS: ALL = utilisateur propriétaire (user_id = auth.uid()).
';

COMMENT ON COLUMN report_schedules.report_type IS 'Type de rapport. Values: timesheet = feuilles de temps | activity_summary = résumé d''activité équipe | attendance = présence/absences';

COMMENT ON COLUMN report_schedules.config IS 'Configuration du rapport en JSONB (même structure que report_jobs.config): date_range, employee_filter, format, etc.';

COMMENT ON COLUMN report_schedules.frequency IS 'Fréquence d''exécution. Values: weekly = hebdomadaire | bi_weekly = aux 2 semaines | monthly = mensuel';

COMMENT ON COLUMN report_schedules.schedule_config IS 'Configuration détaillée de la planification en JSONB (jour de la semaine, heure, etc.)';

COMMENT ON COLUMN report_schedules.last_run_status IS 'Résultat de la dernière exécution. Values: success = réussi | failed = échoué';

-- ---------------------------------------------------------------------------
-- 3.2 report_jobs (Level A)
-- ---------------------------------------------------------------------------
COMMENT ON TABLE report_jobs IS 'ROLE: File d''attente et historique des rapports générés (sync ou async), avec statut d''exécution, fichier résultant et expiration à 30 jours.';

-- ---------------------------------------------------------------------------
-- 3.3 report_audit_logs (Level A)
-- ---------------------------------------------------------------------------
COMMENT ON TABLE report_audit_logs IS 'ROLE: Journal d''audit des actions sur les rapports (génération, téléchargement, suppression, planification) avec contexte IP/user-agent.';

-- =============================================================================
-- SECTION 4: AUDIT (Level B)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 4.1 audit.audit_logs
-- ---------------------------------------------------------------------------
-- Note: this table already has a COMMENT from migration 011.
-- We replace it with the enriched semi-structured format.
COMMENT ON TABLE audit.audit_logs IS '
ROLE: Journal d''audit immutable capturant toutes les modifications (INSERT/UPDATE/DELETE) sur les tables auditées, via trigger générique audit.log_changes().
REGLES: Aucune écriture directe — insertion uniquement via trigger SECURITY DEFINER. Stocke old_values et new_values en JSONB pour traçabilité complète. Aucune politique DELETE/UPDATE — les entrées sont immuables.
RELATIONS: -> employee_profiles (N:1 via user_id, l''auteur du changement) | Les record_id + table_name identifient la ligne modifiée.
TRIGGERS: audit.log_changes() déclenché AFTER INSERT/UPDATE/DELETE sur: employee_profiles, employee_supervisors.
RLS: SELECT = admin/super_admin uniquement. Aucune politique INSERT/UPDATE/DELETE (écriture via trigger SECURITY DEFINER seulement).
';

COMMENT ON COLUMN audit.audit_logs.operation IS 'Type d''opération DML. Values: INSERT | UPDATE | DELETE';

COMMENT ON COLUMN audit.audit_logs.record_id IS 'UUID de la ligne modifiée dans la table source (correspond à la colonne id de la table auditée)';

COMMENT ON COLUMN audit.audit_logs.old_values IS 'Valeurs avant modification (JSONB). NULL pour INSERT. Contient to_jsonb(OLD) pour UPDATE et DELETE.';

COMMENT ON COLUMN audit.audit_logs.new_values IS 'Valeurs après modification (JSONB). NULL pour DELETE. Contient to_jsonb(NEW) pour INSERT et UPDATE.';

COMMENT ON COLUMN audit.audit_logs.email IS 'Email de l''utilisateur ayant effectué le changement, résolu depuis employee_profiles au moment du trigger.';

COMMENT ON COLUMN audit.audit_logs.change_reason IS 'Motif du changement (optionnel, renseigné manuellement si applicable).';

-- =============================================================================
-- SECTION 5: APP CONFIGURATION (Level A)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 5.1 app_config
-- ---------------------------------------------------------------------------
COMMENT ON TABLE app_config IS 'ROLE: Paires clé-valeur de configuration globale de l''application (ex: minimum_app_version, fcm_enabled), lisibles par tous les authentifiés, modifiables par les admins uniquement.';

-- ---------------------------------------------------------------------------
-- 5.2 app_settings
-- ---------------------------------------------------------------------------
COMMENT ON TABLE app_settings IS 'ROLE: Table single-row (CHECK id = 1) stockant le fuseau horaire métier (timezone) utilisé par les fonctions helper to_business_date(), business_day_start(), business_day_end().';
