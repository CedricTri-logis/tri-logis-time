'use client';

import { useState } from 'react';
import { format, subDays } from 'date-fns';
import { useSupervisedEmployees, useShiftHistory } from '@/lib/hooks/use-historical-gps';
import { ShiftHistoryTable } from '@/components/history/shift-history-table';

export default function HistoryPage() {
  // Default date range: last 7 days
  const today = new Date();
  const [startDate, setStartDate] = useState(format(subDays(today, 7), 'yyyy-MM-dd'));
  const [endDate, setEndDate] = useState(format(today, 'yyyy-MM-dd'));
  const [selectedEmployeeId, setSelectedEmployeeId] = useState<string | null>(null);

  const { employees, isLoading: employeesLoading } = useSupervisedEmployees();

  const { shifts, isLoading: shiftsLoading } = useShiftHistory({
    employeeId: selectedEmployeeId,
    startDate,
    endDate,
  });

  const isLoading = employeesLoading || shiftsLoading;

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-slate-900">GPS History</h1>
        <p className="text-sm text-slate-500 mt-1">
          View historical GPS trails for completed shifts
        </p>
      </div>

      <ShiftHistoryTable
        shifts={shifts}
        employees={employees}
        selectedEmployeeId={selectedEmployeeId}
        onEmployeeChange={setSelectedEmployeeId}
        startDate={startDate}
        endDate={endDate}
        onStartDateChange={setStartDate}
        onEndDateChange={setEndDate}
        isLoading={isLoading}
      />
    </div>
  );
}
