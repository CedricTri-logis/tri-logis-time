-- Migration: Employee categories (period-based)
-- Tracks employee job categories: renovation, entretien, menage, admin
-- An employee can have multiple active categories simultaneously

CREATE TABLE employee_categories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
    category TEXT NOT NULL CHECK (category IN ('renovation', 'entretien', 'menage', 'admin')),
    started_at DATE NOT NULL,
    ended_at DATE,  -- NULL = ongoing period
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_employee_categories_employee ON employee_categories(employee_id);
CREATE INDEX idx_employee_categories_active ON employee_categories(employee_id) WHERE ended_at IS NULL;
CREATE INDEX idx_employee_categories_dates ON employee_categories(started_at, ended_at);

-- Prevent exact duplicate periods (same employee + category + start date)
ALTER TABLE employee_categories
  ADD CONSTRAINT no_duplicate_category_period UNIQUE (employee_id, category, started_at);

-- Updated_at trigger (reuse existing function)
CREATE TRIGGER trg_employee_categories_updated_at
    BEFORE UPDATE ON employee_categories
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- RLS
ALTER TABLE employee_categories ENABLE ROW LEVEL SECURITY;

-- Admin/super_admin can do everything
CREATE POLICY "Admins manage employee categories"
    ON employee_categories FOR ALL
    USING (is_admin_or_super_admin(auth.uid()));

-- Employees can view their own categories
CREATE POLICY "Employees view own categories"
    ON employee_categories FOR SELECT
    USING (employee_id = auth.uid());

-- Comments
COMMENT ON TABLE employee_categories IS 'ROLE: Catégories de poste des employés par période | CATEGORIES: renovation, entretien, menage, admin | REGLES: Un employé peut avoir plusieurs catégories actives simultanément (ex: menage + admin). ended_at NULL = période en cours.';
COMMENT ON COLUMN employee_categories.category IS 'ROLE: Type de poste | VALUES: renovation (Rénovation), entretien (Entretien/Maintenance), menage (Ménage), admin (Administration)';
COMMENT ON COLUMN employee_categories.started_at IS 'ROLE: Date de début de la période | FORMAT: DATE';
COMMENT ON COLUMN employee_categories.ended_at IS 'ROLE: Date de fin de la période | NULL = toujours actif';
