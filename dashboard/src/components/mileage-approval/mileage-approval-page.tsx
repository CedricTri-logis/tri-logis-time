'use client';

import { useState } from 'react';
import { format } from 'date-fns';
import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/ui/tabs';
import { PayrollPeriodSelector } from '@/components/payroll/payroll-period-selector';
import { useMileageApprovalSummary } from '@/lib/hooks/use-mileage-approval';
import { MileageEmployeeList } from './mileage-employee-list';
import { MileageEmployeeDetail } from './mileage-employee-detail';
import { VehiclePeriodsTab } from '@/components/mileage/vehicle-periods-tab';
import { getLastCompletedPeriod } from '@/lib/utils/pay-periods';
import type { PayPeriod } from '@/types/payroll';
import { Loader2, AlertTriangle } from 'lucide-react';

export function MileageApprovalPage() {
  const todayStr = format(new Date(), 'yyyy-MM-dd');
  const [activeTab, setActiveTab] = useState('approval');
  const [period, setPeriod] = useState<PayPeriod>(getLastCompletedPeriod(todayStr));
  const [selectedEmployeeId, setSelectedEmployeeId] = useState<string | null>(null);
  const { employees, teamTotals, isLoading, error, refetch } = useMileageApprovalSummary(period);

  const selectedEmployee = employees.find(e => e.employee_id === selectedEmployeeId);

  return (
    <div className="flex flex-col h-[calc(100vh-64px)]">
      {/* Header */}
      <div className="flex items-center justify-between px-6 py-4 border-b">
        <div className="flex items-center gap-4">
          <h1 className="text-lg font-semibold">Approbation kilométrage</h1>
          <Tabs value={activeTab} onValueChange={setActiveTab}>
            <TabsList>
              <TabsTrigger value="approval">Approbation</TabsTrigger>
              <TabsTrigger value="vehicles">Véhicules</TabsTrigger>
            </TabsList>
          </Tabs>
        </div>
        {activeTab === 'approval' && (
          <PayrollPeriodSelector
            period={period}
            onPeriodChange={setPeriod}
            todayStr={todayStr}
          />
        )}
      </div>

      {/* Content */}
      {activeTab === 'approval' ? (
        isLoading ? (
          <div className="flex items-center justify-center flex-1">
            <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
          </div>
        ) : error ? (
          <div className="flex items-center justify-center flex-1">
            <div className="text-red-600 flex items-center gap-2">
              <AlertTriangle className="h-4 w-4" />
              {error}
            </div>
          </div>
        ) : employees.length === 0 ? (
          <div className="flex items-center justify-center flex-1 text-muted-foreground">
            Aucun trajet en véhicule pour cette période
          </div>
        ) : (
          <div className="flex flex-1 overflow-hidden">
            {/* Left panel: employee list (40%) */}
            <div className="w-[40%] border-r overflow-hidden">
              <MileageEmployeeList
                employees={employees}
                selectedId={selectedEmployeeId}
                onSelect={setSelectedEmployeeId}
                teamTotals={teamTotals}
              />
            </div>

            {/* Right panel: employee detail (60%) */}
            <div className="w-[60%] overflow-hidden">
              {selectedEmployeeId && selectedEmployee ? (
                <MileageEmployeeDetail
                  employeeId={selectedEmployeeId}
                  employeeName={selectedEmployee.employee_name}
                  period={period}
                  onChanged={refetch}
                />
              ) : (
                <div className="flex items-center justify-center h-full text-muted-foreground">
                  Sélectionnez un employé pour voir ses trajets
                </div>
              )}
            </div>
          </div>
        )
      ) : (
        <div className="flex-1 overflow-auto p-6">
          <VehiclePeriodsTab />
        </div>
      )}
    </div>
  );
}
