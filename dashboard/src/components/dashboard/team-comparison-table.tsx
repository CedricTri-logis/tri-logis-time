'use client';

import { useState, useCallback } from 'react';
import { ArrowUpDown, Users } from 'lucide-react';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Skeleton } from '@/components/ui/skeleton';
import type { TeamSummary } from '@/types/dashboard';
import { formatHours } from '@/types/dashboard';

interface TeamComparisonTableProps {
  data?: TeamSummary[];
  isLoading?: boolean;
}

type SortField = 'manager_name' | 'team_size' | 'total_hours' | 'total_shifts' | 'avg_hours_per_employee';
type SortDirection = 'asc' | 'desc';

interface SortableHeaderProps {
  field: SortField;
  currentSortField: SortField;
  children: React.ReactNode;
  onSort: (field: SortField) => void;
}

function SortableHeader({ field, currentSortField, children, onSort }: SortableHeaderProps) {
  return (
    <Button
      variant="ghost"
      size="sm"
      onClick={() => onSort(field)}
      className={`-ml-3 h-8 gap-1 text-xs font-medium ${
        currentSortField === field ? 'text-slate-900' : 'text-slate-600'
      }`}
    >
      {children}
      <ArrowUpDown className="h-3.5 w-3.5" />
    </Button>
  );
}

export function TeamComparisonTable({ data, isLoading }: TeamComparisonTableProps) {
  const [sortField, setSortField] = useState<SortField>('total_hours');
  const [sortDirection, setSortDirection] = useState<SortDirection>('desc');

  const handleSort = useCallback((field: SortField) => {
    if (sortField === field) {
      setSortDirection(sortDirection === 'asc' ? 'desc' : 'asc');
    } else {
      setSortField(field);
      setSortDirection('desc');
    }
  }, [sortField, sortDirection]);

  if (isLoading) {
    return <TeamComparisonTableSkeleton />;
  }

  if (!data || data.length === 0) {
    return null; // Empty state handled in parent
  }

  const sortedData = [...data].sort((a, b) => {
    const aValue = a[sortField];
    const bValue = b[sortField];

    if (typeof aValue === 'string' && typeof bValue === 'string') {
      return sortDirection === 'asc'
        ? aValue.localeCompare(bValue)
        : bValue.localeCompare(aValue);
    }

    return sortDirection === 'asc'
      ? (aValue as number) - (bValue as number)
      : (bValue as number) - (aValue as number);
  });

  return (
    <div className="rounded-lg border border-slate-200 bg-white">
      <Table>
        <TableHeader>
          <TableRow className="bg-slate-50">
            <TableHead className="w-[250px]">
              <SortableHeader field="manager_name" currentSortField={sortField} onSort={handleSort}>
                Gestionnaire
              </SortableHeader>
            </TableHead>
            <TableHead>
              <SortableHeader field="team_size" currentSortField={sortField} onSort={handleSort}>
                Taille d&apos;&eacute;quipe
              </SortableHeader>
            </TableHead>
            <TableHead>
              <SortableHeader field="total_hours" currentSortField={sortField} onSort={handleSort}>
                Heures totales
              </SortableHeader>
            </TableHead>
            <TableHead>
              <SortableHeader field="total_shifts" currentSortField={sortField} onSort={handleSort}>
                Quarts
              </SortableHeader>
            </TableHead>
            <TableHead>
              <SortableHeader field="avg_hours_per_employee" currentSortField={sortField} onSort={handleSort}>
                Moy. heures/employ&eacute;
              </SortableHeader>
            </TableHead>
            <TableHead className="text-right">Statut</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {sortedData.map((team) => (
            <TableRow key={team.manager_id} className="hover:bg-slate-50">
              <TableCell>
                <div className="flex items-center gap-3">
                  <div className="flex h-9 w-9 items-center justify-center rounded-full bg-slate-100">
                    <Users className="h-4 w-4 text-slate-600" />
                  </div>
                  <div>
                    <p className="font-medium text-slate-900">{team.manager_name}</p>
                    <p className="text-xs text-slate-500">{team.manager_email}</p>
                  </div>
                </div>
              </TableCell>
              <TableCell>
                <span className="font-medium text-slate-900">{team.team_size}</span>
                <span className="text-slate-500"> employ&eacute;s</span>
              </TableCell>
              <TableCell>
                <span className="font-medium text-slate-900">
                  {formatHours(team.total_hours)}h
                </span>
              </TableCell>
              <TableCell>
                <span className="font-medium text-slate-900">{team.total_shifts}</span>
              </TableCell>
              <TableCell>
                <span className="font-medium text-slate-900">
                  {formatHours(team.avg_hours_per_employee)}h
                </span>
              </TableCell>
              <TableCell className="text-right">
                <div className="flex items-center justify-end gap-2">
                  {team.active_employees > 0 ? (
                    <Badge variant="default" className="bg-green-100 text-green-700 hover:bg-green-100">
                      {team.active_employees} actif(s)
                    </Badge>
                  ) : (
                    <Badge variant="secondary">Inactif</Badge>
                  )}
                </div>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  );
}

function TeamComparisonTableSkeleton() {
  return (
    <div className="rounded-lg border border-slate-200 bg-white">
      <Table>
        <TableHeader>
          <TableRow className="bg-slate-50">
            <TableHead className="w-[250px]">Gestionnaire</TableHead>
            <TableHead>Taille d&apos;&eacute;quipe</TableHead>
            <TableHead>Heures totales</TableHead>
            <TableHead>Quarts</TableHead>
            <TableHead>Moy. heures/employ&eacute;</TableHead>
            <TableHead className="text-right">Statut</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {Array.from({ length: 5 }).map((_, i) => (
            <TableRow key={i}>
              <TableCell>
                <div className="flex items-center gap-3">
                  <Skeleton className="h-9 w-9 rounded-full" />
                  <div>
                    <Skeleton className="h-4 w-24 mb-1" />
                    <Skeleton className="h-3 w-32" />
                  </div>
                </div>
              </TableCell>
              <TableCell>
                <Skeleton className="h-4 w-20" />
              </TableCell>
              <TableCell>
                <Skeleton className="h-4 w-16" />
              </TableCell>
              <TableCell>
                <Skeleton className="h-4 w-12" />
              </TableCell>
              <TableCell>
                <Skeleton className="h-4 w-16" />
              </TableCell>
              <TableCell className="text-right">
                <Skeleton className="h-6 w-16 ml-auto" />
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  );
}
