-- =============================================================================
-- COMMENT ON statements: cleaning & property tables
-- Tables: cleaning_sessions (Level C), buildings, studios, property_buildings,
--         apartments, maintenance_sessions (Level B)
-- Generated: 2026-03-09
-- =============================================================================

-- =============================================================================
-- SECTION 1: buildings (ancien systeme de menage)
-- =============================================================================

COMMENT ON TABLE buildings IS '
ROLE: Immeubles de location courte duree geres par Tri-logis, utilises pour le suivi de menage par QR code. Chaque building contient des studios (unites, aires communes, conciergerie).
RELATIONS: <- studios (1:N) | -> locations (N:1, via location_id, ajout migration 099)
TRIGGERS: On UPDATE -> updated_at auto-mis a jour.
RLS: SELECT = tout authenticated | INSERT/UPDATE/DELETE = admin ou super_admin uniquement.
';

COMMENT ON COLUMN buildings.name IS 'Nom commercial de l''immeuble (ex: Le Citadin, Le Cardinal). Unique. Mappe a un property_building via la table locations.';
COMMENT ON COLUMN buildings.location_id IS 'FK vers locations. Lie ce building de menage a sa geolocalisation. Backfill migration 100 avec mapping manuel (ex: Le Cardinal -> 254-258_Cardinal-Begin-E).';

-- =============================================================================
-- SECTION 2: studios
-- =============================================================================

COMMENT ON TABLE studios IS '
ROLE: Unite nettoyable dans un building de menage. Chaque studio a un QR code physique colle sur place, scanne par l''employe pour demarrer/terminer une session de menage.
REGLES: Un studio peut etre de type unit (logement), common_area (aires communes) ou conciergerie. Le QR code est unique globalement. La paire (building_id, studio_number) est unique.
RELATIONS: -> buildings (N:1) | <- cleaning_sessions (1:N)
TRIGGERS: On UPDATE -> updated_at auto-mis a jour.
RLS: SELECT = tout authenticated | INSERT/UPDATE/DELETE = admin ou super_admin uniquement.
';

COMMENT ON COLUMN studios.qr_code IS 'Code aleatoire imprime sur le QR physique. Scanne via l''app mobile pour identifier le studio. Unique globalement.';
COMMENT ON COLUMN studios.studio_number IS 'Numero du studio affiché (ex: 201, Aires communes, Conciergerie). Unique par building.';
COMMENT ON COLUMN studios.building_id IS 'FK vers buildings. Immeuble auquel appartient ce studio.';
COMMENT ON COLUMN studios.studio_type IS 'Type de studio. Values: unit = logement a nettoyer (seuil flag 5 min) | common_area = aires communes (seuil flag 2 min) | conciergerie = bureau de conciergerie (seuil flag 2 min).';
COMMENT ON COLUMN studios.is_active IS 'false = studio desactive, scan_in refuse avec erreur STUDIO_INACTIVE.';

-- =============================================================================
-- SECTION 3: cleaning_sessions (Level C — detail maximal)
-- =============================================================================

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

-- =============================================================================
-- SECTION 4: property_buildings (systeme immobilier Tri-logis)
-- =============================================================================

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

-- =============================================================================
-- SECTION 5: apartments
-- =============================================================================

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

-- =============================================================================
-- SECTION 6: maintenance_sessions
-- =============================================================================

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
