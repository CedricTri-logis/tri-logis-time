-- Add gaz (gas station) to location_type enum
ALTER TYPE location_type ADD VALUE IF NOT EXISTS 'gaz';
