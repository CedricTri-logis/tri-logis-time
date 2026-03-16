'use client';

import { useState, useMemo, Fragment, useCallback } from 'react';
import Link from 'next/link';
import {
  ColumnDef,
  flexRender,
  getCoreRowModel,
  getExpandedRowModel,
  useReactTable,
  type Row,
} from '@tanstack/react-table';
import { ChevronRight, ChevronDown, AlertTriangle, Loader2, RefreshCw, Check, X } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Skeleton } from '@/components/ui/skeleton';
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from '@/components/ui/table';
import { StatusBadge, RoleBadge } from './status-badge';
import type { EmployeeListItem } from '@/types/employee';
import { getEmployeeExpandDetails, type EmployeeExpandDetails } from '@/lib/api/employee-expand';

const CATEGORY_LABELS: Record<string, string> = {
  renovation: 'Rénovation',
  maintenance: 'Maintenance',
  menage: 'Ménage',
  admin: 'Administration',
};

const CATEGORY_BADGE_CLASSES: Record<string, string> = {
  renovation: 'bg-blue-100 text-blue-700 hover:bg-blue-100',
  maintenance: 'bg-green-100 text-green-700 hover:bg-green-100',
  menage: 'bg-purple-100 text-purple-700 hover:bg-purple-100',
  admin: 'bg-amber-100 text-amber-700 hover:bg-amber-100',
};

interface ExpandState {
  data: EmployeeExpandDetails | null;
  loading: boolean;
  error: string | null;
}

interface EmployeeTableExpandableProps {
  data: EmployeeListItem[];
  isLoading?: boolean;
}

export function EmployeeTableExpandable({ data, isLoading }: EmployeeTableExpandableProps) {
  const [expandedRows, setExpandedRows] = useState<Record<string, boolean>>({});
  const [expandState, setExpandState] = useState<Record<string, ExpandState>>({});

  const toggleRow = useCallback(async (employeeId: string) => {
    const isExpanded = expandedRows[employeeId];
    setExpandedRows((prev) => ({ ...prev, [employeeId]: !isExpanded }));

    // Fetch data if expanding and not already loaded
    if (!isExpanded && !expandState[employeeId]?.data) {
      setExpandState((prev) => ({
        ...prev,
        [employeeId]: { data: null, loading: true, error: null },
      }));
      try {
        const details = await getEmployeeExpandDetails(employeeId);
        setExpandState((prev) => ({
          ...prev,
          [employeeId]: { data: details, loading: false, error: null },
        }));
      } catch (e: any) {
        setExpandState((prev) => ({
          ...prev,
          [employeeId]: { data: null, loading: false, error: e.message || 'Erreur de chargement' },
        }));
      }
    }
  }, [expandedRows, expandState]);

  const retryFetch = useCallback(async (employeeId: string) => {
    setExpandState((prev) => ({
      ...prev,
      [employeeId]: { data: null, loading: true, error: null },
    }));
    try {
      const details = await getEmployeeExpandDetails(employeeId);
      setExpandState((prev) => ({
        ...prev,
        [employeeId]: { data: details, loading: false, error: null },
      }));
    } catch (e: any) {
      setExpandState((prev) => ({
        ...prev,
        [employeeId]: { data: null, loading: false, error: e.message || 'Erreur de chargement' },
      }));
    }
  }, []);

  const columns = useMemo<ColumnDef<EmployeeListItem>[]>(
    () => [
      {
        id: 'expand',
        header: '',
        cell: ({ row }) => (
          <Button
            variant="ghost"
            size="sm"
            className="h-8 w-8 p-0"
            onClick={() => toggleRow(row.original.id)}
          >
            {expandedRows[row.original.id] ? (
              <ChevronDown className="h-4 w-4" />
            ) : (
              <ChevronRight className="h-4 w-4" />
            )}
          </Button>
        ),
        size: 40,
      },
      {
        accessorKey: 'full_name',
        header: 'Nom',
        cell: ({ row }) => {
          const name = row.original.full_name || row.original.email;
          const email = row.original.email;
          return (
            <div className="flex flex-col">
              <span className="font-medium text-slate-900">{name}</span>
              {row.original.full_name && (
                <span className="text-sm text-slate-500">{email}</span>
              )}
            </div>
          );
        },
      },
      {
        id: 'categories',
        header: 'Catégories',
        cell: ({ row }) => {
          const count = row.original.active_category_count;
          if (count === 0) {
            return (
              <span className="flex items-center gap-1 text-amber-600 text-sm">
                <AlertTriangle className="h-3.5 w-3.5" />
                Aucune
              </span>
            );
          }
          return (
            <span className="text-sm text-slate-600">
              {count} active{count > 1 ? 's' : ''}
            </span>
          );
        },
      },
      {
        id: 'remuneration',
        header: 'Rémunération',
        cell: ({ row }) => {
          const rate = row.original.current_hourly_rate;
          if (rate === null) {
            return (
              <span className="flex items-center gap-1 text-amber-600 text-sm">
                <AlertTriangle className="h-3.5 w-3.5" />
                Non défini
              </span>
            );
          }
          return (
            <span className="text-sm font-mono text-slate-600">
              {Number(rate).toFixed(2)} $/h
            </span>
          );
        },
      },
      {
        id: 'weekend_premium',
        header: 'Prime FDS',
        cell: ({ row }) => {
          if (!row.original.has_menage_category) {
            return <span className="text-slate-300">—</span>;
          }
          return row.original.has_weekend_premium ? (
            <Check className="h-4 w-4 text-green-600" />
          ) : (
            <X className="h-4 w-4 text-red-400" />
          );
        },
      },
      {
        id: 'actions',
        header: '',
        cell: ({ row }) => (
          <div className="flex justify-end">
            <Button variant="ghost" size="sm" asChild>
              <Link href={`/dashboard/employees/${row.original.id}`}>
                Voir
                <ChevronRight className="ml-1 h-4 w-4" />
              </Link>
            </Button>
          </div>
        ),
      },
    ],
    [expandedRows, toggleRow]
  );

  const table = useReactTable({
    data,
    columns,
    getCoreRowModel: getCoreRowModel(),
    getRowId: (row) => row.id,
  });

  if (isLoading) {
    return <ExpandableTableSkeleton />;
  }

  return (
    <div className="rounded-md border border-slate-200">
      <Table>
        <TableHeader>
          {table.getHeaderGroups().map((headerGroup) => (
            <TableRow key={headerGroup.id}>
              {headerGroup.headers.map((header) => (
                <TableHead key={header.id}>
                  {header.isPlaceholder
                    ? null
                    : flexRender(header.column.columnDef.header, header.getContext())}
                </TableHead>
              ))}
            </TableRow>
          ))}
        </TableHeader>
        <TableBody>
          {table.getRowModel().rows?.length ? (
            table.getRowModel().rows.map((row) => (
              <Fragment key={row.id}>
                <TableRow className="hover:bg-slate-50">
                  {row.getVisibleCells().map((cell) => (
                    <TableCell key={cell.id}>
                      {flexRender(cell.column.columnDef.cell, cell.getContext())}
                    </TableCell>
                  ))}
                </TableRow>
                {expandedRows[row.original.id] && (
                  <TableRow>
                    <TableCell colSpan={columns.length} className="bg-slate-50/50 p-0">
                      <ExpandedContent
                        state={expandState[row.original.id]}
                        onRetry={() => retryFetch(row.original.id)}
                      />
                    </TableCell>
                  </TableRow>
                )}
              </Fragment>
            ))
          ) : (
            <TableRow>
              <TableCell colSpan={columns.length} className="h-24 text-center">
                Aucun employé trouvé.
              </TableCell>
            </TableRow>
          )}
        </TableBody>
      </Table>
    </div>
  );
}

function ExpandedContent({
  state,
  onRetry,
}: {
  state: ExpandState | undefined;
  onRetry: () => void;
}) {
  if (!state || state.loading) {
    return (
      <div className="flex items-center gap-2 px-6 py-4 text-sm text-slate-500">
        <Loader2 className="h-4 w-4 animate-spin" />
        Chargement des détails...
      </div>
    );
  }

  if (state.error) {
    return (
      <div className="flex items-center gap-3 px-6 py-4 text-sm text-red-600">
        <span>{state.error}</span>
        <Button variant="outline" size="sm" onClick={onRetry}>
          <RefreshCw className="h-3.5 w-3.5 mr-1" />
          Réessayer
        </Button>
      </div>
    );
  }

  const { categories, rates } = state.data!;

  return (
    <div className="grid gap-6 px-6 py-4 sm:grid-cols-2">
      {/* Categories */}
      <div>
        <h4 className="text-sm font-medium text-slate-700 mb-2">Catégories de poste</h4>
        {categories.length === 0 ? (
          <p className="text-sm text-slate-400">Aucune catégorie assignée</p>
        ) : (
          <div className="space-y-1.5">
            {categories.map((cat, i) => (
              <div key={i} className="flex items-center gap-2 text-sm">
                <Badge
                  variant="secondary"
                  className={CATEGORY_BADGE_CLASSES[cat.category] ?? ''}
                >
                  {CATEGORY_LABELS[cat.category] ?? cat.category}
                </Badge>
                <span className={cat.ended_at ? 'text-slate-400' : 'text-slate-600'}>
                  {formatDate(cat.started_at)}
                  {' → '}
                  {cat.ended_at ? (
                    formatDate(cat.ended_at)
                  ) : (
                    <Badge variant="outline" className="text-green-600 border-green-200 text-xs">
                      en cours
                    </Badge>
                  )}
                </span>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Rates */}
      <div>
        <h4 className="text-sm font-medium text-slate-700 mb-2">Historique des taux</h4>
        {rates.length === 0 ? (
          <p className="text-sm text-slate-400">Aucun taux défini</p>
        ) : (
          <div className="space-y-1.5">
            {rates.map((rate, i) => (
              <div key={i} className="flex items-center gap-2 text-sm">
                <span className="font-mono font-medium">{rate.rate.toFixed(2)} $/h</span>
                <span className={rate.effective_to ? 'text-slate-400' : 'text-slate-600'}>
                  {rate.effective_from}
                  {' → '}
                  {rate.effective_to ? (
                    rate.effective_to
                  ) : (
                    <Badge variant="outline" className="text-green-600 border-green-200 text-xs">
                      en cours
                    </Badge>
                  )}
                </span>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function formatDate(dateStr: string): string {
  return new Date(dateStr + 'T00:00:00').toLocaleDateString('fr-CA', {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
  });
}

function ExpandableTableSkeleton() {
  return (
    <div className="rounded-md border border-slate-200">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead className="w-10"></TableHead>
            <TableHead>Nom</TableHead>
            <TableHead>Catégories</TableHead>
            <TableHead>Rémunération</TableHead>
            <TableHead></TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {Array.from({ length: 5 }).map((_, i) => (
            <TableRow key={i}>
              <TableCell><Skeleton className="h-4 w-4" /></TableCell>
              <TableCell>
                <div className="space-y-2">
                  <Skeleton className="h-4 w-32" />
                  <Skeleton className="h-3 w-40" />
                </div>
              </TableCell>
              <TableCell><Skeleton className="h-4 w-16" /></TableCell>
              <TableCell><Skeleton className="h-4 w-20" /></TableCell>
              <TableCell><Skeleton className="h-8 w-16" /></TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  );
}
