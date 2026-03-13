-- =============================================================================
-- COMMENT ON statements for trip & mileage tracking tables
-- Generated from specs, design docs, and migrations
-- =============================================================================

-- =============================================================================
-- LEVEL C (maximal detail): trips
-- =============================================================================

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

COMMENT ON COLUMN trips.end_latitude IS 'Latitude du centroide pondere du cluster d arrivee.';
COMMENT ON COLUMN trips.end_longitude IS 'Longitude du centroide pondere du cluster d arrivee.';
COMMENT ON COLUMN trips.end_address IS 'Adresse obtenue par reverse-geocoding du point d arrivee.';
COMMENT ON COLUMN trips.end_location_id IS 'Location geofencee la plus proche de l arrivee. Assignee par match_trip_to_location() avec buffer de precision GPS.';

COMMENT ON COLUMN trips.distance_km IS 'Distance haversine centroide-a-centroide multipliee par le facteur de correction 1.3x. Peut etre remplacee par road_distance_km apres OSRM matching.';
COMMENT ON COLUMN trips.duration_minutes IS 'Duree = ended_at - started_at en minutes. Minimum 1 minute.';

COMMENT ON COLUMN trips.classification IS 'Classification du trajet. Values: business = professionnel (defaut, inclus dans le remboursement) | personal = personnel (exclus). Modifiable par l employe.';

COMMENT ON COLUMN trips.confidence_score IS 'Score de confiance 0-1 base sur le ratio de points GPS basse precision. Formule: 1 - (low_accuracy_segments / gps_point_count). Points avec accuracy > 50m = basse precision.';
COMMENT ON COLUMN trips.gps_point_count IS 'Nombre de points GPS dans le buffer de transit entre les deux clusters. 0 = trajet synthetique (GPS gap, aucune trace GPS).';
COMMENT ON COLUMN trips.low_accuracy_segments IS 'Nombre de points GPS avec accuracy > 50m dans ce trajet.';

COMMENT ON COLUMN trips.detection_method IS 'Values: auto = detecte par detect_trips() | manual = cree manuellement.';

COMMENT ON COLUMN trips.start_cluster_id IS 'FK vers le cluster stationnaire de depart. Les coordonnees du trajet proviennent du centroide de ce cluster.';
COMMENT ON COLUMN trips.end_cluster_id IS 'FK vers le cluster stationnaire d arrivee. NULL pour les trajets trailing (fin de donnees sans cluster d arrivee).';

COMMENT ON COLUMN trips.start_location_match_method IS 'Methode d assignation du start_location_id. Values: auto = geofence matching automatique | manual = correction admin via update_trip_location().';
COMMENT ON COLUMN trips.end_location_match_method IS 'Methode d assignation du end_location_id. Values: auto = geofence matching automatique | manual = correction admin.';

COMMENT ON COLUMN trips.transport_mode IS 'Mode de transport classifie par classify_trip_transport_mode(). Values: driving = vehicule | walking = marche | unknown = non classifie. Criteres: >10 km/h moy. = driving, <4 km/h = walking, 4-10 km/h = analyse par segments.';

COMMENT ON COLUMN trips.has_gps_gap IS 'TRUE quand le trajet a ete cree avec peu ou pas de trace GPS (trajet synthetique entre clusters, ou gap >15 min). Declenche auto_status=needs_review pour approbation superviseur.';
COMMENT ON COLUMN trips.gps_gap_seconds IS 'Total des secondes de gaps GPS >5 min dans ce trajet (exces au-dela de 5 min de grace).';
COMMENT ON COLUMN trips.gps_gap_count IS 'Nombre de gaps GPS individuels >5 min dans ce trajet.';

COMMENT ON COLUMN trips.road_distance_km IS 'Distance routiere OSRM apres map-matching (/match) ou estimation (/route pour les trajets synthetiques). NULL si pas encore matche.';
COMMENT ON COLUMN trips.estimated_distance_km IS 'Part de road_distance_km estimee via OSRM /route (pas matchee GPS). Permet d afficher "18.3 km (dont 4.2 km estimes)".';

COMMENT ON COLUMN trips.expected_distance_km IS 'Distance routiere optimale OSRM entre les deux locations connues (start et end). NULL si un endpoint est inconnu. Sert a la detection d anomalies : trajet reel > 2x expected = detour excessif.';
COMMENT ON COLUMN trips.expected_duration_seconds IS 'Duree de trajet estimee OSRM entre les deux locations connues. NULL si un endpoint est inconnu. Trajet reel > 2x expected = duree anormale.';

COMMENT ON COLUMN trips.match_status IS 'Statut du matching OSRM. Values: pending = en attente | processing = en cours | matched = trace routiere obtenue | failed = echec OSRM | anomalous = anomalie detectee. Le cron pg_cron appelle batch-match-trips toutes les 5 min pour les pending.';

-- =============================================================================
-- LEVEL C (maximal detail): stationary_clusters
-- =============================================================================

COMMENT ON TABLE stationary_clusters IS '
ROLE: Groupe de points GPS stationnaires representant un arret prolonge (>=3 min) dans un rayon de 50m, avec centroide pondere par la precision GPS inverse. Entite de premier niveau pour la visualisation des arrets et la liaison aux trajets.
REGLES: Detecte par detect_trips() en meme temps que les trajets. Un cluster est confirme quand des points GPS restent dans un rayon de 50m (ajuste pour la precision GPS) pendant >=3 minutes. Centroide calcule par ponderation inverse de la precision : SUM(lat/GREATEST(acc,1)) / SUM(1/GREATEST(acc,1)). Les points GPS du cluster sont tagges via gps_points.stationary_cluster_id. Les clusters ne sont PAS coupes par les gaps GPS (les gaps sont normaux en mode stationnaire avec frequence adaptative de 120s). Pour les quarts termines : suppression et recreation totale. Le champ effective_location_type permet de surcharger le type de lieu (ex: domicile qui est aussi bureau pour certains employes).
RELATIONS: -> shifts (N:1) | -> employee_profiles (N:1) | -> locations (N:1, matched_location_id) | <- gps_points (1:N, via stationary_cluster_id) | <- trips (1:N, via start_cluster_id) | <- trips (1:N, via end_cluster_id)
ALGORITHME: Pendant la passe unique de detect_trips() : tracker concurrent "cluster courant" + "cluster tentatif". Distance ajustee au cluster = GREATEST(haversine_km(centroide, point)*1000 - precision_point, 0). Si <=50m, le point rejoint le cluster. Si >50m, il demarre un cluster tentatif. Quand le tentatif atteint 3 min, le cluster courant est finalise, un trajet est cree, et le tentatif est promu. Precision du centroide combinee : 1/SQRT(SUM(1/GREATEST(acc^2, 1))). La location matchee est assignee par match_trip_to_location(centroide_lat, centroide_lng, centroide_accuracy).
RLS: SELECT = admin/super_admin voit tout | employe voit ses propres clusters | superviseur voit les employes supervises. INSERT/UPDATE/DELETE = via RPC SECURITY DEFINER (detect_trips).
';

COMMENT ON COLUMN stationary_clusters.centroid_latitude IS 'Latitude du centroide pondere par precision GPS inverse. Plus precis qu un point GPS individuel (amelioration mesuree de ~11m).';
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


-- =============================================================================
-- LEVEL B (standard detail): trip_gps_points
-- =============================================================================

COMMENT ON TABLE trip_gps_points IS '
ROLE: Table de jonction reliant les trajets aux points GPS du buffer de transit (points entre les deux clusters stationnaires).
REGLES: Les points sont inseres dans l ordre chronologique (sequence_order). Ne contient PAS les points stationnaires des clusters de depart/arrivee, seulement les points en mouvement. Peut etre vide (gps_point_count=0) pour les trajets synthetiques. Supprime en cascade avec le trajet parent. ON CONFLICT DO NOTHING pour eviter les doublons.
RELATIONS: -> trips (N:1, CASCADE) | -> gps_points (N:1, CASCADE)
RLS: SELECT = utilisateurs qui ont acces au trajet parent | INSERT/DELETE = authenticated (via RPC).
';

COMMENT ON COLUMN trip_gps_points.sequence_order IS 'Ordre chronologique du point dans le trajet, commence a 1.';


-- =============================================================================
-- LEVEL B (standard detail): reimbursement_rates
-- =============================================================================

COMMENT ON TABLE reimbursement_rates IS '
ROLE: Configuration du taux de remboursement kilometrique avec paliers et dates d effet. Modele CRA/ARC canadien avec taux different apres un seuil.
REGLES: Taux par defaut = CRA/ARC 2026 : 0.72$/km pour les premiers 5000 km, puis 0.66$/km. Les changements de taux s appliquent prospectivement (pas d effet retroactif sur les rapports generes). Les rapports figent le taux utilise au moment de la generation. Un seul taux actif a la fois (effective_to NULL = taux courant). Ecriture reservee aux admins via service role.
RELATIONS: -> employee_profiles (N:1, created_by, nullable)
RLS: SELECT = tous les utilisateurs authentifies | INSERT/UPDATE = admin uniquement (via service role).
';

COMMENT ON COLUMN reimbursement_rates.rate_per_km IS 'Taux en $/km pour le premier palier. Ex: 0.7200 = 0.72$/km.';
COMMENT ON COLUMN reimbursement_rates.threshold_km IS 'Seuil en km declenchant le taux reduit. Ex: 5000. NULL = taux unique sans palier.';
COMMENT ON COLUMN reimbursement_rates.rate_after_threshold IS 'Taux en $/km apres le seuil. Ex: 0.6600. NULL = taux unique.';
COMMENT ON COLUMN reimbursement_rates.effective_from IS 'Date de debut d effet du taux.';
COMMENT ON COLUMN reimbursement_rates.effective_to IS 'Date de fin d effet. NULL = taux actuellement actif.';
COMMENT ON COLUMN reimbursement_rates.rate_source IS 'Origine du taux. Values: cra = taux officiel CRA/ARC Canada | custom = taux personnalise par l employeur.';


-- =============================================================================
-- LEVEL B (standard detail): mileage_reports
-- =============================================================================

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


-- =============================================================================
-- LEVEL B (standard detail): employee_vehicle_periods
-- =============================================================================

COMMENT ON TABLE employee_vehicle_periods IS '
ROLE: Periodes d acces a un vehicule (personnel ou entreprise) pour chaque employe. Determine l eligibilite au remboursement kilometrique et le role conducteur/passager dans le covoiturage.
REGLES: Periodes non-chevauchantes par employe + type de vehicule (trigger trg_check_vehicle_period_overlap). Un employe peut avoir les deux types simultanement (voiture perso + camion entreprise). ended_at NULL = periode en cours. Les employes avec vehicule entreprise actif ne sont PAS rembourses. La detection de covoiturage utilise les periodes pour assigner automatiquement le conducteur : 1 seul membre avec vehicule personnel = conducteur auto-assigne. Gestion admin uniquement (dashboard), pas d interface employe.
RELATIONS: -> employee_profiles (N:1, CASCADE) | -> employee_profiles (N:1, created_by)
TRIGGERS: On INSERT/UPDATE -> check_vehicle_period_overlap() empeche les chevauchements | On UPDATE -> update_updated_at_column() met a jour updated_at.
RLS: ALL = admin/super_admin | SELECT = employe voit ses propres periodes.
';

COMMENT ON COLUMN employee_vehicle_periods.vehicle_type IS 'Type de vehicule. Values: personal = vehicule personnel (eligible remboursement) | company = vehicule entreprise (pas de remboursement).';
COMMENT ON COLUMN employee_vehicle_periods.started_at IS 'Date de debut de la periode d acces au vehicule.';
COMMENT ON COLUMN employee_vehicle_periods.ended_at IS 'Date de fin de la periode. NULL = periode en cours (acces actif).';
COMMENT ON COLUMN employee_vehicle_periods.notes IS 'Description libre du vehicule. Ex: "Ford Escape 2022", "Camion Tri-Logis #12".';


-- =============================================================================
-- LEVEL B (standard detail): carpool_groups
-- =============================================================================

COMMENT ON TABLE carpool_groups IS '
ROLE: Groupe de covoiturage detecte automatiquement — employes ayant voyage ensemble le meme jour (departs et arrivees < 200m, chevauchement temporel > 80%).
STATUTS: status: auto_detected = detecte par l algorithme, en attente de revision | confirmed = confirme par admin | dismissed = rejete par admin.
REGLES: Detection par detect_carpools(date) : comparaison par paires de trajets driving du meme jour. Criteres : distance haversine entre departs < 200m ET entre arrivees < 200m ET chevauchement temporel > 80% de la duree du plus court trajet. Groupement transitif (union-find) : si A~B et B~C alors groupe {A,B,C}. Attribution automatique du conducteur via employee_vehicle_periods : 1 seul membre avec vehicule personnel = conducteur. 0 ou 2+ = review_needed=true. Idempotent : supprime les groupes existants pour la date avant recreation.
RELATIONS: -> employee_profiles (N:1, driver_employee_id) | -> employee_profiles (N:1, reviewed_by) | <- carpool_members (1:N, CASCADE)
RLS: ALL = admin/super_admin | SELECT = employes membres du groupe.
';

COMMENT ON COLUMN carpool_groups.trip_date IS 'Date des trajets du groupe de covoiturage.';
COMMENT ON COLUMN carpool_groups.driver_employee_id IS 'Employe identifie comme conducteur. Auto-assigne quand exactement 1 membre a un vehicule personnel actif. Modifiable par admin.';
COMMENT ON COLUMN carpool_groups.review_needed IS 'TRUE quand 0 ou 2+ membres ont un vehicule personnel actif — l admin doit designer le conducteur manuellement.';
COMMENT ON COLUMN carpool_groups.review_note IS 'Note de l admin lors de la revision.';


-- =============================================================================
-- LEVEL B (standard detail): carpool_members
-- =============================================================================

COMMENT ON TABLE carpool_members IS '
ROLE: Membre d un groupe de covoiturage avec son role (conducteur/passager). Relie un trajet specifique a un groupe de covoiturage.
REGLES: Un trajet ne peut appartenir qu a un seul groupe de covoiturage (UNIQUE trip_id). Les passagers ne recoivent pas de remboursement kilometrique pour ce trajet. Le role est assigne automatiquement par detect_carpools() puis modifiable par admin.
RELATIONS: -> carpool_groups (N:1, CASCADE) | -> trips (N:1, CASCADE, UNIQUE) | -> employee_profiles (N:1)
RLS: ALL = admin/super_admin | SELECT = employe voit sa propre appartenance + co-membres du groupe.
';

COMMENT ON COLUMN carpool_members.role IS 'Role dans le covoiturage. Values: driver = conducteur (seul rembourse) | passenger = passager (pas rembourse) | unassigned = non attribue (review_needed sur le groupe).';


-- =============================================================================
-- LEVEL B (standard detail): ignored_location_clusters
-- =============================================================================

COMMENT ON TABLE ignored_location_clusters IS '
ROLE: Clusters de trajets non-matches rejetes par les admins depuis l onglet Suggested locations du dashboard. Empeche les memes clusters de reapparaitre comme suggestions.
REGLES: Un cluster rejete est filtre dans get_unmatched_trip_clusters() par proximite geographique (150m tolerance via ST_DWithin). Le cluster reapparait automatiquement si son nombre d occurrences depasse le nombre au moment du rejet (occurrence_count_at_ignore), ce qui indique de nouvelles donnees significatives. Remplace en partie par ignored_trip_endpoints (migration 056) qui permet un rejet plus granulaire.
RELATIONS: -> auth.users (N:1, ignored_by)
RLS: ALL = admin/super_admin uniquement.
';

COMMENT ON COLUMN ignored_location_clusters.centroid_latitude IS 'Latitude du centroide du cluster rejete.';
COMMENT ON COLUMN ignored_location_clusters.centroid_longitude IS 'Longitude du centroide du cluster rejete.';
COMMENT ON COLUMN ignored_location_clusters.occurrence_count_at_ignore IS 'Nombre d occurrences du cluster au moment du rejet. Si le cluster depasse ce nombre, il reapparait dans les suggestions.';


-- =============================================================================
-- LEVEL B (standard detail): ignored_trip_endpoints
-- =============================================================================

COMMENT ON TABLE ignored_trip_endpoints IS '
ROLE: Endpoint individuel de trajet rejete par un admin depuis l onglet Suggested locations. Plus granulaire que ignored_location_clusters (rejet par endpoint, pas par cluster).
REGLES: Filtre les endpoints dans get_unmatched_trip_clusters() et get_cluster_occurrences() via NOT EXISTS. Un endpoint rejete ne reapparait jamais (pas de logique de seuil comme ignored_location_clusters). UNIQUE(trip_id, endpoint_type) empeche les doublons. Supprime en cascade avec le trajet parent.
RELATIONS: -> trips (N:1, CASCADE) | -> auth.users (N:1, ignored_by)
RLS: ALL = admin/super_admin uniquement.
';

COMMENT ON COLUMN ignored_trip_endpoints.endpoint_type IS 'Type d endpoint rejete. Values: start = point de depart | end = point d arrivee.';
