'use client';

// Remuneration page — employee hourly rates & weekend cleaning premium
import { useState, useEffect } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { RatesTable } from '@/components/remuneration/rates-table';
import { PremiumSection } from '@/components/remuneration/premium-section';
import { getEmployeeRatesList, getWeekendPremium } from '@/lib/api/remuneration';
import type { EmployeeRateListItem, WeekendCleaningPremium } from '@/types/remuneration';
import type { CompensationFilter } from '@/components/remuneration/rates-table';

export default function RemunerationPage() {
  const [employees, setEmployees] = useState<EmployeeRateListItem[]>([]);
  const [premium, setPremium] = useState<WeekendCleaningPremium | null>(null);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [filter, setFilter] = useState<CompensationFilter>('all');
  const [error, setError] = useState<string | null>(null);

  const fetchData = async () => {
    setLoading(true);
    setError(null);
    try {
      const [empData, premData] = await Promise.all([
        getEmployeeRatesList(),
        getWeekendPremium(),
      ]);
      setEmployees(empData);
      setPremium(premData);
    } catch (e: any) {
      setError(e.message || 'Erreur lors du chargement des données');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { fetchData(); }, []);

  const filtered = employees.filter((emp) => {
    const matchesSearch = !search
      || (emp.full_name?.toLowerCase().includes(search.toLowerCase()))
      || (emp.employee_id_code?.toLowerCase().includes(search.toLowerCase()));
    const matchesFilter =
      filter === 'all' ? true
      : filter === 'with_compensation' ? emp.current_rate !== null
      : filter === 'without_compensation' ? emp.current_rate === null
      : true;
    return matchesSearch && matchesFilter;
  });

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Rémunération</h1>
        <p className="text-muted-foreground">
          Gérer les taux horaires des employés et la prime de fin de semaine.
        </p>
      </div>

      {error && (
        <div className="rounded-md bg-destructive/15 p-3 text-sm text-destructive">
          {error}
        </div>
      )}

      <PremiumSection premium={premium} onUpdate={fetchData} />

      <Card>
        <CardHeader>
          <CardTitle>Taux horaires</CardTitle>
        </CardHeader>
        <CardContent>
          <RatesTable
            employees={filtered}
            loading={loading}
            search={search}
            onSearchChange={setSearch}
            filter={filter}
            onFilterChange={setFilter}
            onUpdate={fetchData}
          />
        </CardContent>
      </Card>
    </div>
  );
}
