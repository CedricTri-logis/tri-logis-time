'use client';

import { useState, useCallback, useMemo, useEffect } from 'react';
import { useList } from '@refinedev/core';
import { Users, UserPlus } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import {
  Pagination,
  PaginationContent,
  PaginationItem,
  PaginationLink,
  PaginationNext,
  PaginationPrevious,
} from '@/components/ui/pagination';
import { EmployeeTable } from '@/components/dashboard/employees/employee-table';
import { EmployeeFilters } from '@/components/dashboard/employees/employee-filters';
import { EmptyState } from '@/components/dashboard/employees/empty-state';
import type { EmployeeListItem } from '@/types/employee';
import { CreateEmployeeDialog } from '@/components/dashboard/employees/create-employee-dialog';
import type { EmployeeRoleType, EmployeeStatusType } from '@/lib/validations/employee';

const PAGE_SIZE = 50;

export default function EmployeesPage() {
  const [search, setSearch] = useState('');
  const [role, setRole] = useState<EmployeeRoleType | ''>('');
  const [status, setStatus] = useState<EmployeeStatusType | ''>('');
  const [currentPage, setCurrentPage] = useState(1);
  const [showCreateDialog, setShowCreateDialog] = useState(false);

  // Debounced search with page reset
  const [debouncedSearch, setDebouncedSearch] = useState('');

  // Debounce search input and reset page
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

  // Handle filter changes with page reset
  const handleRoleChange = useCallback((newRole: EmployeeRoleType | '') => {
    setRole(newRole);
    setCurrentPage(1);
  }, []);

  const handleStatusChange = useCallback((newStatus: EmployeeStatusType | '') => {
    setStatus(newStatus);
    setCurrentPage(1);
  }, []);

  // Build filters for the query
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

  // Fetch employees using the extended data provider
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

  // Generate page numbers for pagination
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

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="rounded-lg bg-slate-100 p-2">
            <Users className="h-6 w-6 text-slate-600" />
          </div>
          <div>
            <h1 className="text-2xl font-semibold text-slate-900">Employees</h1>
            <p className="text-sm text-slate-500">
              {isLoading
                ? 'Loading...'
                : `${totalCount} employee${totalCount !== 1 ? 's' : ''}`}
            </p>
          </div>
        </div>
        <Button onClick={() => setShowCreateDialog(true)}>
          <UserPlus className="mr-2 h-4 w-4" />
          Add Employee
        </Button>
      </div>

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
              Failed to load employees. Please try again.
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
        <EmployeeTable data={employees} isLoading={isLoading} />
      )}

      {/* Pagination */}
      {showPagination && (
        <div className="flex items-center justify-between">
          <p className="text-sm text-slate-500">
            Showing {(currentPage - 1) * PAGE_SIZE + 1} to{' '}
            {Math.min(currentPage * PAGE_SIZE, totalCount)} of {totalCount} employees
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

      <CreateEmployeeDialog
        isOpen={showCreateDialog}
        onClose={() => setShowCreateDialog(false)}
        onCreated={() => query.refetch()}
      />
    </div>
  );
}
