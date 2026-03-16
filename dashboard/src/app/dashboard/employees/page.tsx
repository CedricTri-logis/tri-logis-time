'use client';

import { useState, useCallback, useMemo, useEffect } from 'react';
import { useList } from '@refinedev/core';
import { Users, UserPlus } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import {
  Pagination,
  PaginationContent,
  PaginationItem,
  PaginationLink,
  PaginationNext,
  PaginationPrevious,
} from '@/components/ui/pagination';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { EmployeeTableExpandable } from '@/components/dashboard/employees/employee-table-expandable';
import { EmployeeFilters } from '@/components/dashboard/employees/employee-filters';
import { EmptyState } from '@/components/dashboard/employees/empty-state';
import { RatesTable } from '@/components/remuneration/rates-table';
import { PremiumSection } from '@/components/remuneration/premium-section';
import { getEmployeeRatesList, getWeekendPremium } from '@/lib/api/remuneration';
import type { EmployeeListItem } from '@/types/employee';
import type { EmployeeRateListItem, WeekendCleaningPremium } from '@/types/remuneration';
import { CreateEmployeeDialog } from '@/components/dashboard/employees/create-employee-dialog';
import type { EmployeeRoleType, EmployeeStatusType } from '@/lib/validations/employee';

const PAGE_SIZE = 50;

export default function EmployeesPage() {
  // ── Liste tab state ──
  const [search, setSearch] = useState('');
  const [role, setRole] = useState<EmployeeRoleType | ''>('');
  const [status, setStatus] = useState<EmployeeStatusType | ''>('');
  const [currentPage, setCurrentPage] = useState(1);
  const [showCreateDialog, setShowCreateDialog] = useState(false);
  const [debouncedSearch, setDebouncedSearch] = useState('');

  useEffect(() => {
    const timer = setTimeout(() => {
      if (search !== debouncedSearch) {
        setDebouncedSearch(search);
        setCurrentPage(1);
      }
    }, 300);
    return () => clearTimeout(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [search]);

  const handleRoleChange = useCallback((newRole: EmployeeRoleType | '') => {
    setRole(newRole);
    setCurrentPage(1);
  }, []);

  const handleStatusChange = useCallback((newStatus: EmployeeStatusType | '') => {
    setStatus(newStatus);
    setCurrentPage(1);
  }, []);

  const filters = useMemo(() => {
    const result: Array<{ field: string; operator: 'eq'; value: string }> = [];
    if (debouncedSearch) {
      result.push({ field: 'search', operator: 'eq', value: debouncedSearch });
    }
    if (role) {
      result.push({ field: 'role', operator: 'eq', value: role });
    }
    if (status) {
      result.push({ field: 'status', operator: 'eq', value: status });
    }
    return result;
  }, [debouncedSearch, role, status]);

  const { query, result } = useList<EmployeeListItem>({
    resource: 'employees',
    pagination: {
      currentPage: currentPage,
      pageSize: PAGE_SIZE,
    },
    filters,
    meta: {
      rpc: 'get_employees_paginated',
    },
  });

  const isLoading = query.isLoading;
  const isError = query.isError;
  const employees = result?.data ?? [];
  const totalCount = result?.total ?? 0;
  const totalPages = Math.ceil(totalCount / PAGE_SIZE);

  const handleClearFilters = useCallback(() => {
    setSearch('');
    setRole('');
    setStatus('');
    setCurrentPage(1);
  }, []);

  const handlePageChange = useCallback((page: number) => {
    setCurrentPage(page);
  }, []);

  const pageNumbers = useMemo(() => {
    const pages: number[] = [];
    const maxVisiblePages = 5;
    let start = Math.max(1, currentPage - Math.floor(maxVisiblePages / 2));
    const end = Math.min(totalPages, start + maxVisiblePages - 1);

    if (end - start < maxVisiblePages - 1) {
      start = Math.max(1, end - maxVisiblePages + 1);
    }

    for (let i = start; i <= end; i++) {
      pages.push(i);
    }
    return pages;
  }, [currentPage, totalPages]);

  const showEmptyState = !isLoading && employees.length === 0;
  const showPagination = !isLoading && totalPages > 1;

  // ── Rémunération tab state ──
  const [remEmployees, setRemEmployees] = useState<EmployeeRateListItem[]>([]);
  const [premium, setPremium] = useState<WeekendCleaningPremium | null>(null);
  const [remLoading, setRemLoading] = useState(false);
  const [remSearch, setRemSearch] = useState('');
  const [remFilter, setRemFilter] = useState<'all' | 'with_rate' | 'without_rate'>('all');
  const [remError, setRemError] = useState<string | null>(null);
  const [remLoaded, setRemLoaded] = useState(false);

  const fetchRemunerationData = useCallback(async () => {
    setRemLoading(true);
    setRemError(null);
    try {
      const [empData, premData] = await Promise.all([
        getEmployeeRatesList(),
        getWeekendPremium(),
      ]);
      setRemEmployees(empData);
      setPremium(premData);
      setRemLoaded(true);
    } catch (e: any) {
      setRemError(e.message || 'Erreur lors du chargement');
    } finally {
      setRemLoading(false);
    }
  }, []);

  const filteredRemEmployees = useMemo(() => {
    return remEmployees.filter((emp) => {
      const matchesSearch = !remSearch
        || emp.full_name?.toLowerCase().includes(remSearch.toLowerCase())
        || emp.employee_id_code?.toLowerCase().includes(remSearch.toLowerCase());
      const matchesFilter =
        remFilter === 'all' ? true
        : remFilter === 'with_rate' ? emp.current_rate !== null
        : emp.current_rate === null;
      return matchesSearch && matchesFilter;
    });
  }, [remEmployees, remSearch, remFilter]);

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="rounded-lg bg-slate-100 p-2">
            <Users className="h-6 w-6 text-slate-600" />
          </div>
          <div>
            <h1 className="text-2xl font-semibold text-slate-900">Employés</h1>
            <p className="text-sm text-slate-500">
              {isLoading
                ? 'Chargement...'
                : `${totalCount} employé${totalCount !== 1 ? 's' : ''}`}
            </p>
          </div>
        </div>
        <Button onClick={() => setShowCreateDialog(true)}>
          <UserPlus className="mr-2 h-4 w-4" />
          Ajouter un employé
        </Button>
      </div>

      <Tabs defaultValue="liste" onValueChange={(v) => {
        if (v === 'remuneration' && !remLoaded) fetchRemunerationData();
      }}>
        <TabsList>
          <TabsTrigger value="liste">Liste</TabsTrigger>
          <TabsTrigger value="remuneration">Rémunération</TabsTrigger>
        </TabsList>

        <TabsContent value="liste" className="space-y-6">
          {/* Filters */}
          <Card>
            <CardContent className="pt-6">
              <EmployeeFilters
                search={search}
                role={role}
                status={status}
                onSearchChange={setSearch}
                onRoleChange={handleRoleChange}
                onStatusChange={handleStatusChange}
                onClearFilters={handleClearFilters}
              />
            </CardContent>
          </Card>

          {/* Error State */}
          {isError && (
            <Card className="border-red-200 bg-red-50">
              <CardContent className="flex items-center justify-center py-8">
                <p className="text-red-600">
                  Échec du chargement des employés. Veuillez réessayer.
                </p>
              </CardContent>
            </Card>
          )}

          {/* Employee Table or Empty State */}
          {showEmptyState ? (
            <Card>
              <CardContent>
                <EmptyState
                  search={debouncedSearch}
                  role={role}
                  status={status}
                  onClearFilters={handleClearFilters}
                />
              </CardContent>
            </Card>
          ) : (
            <EmployeeTableExpandable data={employees} isLoading={isLoading} />
          )}

          {/* Pagination */}
          {showPagination && (
            <div className="flex items-center justify-between">
              <p className="text-sm text-slate-500">
                Affichage de {(currentPage - 1) * PAGE_SIZE + 1} à{' '}
                {Math.min(currentPage * PAGE_SIZE, totalCount)} sur {totalCount} employés
              </p>
              <Pagination>
                <PaginationContent>
                  <PaginationItem>
                    <PaginationPrevious
                      href="#"
                      onClick={(e) => {
                        e.preventDefault();
                        if (currentPage > 1) handlePageChange(currentPage - 1);
                      }}
                      className={currentPage <= 1 ? 'pointer-events-none opacity-50' : ''}
                    />
                  </PaginationItem>
                  {pageNumbers.map((page) => (
                    <PaginationItem key={page}>
                      <PaginationLink
                        href="#"
                        onClick={(e) => {
                          e.preventDefault();
                          handlePageChange(page);
                        }}
                        isActive={page === currentPage}
                      >
                        {page}
                      </PaginationLink>
                    </PaginationItem>
                  ))}
                  <PaginationItem>
                    <PaginationNext
                      href="#"
                      onClick={(e) => {
                        e.preventDefault();
                        if (currentPage < totalPages) handlePageChange(currentPage + 1);
                      }}
                      className={currentPage >= totalPages ? 'pointer-events-none opacity-50' : ''}
                    />
                  </PaginationItem>
                </PaginationContent>
              </Pagination>
            </div>
          )}
        </TabsContent>

        <TabsContent value="remuneration" className="space-y-6">
          {remError && (
            <div className="rounded-md bg-destructive/15 p-3 text-sm text-destructive">{remError}</div>
          )}
          <PremiumSection premium={premium} onUpdate={fetchRemunerationData} />
          <Card>
            <CardHeader>
              <CardTitle>Taux horaires</CardTitle>
            </CardHeader>
            <CardContent>
              <RatesTable
                employees={filteredRemEmployees}
                loading={remLoading}
                search={remSearch}
                onSearchChange={setRemSearch}
                filter={remFilter}
                onFilterChange={setRemFilter}
                onUpdate={fetchRemunerationData}
              />
            </CardContent>
          </Card>
        </TabsContent>
      </Tabs>

      <CreateEmployeeDialog
        isOpen={showCreateDialog}
        onClose={() => setShowCreateDialog(false)}
        onCreated={() => query.refetch()}
      />
    </div>
  );
}
