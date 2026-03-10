-- Add date validation: ended_at must be >= started_at when set
ALTER TABLE employee_categories
  ADD CONSTRAINT chk_category_dates CHECK (ended_at IS NULL OR ended_at >= started_at);
