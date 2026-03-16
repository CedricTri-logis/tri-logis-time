-- ============================================================
-- Migration: Rename category 'entretien' → 'maintenance'
-- Clearer label to avoid confusion with 'ménage' (entretien ménager)
-- ============================================================

-- 1. Update existing data (if any)
UPDATE employee_categories SET category = 'maintenance' WHERE category = 'entretien';

-- 2. Replace CHECK constraint
ALTER TABLE employee_categories DROP CONSTRAINT employee_categories_category_check;
ALTER TABLE employee_categories ADD CONSTRAINT employee_categories_category_check
  CHECK (category = ANY (ARRAY['renovation'::text, 'maintenance'::text, 'menage'::text, 'admin'::text]));

-- 3. Update table comment
COMMENT ON COLUMN employee_categories.category IS
  'Job category type: renovation, maintenance (formerly entretien), menage, admin.';
