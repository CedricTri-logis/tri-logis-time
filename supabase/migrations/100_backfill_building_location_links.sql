-- Migration 100: Backfill building-location links
-- Links property_buildings and cleaning buildings to their matching locations by name
-- Also deactivates 5 parking property_buildings that have no location match

-- 1. Link property_buildings to locations by exact name match (72 of 77 match)
UPDATE property_buildings pb
SET location_id = l.id
FROM locations l
WHERE l.name = pb.name
  AND l.is_active = true
  AND pb.location_id IS NULL;

-- 2. Link cleaning buildings to locations using known mapping
-- (from Tri-logis.ca short_term.building_studio_mapping)

-- Le Cardinal → 254-258_Cardinal-Begin-E
UPDATE buildings SET location_id = (SELECT id FROM locations WHERE name = '254-258_Cardinal-Begin-E')
WHERE name = 'Le Cardinal' AND location_id IS NULL;

-- Le Central → 22-28_Gamble-O
UPDATE buildings SET location_id = (SELECT id FROM locations WHERE name = '22-28_Gamble-O')
WHERE name = 'Le Central' AND location_id IS NULL;

-- Le Centre-Ville → 14-20_Perreault-E
UPDATE buildings SET location_id = (SELECT id FROM locations WHERE name = '14-20_Perreault-E')
WHERE name = 'Le Centre-Ville' AND location_id IS NULL;

-- Le Chambreur → 110-114_Mgr-Tessier-O
UPDATE buildings SET location_id = (SELECT id FROM locations WHERE name = '110-114_Mgr-Tessier-O')
WHERE name = 'Le Chambreur' AND location_id IS NULL;

-- Le Chic-urbain → 151-159_Principale (the office!)
UPDATE buildings SET location_id = (SELECT id FROM locations WHERE name = '151-159_Principale')
WHERE name = 'Le Chic-urbain' AND location_id IS NULL;

-- Le Cinq Étoiles → 500_Boutour
UPDATE buildings SET location_id = (SELECT id FROM locations WHERE name = '500_Boutour')
WHERE name = 'Le Cinq Étoiles' AND location_id IS NULL;

-- Le Citadin → 45_Perreault-E
UPDATE buildings SET location_id = (SELECT id FROM locations WHERE name = '45_Perreault-E')
WHERE name = 'Le Citadin' AND location_id IS NULL;

-- Le Contemporain → 296-300_Principale
UPDATE buildings SET location_id = (SELECT id FROM locations WHERE name = '296-300_Principale')
WHERE name = 'Le Contemporain' AND location_id IS NULL;

-- Le Convivial → 62-66_Perreault-E
UPDATE buildings SET location_id = (SELECT id FROM locations WHERE name = '62-66_Perreault-E')
WHERE name = 'Le Convivial' AND location_id IS NULL;

-- Le Court-toit → 96_Horne
UPDATE buildings SET location_id = (SELECT id FROM locations WHERE name = '96_Horne')
WHERE name = 'Le Court-toit' AND location_id IS NULL;

-- 3. Mark 151-159_Principale as also an office (Le Chic-urbain is office + building)
UPDATE locations SET is_also_office = true WHERE name = '151-159_Principale';

-- 4. Deactivate 5 parking property_buildings that have no matching location
-- These are parkings, not buildings
UPDATE property_buildings SET is_active = false
WHERE name IN (
  '10_Olivier',
  '100_Mgr-Tessier-O',
  '103-105_Dallaire',
  '21_Lausanne',
  '29_Perreault-E'
);
