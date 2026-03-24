'use client';

import { Badge } from '@/components/ui/badge';
import { Users, AlertTriangle, Check, CheckCheck } from 'lucide-react';
import type { MileageApprovalSummaryRow } from '@/types/mileage';

interface MileageEmployeeListProps {
  employees: MileageApprovalSummaryRow[];
  selectedId: string | null;
  onSelect: (employeeId: string) => void;
  teamTotals: {
    totalKm: number;
    totalCompanyKm: number;
    totalAmount: number;
    totalNeedsReview: number;
  };
}

export function MileageEmployeeList({
  employees,
  selectedId,
  onSelect,
  teamTotals,
}: MileageEmployeeListProps) {
  // Sort: needs review first, then ready, then approved
  const sorted = [...employees].sort((a, b) => {
    const aStatus = a.mileage_status === 'approved' ? 2 : a.needs_review_count > 0 ? 0 : 1;
    const bStatus = b.mileage_status === 'approved' ? 2 : b.needs_review_count > 0 ? 0 : 1;
    if (aStatus !== bStatus) return aStatus - bStatus;
    return a.employee_name.localeCompare(b.employee_name);
  });

  return (
    <div className="flex flex-col h-full">
      <div className="flex-1 overflow-y-auto">
        <div className="text-xs font-semibold text-muted-foreground uppercase px-4 py-2">
          Employés ({employees.length})
        </div>
        {sorted.map((emp) => {
          const isSelected = emp.employee_id === selectedId;
          const isApproved = emp.mileage_status === 'approved';
          const needsReview = emp.needs_review_count > 0;

          return (
            <div
              key={emp.employee_id}
              onClick={() => onSelect(emp.employee_id)}
              className={`px-4 py-3 cursor-pointer border-l-[3px] transition-colors ${
                isSelected
                  ? 'border-l-blue-500 bg-blue-50/50'
                  : 'border-l-transparent hover:bg-muted/50'
              } ${isApproved ? 'bg-green-50/30' : ''}`}
            >
              <div className="flex justify-between items-center">
                <span className="font-medium text-sm">{emp.employee_name}</span>
                {isApproved ? (
                  <CheckCheck className="h-4 w-4 text-green-600" />
                ) : needsReview ? (
                  <Badge variant="outline" className="text-xs text-yellow-700 border-yellow-300">
                    <AlertTriangle className="h-3 w-3 mr-1" />
                    {emp.needs_review_count}
                  </Badge>
                ) : (
                  <Check className="h-4 w-4 text-green-600" />
                )}
              </div>
              <div className="text-xs text-muted-foreground mt-1">
                {emp.trip_count} trajets · {emp.reimbursable_km.toFixed(0)} km
                {isApproved && emp.approved_amount != null
                  ? ` · ${emp.approved_amount.toFixed(2)} $`
                  : emp.estimated_amount > 0
                  ? ` · ~${emp.estimated_amount.toFixed(2)} $`
                  : ''}
                {emp.is_forfait && (
                  <Badge variant="secondary" className="text-xs ml-1">Forfait</Badge>
                )}
                {emp.carpool_group_count > 0 && (
                  <span className="ml-1 text-yellow-600">
                    <Users className="inline h-3 w-3" /> {emp.carpool_group_count}
                  </span>
                )}
              </div>
            </div>
          );
        })}
      </div>

      {/* Team totals */}
      <div className="border-t bg-muted/30 p-3 text-xs text-center space-y-1">
        <div>
          Total équipe: <strong>{teamTotals.totalKm.toFixed(0)} km</strong>
          {teamTotals.totalAmount > 0 && (
            <> · <strong>{teamTotals.totalAmount.toFixed(2)} $</strong></>
          )}
        </div>
        {teamTotals.totalNeedsReview > 0 && (
          <div className="text-yellow-700">
            {teamTotals.totalNeedsReview} items à revoir
          </div>
        )}
      </div>
    </div>
  );
}
