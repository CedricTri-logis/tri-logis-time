'use client';

import { useState, useMemo, Fragment } from 'react';
import {
  useReactTable,
  getCoreRowModel,
  flexRender,
  type ColumnDef,
} from '@tanstack/react-table';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { ChevronDown, ChevronRight, Pencil } from 'lucide-react';
import { RateDialog } from './rate-dialog';
import { RateHistory } from './rate-history';
import type { EmployeeRateListItem } from '@/types/remuneration';

interface RatesTableProps {
  employees: EmployeeRateListItem[];
  loading: boolean;
  search: string;
  onSearchChange: (v: string) => void;
  filter: 'all' | 'with_rate' | 'without_rate';
  onFilterChange: (v: 'all' | 'with_rate' | 'without_rate') => void;
  onUpdate: () => void;
}

export function RatesTable({
  employees,
  loading,
  search,
  onSearchChange,
  filter,
  onFilterChange,
  onUpdate,
}: RatesTableProps) {
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [editingEmployee, setEditingEmployee] = useState<EmployeeRateListItem | null>(null);

  const columns = useMemo<ColumnDef<EmployeeRateListItem>[]>(
    () => [
      {
        id: 'expand',
        header: '',
        cell: ({ row }) => (
          <Button
            variant="ghost"
            size="sm"
            onClick={() =>
              setExpandedId(
                expandedId === row.original.employee_id
                  ? null
                  : row.original.employee_id
              )
            }
          >
            {expandedId === row.original.employee_id ? (
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
        cell: ({ row }) => (
          <span className="font-medium">
            {row.original.full_name || '—'}
          </span>
        ),
      },
      {
        accessorKey: 'employee_id_code',
        header: 'ID employé',
        cell: ({ row }) => (
          <span className="text-muted-foreground">
            {row.original.employee_id_code || '—'}
          </span>
        ),
      },
      {
        accessorKey: 'current_rate',
        header: 'Taux actuel ($/h)',
        cell: ({ row }) =>
          row.original.current_rate !== null ? (
            <span className="font-mono">
              {row.original.current_rate.toFixed(2)} $
            </span>
          ) : (
            <span className="text-muted-foreground italic">Non défini</span>
          ),
      },
      {
        accessorKey: 'effective_from',
        header: 'En vigueur depuis',
        cell: ({ row }) =>
          row.original.effective_from ? (
            <span>{row.original.effective_from}</span>
          ) : (
            <span className="text-muted-foreground">—</span>
          ),
      },
      {
        id: 'actions',
        header: '',
        cell: ({ row }) => (
          <Button
            variant="ghost"
            size="sm"
            onClick={() => setEditingEmployee(row.original)}
          >
            <Pencil className="h-4 w-4 mr-1" />
            Modifier
          </Button>
        ),
      },
    ],
    [expandedId]
  );

  const table = useReactTable({
    data: employees,
    columns,
    getCoreRowModel: getCoreRowModel(),
    getRowId: (row) => row.employee_id,
  });

  return (
    <div className="space-y-4">
      {/* Filters */}
      <div className="flex gap-4">
        <Input
          placeholder="Rechercher par nom..."
          value={search}
          onChange={(e) => onSearchChange(e.target.value)}
          className="max-w-sm"
        />
        <Select value={filter} onValueChange={(v) => onFilterChange(v as any)}>
          <SelectTrigger className="w-[200px]">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Tous les employés</SelectItem>
            <SelectItem value="with_rate">Avec taux</SelectItem>
            <SelectItem value="without_rate">Sans taux</SelectItem>
          </SelectContent>
        </Select>
      </div>

      {/* Table */}
      <div className="rounded-md border">
        <Table>
          <TableHeader>
            {table.getHeaderGroups().map((headerGroup) => (
              <TableRow key={headerGroup.id}>
                {headerGroup.headers.map((header) => (
                  <TableHead key={header.id}>
                    {flexRender(header.column.columnDef.header, header.getContext())}
                  </TableHead>
                ))}
              </TableRow>
            ))}
          </TableHeader>
          <TableBody>
            {loading ? (
              Array.from({ length: 5 }).map((_, i) => (
                <TableRow key={i}>
                  {columns.map((_, j) => (
                    <TableCell key={j}>
                      <div className="h-4 bg-muted rounded animate-pulse" />
                    </TableCell>
                  ))}
                </TableRow>
              ))
            ) : table.getRowModel().rows.length === 0 ? (
              <TableRow>
                <TableCell colSpan={columns.length} className="text-center py-8 text-muted-foreground">
                  Aucun employé trouvé
                </TableCell>
              </TableRow>
            ) : (
              table.getRowModel().rows.map((row) => (
                <Fragment key={row.id}>
                  <TableRow>
                    {row.getVisibleCells().map((cell) => (
                      <TableCell key={cell.id}>
                        {flexRender(cell.column.columnDef.cell, cell.getContext())}
                      </TableCell>
                    ))}
                  </TableRow>
                  {expandedId === row.original.employee_id && (
                    <TableRow>
                      <TableCell colSpan={columns.length} className="bg-muted/50 p-4">
                        <RateHistory employeeId={row.original.employee_id} />
                      </TableCell>
                    </TableRow>
                  )}
                </Fragment>
              ))
            )}
          </TableBody>
        </Table>
      </div>

      {/* Edit Dialog */}
      <RateDialog
        employee={editingEmployee}
        onClose={() => setEditingEmployee(null)}
        onSaved={() => {
          setEditingEmployee(null);
          onUpdate();
        }}
      />
    </div>
  );
}
