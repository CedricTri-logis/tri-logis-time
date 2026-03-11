-- Allow supervisors to view their subordinates' day_approvals
CREATE POLICY "supervisor_view_subordinate_day_approvals"
  ON public.day_approvals
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM employee_supervisors es
      WHERE es.manager_id = auth.uid()
        AND es.employee_id = day_approvals.employee_id
        AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
    )
  );
