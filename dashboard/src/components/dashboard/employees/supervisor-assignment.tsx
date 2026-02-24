'use client';

import { useState, useCallback, useEffect } from 'react';
import { toast } from 'sonner';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { Button } from '@/components/ui/button';
import { Skeleton } from '@/components/ui/skeleton';
import { UserMinus, History, ChevronDown, ChevronUp } from 'lucide-react';
import { supabaseClient } from '@/lib/supabase/client';
import type { SupervisorInfo, SupervisionHistoryEntry, ManagerListItem, AssignSupervisorResponse, RemoveSupervisorResponse } from '@/types/employee';

interface SupervisorAssignmentProps {
  employeeId: string;
  currentSupervisor: SupervisorInfo | null;
  supervisionHistory: SupervisionHistoryEntry[];
  onAssignmentChange: () => void;
  isDisabled?: boolean;
}

export function SupervisorAssignment({
  employeeId,
  currentSupervisor,
  supervisionHistory,
  onAssignmentChange,
  isDisabled = false,
}: SupervisorAssignmentProps) {
  const [managers, setManagers] = useState<ManagerListItem[]>([]);
  const [isLoadingManagers, setIsLoadingManagers] = useState(true);
  const [selectedManagerId, setSelectedManagerId] = useState<string>('');
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [showHistory, setShowHistory] = useState(false);

  // Fetch available managers
  useEffect(() => {
    const fetchManagers = async () => {
      setIsLoadingManagers(true);
      try {
        const { data, error } = await supabaseClient.rpc('get_managers_list');
        if (error) throw error;
        // Filter out the employee themselves from the manager list
        const filteredManagers = (data as ManagerListItem[]).filter(
          (m) => m.id !== employeeId
        );
        setManagers(filteredManagers);
      } catch (err) {
        console.error('Failed to fetch managers:', err);
        toast.error('Failed to load managers list');
      } finally {
        setIsLoadingManagers(false);
      }
    };

    fetchManagers();
  }, [employeeId]);

  // Handle supervisor assignment
  const handleAssign = useCallback(async () => {
    if (!selectedManagerId) return;

    setIsSubmitting(true);
    try {
      const { data: result, error } = await supabaseClient.rpc('assign_supervisor', {
        p_employee_id: employeeId,
        p_manager_id: selectedManagerId,
        p_supervision_type: 'direct',
      });

      if (error) throw error;

      const response = result as AssignSupervisorResponse;
      if (!response.success) {
        toast.error(response.error?.message || 'Failed to assign supervisor');
        return;
      }

      toast.success(
        response.previous_assignment_ended
          ? 'Supervisor reassigned successfully'
          : 'Supervisor assigned successfully'
      );
      setSelectedManagerId('');
      onAssignmentChange();
    } catch (err) {
      console.error('Assignment error:', err);
      toast.error('Failed to assign supervisor');
    } finally {
      setIsSubmitting(false);
    }
  }, [employeeId, selectedManagerId, onAssignmentChange]);

  // Handle supervisor removal
  const handleRemove = useCallback(async () => {
    setIsSubmitting(true);
    try {
      const { data: result, error } = await supabaseClient.rpc('remove_supervisor', {
        p_employee_id: employeeId,
      });

      if (error) throw error;

      const response = result as RemoveSupervisorResponse;
      if (!response.success) {
        toast.error(response.error?.message || 'Failed to remove supervisor');
        return;
      }

      toast.success('Supervisor removed successfully');
      onAssignmentChange();
    } catch (err) {
      console.error('Remove error:', err);
      toast.error('Failed to remove supervisor');
    } finally {
      setIsSubmitting(false);
    }
  }, [employeeId, onAssignmentChange]);

  if (isLoadingManagers) {
    return (
      <div className="space-y-4">
        <Skeleton className="h-10 w-full" />
        <Skeleton className="h-10 w-32" />
      </div>
    );
  }

  return (
    <div className="space-y-4">
      {/* Current Supervisor Display */}
      <div className="space-y-2">
        <p className="text-sm font-medium">Current Supervisor</p>
        {currentSupervisor ? (
          <div className="flex items-center justify-between rounded-md border border-slate-200 bg-slate-50 px-3 py-2">
            <div>
              <p className="text-sm font-medium text-slate-900">
                {currentSupervisor.full_name || currentSupervisor.email}
              </p>
              {currentSupervisor.full_name && (
                <p className="text-xs text-slate-500">{currentSupervisor.email}</p>
              )}
            </div>
            {!isDisabled && (
              <Button
                variant="ghost"
                size="sm"
                onClick={handleRemove}
                disabled={isSubmitting}
                className="text-red-600 hover:text-red-700 hover:bg-red-50"
              >
                <UserMinus className="h-4 w-4" />
              </Button>
            )}
          </div>
        ) : (
          <div className="rounded-md border border-dashed border-slate-300 bg-slate-50 px-3 py-2 text-sm text-slate-500">
            No supervisor assigned
          </div>
        )}
      </div>

      {/* Assign/Reassign Supervisor */}
      {!isDisabled && (
        <div className="space-y-2">
          <p className="text-sm font-medium">
            {currentSupervisor ? 'Reassign Supervisor' : 'Assign Supervisor'}
          </p>
          <div className="flex gap-2">
            <Select value={selectedManagerId} onValueChange={setSelectedManagerId}>
              <SelectTrigger className="flex-1">
                <SelectValue placeholder="Select a manager..." />
              </SelectTrigger>
              <SelectContent>
                {managers.length === 0 ? (
                  <div className="px-2 py-1.5 text-sm text-slate-500">
                    No managers available
                  </div>
                ) : (
                  managers.map((manager) => (
                    <SelectItem key={manager.id} value={manager.id}>
                      <div className="flex flex-col">
                        <span>{manager.full_name || manager.email}</span>
                        <span className="text-xs text-slate-500">
                          {manager.role} • {manager.supervised_count} supervised
                        </span>
                      </div>
                    </SelectItem>
                  ))
                )}
              </SelectContent>
            </Select>
            <Button
              onClick={handleAssign}
              disabled={!selectedManagerId || isSubmitting}
            >
              {isSubmitting ? 'Assigning...' : 'Assign'}
            </Button>
          </div>
        </div>
      )}

      {/* Supervision History */}
      {supervisionHistory.length > 0 && (
        <div className="space-y-2">
          <button
            type="button"
            onClick={() => setShowHistory(!showHistory)}
            className="flex items-center gap-1 text-sm font-medium text-slate-600 hover:text-slate-900"
          >
            <History className="h-4 w-4" />
            Supervision History ({supervisionHistory.length})
            {showHistory ? (
              <ChevronUp className="h-4 w-4" />
            ) : (
              <ChevronDown className="h-4 w-4" />
            )}
          </button>

          {showHistory && (
            <div className="space-y-2 rounded-md border border-slate-200 bg-slate-50 p-3">
              {supervisionHistory.map((entry) => (
                <div
                  key={entry.id}
                  className="flex items-center justify-between text-sm"
                >
                  <div>
                    <span className="font-medium">
                      {entry.manager_name || entry.manager_email}
                    </span>
                    <span className="text-slate-500 ml-1">({entry.supervision_type})</span>
                  </div>
                  <div className="text-slate-500 text-xs">
                    {new Date(entry.effective_from).toLocaleDateString()} –{' '}
                    {entry.effective_to
                      ? new Date(entry.effective_to).toLocaleDateString()
                      : 'Present'}
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
