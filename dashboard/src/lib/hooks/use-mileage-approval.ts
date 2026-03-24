'use client';

import { useState, useEffect, useCallback, useMemo } from 'react';
import type { PayPeriod } from '@/types/payroll';
import type {
  MileageApprovalSummaryRow,
  MileageApprovalDetail,
  MileageTripDetail,
} from '@/types/mileage';
import {
  getMileageApprovalSummary,
  getMileageApprovalDetail,
  prefillMileageDefaults,
} from '@/lib/api/mileage-approval';

export function useMileageApprovalSummary(period: PayPeriod) {
  const [employees, setEmployees] = useState<MileageApprovalSummaryRow[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchData = useCallback(async () => {
    setIsLoading(true);
    setError(null);
    try {
      const data = await getMileageApprovalSummary(period.start, period.end);
      setEmployees(data);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to load mileage summary');
    } finally {
      setIsLoading(false);
    }
  }, [period.start, period.end]);

  useEffect(() => { fetchData(); }, [fetchData]);

  const teamTotals = useMemo(() => ({
    totalKm: employees.reduce((s, e) => s + e.reimbursable_km, 0),
    totalCompanyKm: employees.reduce((s, e) => s + e.company_km, 0),
    totalAmount: employees.reduce((s, e) => s + (e.approved_amount ?? e.estimated_amount), 0),
    totalNeedsReview: employees.reduce((s, e) => s + e.needs_review_count, 0),
  }), [employees]);

  return { employees, teamTotals, isLoading, error, refetch: fetchData };
}

export function useMileageApprovalDetail(
  employeeId: string | null,
  period: PayPeriod
) {
  const [detail, setDetail] = useState<MileageApprovalDetail | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fetchData = useCallback(async () => {
    if (!employeeId) {
      setDetail(null);
      return;
    }
    setIsLoading(true);
    setError(null);
    try {
      // Prefill defaults first, then fetch detail
      await prefillMileageDefaults(employeeId, period.start, period.end);
      const data = await getMileageApprovalDetail(employeeId, period.start, period.end);
      setDetail(data);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to load mileage detail');
    } finally {
      setIsLoading(false);
    }
  }, [employeeId, period.start, period.end]);

  useEffect(() => { fetchData(); }, [fetchData]);

  // Group trips by day
  const tripsByDay = useMemo(() => {
    if (!detail) return new Map<string, MileageTripDetail[]>();
    const map = new Map<string, MileageTripDetail[]>();
    for (const trip of detail.trips) {
      const existing = map.get(trip.trip_date) ?? [];
      existing.push(trip);
      map.set(trip.trip_date, existing);
    }
    return map;
  }, [detail]);

  return { detail, tripsByDay, isLoading, error, refetch: fetchData };
}
