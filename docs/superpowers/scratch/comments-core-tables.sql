-- =============================================================================
-- COMMENT ON statements pour les tables core du GPS Clock-In Tracker
-- Genere le 2026-03-09
-- =============================================================================
-- Tables Level C (detail maximal) : employee_profiles, shifts, gps_points
-- Tables Level B (detail standard) : employee_supervisors, gps_gaps,
--                                     employee_devices, active_device_sessions
-- =============================================================================


-- #############################################################################
-- SECTION 1 : employee_profiles (Level C)
-- #############################################################################

COMMENT ON TABLE employee_profiles IS '
ROLE: Profil employe lie 1:1 a auth.users, contient les donnees metier (role, statut, consentement vie privee, infos appareil).
STATUTS: active = peut utiliser toutes les fonctions | inactive = desactive par admin (connexion bloquee) | suspended = acces temporairement restreint (peut se connecter mais voit un message)
REGLES: Seuls les admins peuvent changer le statut (pas en self-service). Un inactive ne peut pas se connecter (Supabase Auth disabled). Le consentement vie privee (privacy_consent_at) est obligatoire avant tout clock-in GPS (Constitution III). Le role super_admin est protege : impossible de le retrograder ou le supprimer (trigger protect_super_admin). Impossible de desactiver le dernier admin actif (check_last_admin). La desactivation ferme automatiquement toutes les supervisions actives (trigger end_supervision_on_status_change).
RELATIONS: -> auth.users (1:1, PK=FK, CASCADE DELETE) | <- shifts (1:N) | <- gps_points (1:N) | <- gps_gaps (1:N) | <- employee_supervisors (1:N comme employee ET comme manager) | <- employee_devices (1:N) | <- active_device_sessions (1:1)
TRIGGERS: On INSERT auth.users -> auto-creation du profil (handle_new_user). On UPDATE -> updated_at = NOW(). On UPDATE status vers inactive/suspended -> cloture des supervisions actives (end_active_supervisions). On UPDATE/DELETE -> audit log (audit.log_changes). On UPDATE/DELETE -> protection super_admin (protect_super_admin_trigger).
RLS: Employe voit son propre profil. Manager voit les profils de ses supervises actifs. Admin/super_admin voit tous les profils. Employe peut modifier son propre profil (sauf changer son role, sauf super_admin). Admin peut modifier les profils non-super_admin.
';

COMMENT ON COLUMN employee_profiles.email IS 'Email de travail synchronise depuis auth.users. Unique. Utilise pour la connexion et la recuperation de mot de passe.';

COMMENT ON COLUMN employee_profiles.full_name IS 'Nom complet affiche dans l''app et le dashboard. Max 255 caracteres (validation app-level).';

COMMENT ON COLUMN employee_profiles.employee_id IS 'Identifiant employe interne de l''entreprise (optionnel). Max 50 caracteres. Doit etre unique si fourni.';

COMMENT ON COLUMN employee_profiles.status IS 'Statut du compte. Values: active = toutes les fonctions | inactive = bloque par admin | suspended = acces restreint. Seul un admin peut modifier. Transitions : active <-> inactive, active <-> suspended, le tout par admin uniquement.';

COMMENT ON COLUMN employee_profiles.role IS 'Role pour le controle d''acces. Values: employee = utilisateur standard | manager = voit les donnees de ses supervises | admin = acces global + gestion employes | super_admin = admin protege (impossible a retrograder ou supprimer).';

COMMENT ON COLUMN employee_profiles.privacy_consent_at IS 'Timestamp du consentement vie privee. NULL = pas encore consenti. Obligatoire avant tout clock-in (Constitution III, verifie par la fonction clock_in()).';

COMMENT ON COLUMN employee_profiles.device_platform IS 'Plateforme du dernier appareil connecte. Values: android | ios. Mis a jour par register_device_login().';

COMMENT ON COLUMN employee_profiles.device_os_version IS 'Version OS du dernier appareil (ex: 18.3.2, 14). Mis a jour par register_device_login().';

COMMENT ON COLUMN employee_profiles.device_model IS 'Modele du dernier appareil (ex: iPhone 15, Pixel 8). Mis a jour par register_device_login().';

COMMENT ON COLUMN employee_profiles.device_app_version IS 'Version de l''app sur le dernier appareil (ex: 1.0.0+113). Mis a jour par register_device_login(). Utilise par enforce_clock_in_version pour bloquer les builds obsoletes.';

COMMENT ON COLUMN employee_profiles.device_updated_at IS 'Dernier update des colonnes device_*. Mis a jour par register_device_login().';

COMMENT ON COLUMN employee_profiles.fcm_token IS 'Token Firebase Cloud Messaging pour les push silencieux de reveil (wake push). Mis a jour par le client a chaque refresh de token.';

COMMENT ON COLUMN employee_profiles.last_wake_push_at IS 'Dernier envoi de push silencieux de reveil. Throttle : max 1 push par 5 minutes par device. Utilise par get_stale_active_devices().';

COMMENT ON COLUMN employee_profiles.battery_setup_completed_at IS 'Timestamp de completion du wizard de desactivation d''optimisation batterie OEM. NULL = jamais complete. Sur Android uniquement.';


-- #############################################################################
-- SECTION 2 : shifts (Level C)
-- #############################################################################

COMMENT ON TABLE shifts IS '
ROLE: Session de travail d''un employe, du clock-in au clock-out, avec position GPS et suivi de la vitalite du tracking.
STATUTS: active = quart en cours (un seul par employe a la fois) | completed = quart termine
REGLES: Un employe ne peut avoir qu''un seul shift active a la fois (contrainte applicative dans clock_in()). clock_out_at doit etre > clocked_in_at (CHECK constraint). Le consentement vie privee est requis avant clock-in (verifie par clock_in()). request_id est une cle d''idempotence UUID generee cote client pour eviter les doublons offline. Les timestamps sont en UTC (TIMESTAMPTZ). Un shift actif > 10 min sans aucun GPS point est auto-ferme par le cron flag_gpsless_shifts (toutes les 10 min). A minuit Eastern (America/Montreal), un cron (cleanup_zombie_shifts) ferme tous les shifts encore actifs. Le heartbeat est mis a jour par le trigger gps_point_heartbeat (chaque INSERT dans gps_points) ET par le RPC ping_shift_heartbeat (~90s, independant du GPS).
RELATIONS: -> employee_profiles (N:1, FK employee_id) | <- gps_points (1:N) | <- gps_gaps (1:N) | <- trips (1:N, detection de trajets) | <- lunch_breaks (1:N)
TRIGGERS: On UPDATE -> updated_at = NOW() (update_shifts_updated_at).
RLS: Employe voit/insere/modifie ses propres shifts. Manager voit les shifts de ses supervises. Admin/super_admin voit tous les shifts. Pas de DELETE (piste d''audit immutable).
';

COMMENT ON COLUMN shifts.employee_id IS 'FK vers employee_profiles.id. Proprietaire du shift. NOT NULL, CASCADE DELETE.';

COMMENT ON COLUMN shifts.request_id IS 'Cle d''idempotence UUID generee par le client. Empeche la creation de doublons lors de retentatives de clock-in offline. UNIQUE.';

COMMENT ON COLUMN shifts.status IS 'Etat du shift. Values: active = en cours | completed = termine. Transition : active -> completed (via clock_out() ou auto-close serveur). Jamais completed -> active.';

COMMENT ON COLUMN shifts.clocked_in_at IS 'Timestamp UTC du clock-in. DEFAULT NOW() pour le clock-in serveur, mais peut etre le timestamp device si clock-in offline.';

COMMENT ON COLUMN shifts.clock_in_location IS 'Position GPS au clock-in. Format JSONB : {latitude: number, longitude: number}. Nullable si GPS indisponible (ne devrait plus arriver avec le GPS health check).';

COMMENT ON COLUMN shifts.clock_in_accuracy IS 'Precision GPS au clock-in en metres. Le GPS health check rejette > 100m.';

COMMENT ON COLUMN shifts.clocked_out_at IS 'Timestamp UTC du clock-out. NULL tant que le shift est actif. Doit etre > clocked_in_at (CHECK constraint).';

COMMENT ON COLUMN shifts.clock_out_location IS 'Position GPS au clock-out. Format JSONB : {latitude: number, longitude: number}. Nullable.';

COMMENT ON COLUMN shifts.clock_out_accuracy IS 'Precision GPS au clock-out en metres.';

COMMENT ON COLUMN shifts.clock_out_reason IS 'Raison de la fermeture. Values: manual = employe a clock-out | auto_zombie_cleanup = cron de minuit | no_gps_auto_close = cron flag_gpsless_shifts (0 GPS apres 10 min) | stale_reconciliation = reconciliation au demarrage de l''app | lunch_break = fermeture pour pause | tracking_verification_failed = echec de verification du tracking post-clock-in. DEFAULT manual.';

COMMENT ON COLUMN shifts.last_heartbeat_at IS 'Dernier signe de vie du device. Mis a jour par : (1) trigger gps_point_heartbeat a chaque INSERT gps_points, (2) RPC ping_shift_heartbeat (~90s). Utilise par cleanup_zombie_shifts et get_stale_active_devices pour detecter les shifts orphelins.';

COMMENT ON COLUMN shifts.clock_in_cluster_id IS 'FK vers stationary_clusters. Cluster GPS le plus proche au moment du clock-in. Utilise pour matcher le lieu de clock-in a une location connue.';

COMMENT ON COLUMN shifts.clock_out_cluster_id IS 'FK vers stationary_clusters. Cluster GPS le plus proche au moment du clock-out.';

COMMENT ON COLUMN shifts.clock_in_location_id IS 'FK vers locations. Lieu connu matche au clock-in (via cluster). Utilise pour les suggestions et le dashboard.';

COMMENT ON COLUMN shifts.clock_out_location_id IS 'FK vers locations. Lieu connu matche au clock-out.';


-- #############################################################################
-- SECTION 3 : gps_points (Level C)
-- #############################################################################

COMMENT ON TABLE gps_points IS '
ROLE: Point GPS capture pendant un shift actif, stocke en local puis synchronise via sync_gps_points RPC. Constitue la trace de deplacement de l''employe.
REGLES: Les points sont immutables (pas de UPDATE/DELETE via RLS). client_id est un UUID genere par le client pour deduplication idempotente (UNIQUE constraint, gere les retries offline). captured_at est le timestamp du device (pas du serveur) — les timestamps originaux sont toujours preserves meme si la sync est retardee. received_at est le timestamp serveur de reception. Latitude [-90, 90], longitude [-180, 180] (CHECK constraints). Le point GPS est d''abord stocke dans SQLCipher local, puis sync en batch vers Supabase. Des buffers natifs (NativeGpsBuffer iOS/Android, max 500 pts) capturent des points meme si Flutter est mort. L''intervalle de capture est adaptatif : 10s en mouvement (>= 0.5 m/s), 60s stationnaire, avec multiplicateur thermique (x2 eleve, x4 critique). La frequence est egalement adaptee par la vitesse du vehicule.
RELATIONS: -> shifts (N:1, FK shift_id, CASCADE DELETE) | -> employee_profiles (N:1, FK employee_id, CASCADE DELETE) | -> stationary_clusters (N:1, FK stationary_cluster_id optionnel)
TRIGGERS: On INSERT -> update shifts.last_heartbeat_at (gps_point_heartbeat trigger).
RLS: Employe voit/insere ses propres points. Manager voit les points de ses supervises. Admin/super_admin voit tous les points. Pas de UPDATE/DELETE (piste d''audit immutable).
';

COMMENT ON COLUMN gps_points.client_id IS 'UUID genere par le client (= id du LocalGpsPoint). Cle d''idempotence pour deduplication : les retries de sync ne creent pas de doublons grace a la contrainte UNIQUE.';

COMMENT ON COLUMN gps_points.shift_id IS 'FK vers shifts.id. Chaque point est lie a un shift actif. CASCADE DELETE.';

COMMENT ON COLUMN gps_points.employee_id IS 'FK vers employee_profiles.id. Redondant avec shift.employee_id pour accelerer les requetes RLS. CASCADE DELETE.';

COMMENT ON COLUMN gps_points.latitude IS 'Latitude en degres decimaux. CHECK [-90, 90]. Precision DECIMAL(10,8).';

COMMENT ON COLUMN gps_points.longitude IS 'Longitude en degres decimaux. CHECK [-180, 180]. Precision DECIMAL(11,8).';

COMMENT ON COLUMN gps_points.accuracy IS 'Precision horizontale GPS en metres. < 50m = haute qualite (95% des points en conditions normales). > 100m = qualite basse, flagge.';

COMMENT ON COLUMN gps_points.captured_at IS 'Timestamp device au moment de la capture GPS. Toujours le timestamp original du device, jamais ecrase par le serveur. Utilise pour ordonner la trace et calculer les gaps.';

COMMENT ON COLUMN gps_points.received_at IS 'Timestamp serveur a la reception (sync). Peut differer de captured_at si sync offline retardee.';

COMMENT ON COLUMN gps_points.device_id IS 'Identifiant unique de l''appareil qui a capture le point. Utilise pour le diagnostic multi-device.';

COMMENT ON COLUMN gps_points.speed IS 'Vitesse en m/s rapportee par le GPS du device. Utilise pour la detection stationnaire et la detection de trajet.';

COMMENT ON COLUMN gps_points.heading IS 'Direction (bearing) en degres [0-360] rapportee par le GPS.';

COMMENT ON COLUMN gps_points.altitude IS 'Altitude en metres au-dessus du niveau de la mer.';

COMMENT ON COLUMN gps_points.is_mocked IS 'True si la position a ete simulee/fakee. Android uniquement (isFromMockProvider). Utilise pour detecter la fraude GPS.';

COMMENT ON COLUMN gps_points.activity_type IS 'Type d''activite physique detectee par le device au moment de la capture. Values: still | walking | running | in_vehicle | on_bicycle | unknown. Utilise pour filtrer les ghost trips (activite still = supprime le mouvement apparent).';

COMMENT ON COLUMN gps_points.stationary_cluster_id IS 'FK vers stationary_clusters.id. Cluster auquel ce point a ete assigne par l''algorithme de clustering. NULL si le point n''appartient a aucun cluster (en deplacement).';

COMMENT ON COLUMN gps_points.battery_level IS 'Niveau de batterie du device (0-100) au moment de la capture. Utilise pour le diagnostic et la correlation avec les pertes de GPS.';


-- #############################################################################
-- SECTION 4 : employee_supervisors (Level B)
-- #############################################################################

COMMENT ON TABLE employee_supervisors IS '
ROLE: Relation de supervision manager-employe avec historique temporel (effective_from/effective_to). Controle la visibilite des donnees via RLS.
STATUTS: effective_to IS NULL = supervision active | effective_to renseignee = supervision terminee
REGLES: Pas d''auto-supervision (CHECK manager_id != employee_id). effective_to > effective_from si renseignee. Un employe n''a qu''un seul superviseur direct actif a la fois (l''ancien est cloture lors d''une reassignation). La desactivation d''un employe ferme automatiquement ses supervisions actives (trigger end_active_supervisions). Le manager doit avoir le role manager/admin/super_admin.
RELATIONS: -> employee_profiles (N:1, FK manager_id) | -> employee_profiles (N:1, FK employee_id)
RLS: Les deux parties (manager et employe) peuvent voir la relation. Seuls admin/super_admin peuvent creer/modifier/supprimer.
';

COMMENT ON COLUMN employee_supervisors.supervision_type IS 'Type de supervision. Values: direct = superviseur principal | matrix = supervision secondaire | temporary = supervision temporaire.';

COMMENT ON COLUMN employee_supervisors.effective_from IS 'Date de debut de la supervision. DEFAULT CURRENT_DATE.';

COMMENT ON COLUMN employee_supervisors.effective_to IS 'Date de fin de la supervision. NULL = supervision active en cours. Renseignee automatiquement lors de la desactivation de l''employe ou lors d''une reassignation.';


-- #############################################################################
-- SECTION 5 : gps_gaps (Level B)
-- #############################################################################

COMMENT ON TABLE gps_gaps IS '
ROLE: Periode de perte de signal GPS pendant un shift. Detectee cote client quand aucun point GPS n''est recu pendant > 45 secondes, synchronisee vers le serveur.
REGLES: client_id est un UUID d''idempotence genere par le client (UNIQUE). ended_at peut etre NULL si le gap est en cours. Les gaps sont utilises par le dashboard pour calculer le temps non-suivi et par detect_trips pour la resilience aux coupures GPS.
RELATIONS: -> shifts (N:1, FK shift_id, CASCADE DELETE) | -> employee_profiles (N:1, FK employee_id)
RLS: Employe peut inserer/lire ses propres gaps. Superviseur peut lire les gaps de ses employes. Admin/super_admin peut lire tous les gaps.
';

COMMENT ON COLUMN gps_gaps.client_id IS 'UUID genere cote client pour deduplication idempotente (UNIQUE).';

COMMENT ON COLUMN gps_gaps.started_at IS 'Debut de la perte GPS. Timestamp device.';

COMMENT ON COLUMN gps_gaps.ended_at IS 'Fin de la perte GPS. NULL si le gap est en cours. Timestamp device.';

COMMENT ON COLUMN gps_gaps.reason IS 'Cause de la perte. DEFAULT signal_loss. Autres valeurs possibles selon le contexte client.';


-- #############################################################################
-- SECTION 6 : employee_devices (Level B)
-- #############################################################################

COMMENT ON TABLE employee_devices IS '
ROLE: Historique de tous les appareils ayant ete utilises par un employe. Un seul device est marque is_current = true a la fois. Mis a jour via register_device_login() a chaque connexion.
REGLES: UNIQUE(employee_id, device_id) — un device par employe. L''ancien device courant est demarque (is_current = false) quand un nouveau device se connecte. last_seen_at est mis a jour a chaque login du meme device.
RELATIONS: -> auth.users (N:1, FK employee_id, CASCADE DELETE)
RLS: Employe voit ses propres devices. Admin voit tous les devices.
';

COMMENT ON COLUMN employee_devices.device_id IS 'Identifiant unique de l''appareil (genere par le client). Cle composite UNIQUE avec employee_id.';

COMMENT ON COLUMN employee_devices.is_current IS 'True si c''est l''appareil actuellement actif pour cet employe. Un seul device is_current = true par employe.';

COMMENT ON COLUMN employee_devices.first_seen_at IS 'Premiere connexion de cet employe depuis cet appareil.';

COMMENT ON COLUMN employee_devices.last_seen_at IS 'Derniere connexion de cet employe depuis cet appareil. Mis a jour a chaque login.';


-- #############################################################################
-- SECTION 7 : active_device_sessions (Level B)
-- #############################################################################

COMMENT ON TABLE active_device_sessions IS '
ROLE: Session active d''appareil par employe (un seul a la fois). Table de lookup rapide pour verifier si le device courant est toujours la session active (check_device_session RPC). Publiee en Realtime pour detecter les deconnexions multi-device.
REGLES: PK = employee_id (un seul enregistrement par employe). Upsert a chaque register_device_login(). REPLICA IDENTITY FULL pour que Supabase Realtime envoie les anciennes + nouvelles valeurs.
RELATIONS: -> auth.users (1:1, FK employee_id, CASCADE DELETE)
RLS: Employe voit sa propre session. Admin voit toutes les sessions.
';

COMMENT ON COLUMN active_device_sessions.device_id IS 'device_id de l''appareil actuellement actif pour cet employe.';

COMMENT ON COLUMN active_device_sessions.session_started_at IS 'Timestamp du debut de la session active courante. Mis a jour a chaque register_device_login().';
