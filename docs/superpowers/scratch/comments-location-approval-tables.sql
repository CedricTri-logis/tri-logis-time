-- ============================================================================
-- COMMENT ON statements for location & approval tables
-- Generated from specs, design docs, and migrations
-- ============================================================================

-- ============================================================================
-- TABLE: locations (Level C — maximal detail)
-- ============================================================================

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


-- ============================================================================
-- TABLE: day_approvals (Level C — maximal detail)
-- ============================================================================

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


-- ============================================================================
-- TABLE: location_matches (Level B — standard detail)
-- ============================================================================

COMMENT ON TABLE location_matches IS '
ROLE: Cache de matching GPS-to-location. Chaque enregistrement associe un point GPS a la location geofence la plus proche qui le contient. Calcule par match_shift_gps_to_locations() et utilise par get_shift_timeline() pour la segmentation de la timeline.
REGLES: Un point GPS est matche a une seule location (la plus proche par ST_Distance parmi celles dont le geofence contient le point). Le score de confiance vaut 1.0 au centre du geofence et 0.0 au bord. Les matches sont calcules a la demande et mis en cache (pas recalcules si deja presents). La contrainte UNIQUE(gps_point_id, location_id) empeche les doublons. Remplace par le matching direct sur clusters/trips dans les versions recentes — principalement utilise pour la visualisation timeline.
RELATIONS: -> gps_points (N:1 via gps_point_id, ON DELETE CASCADE) | -> locations (N:1 via location_id, ON DELETE CASCADE)
RLS: SELECT = superviseur de l''employe du shift, ou l''employe lui-meme, ou admin/manager. INSERT = superviseur ou superieur.
';

COMMENT ON COLUMN location_matches.distance_meters IS 'Distance en metres entre le point GPS et le centre de la location matchee. Calculee via ST_Distance sur geography.';

COMMENT ON COLUMN location_matches.confidence_score IS 'Score de confiance du match : 1.0 quand le point est au centre exact du geofence, 0.0 quand il est sur le bord. Formule : GREATEST(0, 1 - distance/radius).';

COMMENT ON COLUMN location_matches.matched_at IS 'Horodatage du calcul du match. Utilise pour determiner si le cache est a jour.';


-- ============================================================================
-- TABLE: activity_overrides (Level B — standard detail)
-- ============================================================================

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


-- ============================================================================
-- TABLE: employee_home_locations (Level B — standard detail)
-- ============================================================================

COMMENT ON TABLE employee_home_locations IS '
ROLE: Association entre un employe et une ou plusieurs locations identifiees comme son domicile. Permet de typer dynamiquement les clusters GPS comme "home" pour un employe specifique, meme si la location est un immeuble (building) de l''entreprise.
REGLES: Un employe peut avoir plusieurs locations "home" (ex: employe logeant dans un immeuble de l''entreprise). La location doit avoir is_employee_home = true pour que l''association prenne effet. Contrainte UNIQUE(employee_id, location_id) empeche les doublons. Effet sur le type effectif : si un cluster matche une location qui est le home de cet employe, effective_location_type = "home" au lieu du location_type brut. Cette regle est prioritaire sur is_also_office mais pas sur les sessions menage/entretien actives. ON DELETE CASCADE sur les deux FK (employe supprime ou location supprimee = association retiree).
RELATIONS: -> employee_profiles (N:1 via employee_id, ON DELETE CASCADE) | -> locations (N:1 via location_id, ON DELETE CASCADE)
RLS: SELECT = admin/super_admin ou superviseur de l''employe. INSERT/UPDATE/DELETE = admin/super_admin uniquement.
';

COMMENT ON COLUMN employee_home_locations.employee_id IS 'Employe associe a cette location domicile. FK vers employee_profiles.';

COMMENT ON COLUMN employee_home_locations.location_id IS 'Location identifiee comme domicile de l''employe. Doit avoir is_employee_home = true sur la table locations pour que l''override de type effectif s''applique.';
