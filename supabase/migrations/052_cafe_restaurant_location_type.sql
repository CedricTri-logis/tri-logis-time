-- Add cafe_restaurant to location_type enum
ALTER TYPE location_type ADD VALUE IF NOT EXISTS 'cafe_restaurant';
