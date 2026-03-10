-- ============================================================
-- Migration: Add comprehensive COMMENT ON to all tables
-- Purpose: Self-documenting database for AI-assisted development
-- Non-destructive: Only adds metadata, no schema/data changes
-- ============================================================


-- ============================================================
-- CORE TABLES
-- ============================================================

-- -----------------------------------------------
-- employee_profiles (Level C)
-- -----------------------------------------------

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


-- -----------------------------------------------
-- shifts (Level C)
-- -----------------------------------------------

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


-- -----------------------------------------------
-- gps_points (Level C)
-- -----------------------------------------------

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


-- -----------------------------------------------
-- employee_supervisors (Level B)
-- -----------------------------------------------

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


-- -----------------------------------------------
-- gps_gaps (Level B)
-- -----------------------------------------------

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


-- -----------------------------------------------
-- employee_devices (Level B)
-- -----------------------------------------------

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


-- -----------------------------------------------
-- active_device_sessions (Level B)
-- -----------------------------------------------

COMMENT ON TABLE active_device_sessions IS '
ROLE: Session active d''appareil par employe (un seul a la fois). Table de lookup rapide pour verifier si le device courant est toujours la session active (check_device_session RPC). Publiee en Realtime pour detecter les deconnexions multi-device.
REGLES: PK = employee_id (un seul enregistrement par employe). Upsert a chaque register_device_login(). REPLICA IDENTITY FULL pour que Supabase Realtime envoie les anciennes + nouvelles valeurs.
RELATIONS: -> auth.users (1:1, FK employee_id, CASCADE DELETE)
RLS: Employe voit sa propre session. Admin voit toutes les sessions.
';

COMMENT ON COLUMN active_device_sessions.device_id IS 'device_id de l''appareil actuellement actif pour cet employe.';
COMMENT ON COLUMN active_device_sessions.session_started_at IS 'Timestamp du debut de la session active courante. Mis a jour a chaque register_device_login().';


-- ============================================================
-- TRIP & MILEAGE TABLES
-- ============================================================

-- -----------------------------------------------
-- trips (Level C)
-- -----------------------------------------------

COMMENT ON TABLE trips IS '
ROLE: Deplacement detecte automatiquement entre deux arrets (clusters stationnaires) a partir des points GPS enregistres pendant un quart de travail.
STATUTS: classification: business = deplacement professionnel (defaut) | personal = deplacement personnel (exclus du remboursement). transport_mode: driving = vehicule (>10 km/h moy.) | walking = marche (<4 km/h moy.) | unknown = non classifie. match_status: pending = en attente OSRM | processing = en cours | matched = trace OSRM obtenue | failed = OSRM echoue | anomalous = anomalie detectee. detection_method: auto = detecte par algorithme cluster-first | manual = saisi manuellement.
REGLES: Detecte par la fonction detect_trips(shift_id) qui utilise un algorithme cluster-first : les clusters stationnaires (rayon 50m, duree >=3 min) sont identifies, puis les trajets sont crees entre chaque paire de clusters consecutifs. Distance calculee par haversine centroide-a-centroide multipliee par un facteur de correction routiere de 1.3x. Les trajets synthetiques (has_gps_gap=true, 0 points GPS) sont crees pour chaque paire de clusters sans trajet reel. Filtre anti-fantome post-creation : marche <100m deplacement = supprime | conduite <500m distance = supprime | conduite <50m deplacement = supprime | conduite <=10 pts avec ratio rectitude <10% = supprime. Seuls les trajets business + driving + conducteur (non passager covoiturage) + vehicule personnel sont remboursables. Un employe ne peut modifier que la classification (business/personal). La re-detection complete supprime et recree tous les trajets pour les quarts termines.
RELATIONS: -> shifts (N:1) | -> employee_profiles (N:1) | -> locations (N:1, start_location_id) | -> locations (N:1, end_location_id) | -> stationary_clusters (N:1, start_cluster_id) | -> stationary_clusters (N:1, end_cluster_id) | <- trip_gps_points (1:N) | <- carpool_members (1:N)
TRIGGERS: On UPDATE -> update_trips_updated_at() met a jour updated_at.
ALGORITHME: Algorithme cluster-first (migration 071+) : passe unique sur les GPS points tries par captured_at. Deux trackers concurrents : cluster courant (confirme) et cluster tentatif (en formation). Quand le tentatif atteint 3 min, il est promu en cluster courant et un trajet est cree entre les deux centroides. Centroide pondere par la precision GPS inverse (les points precis pesent plus). Distance ajustee = GREATEST(haversine*1000 - precision_GPS, 0) pour le test de rayon 50m. Classification du mode de transport : vitesse moy. >10 km/h = driving, <4 km/h = walking, zone grise 4-10 km/h = analyse des segments inter-points. Detection anomalies (Tier 1) : distance reelle > 2x distance attendue OSRM ou duree > 2x duree attendue = needs_review. Detection anomalies (Tier 2, endpoints inconnus) : duree >30 min, distance >10 km, ratio detour >2x, vitesse >130 km/h ou <5 km/h = needs_review.
RLS: SELECT = employe voit ses propres trajets + superviseur voit les employes supervises. UPDATE = employe sur ses propres trajets (classification seulement). INSERT/DELETE = authenticated (via RPC SECURITY DEFINER).
';

COMMENT ON COLUMN trips.shift_id IS 'Quart de travail parent. Tous les trajets sont limites a la fenetre temporelle du quart.';
COMMENT ON COLUMN trips.start_latitude IS 'Latitude du centroide pondere du cluster de depart (pas un point GPS individuel).';
COMMENT ON COLUMN trips.start_longitude IS 'Longitude du centroide pondere du cluster de depart.';
COMMENT ON COLUMN trips.start_address IS 'Adresse obtenue par reverse-geocoding du point de depart (Nominatim/Google).';
COMMENT ON COLUMN trips.start_location_id IS 'Location geofencee la plus proche du depart. Assignee par match_trip_to_location() ou par continuite (si < 100m du end_location du trajet precedent). NULL = aucun match.';
COMMENT ON COLUMN trips.end_latitude IS 'Latitude du centroide pondere du cluster d''arrivee.';
COMMENT ON COLUMN trips.end_longitude IS 'Longitude du centroide pondere du cluster d''arrivee.';
COMMENT ON COLUMN trips.end_address IS 'Adresse obtenue par reverse-geocoding du point d''arrivee.';
COMMENT ON COLUMN trips.end_location_id IS 'Location geofencee la plus proche de l''arrivee. Assignee par match_trip_to_location() avec buffer de precision GPS.';
COMMENT ON COLUMN trips.distance_km IS 'Distance haversine centroide-a-centroide multipliee par le facteur de correction 1.3x. Peut etre remplacee par road_distance_km apres OSRM matching.';
COMMENT ON COLUMN trips.duration_minutes IS 'Duree = ended_at - started_at en minutes. Minimum 1 minute.';
COMMENT ON COLUMN trips.classification IS 'Classification du trajet. Values: business = professionnel (defaut, inclus dans le remboursement) | personal = personnel (exclus). Modifiable par l''employe.';
COMMENT ON COLUMN trips.confidence_score IS 'Score de confiance 0-1 base sur le ratio de points GPS basse precision. Formule: 1 - (low_accuracy_segments / gps_point_count). Points avec accuracy > 50m = basse precision.';
COMMENT ON COLUMN trips.gps_point_count IS 'Nombre de points GPS dans le buffer de transit entre les deux clusters. 0 = trajet synthetique (GPS gap, aucune trace GPS).';
COMMENT ON COLUMN trips.low_accuracy_segments IS 'Nombre de points GPS avec accuracy > 50m dans ce trajet.';
COMMENT ON COLUMN trips.detection_method IS 'Values: auto = detecte par detect_trips() | manual = cree manuellement.';
COMMENT ON COLUMN trips.start_cluster_id IS 'FK vers le cluster stationnaire de depart. Les coordonnees du trajet proviennent du centroide de ce cluster.';
COMMENT ON COLUMN trips.end_cluster_id IS 'FK vers le cluster stationnaire d''arrivee. NULL pour les trajets trailing (fin de donnees sans cluster d''arrivee).';
COMMENT ON COLUMN trips.start_location_match_method IS 'Methode d''assignation du start_location_id. Values: auto = geofence matching automatique | manual = correction admin via update_trip_location().';
COMMENT ON COLUMN trips.end_location_match_method IS 'Methode d''assignation du end_location_id. Values: auto = geofence matching automatique | manual = correction admin.';
COMMENT ON COLUMN trips.transport_mode IS 'Mode de transport classifie par classify_trip_transport_mode(). Values: driving = vehicule | walking = marche | unknown = non classifie. Criteres: >10 km/h moy. = driving, <4 km/h = walking, 4-10 km/h = analyse par segments.';
COMMENT ON COLUMN trips.has_gps_gap IS 'TRUE quand le trajet a ete cree avec peu ou pas de trace GPS (trajet synthetique entre clusters, ou gap >15 min). Declenche auto_status=needs_review pour approbation superviseur.';
COMMENT ON COLUMN trips.gps_gap_seconds IS 'Total des secondes de gaps GPS >5 min dans ce trajet (exces au-dela de 5 min de grace).';
COMMENT ON COLUMN trips.gps_gap_count IS 'Nombre de gaps GPS individuels >5 min dans ce trajet.';
COMMENT ON COLUMN trips.road_distance_km IS 'Distance routiere OSRM apres map-matching (/match) ou estimation (/route pour les trajets synthetiques). NULL si pas encore matche.';
COMMENT ON COLUMN trips.estimated_distance_km IS 'Part de road_distance_km estimee via OSRM /route (pas matchee GPS). Permet d''afficher "18.3 km (dont 4.2 km estimes)".';
COMMENT ON COLUMN trips.expected_distance_km IS 'Distance routiere optimale OSRM entre les deux locations connues (start et end). NULL si un endpoint est inconnu. Sert a la detection d''anomalies : trajet reel > 2x expected = detour excessif.';
COMMENT ON COLUMN trips.expected_duration_seconds IS 'Duree de trajet estimee OSRM entre les deux locations connues. NULL si un endpoint est inconnu. Trajet reel > 2x expected = duree anormale.';
COMMENT ON COLUMN trips.match_status IS 'Statut du matching OSRM. Values: pending = en attente | processing = en cours | matched = trace routiere obtenue | failed = echec OSRM | anomalous = anomalie detectee. Le cron pg_cron appelle batch-match-trips toutes les 5 min pour les pending.';


-- -----------------------------------------------
-- stationary_clusters (Level C)
-- -----------------------------------------------

COMMENT ON TABLE stationary_clusters IS '
ROLE: Groupe de points GPS stationnaires representant un arret prolonge (>=3 min) dans un rayon de 50m, avec centroide pondere par la precision GPS inverse. Entite de premier niveau pour la visualisation des arrets et la liaison aux trajets.
REGLES: Detecte par detect_trips() en meme temps que les trajets. Un cluster est confirme quand des points GPS restent dans un rayon de 50m (ajuste pour la precision GPS) pendant >=3 minutes. Centroide calcule par ponderation inverse de la precision : SUM(lat/GREATEST(acc,1)) / SUM(1/GREATEST(acc,1)). Les points GPS du cluster sont tagges via gps_points.stationary_cluster_id. Les clusters ne sont PAS coupes par les gaps GPS (les gaps sont normaux en mode stationnaire avec frequence adaptative de 120s). Pour les quarts termines : suppression et recreation totale. Le champ effective_location_type permet de surcharger le type de lieu (ex: domicile qui est aussi bureau pour certains employes).
RELATIONS: -> shifts (N:1) | -> employee_profiles (N:1) | -> locations (N:1, matched_location_id) | <- gps_points (1:N, via stationary_cluster_id) | <- trips (1:N, via start_cluster_id) | <- trips (1:N, via end_cluster_id)
ALGORITHME: Pendant la passe unique de detect_trips() : tracker concurrent "cluster courant" + "cluster tentatif". Distance ajustee au cluster = GREATEST(haversine_km(centroide, point)*1000 - precision_point, 0). Si <=50m, le point rejoint le cluster. Si >50m, il demarre un cluster tentatif. Quand le tentatif atteint 3 min, le cluster courant est finalise, un trajet est cree, et le tentatif est promu. Precision du centroide combinee : 1/SQRT(SUM(1/GREATEST(acc^2, 1))). La location matchee est assignee par match_trip_to_location(centroide_lat, centroide_lng, centroide_accuracy).
RLS: SELECT = admin/super_admin voit tout | employe voit ses propres clusters | superviseur voit les employes supervises. INSERT/UPDATE/DELETE = via RPC SECURITY DEFINER (detect_trips).
';

COMMENT ON COLUMN stationary_clusters.centroid_latitude IS 'Latitude du centroide pondere par precision GPS inverse. Plus precis qu''un point GPS individuel (amelioration mesuree de ~11m).';
COMMENT ON COLUMN stationary_clusters.centroid_longitude IS 'Longitude du centroide pondere par precision GPS inverse.';
COMMENT ON COLUMN stationary_clusters.centroid_accuracy IS 'Precision estimee du centroide en metres. Formule: 1/SQRT(SUM(1/GREATEST(acc^2, 1))). Diminue avec plus de points.';
COMMENT ON COLUMN stationary_clusters.started_at IS 'Timestamp du premier point GPS du cluster.';
COMMENT ON COLUMN stationary_clusters.ended_at IS 'Timestamp du dernier point GPS du cluster.';
COMMENT ON COLUMN stationary_clusters.duration_seconds IS 'Duree totale = ended_at - started_at en secondes. Un cluster doit durer >= 180s (3 min) pour etre confirme.';
COMMENT ON COLUMN stationary_clusters.gps_point_count IS 'Nombre de points GPS dans le cluster.';
COMMENT ON COLUMN stationary_clusters.matched_location_id IS 'Location geofencee la plus proche du centroide. Assignee par match_trip_to_location(centroide, precision). NULL = aucun match dans les geofences actives.';
COMMENT ON COLUMN stationary_clusters.gps_gap_seconds IS 'Total des secondes de gaps GPS >5 min dans ce cluster (exces au-dela de 5 min de grace). Normal en mode stationnaire avec frequence adaptative 120s.';
COMMENT ON COLUMN stationary_clusters.gps_gap_count IS 'Nombre de gaps GPS individuels >5 min dans ce cluster.';
COMMENT ON COLUMN stationary_clusters.effective_location_type IS 'Type de lieu effectif, peut surcharger le location_type de la location matchee. Permet de gerer les domiciles qui sont aussi bureaux pour certains employes.';


-- -----------------------------------------------
-- trip_gps_points (Level B)
-- -----------------------------------------------

COMMENT ON TABLE trip_gps_points IS '
ROLE: Table de jonction reliant les trajets aux points GPS du buffer de transit (points entre les deux clusters stationnaires).
REGLES: Les points sont inseres dans l''ordre chronologique (sequence_order). Ne contient PAS les points stationnaires des clusters de depart/arrivee, seulement les points en mouvement. Peut etre vide (gps_point_count=0) pour les trajets synthetiques. Supprime en cascade avec le trajet parent. ON CONFLICT DO NOTHING pour eviter les doublons.
RELATIONS: -> trips (N:1, CASCADE) | -> gps_points (N:1, CASCADE)
RLS: SELECT = utilisateurs qui ont acces au trajet parent | INSERT/DELETE = authenticated (via RPC).
';

COMMENT ON COLUMN trip_gps_points.sequence_order IS 'Ordre chronologique du point dans le trajet, commence a 1.';


-- -----------------------------------------------
-- reimbursement_rates (Level B)
-- -----------------------------------------------

COMMENT ON TABLE reimbursement_rates IS '
ROLE: Configuration du taux de remboursement kilometrique avec paliers et dates d''effet. Modele CRA/ARC canadien avec taux different apres un seuil.
REGLES: Taux par defaut = CRA/ARC 2026 : 0.72$/km pour les premiers 5000 km, puis 0.66$/km. Les changements de taux s''appliquent prospectivement (pas d''effet retroactif sur les rapports generes). Les rapports figent le taux utilise au moment de la generation. Un seul taux actif a la fois (effective_to NULL = taux courant). Ecriture reservee aux admins via service role.
RELATIONS: -> employee_profiles (N:1, created_by, nullable)
RLS: SELECT = tous les utilisateurs authentifies | INSERT/UPDATE = admin uniquement (via service role).
';

COMMENT ON COLUMN reimbursement_rates.rate_per_km IS 'Taux en $/km pour le premier palier. Ex: 0.7200 = 0.72$/km.';
COMMENT ON COLUMN reimbursement_rates.threshold_km IS 'Seuil en km declenchant le taux reduit. Ex: 5000. NULL = taux unique sans palier.';
COMMENT ON COLUMN reimbursement_rates.rate_after_threshold IS 'Taux en $/km apres le seuil. Ex: 0.6600. NULL = taux unique.';
COMMENT ON COLUMN reimbursement_rates.effective_from IS 'Date de debut d''effet du taux.';
COMMENT ON COLUMN reimbursement_rates.effective_to IS 'Date de fin d''effet. NULL = taux actuellement actif.';
COMMENT ON COLUMN reimbursement_rates.rate_source IS 'Origine du taux. Values: cra = taux officiel CRA/ARC Canada | custom = taux personnalise par l''employeur.';


-- -----------------------------------------------
-- mileage_reports (Level B)
-- -----------------------------------------------

COMMENT ON TABLE mileage_reports IS '
ROLE: Reference vers un rapport de remboursement kilometrique genere (PDF/CSV) pour une periode donnee. Contient un snapshot fige des totaux au moment de la generation.
REGLES: Les totaux (distances, remboursement, nombre de trajets) sont figes au moment de la generation et ne changent pas si les trajets sont modifies ensuite. Le taux utilise est egalement fige. Le format par defaut est PDF. Seuls les trajets business + driving sont inclus dans le remboursement. Les trajets avec passager covoiturage et vehicule entreprise sont exclus.
RELATIONS: -> employee_profiles (N:1, CASCADE)
RLS: SELECT = employe voit ses propres rapports + superviseur voit les employes supervises. INSERT = employe pour ses propres rapports.
';

COMMENT ON COLUMN mileage_reports.total_distance_km IS 'Distance totale tous trajets confondus (business + personal) pour la periode.';
COMMENT ON COLUMN mileage_reports.business_distance_km IS 'Distance des trajets business uniquement.';
COMMENT ON COLUMN mileage_reports.personal_distance_km IS 'Distance des trajets personal uniquement.';
COMMENT ON COLUMN mileage_reports.total_reimbursement IS 'Montant total de remboursement calcule avec le taux fige. Formule: business_distance_km * rate_per_km_used (avec paliers si applicable).';
COMMENT ON COLUMN mileage_reports.rate_per_km_used IS 'Taux $/km fige au moment de la generation du rapport.';
COMMENT ON COLUMN mileage_reports.rate_source_used IS 'Source du taux fige : cra ou custom.';
COMMENT ON COLUMN mileage_reports.file_path IS 'Chemin vers le fichier dans Supabase Storage ou chemin local.';
COMMENT ON COLUMN mileage_reports.file_format IS 'Format du rapport. Values: pdf | csv.';


-- -----------------------------------------------
-- employee_vehicle_periods (Level B)
-- -----------------------------------------------

COMMENT ON TABLE employee_vehicle_periods IS '
ROLE: Periodes d''acces a un vehicule (personnel ou entreprise) pour chaque employe. Determine l''eligibilite au remboursement kilometrique et le role conducteur/passager dans le covoiturage.
REGLES: Periodes non-chevauchantes par employe + type de vehicule (trigger trg_check_vehicle_period_overlap). Un employe peut avoir les deux types simultanement (voiture perso + camion entreprise). ended_at NULL = periode en cours. Les employes avec vehicule entreprise actif ne sont PAS rembourses. La detection de covoiturage utilise les periodes pour assigner automatiquement le conducteur : 1 seul membre avec vehicule personnel = conducteur auto-assigne. Gestion admin uniquement (dashboard), pas d''interface employe.
RELATIONS: -> employee_profiles (N:1, CASCADE) | -> employee_profiles (N:1, created_by)
TRIGGERS: On INSERT/UPDATE -> check_vehicle_period_overlap() empeche les chevauchements | On UPDATE -> update_updated_at_column() met a jour updated_at.
RLS: ALL = admin/super_admin | SELECT = employe voit ses propres periodes.
';

COMMENT ON COLUMN employee_vehicle_periods.vehicle_type IS 'Type de vehicule. Values: personal = vehicule personnel (eligible remboursement) | company = vehicule entreprise (pas de remboursement).';
COMMENT ON COLUMN employee_vehicle_periods.started_at IS 'Date de debut de la periode d''acces au vehicule.';
COMMENT ON COLUMN employee_vehicle_periods.ended_at IS 'Date de fin de la periode. NULL = periode en cours (acces actif).';
COMMENT ON COLUMN employee_vehicle_periods.notes IS 'Description libre du vehicule. Ex: "Ford Escape 2022", "Camion Tri-Logis #12".';


-- -----------------------------------------------
-- carpool_groups (Level B)
-- -----------------------------------------------

COMMENT ON TABLE carpool_groups IS '
ROLE: Groupe de covoiturage detecte automatiquement — employes ayant voyage ensemble le meme jour (departs et arrivees < 200m, chevauchement temporel > 80%).
STATUTS: status: auto_detected = detecte par l''algorithme, en attente de revision | confirmed = confirme par admin | dismissed = rejete par admin.
REGLES: Detection par detect_carpools(date) : comparaison par paires de trajets driving du meme jour. Criteres : distance haversine entre departs < 200m ET entre arrivees < 200m ET chevauchement temporel > 80% de la duree du plus court trajet. Groupement transitif (union-find) : si A~B et B~C alors groupe {A,B,C}. Attribution automatique du conducteur via employee_vehicle_periods : 1 seul membre avec vehicule personnel = conducteur. 0 ou 2+ = review_needed=true. Idempotent : supprime les groupes existants pour la date avant recreation.
RELATIONS: -> employee_profiles (N:1, driver_employee_id) | -> employee_profiles (N:1, reviewed_by) | <- carpool_members (1:N, CASCADE)
RLS: ALL = admin/super_admin | SELECT = employes membres du groupe.
';

COMMENT ON COLUMN carpool_groups.trip_date IS 'Date des trajets du groupe de covoiturage.';
COMMENT ON COLUMN carpool_groups.driver_employee_id IS 'Employe identifie comme conducteur. Auto-assigne quand exactement 1 membre a un vehicule personnel actif. Modifiable par admin.';
COMMENT ON COLUMN carpool_groups.review_needed IS 'TRUE quand 0 ou 2+ membres ont un vehicule personnel actif — l''admin doit designer le conducteur manuellement.';
COMMENT ON COLUMN carpool_groups.review_note IS 'Note de l''admin lors de la revision.';


-- -----------------------------------------------
-- carpool_members (Level B)
-- -----------------------------------------------

COMMENT ON TABLE carpool_members IS '
ROLE: Membre d''un groupe de covoiturage avec son role (conducteur/passager). Relie un trajet specifique a un groupe de covoiturage.
REGLES: Un trajet ne peut appartenir qu''a un seul groupe de covoiturage (UNIQUE trip_id). Les passagers ne recoivent pas de remboursement kilometrique pour ce trajet. Le role est assigne automatiquement par detect_carpools() puis modifiable par admin.
RELATIONS: -> carpool_groups (N:1, CASCADE) | -> trips (N:1, CASCADE, UNIQUE) | -> employee_profiles (N:1)
RLS: ALL = admin/super_admin | SELECT = employe voit sa propre appartenance + co-membres du groupe.
';

COMMENT ON COLUMN carpool_members.role IS 'Role dans le covoiturage. Values: driver = conducteur (seul rembourse) | passenger = passager (pas rembourse) | unassigned = non attribue (review_needed sur le groupe).';


-- -----------------------------------------------
-- ignored_location_clusters (Level B)
-- -----------------------------------------------

COMMENT ON TABLE ignored_location_clusters IS '
ROLE: Clusters de trajets non-matches rejetes par les admins depuis l''onglet Suggested locations du dashboard. Empeche les memes clusters de reapparaitre comme suggestions.
REGLES: Un cluster rejete est filtre dans get_unmatched_trip_clusters() par proximite geographique (150m tolerance via ST_DWithin). Le cluster reapparait automatiquement si son nombre d''occurrences depasse le nombre au moment du rejet (occurrence_count_at_ignore), ce qui indique de nouvelles donnees significatives. Remplace en partie par ignored_trip_endpoints (migration 056) qui permet un rejet plus granulaire.
RELATIONS: -> auth.users (N:1, ignored_by)
RLS: ALL = admin/super_admin uniquement.
';

COMMENT ON COLUMN ignored_location_clusters.centroid_latitude IS 'Latitude du centroide du cluster rejete.';
COMMENT ON COLUMN ignored_location_clusters.centroid_longitude IS 'Longitude du centroide du cluster rejete.';
COMMENT ON COLUMN ignored_location_clusters.occurrence_count_at_ignore IS 'Nombre d''occurrences du cluster au moment du rejet. Si le cluster depasse ce nombre, il reapparait dans les suggestions.';


-- -----------------------------------------------
-- ignored_trip_endpoints (Level B)
-- -----------------------------------------------

COMMENT ON TABLE ignored_trip_endpoints IS '
ROLE: Endpoint individuel de trajet rejete par un admin depuis l''onglet Suggested locations. Plus granulaire que ignored_location_clusters (rejet par endpoint, pas par cluster).
REGLES: Filtre les endpoints dans get_unmatched_trip_clusters() et get_cluster_occurrences() via NOT EXISTS. Un endpoint rejete ne reapparait jamais (pas de logique de seuil comme ignored_location_clusters). UNIQUE(trip_id, endpoint_type) empeche les doublons. Supprime en cascade avec le trajet parent.
RELATIONS: -> trips (N:1, CASCADE) | -> auth.users (N:1, ignored_by)
RLS: ALL = admin/super_admin uniquement.
';

COMMENT ON COLUMN ignored_trip_endpoints.endpoint_type IS 'Type d''endpoint rejete. Values: start = point de depart | end = point d''arrivee.';


-- ============================================================
-- CLEANING & PROPERTY TABLES
-- ============================================================

-- -----------------------------------------------
-- buildings (Level B)
-- -----------------------------------------------

COMMENT ON TABLE buildings IS '
ROLE: Immeubles de location courte duree geres par Tri-logis, utilises pour le suivi de menage par QR code. Chaque building contient des studios (unites, aires communes, conciergerie).
RELATIONS: <- studios (1:N) | -> locations (N:1, via location_id, ajout migration 099)
TRIGGERS: On UPDATE -> updated_at auto-mis a jour.
RLS: SELECT = tout authenticated | INSERT/UPDATE/DELETE = admin ou super_admin uniquement.
';

COMMENT ON COLUMN buildings.name IS 'Nom commercial de l''immeuble (ex: Le Citadin, Le Cardinal). Unique. Mappe a un property_building via la table locations.';
COMMENT ON COLUMN buildings.location_id IS 'FK vers locations. Lie ce building de menage a sa geolocalisation. Backfill migration 100 avec mapping manuel (ex: Le Cardinal -> 254-258_Cardinal-Begin-E).';


-- -----------------------------------------------
-- studios (Level B)
-- -----------------------------------------------

COMMENT ON TABLE studios IS '
ROLE: Unite nettoyable dans un building de menage. Chaque studio a un QR code physique colle sur place, scanne par l''employe pour demarrer/terminer une session de menage.
REGLES: Un studio peut etre de type unit (logement), common_area (aires communes) ou conciergerie. Le QR code est unique globalement. La paire (building_id, studio_number) est unique.
RELATIONS: -> buildings (N:1) | <- cleaning_sessions (1:N)
TRIGGERS: On UPDATE -> updated_at auto-mis a jour.
RLS: SELECT = tout authenticated | INSERT/UPDATE/DELETE = admin ou super_admin uniquement.
';

COMMENT ON COLUMN studios.qr_code IS 'Code aleatoire imprime sur le QR physique. Scanne via l''app mobile pour identifier le studio. Unique globalement.';
COMMENT ON COLUMN studios.studio_number IS 'Numero du studio affiche (ex: 201, Aires communes, Conciergerie). Unique par building.';
COMMENT ON COLUMN studios.building_id IS 'FK vers buildings. Immeuble auquel appartient ce studio.';
COMMENT ON COLUMN studios.studio_type IS 'Type de studio. Values: unit = logement a nettoyer (seuil flag 5 min) | common_area = aires communes (seuil flag 2 min) | conciergerie = bureau de conciergerie (seuil flag 2 min).';
COMMENT ON COLUMN studios.is_active IS 'false = studio desactive, scan_in refuse avec erreur STUDIO_INACTIVE.';


-- -----------------------------------------------
-- cleaning_sessions (Level C)
-- -----------------------------------------------

COMMENT ON TABLE cleaning_sessions IS '
ROLE: Session de menage d''un studio, tracee du scan-in QR au scan-out QR. Represente le travail effectif d''un employe sur une unite nettoyable pendant un shift.
STATUTS: in_progress = session active, employe en train de nettoyer | completed = termine normalement via scan-out QR | auto_closed = ferme automatiquement quand le shift passe a completed (trigger trg_auto_close_sessions_on_shift_complete ou RPC auto_close_shift_sessions) | manually_closed = ferme par superviseur/admin (RPC manually_close_session) ou auto-ferme quand l''employe scanne un autre studio/demarre un entretien (migration 148)
REGLES: Un employe ne peut avoir qu''une seule session in_progress a la fois (enforce par scan_in qui ferme les sessions precedentes). Protection double-tap: si meme employe+studio scanne < 5 secondes, retourne la session existante au lieu d''en creer une nouvelle. completed_at doit etre > started_at (CHECK). duration_minutes >= 0 (CHECK). Le flagging est automatique au scan-out/auto-close via _compute_cleaning_flags().
RELATIONS: -> employee_profiles (N:1) | -> studios (N:1) | -> shifts (N:1)
TRIGGERS: On UPDATE -> updated_at auto-mis a jour. On shifts.status -> completed: trigger trg_auto_close_sessions_on_shift_complete ferme toutes les sessions in_progress du shift.
RLS: SELECT = employe voit ses propres sessions | superviseur voit celles de ses employes (via employee_supervisors) | admin/super_admin voit tout. INSERT = employe pour ses propres sessions. UPDATE = employe sur ses sessions in_progress | superviseur sur sessions de ses employes | admin/super_admin sur tout.
';

COMMENT ON COLUMN cleaning_sessions.employee_id IS 'FK vers employee_profiles. L''employe qui effectue le menage.';
COMMENT ON COLUMN cleaning_sessions.studio_id IS 'FK vers studios. Le studio nettoye, identifie par scan QR.';
COMMENT ON COLUMN cleaning_sessions.shift_id IS 'FK vers shifts. Le shift actif au moment du scan-in. Doit etre status=active pour que scan_in accepte.';
COMMENT ON COLUMN cleaning_sessions.status IS 'Cycle de vie: in_progress -> completed (scan-out) | in_progress -> auto_closed (fin de shift) | in_progress -> manually_closed (superviseur ou nouveau scan). Enum cleaning_session_status.';
COMMENT ON COLUMN cleaning_sessions.started_at IS 'Timestamp du scan-in QR (now() au moment de l''appel scan_in).';
COMMENT ON COLUMN cleaning_sessions.completed_at IS 'Timestamp du scan-out, auto-close ou fermeture manuelle. NULL tant que in_progress.';
COMMENT ON COLUMN cleaning_sessions.duration_minutes IS 'Duree calculee en minutes (NUMERIC 10,2). Calculee comme EXTRACT(EPOCH FROM (completed_at - started_at)) / 60. NULL tant que in_progress.';
COMMENT ON COLUMN cleaning_sessions.is_flagged IS 'true = session anomale detectee automatiquement par _compute_cleaning_flags(). Seuils: unit < 5 min, common_area/conciergerie < 2 min, toute session > 240 min (4h).';
COMMENT ON COLUMN cleaning_sessions.flag_reason IS 'Raison du flag en texte libre. Values: "Duration too short for unit (< 5 min)" | "Duration too short (< 2 min)" | "Duration too long (> 4 hours)" | NULL si non-flagge.';
COMMENT ON COLUMN cleaning_sessions.start_latitude IS 'Latitude GPS au moment du scan-in (ajout migration 037). Preuve de localisation.';
COMMENT ON COLUMN cleaning_sessions.start_longitude IS 'Longitude GPS au moment du scan-in.';
COMMENT ON COLUMN cleaning_sessions.start_accuracy IS 'Precision GPS en metres au scan-in.';
COMMENT ON COLUMN cleaning_sessions.end_latitude IS 'Latitude GPS au moment du scan-out.';
COMMENT ON COLUMN cleaning_sessions.end_longitude IS 'Longitude GPS au moment du scan-out.';
COMMENT ON COLUMN cleaning_sessions.end_accuracy IS 'Precision GPS en metres au scan-out.';


-- -----------------------------------------------
-- property_buildings (Level B)
-- -----------------------------------------------

COMMENT ON TABLE property_buildings IS '
ROLE: Immeuble du parc immobilier Tri-logis (76 batiments). Donnees de reference importees du systeme de gestion immobiliere. Utilise comme reference pour les sessions de maintenance (contrairement a buildings qui sert au menage).
REGLES: Certains batiments desactives (is_active=false) sont des stationnements sans geolocalisation (migration 100). Champs cadastre/matricule proviennent du registre foncier.
RELATIONS: <- apartments (1:N) | <- maintenance_sessions (1:N) | -> locations (N:1, via location_id, ajout migration 099)
TRIGGERS: On UPDATE -> updated_at auto-mis a jour.
RLS: SELECT = tout authenticated (donnees de reference en lecture seule). Pas de policies INSERT/UPDATE/DELETE pour authenticated (donnees gerees par migration/admin).
';

COMMENT ON COLUMN property_buildings.name IS 'Nom du batiment dans le format adresse (ex: 254-258_Cardinal-Begin-E). Correspond au name dans la table locations.';
COMMENT ON COLUMN property_buildings.address IS 'Adresse civique complete.';
COMMENT ON COLUMN property_buildings.city IS 'Ville (principalement Rouyn-Noranda).';
COMMENT ON COLUMN property_buildings.total_units IS 'Nombre total de logements dans l''immeuble.';
COMMENT ON COLUMN property_buildings.is_active IS 'false = batiment desactive (stationnements, vendus). Filtre par defaut dans les UI.';
COMMENT ON COLUMN property_buildings.cadastre IS 'Numero de cadastre du registre foncier.';
COMMENT ON COLUMN property_buildings.matricule IS 'Matricule du role d''evaluation fonciere.';
COMMENT ON COLUMN property_buildings.location_id IS 'FK vers locations. Permet le lien geographique pour la concordance GPS. Backfill par migration 100.';


-- -----------------------------------------------
-- apartments (Level B)
-- -----------------------------------------------

COMMENT ON TABLE apartments IS '
ROLE: Logement (unite locative) dans un property_building. Donnees de reference importees de Tri-logis. Utilise optionnellement dans les sessions de maintenance pour preciser l''appartement concerne.
REGLES: apartment_category contraint a: Residential, Commercial, Storage, Office, Parking, Chalet, Sold.
RELATIONS: -> property_buildings (N:1, via building_id) | <- maintenance_sessions (1:N, optionnel)
TRIGGERS: On UPDATE -> updated_at auto-mis a jour.
RLS: SELECT = tout authenticated (donnees de reference). Pas de policies INSERT/UPDATE/DELETE pour authenticated.
';

COMMENT ON COLUMN apartments.building_id IS 'FK vers property_buildings. L''immeuble contenant ce logement.';
COMMENT ON COLUMN apartments.apartment_name IS 'Nom complet du logement (ex: 254-1, 108-Taschereau-E-1).';
COMMENT ON COLUMN apartments.unit_address IS 'Adresse complete de l''unite.';
COMMENT ON COLUMN apartments.unit_number IS 'Numero d''unite simplifie. Affiche dans l''UI de session maintenance et le dashboard d''approbation.';
COMMENT ON COLUMN apartments.apartment_category IS 'Categorie. Values: Residential = logement | Commercial = local commercial | Storage = entreposage | Office = bureau | Parking = stationnement | Chalet = chalet | Sold = vendu.';
COMMENT ON COLUMN apartments.floor IS 'Etage du logement.';
COMMENT ON COLUMN apartments.rooms_notation IS 'Notation du nombre de pieces (ex: 3 1/2, 4 1/2).';
COMMENT ON COLUMN apartments.is_active IS 'false = logement desactive.';
COMMENT ON COLUMN apartments.market_rent IS 'Loyer du marche en dollars.';
COMMENT ON COLUMN apartments.on_hold IS 'true = logement en attente (renovation, litige, etc).';


-- -----------------------------------------------
-- maintenance_sessions (Level B)
-- -----------------------------------------------

COMMENT ON TABLE maintenance_sessions IS '
ROLE: Session d''entretien/maintenance dans un immeuble du parc Tri-logis. Demarre manuellement (selection batiment + optionnellement appartement), sans QR code. Utilise le systeme property_buildings/apartments (contrairement a cleaning_sessions qui utilise buildings/studios).
STATUTS: in_progress = session active | completed = terminee normalement via complete_maintenance | auto_closed = fermee automatiquement quand le shift passe a completed (trigger trg_auto_close_sessions_on_shift_complete) | manually_closed = fermee par superviseur ou auto-fermee au demarrage d''une nouvelle session (migration 148)
REGLES: Un employe ne peut avoir qu''une session in_progress a la fois. Le demarrage (start_maintenance) bloque si une session de menage est deja active (cross-feature). Protection double-tap < 5 secondes (migration 148). Pas de flagging automatique (contrairement a cleaning_sessions). apartment_id optionnel (maintenance peut etre au niveau batiment).
RELATIONS: -> employee_profiles (N:1) | -> shifts (N:1) | -> property_buildings (N:1) | -> apartments (N:1, optionnel)
TRIGGERS: On UPDATE -> updated_at auto-mis a jour. On shifts.status -> completed: trigger trg_auto_close_sessions_on_shift_complete ferme les sessions in_progress.
RLS: SELECT = employe voit ses sessions | superviseur voit celles de ses employes (via employee_supervisors.manager_id) | admin/super_admin voit tout. INSERT = employe pour ses propres sessions. UPDATE = employe sur ses sessions in_progress | superviseur sur sessions de ses employes | admin/super_admin sur tout.
';

COMMENT ON COLUMN maintenance_sessions.employee_id IS 'FK vers employee_profiles. L''employe effectuant l''entretien.';
COMMENT ON COLUMN maintenance_sessions.shift_id IS 'FK vers shifts. Le shift actif au demarrage. Doit etre status=active.';
COMMENT ON COLUMN maintenance_sessions.building_id IS 'FK vers property_buildings. L''immeuble ou se deroule l''entretien. Obligatoire.';
COMMENT ON COLUMN maintenance_sessions.apartment_id IS 'FK vers apartments. Le logement specifique (optionnel). ON DELETE SET NULL — si l''appartement est supprime, la session reste avec building_id seul.';
COMMENT ON COLUMN maintenance_sessions.status IS 'Cycle de vie identique a cleaning_sessions. Enum maintenance_session_status.';
COMMENT ON COLUMN maintenance_sessions.started_at IS 'Timestamp du demarrage (now() au moment de start_maintenance).';
COMMENT ON COLUMN maintenance_sessions.completed_at IS 'Timestamp de fin. NULL tant que in_progress.';
COMMENT ON COLUMN maintenance_sessions.duration_minutes IS 'Duree calculee en minutes (NUMERIC 10,2). NULL tant que in_progress.';
COMMENT ON COLUMN maintenance_sessions.notes IS 'Notes libres de l''employe sur l''intervention.';
COMMENT ON COLUMN maintenance_sessions.sync_status IS 'Etat de synchronisation offline. Default: synced. Utilise par l''app mobile pour le mode hors-ligne.';
COMMENT ON COLUMN maintenance_sessions.start_latitude IS 'Latitude GPS au demarrage (ajout migration 037). Preuve de localisation.';
COMMENT ON COLUMN maintenance_sessions.start_longitude IS 'Longitude GPS au demarrage.';
COMMENT ON COLUMN maintenance_sessions.start_accuracy IS 'Precision GPS en metres au demarrage.';
COMMENT ON COLUMN maintenance_sessions.end_latitude IS 'Latitude GPS a la fin de session.';
COMMENT ON COLUMN maintenance_sessions.end_longitude IS 'Longitude GPS a la fin de session.';
COMMENT ON COLUMN maintenance_sessions.end_accuracy IS 'Precision GPS en metres a la fin.';


-- ============================================================
-- LOCATION & APPROVAL TABLES
-- ============================================================

-- -----------------------------------------------
-- locations (Level C)
-- -----------------------------------------------

COMMENT ON TABLE locations IS '
ROLE: Geofences circulaires representant les lieux de travail connus (bureaux, immeubles, fournisseurs, domiciles). Chaque location definit un centre GPS + rayon pour le matching automatique des points GPS et clusters.
STATUTS: is_active = true (geofence active, utilisee pour le matching) | false (desactivee, ignoree par les algorithmes)
REGLES: Le rayon doit etre entre 10m et 1000m. Le matching spatial utilise ST_DWithin avec tolerance combinee (radius_meters + gps_accuracy). En cas de locations multiples qui se chevauchent, la plus proche par ST_Distance gagne. Les chevauchements (distance < somme des rayons) sont bloques a la creation/modification via check_location_overlap(). Un point GPS est matche a la location active la plus proche dont le geofence couvre le point. is_employee_home = true signifie que cette location peut servir de domicile pour certains employes (via employee_home_locations). is_also_office = true signifie que cette location est aussi un bureau — les clusters y sont types "office" sauf si une session menage/entretien est active.
RELATIONS: -> employee_profiles (N:1 implicite via employee_home_locations) | <- location_matches (1:N) | <- stationary_clusters (1:N via matched_location_id) | <- trips (1:N via start_location_id, end_location_id) | <- employee_home_locations (1:N) | <- buildings (1:N via location_id) | <- property_buildings (1:N via location_id)
TRIGGERS: On UPDATE -> updated_at = NOW() (via locations_updated_at_trigger).
ALGORITHME: Classification auto des arrets par type de location : office/building = approved, vendor/gaz = needs_review, home/cafe_restaurant/other = rejected, NULL (non matche) = needs_review. Le type effectif (effective_location_type) peut differer du location_type brut selon les regles de priorite : session menage/entretien active -> building, home override -> home, is_also_office -> office, sinon location_type.
RLS: SELECT/INSERT/UPDATE = superviseur ou superieur (has_supervisor_role). DELETE = admin/super_admin uniquement.
';

COMMENT ON COLUMN locations.location IS 'Centre du geofence en PostGIS geography(POINT, 4326). Utilise pour les calculs de distance spheriques precis via ST_Distance et ST_DWithin. Index GIST pour performance spatiale.';
COMMENT ON COLUMN locations.radius_meters IS 'Rayon du geofence en metres (10-1000). Combine avec la precision GPS du point pour determiner le matching : match si ST_DWithin(location, point, radius_meters + gps_accuracy).';
COMMENT ON COLUMN locations.location_type IS 'Classification du lieu. Values: office = bureau corporatif | building = chantier/immeuble | vendor = fournisseur | gaz = station-service | home = domicile employe | cafe_restaurant = cafe/restaurant | other = lieu divers. Determine le statut auto dans le workflow approbation.';
COMMENT ON COLUMN locations.latitude IS 'Latitude calculee automatiquement depuis la colonne location (GENERATED ALWAYS AS ST_Y). Evite aux clients de devoir appeler ST_Y.';
COMMENT ON COLUMN locations.longitude IS 'Longitude calculee automatiquement depuis la colonne location (GENERATED ALWAYS AS ST_X). Evite aux clients de devoir appeler ST_X.';
COMMENT ON COLUMN locations.is_active IS 'Seules les locations actives sont utilisees pour le matching GPS. Desactiver une location la retire du matching sans la supprimer.';
COMMENT ON COLUMN locations.is_employee_home IS 'Indique que cette location peut etre le domicile d''un employe. Quand true, les employes lies via employee_home_locations voient leurs clusters types "home" au lieu du location_type brut.';
COMMENT ON COLUMN locations.is_also_office IS 'Indique que cette location est aussi un bureau (ex: Le Chic-urbain / 151-159_Principale). Les clusters sont types "office" sauf si une session menage/entretien est active.';
COMMENT ON COLUMN locations.address IS 'Adresse textuelle optionnelle pour reference humaine. Non utilisee dans le matching spatial.';
COMMENT ON COLUMN locations.notes IS 'Notes libres de l''administrateur sur cette location.';


-- -----------------------------------------------
-- day_approvals (Level C)
-- -----------------------------------------------

COMMENT ON TABLE day_approvals IS '
ROLE: Approbation journaliere des heures de travail d''un employe. Represente la decision finale de l''administrateur pour un jour donne : en attente de revision ou approuve avec les totaux geles.
STATUTS: status = pending (jour en attente de revision, totaux calcules dynamiquement) | approved (jour approuve, totaux geles dans approved_minutes/rejected_minutes)
REGLES: Un seul enregistrement par couple (employee_id, date) — contrainte UNIQUE. L''approbation necessite que needs_review_count = 0 (aucune activite en attente de revision, hors trips qui derivent des stops). A l''approbation, approved_minutes et rejected_minutes sont figes et ne changent plus meme si les locations ou les activites sont modifiees. Un jour approuve peut etre rouvert via reopen_day(), ce qui remet status = pending et efface les totaux geles. Le calcul des minutes : approved_minutes = SUM(duration) WHERE final_status = approved, rejected_minutes = SUM(duration) WHERE final_status = rejected. final_status = COALESCE(override_status, auto_status). Les jours avec un shift actif ne peuvent pas etre approuves. Les overrides sur un jour deja approuve sont bloques.
RELATIONS: -> employee_profiles (N:1 via employee_id) | -> employee_profiles (N:1 via approved_by) | <- activity_overrides (1:N via day_approval_id, ON DELETE CASCADE)
TRIGGERS: On UPDATE -> updated_at = NOW() (via set_day_approvals_updated_at).
ALGORITHME: Classification en temps reel via get_day_approval_detail() : chaque activite (stop, trip, clock_in, clock_out) recoit un auto_status base sur le type de location, puis fusionne avec les overrides manuels. Arrets : office/building = approved, vendor/gaz = needs_review, home/cafe_restaurant/other = rejected, non matche = needs_review. Trips : derives des stops adjacents (les deux approved = approved, l''un rejected = rejected). Commute auto-detecte : premier/dernier trajet inconnu->travail ou travail->inconnu = rejected. Anomalies (detour excessif, vitesse irrealiste, GPS gap) = needs_review.
RLS: admin/super_admin = acces complet (ALL). Employes = SELECT sur leurs propres lignes uniquement.
';

COMMENT ON COLUMN day_approvals.employee_id IS 'Employe dont les heures sont approuvees. FK vers employee_profiles. Fait partie de la contrainte UNIQUE(employee_id, date).';
COMMENT ON COLUMN day_approvals.date IS 'Date ouvrable (business date) du jour approuve. Utilise to_business_date() pour gerer les shifts traversant minuit. Fait partie de la contrainte UNIQUE(employee_id, date).';
COMMENT ON COLUMN day_approvals.status IS 'Etat du workflow. Values: pending = en attente de revision par l''admin | approved = jour approuve, totaux geles. Transition pending -> approved via approve_day(). Transition approved -> pending via reopen_day().';
COMMENT ON COLUMN day_approvals.total_shift_minutes IS 'Duree brute totale du shift (clock-in a clock-out) en minutes. Gele a l''approbation. NULL tant que le jour est pending.';
COMMENT ON COLUMN day_approvals.approved_minutes IS 'Minutes approuvees (activites avec final_status = approved). Gele a l''approbation. NULL tant que le jour est pending (calcule dynamiquement).';
COMMENT ON COLUMN day_approvals.rejected_minutes IS 'Minutes rejetees (activites avec final_status = rejected). Gele a l''approbation. NULL tant que le jour est pending (calcule dynamiquement).';
COMMENT ON COLUMN day_approvals.approved_by IS 'Admin qui a approuve le jour. FK vers employee_profiles. NULL tant que status = pending.';
COMMENT ON COLUMN day_approvals.approved_at IS 'Horodatage de l''approbation. NULL tant que status = pending. Remis a NULL lors d''un reopen_day().';
COMMENT ON COLUMN day_approvals.notes IS 'Notes optionnelles de l''admin lors de l''approbation.';


-- -----------------------------------------------
-- location_matches (Level B)
-- -----------------------------------------------

COMMENT ON TABLE location_matches IS '
ROLE: Cache de matching GPS-to-location. Chaque enregistrement associe un point GPS a la location geofence la plus proche qui le contient. Calcule par match_shift_gps_to_locations() et utilise par get_shift_timeline() pour la segmentation de la timeline.
REGLES: Un point GPS est matche a une seule location (la plus proche par ST_Distance parmi celles dont le geofence contient le point). Le score de confiance vaut 1.0 au centre du geofence et 0.0 au bord. Les matches sont calcules a la demande et mis en cache (pas recalcules si deja presents). La contrainte UNIQUE(gps_point_id, location_id) empeche les doublons. Remplace par le matching direct sur clusters/trips dans les versions recentes — principalement utilise pour la visualisation timeline.
RELATIONS: -> gps_points (N:1 via gps_point_id, ON DELETE CASCADE) | -> locations (N:1 via location_id, ON DELETE CASCADE)
RLS: SELECT = superviseur de l''employe du shift, ou l''employe lui-meme, ou admin/manager. INSERT = superviseur ou superieur.
';

COMMENT ON COLUMN location_matches.distance_meters IS 'Distance en metres entre le point GPS et le centre de la location matchee. Calculee via ST_Distance sur geography.';
COMMENT ON COLUMN location_matches.confidence_score IS 'Score de confiance du match : 1.0 quand le point est au centre exact du geofence, 0.0 quand il est sur le bord. Formule : GREATEST(0, 1 - distance/radius).';
COMMENT ON COLUMN location_matches.matched_at IS 'Horodatage du calcul du match. Utilise pour determiner si le cache est a jour.';


-- -----------------------------------------------
-- activity_overrides (Level B)
-- -----------------------------------------------

COMMENT ON TABLE activity_overrides IS '
ROLE: Decisions manuelles de l''administrateur sur une activite individuelle (stop, trip, clock_in, clock_out). Ecrase le statut auto-classifie par le statut choisi par l''admin.
REGLES: Une seule override par activite par jour (UNIQUE sur day_approval_id + activity_type + activity_id). Les overrides ne peuvent etre ajoutees/modifiees que sur un jour pending (bloque si status = approved). L''override prend priorite sur l''auto-classification : final_status = COALESCE(override_status, auto_status). Les trips peuvent etre overrides mais sont normalement derives des stops adjacents. Les IDs d''activite sont deterministes (uuid_generate_v5 base sur shift_id + type + started_at) pour survivre aux re-executions de detect_trips(). Les overrides orphelines (activity_id obsolete) sont ignorees gracieusement.
RELATIONS: -> day_approvals (N:1 via day_approval_id, ON DELETE CASCADE) | -> employee_profiles (N:1 via created_by)
RLS: admin/super_admin = acces complet (ALL).
';

COMMENT ON COLUMN activity_overrides.activity_type IS 'Type d''activite overridee. Values: trip = deplacement | stop = arret (stationary_cluster) | clock_in = pointage entree | clock_out = pointage sortie.';
COMMENT ON COLUMN activity_overrides.activity_id IS 'UUID de l''activite overridee. Pointe vers trips.id, stationary_clusters.id ou shifts.id selon activity_type. Deterministe via uuid_generate_v5 pour survivre aux re-detections.';
COMMENT ON COLUMN activity_overrides.override_status IS 'Statut force par l''admin. Values: approved = heures comptabilisees | rejected = heures exclues.';
COMMENT ON COLUMN activity_overrides.reason IS 'Note optionnelle de l''admin expliquant la raison de l''override.';
COMMENT ON COLUMN activity_overrides.created_by IS 'Admin ayant cree ou modifie l''override. FK vers employee_profiles.';


-- -----------------------------------------------
-- employee_home_locations (Level B)
-- -----------------------------------------------

COMMENT ON TABLE employee_home_locations IS '
ROLE: Association entre un employe et une ou plusieurs locations identifiees comme son domicile. Permet de typer dynamiquement les clusters GPS comme "home" pour un employe specifique, meme si la location est un immeuble (building) de l''entreprise.
REGLES: Un employe peut avoir plusieurs locations "home" (ex: employe logeant dans un immeuble de l''entreprise). La location doit avoir is_employee_home = true pour que l''association prenne effet. Contrainte UNIQUE(employee_id, location_id) empeche les doublons. Effet sur le type effectif : si un cluster matche une location qui est le home de cet employe, effective_location_type = "home" au lieu du location_type brut. Cette regle est prioritaire sur is_also_office mais pas sur les sessions menage/entretien actives. ON DELETE CASCADE sur les deux FK (employe supprime ou location supprimee = association retiree).
RELATIONS: -> employee_profiles (N:1 via employee_id, ON DELETE CASCADE) | -> locations (N:1 via location_id, ON DELETE CASCADE)
RLS: SELECT = admin/super_admin ou superviseur de l''employe. INSERT/UPDATE/DELETE = admin/super_admin uniquement.
';

COMMENT ON COLUMN employee_home_locations.employee_id IS 'Employe associe a cette location domicile. FK vers employee_profiles.';
COMMENT ON COLUMN employee_home_locations.location_id IS 'Location identifiee comme domicile de l''employe. Doit avoir is_employee_home = true sur la table locations pour que l''override de type effectif s''applique.';


-- ============================================================
-- DASHBOARD, REPORT & UTILITY TABLES
-- ============================================================

-- -----------------------------------------------
-- diagnostic_logs (Level B)
-- -----------------------------------------------

COMMENT ON TABLE diagnostic_logs IS '
ROLE: Journal des evenements de diagnostic envoyes par les appareils mobiles pour visibilite a distance sur les problemes GPS, shifts et synchronisation.
REGLES: Retention de 90 jours (cron quotidien a 3h UTC). Sync par batch via RPC sync_diagnostic_logs. UUID client comme PK pour deduplication (ON CONFLICT = duplicate ignore). L''employe ne peut soumettre que ses propres logs (verification caller = employee_id).
RELATIONS: -> auth.users (N:1 via employee_id) | -> shifts (N:1 via shift_id, optionnel)
RLS: INSERT = employe authentifie (ses propres logs) | SELECT = admin et manager uniquement.
';

COMMENT ON COLUMN diagnostic_logs.event_category IS 'Categorie technique de l''evenement. Values: gps = suivi de position | shift = cycle clock-in/out | sync = synchronisation donnees | auth = authentification | permission = permissions OS | lifecycle = cycle de vie app | thermal = surchauffe appareil | error = erreur generique | network = connectivite reseau | battery = niveau batterie | memory = memoire | crash = crash app | service = service background | satellite = reception satellite | doze = mode economie Android | motion = detection mouvement | metrickit = metriques iOS';
COMMENT ON COLUMN diagnostic_logs.severity IS 'Niveau de gravite. Values: info = information normale | warn = avertissement non-bloquant | error = erreur recuperable | critical = erreur bloquante necessitant attention';
COMMENT ON COLUMN diagnostic_logs.metadata IS 'Donnees contextuelles libres en JSONB (stack trace, valeurs capteur, etc.)';
COMMENT ON COLUMN diagnostic_logs.received_at IS 'Horodatage de reception serveur (DEFAULT NOW()). Distinct de created_at qui est l''heure de capture sur l''appareil.';
COMMENT ON COLUMN diagnostic_logs.platform IS 'Plateforme mobile. Values: ios | android';


-- -----------------------------------------------
-- device_status (Level B)
-- -----------------------------------------------

COMMENT ON TABLE device_status IS '
ROLE: Instantane de l''etat du device de chaque employe (permissions, version app, modele), mis a jour a chaque clock-in via upsert.
REGLES: Une seule ligne par employe (UNIQUE sur employee_id). Upsert via ON CONFLICT — la ligne est creee au premier clock-in et mise a jour ensuite. Aucun historique conserve, seul le dernier etat est stocke.
RELATIONS: -> employee_profiles (1:1 via employee_id ON DELETE CASCADE)
RLS: ALL = employe (sa propre ligne) | SELECT = admin/super_admin (toutes les lignes).
';

COMMENT ON COLUMN device_status.gps_permission IS 'Permission GPS accordee par l''OS. Values typiques: denied | whenInUse | always';
COMMENT ON COLUMN device_status.precise_location_enabled IS 'True si la localisation precise est activee (vs approximative sur iOS 14+)';
COMMENT ON COLUMN device_status.battery_optimization_disabled IS 'True si l''optimisation de batterie est desactivee pour l''app (important pour le tracking GPS en arriere-plan)';
COMMENT ON COLUMN device_status.app_standby_bucket IS 'Android App Standby Bucket. Values typiques: ACTIVE | WORKING_SET | FREQUENT | RARE | RESTRICTED. Affecte la frequence des taches background autorisees par Android.';


-- -----------------------------------------------
-- lunch_breaks (Level B)
-- -----------------------------------------------

COMMENT ON TABLE lunch_breaks IS '
ROLE: Pauses diner declarees manuellement par les employes pendant un shift actif, deduites du temps de travail total dans les approbations.
REGLES: Une pause = started_at renseigne, ended_at NULL tant que la pause est en cours. La duree est soustraite de total_shift_minutes dans les approbations. Les pauses apparaissent comme activite de type ''lunch'' (auto_status = approved) dans la timeline d''approbation. Les pauses sont considerees comme temps couvert pour la detection de gaps (pas de faux "temps non suivi"). Publication Realtime activee pour les mises a jour live du dashboard.
RELATIONS: -> shifts (N:1 via shift_id ON DELETE CASCADE) | -> employee_profiles (N:1 via employee_id)
RLS: SELECT/INSERT/UPDATE = employe (ses propres pauses) | SELECT = superviseur (via employee_supervisors) | ALL = admin.
';

COMMENT ON COLUMN lunch_breaks.started_at IS 'Debut de la pause diner. Toujours renseigne des la creation.';
COMMENT ON COLUMN lunch_breaks.ended_at IS 'Fin de la pause diner. NULL = pause en cours (is_on_lunch = true dans le monitoring).';


-- -----------------------------------------------
-- report_schedules (Level B)
-- -----------------------------------------------

COMMENT ON TABLE report_schedules IS '
ROLE: Planifications recurrentes de generation de rapports, configurees par les admins pour une execution automatique periodique.
STATUTS: active = planification active, prochaine execution prevue | paused = temporairement suspendue | deleted = supprimee logiquement (soft delete, jamais affichee)
REGLES: Seuls les admin/super_admin peuvent creer des planifications. La suppression est logique (status = deleted). next_run_at recalcule apres chaque execution. run_count et failure_count trackent l''historique d''execution.
RELATIONS: -> auth.users (N:1 via user_id ON DELETE CASCADE) | <- report_jobs (1:N via schedule_id)
RLS: ALL = utilisateur proprietaire (user_id = auth.uid()).
';

COMMENT ON COLUMN report_schedules.report_type IS 'Type de rapport. Values: timesheet = feuilles de temps | activity_summary = resume d''activite equipe | attendance = presence/absences';
COMMENT ON COLUMN report_schedules.config IS 'Configuration du rapport en JSONB (meme structure que report_jobs.config): date_range, employee_filter, format, etc.';
COMMENT ON COLUMN report_schedules.frequency IS 'Frequence d''execution. Values: weekly = hebdomadaire | bi_weekly = aux 2 semaines | monthly = mensuel';
COMMENT ON COLUMN report_schedules.schedule_config IS 'Configuration detaillee de la planification en JSONB (jour de la semaine, heure, etc.)';
COMMENT ON COLUMN report_schedules.last_run_status IS 'Resultat de la derniere execution. Values: success = reussi | failed = echoue';


-- -----------------------------------------------
-- report_jobs (Level A)
-- -----------------------------------------------

COMMENT ON TABLE report_jobs IS 'ROLE: File d''attente et historique des rapports generes (sync ou async), avec statut d''execution, fichier resultant et expiration a 30 jours.';


-- -----------------------------------------------
-- report_audit_logs (Level A)
-- -----------------------------------------------

COMMENT ON TABLE report_audit_logs IS 'ROLE: Journal d''audit des actions sur les rapports (generation, telechargement, suppression, planification) avec contexte IP/user-agent.';


-- -----------------------------------------------
-- audit.audit_logs (Level B)
-- -----------------------------------------------

COMMENT ON TABLE audit.audit_logs IS '
ROLE: Journal d''audit immutable capturant toutes les modifications (INSERT/UPDATE/DELETE) sur les tables auditees, via trigger generique audit.log_changes().
REGLES: Aucune ecriture directe — insertion uniquement via trigger SECURITY DEFINER. Stocke old_values et new_values en JSONB pour tracabilite complete. Aucune politique DELETE/UPDATE — les entrees sont immuables.
RELATIONS: -> employee_profiles (N:1 via user_id, l''auteur du changement) | Les record_id + table_name identifient la ligne modifiee.
TRIGGERS: audit.log_changes() declenche AFTER INSERT/UPDATE/DELETE sur: employee_profiles, employee_supervisors.
RLS: SELECT = admin/super_admin uniquement. Aucune politique INSERT/UPDATE/DELETE (ecriture via trigger SECURITY DEFINER seulement).
';

COMMENT ON COLUMN audit.audit_logs.operation IS 'Type d''operation DML. Values: INSERT | UPDATE | DELETE';
COMMENT ON COLUMN audit.audit_logs.record_id IS 'UUID de la ligne modifiee dans la table source (correspond a la colonne id de la table auditee)';
COMMENT ON COLUMN audit.audit_logs.old_values IS 'Valeurs avant modification (JSONB). NULL pour INSERT. Contient to_jsonb(OLD) pour UPDATE et DELETE.';
COMMENT ON COLUMN audit.audit_logs.new_values IS 'Valeurs apres modification (JSONB). NULL pour DELETE. Contient to_jsonb(NEW) pour INSERT et UPDATE.';
COMMENT ON COLUMN audit.audit_logs.email IS 'Email de l''utilisateur ayant effectue le changement, resolu depuis employee_profiles au moment du trigger.';
COMMENT ON COLUMN audit.audit_logs.change_reason IS 'Motif du changement (optionnel, renseigne manuellement si applicable).';


-- -----------------------------------------------
-- app_config (Level A)
-- -----------------------------------------------

COMMENT ON TABLE app_config IS 'ROLE: Paires cle-valeur de configuration globale de l''application (ex: minimum_app_version, fcm_enabled), lisibles par tous les authentifies, modifiables par les admins uniquement.';


-- -----------------------------------------------
-- app_settings (Level A)
-- -----------------------------------------------

COMMENT ON TABLE app_settings IS 'ROLE: Table single-row (CHECK id = 1) stockant le fuseau horaire metier (timezone) utilise par les fonctions helper to_business_date(), business_day_start(), business_day_end().';
