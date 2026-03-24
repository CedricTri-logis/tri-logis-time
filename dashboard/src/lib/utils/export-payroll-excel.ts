import * as XLSX from 'xlsx';
import type { PayrollCategoryGroup, PayPeriod } from '@/types/payroll';
import { formatMinutesAsHours } from './pay-periods';

const CATEGORY_LABELS: Record<string, string> = {
  menage: 'Menage',
  maintenance: 'Maintenance',
  renovation: 'Renovation',
  admin: 'Administration',
  'Non categorise': 'Non categorise',
};

export function exportPayrollToExcel(
  categoryGroups: PayrollCategoryGroup[],
  period: PayPeriod
) {
  const wb = XLSX.utils.book_new();

  // Sheet 1: Sommaire
  const summaryRows: Record<string, unknown>[] = [];
  for (const group of categoryGroups) {
    // Category header
    summaryRows.push({ Employe: `--- ${CATEGORY_LABELS[group.category] || group.category} ---` });

    for (const emp of group.employees) {
      summaryRows.push({
        Employe: emp.full_name,
        Code: emp.employee_id_code,
        Categorie: emp.primary_category || '',
        'Type paie': emp.pay_type === 'annual' ? 'Annuel' : 'Horaire',
        'Heures approuvees': formatMinutesAsHours(emp.total_approved_minutes),
        'Rappel bonus': emp.total_callback_bonus_minutes > 0
          ? formatMinutesAsHours(emp.total_callback_bonus_minutes)
          : '',
        'Pause totale': formatMinutesAsHours(emp.total_break_minutes),
        'Jours sans pause': emp.days_without_break || '',
        '% Sessions': `${emp.work_session_coverage_pct}%`,
        'Prime FDS ($)': emp.total_premium > 0 ? emp.total_premium : '',
        'Montant base ($)': emp.total_base,
        'Total ($)': emp.total_amount,
        'Approbation paie': emp.payroll_status === 'approved' ? 'Approuvee' : 'En attente',
      });
    }

    // Sub-total
    summaryRows.push({
      Employe: `Sous-total ${CATEGORY_LABELS[group.category]}`,
      'Heures approuvees': formatMinutesAsHours(group.totals.approved_minutes),
      'Montant base ($)': group.totals.base_amount,
      'Prime FDS ($)': group.totals.premium_amount,
      'Total ($)': group.totals.total_amount,
    });
    summaryRows.push({}); // Empty row separator
  }

  const ws1 = XLSX.utils.json_to_sheet(summaryRows);
  XLSX.utils.book_append_sheet(wb, ws1, 'Sommaire');

  // Sheet 2: Detail
  const detailRows: Record<string, unknown>[] = [];
  for (const group of categoryGroups) {
    for (const emp of group.employees) {
      for (const day of emp.days) {
        detailRows.push({
          Employe: emp.full_name,
          Code: emp.employee_id_code,
          Date: day.date,
          'Heures approuvees': formatMinutesAsHours(day.approved_minutes),
          'Pause (min)': day.break_minutes,
          'Rappel bonus (h)': day.callback_bonus_minutes > 0
            ? formatMinutesAsHours(day.callback_bonus_minutes)
            : '',
          'Menage (h)': day.cleaning_minutes > 0
            ? formatMinutesAsHours(day.cleaning_minutes)
            : '',
          'Entretien (h)': day.maintenance_minutes > 0
            ? formatMinutesAsHours(day.maintenance_minutes)
            : '',
          'Admin (h)': day.admin_minutes > 0
            ? formatMinutesAsHours(day.admin_minutes)
            : '',
          'Non couvert (h)': day.uncovered_minutes > 0
            ? formatMinutesAsHours(day.uncovered_minutes)
            : '',
          'Prime FDS ($)': day.premium_amount > 0 ? day.premium_amount : '',
          'Montant ($)': day.total_amount,
          'Statut jour': day.day_approval_status === 'approved' ? 'Approuve' : 'En attente',
        });
      }
      detailRows.push({}); // Separator between employees
    }
  }

  const ws2 = XLSX.utils.json_to_sheet(detailRows);
  XLSX.utils.book_append_sheet(wb, ws2, 'Detail');

  // Download
  XLSX.writeFile(wb, `Paie_${period.start}_${period.end}.xlsx`);
}
