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
import { getEmployeeRateHistory } from '@/lib/api/remuneration';
import type { EmployeeHourlyRateWithCreator } from '@/types/remuneration';

interface RateHistoryProps {
  employeeId: string;
}

export function RateHistory({ employeeId }: RateHistoryProps) {
  const [history, setHistory] = useState<EmployeeHourlyRateWithCreator[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    setLoading(true);
    getEmployeeRateHistory(employeeId)
      .then(setHistory)
      .finally(() => setLoading(false));
  }, [employeeId]);

  if (loading) {
    return <div className="text-sm text-muted-foreground">Chargement...</div>;
  }

  if (history.length === 0) {
    return (
      <div className="text-sm text-muted-foreground">
        Aucun historique de taux pour cet employé.
      </div>
    );
  }

  return (
    <div>
      <h4 className="text-sm font-medium mb-2">Historique des taux</h4>
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Taux ($/h)</TableHead>
            <TableHead>Du</TableHead>
            <TableHead>Au</TableHead>
            <TableHead>Créé par</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {history.map((entry) => (
            <TableRow key={entry.id}>
              <TableCell className="font-mono">{entry.rate.toFixed(2)} $</TableCell>
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
