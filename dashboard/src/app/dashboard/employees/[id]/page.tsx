'use client';

import { useState, useCallback, useEffect } from 'react';
import { useParams } from 'next/navigation';
import { useOne } from '@refinedev/core';
import { ArrowLeft, User, Shield, AlertTriangle, History, UserCheck } from 'lucide-react';
import Link from 'next/link';
import { toast } from 'sonner';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Skeleton } from '@/components/ui/skeleton';
import { EmployeeForm } from '@/components/dashboard/employees/employee-form';
import { StatusBadge, RoleBadge } from '@/components/dashboard/employees/status-badge';
import { RoleSelector } from '@/components/dashboard/employees/role-selector';
import { StatusSelector } from '@/components/dashboard/employees/status-selector';
import { SupervisorAssignment } from '@/components/dashboard/employees/supervisor-assignment';
import { DeactivationWarningDialog } from '@/components/dashboard/employees/deactivation-warning-dialog';
import { supabaseClient } from '@/lib/supabase/client';
import type { EmployeeDetail, UpdateEmployeeResponse, UpdateStatusResponse } from '@/types/employee';
import type { EmployeeEditExtendedInput, EmployeeStatusType } from '@/lib/validations/employee';

export default function EmployeeDetailPage() {
  const params = useParams();
  const employeeId = params.id as string;

  const [isSubmitting, setIsSubmitting] = useState(false);
  const [currentUser, setCurrentUser] = useState<{ id: string; role: string } | null>(null);
  const [pendingStatus, setPendingStatus] = useState<EmployeeStatusType | null>(null);
  const [showDeactivationWarning, setShowDeactivationWarning] = useState(false);

  // Fetch current user info
  useEffect(() => {
    const fetchCurrentUser = async () => {
      const { data: { user } } = await supabaseClient.auth.getUser();
      if (user) {
        const { data: profile } = await supabaseClient
          .from('employee_profiles')
          .select('id, role')
          .eq('id', user.id)
          .single();
        if (profile) {
          setCurrentUser(profile);
        }
      }
    };
    fetchCurrentUser();
  }, []);

  // Fetch employee details
  const { query, result: employee } = useOne<EmployeeDetail>({
    resource: 'employees',
    id: employeeId,
    meta: {
      rpc: 'get_employee_detail',
      rpcParams: { p_employee_id: employeeId },
    },
  });

  const isLoading = query.isLoading;
  const isError = query.isError;
  const refetch = query.refetch;

  // Determine edit permissions
  const isSuperAdmin = currentUser?.role === 'super_admin';
  const isTargetSuperAdmin = employee?.role === 'super_admin';
  const canEdit = isSuperAdmin || !isTargetSuperAdmin;
  const isSelf = currentUser?.id === employeeId;

  // Handle profile update
  const handleProfileUpdate = useCallback(
    async (formData: EmployeeEditExtendedInput) => {
      setIsSubmitting(true);
      try {
        // 1. Update name and employee_id via existing RPC
        const { data: result, error } = await supabaseClient.rpc('update_employee_profile', {
          p_employee_id: employeeId,
          p_full_name: formData.full_name,
          p_employee_id_value: formData.employee_id,
        });

        if (error) throw error;

        const response = result as UpdateEmployeeResponse;
        if (!response.success) {
          toast.error(response.error?.message || 'Failed to update profile');
          return;
        }

        // 2. Update phone if changed (PhoneInput returns E.164 directly)
        const newPhone = formData.phone_number?.trim() || null;
        if (newPhone !== employee?.phone_number && (newPhone || employee?.phone_number)) {
          const { data: phoneResult, error: phoneError } = await supabaseClient.rpc('admin_update_phone_number', {
            p_user_id: employeeId,
            p_phone: newPhone,
          });
          if (phoneError) throw phoneError;
          const phoneResponse = phoneResult as { success: boolean; error?: { message: string } };
          if (!phoneResponse.success) {
            toast.error(phoneResponse.error?.message || 'Failed to update phone');
            return;
          }
        }

        // 3. Update email if changed
        if (formData.email && formData.email !== employee?.email) {
          const token = (await supabaseClient.auth.getSession()).data.session?.access_token;
          const res = await fetch('/api/employees/update-email', {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              'Authorization': `Bearer ${token}`,
            },
            body: JSON.stringify({
              employee_id: employeeId,
              email: formData.email,
            }),
          });
          const emailResult = await res.json();
          if (!emailResult.success) {
            toast.error(emailResult.error || 'Failed to update email');
            return;
          }
        }

        toast.success('Profile updated successfully');
        refetch();
      } catch (err) {
        console.error('Update error:', err);
        toast.error('Failed to update profile');
      } finally {
        setIsSubmitting(false);
      }
    },
    [employeeId, employee?.phone_number, employee?.email, refetch]
  );

  // Handle status change
  const handleStatusChange = useCallback(
    async (newStatus: EmployeeStatusType, force = false) => {
      if (newStatus === employee?.status) return;

      // Check for active shift when deactivating
      if ((newStatus === 'inactive' || newStatus === 'suspended') && employee?.has_active_shift && !force) {
        setPendingStatus(newStatus);
        setShowDeactivationWarning(true);
        return;
      }

      setIsSubmitting(true);
      try {
        const { data: result, error } = await supabaseClient.rpc('update_employee_status', {
          p_employee_id: employeeId,
          p_new_status: newStatus,
          p_force: force,
        });

        if (error) throw error;

        const response = result as UpdateStatusResponse;
        if (!response.success) {
          if (response.requires_confirmation) {
            setPendingStatus(newStatus);
            setShowDeactivationWarning(true);
            return;
          }
          toast.error(response.error?.message || 'Failed to update status');
          return;
        }

        toast.success('Status updated successfully');
        refetch();
      } catch (err) {
        console.error('Status update error:', err);
        toast.error('Failed to update status');
      } finally {
        setIsSubmitting(false);
        setShowDeactivationWarning(false);
        setPendingStatus(null);
      }
    },
    [employeeId, employee?.status, employee?.has_active_shift, refetch]
  );

  // Handle role change
  const handleRoleChange = useCallback(
    async (newRole: string) => {
      if (newRole === employee?.role) return;

      setIsSubmitting(true);
      try {
        const { error } = await supabaseClient.rpc('update_user_role', {
          p_user_id: employeeId,
          p_new_role: newRole,
        });

        if (error) throw error;

        toast.success('Role updated successfully');
        refetch();
      } catch (err: unknown) {
        console.error('Role update error:', err);
        const errorMessage = err instanceof Error ? err.message : 'Failed to update role';
        toast.error(errorMessage);
      } finally {
        setIsSubmitting(false);
      }
    },
    [employeeId, employee?.role, refetch]
  );

  // Handle deactivation confirmation
  const handleConfirmDeactivation = useCallback(() => {
    if (pendingStatus) {
      handleStatusChange(pendingStatus, true);
    }
  }, [pendingStatus, handleStatusChange]);

  if (isLoading) {
    return <EmployeeDetailSkeleton />;
  }

  if (isError || !employee) {
    return (
      <div className="space-y-6">
        <div className="flex items-center gap-4">
          <Button variant="ghost" size="sm" asChild>
            <Link href="/dashboard/employees">
              <ArrowLeft className="mr-2 h-4 w-4" />
              Back to Employees
            </Link>
          </Button>
        </div>
        <Card className="border-red-200 bg-red-50">
          <CardContent className="flex items-center justify-center py-8">
            <p className="text-red-600">
              Employee not found or you do not have permission to view this profile.
            </p>
          </CardContent>
        </Card>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-4">
          <Button variant="ghost" size="sm" asChild>
            <Link href="/dashboard/employees">
              <ArrowLeft className="mr-2 h-4 w-4" />
              Back
            </Link>
          </Button>
          <div className="flex items-center gap-3">
            <div className="rounded-full bg-slate-100 p-2">
              <User className="h-6 w-6 text-slate-600" />
            </div>
            <div>
              <h1 className="text-2xl font-semibold text-slate-900">
                {employee.full_name || employee.email}
              </h1>
              <p className="text-sm text-slate-500">{employee.email}</p>
            </div>
          </div>
        </div>
        <div className="flex items-center gap-2">
          <RoleBadge role={employee.role} />
          <StatusBadge status={employee.status} />
        </div>
      </div>

      {/* Protected User Warning */}
      {isTargetSuperAdmin && !isSuperAdmin && (
        <Card className="border-amber-200 bg-amber-50">
          <CardContent className="flex items-center gap-3 py-4">
            <Shield className="h-5 w-5 text-amber-600" />
            <p className="text-sm text-amber-800">
              This is a protected super admin account. You can view but not edit this profile.
            </p>
          </CardContent>
        </Card>
      )}

      <div className="grid gap-6 lg:grid-cols-2">
        {/* Profile Information */}
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <User className="h-5 w-5" />
              Profile Information
            </CardTitle>
            <CardDescription>
              Update the employee name and identifier.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <EmployeeForm
              defaultValues={{
                full_name: employee.full_name,
                employee_id: employee.employee_id,
                email: employee.email,
                phone_number: employee.phone_number,
              }}
              onSubmit={handleProfileUpdate}
              isSubmitting={isSubmitting}
              isDisabled={!canEdit}
              showEmailWarning={true}
            />
          </CardContent>
        </Card>

        {/* Role Management */}
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <Shield className="h-5 w-5" />
              Role & Permissions
            </CardTitle>
            <CardDescription>
              Manage the employee role and access level.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <RoleSelector
              currentRole={employee.role}
              onRoleChange={handleRoleChange}
              isDisabled={!canEdit || isSelf}
              callerIsSuperAdmin={isSuperAdmin}
            />
            {isSelf && canEdit && (
              <p className="mt-2 text-sm text-slate-500">
                You cannot change your own role.
              </p>
            )}
          </CardContent>
        </Card>

        {/* Status Management */}
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <AlertTriangle className="h-5 w-5" />
              Account Status
            </CardTitle>
            <CardDescription>
              Activate, deactivate, or suspend this account.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <StatusSelector
              currentStatus={employee.status}
              onStatusChange={handleStatusChange}
              isDisabled={!canEdit || isSelf}
              hasActiveShift={employee.has_active_shift}
            />
            {isSelf && canEdit && (
              <p className="mt-2 text-sm text-slate-500">
                You cannot change your own status.
              </p>
            )}
            {employee.status !== 'active' && (
              <p className="mt-4 text-sm text-slate-600">
                Note: Reactivating this employee will not automatically restore their previous supervisor assignment.
              </p>
            )}
          </CardContent>
        </Card>

        {/* Supervisor Assignment */}
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <UserCheck className="h-5 w-5" />
              Supervisor Assignment
            </CardTitle>
            <CardDescription>
              Assign or change this employee supervisor.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <SupervisorAssignment
              employeeId={employeeId}
              currentSupervisor={employee.current_supervisor}
              supervisionHistory={employee.supervision_history}
              onAssignmentChange={refetch}
              isDisabled={!canEdit}
            />
          </CardContent>
        </Card>
      </div>

      {/* Account Information */}
      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <History className="h-5 w-5" />
            Account Information
          </CardTitle>
        </CardHeader>
        <CardContent>
          <dl className="grid gap-4 sm:grid-cols-3">
            <div>
              <dt className="text-sm font-medium text-slate-500">Created</dt>
              <dd className="text-sm text-slate-900">
                {new Date(employee.created_at).toLocaleDateString('en-US', {
                  year: 'numeric',
                  month: 'long',
                  day: 'numeric',
                })}
              </dd>
            </div>
            <div>
              <dt className="text-sm font-medium text-slate-500">Last Updated</dt>
              <dd className="text-sm text-slate-900">
                {new Date(employee.updated_at).toLocaleDateString('en-US', {
                  year: 'numeric',
                  month: 'long',
                  day: 'numeric',
                })}
              </dd>
            </div>
            <div>
              <dt className="text-sm font-medium text-slate-500">Privacy Consent</dt>
              <dd className="text-sm text-slate-900">
                {employee.privacy_consent_at
                  ? new Date(employee.privacy_consent_at).toLocaleDateString('en-US', {
                      year: 'numeric',
                      month: 'long',
                      day: 'numeric',
                    })
                  : 'Not provided'}
              </dd>
            </div>
          </dl>
        </CardContent>
      </Card>

      {/* Deactivation Warning Dialog */}
      <DeactivationWarningDialog
        isOpen={showDeactivationWarning}
        onClose={() => {
          setShowDeactivationWarning(false);
          setPendingStatus(null);
        }}
        onConfirm={handleConfirmDeactivation}
        isSubmitting={isSubmitting}
      />
    </div>
  );
}

function EmployeeDetailSkeleton() {
  return (
    <div className="space-y-6">
      <div className="flex items-center gap-4">
        <Skeleton className="h-9 w-24" />
        <div className="flex items-center gap-3">
          <Skeleton className="h-10 w-10 rounded-full" />
          <div>
            <Skeleton className="h-7 w-48" />
            <Skeleton className="mt-1 h-4 w-36" />
          </div>
        </div>
      </div>
      <div className="grid gap-6 lg:grid-cols-2">
        {Array.from({ length: 4 }).map((_, i) => (
          <Card key={i}>
            <CardHeader>
              <Skeleton className="h-6 w-40" />
              <Skeleton className="h-4 w-64" />
            </CardHeader>
            <CardContent>
              <div className="space-y-4">
                <Skeleton className="h-10 w-full" />
                <Skeleton className="h-10 w-full" />
              </div>
            </CardContent>
          </Card>
        ))}
      </div>
    </div>
  );
}
