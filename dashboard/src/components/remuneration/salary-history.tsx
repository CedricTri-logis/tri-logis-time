'use client';

import { useState, useEffect } from 'react';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { getEmployeeSalaryHistory } from '@/lib/api/remuneration';
import type { EmployeeAnnualSalaryWithCreator } from '@/types/remuneration';

interface SalaryHistoryProps {
  employeeId: string;
}

export function SalaryHistory({ employeeId }: SalaryHistoryProps) {
  const [history, setHistory] = useState<EmployeeAnnualSalaryWithCreator[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    setLoading(true);
    getEmployeeSalaryHistory(employeeId)
      .then(setHistory)
      .finally(() => setLoading(false));
  }, [employeeId]);

  if (loading) {
    return <div className="text-sm text-muted-foreground">Chargement...</div>;
  }

  if (history.length === 0) {
    return (
      <div className="text-sm text-muted-foreground">
        Aucun historique de salaire pour cet employé.
      </div>
    );
  }

  return (
    <div>
      <h4 className="text-sm font-medium mb-2">Historique des salaires</h4>
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Salaire ($/an)</TableHead>
            <TableHead>Aux 2 sem.</TableHead>
            <TableHead>Du</TableHead>
            <TableHead>Au</TableHead>
            <TableHead>Créé par</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {history.map((entry) => (
            <TableRow key={entry.id}>
              <TableCell className="font-mono">
                {entry.salary.toLocaleString('fr-CA')} $
              </TableCell>
              <TableCell className="font-mono text-muted-foreground">
                {(entry.salary / 26).toFixed(2)} $
              </TableCell>
              <TableCell>{entry.effective_from}</TableCell>
              <TableCell>
                {entry.effective_to ?? (
                  <span className="text-green-600 font-medium">En cours</span>
                )}
              </TableCell>
              <TableCell className="text-muted-foreground">
                {entry.creator_name ?? '—'}
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  );
}
